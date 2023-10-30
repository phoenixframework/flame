defmodule Dragonfly.TaskTerminator do
  @moduledoc false
  use GenServer

  alias Dragonfly.TaskTerminator

  defstruct timeout: nil

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    timeout = Keyword.fetch!(opts, :timeout)
    {:ok, %TaskTerminator{timeout: timeout}}
  end

  @impl true
  def handle_info(_, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, timeout) do
    case Supervisor.which_children(Dragonfly.TaskSupervisor) do
      [] ->
        :ok

      [_ | _] = children ->
        for {_, child, _, _} <- children, is_pid(child), do: Process.monitor(child)
        Process.send_after(self(), :timeout, timeout)
        receive_downs(length(children))
    end
  end

  defp receive_downs(0), do: :ok

  defp receive_downs(remaining) do
    receive do
      {:DOWN, _, :process, _pid, _reason} -> receive_downs(remaining - 1)
      :timeout -> :ok
    end
  end
end
