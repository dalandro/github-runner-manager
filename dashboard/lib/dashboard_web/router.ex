defmodule DashboardWeb.Router do
  use DashboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug DashboardWeb.Plugs.RelayLogin
    plug DashboardWeb.Plugs.RequireViewer
    plug :put_root_layout, html: {DashboardWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{"referrer-policy" => "no-referrer"}
    plug :put_content_security_policy
  end

  # Pushes from a runner host, in relay mode only (Dashboard.Relay): no
  # session, no CSRF token, no HTML. The controller checks the push token and
  # always answers JSON, whatever the client accepts.
  pipeline :ingest do
    plug :relay_only
  end

  scope "/", DashboardWeb do
    pipe_through :browser

    live "/", StatusLive
  end

  scope "/", DashboardWeb do
    pipe_through :ingest

    post "/ingest", IngestController, :create
  end

  # Routes are compiled, the mode is not: outside relay mode the route
  # answers as if it did not exist.
  defp relay_only(conn, _options) do
    if Dashboard.Relay.enabled?() do
      conn
    else
      conn |> send_resp(404, "Not Found") |> halt()
    end
  end

  # The page embeds nothing external; the policy says so to the browser.
  defp put_content_security_policy(conn, _options) do
    put_resp_header(
      conn,
      "content-security-policy",
      DashboardWeb.AllowedHosts.content_security_policy()
    )
  end
end
