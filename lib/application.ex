defmodule Dragonfly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    terminator_timeout = Application.get_env(:dragonfly, :terminator_timeout) || 20_000

    children = [
      {Task.Supervisor, name: Dragonfly.TaskSupervisor},
      {Dragonfly.TaskTerminator, timeout: terminator_timeout}
    ]

    opts = [strategy: :one_for_one, name: Dragonfly.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
