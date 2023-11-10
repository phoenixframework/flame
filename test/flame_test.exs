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
    dyn_sup = Module.concat(config.test, "DynamicSup")
    pool_pid = start_supervised!({Pool, Keyword.merge(runner_opts, name: config.test)})

    {:ok, dyn_sup: dyn_sup, pool_pid: pool_pid}
  end

  @tag runner: [min: 1, max: 2, max_concurrency: 2]
  test "init boots min runners synchronously", %{dyn_sup: dyn_sup} = config do
    min_pool = Supervisor.which_children(dyn_sup)
    assert [{:undefined, _pid, :worker, [FLAME.Runner]}] = min_pool
    # execute against single runner
    assert FLAME.call(config.test, fn -> :works end) == :works

    # dynamically grows to max
    _task1 = sim_long_running(config.test)
    assert FLAME.call(config.test, fn -> :works end) == :works
    # max concurrency still below threshold
    assert Supervisor.which_children(dyn_sup) == min_pool
    # max concurrency above threshold boots new runner
    _task2 = sim_long_running(config.test)
    assert FLAME.call(config.test, fn -> :works end) == :works
    new_pool = Supervisor.which_children(dyn_sup)
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
    assert new_pool == Supervisor.which_children(dyn_sup)
  end

  @tag runner: [min: 1, max: 2, max_concurrency: 2, idle_shutdown_after: 500]
  test "idle shutdown", %{dyn_sup: dyn_sup} = config do
    sim_long_running(config.test, 100)
    sim_long_running(config.test, 100)
    sim_long_running(config.test, 100)

    # we've scaled from min 1 to max 2 at this point
    assert [
             {:undefined, runner1, :worker, [FLAME.Runner]},
             {:undefined, runner2, :worker, [FLAME.Runner]}
           ] = Supervisor.which_children(dyn_sup)

    Process.monitor(runner1)
    Process.monitor(runner2)
    assert_receive {:DOWN, _ref, :process, ^runner2, {:shutdown, :idle}}, 1000
    refute_receive {:DOWN, _ref, :process, ^runner1, {:shutdown, :idle}}

    assert [{:undefined, ^runner1, :worker, [FLAME.Runner]}] =
             Supervisor.which_children(dyn_sup)
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
