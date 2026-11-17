defmodule DashboardWeb.Router do
  use DashboardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug DashboardWeb.Plugs.RequireViewer
    plug :put_root_layout, html: {DashboardWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{"referrer-policy" => "no-referrer"}
    plug :put_content_security_policy
  end

  scope "/", DashboardWeb do
    pipe_through :browser

    live "/", StatusLive
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
