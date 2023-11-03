defmodule Dragonfly.Pool.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    dynamic_sup = Module.concat(name, "DynamicSup")
    pool_opts = Keyword.merge(opts, dynamic_sup: dynamic_sup)

    children =
      [
        {DynamicSupervisor, name: dynamic_sup, strategy: :one_for_one},
        %{
          id: {Dragonfly.Pool, Keyword.fetch!(opts, :name)},
          start: {Dragonfly.Pool, :start_link, [pool_opts]},
          type: :worker
        }
      ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
