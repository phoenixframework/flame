defmodule FLAME.LocalBackendAnotherPeer do
  @behaviour FLAME.Backend

  alias FLAME.LocalBackendAnotherPeer
  require Logger

  defstruct host_node_name: nil,
            host_pid: nil,
            remote_terminator_pid: nil,
            parent_ref: nil,
            boot_timeout: nil,
            runner_node_name: nil,
            runner_node_pid: nil,
            log: nil,
            terminator_sup: nil

  # @valid_opts []

  @spec gen_random(integer()) :: bitstring()
  def gen_random(length \\ 10), do: for(_ <- 1..length, into: "", do: <<Enum.random(?a..?z)>>)

  @impl true
  @spec init(keyword()) :: {:ok, any()}
  def init(opts) do
    System.cmd("epmd", ["-daemon"])
    Logger.debug("started epmd")

    with %{started: started?} <- :net_kernel.get_state() do
      case started? do
        :no ->
          Logger.debug("distribution check: no case")
          {:ok, _pid} = :net_kernel.start([String.to_atom("primary_#{gen_random()}"), :longnames])
          Logger.debug("turning the parent into a distributed node")
          IO.inspect(:net_kernel.get_state())

        :dynamic ->
          Logger.debug("the host node is using a dynamic hostname")
      end
    end

    Logger.debug("checked distribution mode")
    conf = Application.get_env(:flame, __MODULE__) || []

    default = %LocalBackendAnotherPeer{
      host_node_name: Node.self(),
      host_pid: self(),
      boot_timeout: 1_000,
      log: Keyword.get(conf, :log, :debug),
      terminator_sup: Keyword.fetch!(opts, :terminator_sup)
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)

    # |> Keyword.validate!(@valid_opts)

    %LocalBackendAnotherPeer{} = state = Map.merge(default, Map.new(provided_opts))
    Logger.debug("about to exit Anotherbackend.init/1")
    {:ok, state}
  end

  @doc """
  This is largely the same as the orignal, but we switch spawn_monitor/3 for Node.spawn_monitor/4 and refer to the state object for information on the remove runner

  make sure that the runner name, pid, and monitor pid are getting added to the state object
  """
  @impl true
  def remote_spawn_monitor(state, term) do
    case term do
      func when is_function(func, 0) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, func)
        {:ok, {pid, ref}}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        {pid, ref} = Node.spawn_monitor(state.runner_node_name, mod, fun, args)
        {:ok, {pid, ref}}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args}. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown do
    System.stop()
  end

  def remote_node_information(caller_id, caller_ref) do
    available_modules = :code.all_loaded() |> Enum.map(fn {x, _y} -> x end)
    resp = %{available_modules: available_modules}
    send(caller_id, {caller_ref, resp})
  end

  @impl true
  def remote_boot(%LocalBackendAnotherPeer{host_pid: _parent_ref} = state) do
    {:ok, remote_node_pid, remote_node_name} = create_peer_with_applications()
    {parent_ref, parent_id} = {make_ref(), self()}

    terminator_supervisor_name = state.terminator_sup

    term_sup_name =
      Module.concat(terminator_supervisor_name, to_string(System.unique_integer([:positive])))

    terminator_options =
      %{
        parent: FLAME.Parent.new(parent_ref, parent_id, __MODULE__, remote_node_name, nil),
        log: :debug,
        name: term_sup_name
      }
      |> Enum.to_list()

    terminator_spec =
      Supervisor.child_spec({FLAME.Terminator, terminator_options},
        restart: :temporary,
        id: term_sup_name
      )

    {:ok, _term_sup_pid} =
      :erpc.call(remote_node_name, DynamicSupervisor, :start_child, [
        terminator_supervisor_name,
        terminator_spec
      ])

    remote_terminator_pid =
      case :erpc.call(remote_node_name, Process, :whereis, [term_sup_name]) do
        terminator_pid when is_pid(terminator_pid) ->
          terminator_pid

        all ->
          Logger.debug("printing the catchall response to Process.whereis(term_sup_name)")
          IO.inspect(all)
      end

    new_state = %LocalBackendAnotherPeer{
      state
      | runner_node_name: remote_node_name,
        runner_node_pid: remote_node_pid,
        remote_terminator_pid: remote_terminator_pid
    }

    Logger.debug("exiting the remote boot")
    {:ok, remote_terminator_pid, new_state}
  end

  def create_peer_with_applications() do
    {:ok, pid, name} = :peer.start_link(%{name: ~s"#{gen_random()}"})

    add_code_paths(name)
    load_apps_and_transfer_configuration(name, %{})
    ensure_apps_started(name)

    {:ok, pid, name}
  end

  def rpc(node, module, function, args) do
    :rpc.block_call(node, module, function, args)
  end

  defp add_code_paths(node) do
    rpc(node, :code, :add_paths, [:code.get_path()])
  end

  defp load_apps_and_transfer_configuration(node, override_configs) do
    Enum.each(Application.loaded_applications(), fn {app_name, _, _} ->
      app_name
      |> Application.get_all_env()
      |> Enum.each(fn {key, primary_config} ->
        rpc(node, Application, :put_env, [app_name, key, primary_config, [persistent: true]])
      end)
    end)

    Enum.each(override_configs, fn {app_name, key, val} ->
      rpc(node, Application, :put_env, [app_name, key, val, [persistent: true]])
    end)
  end

  defp ensure_apps_started(node) do
    loaded_names = Enum.map(Application.loaded_applications(), fn {name, _, _} -> name end)

    rpc(node, Application, :ensure_all_started, [:mix])
    rpc(node, Mix, :env, [Mix.env()])

    Logger.info("on node #{node} starting applications")

    Enum.reduce(loaded_names, MapSet.new(), fn app, loaded ->
      if Enum.member?(loaded, app) do
        loaded
      else
        {:ok, started} = rpc(node, Application, :ensure_all_started, [app])
        MapSet.union(loaded, MapSet.new(started))
      end
    end)
  end
end
