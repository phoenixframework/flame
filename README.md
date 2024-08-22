# Flame

[![Hex.pm version](https://img.shields.io/hexpm/v/flame.svg)](https://hex.pm/packages/flame)
[![Hex.pm downloads](https://img.shields.io/hexpm/dt/flame.svg)](https://hex.pm/packages/flame)
[![Hex.pm weekly downloads](https://img.shields.io/hexpm/dw/flame.svg)](https://hex.pm/packages/flame)
[![Hex.pm daily downloads](https://img.shields.io/hexpm/dd/flame.svg)](https://hex.pm/packages/flame)

Imagine if we could auto scale simply by wrapping any existing app code in a function and have that block of code run in a temporary copy of the app.

Enter the FLAME pattern.

> FLAME - Fleeting Lambda Application for Modular Execution

With FLAME, you treat your _entire application_ as a lambda, where modular parts can be executed on short-lived infrastructure.

Check the screencast to see it in action:

[![Video](https://img.youtube.com/vi/l1xt_rkWdic/maxresdefault.jpg)](https://www.youtube.com/watch?v=l1xt_rkWdic)

## Setup

First add `:flame` as a dependency:

```elixir
defp deps do
  [
    # For Erlang/OTP 26 and earlier, you also need Jason
    # {:jason, ">= 0.0.0"},
    {:flame, "~> 0.3"}
  ]
end
```

Then start a FLAME pool in your supervision tree, typically on `application.ex`. The example below uses [Fly.io](https://fly.io/)'s backend:

```elixir
children = [
  {FLAME.Pool,
   name: MyApp.SamplePool,
   backend: FLAME.FlyBackend,
   min: 0,
   max: 10,
   max_concurrency: 5,
   idle_shutdown_after: 30_000,
   log: :debug}
]
```

Now you can wrap any block of code in a `FLAME.call` and it will find or boot a copy of the app, execute the work there, and return the results:

```elixir
def generate_thumbnails(%Video{} = vid, interval) do
  FLAME.call(MyApp.FFMpegRunner, fn ->
    # I'm runner on a short-lived, temporary server
    tmp_dir = Path.join(System.tmp_dir!(), Ecto.UUID.generate())
    File.mkdir!(tmp_dir)
    System.cmd("ffmpeg", ~w(-i #{vid.url} -vf fps=1/#{interval} #{tmp_dir}/%02d.png))
    urls = VideoStore.put_thumbnails(vid, Path.wildcard(tmp_dir <> "/*.png"))
    Repo.insert_all(Thumbnail, Enum.map(urls, &%{video_id: vid.id, url: &1}))
  end)
end
```

Here we wrapped up our CPU expensive `ffmpeg` operation in a `FLAME.call/2`. FLAME accepts a function and any variables that the function closes over. In this example, the `%Video{}` struct and `interval` are passed along automatically. The work happens in a temporary copy of the app. We can do any work inside the FLAME call because we are running the _entire application_, database connection(s) and all.

`FLAME` provides the following interfaces for elastically scaled operations:

- `FLAME.call/3` - used for synchronous calls
- `FLAME.cast/3` - used for async casts where you don't need to wait on the results
- `FLAME.place_child/3` – used for placing a child spec somewhere to run, in place of `DynamicSupervisor.start_child`, `Task.Supervisor.start_child`, etc

The `FLAME.Pool` handles elastically scaling runners up and down, as well as remote monitoring of resources. Check the moduledoc for example usage.
