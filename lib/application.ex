defmodule Dragonfly.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {shutdown_timeout, opts} =
      :dragonfly
      |> Application.get_env(:terminator, [])
      |> Keyword.pop(:shutdown_timeout, 30_000)

    children = [
      Supervisor.child_spec({Dragonfly.Terminator, opts}, shutdown: shutdown_timeout)
    ]

    opts = [strategy: :one_for_one, name: Dragonfly.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
