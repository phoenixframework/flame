defmodule FLAME.Pool.PerRunnerMaxConcurrencyStrategy do
  alias FLAME.Pool
  @behaviour FLAME.Pool.Strategy

  def checkout_runner(%Pool{} = pool, opts) do
    min_runner = min_runner(pool)
    runner_count = Pool.runner_count(pool)
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)

    cond do
      min_runner && min_runner.count < state.max_concurrency ->
        reply_runner_checkout(state, min_runner, from, monitor_ref)
        {:checkout, min_runner}

      runner_count < state.max ->
        if state.async_boot_timer ||
             map_size(state.pending_runners) * state.max_concurrency > waiting_count(state) do
          :wait
        else
          :scale

          state
          |> async_boot_runner()
          |> waiting_in(deadline, from)
        end

      true ->
        :wait
    end
  end

  def assign_waiting_callers(%Pool{} = pool, %Pool.RunnerState{} = runner, opts) do
    max_concurrency = Keyword.fetch!(opts, :max_concurrency)

    # pop waiting callers up to max_concurrency, but we must handle:
    # 1. the case where we have no waiting callers
    # 2. the case where we process a DOWN for the new runner as we pop DOWNs
    #   looking for fresh waiting
    {pool, _assigned_concurrency} =
      Enum.reduce_while(1..max_concurrency, {pool, 0}, fn _i, {pool, assigned_concurrency} ->
        with {:ok, %Pool.RunnerState{} = runner} <- Map.fetch(pool.runners, runner.monitor_ref),
             true <- assigned_concurrency <= max_concurrency do
          case Pool.pop_next_waiting_caller(pool) do
            {%Pool.WaitingState{} = next, pool} ->
              pool = Pool.reply_runner_checkout(pool, runner, next.from, next.monitor_ref)
              {:cont, {pool, assigned_concurrency + 1}}

            {nil, pool} ->
              {:halt, {pool, assigned_concurrency}}
          end
        else
          _ -> {:halt, {pool, assigned_concurrency}}
        end
      end)

    pool
  end

  def desired_count(%Pool{} = pool, _opts) do
    Pool.runner_count(pool) + 1
  end

  defp min_runner(pool) do
    if map_size(pool.runners) == 0 do
      nil
    else
      {_ref, min} =
        Enum.min_by(pool.runners, fn {_, %Pool.RunnerState{count: count}} -> count end)

      min
    end
  end
end
