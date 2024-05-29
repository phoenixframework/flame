defmodule FLAME.GigalixirBackendTest do
  use ExUnit.Case, async: false

  alias FLAME.{Runner, GigalixirBackend}

  def new({backend, opts}) do
    Runner.new(backend: {backend, Keyword.merge([terminator_sup: __MODULE__], opts)})
  end

  setup do
    Application.delete_env(:flame, :backend)
    Application.delete_env(:flame, GigalixirBackend)
  end

  test "explicit backend" do
    assert_raise ArgumentError, ~r/missing :token/, fn ->
      new({GigalixirBackend, []})
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      new({GigalixirBackend, token: "123"})
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      new({GigalixirBackend, token: "123"})
    end

    assert new({GigalixirBackend, token: "123", app: "app"})
  end

  test "extended opts" do
    opts = [
      token: "123",
      app: "app",
      host: "foo.local",
      env: %{one: 1},
      size: 1.0,
      max_runtime: 45
    ]

    runner = new({GigalixirBackend, opts})
    assert {:ok, init} = runner.backend_init
    assert init.host == "foo.local"
    assert init.size == 1.0
    assert init.max_runtime == 45

    assert %{
             one: 1,
             FLAME_PARENT: _,
             PHX_SERVER: "false"
           } = init.env
  end

  test "global configured backend" do
    assert_raise ArgumentError, ~r/missing :token/, fn ->
      Application.put_env(:flame, FLAME.GigalixirBackend, [])
      Runner.new(backend: FLAME.GigalixirBackend)
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      Application.put_env(:flame, FLAME.GigalixirBackend, token: "123")
      Runner.new(backend: FLAME.GigalixirBackend)
    end

    Application.put_env(:flame, :backend, FLAME.GigalixirBackend)
    Application.put_env(:flame, FLAME.GigalixirBackend, token: "123", app: "app")

    assert Runner.new(backend: FLAME.GigalixirBackend)
  end
end
