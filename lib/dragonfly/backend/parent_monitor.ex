defmodule Dragonfly.Backend.ParentMonitor do
  @moduledoc """
  TODO

  To be used across dist erl based backends
  """
  use GenServer
  require Logger

  @failsafe_timeout :timer.seconds(20)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  TODO
  {ref, pid}
  """
  def remote_parent do
    case System.fetch_env("DRAGONFLY_PARENT") do
      {:ok, encoded} -> encoded |> Base.decode64!() |> :erlang.binary_to_term()
      :error -> nil
    end
  end

  @impl true
  def init(opts) do
    :global_group.monitor_nodes(true)
    {parent_ref, parent_pid} = Keyword.fetch!(opts, :parent)
    failsafe_timeout = Keyword.get(opts, :failsafe_timeout, @failsafe_timeout)
    failsafe_timer = Process.send_after(self(), :failsafe_stop, failsafe_timeout)

    {:ok,
     %{
       parent_pid: parent_pid,
       parent_ref: parent_ref,
       parent_monitor_ref: nil,
       connect_timer: nil,
       connect_attempts: 0,
       failsafe_timer: failsafe_timer
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, connect(state)}
  end

  def connect(state) do
    new_attempts = state.connect_attempts + 1
    state.connect_timer && Process.cancel_timer(state.connect_timer)
    connected? = Node.connect(node(state.parent_pid))

    Logger.info(
      "connect (#{new_attempts}) #{inspect(node(state.parent_pid))}: #{inspect(connected?)}"
    )

    if connected? do
      state.failsafe_timer && Process.cancel_timer(state.failsafe_timer)
      ref = Process.monitor(state.parent_pid)
      send(state.parent_pid, {state.parent_ref, :up, self()})

      %{
        state
        | parent_monitor_ref: ref,
          failsafe_timer: nil,
          connect_timer: nil,
          connect_attempts: new_attempts
      }
    else
      %{
        state
        | connect_timer: Process.send_after(self(), :connect, 100),
          connect_attempts: new_attempts
      }
    end
  end

  @impl true
  def handle_info(:connect, state) do
    if state.parent_monitor_ref do
      {:noreply, state}
    else
      {:noreply, connect(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, parent_pid, _reason}, state) do
    system_stop("parent pid #{inspect(parent_pid)} went away. Going down")
    {:stop, {:shutdown, :noconnection}, state}
  end

  def handle_info({:nodeup, who}, state) do
    if !state.parent_monitor_ref && who === node(state.parent_pid) do
      {:noreply, connect(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, who}, state) do
    if who === node(state.parent_pid) do
      system_stop("nodedown #{inspect(who)}")
      {:stop, {:shutdown, :noconnection}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:failsafe_timeout, state) do
    system_stop("failsafe timeout")
    {:stop, {:shutdown, :noconnection}, state}
  end

  defp system_stop(reason) do
    Logger.info("#{inspect(__MODULE__)}.system_stop: #{inspect(reason)}")
    System.stop()
  end
end
