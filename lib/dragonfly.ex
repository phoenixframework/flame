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
        Dragonfly.call(MyApp.FFMpegRunner, fn ->
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

  To support your Dragonfly calls, you'll need to add a named `Dragonfly.Pool` to your
  application's supervision tree, which we'll discuss next.

  ## Pools

  A `Dragonfly.Pool` provides elastic runner scaling, allowing a minimum and
  maximum number of runners to be configured, and idle'd down as load decreases.

  Pools give you elastic scale that maximizes the newly spawned hardware.
  At the same time, you also want to avoid spawning unbound resources. You also
  want to keep spawned nodes alive for a period of time to avoid the overhead
  of booting new ones before idleing them down. The following pool configuration
  takes care of all of this for you:

      children = [
        ...,
        {Dragonfly.Pool,
         name: App.FFMpegRunner,
         min: 0,
         max: 10,
         max_concurrency: 5,
         idle_shutdown_after: :timer.minutes(5)},
      ]

  Here we add a `Dragonfly.Pool` to our application supervision tree, configuring
  a minimum of 0 and maximum of 10 runners. This acheives "scale to zero" behavior
  while also allowing the pool to scale up to 10 runners when load increases.
  Each runner in the case will be able to execute up to 5 concurrent functions.
  The runners will shutdown atter 5 minutes of inactivity.

  Calling a pool is as simple as passing its name to the Dragonfly functions:

      Dragonfly.call(App.FFMpegRunner, fn -> :operation1 end)

  You'll also often want to enable or disable other application services based on whether
  your application is being started as child Dragonfly runner or being run directly. You
  can use `Dragonfly.Parent.get/0` to conditionally enable or disable processes in your
  `applicaiton.ex` file:

      def start(_type, _args) do
        dragonfly_parent = Dragonfly.Parent.get()

        children = [
          ...,
          {Dragonfly.Pool,
           name: Thumbs.FFMpegRunner,
           min: 0,
           max: 10,
           max_concurrency: 5,
           idle_shutdown_after: :timer.minutes(5)},
        !dragonfly_parent && ThumbsWeb.Endpoint
        ]
        |> Enum.filter(& &1)

        opts = [strategy: :one_for_one, name: Thumbs.Supervisor]
        Supervisor.start_link(children, opts)
      end

  Here we filter the phoenix endpoint from being started when running as a Dragonfly
  child because we have no need to handle web requests in this case.

  ## Backends

  The `Dragonfly.Backend` behavior defines an interface for spawning remote
  application nodes and sending functions to them. By default, the
  `Dragonfly.LocalBackend` is used, which is great for development and test
  environments, as you can have your code simply execute locally in most cases
  and worry about scaling the operation only in production.

  For production, Dragonfly provides the `Dragonfly.FlyBackend`, which uses
  [Fly.io](https://fly.io). Because Fly deploys a containerized machine of
  your application, a single Fly API call can boot a machine running your
  exact Docker deployment image, allowing closures to be executed across
  distributed nodes.

  Default backends can be configured in your `config/runtime.exs`:

      if config_env() == :prod do
        config :dragonfly, :backend, Dragonfly.FlyBackend
        config :dragonfly, Dragonfly.FlyBackend, token: System.fetch_env!("FLY_API_TOKEN")
        ...
      end
  """
  require Logger

  @doc """
  Calls a function in a remote runner for the given `Dragonfly.Pool`.

  ## Options

    * `:timeout` - The timeout the caller is willing to wait for a response before an
      exit with `:timeout`. Defaults to the configured timeout of the pool.
      The executed function will also be terminated on the remote dragonfly if
      the timeout is reached.

  ## Examples

    def my_expensive_thing(arg) do
      Dragonfly.call(MyApp.Runner, fn ->
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

  def call(pool, func) when is_atom(pool) and is_function(func, 0) do
    Dragonfly.Pool.call(pool, func, [])
  end
end
