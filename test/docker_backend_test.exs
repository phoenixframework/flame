defmodule FLAME.DockerBackendTest do
  use ExUnit.Case, async: false

  alias FLAME.{Runner, DockerBackend}

  def new({backend, opts}) do
    Runner.new(backend: {backend, Keyword.merge([terminator_sup: __MODULE__], opts)})
  end

  setup do
    Application.delete_env(:flame, :backend)
    Application.delete_env(:flame, DockerBackend)
  end

  test "explicit backend" do
    assert_raise ArgumentError, ~r/missing :image/, fn ->
      new({DockerBackend, []})
    end

    assert new({DockerBackend, image: "img"})
  end

  test "extended opts" do
    opts = [
      image: "img",
      env: %{"ONE" => "1"},
      boot_timeout: 12345,
      docker_host: "tcp://localhost:2375",
      docker_api_version: "1.40",
      log: :debug
    ]

    runner = new({DockerBackend, opts})
    assert {:ok, init} = runner.backend_init
    assert init.image == "img"
    assert init.boot_timeout == 12345
    assert init.docker_host == "tcp://localhost:2375"
    assert init.docker_api_version == "1.40"
    assert init.log == :debug

    assert %{
             "ONE" => "1",
             "FLAME_PARENT" => _,
             "PHX_SERVER" => "false"
           } = init.env
  end

  test "global configured backend" do
    assert_raise ArgumentError, ~r/missing :image/, fn ->
      Application.put_env(:flame, DockerBackend, [])
      Runner.new(backend: DockerBackend)
    end

    Application.put_env(:flame, :backend, DockerBackend)
    Application.put_env(:flame, DockerBackend, image: "img")

    assert Runner.new(backend: DockerBackend)
  end

  test "parent backend attributes" do
    assert %FLAME.Parent{
             pid: _,
             ref: _,
             backend: FLAME.DockerBackend,
             flame_vsn: vsn,
             backend_vsn: vsn,
             backend_app: :flame
           } =
             FLAME.Parent.new(
               make_ref(),
               self(),
               FLAME.DockerBackend,
               "docker-flame-1",
               "DOCKER_IP"
             )
  end
end
