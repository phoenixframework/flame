defmodule FLAME.RunnerTest do
  use ExUnit.Case, async: false

  import Mox

  alias FLAME.{Runner, MockBackend}
  alias FLAME.Test.CodeSyncMock

  # Make sure mocks are verified when the test exits
  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    term_sup =
      start_supervised!({DynamicSupervisor, name: __MODULE__.TermSup, strategy: :one_for_one})

    {:ok, term_sup: term_sup}
  end

  @post_success %{
    "id" => "app",
    "instance_id" => "iad-app",
    "private_ip" => node() |> to_string() |> String.split("@") |> Enum.at(-1)
  }

  defp remote_boot(state) do
    parent = FLAME.Parent.new(make_ref(), self(), MockBackend, "app-flame-1", "MY_HOST_IP")
    name = Module.concat(FLAME.TerminatorTest, to_string(System.unique_integer([:positive])))
    opts = [name: name, parent: parent]
    spec = Supervisor.child_spec({FLAME.Terminator, opts}, restart: :temporary)
    {:ok, _sup_pid} = DynamicSupervisor.start_child(__MODULE__.TermSup, spec)

    case Process.whereis(name) do
      terminator_pid when is_pid(terminator_pid) -> {:ok, terminator_pid, state}
    end
  end

  def mock_successful_runner(executions, runner_opts \\ []) do
    test_pid = self()

    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> remote_boot(@post_success) end)
    |> expect(:handle_info, fn {_ref, {:remote_up, _pid}}, state -> {:noreply, state} end)
    |> expect(:remote_spawn_monitor, executions, fn @post_success = _state, func ->
      {:ok, spawn_monitor(func)}
    end)
    # we need to send and assert_receive to avoid the race of going down before mox verify
    |> expect(:system_shutdown, fn -> send(test_pid, :stopped) end)

    Runner.start_link(
      Keyword.merge(
        [backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}],
        runner_opts
      )
    )
  end

  def wrap_exit(runner, func) do
    prev_trap = Process.flag(:trap_exit, true)
    Process.unlink(runner)
    ref = make_ref()

    ExUnit.CaptureLog.capture_log(fn ->
      error =
        try do
          func.()
        catch
          kind, reason -> {kind, reason}
        end

      send(self(), {ref, error})
    end)

    receive do
      {^ref, error} ->
        Process.flag(:trap_exit, prev_trap)
        error
    end
  end

  setup_all do
    Mox.defmock(MockBackend, for: FLAME.Backend)
    Application.put_env(:flame, :backend, FLAME.MockBackend)
    :ok
  end

  test "backend success single_use" do
    test_pid = self()

    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> remote_boot(@post_success) end)
    |> expect(:handle_info, fn {_ref, {:remote_up, _pid}}, state -> {:noreply, state} end)
    |> expect(:remote_spawn_monitor, 2, fn @post_success = _state, func ->
      {:ok, spawn_monitor(func)}
    end)
    |> expect(:system_shutdown, fn -> send(test_pid, :stopped) end)

    {:ok, runner} =
      Runner.start_link(
        single_use: true,
        backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
      )

    assert Runner.remote_boot(runner) == :ok
    assert Runner.call(runner, self(), fn -> :works end) == :works
    assert_receive :stopped
  end

  test "backend success multi use" do
    {:ok, runner} = mock_successful_runner(4)

    assert Runner.remote_boot(runner) == :ok
    assert Runner.remote_boot(runner) == {:error, :already_booted}
    assert Runner.call(runner, self(), fn -> :works end) == :works
    refute_receive :stopped
    assert Runner.call(runner, self(), fn -> :still_works end) == :still_works
    ref = Process.monitor(runner)
    assert Runner.shutdown(runner) == :ok
    assert_receive :stopped
    assert_receive {:DOWN, ^ref, :process, ^runner, :normal}
  end

  test "backend runner spawn connect failure" do
    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> {:error, :invalid_authentication} end)

    {:ok, runner} =
      Runner.start_link(
        backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
      )

    assert {:exit, {{:shutdown, :invalid_authentication}, _}} =
             wrap_exit(runner, fn -> Runner.remote_boot(runner) end)
  end

  test "backend runner boot failure" do
    MockBackend
    |> expect(:init, fn _opts -> {:ok, :state} end)
    |> expect(:remote_boot, fn :state -> {:error, :nxdomain} end)

    {:ok, runner} =
      Runner.start_link(
        backend: {MockBackend, image: "my-imag", app_name: "test", api_token: "secret"}
      )

    assert {:exit, {{:shutdown, :nxdomain}, _}} =
             wrap_exit(runner, fn -> Runner.remote_boot(runner) end)
  end

  describe "execution failure" do
    test "single use" do
      {:ok, runner} = mock_successful_runner(3, single_use: true)
      assert Runner.remote_boot(runner) == :ok
      error = wrap_exit(runner, fn -> Runner.call(runner, self(), fn -> raise "boom" end) end)
      assert {:exit, {%RuntimeError{message: "boom"}, _}} = error
      assert_receive :stopped
      assert Runner.shutdown(runner) == :ok
    end

    test "multi use" do
      {:ok, runner} = mock_successful_runner(4)
      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok

      error = wrap_exit(runner, fn -> Runner.call(runner, self(), fn -> raise "boom" end) end)
      assert {:exit, {%RuntimeError{message: "boom"}, _}} = error
      refute_receive :stopped
      refute_receive {:DOWN, _ref, :process, ^runner, _}
      assert Runner.call(runner, self(), fn -> :works end) == :works
      assert Runner.shutdown(runner) == :ok
    end
  end

  describe "execution timeout" do
    test "single use" do
      timeout = 100
      {:ok, runner} = mock_successful_runner(3, timeout: timeout, single_use: true)

      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok

      error =
        wrap_exit(runner, fn ->
          Runner.call(runner, self(), fn -> Process.sleep(timeout * 2) end)
        end)

      assert error == {:exit, :timeout}

      assert_receive :stopped
      assert_receive {:DOWN, _ref, :process, _, :killed}
      assert Runner.shutdown(runner) == :ok
    end

    test "multi use" do
      timeout = 100
      {:ok, runner} = mock_successful_runner(4, timeout: timeout)

      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok

      error =
        wrap_exit(runner, fn ->
          Runner.call(runner, self(), fn -> Process.sleep(timeout * 2) end)
        end)

      assert error == {:exit, :timeout}

      refute_receive :stopped
      refute_receive {:DOWN, _ref, :process, ^runner, _}
      assert Runner.call(runner, self(), fn -> :works end, timeout: 1234) == :works
      assert Runner.shutdown(runner) == :ok
    end
  end

  describe "idle shutdown" do
    test "with time" do
      timeout = 500
      {:ok, runner} = mock_successful_runner(1, idle_shutdown_after: timeout)

      Process.unlink(runner)
      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok

      assert_receive :stopped, timeout * 2
      assert_receive {:DOWN, _ref, :process, ^runner, _}

      {:ok, runner} = mock_successful_runner(2, idle_shutdown_after: timeout)
      Process.unlink(runner)
      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok
      assert Runner.call(runner, self(), fn -> :works end) == :works
      assert_receive :stopped, timeout * 2
      assert_receive {:DOWN, _ref, :process, ^runner, _}
    end

    test "with timed check" do
      agent = start_supervised!({Agent, fn -> false end})
      timeout = 500
      idle_after = {timeout, fn -> Agent.get(agent, & &1) end}
      {:ok, runner} = mock_successful_runner(1, idle_shutdown_after: idle_after)

      Process.unlink(runner)
      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok

      refute_receive {:DOWN, _ref, :process, ^runner, _}, timeout * 2
      Agent.update(agent, fn _ -> true end)
      assert_receive :stopped, timeout * 2
      assert_receive {:DOWN, _ref, :process, ^runner, _}
    end
  end

  describe "code_sync" do
    test "copy_paths: true, copies the code paths and extracts on boot" do
      mock = CodeSyncMock.new()
      # the 4th invocation is the rpc to diff code paths
      {:ok, runner} = mock_successful_runner(4, code_sync: mock.opts)

      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok
      assert Runner.call(runner, self(), fn -> :works end, timeout: 1234) == :works
      assert Runner.shutdown(runner) == :ok
      # called on remote boot
      assert_receive {CodeSyncMock, {_mock, :extract}}

      # called on :works call
      assert_receive {CodeSyncMock, {_mock, :extract}}
    end

    test "noops by default" do
      {:ok, runner} = mock_successful_runner(3)

      Process.monitor(runner)
      assert Runner.remote_boot(runner) == :ok
      assert Runner.call(runner, self(), fn -> :works end, timeout: 1234) == :works
      assert Runner.shutdown(runner) == :ok
      refute_receive {CodeSyncMock, _}
    end
  end
end
