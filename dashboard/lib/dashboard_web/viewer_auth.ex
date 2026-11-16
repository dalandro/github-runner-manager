defmodule DashboardWeb.ViewerAuth do
  @moduledoc """
  The live socket's half of the viewer check. Phoenix dispatches sockets
  before endpoint and router plugs, so `DashboardWeb.Plugs.RequireViewer`
  never sees them. With a viewer list, a page mounts only when its signed
  session names a listed viewer recorded within `DashboardWeb.Viewers.max_age/0`.
  Otherwise the page is sent back to `/`, where the plug answers.
  """

  import Phoenix.LiveView

  alias DashboardWeb.Viewers

  def on_mount(:require_viewer, _params, session, socket) do
    if not Viewers.required?() or recent_viewer?(session) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp recent_viewer?(%{"viewer" => viewer, "viewer_at" => at}) when is_integer(at) do
    Viewers.listed?(viewer) and (System.system_time(:second) - at) in 0..Viewers.max_age()
  end

  defp recent_viewer?(_session), do: false
end
