defmodule FLAME.CodeSyncMock do
  def mock_adapter do
    agent =
      ExUnit.Callbacks.start_supervised!(
        {Agent,
         fn ->
           [
             {"path/to/Elixir.Mod1.beam", :crypto.hash(:md5, "dummy1")},
             {"path/to/Elixir.Mod2.beam", :crypto.hash(:md5, "dummy2")}
           ]
         end}
      )

    %{
      agent: agent,
      beams: fn -> for({path, _hash} <- Agent.get(agent, & &1), do: path) end,
      generate_hashes: fn _beams -> Enum.into(Agent.get(agent, & &1), %{}) end,
      tar_open: fn path, _ ->
        File.mkdir_p("tmp")
        File.touch!(path)
        {:ok, :tar_ref}
      end,
      tar_add: fn :tar_ref, _, _ -> :ok end,
      tar_close: fn :tar_ref -> :ok end
    }
  end
end
