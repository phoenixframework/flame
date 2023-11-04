defmodule Dragonfly.Backend do
  @callback init(Runner.t(), opts :: Keyword.t()) :: {:ok, state :: term()} | {:error, term()}
  @callback remote_spawn_monitor(state :: term, func :: function() | term) ::
              {:ok, {pid, reference()}} | {:error, reason :: term}
  @callback system_shutdown() :: no_return()
  @callback remote_boot(state :: term) ::
              {:ok, remote_terminator_pid :: pid(), new_state :: term} | {:error, term}
  @callback handle_info(msg :: term, state :: term) ::
              {:noreply, new_state :: term} | {:stop, term, new_state :: term}

  def init(opts), do: impl().init(opts)

  def remote_spawn_monitor(state, func) do
    impl().remote_spawn_monitor(state, func)
  end

  def system_shutdown do
    impl().system_shutdown()
  end

  def remote_boot(state) do
    impl().remote_boot(state)
  end

  def handle_info(msg, state) do
    impl().handle_info(msg, state)
  end

  def impl, do: Application.get_env(:dragonfly, :backend, Dragonfly.LocalBackend)
end
