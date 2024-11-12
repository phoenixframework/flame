defmodule FLAME.LocalBackendAnotherPeerTest do
  alias FLAME.{Runner, LocalBackendAnotherPeer}

  setup do
    Application.ensure_started(:logger)
    Application.delete_env(:flame, :backend)
    Application.delete_env(:flame, LocalBackendAnotherPeer)
  end
end
