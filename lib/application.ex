defmodule FLAME.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    opts = Application.get_env(:flame, :terminator, [])
    shutdown = Keyword.get(opts, :shutdown_timeout, 30_000)

    opts = Keyword.put(opts, :name, FLAME.Terminator)

    children = [
      Supervisor.child_spec({FLAME.Terminator, opts}, shutdown: shutdown)
    ]

    opts = [strategy: :one_for_one, name: FLAME.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
