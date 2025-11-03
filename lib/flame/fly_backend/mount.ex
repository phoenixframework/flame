defmodule FLAME.FlyBackend.Mount do
  # Refer to the "mount:" section most of the may down this page for how to use these keys
  # https://fly.io/docs/machines/api/machines-resource/

  alias FLAME.FlyBackend.Mount

  @derive {Inspect,
           only: [
             :volume,
             :path,
             :name,
             :extend_threshold_percent,
             :add_size_gb,
             :size_gb_limit
           ]}
  defstruct volume: nil,
            path: nil,
            name: nil,
            extend_threshold_percent: nil,
            add_size_gb: nil,
            size_gb_limit: nil

  @valid_opts [:volume, :path, :name, :extend_threshold_percent, :add_size_gb, :size_gb_limit]

  @required_opts [:path, :name]

  def parse_opts(opts) do
    default = %Mount{extend_threshold_percent: 0, add_size_gb: 0, size_gb_limit: 0}

    provided_opts = Keyword.validate!(opts, @valid_opts)

    %Mount{} = state = Map.merge(default, Map.new(provided_opts))

    for key <- @required_opts do
      unless Map.get(state, key) do
        raise ArgumentError, "missing :#{key} config for #{inspect(__MODULE__)}"
      end
    end

    state
  end
end
