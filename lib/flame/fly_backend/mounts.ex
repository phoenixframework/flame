defmodule FLAME.FlyBackend.Mounts do
  defstruct name: nil,
            path: nil,
            volume: nil,
            extend_threshold_percent: 0,
            add_size_gb: 0,
            size_gb_limit: 0

  if Code.ensure_loaded?(:json) do
    :json.encode(Map.take(value, [
            :name,
            :path,
            :volume,
            :extend_threshold_percent,
            :add_size_gb,
            :size_gb_limit
          ]))
  else
    defimpl Jason.Encoder, for: FLAME.FlyBackend.Mounts do
      def encode(value, opts) do
        Jason.Encode.map(
          Map.take(value, [
            :name,
            :path,
            :volume,
            :extend_threshold_percent,
            :add_size_gb,
            :size_gb_limit
          ]),
          opts
        )
      end
    end
  end
end
