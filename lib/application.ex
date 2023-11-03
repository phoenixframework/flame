defmodule Dragonfly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    terminator_defaults = [
      shutdown_timeout: 20_000,
      failsafe_timeout: 20_000
    ]

    terminator_opts =
      Keyword.merge(terminator_defaults, Application.get_env(:dragonfly, :terminator) || [])

    children = [
      {Dragonfly.Terminator, terminator_opts}
    ]

    opts = [strategy: :one_for_one, name: Dragonfly.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
