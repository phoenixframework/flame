defmodule FLAME.LocalBackend do
  @moduledoc """
  A `FLAME.Backend` useful for development and testing.
  """

  @behaviour FLAME.Backend

  @impl true
  def init(opts) do
    defaults =
      Application.get_env(:flame, __MODULE__) || []

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
    parent = FLAME.Parent.new(make_ref(), self(), __MODULE__, "nonode", nil)
    name = Module.concat(state.terminator_sup, to_string(System.unique_integer([:positive])))
    opts = [name: name, parent: parent, log: state.log]

    spec = Supervisor.child_spec({FLAME.Terminator, opts}, restart: :temporary)
    {:ok, _sup_pid} = DynamicSupervisor.start_child(state.terminator_sup, spec)

    case Process.whereis(name) do
      terminator_pid when is_pid(terminator_pid) -> {:ok, terminator_pid, state}
    end
  end
end
