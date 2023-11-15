defmodule FLAME.Terminator.Supervisor do
  use Supervisor

  def start_link(opts) do
    sup_name = opts |> Keyword.fetch!(:name) |> Module.concat("Supervisor")
    Supervisor.start_link(__MODULE__, opts, name: sup_name)
  end

  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    child_placement_sup = Module.concat(name, "ChildPlacementSup")
    terminator_opts = Keyword.merge(opts, child_placement_sup: child_placement_sup)

    children =
      [
        {DynamicSupervisor, name: child_placement_sup, strategy: :one_for_one},
        %{
          id: FLAME.Terminator,
          start: {FLAME.Terminator, :start_link, [terminator_opts]},
          type: :worker,
          shutdown: opts[:shutdown_timeout] || 30_000
        }
      ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
