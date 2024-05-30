defmodule FLAME.CodeSync do
  @moduledoc false
  alias FLAME.CodeSync

  defstruct beams: [],
            hashes: %{},
            changed_paths: [],
            deleted_paths: [],
            purge_modules: [],
            adapter: nil

  def new(
        adapter \\ %{
          beams: &beams/0,
          generate_hashes: &generate_hashes/1,
          tar_open: &:erl_tar.open/2,
          tar_add: &:erl_tar.add/3,
          tar_close: &:erl_tar.close/1
        }
      ) do
    beam_files = adapter.beams.()
    %CodeSync{adapter: adapter, beams: beam_files, hashes: adapter.generate_hashes.(beam_files)}
  end

  def diff(%CodeSync{hashes: prev_hashes} = prev) do
    current = new(prev.adapter)

    changed =
      for path <- current.beams,
          current.hashes[path] != prev_hashes[path],
          do: path

    deleted_paths =
      for path <- prev.beams, not Map.has_key?(current.hashes, path), do: path

    module_to_purge =
      for path <- deleted_paths,
          basename = Path.basename(path),
          [mod | _] = String.split(basename, ".beam"),
          mod != basename,
          do: Module.concat([mod])

    %CodeSync{
      current
      | changed_paths: changed,
        deleted_paths: deleted_paths,
        purge_modules: module_to_purge
    }
  end

  def package_to_stream(%CodeSync{beams: beams, adapter: adapter}, out_path \\ nil) do
    out_path = out_path || uniq_tmp_file("flame_code_sync", "tar.gz")
    dirs = for beam <- beams, uniq: true, do: ~c"#{Path.dirname(beam)}"
    {:ok, tar} = adapter.tar_open.(out_path, [:write, :compressed])
    for dir <- dirs, do: adapter.tar_add.(tar, dir, recursive: true)
    :ok = adapter.tar_close.(tar)

    File.stream!(out_path, [], 2048)
  end

  def uniq_tmp_file(base_name, ext) do
    Path.join([System.tmp_dir!(), "#{base_name}-#{System.unique_integer([:positive])}.#{ext}"])
  end

  def extract_packaged_stream(
        parent_stream,
        target_path \\ nil,
        tar_extract \\ &:erl_tar.extract/2
      ) do
    target_path = target_path || uniq_tmp_file("flame_code_sync", "tar.gz")
    flame_stream = File.stream!(target_path)
    # transfer the file
    Enum.into(parent_stream, flame_stream)
    :ok = tar_extract.(target_path, [{:cwd, "/"}, :compressed])
    File.rm!(target_path)
    :c.lm()
    :ok
  end

  defp beams do
    otp_lib = :code.lib_dir()

    reject_apps =
      for app <- [:flame, :eex, :elixir, :ex_unit, :iex, :logger, :mix],
          ebin = :code.lib_dir(app, :ebin),
          is_list(ebin),
          do: ebin

    :code.get_path()
    |> Kernel.--(reject_apps)
    |> Enum.reject(&(List.starts_with?(&1, otp_lib) or Enum.take(&1, -13) == ~c"/consolidated"))
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*{.app,.beam}")))
  end

  defp generate_hashes(beams) when is_list(beams) do
    Enum.into(beams, %{}, fn path -> {path, :crypto.hash(:md5, File.read!(path))} end)
  end
end
