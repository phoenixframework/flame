defmodule Dragonfly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: Dragonfly.TaskSupervisor}
    ]

    opts = [strategy: :one_for_one, name: Dragonfly.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
