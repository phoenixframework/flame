defmodule FLAME.FlyBackendTest do
  use ExUnit.Case, async: false

  alias FLAME.{Runner, FlyBackend}

  def new({backend, opts}) do
    Runner.new(backend: {backend, Keyword.merge([terminator_sup: __MODULE__], opts)})
  end

  setup do
    Application.delete_env(:flame, :backend)
    Application.delete_env(:flame, FlyBackend)
  end

  test "explicit backend" do
    assert_raise ArgumentError, ~r/missing :token/, fn ->
      new({FlyBackend, []})
    end

    assert_raise ArgumentError, ~r/missing :image/, fn ->
      new({FlyBackend, token: "123"})
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      new({FlyBackend, token: "123", image: "img"})
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      new({FlyBackend, token: "123", image: "img"})
    end

    assert new({FlyBackend, token: "123", image: "img", app: "app"})
  end

  test "extended opts" do
    opts = [
      token: "123",
      image: "img",
      app: "app",
      host: "foo.local",
      env: %{"ONE" => "1"},
      cpu_kind: "performance",
      cpus: 1,
      memory_mb: 256,
      gpu_kind: "a100-pcie-40gb"
    ]

    runner = new({FlyBackend, opts})
    assert {:ok, init} = runner.backend_init
    assert init.host == "foo.local"
    assert init.cpu_kind == "performance"
    assert init.cpus == 1
    assert init.memory_mb == 256
    assert init.gpu_kind == "a100-pcie-40gb"

    assert %{
             "ONE" => "1",
             "FLAME_PARENT" => _,
             "PHX_SERVER" => "false"
           } = init.env
  end

  test "global configured backend" do
    assert_raise ArgumentError, ~r/missing :token/, fn ->
      Application.put_env(:flame, FLAME.FlyBackend, [])
      Runner.new(backend: FLAME.FlyBackend)
    end

    assert_raise ArgumentError, ~r/missing :image/, fn ->
      Application.put_env(:flame, FLAME.FlyBackend, token: "123")
      Runner.new(backend: FLAME.FlyBackend)
    end

    assert_raise ArgumentError, ~r/missing :app/, fn ->
      Application.put_env(:flame, FLAME.FlyBackend, token: "123", image: "img")
      Runner.new(backend: FLAME.FlyBackend)
    end

    Application.put_env(:flame, :backend, FLAME.FlyBackend)
    Application.put_env(:flame, FLAME.FlyBackend, token: "123", image: "img", app: "app")

    assert Runner.new(backend: FLAME.FlyBackend)
  end

  test "parent backend attributes" do
    assert %FLAME.Parent{
             pid: _,
             ref: _,
             backend: FLAME.FlyBackend,
             flame_vsn: vsn,
             backend_vsn: vsn,
             backend_app: :flame
           } =
             FLAME.Parent.new(
               make_ref(),
               self(),
               FLAME.FlyBackend,
               "app-flame-1",
               "FLY_PRIVATE_IP"
             )
  end
end
