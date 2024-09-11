defmodule FLAME.Test.CodeSyncMock.Mod1 do
end

defmodule FLAME.Test.CodeSyncMock.Mod1Modified do
end

defmodule FLAME.Test.CodeSyncMock.Mod2 do
end

defmodule FLAME.Test.CodeSyncMock.Mod3 do
end

defmodule FLAME.Test.CodeSyncMock do
  defstruct opts: nil, id: nil
  alias FLAME.Test.CodeSyncMock

  def new(opts \\ []) do
    test_pid = self()
    id = System.unique_integer([:positive])
    tmp_dir = File.cwd!() |> Path.join("tmp") |> Path.expand()
    working_dir = tmp_dir |> Path.join("#{id}") |> Path.expand()
    File.rm_rf!(working_dir)
    mod1_dir = Path.join([working_dir, "one", "ebin"])
    mod2_dir = Path.join([working_dir, "two", "ebin"])
    File.mkdir_p!(mod1_dir)
    File.mkdir_p!(mod2_dir)

    File.write!(
      Path.join(mod1_dir, "Elixir.FLAME.Test.CodeSyncMock.Mod1.beam"),
      obj_code(FLAME.Test.CodeSyncMock.Mod1)
    )

    File.write!(
      Path.join(mod2_dir, "Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"),
      obj_code(FLAME.Test.CodeSyncMock.Mod2)
    )

    extract_dir = Path.join([tmp_dir, "#{id}", "extracted_code"])
    File.mkdir_p!(extract_dir)

    get_path =
      fn ->
        working_dir
        |> Path.join("*/ebin")
        |> Path.wildcard()
      end

    default_opts = [
      start_apps: true,
      sync_beams: [working_dir],
      tmp_dir: {Function, :identity, [tmp_dir]},
      extract_dir: {__MODULE__, :extract_dir, [id, test_pid, extract_dir]},
      get_path: get_path
    ]

    %CodeSyncMock{id: id, opts: Keyword.merge(default_opts, opts)}
  end

  def extract_dir(id, test_pid, extract_dir) do
    send(test_pid, {CodeSyncMock, {id, :extract}})
    extract_dir
  end

  def simulate_changes(%CodeSyncMock{id: id} = mock) do
    # mod1 is modified
    mod1_dir = Path.join([mfa(mock.opts[:tmp_dir]), "#{id}", "one", "ebin"])
    mod2_dir = Path.join([mfa(mock.opts[:tmp_dir]), "#{id}", "two", "ebin"])

    File.write!(
      Path.join(mod1_dir, "Elixir.FLAME.Test.CodeSyncMock.Mod1.beam"),
      obj_code(FLAME.Test.CodeSyncMock.Mod1Modified)
    )

    # mod2 is deleted
    File.rm!(Path.join(mod2_dir, "Elixir.FLAME.Test.CodeSyncMock.Mod2.beam"))

    # mod3 is added
    File.write!(
      Path.join(mod1_dir, "Elixir.FLAME.Test.CodeSyncMock.Mod3.beam"),
      obj_code(FLAME.Test.CodeSyncMock.Mod3)
    )

    :ok
  end

  defp mfa({mod, func, args}), do: apply(mod, func, args)

  def extracted_rel_paths(%CodeSyncMock{} = mock) do
    extracted_beams = Path.wildcard(Path.join(mfa(mock.opts[:extract_dir]), "**/*.beam"))

    Enum.map(extracted_beams, fn path ->
      path
      |> Path.relative_to_cwd()
      |> Path.relative_to(Path.join(["tmp", "#{mock.id}", "extracted_code", File.cwd!()]))
      |> Path.relative_to(Path.join(["tmp", "#{mock.id}"]))
    end)
  end

  defp obj_code(mod) do
    {^mod, beam_code, _path} = :code.get_object_code(mod)
    beam_code
  end
end
