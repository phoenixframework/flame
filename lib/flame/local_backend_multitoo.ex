defmodule FLAME.LocalBackendMulti do
  @moduledoc """
  A `FLAME.Backend` that spawns each worker in a new BEAM OS process.
  """

  @behaviour FLAME.Backend

  require Logger

  @impl true
  def init(opts) do
    defaults = Application.get_env(:flame, __MODULE__, [])
    terminator_sup = Keyword.fetch!(opts, :terminator_sup)

    state =
      defaults
      |> Keyword.merge(opts)
      |> Enum.into(%{})
      |> Map.put(:terminator_sup, terminator_sup)

    {:ok, state}
  end

  @impl true
  def remote_boot(state) do
    # Generate a unique node name
    unique_id = System.unique_integer([:positive])
    node_name = :"flame_worker_#{unique_id}@127.0.0.1"

    # Create a reference for identification
    ref = make_ref()

    # Encode parent information for the child
    parent = FLAME.Parent.new(ref, self(), __MODULE__, node(), nil)
    parent_encoded = FLAME.Parent.encode(parent)

    # Prepare command-line arguments
    erl_flags = [
      "--name", Atom.to_string(node_name),
      "--cookie", Atom.to_string(Node.get_cookie()),
      "-e", start_terminator_eval(parent_encoded)
    ]

    # Start the new BEAM instance
    {:ok, port} = start_new_beam_instance(erl_flags)

    # Monitor the port to handle its exit
    port_monitor_ref = Port.monitor(port)

    # Wait for the remote terminator to connect back
    result =
      receive do
        {^ref, {:remote_up, remote_terminator_pid}} ->
          remote_node = node(remote_terminator_pid)

          # Create worker-specific state
          worker_state = %{
            remote_node: remote_node,
            port: port,
            port_monitor_ref: port_monitor_ref
          }

          {:ok, remote_terminator_pid, worker_state}
      after
        5_000 ->
          # Timeout handling
          Port.close(port)
          {:error, :timeout}
      end

    result
  end

  @impl true
  def remote_spawn_monitor(worker_state, term) do
    remote_node = worker_state.remote_node

    case term do
      func when is_function(func, 0) ->
        spawn_remote_monitor(remote_node, func)

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        spawn_remote_monitor(remote_node, {mod, fun, args})

      other ->
        raise ArgumentError,
              "Expected a zero-arity function or {mod, func, args}, got: #{inspect(other)}"
    end
  end

  defp spawn_remote_monitor(remote_node, func) when is_function(func, 0) do
    {:ok, pid, monitor_ref} = Node.spawn_monitor(remote_node, func)
    {:ok, {pid, monitor_ref}}
  end

  defp spawn_remote_monitor(remote_node, {mod, fun, args}) do
    {:ok, pid, monitor_ref} = Node.spawn_monitor(remote_node, mod, fun, args)
    {:ok, {pid, monitor_ref}}
  end

  @impl true
  def system_shutdown(worker_state) do
    remote_node = worker_state.remote_node
    port = worker_state.port
    port_monitor_ref = worker_state.port_monitor_ref

    # Attempt to shut down the remote node
    Logger.info("Shutting down remote node: #{remote_node}")

    shutdown_result =
      case :rpc.call(remote_node, :init, :stop, [], 5_000) do
        :ok ->
          Logger.info("Successfully shut down node #{remote_node}")
          :ok

        {:badrpc, reason} ->
          Logger.error("Failed to shut down node #{remote_node}: #{inspect(reason)}")
          {:error, reason}
      end

    # Close the port
    Logger.info("Closing port: #{inspect(port)}")
    Port.close(port)

    # Demonitor the port
    Port.demonitor(port_monitor_ref, [:flush])

    shutdown_result
  end

  # Helper function to start a new BEAM instance
  defp start_new_beam_instance(erl_flags) do
    port = Port.open({:spawn_executable, elixir_executable()}, [
      :binary,
      {:args, elixir_flags() ++ erl_flags},
      :use_stdio,
      :stderr_to_stdout,
      :exit_status
    ])

    {:ok, port}
  end

  # Helper function to generate the '-e' command
  defp start_terminator_eval(parent_encoded) do
    ~s(FLAME.Terminator.start_link(parent: FLAME.Parent.decode("#{parent_encoded}")))
  end

  defp elixir_executable() do
    System.find_executable("elixir") || raise "Elixir executable not found in PATH"
  end

  defp elixir_flags(), do: ["--no-halt"]
end
