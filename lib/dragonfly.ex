defmodule Dragonfly do
  @moduledoc ~S"""
  Dragonfly remotely executes your application code on ephemeral nodes.

  Dragonfly allows you to scale your application operations on a granular
  level **without rewriting your code**. For example, imagine the following function
  in your application that transcodes a video, saves the result to video storage,
  and updates the database:

      def resize_video_quality(%Video{} = vid) do
        path = "#{vid.id}_720p.mp4"
        System.cmd("ffmpeg", ~w(-i #{vid.url} -s 720x480 -c:a copy #{path}))
        VideoStore.put_file!("videos/#{path}", path)
        {1, _} = Repo.update_all(from v in Video, where v.id == ^vid.id, set: [file_720p: path])
        {:ok, path}
      end

  This works great locally and in production under no load, but video transcoding
  is necessarily an expensive CPU bound operation. In production, only a
  few concurrent users can saturate your CPU and cause your entire application,
  web requests, etc, to come to crawl. This is where folks typically reach for
  FaaS or external service solutions, but Dragonfly gives you a better way.

  Simply wrap your your existing code in a Dragonfly function and it will be executed
  on a newly spawned, ephemeral node. Using Elixir and Erlang's built in distribution
  features, entire function closures, including any state they close over, can be sent
  and executed on a remote node:

      def resize_video_quality(%Video{} = video) do
        Dragonfly.call(fn ->
          path = "#{vid.id}_720p.mp4"
          System.cmd("ffmpeg", ~w(-i #{vid.url} -s 720x480 -c:a copy #{path}))
          VideoStore.put_file!("videos/#{path}", path)
          {1, _} = Repo.update_all(from v in Video, where v.id == ^vid.id, set: [file_720p: path])
          {:ok, path}
        end)
      end

  That's it! The `%Video{}` struct in this example is captured inside the function
  and everything executes on the remotely spawned node, returning the result back to the
  parent node when it completes. Repo calls Just Work because the new node booted
  your entire application, including the database Repo. As soon as the function is done
  executing, the ephemeral node is terminated. This means you can elastically scale
  your app as load increases, and only pay for the resources you need at the time.

  ## Backends

  The `Dragonfly.Backend` behavior defines an interface for spawning remote
  application nodes and sending functions to them. By default, the
  `Dragonfly.LocalBackend` is used, which is great for development and test
  environments, as you can have your code simply execute locally in most cases
  and worry about scaling the operation only in production.

  For production, Dragonfly provides the `Dragonfly.FlyBackend`, which uses
  (Fly.io)[https://fly.io]. Because Fly deploys a containerized machine of
  your application, a single Fly API call can boot a machine running your
  exact Docker deployment image, allowing closures to be executed across
  distributed nodes.

  Default backends can be configured in your `config/runtime.exs`:

      if config_env() == :prod do
        config :dragonfly, :backend, Dragonfly.FlyBackend
        config :dragonfly, Dragonfly.FlyBackend, token: System.fetch_env!("FLY_API_TOKEN")
        ...
      end

  And then started in your supervision tree:

      children = [
        ...,
        Dragonfly.FlyBackend,
      ]

  ## Runners

  In practice, users will utilize the `Dragonfly.call/3` and `Dragonfly.cast/3` functions
  to accomplish most of their work. These functions are backed by a `Dragonfly.Runner`,
  a lower-level primitive for executing functions on remote nodes.

  A `Dragonfly.Runner` is responsible for booting a new node, and executing concurrent
  functions on it. For example:

      {:ok, runner} = Runner.start_link(backend: Dragonfly.FlyBackend)
      :ok = Runner.remote_boot(runner)
      Runner.call(runner, fn -> :operation1 end)
      Runner.cast(runner, fn -> :operation2 end)
      Runner.shutdown(runner)

  When a caller exits or crashes, the remote node will automatically be terminated.
  For distributed erlang backends, like `Dragonfly.FlyBackend`, this will be
  accomplished by the backend making use of  `Dragonfly.Backend.ParentMonitor`,
  but other methods are possible.

  ## Pools

  Most workflows don't necessary need an entire node dedicated to a single function
  execution. Dragonfly.Pool` provides a higher-level abstraction that manages a
  pool of runners. It provides elastic runner scaling, allowing a minimum and
  maximum number of runners to be configured, and idle'd down as load decreases.

  Pools give you elastic scale that maximizes the newly spawned hardware.
  At the same time, you also want to avoid spawning unbound resources. You also
  want to keep spawned nodes alive for a period of time to avoid the overhead
  of booting new ones before idleing them down. The following pool configuration
  takes care of all of this for you:

      children = [
        ...,
        Dragonfly.FlyBackend,
        {Dragonfly.Pool,
         name: App.FFMpegRunner,
         min: 0,
         max: 10,
         max_concurrency: 5,
         idle_shutdown_after: 60_000,
      ]

  Here we add a `Dragonfly.Pool` to our application supervision tree, configuring
  a minimum of 0 and maximum of 10 runners. This acheives "scale to zero" behavior
  while also allowing the pool to scale up to 10 runners when load increases.
  Each runner in the case will be able to execute up to 5 concurrent functions.
  The runners will shutdown atter 60s of inactivity.

  Calling a pool is as simple as passing its name to the Dragonfly functions:

      Dragonfly.call(App.FFMpegRunner, fn -> :operation1 end)
  """
  require Logger

  alias Dragonfly.Runner

  def remote_boot(opts) do
    {:ok, pid} = Runner.start_link(opts)
    :ok = Runner.remote_boot(pid)
    {:ok, pid}
  end

  @doc """
  Calls a function in a remote runner.

  If no runner is provided, a new one is linked to the caller and
  remotely booted.

  ## Options

    * `:single_use` - if `true`, the runner will be terminated after the call. Defaults `false`.
    * `:backend` - The backend to use. Defaults to `Dragonfly.LocalBackend`.
    * `:log` - The log level to use for verbose logging. Defaults to `false`.
    * `:single_use` -
    * `:timeout` -
    * `:connect_timeout` -
    * `:shutdown_timeout` -
    * `:task_su` -

  ## Examples

    def my_expensive_thing(arg) do
      Dragonfly.call(, fn ->
        # i'm now doing expensive work inside a new node
        # pubsub and repo access all just work
        Phoenix.PubSub.broadcast(MyApp.PubSub, "topic", result)

        # can return awaitable results back to caller
        result
      end)

  When the caller exits, the remote runner will be terminated.
  """
  def call(pool, func, opts) when is_atom(pool) and is_function(func, 0) and is_list(opts) do
    Dragonfly.Pool.call(pool, func, opts)
  end

  def call(func) when is_function(func, 0) do
    call(func, [])
  end

  def call(pool, func) when is_atom(pool) and is_function(func, 0) do
    Dragonfly.Pool.call(pool, func, [])
  end

  def call(func, opts) when is_function(func, 0) and is_list(opts) do
    {:ok, pid} = Runner.start_link(opts)
    :ok = Runner.remote_boot(pid)
    call(pid, func)
  end

  def call(pid, func) when is_pid(pid) and is_function(func, 0) do
    Runner.call(pid, func)
  end
end
