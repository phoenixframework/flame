defmodule Dragonfly.Parent do
  @moduledoc """
  TODO
  """

  defstruct pid: nil, ref: nil, backend: nil

  @doc """
  TODO
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
  TODO
  """
  def new(ref, pid, backend) when is_reference(ref) and is_pid(pid) and is_atom(backend) do
    %__MODULE__{pid: pid, ref: ref, backend: backend}
  end

  @doc """
  TODO
  """
  def encode(ref, pid, backend) when is_reference(ref) and is_pid(pid) and is_atom(backend) do
    {ref, pid, backend} |> :erlang.term_to_binary() |> Base.encode64()
  end
end
