defmodule Dragonfly.Terminator.Caller do
  defstruct from_pid: nil, timer: nil, single_use?: false
end

defmodule Dragonfly.Terminator do
  @moduledoc false
  # The terminator is responsible for ensuring RPC deadlines and parent monitoring.

  # All Dragonfly calls are deadlined with a timeout. The runners will spawn a
  # function on a remote node, check in with the terminator and ask to be deadlined
  # with a timeout, and then perform their work. If the process exists beyond the
  # deadline, it is forcefully killed by the terminator. The termintor also ensures
  # a configured shutdown timeout to give existing RPC calls time to finish when
  # the system is shutting down.

  # The Terminator also handles connecting back to the parent node and monitoring
  # it when the node is started as Dragonfly child. If the connection is not
  # established with a failsafe time, or connection is lost, the system is shut
  # down by the terminator.
  use GenServer

  require Logger

  alias Dragonfly.{Terminator, Parent}
  alias Dragonfly.Terminator.Caller

  defstruct shutdown_timeout: nil,
            parent: nil,
            parent_monitor_ref: nil,
            backend: nil,
            calls: %{},
            log: false,
            failsafe_timer: nil,
            connect_timer: nil,
            connect_attempts: 0,
            idle_shutdown_after: nil,
            idle_shutdown_check: nil,
            idle_shutdown_timer: nil

  @doc """
  Starts the Terminator.

  ## Options

    * `:name` – The optional name of the GenServer. Defaults to `__MODULE__`.

    * `:backend` – The optional Gragonfly backend module, defaults to configured backend.

    * `:shutdown_timeout` - The time to wait for existing RPC calls to finish
      before shutting down the system. Defaults to 20 seconds.

    * `:failsafe_timeout` - The time to wait for a connection to the parent node
      before shutting down the system. Defaults to 2 seconds.

    * `:log` - The optional logging level. Defaults `false`.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  def deadline_me(terminator, timeout, single_use?) when is_boolean(single_use?) do
    GenServer.call(terminator, {:deadline, timeout, single_use?})
  end

  def schedule_idle_shutdown(terminator, idle_shutdown, idle_check) do
    GenServer.call(terminator, {:schedule_idle_shutdown, idle_shutdown, idle_check})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    timeout = Keyword.fetch!(opts, :shutdown_timeout)
    failsafe_timeout = Keyword.fetch!(opts, :failsafe_timeout)
    log = Keyword.get(opts, :log, false)

    {parent, backend} =
      case Dragonfly.Parent.get() do
        nil -> {nil, opts[:backend] || Dragonfly.Backend.impl()}
        %Dragonfly.Parent{} = parent -> {parent, parent.backend}
      end

    failsafe_timer =
      if parent do
        :global_group.monitor_nodes(true)
        Process.send_after(self(), :failsafe_shutdown, failsafe_timeout)
      end

    state = %Terminator{
      shutdown_timeout: timeout,
      parent: parent,
      backend: backend,
      calls: %{},
      log: log,
      failsafe_timer: failsafe_timer
    }

    if parent do
      {:ok, state, {:continue, :connect}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:connect, %Terminator{} = state) do
    {:noreply, connect(state)}
  end

  @impl true
  def handle_info(:connect, state) do
    if state.parent_monitor_ref do
      {:noreply, state}
    else
      {:noreply, connect(state)}
    end
  end

  def handle_info({:timeout, ref}, state) do
    %{^ref => %Caller{} = caller} = state.calls
    Process.demonitor(ref, [])
    Process.exit(caller.from_pid, :kill)
    {:noreply, drop_caller(state, ref)}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, %Terminator{} = state) do
    case state.parent do
      %Parent{pid: ^pid} ->
        system_stop(state, "parent pid #{inspect(pid)} went away. Going down")
        {:stop, {:shutdown, :noconnection}, state}

      nil ->
        {:noreply, drop_caller(state, ref)}
    end
  end

  def handle_info({:nodeup, who}, %Terminator{parent: parent} = state) do
    if !state.parent_monitor_ref && who === node(parent.pid) do
      {:noreply, connect(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, who}, %Terminator{parent: parent} = state) do
    if who === node(parent.pid) do
      system_stop(state, "nodedown #{inspect(who)}")
      {:stop, {:shutdown, :noconnection}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:failsafe_shutdown, %Terminator{} = state) do
    system_stop(state, "failsafe connect timeout")
    {:stop, {:shutdown, :noconnection}, state}
  end

  def handle_info(:idle_shutdown, state) do
    if state.idle_shutdown_check.() do
      system_stop(state, "idle shutdown")
      {:noreply, state}
    else
      {:noreply, schedule_idle_shutdown(state)}
    end
  end

  @impl true
  def handle_call({:deadline, timeout, single_use?}, {from_pid, _tag}, %Terminator{} = state) do
    {:reply, :ok, deadline_caller(state, from_pid, timeout, single_use?)}
  end

  def handle_call({:schedule_idle_shutdown, idle_after, idle_check}, _from, %Terminator{} = state) do
    new_state = %Terminator{
      state
      | idle_shutdown_after: idle_after,
        idle_shutdown_check: idle_check
    }

    {:reply, :ok, schedule_idle_shutdown(new_state)}
  end

  @impl true
  def terminate(_reason, %Terminator{} = state) do
    state = cancel_idle_shutdown(state)

    case map_size(state.calls) do
      0 ->
        :ok

      count ->
        Process.send_after(self(), :shutdown_timeout, state.shutdown_timeout)
        receive_downs(count)
    end
  end

  defp receive_downs(0), do: :ok

  defp receive_downs(remaining) do
    receive do
      {:DOWN, _, :process, _pid, _reason} -> receive_downs(remaining - 1)
      :shutdown_timeout -> :ok
    end
  end

  defp deadline_caller(%Terminator{} = state, from_pid, timeout, single_use?)
       when is_pid(from_pid) and
              (is_integer(timeout) or timeout == :infinity) and
              is_boolean(single_use?) do
    ref = Process.monitor(from_pid)
    timer = Process.send_after(self(), {:timeout, ref}, timeout)
    caller = %Caller{from_pid: from_pid, timer: timer, single_use?: single_use?}
    new_state = %Terminator{state | calls: Map.put(state.calls, ref, caller)}
    cancel_idle_shutdown(new_state)
  end

  defp drop_caller(%Terminator{} = state, ref) when is_reference(ref) do
    %{^ref => %Caller{} = caller} = state.calls
    new_state = %Terminator{state | calls: Map.delete(state.calls, ref)}

    if caller.single_use?, do: state.backend.system_shutdown()

    if map_size(new_state.calls) == 0 do
      schedule_idle_shutdown(new_state)
    else
      new_state
    end
  end

  defp schedule_idle_shutdown(%Terminator{} = state) do
    state = cancel_idle_shutdown(state)

    case state.idle_shutdown_after do
      time when time in [nil, :infinity] ->
        %Terminator{state | idle_shutdown_timer: nil}

      time when is_integer(time) ->
        timer = Process.send_after(self(), :idle_shutdown, time)
        %Terminator{state | idle_shutdown_timer: timer}
    end
  end

  defp cancel_idle_shutdown(%Terminator{} = state) do
    if state.idle_shutdown_timer, do: Process.cancel_timer(state.idle_shutdown_timer)
    %Terminator{state | idle_shutdown_timer: nil}
  end

  defp connect(%Terminator{parent: %Parent{} = parent} = state) do
    new_attempts = state.connect_attempts + 1
    state.connect_timer && Process.cancel_timer(state.connect_timer)
    connected? = Node.connect(node(parent.pid))

    log(state, "connect (#{new_attempts}) #{inspect(node(parent.pid))}: #{inspect(connected?)}")

    if connected? do
      state.failsafe_timer && Process.cancel_timer(state.failsafe_timer)
      ref = Process.monitor(parent.pid)
      send(parent.pid, {parent.ref, :up, self()})

      %Terminator{
        state
        | parent_monitor_ref: ref,
          failsafe_timer: nil,
          connect_timer: nil,
          connect_attempts: new_attempts
      }
    else
      %Terminator{
        state
        | connect_timer: Process.send_after(self(), :connect, 100),
          connect_attempts: new_attempts
      }
    end
  end

  defp system_stop(%Terminator{} = state, reason) do
    log(state, "#{inspect(__MODULE__)}.system_stop: #{inspect(reason)}")
    state.backend.system_shutdown()
  end

  defp log(%Terminator{log: level}, message) do
    if level do
      Logger.log(level, message)
    end
  end
end
