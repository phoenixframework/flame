defmodule FLAME.CodeSync.PackagedStream do
  defstruct stream: nil,
            id: nil,
            extract_dir: nil,
            tmp_dir: nil,
            deleted_paths: [],
            purge_modules: []
end

defmodule FLAME.CodeSync do
  @moduledoc false
  alias FLAME.CodeSync
  alias FLAME.CodeSync.PackagedStream

  defstruct beams: [],
            hashes: %{},
            get_paths: nil,
            extract_dir: nil,
            tmp_dir: nil,
            changed_paths: [],
            deleted_paths: [],
            purge_modules: [],
            id: nil,
            opts: []

  def new(opts \\ []) do
    Keyword.validate!(opts, [:id, :tmp_dir, :extract_dir, :get_paths])
    get_paths = Keyword.get(opts, :get_paths, &:code.get_path/0)
    beam_files = beams(get_paths)
    id = opts[:id] || System.unique_integer([:positive])

    %CodeSync{
      id: id,
      opts: Keyword.put(opts, :id, id),
      tmp_dir: Keyword.get(opts, :tmp_dir, &System.tmp_dir!/0),
      extract_dir: Keyword.get(opts, :extract_dir, fn -> "/" end),
      beams: beam_files,
      hashes: generate_hashes(beam_files)
    }
  end

  def changed?(%CodeSync{} = code) do
    code.changed_paths != [] or code.deleted_paths != [] or code.purge_modules != []
  end

  def diff(%CodeSync{hashes: prev_hashes} = prev) do
    current = new(prev.opts)

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

  def package_to_stream(%CodeSync{beams: beams} = code) do
    out_path = Path.join([code.tmp_dir.(), "flame_parent_code_sync_#{code.id}.tar.gz"])
    dirs = for beam <- beams, uniq: true, do: ~c"#{Path.dirname(beam)}"
    {:ok, tar} = :erl_tar.open(out_path, [:write, :compressed])
    for dir <- dirs, do: :erl_tar.add(tar, dir, trim_leading_slash(dir), [])
    :ok = :erl_tar.close(tar)

    %PackagedStream{
      id: code.id,
      tmp_dir: code.tmp_dir,
      extract_dir: code.extract_dir,
      deleted_paths: code.deleted_paths,
      purge_modules: code.purge_modules,
      stream: File.stream!(out_path, [], 2048)
    }
  end

  defp trim_leading_slash([?/ | path]), do: path
  defp trim_leading_slash([_ | _] = path), do: path

  def extract_packaged_stream(%PackagedStream{} = pkg) do
    target_tmp_path = Path.join([pkg.tmp_dir.(), "flame_child_code_sync_#{pkg.id}.tar.gz"])
    flame_stream = File.stream!(target_tmp_path)
    # transfer the file
    Enum.into(pkg.stream, flame_stream)
    :ok = :erl_tar.extract(target_tmp_path, [{:cwd, pkg.extract_dir.()}, :compressed])
    File.rm!(target_tmp_path)
    # purge any deleted modules
    for mod <- pkg.purge_modules, do: :code.purge(mod)
    # delete any deleted code paths, and prune empty dirs
    for del_path <- pkg.deleted_paths do
      File.rm!(del_path)
      ebin_dir = Path.dirname(del_path)

      if File.ls!(ebin_dir) == [] do
        File.rm_rf!(ebin_dir)
        :code.del_path(String.to_charlist(ebin_dir))
      end
    end

    # reload any changed code
    :c.lm()
    :ok
  end

  def rm_packaged_stream!(%PackagedStream{} = pkg) do
    File.rm!(pkg.stream.path)
  end

  defp beams(get_paths) do
    otp_lib = :code.lib_dir()

    reject_apps =
      for app <- [:flame, :eex, :elixir, :ex_unit, :iex, :logger, :mix],
          ebin = :code.lib_dir(app, :ebin),
          is_list(ebin),
          do: ebin

    get_paths.()
    |> Kernel.--(reject_apps)
    |> Enum.reject(&(List.starts_with?(&1, otp_lib)))
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*{.app,.beam}")))
  end

  defp generate_hashes(beams) when is_list(beams) do
    Enum.into(beams, %{}, fn path -> {path, :crypto.hash(:md5, File.read!(path))} end)
  end
end
