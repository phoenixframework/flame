defmodule FLAME.Terminator.Caller do
  defstruct from_pid: nil, timer: nil, placed_child_ref: nil, placed_caller_ref: nil
end

defmodule FLAME.Terminator do
  @moduledoc false
  # The terminator is responsible for ensuring RPC deadlines and parent monitoring.

  # All FLAME calls are deadlined with a timeout. The runners will spawn a
  # function on a remote node, check in with the terminator and ask to be deadlined
  # with a timeout, and then perform their work. If the process exists beyond the
  # deadline, it is forcefully killed by the terminator. The termintor also ensures
  # a configured shutdown timeout to give existing RPC calls time to finish when
  # the system is shutting down.

  # The Terminator also handles connecting back to the parent node and monitoring
  # it when the node is started as FLAME child. If the connection is not
  # established with a failsafe time, or connection is lost, the system is shut
  # down by the terminator.
  use GenServer

  require Logger

  alias FLAME.{Terminator, Parent}
  alias FLAME.Terminator.Caller

  defstruct parent: nil,
            parent_monitor_ref: nil,
            child_placement_sup: nil,
            single_use: false,
            calls: %{},
            log: false,
            status: nil,
            failsafe_timer: nil,
            connect_timer: nil,
            connect_attempts: 0,
            idle_shutdown_after: nil,
            idle_shutdown_check: nil,
            idle_shutdown_timer: nil

  def child_spec(opts) do
    %{
      id: {FLAME.Terminator.Supervisor, Keyword.fetch!(opts, :name)},
      start: {FLAME.Terminator.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Starts the Terminator.

  ## Options

    * `:name` – The optional name of the GenServer.

    * `:parent` – The `%FLAME.Parent{}` of the parent runner.
      Defaults to lookup from `FLAME.Parent.get/0`.

    * `:failsafe_timeout` - The time to wait for a connection to the parent node
      before shutting down the system. Defaults to 2 seconds.

    * `:log` - The optional logging level. Defaults `false`.
  """
  def start_link(opts) do
    Keyword.validate!(opts, [:name, :parent, :child_placement_sup, :failsafe_timeout, :log])
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  def deadline_me(terminator, timeout) do
    GenServer.call(terminator, {:deadline, timeout})
  end

  def schedule_idle_shutdown(terminator, idle_shutdown, idle_check, single_use?) do
    GenServer.call(terminator, {:schedule_idle_shutdown, idle_shutdown, idle_check, single_use?})
  end

  def system_shutdown(terminator) when is_pid(terminator) do
    GenServer.call(terminator, :system_shutdown)
  end

  def place_child(terminator, caller, child_spec) when is_pid(caller) do
    GenServer.call(terminator, {:place_child, caller, child_spec})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    failsafe_timeout = Keyword.get(opts, :failsafe_timeout, 20_000)
    log = Keyword.get(opts, :log, false)

    case opts[:parent] || FLAME.Parent.get() do
      nil ->
        if log, do: Logger.log(log, "no parent found, :ignore")
        :ignore

      %FLAME.Parent{} = parent ->
        :global_group.monitor_nodes(true)
        failsafe_timer = Process.send_after(self(), :failsafe_shutdown, failsafe_timeout)

        state = %Terminator{
          status: :connecting,
          child_placement_sup: Keyword.fetch!(opts, :child_placement_sup),
          parent: parent,
          calls: %{},
          log: log,
          failsafe_timer: failsafe_timer
        }

        log(state, "starting with parent #{inspect(parent)}")

        {:ok, state, {:continue, :connect}}
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

  def handle_info({:DOWN, ref, :process, pid, reason}, %Terminator{} = state) do
    if state.parent && state.parent.pid == pid do
      new_state =
        system_stop(state, "parent pid #{inspect(pid)} went away #{inspect(reason)}. Going down")

      {:noreply, new_state}
    else
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
      new_state = system_stop(state, "nodedown #{inspect(who)}")
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:failsafe_shutdown, %Terminator{} = state) do
    new_state = system_stop(state, "failsafe connect timeout")
    {:noreply, new_state}
  end

  def handle_info(:idle_shutdown, %Terminator{parent: parent} = state) do
    if state.idle_shutdown_check.() do
      send(parent.pid, {parent.ref, :remote_shutdown, :idle})
      new_state = system_stop(state, "idle shutdown")
      {:noreply, new_state}
    else
      {:noreply, schedule_idle_shutdown(state)}
    end
  end

  @impl true
  def handle_call({:place_child, caller, spec}, _from, %Terminator{} = state) do
    case DynamicSupervisor.start_child(state.child_placement_sup, spec) do
      {:ok, child_pid} ->
        {child_ref, new_state} = deadline_caller(state, child_pid, :infinity)
        {caller_ref, new_state} = deadline_caller(new_state, caller, :infinity)

        new_state =
          new_state
          |> update_caller(child_ref, fn %Caller{} = child -> %Caller{child | placed_caller_ref: caller_ref} end)
          |> update_caller(caller_ref, fn %Caller{} = caller -> %Caller{caller | placed_child_ref: child_ref} end)

        {:reply, {:ok, child_pid}, new_state}

      :ignore ->
        {:reply, :ignore, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:system_shutdown, _from, %Terminator{} = state) do
    {:reply, :ok,
     system_stop(state, "system shutdown instructed from parent #{inspect(state.parent.pid)}")}
  end

  def handle_call({:deadline, timeout}, {from_pid, _tag}, %Terminator{} = state) do
    {_ref, new_state} = deadline_caller(state, from_pid, timeout)
    {:reply, :ok, new_state}
  end

  def handle_call(
        {:schedule_idle_shutdown, idle_after, idle_check, single_use?},
        _from,
        %Terminator{} = state
      ) do
    new_state = %Terminator{
      state
      | single_use: single_use?,
        idle_shutdown_after: idle_after,
        idle_shutdown_check: idle_check
    }

    {:reply, :ok, schedule_idle_shutdown(new_state)}
  end

  @impl true
  def terminate(_reason, %Terminator{} = state) do
    state = cancel_idle_shutdown(state, :term)

    if map_size(state.calls) == 0 do
      :ok
    else
      # supervisor will force kill us if we take longer than configured shutdown_timeout
      Enum.each(state.calls, fn {ref, %Caller{}} ->
        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        end
      end)
    end
  end

  defp update_caller(%Terminator{} = state, ref, func) when is_reference(ref) and is_function(func, 1) do
    %Terminator{state | calls: Map.update!(state.calls, ref, func)}
  end

  defp deadline_caller(%Terminator{} = state, from_pid, timeout)
       when is_pid(from_pid) and
              (is_integer(timeout) or timeout == :infinity) do
    ref = Process.monitor(from_pid)

    timer =
      case timeout do
        :infinity -> nil
        ms when is_integer(ms) -> Process.send_after(self(), {:timeout, ref}, ms)
      end

    caller = %Caller{from_pid: from_pid, timer: timer}
    new_state = %Terminator{state | calls: Map.put(state.calls, ref, caller)}
    {ref, cancel_idle_shutdown(new_state, {:new_deadline, from_pid})}
  end

  defp drop_caller(%Terminator{} = state, ref) when is_reference(ref) do
    %{^ref => %Caller{} = caller} = state.calls
    if caller.timer, do: Process.cancel_timer(caller.timer)
    state = %Terminator{state | calls: Map.delete(state.calls, ref)}

    # if the caller going down was one that placed a child, and the child is still tracked,
    # terminate the child. there is no need to notify the og caller, as they linked themselves.
    state =
      with placed_child_ref <- caller.placed_child_ref,
           true <- is_reference(placed_child_ref),
           %{^placed_child_ref => %Caller{} = placed_child} <- state.calls do
        if placed_child.timer, do: Process.cancel_timer(placed_child.timer)
        Process.demonitor(placed_child_ref, [:flush])
        DynamicSupervisor.terminate_child(state.child_placement_sup, placed_child.from_pid)
        %Terminator{state | calls: Map.delete(state.calls, placed_child_ref)}
      else
        _ -> state
      end

    # if the caller going down was a placed child, clean up the placed caller ref
    state =
      with placed_caller_ref <- caller.placed_caller_ref,
           true <- is_reference(placed_caller_ref),
           %{^placed_caller_ref => %Caller{} = placed_caller} <- state.calls do
        if placed_caller.timer, do: Process.cancel_timer(placed_caller.timer)
        Process.demonitor(placed_caller_ref, [:flush])
        %Terminator{state | calls: Map.delete(state.calls, placed_caller_ref)}
      else
        _ -> state
      end

    state =
      if state.single_use do
        system_stop(state, "single use completed. Going down")
      else
        state
      end

    if map_size(state.calls) == 0 do
      schedule_idle_shutdown(state)
    else
      state
    end
  end

  defp schedule_idle_shutdown(%Terminator{} = state) do
    state = cancel_idle_shutdown(state, :schedule)

    case state.idle_shutdown_after do
      time when time in [nil, :infinity] ->
        %Terminator{state | idle_shutdown_timer: nil}

      time when is_integer(time) ->
        timer = Process.send_after(self(), :idle_shutdown, time)
        %Terminator{state | idle_shutdown_timer: timer}
    end
  end

  defp cancel_idle_shutdown(%Terminator{} = state, _reason) do
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
      send(parent.pid, {parent.ref, :remote_up, self()})

      %Terminator{
        state
        | status: :connected,
          parent_monitor_ref: ref,
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

  defp system_stop(%Terminator{parent: parent} = state, log) do
    if state.status != :stopping do
      log(state, "#{inspect(__MODULE__)}.system_stop: #{log}")
      parent.backend.system_shutdown()
    end

    %Terminator{state | status: :stopping}
  end

  defp log(%Terminator{log: level}, message) do
    if level do
      Logger.log(level, message)
    end
  end
end
