defmodule Dragonfly.Backend do
  @callback init(opts :: Keyword.t()) :: {:ok, state :: term()} | {:error, term()}
  @callback remote_spawn_link(state :: term, func :: function() | term) ::
              {:ok, pid, new_state :: term} | {:error, reason :: term, new_state :: term}
  @callback system_shutdown() :: no_return()
  @callback remote_boot(state :: term) :: {:ok, new_state :: term} | {:error, term}
  @callback handle_info(msg :: term, state :: term) ::
              {:noreply, new_state :: term} | {:stop, term, new_state :: term}

  def init(opts), do: impl().init(opts)

  def remote_spawn_link(state, func) do
    impl().remote_spawn_link(state, func)
  end

  def system_shutdown do
    impl().system_shutdown()
  end

  def remote_boot(state) do
    impl().remote_boot(state)
  end

  def impl, do: Application.get_env(:dragonfly, :backend, Dragonfly.LocalBackend)
end
