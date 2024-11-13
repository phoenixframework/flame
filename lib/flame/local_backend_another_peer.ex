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

  @doc """
  We need to both create the initial data structure
  """
  @impl true
  @spec init(keyword()) :: {:ok, any()}
  def init(opts) do
    # idempotently start epmd
    System.cmd("epmd", ["-daemon"])
    Logger.debug("started epmd")

    # start distribution mode on caller
    with %{started: started?} <- :net_kernel.get_state() do
      case started? do
        :no ->
          Logger.debug("distribution check: no case")
          {:ok, _pid} = :net_kernel.start([String.to_atom("primary_#{gen_random()}"), :longnames])
          Logger.debug("turning the parent into a distributed node")
          IO.inspect(:net_kernel.get_state())

        :dynamic ->
          # ensure tha twe are using longnames
          Logger.debug("the host node is using a dynamic hostname")
          # case name_domain do
          #   :longnames ->
          #     Logger.debug("the host node is using the :longnames name domain")

          #   :shortnames ->
          #     Logger.debug("the host node is using the :shortnames name domain. raising for now")
          #     raise "caller node was created using :shortname instead of :longnames"
          # end
      end
    end

    Logger.debug("checked distribution mode")

    # get configuration from config.exs
    conf = Application.get_env(:flame, __MODULE__) || []
    IO.inspect(conf)

    # set defaults
    default = %LocalBackendAnotherPeer{
      host_node_name: Node.self(),
      host_pid: self(),
      boot_timeout: 1_000,
      log: Keyword.get(conf, :log, false)
      # terminator_sup: Keyword.fetch!(opts, :terminator_sup)
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

  @doc """
  Since we are starting processes with links, killing the caller kills the children

  remote terminator pid is (apparently) set here
  """
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
  def remote_boot(%LocalBackendAnotherPeer{host_pid: parent_ref} = state) do
    # start peer
    # return to this and think through how to properly start the node
    # note that the terminator is running on the peer, and that it must be loaded there somehow

    Logger.debug("entering remote_boot!!!")
    Logger.debug("creating remote node")
    # {:ok, remote_node_pid, remote_node_name} = :peer.start_link(%{name: ~s"#{gen_random()}"})
    {:ok, remote_node_pid, remote_node_name} = create_peer_with_applications()
    IO.puts("remote_node_name:")
    IO.inspect(remote_node_name)
    IO.puts("remote_node_pid:")
    IO.inspect(remote_node_pid)

    # we ever send th parent_ref or host pid to the child, so it can never send a response back

    # TODO: send a command to remote instance
    # check for installed packages
    Logger.debug("making first call to remote node")
    caller_ref = make_ref()
    caller_id = self()

    Logger.debug("running 'ensure loaded'")

    ensure_loaded_newbackend? =
      case :erpc.call(remote_node_name, :code, :ensure_loaded, [FLAME.LocalBackendAnotherPeer]) do
        {:badrpc, reason} -> throw(reason)
        {:module, _} -> true
        {:error, :nofile} -> false
        resp -> throw(resp)
      end

    IO.puts("Has new backend?")
    IO.inspect(ensure_loaded_newbackend?)

    ensure_loaded_oldbackend? =
      case :erpc.call(remote_node_name, :code, :ensure_loaded, [FLAME.LocalBackend]) do
        {:badrpc, reason} -> throw(reason)
        {:module, _} -> true
        {:error, :nofile} -> false
        resp -> throw(resp)
      end

    IO.puts("Has old backend?")
    IO.inspect(ensure_loaded_oldbackend?)

    ensure_loaded_core_backend? =
      case :erpc.call(remote_node_name, :code, :ensure_loaded, [FLAME.Backend]) do
        {:badrpc, reason} -> throw(reason)
        {:module, _} -> true
        {:error, :nofile} -> false
        resp -> throw(resp)
      end

    IO.puts("Has core backend?")
    IO.inspect(ensure_loaded_core_backend?)

    Node.spawn_link(remote_node_name, __MODULE__, :remote_node_information, [
      caller_id,
      caller_ref
    ])

    # Node.spawn_link(remote_node_name, fn ->
    #   available_modules = :code.all_loaded |> Enum.map(fn {x, _y} -> x end)

    #   IO.puts("can we print from remote node?")

    #   # create terminator pid?
    #   send(caller_id, {caller_ref, %{available_modules: available_modules}})
    # end)
    Logger.debug("finished spawning a link")

    resp =
      receive do
        {^caller_ref, response} -> response
      after
        10_000 ->
          Logger.error("timed out waiting for response from first call to remote node")
          exit(:timeout)
      end

    IO.puts("Getting from remote node")
    IO.inspect(resp)

    # TOMORROW: we are currently hitting the timeout here
    # A day later I'm back here, but now I know the terminator is present.
    # I need to make sure the terminator is running, and likely need to run an RPC command on the remote node myself

    ## TODO: RPC command that deploys the terminator to the remote node
    ## TODO: I got an :ignore message (a bit humorous) telling me that I need to define a parent in the options field

    terminator_opts =
      %{
        parent: FLAME.Parent.new(make_ref(), self(), __MODULE__, remote_node_name, nil),
        child_placement_sup: nil,
        failsafe_timeout: 1_000_000,
        log: true,
        name: remote_node_name
      }
      |> Enum.to_list()

    # try a blocking rpc call instead
    # we could alternative NOT send a message back from the other process and just get the terminator pid from :erpc.call

    terminator_pid =
      :erpc.call(remote_node_name, GenServer, :start_link, [FLAME.Terminator, terminator_opts])

    Logger.debug(
      "we started the Terminator genserver on the remote node and got its PID. Inspecting..."
    )

    IO.inspect(terminator_pid)

    # :erpc.call(remote_node_name, fn ->
    #   {:module, FLAME.Terminator} = Code.ensure_loaded(FLAME.Terminator)
    #   {:ok, terminator_pid} = GenServer.start_link(FLAME.Terminator, terminator_opts)

    #   Logger.debug("we started the terminator genserver")
    #   send(parent_ref, {:remote_up, terminator_pid})
    #   Logger.debug("we sent a message back to the parent")
    # end)

    # boot_timeouttt = 50_000_000
    remote_terminator_pid = terminator_pid

    # remote_terminator_pid =
    #   receive do
    #     # we see i the Flame.Backend moddoc that this message needs to be send, but where is it sent from
    #     # A: it is sent by the TERMINATOR
    #     {^parent_ref, {:remote_up, remote_terminator_pid}} ->
    #       remote_terminator_pid

    #     general ->
    #       IO.inspect(general)
    #   after
    #     boot_timeouttt ->
    #       Logger.error("failed to connect to the peer machine within #{boot_timeouttt}ms")
    #       exit(:timeout)
    #   end

    new_state = %LocalBackendAnotherPeer{
      state
      | runner_node_name: remote_node_name,
        runner_node_pid: remote_node_pid,
        remote_terminator_pid: remote_terminator_pid
    }

    Logger.debug("exiting the remote boot")
    {:ok, remote_terminator_pid, new_state}
  end

  # def start_terminator(node_name, terminator_opts) do
  #   {:module, FLAME.Terminator} = Code.ensure_loaded(FLAME.Terminator)
  #   {:ok, terminator_pid} = GenServer.start_link(FLAME.Terminator, terminator_opts)

  #   Logger.debug("we started the terminator genserver")
  #   send(parent_ref, {:remote_up, terminator_pid})
  #   Logger.debug("we sent a message back to the parent")
  # end

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
    # app_names = @extra_apps ++ (loaded_names -- @extra_apps)

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
