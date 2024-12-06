defmodule FLAME.Pool.Cleaner do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  def watch_path(server, path) do
    GenServer.call(server, {:watch, path})
  end

  def list_paths(server) do
    GenServer.call(server, :list)
  end

  def init(_opts) do
    Process.flag(:trap_exit, true)
    {:ok, %{paths: []}}
  end

  def handle_call({:watch, path}, _from, state) do
    {:reply, :ok, %{state | paths: [path | state.paths]}}
  end

  def handle_call(:list, _from, state) do
    {:reply, state.paths, state}
  end

  def terminate(_reason, state) do
    for path <- state.paths, do: File.rm!(path)

    :ok
  end
end
