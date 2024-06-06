defmodule FLAME.Parser.JSON do
  @moduledoc """
    JSON parser for Flame, based on erlang OTP 27
  """

  @doc """
    Encodes data to JSON
    example:
    iex> Flame.Parser.JSON.encode!(%{a: 1, b: 2})
    "{\"a\":1,\"b\":2}"
  """
  @spec encode!(any) :: iodata()
  def encode!(data) do
    data
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @doc """
    Decodes data from JSON
    example:
    iex> Flame.Parser.JSON.decode!("{\"a\":1,\"b\":2}")
    %{"a" => 1, "b" => 2}
  """
  @spec decode!(iodata()) :: any()
  def decode!(data) do
    :json.decode(data)
  end
end
