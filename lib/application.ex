defmodule Dragonfly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    terminator_opts = Application.get_env(:dragonfly, :terminator) || []

    children = [
      # {Dragonfly.Terminator, terminator_opts}
    ]

    opts = [strategy: :one_for_one, name: Dragonfly.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
