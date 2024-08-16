defmodule FLAME.Pool.Strategy do
  alias FLAME.Pool

  @type action ::
          :wait
          | :scale
          | {:checkout, Pool.RunnerState.t()}
          | {{:checkout, Pool.RunnerState.t()}, :scale}

  @callback checkout_runner(state :: Pool.t(), opts :: Keyword.t()) :: action

  @callback assign_waiting_callers(
              state :: Pool.t(),
              runner :: Pool.RunnerState.t(),
              opts :: Keyword.t()
            ) ::
              Pool.t()

  @callback desired_count(state :: Pool.t(), opts :: Keyword.t()) :: non_neg_integer()
end
