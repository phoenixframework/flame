defmodule FLAME.CodeSync.PackagedStream do
  @moduledoc false
  defstruct stream: nil,
            id: nil,
            extract_dir: nil,
            tmp_dir: nil,
            apps_to_start: [],
            changed_paths: [],
            deleted_paths: [],
            purge_modules: [],
            verbose: false
end

defmodule FLAME.CodeSync do
  @moduledoc false
  require Logger

  alias FLAME.CodeSync
  alias FLAME.CodeSync.PackagedStream

  defstruct id: nil,
            sync_beam_hashes: {},
            copy_paths: nil,
            sync_beams: nil,
            extract_dir: nil,
            tmp_dir: nil,
            start_apps: true,
            apps_to_start: [],
            changed_paths: [],
            deleted_paths: [],
            purge_modules: [],
            verbose: false

  def new(opts \\ []) do
    Keyword.validate!(opts, [
      :tmp_dir,
      :extract_dir,
      :copy_paths,
      :sync_beams,
      :start_apps,
      :verbose
    ])

    copy_paths =
      case Keyword.fetch(opts, :copy_paths) do
        val when val in [{:ok, false}, :error] ->
          []

        {:ok, paths} when is_list(paths) ->
          paths

        {:ok, true} ->
          otp_lib = :code.lib_dir()

          reject_apps =
            for app <- [:flame, :eex, :elixir, :ex_unit, :iex, :logger, :mix],
                ebin = :code.lib_dir(app, :ebin),
                is_list(ebin),
                do: ebin

          :code.get_path()
          |> Kernel.--([~c"." | reject_apps])
          |> Enum.reject(fn path -> List.starts_with?(path, otp_lib) end)
          |> Enum.map(&to_string/1)
      end

    compute_changes(%CodeSync{
      id: System.unique_integer([:positive]),
      copy_paths: copy_paths,
      sync_beams: Keyword.get(opts, :sync_beams, []),
      tmp_dir: Keyword.get(opts, :tmp_dir, &System.tmp_dir!/0),
      extract_dir: Keyword.get(opts, :extract_dir, fn -> "/" end),
      start_apps: Keyword.get(opts, :start_apps, true),
      verbose: Keyword.get(opts, :verbose, false)
    })
  end

  def compute_changes(%CodeSync{} = code) do
    copy_files = lookup_copy_files(code.copy_paths)
    sync_beams_files = lookup_sync_beams_files(code.sync_beams)
    all_paths = Enum.uniq(copy_files ++ sync_beams_files)

    beam_hashes =
      for path <- sync_beams_files,
          into: %{},
          do: {path, :erlang.md5(File.read!(path))}

    apps_to_start =
      case code.start_apps do
        true ->
          Enum.map(Application.started_applications(), fn {app, _desc, _vsn} -> app end)

        false ->
          []

        apps when is_list(apps) ->
          apps
      end

    %CodeSync{
      code
      | changed_paths: all_paths,
        sync_beam_hashes: beam_hashes,
        apps_to_start: apps_to_start
    }
  end

  def changed?(%CodeSync{} = code) do
    code.changed_paths != [] or code.deleted_paths != [] or code.purge_modules != []
  end

  def diff(%CodeSync{sync_beam_hashes: prev_hashes} = prev) do
    current = compute_changes(%CodeSync{prev | copy_paths: []})

    changed =
      for kv <- current.sync_beam_hashes,
          {path, current_hash} = kv,
          current_hash != prev_hashes[path],
          do: path

    deleted_paths =
      for kv <- prev.sync_beam_hashes,
          {path, _prev_hash} = kv,
          not Map.has_key?(current.sync_beam_hashes, path),
          do: path

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
        purge_modules: module_to_purge,
        apps_to_start: []
    }
  end

  def package_to_stream(%CodeSync{} = code) do
    verbose =
      if code.verbose do
        log_verbose("packaging changed_paths: #{inspect(code.changed_paths)}")
        log_verbose("sending apps_to_start: #{inspect(code.apps_to_start)}")

        [:verbose]
      else
        []
      end

    out_stream =
      if code.changed_paths != [] do
        out_path = Path.join([code.tmp_dir.(), "flame_parent_code_sync_#{code.id}.tar.gz"])
        dirs = for path <- code.changed_paths, uniq: true, do: String.to_charlist(path)
        {:ok, tar} = :erl_tar.open(out_path, [:write, :compressed])
        for dir <- dirs, do: :erl_tar.add(tar, dir, trim_leading_slash(dir), verbose)
        :ok = :erl_tar.close(tar)

        File.stream!(out_path, [], 2048)
      end

    %PackagedStream{
      id: code.id,
      tmp_dir: code.tmp_dir,
      extract_dir: code.extract_dir,
      changed_paths: code.changed_paths,
      deleted_paths: code.deleted_paths,
      purge_modules: code.purge_modules,
      apps_to_start: code.apps_to_start,
      stream: out_stream,
      verbose: code.verbose
    }
  end

  defp trim_leading_slash([?/ | path]), do: path
  defp trim_leading_slash([_ | _] = path), do: path

  def extract_packaged_stream(%PackagedStream{} = pkg) do
    if pkg.stream do
      verbose = if pkg.verbose, do: [:verbose], else: []
      extract_dir = pkg.extract_dir.()
      target_tmp_path = Path.join([pkg.tmp_dir.(), "flame_child_code_sync_#{pkg.id}.tar.gz"])
      flame_stream = File.stream!(target_tmp_path)
      # transfer the file
      Enum.into(pkg.stream, flame_stream)

      # extract tar
      :ok = :erl_tar.extract(target_tmp_path, [{:cwd, extract_dir}, :compressed | verbose])

      # add code paths
      :ok = add_code_paths_from_tar(pkg, extract_dir)

      File.rm!(target_tmp_path)

      # purge any deleted modules
      for mod <- pkg.purge_modules do
        if pkg.verbose, do: log_verbose("purging #{inspect(pkg.purge_modules)}")
        :code.purge(mod)
        :code.delete(mod)
      end

      # delete any deleted code paths, and prune empty dirs
      for del_path <- pkg.deleted_paths do
        File.rm!(del_path)
        ebin_dir = Path.dirname(del_path)

        if File.ls!(ebin_dir) == [] do
          if pkg.verbose, do: log_verbose("deleting path #{ebin_dir}")
          File.rm_rf!(ebin_dir)
          :code.del_path(String.to_charlist(ebin_dir))
        end
      end

      # reload any changed code
      reloaded = :c.lm()
      if pkg.verbose && reloaded != [], do: log_verbose("reloaded #{inspect(reloaded)}")
    end

    # start any synced apps
    if pkg.apps_to_start != [] do
      {:ok, started} = Application.ensure_all_started(pkg.apps_to_start)
      if pkg.verbose, do: log_verbose("started #{inspect(started)}")
    end

    :ok
  end

  def rm_packaged_stream!(%PackagedStream{} = pkg) do
    if pkg.stream, do: File.rm!(pkg.stream.path)
    :ok
  end

  defp lookup_sync_beams_files(paths) do
    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.beam")))
    |> Enum.uniq()
  end

  defp lookup_copy_files(paths) do
    # include ebin's parent if basename is ebin (will include priv)
    paths
    |> Stream.map(fn parent_dir ->
      case Path.basename(parent_dir) do
        "ebin" -> Path.join(Path.dirname(parent_dir), "**/*")
        _ -> Path.join(parent_dir, "*")
      end
    end)
    |> Stream.uniq()
    |> Stream.flat_map(fn glob -> Path.wildcard(glob) end)
    |> Stream.uniq()
    |> Enum.filter(fn path -> File.regular?(path, [:raw]) end)
  end

  defp add_code_paths_from_tar(%PackagedStream{} = pkg, extract_dir) do
    current_code_paths = Enum.map(:code.get_path(), &to_string/1)

    changed_code_paths =
      pkg.changed_paths
      |> Enum.map(fn rel_path ->
        dir = extract_dir |> Path.join(rel_path) |> Path.dirname()

        # todo filter only ebins

        # purge consolidated protocols
        with "consolidated" <- Path.basename(dir),
             [mod_str, ""] <- rel_path |> Path.basename() |> String.split(".beam") do
          mod = Module.concat([mod_str])
          if pkg.verbose, do: log_verbose("purging consolidated protocol #{inspect(mod)}")
          :code.purge(mod)
          :code.delete(mod)
        end

        dir
      end)
      |> Enum.uniq()
      |> then(fn uniq_paths ->
        if pkg.verbose, do: log_verbose("adding code paths: #{inspect(uniq_paths)}")
        uniq_paths
      end)

    Enum.uniq(current_code_paths ++ changed_code_paths)
    |> Enum.reverse()
    |> Code.prepend_paths(cache: true)
  end

  defp log_verbose(msg) do
    Logger.info("[CodeSync #{inspect(node())}] #{msg}")
  end
end
