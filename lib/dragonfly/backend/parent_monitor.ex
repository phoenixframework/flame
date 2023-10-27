defmodule Dragonfly.Backend.ParentMonitor do
  @moduledoc """
  TODO

  To be used across dist erl based backends
  """
  use GenServer
  require Logger

  @failsafe_timeout :timer.seconds(20)

  @doc """
  TODO
  """
  def remote_parent_pid do
    case System.fetch_env("DRAGONFLY_PARENT") do
      {:ok, encoded} -> encoded |> Base.decode64!() |> :erlang.binary_to_term()
      :error -> nil
    end
  end

  @impl true
  def init(opts) do
    :global_group.monitor_nodes(true)
    parent_pid = Keyword.fetch!(opts, :parent_pid)

    if Node.connect(node(parent_pid)) do
      Process.monitor(parent_pid)
      failsafe_timeout = Keyword.get(opts, :failsafe_timeout, @failsafe_timeout)

      failsafe_timer =
        if node(parent_pid) not in Node.list() do
          Process.send_after(self(), :failsafe_stop, failsafe_timeout)
        end

      send(parent_pid, {:up, self()})
      {:ok, %{parent_pid: parent_pid, failsafe_timer: failsafe_timer}}
    else
      Logger.error("failed to connect to parent node #{inspect(node(parent_pid))}}")
      System.stop()
      {:stop, :noconnection}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _parent_pid, _reason}, state) do
    {:stop, {:shutdown, :noconnection}, state}
  end

  def handle_info({:nodeup, who}, state) do
    if who === node(state.parent_pid) do
      state.failafe_timer && Process.cancel_timer(state.failsafe_timer)
      {:noreply, %{state | failsafe_timer: nil}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:nodedown, who}, state) do
    if who === node(state.parent_pid) do
      System.stop()
      {:stop, {:shutdown, :noconnection}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(:failsafe_timeout, state) do
    System.stop()
    {:stop, {:shutdown, :noconnection}, state}
  end
end
