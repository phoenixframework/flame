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

  @valid_opts []

  @spec gen_random(integer()) :: bitstring()
  def gen_random(length \\ 10), do: for(_ <- 1..length, into: "", do: <<Enum.random(?a..?z)>>)

  @doc """
  We need to both create the initial data structure and
  """
  @impl true
  @spec init(keyword()) :: {:ok, any()}
  def init(opts) do
    # idempotently start epmd
    System.cmd("epmd", ["-daemon"])

    # start distribution mode on caller
    with %{started: started?, name_domain: name_domain} <- :net_kernel.get_state() do
      case started? do
        :no ->
          {:ok, _pid} = :net_kernel.start([String.to_atom("primary_#{gen_random()}"), :longnames])
          Logger.info("turning the parent into a distributed node")

        :dynamic ->
          # ensure tha twe are using longnames
          case name_domain do
            :longnames ->
              Logger.debug("the host node is using the :longnames name domain")

            :shortnames ->
              Logger.debug("the host node is using the :shortnames name domain. raising for now")
              raise "caller node was created using :shortname instead of :longnames"
          end
      end

      # get configuration from config.exs
      conf = Application.get_env(:flame, __MODULE__) || []

      # set defaults
      default = %LocalBackendAnotherPeer{
        host_node_name: Node.self(),
        host_pid: self(),
        boot_timeout: 1_000,
        log: Keyword.get(conf, :log, false),
        terminator_sup: Keyword.fetch!(opts, :terminator_sup)
      }

      provided_opts =
        conf
        |> Keyword.merge(opts)
        |> Keyword.validate!(@valid_opts)

      %LocalBackendAnotherPeer{} = state = Map.merge(default, Map.new(provided_opts))
      {:ok, state}
    end
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

  @impl true
  def remote_boot(%LocalBackendAnotherPeer{host_pid: parent_ref} = state) do
    # start peer
    # return to this and think through how to properly start the node
    # note that the terminator is running on the peer, and that it must be loaded there somehow

    {:ok, remote_node_pid, remote_node_name} = :peer.start_link(%{name: ~s"#{gen_random()}"})

    remote_terminator_pid =
      receive do
        # we see i the Flame.Backend moddoc that this message needs to be send, but where is it sent from
        # A: it is sent by the TERMINATOR
        {^parent_ref, {:remote_up, remote_terminator_pid}} ->
          remote_terminator_pid
      after
        3_000 ->
          Logger.error("failed to connect to fly machine within #{state.boot_timeout}ms")
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
