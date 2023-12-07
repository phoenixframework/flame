defmodule FLAME.FlyBackend do
  @moduledoc """
  The `FLAME.Backend` using [Fly.io](https://fly.io) machines.

  The only required configuration is telling FLAME to use the
  `FLAME.FlyBackend` by default and the `:token` which is your Fly.io API
  token. These can be set via application configuration in your `config/runtime.exs`
  withing a `:prod` block:

      if config_env() == :prod do
        config :flame, :backend, FLAME.FlyBackend
        config :flame, FLAME.FlyBackend, token: System.fetch_env!("FLY_API_TOKEN")
        ...
      end

  To set your `FLY_API_TOKEN` secret, you can run the following commands locally:

  ```bash
  $ fly secrets set FLY_API_TOKEN="$(fly auth token)"
  ```
  """
  @behaviour FLAME.Backend

  alias FLAME.FlyBackend

  require Logger

  @derive {Inspect,
           only: [
             :host,
             :size,
             :image,
             :app,
             :runner_id,
             :local_ip,
             :remote_terminator_pid,
             :runner_node_basename,
             :runner_instance_id,
             :runner_private_ip,
             :runner_node_name,
             :boot_timeout
           ]}
  defstruct host: nil,
            local_ip: nil,
            env: %{},
            size: nil,
            image: nil,
            app: nil,
            token: nil,
            boot_timeout: nil,
            runner_id: nil,
            remote_terminator_pid: nil,
            parent_ref: nil,
            runner_node_basename: nil,
            runner_instance_id: nil,
            runner_private_ip: nil,
            runner_node_name: nil

  @impl true
  def init(opts) do
    :global_group.monitor_nodes(true)
    conf = Enum.into(Application.get_env(:flame, __MODULE__) || [], %{})
    [node_base | ip] = node() |> to_string() |> String.split("@")

    default = %FlyBackend{
      app: System.get_env("FLY_APP_NAME"),
      image: System.get_env("FLY_IMAGE_REF"),
      token: System.get_env("FLY_API_TOKEN"),
      host: "https://api.machines.dev",
      size: "performance-2x",
      boot_timeout: 30_000,
      runner_node_basename: node_base
    }

    state =
      default
      |> Map.merge(conf)
      |> Map.merge(Map.new(opts))

    for key <- [:token, :image, :host, :app] do
      unless Map.get(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    parent_ref = make_ref()

    encoded_parent =
      parent_ref
      |> FLAME.Parent.new(self(), __MODULE__)
      |> FLAME.Parent.encode()

    new_env =
      Map.merge(
        %{PHX_SERVER: "false", DRAGONFLY_PARENT: encoded_parent},
        state.env
      )

    new_state =
      %FlyBackend{state | env: new_env, parent_ref: parent_ref, local_ip: ip}

    {:ok, new_state}
  end

  @impl true
  # TODO explore spawn_request
  def remote_spawn_monitor(%FlyBackend{} = state, term) do
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

  def with_elapsed_ms(func) when is_function(func, 0) do
    {micro, result} = :timer.tc(func)
    {result, div(micro, 1000)}
  end

  @impl true
  def remote_boot(%FlyBackend{parent_ref: parent_ref} = state) do
    {req, req_connect_time} =
      with_elapsed_ms(fn ->
        Req.post!("#{state.host}/v1/apps/#{state.app}/machines",
          connect_options: [timeout: state.boot_timeout],
          retry: false,
          auth: {:bearer, state.token},
          headers: %{"flame-parent-ip" => "#{state.local_ip}"},
          json: %{
            name: "#{state.app}-flame-#{rand_id(20)}",
            config: %{
              image: state.image,
              size: state.size,
              auto_destroy: true,
              restart: %{policy: "no"},
              env: state.env
            }
          }
        )
      end)

    remaining_connect_window = state.boot_timeout - req_connect_time

    case req.body do
      %{"id" => id, "instance_id" => instance_id, "private_ip" => ip} ->
        new_state =
          %FlyBackend{
            state
            | runner_id: id,
              runner_instance_id: instance_id,
              runner_private_ip: ip,
              runner_node_name: :"#{state.runner_node_basename}@#{ip}"
          }

        remote_terminator_pid =
          receive do
            {^parent_ref, {:remote_up, remote_terminator_pid}} ->
              remote_terminator_pid
          after
            remaining_connect_window ->
              Logger.error("failed to connect to fly machine within #{state.boot_timeout}ms")
              exit(:timeout)
          end

        new_state = %FlyBackend{new_state | remote_terminator_pid: remote_terminator_pid}
        {:ok, remote_terminator_pid, new_state}

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

  def handle_info({:nodeup, _}, state), do: {:noreply, state}

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp rand_id(len) do
    len |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false) |> binary_part(0, len)
  end
end
