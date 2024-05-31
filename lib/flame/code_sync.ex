defmodule FLAME.CodeSync.PackagedStream do
  @moduledoc false
  defstruct stream: nil,
            id: nil,
            extract_dir: nil,
            tmp_dir: nil,
            apps_to_start: [],
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
            beams: [],
            computed_sync_beams: MapSet.new(),
            hashes: %{},
            get_paths: nil,
            sync_paths: nil,
            extract_dir: nil,
            tmp_dir: nil,
            start_apps: true,
            started_apps: [],
            apps_to_start: [],
            changed_paths: [],
            deleted_paths: [],
            purge_modules: [],
            verbose: false

  def new(opts \\ []) do
    Keyword.validate!(opts, [
      :tmp_dir,
      :extract_dir,
      :get_paths,
      :sync_paths,
      :start_apps,
      :verbose
    ])

    get_paths_func = Keyword.get(opts, :get_paths, &:code.get_path/0)
    sync_paths_func = Keyword.get(opts, :sync_paths, get_paths_func)

    compute_changes(%CodeSync{
      id: System.unique_integer([:positive]),
      get_paths: get_paths_func,
      sync_paths: sync_paths_func,
      tmp_dir: Keyword.get(opts, :tmp_dir, &System.tmp_dir!/0),
      extract_dir: Keyword.get(opts, :extract_dir, fn -> "/" end),
      start_apps: Keyword.get(opts, :start_apps, true),
      verbose: Keyword.get(opts, :verbose, false)
    })
  end

  def compute_changes(%CodeSync{} = code) do
    {all_beams, computed_sync_beams} =
      if code.get_paths == code.sync_paths do
        all = beams(code.get_paths.())
        {all, all}
      else
        get_paths_beams = beams(code.get_paths.())
        sync_paths_beams = beams(code.sync_paths.())

        {Enum.uniq(get_paths_beams ++ sync_paths_beams), sync_paths_beams}
      end

    hashes =
      Enum.into(all_beams, %{}, fn path -> {path, :crypto.hash(:md5, File.read!(path))} end)

    started_apps =
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
      | computed_sync_beams: MapSet.new(computed_sync_beams),
        beams: all_beams,
        changed_paths: all_beams,
        hashes: hashes,
        started_apps: started_apps,
        apps_to_start: started_apps
    }
  end

  def changed?(%CodeSync{} = code) do
    code.changed_paths != [] or code.deleted_paths != [] or code.purge_modules != [] or
      code.apps_to_start != []
  end

  def diff(%CodeSync{hashes: prev_hashes} = prev) do
    current = compute_changes(%CodeSync{prev | get_paths: prev.sync_paths})

    changed =
      for path <- current.beams,
          current.hashes[path] != prev_hashes[path],
          do: path

    deleted_paths =
      for path <- prev.beams,
          not Map.has_key?(current.hashes, path) &&
            MapSet.member?(prev.computed_sync_beams, path),
          do: path

    module_to_purge =
      for path <- deleted_paths,
          basename = Path.basename(path),
          [mod | _] = String.split(basename, ".beam"),
          mod != basename,
          do: Module.concat([mod])

    apps_to_start = current.started_apps -- prev.started_apps

    %CodeSync{
      current
      | changed_paths: changed,
        deleted_paths: deleted_paths,
        apps_to_start: apps_to_start,
        purge_modules: module_to_purge
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
      if length(code.changed_paths) > 0 do
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
      :ok = add_code_paths_from_tar(pkg, target_tmp_path, extract_dir)

      File.rm!(target_tmp_path)
      # purge any deleted modules
      for mod <- pkg.purge_modules, do: :code.purge(IO.inspect(mod, label: "purge"))
      # delete any deleted code paths, and prune empty dirs
      for del_path <- pkg.deleted_paths do
        if pkg.verbose, do: log_verbose("deleting path #{del_path}")
        File.rm!(del_path)
        ebin_dir = Path.dirname(del_path)

        if File.ls!(ebin_dir) == [] do
          File.rm_rf!(ebin_dir)
          :code.del_path(String.to_charlist(ebin_dir))
        end
      end

      # reload any changed code
      reloaded_modules = :c.lm()
      if pkg.verbose, do: log_verbose("reloaded #{inspect(reloaded_modules)}")
    end

    # start any synced apps
    if length(pkg.apps_to_start) > 0 do
      {:ok, started} = Application.ensure_all_started(pkg.apps_to_start)
      if pkg.verbose, do: log_verbose("started #{inspect(started)}")
    end

    :ok
  end

  def rm_packaged_stream!(%PackagedStream{} = pkg) do
    if pkg.stream, do: File.rm!(pkg.stream.path)
    :ok
  end

  defp beams(computed_paths) do
    otp_lib = to_string(:code.lib_dir())

    reject_apps =
      for app <- [:flame, :eex, :elixir, :ex_unit, :iex, :logger, :mix],
          ebin = :code.lib_dir(app, :ebin),
          is_list(ebin),
          do: to_string(ebin)

    computed_paths
    |> Enum.map(fn
      path when is_binary(path) -> path
      path when is_list(path) -> to_string(path)
    end)
    |> Kernel.--(reject_apps)
    |> Enum.reject(&String.starts_with?(&1, otp_lib))
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*{.app,.beam}")))
  end

  defp add_code_paths_from_tar(%PackagedStream{} = pkg, tar_path, extract_dir) do
    {:ok, tab} = :erl_tar.table(tar_path, [:compressed])

    tab
    |> Enum.map(fn rel_path -> extract_dir |> Path.join(to_string(rel_path)) |> Path.dirname() end)
    |> Enum.uniq()
    |> then(fn uniq_paths ->
      if pkg.verbose, do: log_verbose("adding code paths: #{inspect(uniq_paths)}")
      uniq_paths
    end)
    |> Enum.each(fn code_path -> :code.add_path(String.to_charlist(code_path)) end)
  end

  defp log_verbose(msg) do
    Logger.info("[CodeSync #{inspect(node())}] #{msg}")
  end
end
