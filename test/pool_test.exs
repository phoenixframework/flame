defmodule Dragonfly.PooTest do
  use ExUnit.Case, async: true

  alias Dragonfly.Pool

  defp sim_long_running(pool, time \\ 1_000) do
    ref = make_ref()
    parent = self()

    task =
      Task.start_link(fn ->
        Dragonfly.call(pool, fn ->
          send(parent, {ref, :called})
          Process.sleep(time)
        end)
      end)

    receive do
      {^ref, :called} -> task
    end
  end

  setup config do
    runner_opts =
      config
      |> Map.fetch!(:runner)
      |> Keyword.merge(
        terminator: [
          name: __MODULE__.TestTerminator,
          shutdown_timeout: 10_000,
          failsafe_timeout: 10_000
        ]
      )

    dyn_sup = Module.concat(config.test, "DynamicSup")
    pool_pid = start_supervised!({Pool, Keyword.merge(runner_opts, name: config.test)})

    {:ok, dyn_sup: dyn_sup, pool_pid: pool_pid}
  end

  @tag runner: [min: 1, max: 2, max_concurrency: 2]
  test "init boots min runners synchronously", %{dyn_sup: dyn_sup} = config do
    min_pool = Supervisor.which_children(dyn_sup)
    assert [{:undefined, _pid, :worker, [Dragonfly.Runner]}] = min_pool
    # execute against single runner
    assert Dragonfly.call(config.test, fn -> :works end) == :works

    # dynamically grows to max
    _task1 = sim_long_running(config.test)
    assert Dragonfly.call(config.test, fn -> :works end) == :works
    # max concurrency still below threshold
    assert Supervisor.which_children(dyn_sup) == min_pool
    # max concurrency above threshold boots new runner
    _task2 = sim_long_running(config.test)
    assert Dragonfly.call(config.test, fn -> :works end) == :works
    new_pool = Supervisor.which_children(dyn_sup)
    refute new_pool == min_pool
    assert length(new_pool) == 2
    # caller is now queued while waiting for available runner
    _task3 = sim_long_running(config.test)
    _task4 = sim_long_running(config.test)
    # task is queued and times out
    queued = spawn(fn -> Dragonfly.call(config.test, fn -> :queued end, timeout: 100) end)
    ref = Process.monitor(queued)
    assert_receive {:DOWN, ^ref, :process, _, {:timeout, _}}, 1000
    assert Dragonfly.call(config.test, fn -> :queued end) == :queued
    assert new_pool == Supervisor.which_children(dyn_sup)
  end

  @tag runner: [min: 1, max: 2, max_concurrency: 2, idle_shutdown_after: 500]
  test "idle shutdown", %{dyn_sup: dyn_sup} = config do
    Process.monitor(term)
    sim_long_running(config.test, 100)
    sim_long_running(config.test, 100)
    sim_long_running(config.test, 100)

    # we've scaled from min 1 to max 2 at this point
    assert [
             {:undefined, runner1, :worker, [Dragonfly.Runner]},
             {:undefined, runner2, :worker, [Dragonfly.Runner]}
           ] = Supervisor.which_children(dyn_sup)

    Process.monitor(runner1)
    Process.monitor(runner2)
    assert_receive {:DOWN, _ref, :process, ^runner2, {:shutdown, :idle}}, 1000
    refute_receive {:DOWN, _ref, :process, ^runner1, {:shutdown, :idle}}

    assert [{:undefined, ^runner1, :worker, [Dragonfly.Runner]}] =
             Supervisor.which_children(dyn_sup)
  end
end
