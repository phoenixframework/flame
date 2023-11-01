defmodule Dragonfly.Pool.RunnerState do
  defstruct count: nil, pid: nil, monitor_ref: nil
end

defmodule Dragonfly.Pool.WaitingState do
  defstruct from: nil, func: nil, opts: nil, monitor_ref: nil
end

defmodule Dragonfly.Pool do
  @moduledoc """
  Manages a pool of `Dragonfly.Runner`'s.

  Pools support elastic growth and shrinking of the number of runners.

  ## Examples

      children = [
        ...,
        {Dragonfly.Pool, name: MyRunner, min: 1, max: 10, max_concurrency: 100}
      ]

  # TODO spin down after inactive_shutdown
  """
  use GenServer

  alias Dragonfly.{Pool, Runner}
  alias Dragonfly.Pool.{RunnerState, WaitingState}

  @default_timeout 20_000
  @default_max_concurrency 100
  @boot_timeout 20_000
  @idle_shutdown_after 20_000
  @ok_async_call :ok_async_call

  defstruct name: nil,
            dynamic_sup: nil,
            task_sup: nil,
            boot_timeout: nil,
            idle_shutdown_after: nil,
            min: nil,
            max: nil,
            max_concurrency: nil,
            callers: %{},
            waiting: [],
            runners: %{},
            runner_opts: []

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :name)},
      start: {Dragonfly.Pool.Supervisor, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  TODO
  """
  def start_link(opts) do
    Keyword.validate!(opts, [
      :name,
      :dynamic_sup,
      :task_sup,
      :idle_shutdown_after,
      :min,
      :max,
      :max_concurrency,
      :backend,
      :log,
      :single_use,
      :timeout,
      :connect_timeout,
      :shutdown_timeout
    ])

    GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
  end

  @doc """
  TODO
  """
  def call(name, func, opts \\ []) do
    case GenServer.call(name, {:call, func, opts}, opts[:timeout] || @default_timeout) do
      {:ok, res} -> res
      {:exit, reason} -> exit(reason)
    end
  end

  @impl true
  def init(opts) do
    state = %Pool{
      dynamic_sup: Keyword.fetch!(opts, :dynamic_sup),
      task_sup: Keyword.fetch!(opts, :task_sup),
      name: Keyword.fetch!(opts, :name),
      min: Keyword.fetch!(opts, :min),
      max: Keyword.fetch!(opts, :max),
      boot_timeout: Keyword.get(opts, :connect_timeout, @boot_timeout),
      idle_shutdown_after: Keyword.get(opts, :idle_shutdown_after, @idle_shutdown_after),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      runner_opts:
        Keyword.take(
          opts,
          [
            :backend,
            :log,
            :single_use,
            :timeout,
            :connect_timeout,
            :shutdown_timeout,
            :idle_shutdown_after,
            :task_sup
          ]
        )
    }

    {:ok, boot_runners(state)}
  end

  @impl true
  def handle_info({task_ref, @ok_async_call}, state) do
    state =
      case state.callers do
        # we already replied to caller on success inside task
        %{^task_ref => {_from, runner_ref}} ->
          Process.demonitor(task_ref, [:flush])
          new_state = %Pool{state | callers: Map.delete(state.callers, task_ref)}

          new_state
          |> dec_runner_count(runner_ref)
          |> flush_downs()
          |> call_next_waiting_caller()

        %{} ->
          state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason} = msg, %Pool{} = state) do
    callers_before = state.callers

    new_state =
      state
      |> handle_down(msg)
      |> flush_downs()

    if callers_before != new_state.callers do
      {:noreply, call_next_waiting_caller(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_call({:call, func, opts}, from, state) do
    {:noreply, call_runner(state, from, func, opts)}
  end

  defp min_runner(state) do
    if map_size(state.runners) == 0 do
      nil
    else
      {_ref, min} = Enum.min_by(state.runners, fn {_, %RunnerState{count: count}} -> count end)
      min
    end
  end

  defp call_runner(%Pool{} = state, from, func, opts) do
    min_runner = min_runner(state)
    runner_count = map_size(state.runners)

    cond do
      runner_count == 0 || (min_runner.count == state.max_concurrency && runner_count < state.max) ->
        case start_child_runner(state) do
          {:ok, %RunnerState{} = runner} ->
            state
            |> put_runner(runner)
            |> async_runner_call(runner, from, func, opts)

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            state
        end

      min_runner && min_runner.count < state.max_concurrency ->
        async_runner_call(state, min_runner, from, func, opts)

      true ->
        waiting_in(state, from, func, opts)
    end
  end

  defp async_runner_call(state, %RunnerState{monitor_ref: runner_ref} = runner, from, func, opts)
       when is_function(func, 0) do
    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        result = Runner.call(runner.pid, func, opts[:timeout])
        # reply directly to caller here to avoid copying
        GenServer.reply(from, {:ok, result})
        @ok_async_call
      end)

    new_state = %Pool{state | callers: Map.put(state.callers, task.ref, {from, runner_ref})}
    inc_runner_count(new_state, runner_ref)
  end

  defp waiting_in(%Pool{} = state, {pid, _tag} = from, func, opts) when is_function(func, 0) do
    ref = Process.monitor(pid)
    waiting = %WaitingState{from: from, func: func, opts: opts, monitor_ref: ref}
    %Pool{state | waiting: state.waiting ++ [waiting]}
  end

  defp boot_runners(%Pool{} = state) do
    if state.min > 0 do
      # start min runners, and do not idle them down regardless of idle configuration
      0..(state.min - 1)
      |> Task.async_stream(fn _ -> start_child_runner(state, idle_shutdown_after: nil) end,
        max_concurrency: 10,
        timeout: state.boot_timeout
      )
      |> Enum.reduce(state, fn
        {:ok, {:ok, %RunnerState{} = runner}}, acc -> put_runner(acc, runner)
        {:exit, reason}, _acc -> raise "failed to boot runner: #{inspect(reason)}"
      end)
    else
      state
    end
  end

  defp start_child_runner(%Pool{} = state, runner_opts \\ []) do
    opts = Keyword.merge(state.runner_opts, runner_opts)

    name = Module.concat(state.name, "Runner#{map_size(state.runners) + 1}")

    spec = %{
      id: name,
      start: {Dragonfly.Runner, :start_link, [opts]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(state.dynamic_sup, spec)
    ref = Process.monitor(pid)

    try do
      :ok = Runner.remote_boot(pid)
      runner = %RunnerState{count: 0, pid: pid, monitor_ref: ref}
      {:ok, runner}
    catch
      {:exit, reason} ->
        Process.demonitor(ref, [:flush])
        {:error, {:exit, reason}}
    end
  end

  defp put_runner(%Pool{} = state, %RunnerState{} = runner) do
    %Pool{state | runners: Map.put(state.runners, runner.monitor_ref, runner)}
  end

  defp inc_runner_count(%Pool{} = state, ref) do
    new_runners =
      Map.update!(state.runners, ref, fn %RunnerState{} = runner ->
        %RunnerState{runner | count: runner.count + 1}
      end)

    %Pool{state | runners: new_runners}
  end

  defp dec_runner_count(%Pool{} = state, ref) do
    new_runners =
      Map.update!(state.runners, ref, fn %RunnerState{} = runner ->
        %RunnerState{runner | count: runner.count - 1}
      end)

    %Pool{state | runners: new_runners}
  end

  defp drop_child_runner(%Pool{} = state, ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    %Pool{state | runners: Map.delete(state.runners, ref)}
  end

  defp notify_caller(%Pool{} = state, task_ref, runner_ref, from, reply) do
    GenServer.reply(from, reply)
    new_state = %Pool{state | callers: Map.delete(state.callers, task_ref)}
    dec_runner_count(new_state, runner_ref)
  end

  defp call_next_waiting_caller(%Pool{} = state) do
    case state.waiting do
      [] ->
        state

      [%WaitingState{} = first | rest] ->
        Process.demonitor(first.monitor_ref, [:flush])
        call_runner(%Pool{state | waiting: rest}, first.from, first.func, first.opts)
    end
  end

  defp handle_down(%Pool{} = state, {:DOWN, ref, :process, _pid, reason}) do
    new_waiting =
      Enum.filter(state.waiting, fn %WaitingState{} = waiting ->
        waiting.monitor_ref != ref
      end)

    state = %Pool{state | waiting: new_waiting}

    state =
      case state.callers do
        %{^ref => {from, runner_ref}} ->
          notify_caller(state, ref, runner_ref, from, {:exit, reason})

        %{} ->
          state
      end

    case state.runners do
      %{^ref => _} -> drop_child_runner(state, ref)
      %{} -> state
    end
  end

  defp flush_downs(%Pool{} = state) do
    receive do
      {:DOWN, _ref, :process, _pid, _reason} = msg ->
        state
        |> handle_down(msg)
        |> flush_downs()
    after
      0 -> state
    end
  end
end
