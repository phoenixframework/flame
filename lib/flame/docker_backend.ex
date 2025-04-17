defmodule FLAME.DockerBackend do
  @moduledoc """
  A `FLAME.Backend` that runs app calls in Docker containers on the parent machine.
  Uses Docker HTTP API to create and start containers.

  This backend is useful for development and testing when you want to run your code
  in isolated Docker containers but don't want to use a cloud provider like Fly.io.

  It is NOT recommended (or useful) for production use. Though with some tweaking
  it could be used via a remote Docker engine.

  ## Configuration

  The following backend options are supported:

  * `:image` - The Docker image to use for the containers. Required.
  * `:env` - Environment variables to pass to the container. Defaults to `%{}`.
  * `:boot_timeout` - The boot timeout in milliseconds. Defaults to `30_000`.
  * `:docker_host` - The Docker host to connect to. Defaults to `"http://127.0.0.1:2375"`. Be sure to run `socat TCP-LISTEN:2375,reuseaddr,fork UNIX-CONNECT:/var/run/docker.sock &` to expose the Docker socket to the host via TCP.
  * `:docker_api_version` - The Docker API version to use. Defaults to `"1.41"`.
  * `:log` - Whether to enable logging. Defaults to `false`.

  ## Example Setup

  Expose your Docker engine HTTP API:
  ```bash
  socat TCP-LISTEN:2375,reuseaddr,fork UNIX-CONNECT:/var/run/docker.sock &
  ```

  Create a dev Dockerfile for your application:

  ./Dockerfile.flame.dev
  ```dockerfile
  ARG ELIXIR_VERSION=1.18.2
  ARG OTP_VERSION=27.2.4
  ARG DEBIAN_VERSION=bullseye-20250224-slim

  ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"

  FROM ${BUILDER_IMAGE} AS dev

  # Install development dependencies
  RUN apt-get update -y && apt-get install -y build-essential git inotify-tools \
      && apt-get clean && rm -f /var/lib/apt/lists/*_*

  # Prepare app directory
  WORKDIR /app

  # Install hex + rebar
  RUN mix local.hex --force && \
      mix local.rebar --force

  # Set development environment
  ENV MIX_ENV=dev

  COPY . .

  RUN mix deps.get && mix deps.compile

  # EPMD port for node discovery
  EXPOSE 4369

  CMD ["elixir", "--sname", "flame-dev", "--cookie", "test", "-S", "mix", "phx.server"]
  ```

  Build the image from root directory:
  ```bash
  docker build --target dev -t flame-dev:latest -f Dockerfile.flame.dev .
  ```

  Run the host application with the same cookie as the container:
  ```bash
  iex --sname host --cookie test -S mix phx.server
  ```

  Configure Flame to use Docker backend:
  ```elixir
  config :flame, :backend, FLAME.DockerBackend
  config :flame, FLAME.DockerBackend,
    image: "flame-dev:latest",
    env: %{
      "DOCKER_IP" => "127.0.0.1"
    }
  ```

  Or configure Docker backend per pool:
  ```elixir
  {FLAME.Pool,
    name: MyRunner,
    backend: {FLAME.DockerBackend, image: "flame-dev:latest", env: %{"DOCKER_IP" => "127.0.0.1"}}
  }
  ```
  """

  @behaviour FLAME.Backend

  alias FLAME.DockerBackend
  alias FLAME.Parser.JSON

  require Logger

  @derive {Inspect,
           only: [
             :docker_host,
             :docker_api_version,
             :image,
             :env,
             :boot_timeout,
             :runner_id,
             :local_ip,
             :remote_terminator_pid,
             :runner_container_id,
             :runner_node_base,
             :runner_node_name,
             :log
           ]}
  defstruct docker_host: nil,
            docker_api_version: nil,
            image: nil,
            env: %{},
            boot_timeout: nil,
            runner_id: nil,
            local_ip: nil,
            remote_terminator_pid: nil,
            parent_ref: nil,
            runner_container_id: nil,
            runner_node_base: nil,
            runner_node_name: nil,
            log: nil

  @valid_opts [
    :image,
    :env,
    :boot_timeout,
    :docker_host,
    :docker_api_version,
    :terminator_sup,
    :log
  ]

  @impl true
  def init(opts) do
    conf = Application.get_env(:flame, __MODULE__) || []
    [_node_base, ip] = node() |> to_string() |> String.split("@")

    default = %DockerBackend{
      image: nil,
      env: %{},
      boot_timeout: 30_000,
      docker_host: "http://127.0.0.1:2375",
      docker_api_version: "1.41",
      log: Keyword.get(conf, :log, false)
    }

    provided_opts =
      conf
      |> Keyword.merge(opts)
      |> Keyword.validate!(@valid_opts)

    %DockerBackend{} = state = Map.merge(default, Map.new(provided_opts))

    unless Map.get(state, :image) do
      raise ArgumentError, "missing :image config for #{inspect(__MODULE__)}"
    end

    state = %{state | runner_node_base: "flame-#{rand_id(20)}"}
    parent_ref = make_ref()

    encoded_parent =
      parent_ref
      |> FLAME.Parent.new(self(), __MODULE__, state.runner_node_base, "DOCKER_IP")
      |> FLAME.Parent.encode()

    new_env =
      %{"PHX_SERVER" => "false", "FLAME_PARENT" => encoded_parent}
      |> Map.merge(state.env)
      |> then(fn env ->
        if flags = System.get_env("ERL_AFLAGS") do
          Map.put_new(env, "ERL_AFLAGS", flags)
        else
          env
        end
      end)
      |> then(fn env ->
        if flags = System.get_env("ERL_ZFLAGS") do
          Map.put_new(env, "ERL_ZFLAGS", flags)
        else
          env
        end
      end)

    new_state = %{state | env: new_env, parent_ref: parent_ref, local_ip: ip}

    {:ok, new_state}
  end

  @impl true
  def remote_spawn_monitor(%DockerBackend{} = state, term) do
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

  @impl true
  def remote_boot(%DockerBackend{parent_ref: parent_ref} = state) do
    container_id = create_container!(state)

    if state.log do
      Logger.log(
        state.log,
        "#{inspect(__MODULE__)} #{inspect(node())} container create #{container_id}"
      )
    end

    case start_container!(state, container_id) do
      :ok ->
        new_state = %{state | runner_container_id: container_id}

        remote_terminator_pid =
          receive do
            {^parent_ref, {:remote_up, remote_terminator_pid}} ->
              remote_terminator_pid
          after
            state.boot_timeout ->
              Logger.error("failed to connect to docker container within #{state.boot_timeout}ms")
              stop_container!(state, container_id)
              exit(:timeout)
          end

        new_state = %{
          new_state
          | remote_terminator_pid: remote_terminator_pid,
            runner_node_name: node(remote_terminator_pid)
        }

        {:ok, remote_terminator_pid, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_container!(%DockerBackend{} = state) do
    container_name = state.runner_node_base

    body =
      JSON.encode!(%{
        Image: state.image,
        Env: Enum.map(state.env, fn {k, v} -> "#{k}=#{v}" end),
        Name: container_name,
        ExposedPorts: %{
          "4369/tcp" => %{},
          "5432/tcp" => %{}
        },
        HostConfig: %{
          NetworkMode: "host",
          PortBindings: %{
            "4369/tcp" => [%{
              # Inherits host epmd process into container
              "HostIp" => "127.0.0.1",
              "HostPort" => "4369"
            }],
            "5432/tcp" => [%{
              "HostIp" => "127.0.0.1",
              "HostPort" => "5432"
            }]
          }
        }
      })

    case http_post!("#{state.docker_host}/v#{state.docker_api_version}/containers/create", body,
           headers: [{"Content-Type", "application/json"}]
         ) do
      %{"Id" => id} -> id
      other -> raise "failed to create container: #{inspect(other)}"
    end
  end

  defp start_container!(%DockerBackend{} = state, container_id) do
    case http_post!(
           "#{state.docker_host}/v#{state.docker_api_version}/containers/#{container_id}/start",
           "",
           headers: [{"Content-Type", "application/json"}]
         ) do
      :ok -> :ok
      other -> {:error, other}
    end
  end

  defp stop_container!(%DockerBackend{} = state, container_id) do
    http_post!(
      "#{state.docker_host}/v#{state.docker_api_version}/containers/#{container_id}/stop",
      "",
      headers: [{"Content-Type", "application/json"}]
    )
  end

  defp http_post!(url, body, opts) do
    Keyword.validate!(opts, [:headers])

    headers =
      for {field, val} <- Keyword.fetch!(opts, :headers),
          do: {String.to_charlist(field), val}

    case :httpc.request(
           :post,
           {String.to_charlist(url), headers, ~c"application/json", body},
           [ssl: [verify: :verify_none]],
           []
         ) do
      {:ok, {{_, 204, _}, _, _}} ->
        :ok

      {:ok, {{_, 200, _}, _, response_body}} ->
        response_body
        |> IO.iodata_to_binary()
        |> JSON.decode!()

      {:ok, {{_, 201, _}, _, response_body}} ->
        response_body
        |> IO.iodata_to_binary()
        |> JSON.decode!()

      {:ok, {{_, status, reason}, _, resp_body}} ->
        raise "failed POST #{url} with #{inspect(status)} (#{inspect(reason)}): #{inspect(resp_body)}"

      {:error, reason} ->
        raise "failed POST #{url} with #{inspect(reason)}"
    end
  end

  defp rand_id(len) do
    len
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, len)
  end
end
