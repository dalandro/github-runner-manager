defmodule DashboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :dashboard

  # :uri and :x_headers let DashboardWeb.ViewerAuth tell a local socket from
  # one that came through a proxy.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:uri, :x_headers, session: {__MODULE__, :session_options, []}]]

  plug DashboardWeb.Plugs.AllowedHost

  plug Plug.Static,
    at: "/",
    from: :dashboard,
    only: DashboardWeb.static_paths()

  # The LiveView client ships inside the Hex packages; serving it from there
  # means no JavaScript toolchain and no vendored copies to keep in step.
  plug Plug.Static,
    at: "/vendor/phoenix",
    from: {:phoenix, "priv/static"},
    only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor/phoenix_live_view",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  plug Plug.Head
  plug :session
  plug DashboardWeb.Router

  @doc """
  The session cookie: the CSRF token LiveView checks on connect and, with a
  viewer list, the viewer and when the proxy last vouched for them. With a
  viewer list it is then a credential, so it is `Secure` (sent over the
  proxy's HTTPS only; browsers also allow it on loopback) and expires.
  """
  def session_options do
    base = [
      store: :cookie,
      key: "_grm_dashboard",
      signing_salt: "grm-dashboard-session",
      same_site: "Strict"
    ]

    if DashboardWeb.Viewers.required?() do
      base ++ [secure: true, max_age: DashboardWeb.Viewers.max_age()]
    else
      base
    end
  end

  # Options are read per request, not compiled in, because they follow the
  # runtime viewer setting.
  defp session(conn, _options) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end
end
