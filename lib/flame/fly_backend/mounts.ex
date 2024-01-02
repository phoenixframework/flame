defmodule FLAME.FlyBackend.Mounts do
  @derive Jason.Encoder
  defstruct name: nil,
            path: nil,
            volume: nil,
            extend_threshold_percent: 0,
            add_size_gb: 0,
            size_gb_limit: 0
end
