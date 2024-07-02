defmodule MyTrackable do
  defstruct [:pid, :ref, :name]

  defimpl FLAME.Trackable do
    def track(%{ref: ref, name: name} = data, acc, node) do
      ^node = node(ref)
      parent = self()

      {pid, monitor_ref} =
        Node.spawn_monitor(node, fn ->
          Process.register(self(), name)
          send(parent, {ref, :started})

          receive do
            {^ref, :stop} -> :ok
          end
        end)

      receive do
        {^ref, :started} ->
          Process.demonitor(monitor_ref)
          {%{data | pid: pid}, [pid | acc]}

        {:DOWN, ^monitor_ref, _, _, reason} ->
          exit(reason)
      end
    end
  end
end
