defmodule FLAME.FLAMETest do
  use ExUnit.Case, async: true

  alias FLAME.Pool

  defp sim_long_running(pool, time \\ 1_000) do
    ref = make_ref()
    parent = self()

    task =
      Task.start_link(fn ->
        FLAME.call(pool, fn ->
          send(parent, {ref, :called})
          Process.sleep(time)
        end)
      end)

    receive do
      {^ref, :called} -> task
    end
  end

  setup config do
    runner_opts = Map.fetch!(config, :runner)
    runner_sup = Module.concat(config.test, "RunnerSup")
    pool_pid = start_supervised!({Pool, Keyword.merge(runner_opts, name: config.test)})

    {:ok, runner_sup: runner_sup, pool_pid: pool_pid}
  end

  @tag runner: [min: 1, max: 2, max_concurrency: 2]
  test "init boots min runners synchronously and grows on demand",
       %{runner_sup: runner_sup} = config do
    min_pool = Supervisor.which_children(runner_sup)
    assert [{:undefined, _pid, :worker, [FLAME.Runner]}] = min_pool
    # execute against single runner
    assert FLAME.call(config.test, fn -> :works end) == :works

    # dynamically grows to max
    _task1 = sim_long_running(config.test)
    assert FLAME.call(config.test, fn -> :works end) == :works
    # max concurrency still below threshold
    assert Supervisor.which_children(runner_sup) == min_pool
    # max concurrency above threshold boots new runner
    _task2 = sim_long_running(config.test)
    assert FLAME.call(config.test, fn -> :works end) == :works
    new_pool = Supervisor.which_children(runner_sup)
    refute new_pool == min_pool
    assert length(new_pool) == 2
    # caller is now queued while waiting for available runner
    _task3 = sim_long_running(config.test)
    _task4 = sim_long_running(config.test)
    # task is queued and times out
    queued = spawn(fn -> FLAME.call(config.test, fn -> :queued end, timeout: 100) end)
    ref = Process.monitor(queued)
    assert_receive {:DOWN, ^ref, :process, _, {:timeout, _}}, 1000
    assert FLAME.call(config.test, fn -> :queued end) == :queued
    assert new_pool == Supervisor.which_children(runner_sup)
  end

  def on_grow_start(meta) do
    send(:failure_test, {:grow_start, meta})

    if Agent.get_and_update(:failure_test_counter, &{&1 + 1, &1 + 1}) <= 1 do
      raise "boom"
    end
  end

  def on_grow_end(result, meta) do
    send(:failure_test, {:grow_start_end, result, meta})
  end


  @tag runner: [min: 1, max: 2, max_concurrency: 1, on_grow_start: &__MODULE__.on_grow_start/1, on_grow_end: &__MODULE__.on_grow_end/2]
  test "failure of pending async runner bootup", %{runner_sup: runner_sup} = config do
    parent = self()

    ExUnit.CaptureLog.capture_log(fn ->
      start_supervised!(
        {Agent,
         fn ->
           Process.register(self(), :failure_test_counter)
           0
         end}
      )

      Process.register(self(), :failure_test)
      assert [{:undefined, _pid, :worker, [FLAME.Runner]}] = Supervisor.which_children(runner_sup)
      # max concurrency above threshold tries to boot new runner
      _task2 = sim_long_running(config.test, :infinity)
      spawn_link(fn -> FLAME.cast(config.test, fn -> send(parent, :fullfilled) end) end)
      # first attempt fails
      refute_receive :fullfilled
      assert_receive {:grow_start, %{count: 2, pid: pid}}
      assert_receive {:grow_start_end, {:exit, _}, %{pid: ^pid, count: 1}}
      assert length(Supervisor.which_children(runner_sup)) == 1

      # retry attempt succeeds
      assert_receive {:grow_start, %{count: 2, pid: pid}}, 1000
      assert_receive {:grow_start_end, :ok, %{pid: ^pid, count: 2}}
      # queued og caller is now fullfilled from retried runner boot
      assert_receive :fullfilled
      assert FLAME.call(config.test, fn -> :works end) == :works
      assert length(Supervisor.which_children(runner_sup)) == 2
    end)
  end

  @tag runner: [min: 1, max: 2, max_concurrency: 2, idle_shutdown_after: 500]
  test "idle shutdown", %{runner_sup: runner_sup} = config do
    sim_long_running(config.test, 100)
    sim_long_running(config.test, 100)
    sim_long_running(config.test, 100)

    # we've scaled from min 1 to max 2 at this point
    assert [
             {:undefined, runner1, :worker, [FLAME.Runner]},
             {:undefined, runner2, :worker, [FLAME.Runner]}
           ] = Supervisor.which_children(runner_sup)

    Process.monitor(runner1)
    Process.monitor(runner2)
    assert_receive {:DOWN, _ref, :process, ^runner2, {:shutdown, :idle}}, 1000
    refute_receive {:DOWN, _ref, :process, ^runner1, {:shutdown, :idle}}

    assert [{:undefined, ^runner1, :worker, [FLAME.Runner]}] =
             Supervisor.which_children(runner_sup)
  end

  @tag runner: [min: 1, max: 1, max_concurrency: 2, idle_shutdown_after: 500]
  test "pool runner DOWN exits any active checkouts", %{runner_sup: runner_sup} = config do
    {:ok, active_checkout} = sim_long_running(config.test, 10_000)
    Process.unlink(active_checkout)
    Process.monitor(active_checkout)
    assert [{:undefined, runner, :worker, [FLAME.Runner]}] = Supervisor.which_children(runner_sup)
    Process.exit(runner, :brutal_kill)
    assert_receive {:DOWN, _ref, :process, ^active_checkout, :killed}
  end

  describe "cast" do
    @tag runner: [min: 1, max: 2, max_concurrency: 2, idle_shutdown_after: 500]
    test "normal execution", %{} = config do
      sim_long_running(config.test, 100)
      parent = self()
      assert FLAME.cast(config.test, fn -> send(parent, {:ran, self()}) end) == :ok
      assert_receive {:ran, cast_pid}
      Process.monitor(cast_pid)
      assert_receive {:DOWN, _ref, :process, ^cast_pid, :normal}
    end

    @tag runner: [min: 1, max: 2, max_concurrency: 2, idle_shutdown_after: 500]
    test "with exit", %{} = config do
      sim_long_running(config.test, 100)
      parent = self()

      assert FLAME.cast(config.test, fn ->
               send(parent, {:ran, self()})
               exit(:boom)
             end) == :ok

      assert_receive {:ran, cast_pid}
      Process.monitor(cast_pid)
      assert_receive {:DOWN, _ref, :process, ^cast_pid, :boom}
    end
  end
end
