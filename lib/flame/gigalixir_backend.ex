defmodule FLAME.GigalixirBackend do
  @moduledoc """
  The `FLAME.Backend` using [Gigalixir](https://gigalixir.com) machines.

  The only required configuration is telling FLAME to use the
  `FLAME.GigalixirBackend` by default.

  The following backend options are supported:

    * `:size` - The size of the runner. Defaults to the application's size.
      Minimum is `0.2`, which represent 200MiB of memory and 0.2 CPU shares.
      
    * `:boot_timeout` - The boot timeout. Defaults to `60_000` (60 seconds).

    * `:max_runtime` - The maximum runtime of the runner in seconds. Defaults to `300` (5 minutes).

    * `:app` – The name of the Gigalixir app. Defaults to `System.get_env("GIGALIXIR__APP_NAME")`,

    * `:token` – The application's API token. Defaults to `System.get_env("GIGALIXIR__APP_KEY")`.

    * `:host` – The host of the Gigalixir API. Defaults to `"https://api.gigalixir.com"`.
  """
  @behaviour FLAME.Backend

  alias FLAME.{GigalixirBackend, HttpClient}

  require Logger

  @derive {Inspect,
           only: [
             :host,
             :size,
             :app,
             :local_ip,
             :remote_terminator_pid,
             :runner_node_basename,
             :runner_instance_id,
             :runner_private_ip,
             :runner_node_name,
             :boot_timeout,
             :max_runtime
           ]}
  defstruct host: nil,
            local_ip: nil,
            env: %{},
            size: nil,
            app: nil,
            token: nil,
            boot_timeout: nil,
            max_runtime: nil,
            remote_terminator_pid: nil,
            parent_ref: nil,
            runner_node_basename: nil,
            runner_instance_id: nil,
            runner_private_ip: nil,
            runner_node_name: nil,
            log: nil

  @valid_opts [
    :app,
    :token,
    :host,
    :size,
    :boot_timeout,
    :max_runtime,
    :env,
    :terminator_sup,
    :log
  ]

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []
    [node_base, _instance_name] = node() |> to_string() |> String.split("@")
    ip = System.get_env("GIGALIXIR__REPLICA_IP")

    default = %GigalixirBackend{
      app: System.get_env("GIGALIXIR__APP_NAME"),
      token: System.get_env("GIGALIXIR__APP_KEY"),
      host: "https://api.gigalixir.com",
      boot_timeout: 60_000,
      max_runtime: 300,
      runner_node_basename: node_base,
      log: Keyword.get(conf, :log, false)
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    state = Map.merge(default, Map.new(provided_opts))

    for key <- [:token, :host, :app] do
      unless Map.get(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    parent_ref = make_ref()

    encoded_parent =
      parent_ref
      |> FLAME.Parent.new(self(), __MODULE__, "GIGALIXIR__REPLICA_IP")
      |> FLAME.Parent.encode()

    new_env =
      Map.merge(
        %{PHX_SERVER: "false", FLAME_PARENT: encoded_parent},
        state.env
      )

    new_state =
      %GigalixirBackend{state | env: new_env, parent_ref: parent_ref, local_ip: ip}

    {:ok, new_state}
  end

  @impl true
  # TODO explore spawn_request
  def remote_spawn_monitor(%GigalixirBackend{} = state, term) do
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
  def remote_boot(%GigalixirBackend{parent_ref: parent_ref} = state) do
    {resp, req_connect_time} =
      with_elapsed_ms(fn ->
        HttpClient.post!("#{state.host}/api/apps/#{state.app}/flame",
          content_type: "application/json",
          headers: [
            {"Content-Type", "application/json"},
            {"Authorization", basic_auth(state.app, state.token)}
          ],
          connect_timeout: state.boot_timeout,
          body: Jason.encode!(flame_params(state))
        )
      end)

    if state.log,
      do:
        Logger.log(
          state.log,
          "#{inspect(__MODULE__)} #{inspect(node())} FLAME create #{req_connect_time}ms"
        )

    remaining_connect_window = state.boot_timeout - req_connect_time

    case resp do
      %{"instance_id" => instance_id, "private_ip" => ip} ->
        new_state = %GigalixirBackend{
          state
          | runner_instance_id: instance_id,
            runner_private_ip: ip,
            runner_node_name: :"#{state.runner_node_basename}@#{ip}"
        }

        remote_terminator_pid =
          receive do
            {^parent_ref, {:remote_up, remote_terminator_pid}} ->
              remote_terminator_pid
          after
            remaining_connect_window ->
              Logger.error("failed to connect to gigalixir FLAME within #{state.boot_timeout}ms")
              exit(:timeout)
          end

        new_state = %GigalixirBackend{new_state | remote_terminator_pid: remote_terminator_pid}
        {:ok, remote_terminator_pid, new_state}

      other ->
        {:error, other}
    end
  end

  defp flame_params(state) do
    %{
      env: state.env,
      max_runtime: state.max_runtime,
      size: state.size
    }
    |> Map.filter(fn {_k, v} -> v end)
  end

  defp basic_auth(username, password) do
    "Basic #{Base.encode64("#{username}:#{password}")}"
  end
end
