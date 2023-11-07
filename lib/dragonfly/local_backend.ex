defmodule Dragonfly.LocalBackend do
  @moduledoc false
  @behaviour Dragonfly.Backend

  @impl true
  def init(opts) do
    defaults =
      Application.get_env(:dragonfly, __MODULE__) || []

    _terminator_sup = Keyword.fetch!(opts, :terminator_sup)

    {:ok,
     defaults
     |> Keyword.merge(opts)
     |> Enum.into(%{})}
  end

  @impl true
  def remote_spawn_monitor(_state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = spawn_monitor(func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = spawn_monitor(mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown, do: :noop

  @impl true
  def remote_boot(state) do
    parent = Dragonfly.Parent.new(make_ref(), self(), __MODULE__)
    opts = [parent: parent, log: state.log]

    spec = %{
      id: Dragonfly.Terminator,
      start: {Dragonfly.Terminator, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }

    {:ok, terminator_pid} = DynamicSupervisor.start_child(state.terminator_sup, spec)

    {:ok, terminator_pid, state}
  end
end
