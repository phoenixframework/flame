defmodule FLAME.LocalPeerBackend do
  @moduledoc """
  A `FLAME.Backend` useful for development and testing.
  """

  @behaviour FLAME.Backend

  defstruct [runner_node_name: nil]


  @valid_opts []

  @impl true
  def init(opts) do
    # I need to instantiate %LocalBackend, reading partly from Application.get_env
    # I also need to handle the terminator
    # NB: `opts` is passed in by the runner
    conf = Application.get_env(:flame, __MODULE__) || []
    default = %LocalBackend{
      runner_node_name: ""
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    %LocalBackend{} = state = Map.merge(default, Map.new(provided_opts))

    defaults =
      Application.get_env(:flame, __MODULE__) || []

    _terminator_sup = Keyword.fetch!(opts, :terminator_sup)

    {:ok,
     defaults
     |> Keyword.merge(opts)
     |> Enum.into(%{})}
  end

  @impl true
  def remote_spawn_monitor(%LocalBackend{} = _state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = spawn_monitor(func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = spawn_monitor(mod, fun, args)
        {:ok, {pid, eref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  # Does this only just down the workers or the entire system?
  # according to FlyBackend, it seems to shut down the entire system -- be careful.
  # System.stop() is copied from FlyBackend
  @impl true
  def system_shutdown() do
    System.stop()
  end

  @impl true
  def remote_boot(%LocalBackend{parent_ref: parent_ref} = state) do
    parent = FLAME.Parent.new(make_ref(), self(), __MODULE__, "peer_", nil)
    name = Module.concat(state.terminator_sup, to_string(System.unique_integer([:positive])))
    opts = [name: name, parent: parent, log: state.log] # extend to include the code paths, using

    spec = Supervisor.child_spec({FLAME.Terminator, opts}, restart: :temporary)
    {:ok, _sup_pid} = DynamicSupervisor.start_child(state.terminator_sup, spec)

    case Process.whereis(name) do
      terminator_pid when is_pid(terminator_pid) -> {:ok, terminator_pid, state}
    end
  end

  def remote_boot_old(state) do
    parent = FLAME.Parent.new(make_ref(), self(), __MODULE__, "nonode", nil)
    name = Module.concat(state.terminator_sup, to_string(System.unique_integer([:positive])))
    opts = [name: name, parent: parent, log: state.log] # extend to include the code paths, using

    spec = Supervisor.child_spec({FLAME.Terminator, opts}, restart: :temporary)
    {:ok, _sup_pid} = DynamicSupervisor.start_child(state.terminator_sup, spec)

    case Process.whereis(name) do
      terminator_pid when is_pid(terminator_pid) -> {:ok, terminator_pid, state}
    end
  end
end
