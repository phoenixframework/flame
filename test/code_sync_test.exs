defmodule FLAME.CodeSyncTest do
  use ExUnit.Case, async: false
  alias FLAME.CodeSync
  alias FLAME.Test.CodeSyncMock

  def rel(%CodeSyncMock{} = mock, paths) do
    Enum.map(paths, &Path.relative_to(&1, Path.join([File.cwd!(), "tmp", "#{mock.id}"])))
  end

  def started_apps do
    Enum.map(Application.started_applications(), fn {app, _desc, _vsn} -> app end)
  end

  setup do
    Application.ensure_started(:logger)
  end

  describe "new/0" do
    test "creates a new struct with change tracking" do
      mock = CodeSyncMock.new()
      code_sync = CodeSync.new(mock.opts)

      assert %CodeSync{
               sync_beam_hashes: %{},
               changed_paths: changed_paths,
               deleted_paths: [],
               purge_modules: []
             } = code_sync

      assert code_sync.apps_to_start == started_apps()

      assert rel(mock, changed_paths) == [
               "one/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod1.beam",
               "two/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"
             ]
    end
  end

  test "identifies changed, added, and deleted beams" do
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
    assert current.apps_to_start == []
  end

  test "start_apps: false, does not sync started apps" do
    # cheap way to ensure apps are started on extract. Note async: false is required
    Application.stop(:logger)
    refute :logger in started_apps()
    mock = CodeSyncMock.new(start_apps: false)
    previous = CodeSync.new(mock.opts)
    assert previous.apps_to_start == []

    Application.ensure_started(:logger)
    current = CodeSync.diff(previous)
    assert current.apps_to_start == []
  end

  test "start_apps with a list syncs listed apps" do
    # cheap way to ensure apps are started on extract. Note async: false is required
    Application.stop(:logger)
    refute :logger in started_apps()
    mock = CodeSyncMock.new(start_apps: [:logger])
    previous = CodeSync.new(mock.opts)
    assert previous.apps_to_start == [:logger]

    Application.ensure_started(:logger)
    current = CodeSync.diff(previous)
    assert current.apps_to_start == []
  end

  test "packages and extracts packaged code and starts apps by default" do
    assert :logger in started_apps()
    mock = CodeSyncMock.new()
    code = CodeSync.new(mock.opts)
    assert %FLAME.CodeSync.PackagedStream{} = pkg = CodeSync.package_to_stream(code)
    assert File.exists?(pkg.stream.path)

    # cheap way to ensure apps are started on extract. Note async: false is required
    Application.stop(:logger)
    refute :logger in started_apps()

    assert :ok = CodeSync.extract_packaged_stream(pkg)

    assert CodeSyncMock.extracted_rel_paths(mock) == [
             "one/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod1.beam",
             "two/ebin/Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"
           ]

    assert :logger in started_apps()
  end
end
