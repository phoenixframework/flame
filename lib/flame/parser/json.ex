defmodule FLAME.Parser.JSON do
  @moduledoc false

  @doc """
    Encodes data to JSON
    example:
    iex> Flame.Parser.JSON.encode!(%{a: 1, b: 2})
    "{\"a\":1,\"b\":2}"
  """

  if Code.ensure_loaded?(:json) do
    def encode!(data) do
      data
      |> :json.encode()
      |> IO.iodata_to_binary()
    end
  else
    def encode!(data), do: Jason.encode!(data)
  end

  @doc """
    Decodes data from JSON
    example:
    iex> Flame.Parser.JSON.decode!("{\"a\":1,\"b\":2}")
    %{"a" => 1, "b" => 2}
  """

  if Code.ensure_loaded?(:json) do
    def decode!(data) do
      data
      |> :json.decode()
    end
  else
    def decode!(data), do: Jason.decode!(data)
  end

  def json_parser do
    if Code.ensure_loaded?(:json) do
      :json
    else
      Jason
    end
  end
end
