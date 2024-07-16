defmodule FLAME.Parser.JSON do
  @moduledoc false

  if Code.ensure_loaded?(:json) do
    def encode!(data) do
      data
      |> :json.encode()
      |> IO.iodata_to_binary()
    end

    def decode!(data) do
      data
      |> :json.decode()
    end

    def json_parser, do: :json
  else
    def encode!(data), do: Jason.encode!(data)
    def decode!(data), do: Jason.decode!(data)

    def json_parser, do: Jason
  end
end
