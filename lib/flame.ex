defmodule FLAME do
  @moduledoc ~S"""
  FLAME remotely executes your application code on ephemeral nodes.

  FLAME allows you to scale your application operations on a granular
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
  FaaS or external service solutions, but FLAME gives you a better way.

  Simply wrap your your existing code in a FLAME function and it will be executed
  on a newly spawned, ephemeral node. Using Elixir and Erlang's built in distribution
  features, entire function closures, including any state they close over, can be sent
  and executed on a remote node:

      def resize_video_quality(%Video{} = video) do
        FLAME.call(MyApp.FFMpegRunner, fn ->
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

  To support your FLAME calls, you'll need to add a named `FLAME.Pool` to your
  application's supervision tree, which we'll discuss next.

  ## Pools

  A `FLAME.Pool` provides elastic runner scaling, allowing a minimum and
  maximum number of runners to be configured, and idle'd down as load decreases.

  Pools give you elastic scale that maximizes the newly spawned hardware.
  At the same time, you also want to avoid spawning unbound resources. You also
  want to keep spawned nodes alive for a period of time to avoid the overhead
  of booting new ones before idling them down. The following pool configuration
  takes care of all of this for you:

      children = [
        ...,
        {FLAME.Pool,
         name: App.FFMpegRunner,
         min: 0,
         max: 10,
         max_concurrency: 5,
         idle_shutdown_after: 30_000},
      ]

  Here we add a `FLAME.Pool` to our application supervision tree, configuring
  a minimum of 0 and maximum of 10 runners. This acheives "scale to zero" behavior
  while also allowing the pool to scale up to 10 runners when load increases.
  Each runner in the case will be able to execute up to 5 concurrent functions.
  The runners will shutdown after 30 seconds of inactivity.

  Calling a pool is as simple as passing its name to the FLAME functions:

      FLAME.call(App.FFMpegRunner, fn -> :operation1 end)

  You'll also often want to enable or disable other application services based on whether
  your application is being started as child FLAME runner or being run directly.
  See the next `Deployment Considerations` section below for details.

  ## Deployment Considerations

  FLAME nodes effectively clone and start your entire application. This is great
  because all application services and dependencies are ready to go and be used to
  support your FLAME calls; however, You'll also often want to enable or disable
  services based on whether your node is running as a FLAME child or not.
  For example, there's usually no need to serve your Phoenix endpoint within a FLAME.
  You also likely only need a single or small number of database connections instead of
  your existing pool size.

  To accomplish these you can use `FLAME.Parent.get/0` to conditionally enable or
  disable processes in you `application.ex` file:

      def start(_type, _args) do
        flame_parent = FLAME.Parent.get()

        children = [
          ...,
          {FLAME.Pool,
           name: Thumbs.FFMpegRunner,
           min: 0,
           max: 10,
           max_concurrency: 5,
           idle_shutdown_after: 30_000},
        !flame_parent && ThumbsWeb.Endpoint
        ]
        |> Enum.filter(& &1)

        opts = [strategy: :one_for_one, name: Thumbs.Supervisor]
        Supervisor.start_link(children, opts)
      end

  Here we filter the Phoenix endpoint from being started when running as a FLAME
  child because we have no need to handle web requests in this case.

  Or you can use `FLAME.Parent.get/0` to configure your database pool size:

      pool_size =
        if FLAME.Parent.get() do
          1
        else
          String.to_integer(System.get_env("POOL_SIZE") || "10")
        end

      config :thumbs, Thumbs.Repo,
        ...,
        pool_size: pool_size

  ## Backends

  The `FLAME.Backend` behavior defines an interface for spawning remote
  application nodes and sending functions to them. By default, the
  `FLAME.LocalBackend` is used, which is great for development and test
  environments, as you can have your code simply execute locally in most cases
  and worry about scaling the operation only in production.

  For production, FLAME provides the `FLAME.FlyBackend`, which uses
  [Fly.io](https://fly.io). Because Fly deploys a containerized machine of
  your application, a single Fly API call can boot a machine running your
  exact Docker deployment image, allowing closures to be executed across
  distributed nodes.

  Default backends can be configured in your `config/runtime.exs`:

      if config_env() == :prod do
        config :flame, :backend, FLAME.FlyBackend
        config :flame, FLAME.FlyBackend, token: System.fetch_env!("FLY_API_TOKEN")
        ...
      end

  ## Termination and remote links

  FLAME runs a termination process to allow remotely spawned functions time to
  complete before the node is terminated. This process is started automatically
  with the library. The shutdown timeout by default is 30s, but can be configured
  in your application configuration, such as `config/runtime.exs`:

      config :flame, :terminator, shutdown_timeout: :timer.seconds(10)

  *Note*: By default `call/3`, `cast/3`, and `place_child/3` will link the caller
  to the remote process to prevent orphaned resources when the caller or the caller's node
  is terminated. This can be disabled by passing `link: false` to the options, which is
  useful for cases where you want to allow long-running work to complete within the
  `:shutdown_timeout` of the remote runner, regardless of what happens to the parent caller
  process and/or the parent caller node, such as a new cold deploy, a caller crash, etc.
  """
  require Logger

  @doc """
  Calls a function in a remote runner for the given `FLAME.Pool`.

  ## Options

    * `:timeout` - The timeout the caller is willing to wait for a response before an
      exit with `:timeout`. Defaults to the configured timeout of the pool.
      The executed function will also be terminated on the remote flame if
      the timeout is reached.

    * `:link` – Whether the caller should be linked to the remote call process
      to prevent long-running orphaned resources. Defaults to `true`. Set to `false` to
      support long-running work that you want to complete within the `:shutdown_timeout`
      of the remote runner, even when the parent process or node is terminated.
      *Note*: even when `link: false` is used, an exit in the remote process will raise
      an error on the caller. The caller will need to try/catch the call if they wish
      to handle the error.

  ## Examples

    def my_expensive_thing(arg) do
      FLAME.call(MyApp.Runner, fn ->
        # I'm now doing expensive work inside a new node
        # pubsub and repo access all just work
        Phoenix.PubSub.broadcast(MyApp.PubSub, "topic", result)

        # can return awaitable results back to caller
        result
      end)

  When the caller exits, the remote runner will be terminated.
  """
  def call(pool, func, opts) when is_atom(pool) and is_function(func, 0) and is_list(opts) do
    FLAME.Pool.call(pool, func, opts)
  end

  def call(pool, func) when is_atom(pool) and is_function(func, 0) do
    FLAME.Pool.call(pool, func, [])
  end

  @doc """
  Casts a function to a remote runner for the given `FLAME.Pool`.

  ## Options

    * `:link` – Whether the caller should be linked to the remote cast process
      to prevent long-running orphaned resources. Defaults to `true`. Set to `false` to
      support long-running work that you want to complete within the `:shutdown_timeout`
      of the remote runner, even when the parent process or node is terminated.
  """
  def cast(pool, func, opts \\ [])
      when is_atom(pool) and is_function(func, 0) and is_list(opts) do
    FLAME.Pool.cast(pool, func, opts)
  end

  @doc """
  Places a child process on a remote runner for the given `FLAME.Pool`.

  Any child process can be placed on the remote node and it will occupy a space
  in the runner's `max_concurrency` allowance. This is useful for long running
  workloads that you want to run asynchronously from the parent caller.

  *Note*: The placed child process is linked to the caller and will only survive
  as long as the caller does. This is to ensure that the child process is never
  orphaned permanently on the remote node.

  *Note*: The child spec will be rewritten to use a temporary restart strategy
  to ensure that the child process is never restarted on the remote node when it
  exits. If you want restart behavior, you need to monitor on the parent node and
  replace the child yourself.

  ## Options

    * `:timeout` - The timeout the caller is willing to wait for a response before an
      exit with `:timeout`. Defaults to the configured timeout of the pool.
      The executed function will also be terminated on the remote flame if
      the timeout is reached.

    * `:link` – Whether the caller should be linked to the remote child process
      to prevent long-running orphaned resources. Defaults to `true`. Set to `false` to
      support long-running work that you want to complete within the `:shutdown_timeout`
      of the remote runner, even when the parent process or node is terminated.

  Accepts any child spec.

  ## Examples

      {:ok, pid} = FLAME.place_child(MyRunner, {MyWorker, []})
  """
  def place_child(pool, child_spec, opts \\ []) when is_atom(pool) and is_list(opts) do
    FLAME.Pool.place_child(pool, child_spec, opts)
  end
end
