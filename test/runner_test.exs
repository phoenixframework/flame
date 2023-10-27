defmodule Dragonfly.RunnerTest do
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
    Application.put_env(:dragonfly, :backend, Dragonfly.MockBackend)
    :ok
  end

  test "backend success single_use" do
    test_pid = self()

    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> {:ok, @post_success} end)
    |> expect(:remote_spawn_link, fn @post_success = state, func ->
      {:ok, spawn_link(func), state}
    end)
    # we need to send and assert_receive to avoid the race of going down before mox verify
    |> expect(:system_shutdown, fn -> send(test_pid, :stopped) end)

    {:ok, runner} =
      Runner.start_link(
        single_use: true,
        backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
      )

    assert Runner.remote_boot(runner) == :ok
    assert Runner.call(runner, fn -> :works end) == :works
    assert_receive :stopped
  end

  test "backend success multi use" do
    test_pid = self()

    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> {:ok, @post_success} end)
    |> expect(:remote_spawn_link, 3, fn @post_success = state, func ->
      {:ok, spawn_link(func), state}
    end)
    |> stub(:system_shutdown, fn -> send(test_pid, :stopped) end)

    {:ok, runner} =
      Runner.start_link(
        backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
      )

    assert Runner.remote_boot(runner) == :ok
    assert Runner.remote_boot(runner) == {:error, :already_booted}
    assert Runner.call(runner, fn -> :works end) == :works
    refute_receive :stopped
    assert Runner.call(runner, fn -> :still_works end) == :still_works
    ref = Process.monitor(runner)
    assert Runner.shutdown(runner) == :ok
    assert_receive :stopped
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
  end

  test "backend runner spawn connect failure" do
    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> {:error, :invalid_authentication} end)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, runner} =
        Runner.start_link(
          backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
        )

      Process.unlink(runner)

      try do
        Runner.remote_boot(runner)
      catch
        :exit, {reason, _} ->
          assert reason == {:shutdown, :invalid_authentication}
      end
    end)
  end

  test "backend runner boot failure" do
    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> {:error, :nxdomain} end)

    ExUnit.CaptureLog.capture_log(fn ->
      {:ok, runner} =
        Runner.start_link(
          backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
        )

      Process.unlink(runner)

      try do
        Runner.remote_boot(runner)
      catch
        :exit, {reason, _} ->
          assert reason == {:shutdown, :nxdomain}
      end
    end)
  end

  #   test "execution failure" do
  #     Application.put_env(:dragonfly, :backend, Dragonfly.LocalBackend)

  #     ExUnit.CaptureLog.capture_log(fn ->
  #       task = Dragonfly.async(fn -> raise "boom!" end)
  #       assert {:exit, {%RuntimeError{message: "boom!"}, _}} = Task.yield(task)
  #     end)
  #   end

  #   test "execution timeout" do
  #     Application.put_env(:dragonfly, :backend, Dragonfly.LocalBackend)

  #     ExUnit.CaptureLog.capture_log(fn ->
  #       task = Dragonfly.async(fn -> Process.sleep(1000) end, timeout: 50)
  #       assert {:exit, :timeout} = Task.await(task)
  #     end)
  #   end

  #   test "local success" do
  #     Application.put_env(:dragonfly, :backend, Dragonfly.LocalBackend)
  #     task = Dragonfly.async(fn -> {:works, node()} end)
  #     assert Task.await(task) == {:works, node()}
  #   end
end
