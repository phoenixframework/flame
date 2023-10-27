defmodule Dragonfly.FlyBackendTest do
  use ExUnit.Case, async: false

  alias Dragonfly.{Runner, FlyBackend}

  setup do
    Application.delete_env(:dragonfly, :backend)
    Application.delete_env(:dragonfly, FlyBackend)
  end

  test "explicit backend" do
    assert_raise ArgumentError, ~r/missing :token/, fn ->
      Runner.new(backend: {FlyBackend, []})
    end

    assert_raise ArgumentError, ~r/missing :image/, fn ->
      Runner.new(backend: {FlyBackend, token: "123"})
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      Runner.new(backend: {FlyBackend, token: "123", image: "img"})
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      Runner.new(backend: {FlyBackend, token: "123", image: "img"})
    end

    assert Runner.new(backend: {FlyBackend, token: "123", image: "img", app: "app"})
  end

  test "extended opts" do
    opts = [
      token: "123",
      image: "img",
      app: "app",
      host: "foo.local",
      env: %{one: 1},
      size: "performance-1x"
    ]

    runner = Runner.new(backend: {FlyBackend, opts})
    assert runner.backend_options.host == "foo.local"
    assert runner.backend_options.size == "performance-1x"

    assert runner.backend_options.env == %{
             one: 1,
             DRAGONFLY_PARENT_NODE: "nonode@nohost",
             PHX_SERVER: "false"
           }
  end

  test "global configured backend" do
    assert_raise ArgumentError, ~r/missing :token/, fn ->
      Application.put_env(:dragonfly, :backend, Dragonfly.FlyBackend)
      Application.put_env(:dragonfly, Dragonfly.FlyBackend, [])
      Runner.new()
    end

    assert_raise ArgumentError, ~r/missing :image/, fn ->
      Application.put_env(:dragonfly, :backend, Dragonfly.FlyBackend)
      Application.put_env(:dragonfly, Dragonfly.FlyBackend, token: "123")
      Runner.new()
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      Application.put_env(:dragonfly, :backend, Dragonfly.FlyBackend)
      Application.put_env(:dragonfly, Dragonfly.FlyBackend, token: "123", image: "img")
      Runner.new()
    end

    Application.put_env(:dragonfly, :backend, Dragonfly.FlyBackend)
    Application.put_env(:dragonfly, Dragonfly.FlyBackend, token: "123", image: "img", app: "app")

    assert Runner.new()
  end
end
