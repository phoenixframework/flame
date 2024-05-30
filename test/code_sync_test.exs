defmodule FLAME.CodeSyncTest do
  use ExUnit.Case
  alias FLAME.CodeSync

  describe "new/0" do
    test "creates a new struct with beams and hashes" do
      adapter = FLAME.CodeSyncMock.mock_adapter()
      mock_beam_files = adapter.beams.()
      mock_hashes = adapter.generate_hashes.(mock_beam_files)
      code_sync = CodeSync.new(adapter)

      assert %CodeSync{
               beams: ^mock_beam_files,
               hashes: ^mock_hashes,
               changed_paths: [],
               deleted_paths: [],
               purge_modules: []
             } = code_sync
    end
  end

  test "identifies changed, added, and deleted paths" do
    adapter = FLAME.CodeSyncMock.mock_adapter()
    previous = CodeSync.new(adapter)
    # simulate change to mod1, new mod3, and deleted mod2
    Agent.update(adapter.agent, fn _ ->
      [
        {"path/to/Elixir.Mod1.beam", :crypto.hash(:md5, "newdummy1")},
        {"path/to/Elixir.NewMod3.beam", :crypto.hash(:md5, "dummy3")}
      ]
    end)

    current = CodeSync.diff(previous)

    assert current.changed_paths == ["path/to/Elixir.Mod1.beam", "path/to/Elixir.NewMod3.beam"]
    assert current.deleted_paths == ["path/to/Elixir.Mod2.beam"]
    assert current.purge_modules == [Mod2]

    current = CodeSync.diff(current)
    assert current.changed_paths == []
    assert current.deleted_paths == []
    assert current.purge_modules == []
  end

  test "packages and extracts packaged code", config do
    out_file = String.replace(to_string(config.test), ~r/[^\w-]+/, "_")
    out_path = "tmp/#{out_file}.tar"
    File.rm(out_path)
    adapter = FLAME.CodeSyncMock.mock_adapter()
    code = CodeSync.new(adapter)
    refute File.exists?(out_path)
    assert %File.Stream{} = stream = CodeSync.package_to_stream(code, out_path)
    assert stream.path == out_path
    assert File.exists?(out_path)

    extract = fn path, _opts -> File.write!("#{path}.extracted", "extracted!") end

    target_path = "tmp/#{out_file}_extract.tar.gz"
    assert :ok = CodeSync.extract_packaged_stream(stream, target_path, extract)
    refute File.exists?(target_path)
    assert File.read!("#{target_path}.extracted") == "extracted!"
  end
end
