defmodule Dragonfly.Runner do
  @moduledoc """
  TODO
  """
  use GenServer
  require Logger

  alias Dragonfly.{Runner, Backend}

  @derive {Inspect,
           only: [
             :id,
             :backend,
             :instance_id,
             :private_ip,
             :node_name,
             :single_use,
             :task_sup,
             :timeout,
             :status,
             :log,
             :connect_timeout
           ]}

  defstruct id: nil,
            instance_id: nil,
            private_ip: nil,
            backend: nil,
            backend_init: nil,
            node_name: nil,
            single_use: false,
            task_sup: nil,
            timeout: 20_000,
            status: nil,
            log: :info,
            connect_timeout: 10_000,
            shutdown_timeout: 5_000

  @doc """
  TODO

  ## Examples

      iex> Dragonfly.Runner.start_link()
      {:ok, pid}
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  def shutdown(runner, timeout \\ nil) when is_pid(runner) do
    GenServer.call(runner, {:shutdown, timeout})
  end

  @doc """
  TODO

  ## Examples

      iex> {:ok, pid} = Dragonfly.Runner.start_link(...)
      {:ok, pid}

      iex> Dragonfly.Runner.remote_boot(pid)
      :ok
  """
  def remote_boot(pid, timeout \\ nil) when is_pid(pid) do
    GenServer.call(pid, {:remote_boot, timeout}, timeout || :infinity)
  end

  @doc """
  TODO
  """
  def call(pid, func, timeout \\ nil) when is_pid(pid) and is_function(func, 0) do
    ref = make_ref()

    case GenServer.call(pid, {:remote_call, ref, func, timeout}, timeout || :infinity) do
      {^ref, :ok} ->
        # as soon as we get the :ok from runner, we await the remote result which
        # will be in our mailbox
        receive do
          {^ref, :ok, result} -> result
        after
          0 -> exit(:timeout)
        end

      {^ref, :fail, {kind, reason}} ->
        case {kind, reason} do
          {:throw, reason} -> throw(reason)
          {:error, {reason, stack}} -> reraise(reason, stack)
          {:exit, reason} -> exit(reason)
        end
    end
  end

  @doc """
  TODO
  """
  def cast(pid, func) when is_pid(pid) and is_function(func, 0) do
    GenServer.cast(pid, {:remote_cast, func})
  end

  @impl true
  def init(opts) do
    runner = new(opts)

    case runner.backend_init do
      {:ok, backend_state} ->
        {:ok, %{runner: runner, waiting: %{}, spawns: %{}, backend_state: backend_state}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:remote_ok, ref}, state) do
    %{^ref => from} = state.waiting
    GenServer.reply(from, {ref, :ok})
    {:noreply, drop_waiting(state, ref)}
  end

  def handle_info({:remote_fail, ref, reason}, state) do
    debug(state, "remote_fail: #{inspect(reason)}")
    %{^ref => from} = state.waiting
    GenServer.reply(from, {ref, :fail, reason})
    {:noreply, drop_waiting(state, ref)}
  end

  def handle_info({:DOWN, _monitor_ref, :process, pid, reason} = msg, state) do
    %Runner{} = runner = state.runner

    case state.spawns do
      %{^pid => ref} ->
        # if we still have waiting, something went wrong, tell caller and cleanup
        case state.waiting do
          %{^ref => _} -> maybe_reply_waiting(state, ref, {ref, :fail, {:exit, reason}})
          %{} -> :noop
        end

        new_state =
          state
          |> drop_waiting(ref)
          |> drop_spawn(pid)

        if runner.single_use do
          stop_reason =
            case reason do
              :normal -> :normal
              other -> {:shutdown, other}
            end

          {:stop, stop_reason, new_state}
        else
          {:noreply, new_state}
        end

      %{} ->
        {:noreply, maybe_backend_handle_info(state, msg)}
    end
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
  def handle_cast({:remote_cast, func}, state) do
    ref = make_ref()

    {:noreply,
     state
     |> put_waiting(ref, nil)
     |> remote_async_call(ref, _caller_parent = nil, func, _timeout = nil)}
  end

  @impl true
  def handle_call({:shutdown, timeout}, _from, state) do
    %{runner: runner} = state
    timeout = timeout || runner.shutdown_timeout
    ref = make_ref()
    parent = self()

    result =
      runner.backend.remote_spawn_link(state.backend_state, fn ->
        send(parent, {ref, :ok})
        runner.backend.system_shutdown()
      end)

    case result do
      {:ok, _spawn_pid, _backend_state} ->
        receive do
          {^ref, :ok} -> {:stop, :normal, :ok, state}
        after
          timeout -> exit(:timeout)
        end

      {:error, reason, _} ->
        {:stop, {:shutdown, reason}, {:error, reason}, state}
    end
  end

  def handle_call({:remote_call, ref, func, timeout}, from, state) do
    {caller_parent, _ref} = from

    {:noreply,
     state
     |> put_waiting(ref, from)
     |> remote_async_call(ref, caller_parent, func, timeout)}
  end

  def handle_call({:remote_boot, _timeout}, _from, state) do
    %{runner: runner, backend_state: backend_state} = state

    case runner.status do
      :booted ->
        {:reply, {:error, :already_booted}, state}

      :awaiting_boot ->
        time(runner, "runner connect", fn ->
          case runner.backend.remote_boot(backend_state) do
            {:ok, new_backend_state} ->
              new_runner = %Runner{runner | status: :booted}
              {:reply, :ok, %{state | runner: new_runner, backend_state: new_backend_state}}

            {:error, reason} ->
              {:stop, {:shutdown, reason}, state}

            other ->
              raise ArgumentError,
                    "expected #{inspect(runner.backend)}.remote_boot/1 to return {:ok, new_state} | {:error, reason}, got: #{inspect(other)}"
          end
        end)
    end
  end

  defp put_waiting(state, ref, {_pid, _tag} = from) do
    %{state | waiting: Map.put(state.waiting, ref, from)}
  end

  defp drop_waiting(state, ref) do
    %{state | waiting: Map.delete(state.waiting, ref)}
  end

  defp monitor_remote_spawn(state, pid, ref) when is_pid(pid) do
    Process.monitor(pid)
    %{state | spawns: Map.put(state.spawns, pid, ref)}
  end

  defp drop_spawn(state, pid) when is_pid(pid) do
    %{state | spawns: Map.delete(state.spawns, pid)}
  end

  defp remote_async_call(state, ref, caller_parent, func, timeout)
       when is_pid(caller_parent) or is_nil(caller_parent) do
    %Runner{} = runner = state.runner
    parent = self()
    timeout = timeout || state.runner.timeout

    result =
      runner.backend.remote_spawn_link(state.backend_state, fn ->
        try do
          task = Task.Supervisor.async_nolink(runner.task_sup, func)

          case Task.yield(task, timeout) || Task.shutdown(task) do
            {:ok, result} ->
              # send to caller first to ensure we will have it in the mailbox as soon
              # as runner parent tells caller it got :ok
              if caller_parent, do: send(caller_parent, {ref, :ok, result})
              send(parent, {:remote_ok, ref})

            {:exit, reason} ->
              send(parent, {:remote_fail, ref, {:exit, reason}})

            nil ->
              send(parent, {:remote_fail, ref, {:exit, :timeout}})
          end
        after
          if runner.single_use, do: runner.backend.system_shutdown()
        end
      end)

    case result do
      {:ok, spawn_pid, backend_state} ->
        monitor_remote_spawn(%{state | backend_state: backend_state}, spawn_pid, ref)

      {:error, reason, backend_state} ->
        maybe_reply_waiting(state, ref, {ref, :fail, {:exit, reason}})
        {:stop, {:shutdown, reason}, %{state | backend_state: backend_state}}
    end
  end

  defp maybe_reply_waiting(state, ref, reply) do
    case state.waiting do
      %{^ref => nil} -> :noop
      %{^ref => from} -> GenServer.reply(from, reply)
    end
  end

  @doc false
  def new(opts \\ []) do
    opts =
      Keyword.validate!(opts, [
        :backend,
        :log,
        :single_use,
        :timeout,
        :connect_timeout,
        :shutdown_timeout,
        :task_sup
      ])

    {backend, backend_opts} =
      case Keyword.fetch(opts, :backend) do
        {:ok, backend} when is_atom(backend) ->
          opts = Application.get_env(:dragonfly, backend) || []
          {backend, backend.init(opts)}

        {:ok, {backend, opts}} when is_atom(backend) and is_list(opts) ->
          {backend, backend.init(opts)}

        :error ->
          backend = Backend.impl()
          opts = Application.get_env(:dragonfly, backend) || []
          {backend, backend.init(opts)}
      end

    %Runner{
      status: :awaiting_boot,
      backend: backend,
      backend_init: backend_opts,
      log: Keyword.get(opts, :log, :info),
      single_use: Keyword.get(opts, :single_use, false),
      timeout: opts[:timeout] || 20_000,
      connect_timeout: opts[:connect_timeout] || 30_000,
      shutdown_timeout: opts[:shutdown_timeout] || 5_000,
      task_sup: opts[:task_sup] || Dragonfly.TaskSupervisor
    }
  end

  defp time(%Runner{log: :debug}, label, func) do
    {elapsed_micro, result} = :timer.tc(func)
    millisec = System.convert_time_unit(elapsed_micro, :microsecond, :millisecond)
    Logger.info("#{label}: completed in #{millisec}ms")
    result
  end

  defp time(%Runner{log: _} = _runner, _label, func) do
    func.()
  end

  defp debug(%{runner: %Runner{log: log}}, msg) do
    case log do
      :debug -> Logger.info(msg)
      _ -> :noop
    end
  end
end
