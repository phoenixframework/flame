defmodule Dragonfly do
  @moduledoc """
  TODO
  """
  require Logger

  alias Dragonfly.Runner

  def remote_boot(opts) do
    {:ok, pid} = Runner.start_link(opts)
    :ok = Runner.remote_boot(pid)
    {:ok, pid}
  end

  @doc """
  Calls a function in a remote runner.

  If no runner is provided, a new one is linked to the caller and
  remotely booted.

  ## Options

    * `:single_use` - if `true`, the runner will be terminated after the call. Defaults `false`.
    * `:backend` - The backend to use. Defaults to `Dragonfly.LocalBackend`.
    * `:log` - The log level to use for verbose logging. Defaults to `false`.
    * `:single_use` -
    * `:timeout` -
    * `:connect_timeout` -
    * `:shutdown_timeout` -
    * `:task_su` -

  ## Examples

    def my_expensive_thing(arg) do
      Dragonfly.call(, fn ->
        # i'm now doing expensive work inside a new node
        # pubsub and repo access all just work
        Phoenix.PubSub.broadcast(MyApp.PubSub, "topic", result)

        # can return awaitable results back to caller
        result
      end)

  When the caller exits, the remote runner will be terminated.
  """
  def call(pool, func, opts) when is_atom(pool) and is_function(func, 0) and is_list(opts) do
    Dragonfly.Pool.call(pool, func, opts)
  end

  def call(func) when is_function(func, 0) do
    call(func, [])
  end

  def call(pool, func) when is_atom(pool) and is_function(func, 0) do
    Dragonfly.Pool.call(pool, func, [])
  end

  def call(func, opts) when is_function(func, 0) and is_list(opts) do
    {:ok, pid} = Runner.start_link(opts)
    :ok = Runner.remote_boot(pid)
    call(pid, func)
  end

  def call(pid, func) when is_pid(pid) and is_function(func, 0) do
    Runner.call(pid, func)
  end
end
