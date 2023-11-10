defmodule FLAME.Parent do
  @moduledoc """
  Conveniences for looking up FLAME parent information.
  """

  defstruct pid: nil, ref: nil, backend: nil

  @doc """
  Gets the `%FLAME.Parent{}` struct from the system environment.

  Returns `nil` if no parent is set.

  When booting a FLAME node, the `FLAME.Backend` is required to
  export the `DRAGONFLY_PARENT` environment variable for the provisioned
  instance. This value holds required information about the parent node
  and can be set using the `FLAME.Parent.encode/3` function.
  """
  def get do
    with {:ok, encoded} <- System.fetch_env("DRAGONFLY_PARENT"),
         {ref, pid, backend} <- encoded |> Base.decode64!() |> :erlang.binary_to_term() do
      new(ref, pid, backend)
    else
      _ -> nil
    end
  end

  @doc """
  Returns a new `%FLAME.Parent{}` struct.

  The `pid` is the parent node's `FLAME.Runner` process started by
  the `FLAME.Pool`.
  """
  def new(ref, pid, backend) when is_reference(ref) and is_pid(pid) and is_atom(backend) do
    %__MODULE__{pid: pid, ref: ref, backend: backend}
  end

  @doc """
  Encodes a `%FLAME.Parent{}` struct into string.
  """
  def encode(%__MODULE__{ref: ref, pid: pid, backend: backend}) do
    {ref, pid, backend} |> :erlang.term_to_binary() |> Base.encode64()
  end
end
