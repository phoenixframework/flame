defmodule FLAME.CodeSyncTest do
  use ExUnit.Case
  alias FLAME.CodeSync
  alias FLAME.Test.CodeSyncMock

  def rel(%CodeSyncMock{} = mock, paths) do
    Enum.map(paths, &Path.relative_to(&1, Path.join([File.cwd!(), "tmp", "#{mock.id}"])))
  end

  describe "new/0" do
    test "creates a new struct with beams and hashes" do
      mock = CodeSyncMock.new()
      code_sync = CodeSync.new(mock.opts)

      assert %CodeSync{
               beams: beams,
               hashes: %{},
               changed_paths: beams,
               deleted_paths: [],
               purge_modules: []
             } = code_sync

      assert rel(mock, beams) == [
               "one/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod1.beam",
               "two/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"
             ]
    end
  end

  test "identifies changed, added, and deleted paths" do
    mock = CodeSyncMock.new()
    previous = CodeSync.new(mock.opts)
    # simulate change to mod1, new mod3, and deleted mod2
    :ok = CodeSyncMock.simulate_changes(mock)

    current = CodeSync.diff(previous)

    assert rel(mock, current.changed_paths) == [
             "one/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod1.beam",
             "one/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod3.beam"
           ]

    assert rel(mock, current.deleted_paths) == [
             "two/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"
           ]

    assert current.purge_modules == [FLAME.Test.CodeSyncMock.Mod2]

    # new diff should have no changes
    current = CodeSync.diff(current)
    assert current.changed_paths == []
    assert current.deleted_paths == []
    assert current.purge_modules == []
  end

  test "packages and extracts packaged code" do
    mock = CodeSyncMock.new()
    code = CodeSync.new(mock.opts)
    assert %FLAME.CodeSync.PackagedStream{} = pkg = CodeSync.package_to_stream(code)
    assert File.exists?(pkg.stream.path)

    assert :ok = CodeSync.extract_packaged_stream(pkg)

    assert CodeSyncMock.extracted_rel_paths(mock) == [
             "one/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod1.beam",
             "two/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"
           ]
  end
end
