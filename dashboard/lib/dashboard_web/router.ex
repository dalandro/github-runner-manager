defmodule DashboardWeb.Router do
  use DashboardWeb, :router

  # The page embeds nothing external; the policy says so to the browser.
  @content_security_policy "default-src 'self'; img-src 'self' data:; " <>
                             "connect-src 'self' ws://localhost:* ws://127.0.0.1:*; " <>
                             "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :put_root_layout, html: {DashboardWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => @content_security_policy,
      "referrer-policy" => "no-referrer"
    }
  end

  scope "/", DashboardWeb do
    pipe_through :browser

    live "/", StatusLive
  end
end
