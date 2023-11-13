defmodule FLAME.Pool.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    dynamic_sup = Module.concat(name, "DynamicSup")
    terminator_sup = Module.concat(name, "TerminatorSup")
    task_sup = Module.concat(name, "TaskSup")

    child_placement_sup =
      Keyword.get(opts, :child_placement_sup, FLAME.ChildPlacementSup)

    pool_opts =
      Keyword.merge(opts,
        task_sup: task_sup,
        dynamic_sup: dynamic_sup,
        terminator_sup: terminator_sup,
        child_placement_sup: child_placement_sup
      )

    children =
      [
        {Task.Supervisor, name: task_sup, strategy: :one_for_one},
        {DynamicSupervisor, name: dynamic_sup, strategy: :one_for_one},
        {DynamicSupervisor, name: terminator_sup, strategy: :one_for_one},
        %{
          id: {FLAME.Pool, Keyword.fetch!(opts, :name)},
          start: {FLAME.Pool, :start_link, [pool_opts]},
          type: :worker
        }
      ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
