defmodule Dragonfly.FlyBackend.Supervisor do
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    parent = Dragonfly.Backend.ParentMonitor.remote_parent()

    children =
      [
        {Task.Supervisor, name: Dragonfly.FlyBackend.TaskSup},
        parent &&
          {Dragonfly.Backend.ParentMonitor, parent: parent}
      ]
      |> Enum.filter(& &1)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
