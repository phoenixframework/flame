defprotocol FLAME.Trackable do
  @moduledoc """
  A protocol called to track resources.

  This is invoked by FLAME from `FLAME.track_resources/3`,
  which is invoked when the `:track_resources` option is
  set to true.

  Sometimes we may want to allocate long lived resources
  in a FLAME but, because FLAME nodes are temporary, the
  node would terminate shortly after. The `:track_resources`
  option tells `FLAME` to look for resources which implement
  the `FLAME.Trackable` protocol. Those resources can then
  spawn PIDs in the remote node and tell FLAME to track them.
  Once all PIDs terminate, the FLAME will terminate too.

  Implementations of the protocol will receive the data type,
  a list of pids as `acc`, and the `node`. It must return the
  updated data type and an updated list of pids. If you need
  to traverse recursively, you may call `FLAME.track_resources/3`.
  """

  @fallback_to_any true

  @doc """
  The entry point for tracking.

  See the module docs.
  """
  def track(data, acc, node)
end

defimpl FLAME.Trackable, for: Any do
  def track(data, acc, _node), do: {data, acc}
end
