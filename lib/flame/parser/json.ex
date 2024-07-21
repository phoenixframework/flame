defmodule FLAME.Parser.JSON do
  @moduledoc false
  if Code.ensure_loaded?(:json) do
    def encode!(data) do
      data
      |> :json.encode(&encoder/2)
      |> IO.iodata_to_binary()
    end

    def decode!(data) do
      data
      |> :json.decode(:ok, %{null: nil})
      |> handle_decode()
    end

    def json_parser, do: :json

    defp encoder(nil, _encoder), do: "null"
    defp encoder(term, encoder), do: :json.encode_value(term, encoder)

    defp handle_decode({data, :ok, ""}), do: data
  else
    def encode!(data), do: Jason.encode!(data)
    def decode!(data), do: Jason.decode!(data)

    def json_parser, do: Jason
  end
end
