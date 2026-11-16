defmodule DashboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :dashboard

  # The cookie carries the CSRF token LiveView checks on connect and, with a
  # viewer list, the viewer and when the proxy last vouched for them.
  @session_options [
    store: :cookie,
    key: "_grm_dashboard",
    signing_salt: "grm-dashboard-session",
    same_site: "Strict"
  ]

  # :uri and :x_headers let DashboardWeb.ViewerAuth tell a local socket from
  # one that came through a proxy.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:uri, :x_headers, session: @session_options]]

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
  plug Plug.Session, @session_options
  plug DashboardWeb.Router
end
