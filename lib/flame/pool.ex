defmodule FLAME.Pool.RunnerState do
  @moduledoc false

  defstruct count: nil, pid: nil, monitor_ref: nil
end

defmodule FLAME.Pool.WaitingState do
  @moduledoc false

  defstruct from: nil, monitor_ref: nil, deadline: nil
end

defmodule FLAME.Pool.Caller do
  @moduledoc false

  defstruct checkout_ref: nil, monitor_ref: nil, runner_ref: nil
end

defmodule FLAME.Pool do
  @moduledoc """
  Manages a pool of `FLAME.Runner` processes.

  Pools support elastic growth and shrinking of the number of runners.

  ## Examples

      children = [
        ...,
        {FLAME.Pool, name: MyRunner, min: 1, max: 10, max_concurrency: 100}
      ]

  See `start_link/1` for supported options.

  ## TODO
  [ ] interface to configure min/max at runtime

  """
  use GenServer

  alias FLAME.{Pool, Runner, Queue}
  alias FLAME.Pool.{RunnerState, WaitingState, Caller}

  @default_max_concurrency 100
  @boot_timeout 30_000
  @idle_shutdown_after 30_000
  @async_boot_debounce 1_000

  defstruct name: nil,
            runner_sup: nil,
            task_sup: nil,
            terminator_sup: nil,
            child_placement_sup: nil,
            boot_timeout: nil,
            idle_shutdown_after: nil,
            min_idle_shutdown_after: nil,
            min: nil,
            max: nil,
            max_concurrency: nil,
            callers: %{},
            waiting: Queue.new(),
            runners: %{},
            pending_runners: %{},
            runner_opts: [],
            on_grow_start: nil,
            on_grow_end: nil,
            on_shrink: nil,
            async_boot_timer: nil

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {FLAME.Pool.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts a pool of runners.

  ## Options

    * `:name` - The name of the pool, for example: `MyApp.FFMPegRunner`

    * `:min` - The minimum number of runners to keep in the pool at all times.
      For "scale to zero" behavior you may pass `0`. When starting as a flame child,
      the `:min` will be forced to zero to avoid recursively starting backend resources.

    * `:max` - The maximum number of runners to elastically grow to in the pool.

    * `:max_concurrency` - The maximum number of concurrent executions per runner before
      booting new runners or queueing calls. Defaults to `100`.

    * `:single_use` - if `true`, runners will be terminated after each call completes.
      Defaults `false`.

    * `:backend` - The backend to use. Defaults to the configured `:flame, :backend` or
      `FLAME.LocalBackend` if not configured.

    * `:log` - The log level to use for verbose logging. Defaults to `false`.

    * `:timeout` - The time to allow functions to execute on a remote node. Defaults to 30 seconds.
      This value is also used as the default `FLAME.call/3` timeout for the caller.
    * `:boot_timeout` - The time to allow for booting and connecting to a remote node.
      Defaults to 30 seconds.

    * `:shutdown_timeout` - The time to allow for graceful shutdown on the remote node.
      Defaults to 30 seconds.

    * `:idle_shutdown_after` - The amount of time and function check to idle a remote node
      down after a period of inactivity. Defaults to 30 seconds. A tuple may also be passed
      to check a specific condition, for example:

          {10_000, fn -> Supervisor.which_children(MySup) == []}

    * `:min_idle_shutdown_after` - The same behavior of `:idle_shutdown_after`, but applied
      to the the `:min` pool runners. Defaults to `:infinity`.

    * `:on_grow_start` - The optional function to be called when the pool starts booting a new
      runner beyond the configured `:min`. The function receives a map with the following metadata:

        * `:name` - The name of the pool
        * `:count` - The number of runners the pool is attempting to grow to
        * `:pid` - The pid of the async process that is booting the new runner

     * `:on_grow_end` - The optional 2-arty function to be called when the pool growth process completes.
      The 2-arity function receives either `:ok` or `{:exit, reason}`, and map with the following metadata:

        * `:name` - The name of the pool
        * `:count` - The number of runners the pool is now at
        * `:pid` - The pid of the async process that attempted to boot the new runner

    * `:on_shrink` - The optional function to be called when the pool shrinks.
      The function receives a map with the following metadata:

        * `:name` - The name of the pool
        * `:count` - The number of runners the pool is attempting to shrink to

    * `:code_sync` – The optional list of options to enable copying and syncing code paths
      from the parent node to the runner node. Disabled by default. The options are:

      * `:copy_paths` – If `true`, the pool will copy the code paths from the parent node
        to the runner node on boot. Then any subsequent FLAME operation will sync code paths
        from parent to child. Useful when you are starting an image that needs to run
        dynamic code that is not available on the runner node. Defaults to `false`.

      * `:sync_beams` – A list of specific beam code paths to sync to the runner node. Useful
        when you want to sync specific beam code paths from the parent after sending all code
        paths from `:copy_paths` on initial boot. For example, with `copy_paths: true`,
        and `sync_beams: ["/home/app/.cache/.../ebin"]`, all the code from the parent will be
        copied on boot, but only the specific beam files will be synced on subsequent calls.
        With `copy_paths: false`, and `sync_beams: ["/home/app/.cache/.../ebin"]`,
        only the specific beam files will be synced on boot and for subsequent calls.
        Defaults to `[]`.

      * `:start_apps` – Either a boolean or a list of specific OTP applications names to start
        when the runner boots. When `true`, all applications currently running on the parent node
        are sent to the runner node to be started. Defaults to `false`.

      * `:verbose` – If `true`, the pool will log verbose information about the code sync process.
        Defaults to `false`.

      For example, in [Livebook](https://livebook.dev/), to start a pool with code sync enabled:

          Mix.install([:kino, :flame])

          Kino.start_child!(
            {FLAME.Pool,
              name: :my_flame,
              code_sync: [
                start_apps: true,
                copy_paths: true,
                sync_beams: [Path.join(System.tmp_dir!(), "livebook_runtime")]
              ],
              min: 1,
              max: 1,
              max_concurrency: 10,
              backend: {FLAME.FlyBackend,
                cpu_kind: "performance", cpus: 4, memory_mb: 8192,
                token: System.fetch_env!("FLY_API_TOKEN"),
                env: Map.take(System.get_env(), ["LIVEBOOK_COOKIE"]),
              },
              idle_shutdown_after: :timer.minutes(5)}
          )
  """
  def start_link(opts) do
    Keyword.validate!(opts, [
      :name,
      :runner_sup,
      :task_sup,
      :terminator_sup,
      :child_placement_sup,
      :idle_shutdown_after,
      :min_idle_shutdown_after,
      :min,
      :max,
      :max_concurrency,
      :backend,
      :log,
      :single_use,
      :timeout,
      :boot_timeout,
      :shutdown_timeout,
      :on_grow_start,
      :on_grow_end,
      :on_shrink,
      :code_sync
    ])

    Keyword.validate!(opts[:code_sync] || [], [:copy_paths, :sync_beams, :start_apps, :verbose])

    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  Calls a function in a remote runner for the given `FLAME.Pool`.

  See `FLAME.call/3` for more information.
  """
  def call(name, func, opts \\ []) when is_function(func, 0) and is_list(opts) do
    caller_pid = self()
    do_call(name, func, caller_pid, opts)
  end

  defp do_call(name, func, caller_pid, opts) when is_pid(caller_pid) do
    caller_checkout!(name, opts, :call, [name, func, opts], fn runner_pid, remaining_timeout ->
      opts = Keyword.put_new(opts, :timeout, remaining_timeout)
      {:cancel, :ok, Runner.call(runner_pid, caller_pid, func, opts)}
    end)
  end

  @doc """
  Casts a function to a remote runner for the given `FLAME.Pool`.

  See `FLAME.cast/3` for more information.
  """
  def cast(name, func, opts) when is_function(func, 0) and is_list(opts) do
    %{task_sup: task_sup} = lookup_meta(name)

    caller_pid = self()
    opts = Keyword.put_new(opts, :timeout, :infinity)

    # we don't care about the result so don't copy it back to the caller
    wrapped = fn ->
      func.()
      :ok
    end

    {:ok, _pid} =
      Task.Supervisor.start_child(task_sup, fn -> do_call(name, wrapped, caller_pid, opts) end)

    :ok
  end

  @doc """
  See `FLAME.place_child/3` for more information.
  """
  def place_child(name, child_spec, opts) do
    caller_checkout!(name, opts, :place_child, [name, child_spec, opts], fn runner_pid,
                                                                            remaining_timeout ->
      place_opts =
        opts
        |> Keyword.put(:timeout, opts[:timeout] || remaining_timeout)
        |> Keyword.put_new(:link, true)

      case Runner.place_child(runner_pid, child_spec, place_opts) do
        {:ok, child_pid} = result ->
          # we are placing the link back on the parent node, but we are protected
          # from racing the link on the child FLAME because the terminator on
          # the remote flame is monitoring the caller and will terminator the child
          # if we go away
          if Keyword.fetch!(place_opts, :link), do: Process.link(child_pid)
          {:cancel, {:replace, child_pid}, result}

        :ignore ->
          {:cancel, :ok, :ignore}

        {:error, _reason} = result ->
          {:cancel, :ok, result}
      end
    end)
  end

  defp caller_checkout!(name, opts, fun_name, args, func) do
    timeout = opts[:timeout] || lookup_boot_timeout(name)
    pid = Process.whereis(name) || exit!(:noproc, fun_name, args)
    ref = Process.monitor(pid)
    {start_time, deadline} = deadline(timeout)

    # Manually implement call to avoid double monitor.
    # Auto-connect is asynchronous. But we still use :noconnect to make sure
    # we send on the monitored connection, and not trigger a new auto-connect.
    Process.send(pid, {:"$gen_call", {self(), ref}, {:checkout, deadline}}, [:noconnect])

    receive do
      {^ref, runner_pid} ->
        try do
          Process.demonitor(ref, [:flush])
          remaining_timeout = remaining_timeout(opts, start_time)
          func.(runner_pid, remaining_timeout)
        catch
          kind, reason ->
            send_cancel(pid, ref, :catch)
            :erlang.raise(kind, reason, __STACKTRACE__)
        else
          {:cancel, reason, result} ->
            send_cancel(pid, ref, reason)
            result
        end

      {:DOWN, ^ref, _, _, reason} ->
        exit!(reason, fun_name, args)
    after
      timeout ->
        send_cancel(pid, ref, :timeout)
        Process.demonitor(ref, [:flush])
        exit!(:timeout, fun_name, args)
    end
  end

  defp send_cancel(pid, ref, reason) when is_pid(pid) and is_reference(ref) do
    send(pid, {:cancel, ref, self(), reason})
  end

  defp exit!(reason, fun, args), do: exit({reason, {__MODULE__, fun, args}})

  defp remaining_timeout(opts, mono_start) do
    case Keyword.fetch(opts, :timeout) do
      {:ok, :infinity = inf} ->
        inf

      {:ok, nil} ->
        nil

      {:ok, ms} when is_integer(ms) ->
        elapsed_ms =
          System.convert_time_unit(System.monotonic_time() - mono_start, :native, :millisecond)

        ms - elapsed_ms

      :error ->
        nil
    end
  end

  defp lookup_meta(name) do
    :ets.lookup_element(name, :meta, 2)
  end

  defp lookup_boot_timeout(name) do
    %{boot_timeout: timeout} = lookup_meta(name)
    timeout
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    task_sup = Keyword.fetch!(opts, :task_sup)
    boot_timeout = Keyword.get(opts, :boot_timeout, @boot_timeout)
    :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(name, {:meta, %{boot_timeout: boot_timeout, task_sup: task_sup}})
    terminator_sup = Keyword.fetch!(opts, :terminator_sup)
    child_placement_sup = Keyword.fetch!(opts, :child_placement_sup)
    runner_opts = runner_opts(opts, terminator_sup)
    min = Keyword.fetch!(opts, :min)

    # we must avoid recursively booting remote runners if we are a child
    min =
      if FLAME.Parent.get() do
        0
      else
        min
      end

    state = %Pool{
      runner_sup: Keyword.fetch!(opts, :runner_sup),
      task_sup: task_sup,
      terminator_sup: terminator_sup,
      child_placement_sup: child_placement_sup,
      name: name,
      min: min,
      max: Keyword.fetch!(opts, :max),
      boot_timeout: boot_timeout,
      idle_shutdown_after: Keyword.get(opts, :idle_shutdown_after, @idle_shutdown_after),
      min_idle_shutdown_after: Keyword.get(opts, :min_idle_shutdown_after, :infinity),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      on_grow_start: opts[:on_grow_start],
      on_grow_end: opts[:on_grow_end],
      on_shrink: opts[:on_shrink],
      runner_opts: runner_opts
    }

    {:ok, boot_runners(state)}
  end

  defp runner_opts(opts, terminator_sup) do
    defaults = [terminator_sup: terminator_sup, log: Keyword.get(opts, :log, false)]

    runner_opts =
      Keyword.take(
        opts,
        [
          :backend,
          :log,
          :single_use,
          :timeout,
          :boot_timeout,
          :shutdown_timeout,
          :idle_shutdown_after,
          :code_sync
        ]
      )

    case Keyword.fetch(opts, :backend) do
      {:ok, {backend, opts}} ->
        Keyword.put(runner_opts, :backend, {backend, Keyword.merge(opts, defaults)})

      {:ok, backend} ->
        Keyword.put(runner_opts, :backend, {backend, defaults})

      :error ->
        backend = FLAME.Backend.impl()
        backend_opts = Application.get_env(:flame, backend) || []
        Keyword.put(runner_opts, :backend, {backend, Keyword.merge(backend_opts, defaults)})
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason} = msg, %Pool{} = state) do
    {:noreply, handle_down(state, msg)}
  end

  def handle_info({ref, {:ok, pid}}, %Pool{} = state) when is_reference(ref) do
    {:noreply, handle_runner_async_up(state, pid, ref)}
  end

  def handle_info(:async_boot_continue, %Pool{} = state) do
    {:noreply, async_boot_runner(%Pool{state | async_boot_timer: nil})}
  end

  def handle_info({:cancel, ref, caller_pid, reason}, state) do
    case reason do
      {:replace, child_pid} ->
        {:noreply, replace_caller(state, ref, caller_pid, child_pid)}

      reason when reason in [:ok, :timeout, :catch] ->
        {:noreply, checkin_runner(state, ref, caller_pid, reason)}
    end
  end

  @impl true
  def handle_call({:checkout, deadline}, from, state) do
    {:noreply, checkout_runner(state, deadline, from)}
  end

  defp runner_count(state) do
    map_size(state.runners) + map_size(state.pending_runners)
  end

  defp waiting_count(%Pool{waiting: %Queue{} = waiting}) do
    Queue.size(waiting)
  end

  defp min_runner(state) do
    if map_size(state.runners) == 0 do
      nil
    else
      {_ref, min} = Enum.min_by(state.runners, fn {_, %RunnerState{count: count}} -> count end)
      min
    end
  end

  defp replace_caller(state, checkout_ref, caller_pid, child_pid) do
    # replace caller with child pid and do not inc concurrency counts since we are replacing
    %{^caller_pid => %Caller{checkout_ref: ^checkout_ref} = caller} = state.callers
    Process.demonitor(caller.monitor_ref, [:flush])

    new_caller = %Caller{
      checkout_ref: checkout_ref,
      monitor_ref: Process.monitor(child_pid),
      runner_ref: caller.runner_ref
    }

    new_callers =
      state.callers
      |> Map.delete(caller_pid)
      |> Map.put(child_pid, new_caller)

    %Pool{state | callers: new_callers}
  end

  defp checkin_runner(state, ref, caller_pid, reason)
       when is_reference(ref) and is_pid(caller_pid) do
    case state.callers do
      %{^caller_pid => %Caller{checkout_ref: ^ref} = caller} ->
        Process.demonitor(caller.monitor_ref, [:flush])
        drop_caller(state, caller_pid, caller)

      # the only way to race a checkin is if the caller has expired while still in the
      # waiting state and checks in on the timeout before we lease it a runner.
      %{} when reason == :timeout ->
        maybe_drop_waiting(state, caller_pid)

      %{} ->
        raise ArgumentError,
              "expected to checkin runner for #{inspect(caller_pid)} that does not exist"
    end
  end

  defp checkout_runner(%Pool{} = state, deadline, from, monitor_ref \\ nil) do
    min_runner = min_runner(state)
    runner_count = runner_count(state)

    cond do
      runner_count == 0 || !min_runner ||
          (min_runner.count == state.max_concurrency && runner_count < state.max) ->
        if map_size(state.pending_runners) > 0 || state.async_boot_timer do
          waiting_in(state, deadline, from)
        else
          state
          |> async_boot_runner()
          |> waiting_in(deadline, from)
        end

      min_runner && min_runner.count < state.max_concurrency ->
        reply_runner_checkout(state, min_runner, from, monitor_ref)

      true ->
        waiting_in(state, deadline, from)
    end
  end

  defp reply_runner_checkout(state, %RunnerState{} = runner, from, monitor_ref) do
    # we pass monitor_ref down from waiting so we don't need to remonitor if already monitoring
    {from_pid, checkout_ref} = from

    caller_monitor_ref =
      if monitor_ref do
        monitor_ref
      else
        Process.monitor(from_pid)
      end

    GenServer.reply(from, runner.pid)

    new_caller = %Caller{
      checkout_ref: checkout_ref,
      monitor_ref: caller_monitor_ref,
      runner_ref: runner.monitor_ref
    }

    new_state = %Pool{state | callers: Map.put(state.callers, from_pid, new_caller)}

    inc_runner_count(new_state, runner.monitor_ref)
  end

  defp waiting_in(%Pool{} = state, deadline, {pid, _tag} = from) do
    ref = Process.monitor(pid)
    waiting = %WaitingState{from: from, monitor_ref: ref, deadline: deadline}
    %Pool{state | waiting: Queue.insert(state.waiting, waiting, pid)}
  end

  defp boot_runners(%Pool{} = state) do
    if state.min > 0 do
      # start min runners, and do not idle them down regardless of idle configuration
      # unless `:min_idle_shutdown_after` not infinity
      # TODO: allow % threshold of failed min's to continue startup?
      0..(state.min - 1)
      |> Task.async_stream(
        fn _ -> start_child_runner(state, idle_shutdown_after: state.min_idle_shutdown_after) end,
        max_concurrency: 10,
        timeout: state.boot_timeout
      )
      |> Enum.reduce(state, fn
        {:ok, {:ok, pid}}, acc ->
          {_runner, new_acc} = put_runner(acc, pid)
          new_acc

        {:exit, reason}, _acc ->
          raise "failed to boot runner: #{inspect(reason)}"
      end)
    else
      state
    end
  end

  defp schedule_async_boot_runner(%Pool{} = state) do
    if state.async_boot_timer, do: Process.cancel_timer(state.async_boot_timer)

    %Pool{
      state
      | async_boot_timer: Process.send_after(self(), :async_boot_continue, @async_boot_debounce)
    }
  end

  defp async_boot_runner(%Pool{on_grow_start: on_grow_start, name: name} = state) do
    new_count = runner_count(state) + 1

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        if on_grow_start, do: on_grow_start.(%{count: new_count, name: name, pid: self()})

        start_child_runner(state)
      end)

    new_pending = Map.put(state.pending_runners, task.ref, task.pid)
    %Pool{state | pending_runners: new_pending}
  end

  defp start_child_runner(%Pool{} = state, runner_opts \\ []) do
    opts = Keyword.merge(state.runner_opts, runner_opts)
    name = Module.concat(state.name, "Runner#{map_size(state.runners) + 1}")

    spec = %{
      id: name,
      start: {FLAME.Runner, :start_link, [opts]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(state.runner_sup, spec)

    try do
      case Runner.remote_boot(pid) do
        :ok -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    catch
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp put_runner(%Pool{} = state, pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    runner = %RunnerState{count: 0, pid: pid, monitor_ref: ref}
    new_state = %Pool{state | runners: Map.put(state.runners, runner.monitor_ref, runner)}
    {runner, new_state}
  end

  defp inc_runner_count(%Pool{} = state, ref) do
    new_runners =
      Map.update!(state.runners, ref, fn %RunnerState{} = runner ->
        %RunnerState{runner | count: runner.count + 1}
      end)

    %Pool{state | runners: new_runners}
  end

  defp dec_runner_count(%Pool{} = state, ref) do
    new_runners =
      Map.update!(state.runners, ref, fn %RunnerState{} = runner ->
        %RunnerState{runner | count: runner.count - 1}
      end)

    %Pool{state | runners: new_runners}
  end

  defp drop_child_runner(%Pool{} = state, runner_ref) when is_reference(runner_ref) do
    %{^runner_ref => %RunnerState{}} = state.runners
    Process.demonitor(runner_ref, [:flush])
    # kill all callers that still had a checkout for this runner
    new_state =
      Enum.reduce(state.callers, state, fn
        {caller_pid, %Caller{monitor_ref: ref, runner_ref: ^runner_ref}}, acc ->
          Process.demonitor(ref, [:flush])
          Process.exit(caller_pid, :kill)
          %Pool{acc | callers: Map.delete(acc.callers, caller_pid)}

        {_caller_pid, %Caller{}}, acc ->
          acc
      end)

    maybe_on_shrink(%Pool{new_state | runners: Map.delete(new_state.runners, runner_ref)})
  end

  defp drop_caller(%Pool{} = state, caller_pid, %Caller{} = caller) when is_pid(caller_pid) do
    new_state = %Pool{state | callers: Map.delete(state.callers, caller_pid)}

    new_state
    |> dec_runner_count(caller.runner_ref)
    |> call_next_waiting_caller()
  end

  defp maybe_drop_waiting(%Pool{} = state, caller_pid) when is_pid(caller_pid) do
    %Pool{state | waiting: Queue.delete_by_key(state.waiting, caller_pid)}
  end

  defp pop_next_waiting_caller(%Pool{} = state) do
    result =
      Queue.pop_until(state.waiting, fn _pid, %WaitingState{} = waiting ->
        %WaitingState{from: {pid, _}, monitor_ref: ref, deadline: deadline} = waiting
        # we don't need to reply to waiting callers because they will either have died
        # or execeeded their own deadline handled by receive + after
        if Process.alive?(pid) and not deadline_expired?(deadline) do
          true
        else
          Process.demonitor(ref, [:flush])
          false
        end
      end)

    case result do
      {nil, %Queue{} = new_waiting} -> {nil, %Pool{state | waiting: new_waiting}}
      {{_pid, %WaitingState{} = first}, %Queue{} = rest} -> {first, %Pool{state | waiting: rest}}
    end
  end

  defp call_next_waiting_caller(%Pool{} = state) do
    case pop_next_waiting_caller(state) do
      {nil, new_state} ->
        new_state

      {%WaitingState{} = first, new_state} ->
        # checkout_runner will borrow already running monitor
        checkout_runner(new_state, first.deadline, first.from, first.monitor_ref)
    end
  end

  defp handle_down(%Pool{} = state, {:DOWN, ref, :process, pid, reason}) do
    state = maybe_drop_waiting(state, pid)

    state =
      case state.callers do
        %{^pid => %Caller{monitor_ref: ^ref} = caller} ->
          drop_caller(state, pid, caller)

        %{} ->
          state
      end

    state =
      case state.runners do
        %{^ref => _} -> drop_child_runner(state, ref)
        %{} -> state
      end

    case state.pending_runners do
      %{^ref => _} ->
        state = %Pool{state | pending_runners: Map.delete(state.pending_runners, ref)}
        # we rate limit this to avoid many failed async boot attempts
        if has_unmet_servicable_demand?(state) do
          state
          |> maybe_on_grow_end(pid, {:exit, reason})
          |> schedule_async_boot_runner()
        else
          maybe_on_grow_end(state, pid, {:exit, reason})
        end

      %{} ->
        state
    end
  end

  defp maybe_on_grow_end(%Pool{on_grow_end: on_grow_end} = state, pid, result) do
    new_count = runner_count(state)
    meta = %{count: new_count, name: state.name, pid: pid}

    case result do
      :ok -> if on_grow_end, do: on_grow_end.(:ok, meta)
      {:exit, reason} -> if on_grow_end, do: on_grow_end.({:exit, reason}, meta)
    end

    state
  end

  defp maybe_on_shrink(%Pool{} = state) do
    new_count = runner_count(state)
    if state.on_shrink, do: state.on_shrink.(%{count: new_count, name: state.name})

    state
  end

  defp has_unmet_servicable_demand?(%Pool{} = state) do
    waiting_count(state) > 0 and runner_count(state) < state.max
  end

  defp handle_runner_async_up(%Pool{} = state, pid, ref) when is_pid(pid) and is_reference(ref) do
    %{^ref => task_pid} = state.pending_runners
    Process.demonitor(ref, [:flush])

    new_state = %Pool{state | pending_runners: Map.delete(state.pending_runners, ref)}
    {runner, new_state} = put_runner(new_state, pid)
    new_state = maybe_on_grow_end(new_state, task_pid, :ok)

    # pop waiting callers up to max_concurrency, but we must handle:
    # 1. the case where we have no waiting callers
    # 2. the case where we process a DOWN for the new runner as we pop DOWNs
    #   looking for fresh waiting
    # 3. if we still have waiting callers at the end, boot more runners if we have capacity
    new_state =
      Enum.reduce_while(1..state.max_concurrency, new_state, fn i, acc ->
        with {:ok, %RunnerState{} = runner} <- Map.fetch(acc.runners, runner.monitor_ref),
             true <- i <= acc.max_concurrency do
          case pop_next_waiting_caller(acc) do
            {%WaitingState{} = next, acc} ->
              {:cont, reply_runner_checkout(acc, runner, next.from, next.monitor_ref)}

            {nil, acc} ->
              {:halt, acc}
          end
        else
          _ -> {:halt, acc}
        end
      end)

    if has_unmet_servicable_demand?(new_state) do
      async_boot_runner(new_state)
    else
      new_state
    end
  end

  defp deadline(timeout) when is_integer(timeout) do
    t1 = System.monotonic_time()
    {t1, t1 + System.convert_time_unit(timeout, :millisecond, :native)}
  end

  defp deadline(:infinity) do
    {System.monotonic_time(), :infinity}
  end

  defp deadline_expired?(deadline) when is_integer(deadline) do
    System.monotonic_time() >= deadline
  end

  defp deadline_expired?(:infinity), do: false
end
