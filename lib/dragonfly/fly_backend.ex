defmodule Dragonfly.FlyBackend do
  @behaviour Dragonfly.Backend

  alias Dragonfly.FlyBackend

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Dragonfly.FlyBackend.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @derive {Inspect,
           only: [
             :host,
             :size,
             :image,
             :app,
             :runner_id,
             :runner_pid,
             :runner_instance_id,
             :runner_private_ip,
             :runner_node_name
           ]}
  defstruct host: nil,
            env: %{},
            size: nil,
            image: nil,
            app: nil,
            token: nil,
            runner_id: nil,
            runner_pid: nil,
            runner_instance_id: nil,
            runner_private_ip: nil,
            runner_node_name: nil

  @impl true
  def init(opts) do
    :global_group.monitor_nodes(true)
    conf = Enum.into(Application.get_env(:dragonfly, __MODULE__) || [], %{})

    default = %FlyBackend{
      host: "https://api.machines.dev",
      size: "performance-2x"
    }

    state =
      default
      |> Map.merge(conf)
      |> Map.merge(Map.new(opts))

    for key <- [:token, :image, :host, :app] do
      unless Map.has_key?(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    parent = self() |> :erlang.term_to_binary() |> Base.encode64()

    new_env =
      Map.merge(
        %{PHX_SERVER: "false", DRAGONFLY_PARENT: parent},
        state.env
      )

    new_state =
      %FlyBackend{state | env: new_env}

    {:ok, new_state}
  end

  def __rpc_spawn_link__(func) when is_function(func, 0) do
    Task.Supervisor.async(Dragonfly.FlyBackend.TaskSup, func)
  end

  def __rpc_spawn_link__({mod, func, args}) do
    Task.Supervisor.async(Dragonfly.FlyBackend.TaskSup, mod, func, args)
  end

  @impl true
  def remote_spawn_link(%FlyBackend{} = state, term) do
    case term do
      func when is_function(func, 0) ->
        pid = Node.spawn_link(state.runner_node_name, __MODULE__, :__rpc_spawn_link__, func)
        {:ok, pid, state}

      {mod, fun, args} when is_atom(mod) and is_atom(fun) and is_list(args) ->
        pid =
          Node.spawn_link(
            state.runner_node_name,
            __MODULE__,
            :__rpc_spawn_link__,
            {mod, fun, args}
          )

        {:ok, pid, state}

      other ->
        raise ArgumentError,
              "expected a null arity function or {mod, func, args. Got: #{inspect(other)}"
    end
  end

  @impl true
  def system_shutdown do
    System.stop()
  end

  @impl true
  def remote_boot(%FlyBackend{} = state) do
    body =
      Req.post!("#{state.host}/v1/apps/#{state.app}/Runners",
        auth: {:bearer, state.token},
        json: %{
          name: "#{state.app}-async-#{rand_id(20)}",
          config: %{
            image: state.image,
            size: state.size,
            auto_destroy: true,
            env: state.env
          }
        }
      )

    case body do
      %{"id" => id, "instance_id" => instance_id, "private_ip" => ip} ->
        new_state =
          %FlyBackend{
            state
            | runner_id: id,
              runner_instance_id: instance_id,
              runner_private_ip: ip,
              runner_node_name: :"#{state.app}@#{ip}"
          }

        runner_pid =
          receive do
            {:up, runner_pid} -> runner_pid
          end

        {:ok, %{new_state | runner_pid: runner_pid}}

      other ->
        {:error, other}
    end
  end

  @impl true
  def handle_info({:nodedown, down_node}, state) do
    if down_node == state.runner_node_name do
      {:stop, {:shutdown, :noconnection}, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    ^pid = state.runner_pid
    {:stop, {:shutdown, reason}, state}
  end

  defp rand_id(len) do
    len |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false) |> binary_part(0, len)
  end
end
