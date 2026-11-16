defmodule DashboardWeb.ViewerAuth do
  @moduledoc """
  The live socket's half of the viewer check. Phoenix dispatches sockets
  before endpoint and router plugs, so `DashboardWeb.Plugs.RequireViewer`
  never sees them. With a viewer list, a page mounts only when its signed
  session names a listed viewer recorded within `DashboardWeb.Viewers.max_age/0`,
  or when the socket itself is plainly local (loopback host, no forwarding
  headers). Otherwise the page is sent back to `/`, where the plug answers.
  """

  import Phoenix.LiveView

  alias DashboardWeb.Viewers

  def on_mount(:require_viewer, _params, session, socket) do
    if not Viewers.required?() or recent_viewer?(session) or local?(socket) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp recent_viewer?(%{"viewer" => viewer, "viewer_at" => at}) when is_integer(at) do
    Viewers.listed?(viewer) and (System.system_time(:second) - at) in 0..Viewers.max_age()
  end

  defp recent_viewer?(_session), do: false

  defp local?(socket) do
    case get_connect_info(socket, :uri) do
      %URI{host: host} -> Viewers.local?(host, get_connect_info(socket, :x_headers) || [])
      _ -> false
    end
  end
end
