defmodule FLAME.Test.Mod1 do
end

defmodule FLAME.Test.Mod1Modified do
end

defmodule FLAME.Test.Mod2 do
end

defmodule FLAME.Test.Mod3 do
end

defmodule FLAME.Test.CodeSyncMock do
  defstruct opts: nil, id: nil

  def new do
    id = System.unique_integer([:positive])
    tmp_dir = File.cwd!() |> Path.join("tmp") |> Path.expand()
    working_dir = tmp_dir |> Path.join("#{id}") |> Path.expand()
    File.rm_rf!(working_dir)
    mod1_dir = Path.join([working_dir, "one", "ebin"])
    mod2_dir = Path.join([working_dir, "two", "ebin"])
    File.mkdir_p!(mod1_dir)
    File.mkdir_p!(mod2_dir)

    File.write!(Path.join(mod1_dir, "Elixir.FLAME.Test.Mod1.beam"), obj_code(FLAME.Test.Mod1))
    File.write!(Path.join(mod2_dir, "Elixir.FLAME.Test.Mod2.beam"), obj_code(FLAME.Test.Mod2))

    opts = [
      get_paths: fn ->
        Enum.map(Path.wildcard(Path.join(working_dir, "*")), &String.to_charlist/1)
      end,
      tmp_dir: fn -> tmp_dir end,
      extract_dir: fn ->
        dir = Path.join([tmp_dir, "#{id}", "extracted_code"])
        File.mkdir_p!(dir)
        dir
      end
    ]

    %__MODULE__{id: id, opts: opts}
  end

  def simulate_changes(%__MODULE__{id: id} = mock) do
    # mod1 is modified
    mod1_dir = Path.join([mock.opts[:tmp_dir].(), "#{id}", "one", "ebin"])
    mod2_dir = Path.join([mock.opts[:tmp_dir].(), "#{id}", "two", "ebin"])

    File.write!(
      Path.join(mod1_dir, "Elixir.FLAME.Test.Mod1.beam"),
      obj_code(FLAME.Test.Mod1Modified)
    )

    # mod2 is deleted
    File.rm!(Path.join(mod2_dir, "Elixir.FLAME.Test.Mod2.beam"))

    # mod3 is added
    File.write!(Path.join(mod1_dir, "Elixir.FLAME.Test.Mod3.beam"), obj_code(FLAME.Test.Mod3))
    :ok
  end

  def extracted_rel_paths(%__MODULE__{} = mock) do
    extracted_beams = Path.wildcard(Path.join(mock.opts[:extract_dir].(), "**/*.beam"))

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
