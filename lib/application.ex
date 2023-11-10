defmodule FLAME.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    {shutdown_timeout, opts} =
      :flame
      |> Application.get_env(:terminator, [])
      |> Keyword.pop(:shutdown_timeout, 30_000)

    children = [
      {DynamicSupervisor, name: FLAME.ChildPlacementSup, strategy: :one_for_one},
      Supervisor.child_spec({FLAME.Terminator, opts}, shutdown: shutdown_timeout)
    ]

    opts = [strategy: :one_for_one, name: FLAME.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
