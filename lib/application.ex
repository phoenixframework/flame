defmodule FLAME.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    opts = Application.get_env(:flame, :terminator, [])
    shutdown = Keyword.get(opts, :shutdown_timeout, 30_000)

    opts = Keyword.put(opts, :name, FLAME.Terminator)

    children = [
      Supervisor.child_spec({FLAME.Terminator, opts}, shutdown: shutdown)
    ]
    Logger.info("starting FLAME #{inspect(children)}")

    opts = [strategy: :one_for_one, name: FLAME.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
