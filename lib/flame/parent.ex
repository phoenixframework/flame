defmodule FLAME.Parent do
  @moduledoc """
  Conveniences for looking up FLAME parent information.

  ## Parent Information

  When a FLAME child is started, it contains the `FLAME_PARENT` environment
  variable that holds the parent node's information base 64 encoded into a
  map, with the following keys:

    * `:ref` - The parent node's reference.
    * `:pid` - The parent node's Pid.
    * `:backend` - The FLAME backend in use.
    * `:flame_vsn` - The FLAME version running on the parent.
    * `:backend_app` - The FLAME backend application running on the parent.
    * `:backend_vsn` - The FLAME backend version running on the parent.
    * `:node_base` - The node basename the parent generated for the runner.
    * `:host_env` - The environment variable name on the runner to use to
      to lookup the runner's hostname for the runner's longname.
  """

  @flame_vsn Keyword.fetch!(Mix.Project.config(), :version)

  defstruct pid: nil,
            ref: nil,
            backend: nil,
            node_base: nil,
            flame_vsn: nil,
            backend_vsn: nil,
            backend_app: nil,
            host_env: nil

  @doc """
  Gets the `%FLAME.Parent{}` struct from the system environment.

  Returns `nil` if no parent is set.

  When booting a FLAME node, the `FLAME.Backend` is required to
  export the `FLAME_PARENT` environment variable for the provisioned
  instance. This value holds required information about the parent node
  and can be set using the `encode/1` function.
  """
  def get do
    with {:ok, encoded} <- System.fetch_env("FLAME_PARENT"),
         %{ref: ref, pid: pid, backend: backend, host_env: host_env, node_base: node_base} =
           encoded |> Base.decode64!() |> :erlang.binary_to_term() do
      new(ref, pid, backend, node_base, host_env)
    else
      _ -> nil
    end
  end

  @doc """
  Returns a new `%FLAME.Parent{}` struct.

  The `pid` is the parent node's `FLAME.Runner` process started by
  the `FLAME.Pool`.
  """
  def new(ref, pid, backend, node_base, host_env)
      when is_reference(ref) and is_pid(pid) and is_atom(backend) do
    {backend_app, backend_vsn} =
      case :application.get_application(backend) do
        {:ok, app} -> {app, to_string(Application.spec(app, :vsn))}
        :undefined -> {nil, nil}
      end

    %__MODULE__{
      pid: pid,
      ref: ref,
      backend: backend,
      node_base: node_base,
      host_env: host_env,
      flame_vsn: @flame_vsn,
      backend_app: backend_app,
      backend_vsn: backend_vsn
    }
  end

  @doc """
  Encodes a `%FLAME.Parent{}` struct into string.
  """
  def encode(%__MODULE__{} = parent) do
    info =
      parent
      |> Map.from_struct()
      |> Map.take([
        :ref,
        :pid,
        :backend,
        :flame_vsn,
        :backend_app,
        :backend_vsn,
        :node_base,
        :host_env
      ])

    info |> :erlang.term_to_binary() |> Base.encode64()
  end
end
