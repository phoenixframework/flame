defmodule DragonflyTest do
  use ExUnit.Case, async: false

  import Mox

  alias Dragonfly.{Runner, MockBackend}

  # Make sure mocks are verified when the test exits
  setup :set_mox_global
  setup :verify_on_exit!

  @post_success %{
    "id" => "app",
    "instance_id" => "iad-app",
    "private_ip" => node() |> to_string() |> String.split("@") |> Enum.at(-1)
  }

  setup_all do
    Mox.defmock(MockBackend, for: Dragonfly.Backend)
    :ok
  end

  describe "async" do
    setup do
      Application.put_env(:dragonfly, :backend, Dragonfly.MockBackend)
      :ok
    end

    test "api success" do
      MockBackend
      |> expect(:init, fn _opts -> [] end)
      |> expect(:remote_boot, fn %Runner{} -> @post_success end)
      |> expect(:remote_spawn_link, fn %Runner{}, func -> func.() end)
      |> expect(:system_shutdown, fn -> :ok end)

      task =
        Runner.new(
          backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
        )
        |> Dragonfly.async(fn -> :works end)

      assert Task.await(task) == :works
    end

    test "api Runner create failure" do
      MockBackend
      |> expect(:init, fn _opts -> [] end)
      |> expect(:remote_boot, fn %Runner{} -> %{"error" => "invalid authentication"} end)

      ExUnit.CaptureLog.capture_log(fn ->
        task =
          Runner.new(
            backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
          )
          |> Dragonfly.async(fn -> :works end)

        assert {:exit, {%RuntimeError{message: "unexpected response from API" <> _}, _}} =
                 Task.yield(task)
      end)
    end

    test "api Runner node connect failure" do
      MockBackend
      |> expect(:init, fn _opts -> {:ok, :state} end)
      |> expect(:remote_boot, fn :state -> {:error, :nxdomain} end)

      opts = [
        backend:
          {MockBackend,
           image: "my-imag", app_name: "test", api_token: "secret", connect_timeout: 1000}
      ]

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, runner = Dragonfly.start_runner()
        task = Dragonfly.async(runner, fn -> :works end, opts)

        assert {:exit,
                {%RuntimeError{message: "unable to reach Runner test@nohost after 1000ms"}, _}} =
                 Task.yield(task)
      end)
    end

    test "execution failure" do
      Application.put_env(:dragonfly, :backend, Dragonfly.LocalBackend)

      ExUnit.CaptureLog.capture_log(fn ->
        task = Dragonfly.async(fn -> raise "boom!" end)
        assert {:exit, {%RuntimeError{message: "boom!"}, _}} = Task.yield(task)
      end)
    end

    test "execution timeout" do
      Application.put_env(:dragonfly, :backend, Dragonfly.LocalBackend)

      ExUnit.CaptureLog.capture_log(fn ->
        task = Dragonfly.async(fn -> Process.sleep(1000) end, timeout: 50)
        assert {:exit, :timeout} = Task.await(task)
      end)
    end

    test "local success" do
      Application.put_env(:dragonfly, :backend, Dragonfly.LocalBackend)
      task = Dragonfly.async(fn -> {:works, node()} end)
      assert Task.await(task) == {:works, node()}
    end
  end
end
