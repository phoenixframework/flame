defmodule FLAME.Runner do
  @moduledoc false
  # ## Runners

  # In practice, users utilize the `FLAME.call/3` and `FLAME.cast/3` functions
  # to accomplish their work. These functions are backed by a `FLAME.Pool` of
  # `FLAME.Runner`'s
  #
  # A `FLAME.Runner` is responsible for booting a new node, and executing concurrent
  # functions on it. For example:
  #
  #     {:ok, runner} = Runner.start_link(backend: FLAME.FlyBackend)
  #     :ok = Runner.remote_boot(runner)
  #     Runner.call(runner, fn -> :operation1 end)
  #     Runner.shutdown(runner)
  #
  # When a caller exits or crashes, the remote node will automatically be terminated.
  # For distributed erlang backends, like `FLAME.FlyBackend`, this will be
  # accomplished automatically by the `FLAME.Terminator`, but other methods
  # are possible.

  use GenServer
  require Logger

  alias FLAME.{Runner, Terminator, CodeSync}

  @derive {Inspect,
           only: [
             :id,
             :backend,
             :terminator,
             :instance_id,
             :private_ip,
             :node_name,
             :single_use,
             :timeout,
             :status,
             :log,
             :boot_timeout,
             :idle_shutdown_after,
             :idle_shutdown_check
           ]}

  defstruct id: nil,
            instance_id: nil,
            private_ip: nil,
            backend: nil,
            terminator: nil,
            backend_init: nil,
            node_name: nil,
            single_use: false,
            timeout: 20_000,
            status: nil,
            log: :info,
            boot_timeout: 10_000,
            shutdown_timeout: 5_000,
            idle_shutdown_after: nil,
            idle_shutdown_check: nil,
            code_sync_opts: false,
            code_sync: nil

  @doc """
  Starts a runner.

  ## Options

    `:backend` - The `Flame.Backend` implementation to use
    `:log` - The log level, or `false`
    `:single_use` - The boolean on whether to terminate the runner after it's first call
    `:timeout` - The execution timeout of calls
    `:boot_timeout` - The boot timeout of the runner
    `:shutdown_timeout` - The shutdown timeout
    `:idle_shutdown_after` - The idle shutdown time
    `:code_sync` - The code sync options. See the `FLAME.Pool` module for more information.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def shutdown(runner, timeout \\ nil) when is_pid(runner) do
    GenServer.call(runner, {:runner_shutdown, timeout})
  end

  @doc """
  Boots the remote runner using the `FLAME.Backend`.
  """
  def remote_boot(pid, timeout \\ nil) when is_pid(pid) do
    GenServer.call(pid, {:remote_boot, timeout}, timeout || :infinity)
  end

  @doc """
  Places a child process on the remote node.

  The started child spec will be rewritten to use the `:temporary` restart strategy
  to ensure that the child is not restarted if it exits. If you want restart
  behavior, you must monitor the process yourself on the parent node and replace it.
  """
  def place_child(runner_pid, child_spec, opts)
      when is_pid(runner_pid) and is_list(opts) do
    # we must rewrite :temporary restart strategy for the spec to avoid restarting placed children
    new_spec = Supervisor.child_spec(child_spec, restart: :temporary)
    caller_pid = self()
    link? = Keyword.get(opts, :link, true)

    call(
      runner_pid,
      caller_pid,
      fn terminator ->
        Terminator.place_child(terminator, caller_pid, link?, new_spec)
      end,
      opts
    )
  end

  @doc """
  Calls a function on the remote node.
  """
  def call(runner_pid, caller_pid, func, opts \\ [])
      when is_pid(runner_pid) and is_pid(caller_pid) and is_function(func) and is_list(opts) do
    link? = Keyword.get(opts, :link, true)
    timeout = opts[:timeout] || nil
    {ref, %Runner{} = runner, backend_state} = checkout(runner_pid)
    %Runner{terminator: terminator} = runner
    call_timeout = timeout || runner.timeout

    result =
      remote_call(runner, backend_state, call_timeout, fn ->
        if link?, do: Process.link(caller_pid)
        :ok = Terminator.deadline_me(terminator, call_timeout)
        if is_function(func, 1), do: func.(terminator), else: func.()
      end)

    case result do
      {:ok, value} ->
        :ok = checkin(runner_pid, ref)
        value

      {kind, reason} ->
        :ok = checkin(runner_pid, ref)

        case kind do
          :exit -> exit(reason)
          :error -> raise(reason)
          :throw -> throw(reason)
        end
    end
  end

  defp checkout(runner_pid) do
    GenServer.call(runner_pid, :checkout)
  end

  defp checkin(runner_pid, ref) do
    GenServer.call(runner_pid, {:checkin, ref})
  end

  @impl true
  def init(opts) do
    runner = new(opts)

    case runner.backend_init do
      {:ok, backend_state} ->
        state = %{
          runner: runner,
          checkouts: %{},
          backend_state: backend_state,
          otp_app: if(otp_app = System.get_env("RELEASE_NAME"), do: String.to_atom(otp_app))
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, reason} = msg, state) do
    %{runner: %Runner{} = runner} = state

    case runner do
      %Runner{terminator: ^pid} ->
        {:stop, reason, state}

      %Runner{terminator: _} ->
        case state.checkouts do
          %{^ref => _from_pid} ->
            new_state = drop_checkout(state, ref)

            if runner.single_use do
              {:stop, reason, new_state}
            else
              {:noreply, new_state}
            end

          %{} ->
            {:noreply, maybe_backend_handle_info(state, msg)}
        end
    end
  end

  def handle_info({_ref, {:remote_shutdown, reason}}, state) do
    {:stop, {:shutdown, reason}, state}
  end

  def handle_info(msg, state) do
    {:noreply, maybe_backend_handle_info(state, msg)}
  end

  defp maybe_backend_handle_info(state, msg) do
    %Runner{backend: backend} = state.runner

    if function_exported?(backend, :handle_info, 2) do
      case backend.handle_info(msg, state.backend_state) do
        {:noreply, new_backend_state} ->
          %{state | backend_state: new_backend_state}

        other ->
          raise ArgumentError,
                "expected #{inspect(backend)}.handle_info/2 to return {:noreply, state}, got: #{inspect(other)}"
      end
    else
      state
    end
  end

  @impl true
  def handle_call({:runner_shutdown, timeout}, _from, state) do
    %{runner: runner} = state
    timeout = timeout || runner.shutdown_timeout
    ref = make_ref()
    parent = self()
    %Runner{terminator: terminator} = runner

    state = drain_checkouts(state, timeout)

    {:ok, {remote_pid, remote_monitor_ref}} =
      runner.backend.remote_spawn_monitor(state.backend_state, fn ->
        :ok = Terminator.system_shutdown(terminator)
        send(parent, {ref, :ok})
      end)

    receive do
      {^ref, :ok} ->
        {:stop, :normal, :ok, state}

      {:DOWN, ^remote_monitor_ref, :process, ^remote_pid, reason} ->
        {:stop, {:shutdown, reason}, {:error, reason}, state}
    after
      timeout -> exit(:timeout)
    end
  end

  def handle_call(:checkout, {from_pid, _tag}, state) do
    ref = Process.monitor(from_pid)

    state =
      case maybe_diff_code_paths(state) do
        {new_state, nil} ->
          new_state

        {new_state, %CodeSync.PackagedStream{} = parent_pkg} ->
          remote_call!(state.runner, state.backend_state, state.runner.boot_timeout, fn ->
            :ok = CodeSync.extract_packaged_stream(parent_pkg)
          end)

          CodeSync.rm_packaged_stream(parent_pkg)

          new_state
      end

    {:reply, {ref, state.runner, state.backend_state}, put_checkout(state, from_pid, ref)}
  end

  def handle_call({:checkin, ref}, _from, state) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, drop_checkout(state, ref)}
  end

  def handle_call({:remote_boot, _timeout}, _from, state) do
    %{runner: runner, backend_state: backend_state, otp_app: otp_app} = state

    case runner.status do
      :booted ->
        {:reply, {:error, :already_booted}, state}

      :awaiting_boot ->
        time(runner, "runner connect", fn ->
          case runner.backend.remote_boot(backend_state) do
            {:ok, remote_terminator_pid, new_backend_state} when is_pid(remote_terminator_pid) ->
              Process.monitor(remote_terminator_pid)
              new_runner = %Runner{runner | terminator: remote_terminator_pid, status: :booted}
              new_state = %{state | runner: new_runner, backend_state: new_backend_state}
              {new_state, parent_stream} = maybe_stream_code_paths(new_state)

              %Runner{
                single_use: single_use,
                idle_shutdown_after: idle_after,
                idle_shutdown_check: idle_check,
                terminator: term
              } = new_runner

              :ok =
                remote_call!(runner, new_backend_state, runner.boot_timeout, fn ->
                  # ensure app is fully started if parent connects before up
                  if otp_app, do: {:ok, _} = Application.ensure_all_started(otp_app)

                  :ok =
                    Terminator.schedule_idle_shutdown(term, idle_after, idle_check, single_use)

                  if parent_stream do
                    :ok = CodeSync.extract_packaged_stream(parent_stream)
                  else
                    :ok
                  end
                end)

              if parent_stream, do: CodeSync.rm_packaged_stream(parent_stream)

              {:reply, :ok, new_state}

            {:error, reason} ->
              {:stop, {:shutdown, reason}, state}

            other ->
              raise ArgumentError,
                    "expected #{inspect(runner.backend)}.remote_boot/1 to return {:ok, remote_terminator_pid, new_state} | {:error, reason}, got: #{inspect(other)}"
          end
        end)
    end
  end

  @doc false
  def new(opts) when is_list(opts) do
    opts =
      Keyword.validate!(opts, [
        :backend,
        :log,
        :single_use,
        :timeout,
        :boot_timeout,
        :shutdown_timeout,
        :idle_shutdown_after,
        :code_sync
      ])

    Keyword.validate!(opts[:code_sync] || [], [
      :copy_paths,
      :sync_beams,
      :start_apps,
      :tmp_dir,
      :extract_dir,
      :verbose
    ])

    {idle_shutdown_after_ms, idle_check} =
      case Keyword.fetch(opts, :idle_shutdown_after) do
        {:ok, :infinity} -> {:infinity, fn -> false end}
        {:ok, ms} when is_integer(ms) -> {ms, fn -> true end}
        {:ok, {ms, func}} when is_integer(ms) and is_function(func, 0) -> {ms, func}
        other when other in [{:ok, nil}, :error] -> {30_000, fn -> true end}
      end

    runner =
      %Runner{
        status: :awaiting_boot,
        backend: :pending,
        backend_init: :pending,
        log: Keyword.get(opts, :log, false),
        single_use: Keyword.get(opts, :single_use, false),
        timeout: opts[:timeout] || 30_000,
        boot_timeout: opts[:boot_timeout] || 30_000,
        shutdown_timeout: opts[:shutdown_timeout] || 30_000,
        idle_shutdown_after: idle_shutdown_after_ms,
        idle_shutdown_check: idle_check,
        terminator: nil,
        code_sync_opts: Keyword.get(opts, :code_sync, false)
      }

    {backend, backend_init} =
      case Keyword.fetch!(opts, :backend) do
        backend when is_atom(backend) ->
          opts = Application.get_env(:flame, backend) || []
          {backend, backend.init(opts)}

        {backend, opts} when is_atom(backend) and is_list(opts) ->
          {backend, backend.init(opts)}
      end

    %Runner{runner | backend: backend, backend_init: backend_init}
  end

  defp time(%Runner{log: false} = _runner, _label, func) do
    func.()
  end

  # TODO move this to telemetry
  defp time(%Runner{log: level}, label, func) do
    Logger.log(level, "#{label}: start")
    {elapsed_micro, result} = :timer.tc(func)
    millisec = System.convert_time_unit(elapsed_micro, :microsecond, :millisecond)
    Logger.log(level, "#{label}: completed in #{millisec}ms")
    result
  end

  defp put_checkout(state, from_pid, ref) when is_pid(from_pid) do
    %{state | checkouts: Map.put(state.checkouts, ref, from_pid)}
  end

  defp drop_checkout(state, ref) when is_reference(ref) do
    %{^ref => _from_pid} = state.checkouts
    %{state | checkouts: Map.delete(state.checkouts, ref)}
  end

  defp remote_call!(%Runner{} = runner, backend_state, timeout, func) do
    case remote_call(runner, backend_state, timeout, func) do
      {:ok, value} -> value
      {:exit, reason} -> exit(reason)
      {:error, error} -> raise(error)
      {:throw, val} -> throw(val)
    end
  end

  defp remote_call(%Runner{} = runner, backend_state, timeout, func) do
    parent_ref = make_ref()
    parent = self()

    {:ok, {remote_pid, remote_monitor_ref}} =
      runner.backend.remote_spawn_monitor(backend_state, fn ->
        # This runs on the remote node
        send(parent, {parent_ref, func.()})
      end)

    receive do
      {^parent_ref, result} ->
        Process.demonitor(remote_monitor_ref, [:flush])
        {:ok, result}

      {:DOWN, ^remote_monitor_ref, :process, ^remote_pid, reason} ->
        case reason do
          :killed -> {:exit, :timeout}
          other -> {:exit, other}
        end

      {:EXIT, ^remote_pid, reason} ->
        {:exit, reason}
    after
      timeout ->
        {:exit, :timeout}
    end
  end

  @drain_timeout :drain_timeout
  defp drain_checkouts(state, timeout) do
    case state.checkouts do
      checkouts when checkouts == %{} ->
        state

      checkouts ->
        Process.send_after(self(), @drain_timeout, timeout)

        Enum.reduce(checkouts, state, fn {ref, _from_pid}, acc ->
          receive do
            {:checkin, ^ref} -> drop_checkout(acc, ref)
            {:DOWN, ^ref, :process, _pid, _reason} -> drop_checkout(acc, ref)
            @drain_timeout -> exit(:timeout)
          end
        end)
    end
  end

  defp maybe_stream_code_paths(%{runner: %Runner{} = runner} = state) do
    if code_sync_opts = runner.code_sync_opts do
      code_sync = CodeSync.new(code_sync_opts)
      %CodeSync.PackagedStream{} = parent_stream = CodeSync.package_to_stream(code_sync)
      new_runner = %Runner{runner | code_sync: code_sync}
      {%{state | runner: new_runner}, parent_stream}
    else
      {state, nil}
    end
  end

  defp maybe_diff_code_paths(%{runner: %Runner{} = runner} = state) do
    if runner.code_sync do
      diffed_code = CodeSync.diff(runner.code_sync)
      new_runner = %Runner{runner | code_sync: diffed_code}
      new_state = %{state | runner: new_runner}

      if CodeSync.changed?(diffed_code) do
        %CodeSync.PackagedStream{} = parent_stream = CodeSync.package_to_stream(diffed_code)
        {new_state, parent_stream}
      else
        {new_state, nil}
      end
    else
      {state, nil}
    end
  end
end
