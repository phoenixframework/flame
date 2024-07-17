defmodule FLAME.Parser.JSON do
  @moduledoc false

  if Code.ensure_loaded?(:json) do
    def encode!(data) do
      data
      |> normalize_nullable()
      |> :json.encode()
      |> IO.iodata_to_binary()
    end

    def decode!(data) do
      data
      |> :json.decode()
      |> normalize_nullable()
    end

    def json_parser, do: :json

    defp normalize_nullable(data) when is_map(data) do
      for {key, value} <- data, into: %{}, do: {key, normalize_nullable(value)}
    end

    defp normalize_nullable(data) when is_list(data) do
      for value <- data, into: [], do: normalize_nullable(value)
    end

    defp normalize_nullable(:null), do: nil
    defp normalize_nullable(nil), do: :null
    defp normalize_nullable(data), do: data
  else
    def encode!(data), do: Jason.encode!(data)
    def decode!(data), do: Jason.decode!(data)

    def json_parser, do: Jason
  end
end
