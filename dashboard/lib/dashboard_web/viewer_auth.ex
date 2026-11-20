defmodule DashboardWeb.ViewerAuth do
  @moduledoc """
  The live socket's half of the viewer check. Phoenix dispatches sockets
  before endpoint and router plugs, so `DashboardWeb.Plugs.RequireViewer`
  never sees them. With a viewer list, a page mounts only when its signed
  session names a listed viewer recorded within `DashboardWeb.Viewers.max_age/0`.
  With a relay viewer password, only when it records a sign-in with the
  current password (`DashboardWeb.RelayLogin.session_valid?/4`, checked by
  `DashboardWeb.Plugs.RelayLogin` on page requests).
  Otherwise the page is sent back to `/`, where the plugs answer.
  """

  import Phoenix.LiveView

  alias Dashboard.Relay
  alias DashboardWeb.{Endpoint, RelayLogin, Viewers}

  def on_mount(:require_viewer, _params, session, socket) do
    if allowed?(session) do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/")}
    end
  end

  defp allowed?(session) do
    cond do
      Relay.login_required?() ->
        RelayLogin.session_valid?(
          session,
          Relay.viewer_password(),
          Endpoint.config(:secret_key_base),
          System.system_time(:second)
        )

      Viewers.required?() ->
        recent_viewer?(session)

      true ->
        true
    end
  end

  defp recent_viewer?(%{"viewer" => viewer, "viewer_at" => at}) when is_integer(at) do
    Viewers.listed?(viewer) and (System.system_time(:second) - at) in 0..Viewers.max_age()
  end

  defp recent_viewer?(_session), do: false
end
