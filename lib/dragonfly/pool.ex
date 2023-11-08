defmodule Dragonfly.Pool.RunnerState do
  defstruct count: nil, pid: nil, monitor_ref: nil
end

defmodule Dragonfly.Pool.WaitingState do
  defstruct from: nil, monitor_ref: nil
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

  @default_max_concurrency 100
  @boot_timeout 20_000
  @idle_shutdown_after 20_000

  defstruct name: nil,
            dynamic_sup: nil,
            terminator_sup: nil,
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
      :terminator_sup,
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
    opts = Keyword.put_new_lazy(opts, :timeout, fn -> lookup_boot_timeout(name) end)
    {{ref, runner_pid}, opts} =
      with_elapsed_timeout(opts, fn -> GenServer.call(name, :checkout, opts[:timeout]) end)

    result = Runner.call(runner_pid, func, opts[:timeout])
    :ok = GenServer.call(name, {:checkin, ref})
    result
  end

  defp with_elapsed_timeout(opts, func) do
    {micro, result} = :timer.tc(func)
    elapsed_ms = div(micro, 1000)

    opts =
      case Keyword.fetch(opts, :timeout) do
        {:ok, :infinity} -> opts
        {:ok, ms} when is_integer(ms) -> Keyword.put(opts, :timeout, ms - elapsed_ms)
        {:ok, nil} -> opts
        :error -> opts
      end

    {result, opts}
  end

  defp lookup_boot_timeout(name) do
    :ets.lookup_element(name, :boot_timeout, 2)
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    boot_timeout = Keyword.get(opts, :connect_timeout, @boot_timeout)
    :ets.new(name, [:set, :public, :named_table, read_concurrency: true])
    :ets.insert(name, {:boot_timeout, boot_timeout})
    terminator_sup = Keyword.fetch!(opts, :terminator_sup)
    runner_opts = runner_opts(opts, terminator_sup)
    min = Keyword.fetch!(opts, :min)

    # we must avoid recursively booting remote runners if we are a child
    min =
      if Dragonfly.Parent.get() do
        0
      else
        min
      end

    state = %Pool{
      dynamic_sup: Keyword.fetch!(opts, :dynamic_sup),
      terminator_sup: terminator_sup,
      name: name,
      min: min,
      max: Keyword.fetch!(opts, :max),
      boot_timeout: boot_timeout,
      idle_shutdown_after: Keyword.get(opts, :idle_shutdown_after, @idle_shutdown_after),
      max_concurrency: Keyword.get(opts, :max_concurrency, @default_max_concurrency),
      runner_opts: runner_opts
    }

    {:ok, boot_runners(state)}
  end

  defp runner_opts(opts, terminator_sup) do
    defaults = [terminator_sup: terminator_sup, log: Keyword.get(opts, :log, false)]

    runner_opts =
      Keyword.take(
        opts,
        [
          :backend,
          :log,
          :single_use,
          :timeout,
          :connect_timeout,
          :shutdown_timeout,
          :idle_shutdown_after
        ]
      )

    case Keyword.fetch(opts, :backend) do
      {:ok, {backend, opts}} ->
        Keyword.update!(runner_opts, :backend, {backend, Keyword.merge(opts, defaults)})

      {:ok, backend} ->
        Keyword.update!(runner_opts, :backend, {backend, defaults})

      :error ->
        backend = Dragonfly.Backend.impl()
        backend_opts = Application.get_env(:dragonfly, backend) || []
        Keyword.put(runner_opts, :backend, {backend, Keyword.merge(backend_opts, defaults)})
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason} = msg, %Pool{} = state) do
    {:noreply, handle_down(state, msg)}
  end

  @impl true
  def handle_call(:checkout, from, state) do
    {:noreply, checkout_runner(state, from)}
  end

  def handle_call({:checkin, ref}, _from, state) do
    {:reply, :ok, checkin_runner(state, ref)}
  end

  defp min_runner(state) do
    if map_size(state.runners) == 0 do
      nil
    else
      {_ref, min} = Enum.min_by(state.runners, fn {_, %RunnerState{count: count}} -> count end)
      min
    end
  end

  defp checkin_runner(state, ref) do
    %{^ref => {_from, runner_ref}} = state.callers
    Process.demonitor(ref, [:flush])

    drop_caller(state, ref, runner_ref)
  end

  defp checkout_runner(%Pool{} = state, from, monitor_ref \\ nil) do
    min_runner = min_runner(state)
    runner_count = map_size(state.runners)

    cond do
      runner_count == 0 || (min_runner.count == state.max_concurrency && runner_count < state.max) ->
        case start_child_runner(state) do
          {:ok, %RunnerState{} = runner} ->
            state
            |> put_runner(runner)
            |> reply_runner_checkout(runner, from, monitor_ref)

          {:error, reason} ->
            GenServer.reply(from, {:error, reason})
            state
        end

      min_runner && min_runner.count < state.max_concurrency ->
        reply_runner_checkout(state, min_runner, from, monitor_ref)

      true ->
        waiting_in(state, from)
    end
  end

  defp reply_runner_checkout(state, %RunnerState{} = runner, from, monitor_ref) do
    # we pass monitor_ref down from waiting so we don't need to remonitor if already monitoring
    ref =
      if monitor_ref do
        monitor_ref
      else
        {from_pid, _tag} = from
        Process.monitor(from_pid)
      end

    GenServer.reply(from, {ref, runner.pid})
    new_state = %Pool{state | callers: Map.put(state.callers, ref, {from, runner.monitor_ref})}
    inc_runner_count(new_state, runner.monitor_ref)
  end

  defp waiting_in(%Pool{} = state, {pid, _tag} = from) do
    ref = Process.monitor(pid)
    waiting = %WaitingState{from: from, monitor_ref: ref}
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

  defp drop_caller(%Pool{} = state, caller_ref, runner_ref) do
    new_state = %Pool{state | callers: Map.delete(state.callers, caller_ref)}

    new_state
    |> dec_runner_count(runner_ref)
    |> call_next_waiting_caller()
  end

  defp call_next_waiting_caller(%Pool{} = state) do
    # we flush DOWN's so we don't send a lease to a waiting caller that is already down
    new_state = flush_downs(state)

    case new_state.waiting do
      [] ->
        new_state

      [%WaitingState{} = first | rest] ->
        # checkout_runner will borrow already running monitor
        checkout_runner(%Pool{new_state | waiting: rest}, first.from, first.monitor_ref)
    end
  end

  defp handle_down(%Pool{} = state, {:DOWN, ref, :process, _pid, _reason}) do
    new_waiting =
      Enum.filter(state.waiting, fn %WaitingState{} = waiting ->
        waiting.monitor_ref != ref
      end)

    state = %Pool{state | waiting: new_waiting}

    state =
      case state.callers do
        %{^ref => {_from, runner_ref}} ->
          drop_caller(state, ref, runner_ref)

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
