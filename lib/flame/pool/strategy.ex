defmodule FLAME.Pool.Strategy do
  alias FLAME.Pool

  @type action ::
          :wait
          | :scale
          | {:checkout, Pool.RunnerState.t()}
          | {{:checkout, Pool.RunnerState.t()}, :scale}

  @callback checkout_runner(state :: Pool.t(), opts :: Keyword.t()) :: action

  @type pop_next_waiting_caller_fun :: (Pool.t() -> {Pool.WaitingState.t() | nil, Pool.t()})
  @type reply_runner_checkout_fun ::
          (Pool.t(), Pool.RunnerState.t(), pid(), reference() -> Pool.t())

  @callback assign_waiting_callers(
              state :: Pool.t(),
              runner :: Pool.RunnerState.t(),
              pop_next_waiting_caller :: pop_next_waiting_caller_fun(),
              reply_runner_checkout :: reply_runner_checkout_fun(),
              opts :: Keyword.t()
            ) ::
              Pool.t()

  @callback desired_count(state :: Pool.t(), opts :: Keyword.t()) :: non_neg_integer()
end
