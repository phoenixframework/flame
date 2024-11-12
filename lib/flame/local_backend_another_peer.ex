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
    {:ok, remote_node_pid, remote_node_name} = :peer.start_link(%{name: ~s"#{gen_random()}"})
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
    remote_terminator_pid =
      receive do
        # we see i the Flame.Backend moddoc that this message needs to be send, but where is it sent from
        # A: it is sent by the TERMINATOR
        {^parent_ref, {:remote_up, remote_terminator_pid}} ->
          remote_terminator_pid

        general ->
          IO.inspect(general)
      after
        50_000 ->
          Logger.error("failed to connect to the peer machine within #{state.boot_timeout}ms")
          exit(:timeout)
      end

    new_state = %LocalBackendAnotherPeer{
      state
      | runner_node_name: remote_node_name,
        runner_node_pid: remote_node_pid,
        remote_terminator_pid: remote_terminator_pid
    }

    {:ok, remote_terminator_pid, new_state}
  end
end
