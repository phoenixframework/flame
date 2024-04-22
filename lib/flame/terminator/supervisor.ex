defmodule FLAME.Terminator.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    sup_name = opts |> Keyword.fetch!(:name) |> Module.concat("Supervisor")
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  def child_placement_sup_name(terminator_pid) when is_pid(terminator_pid) do
    {:registered_name, name} = Process.info(terminator_pid, :registered_name)
    child_placement_sup_name(name)
  end

  def child_placement_sup_name(terminator_name) when is_atom(terminator_name) do
    Module.concat(terminator_name, "ChildPlacementSup")
  end

  def init(opts) do
    {shutdown_timeout, opts} = Keyword.pop(opts, :shutdown_timeout, 30_000)
    name = Keyword.fetch!(opts, :name)
    child_placement_sup = child_placement_sup_name(name)
    terminator_opts = Keyword.merge(opts, child_placement_sup: child_placement_sup)

    children =
      [
        {DynamicSupervisor, name: child_placement_sup, strategy: :one_for_one},
        %{
          id: FLAME.Terminator,
          start: {FLAME.Terminator, :start_link, [terminator_opts]},
          type: :worker,
          shutdown: shutdown_timeout
        }
      ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 0)
  end
end
