defmodule DashboardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :dashboard

  # The page sends the socket nothing but joins and heartbeats; a public relay
  # need not buffer more for anyone who opens one.
  socket "/live", DashboardWeb.LiveSocket,
    websocket: [
      connect_info: [session: {__MODULE__, :session_options, []}],
      max_frame_size: 65_536
    ]

  plug :public_headers
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
  viewer list, the viewer and when the proxy last vouched for them (with a
  relay viewer password, a sign-in). It is then a credential, so it is
  `Secure` (sent over HTTPS only) and expires.
  """
  def session_options do
    base = [
      store: :cookie,
      key: "_grm_dashboard",
      signing_salt: "grm-dashboard-session",
      same_site: "Strict"
    ]

    cond do
      Dashboard.Relay.login_required?() ->
        base ++ [secure: true, max_age: DashboardWeb.RelayLogin.max_age()]

      DashboardWeb.Viewers.required?() ->
        base ++ [secure: true, max_age: DashboardWeb.Viewers.max_age()]

      true ->
        base
    end
  end

  # On the internet only: browsers are told to use HTTPS from now on, and
  # search engines to keep every response out of their index.
  defp public_headers(conn, _options) do
    if Dashboard.Relay.public?() do
      conn
      |> put_resp_header("strict-transport-security", "max-age=31536000")
      |> put_resp_header("x-robots-tag", "noindex, nofollow")
    else
      conn
    end
  end

  # Options are read per request, not compiled in, because they follow the
  # runtime viewer setting.
  defp session(conn, _options) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end
end
