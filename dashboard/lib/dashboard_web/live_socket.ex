defmodule DashboardWeb.LiveSocket do
  @moduledoc """
  The live socket. With a relay viewer password it refuses to connect without
  a sign-in in the signed session (`DashboardWeb.ViewerAuth.socket_allowed?/1`),
  so nobody without the password can hold one of the relay's few connections
  open. A page still checks again when it mounts.
  """

  use Phoenix.LiveView.Socket

  @impl Phoenix.Socket
  def connect(_params, socket, connect_info) do
    if DashboardWeb.ViewerAuth.socket_allowed?(connect_info[:session]),
      do: {:ok, socket},
      else: :error
  end

  @impl Phoenix.Socket
  def id(socket), do: Phoenix.LiveView.Socket.id(socket)
end
