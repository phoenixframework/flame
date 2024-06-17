defmodule FLAME.CodeSync.PackagedStream do
  @moduledoc false
  defstruct stream: nil,
            id: nil,
            extract_dir: nil,
            tmp_dir: nil,
            apps_to_start: [],
            changed_paths: [],
            sync_beam_hashes: %{},
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
            sync_beam_hashes: %{},
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
      case Keyword.get(opts, :copy_paths, false) do
        paths when is_list(paths) ->
          paths

        false ->
          []

        true ->
          otp_lib = :code.lib_dir()

          reject_apps =
            for app <- [:flame, :eex, :elixir, :ex_unit, :iex, :logger, :mix],
                lib_dir = :code.lib_dir(app),
                is_list(lib_dir),
                do: :filename.join(lib_dir, ~c"ebin")

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
          do: path |> Path.basename(".beam") |> String.to_atom()

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
        if !Enum.empty?(code.changed_paths),
          do: log_verbose("packaging changed_paths: #{inspect(code.changed_paths)}")

        if !Enum.empty?(code.apps_to_start),
          do: log_verbose("sending apps_to_start: #{inspect(code.apps_to_start)}")

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
      sync_beam_hashes: code.sync_beam_hashes,
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

      File.rm(target_tmp_path)

      # purge any deleted modules
      for mod <- pkg.purge_modules do
        if pkg.verbose && !Enum.empty?(pkg.purge_modules),
          do: log_verbose("purging #{inspect(pkg.purge_modules)}")

        :code.purge(mod)
        :code.delete(mod)
      end

      # delete any deleted code paths, and prune empty dirs
      for del_path <- pkg.deleted_paths do
        File.rm(del_path)
        ebin_dir = Path.dirname(del_path)

        if File.ls!(ebin_dir) == [] do
          if pkg.verbose, do: log_verbose("deleting path #{ebin_dir}")
          File.rm_rf(ebin_dir)
          :code.del_path(String.to_charlist(ebin_dir))
        end
      end
    end

    # start any synced apps
    if !Enum.empty?(pkg.apps_to_start) do
      {:ok, started} = Application.ensure_all_started(pkg.apps_to_start)
      if pkg.verbose, do: log_verbose("started #{inspect(started)}")
    end

    :ok
  end

  def rm_packaged_stream(%PackagedStream{} = pkg) do
    if pkg.stream, do: File.rm(pkg.stream.path)
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
    init = {_consolidated = [], _regular = [], _beams = [], _reload = [], _seen = MapSet.new()}

    Enum.reduce(pkg.changed_paths, init, fn rel_path, {cons, reg, beams, reload, seen} ->
      new_seen = MapSet.put(seen, rel_path)
      dir = extract_dir |> Path.join(rel_path) |> Path.dirname()

      new_reload =
        case rel_path |> Path.basename() |> String.split(".beam") do
          [mod_str, ""] ->
            mod = Module.concat([mod_str])
            :code.purge(mod)
            :code.delete(mod)
            [mod | reload]

          _ ->
            reload
        end

      cond do
        # purge consolidated protocols
        MapSet.member?(seen, rel_path) ->
          {cons, reg, beams, new_reload, seen}

        Path.basename(dir) == "consolidated" ->
          {[dir | cons], reg, beams, new_reload, new_seen}

        pkg.sync_beam_hashes[rel_path] ->
          {cons, reg, [dir | beams], new_reload, new_seen}

        true ->
          {cons, [dir | reg], beams, new_reload, new_seen}
      end
    end)
    |> then(fn {consolidated, regular, sync_beams, reload, _seen} ->
      # paths already in reverse order, which is what we want for prepend
      if pkg.verbose do
        if !Enum.empty?(consolidated),
          do: log_verbose("prepending consolidated paths: #{inspect(consolidated)}")

        if !Enum.empty?(regular),
          do: log_verbose("appending code paths: #{inspect(regular)}")

        if !Enum.empty?(sync_beams),
          do: log_verbose("reloading code paths: #{inspect(sync_beams)}")
      end

      Code.prepend_paths(regular, cache: true)
      Code.prepend_paths(consolidated, cache: true)
      # don't cache for sync_beams
      Code.prepend_paths(sync_beams)

      if pkg.verbose && !Enum.empty?(reload), do: log_verbose("reloading #{inspect(reload)}")
      for mod <- reload, do: :code.load_file(mod)

      :ok
    end)
  end

  defp log_verbose(msg) do
    Logger.info("[CodeSync #{inspect(node())}] #{msg}")
  end
end
