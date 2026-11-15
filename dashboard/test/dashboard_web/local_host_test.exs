defmodule DashboardWeb.LocalHostTest do
  use DashboardWeb.ConnCase, async: true

  test "answers to loopback names", %{conn: conn} do
    for host <- ["localhost", "127.0.0.1"] do
      assert %{status: 200} = conn |> Map.put(:host, host) |> get("/robots.txt")
    end
  end

  test "refuses any other Host, which is what a DNS-rebinding request carries", %{conn: conn} do
    for host <- ["attacker.example", "localhost.attacker.example", "192.0.2.10", ""] do
      conn = conn |> Map.put(:host, host) |> get("/")

      assert conn.status == 403
      assert conn.halted
      assert conn.resp_body =~ "only to localhost"
    end
  end

  test "static files cannot be reached outside the static directory", %{conn: conn} do
    for path <- [
          "/assets/../../../mix.exs",
          "/assets/%2e%2e/%2e%2e/mix.exs",
          "/vendor/phoenix/../mix.exs"
        ] do
      # Plug.Static raises (a 400) for a traversal under its prefix; anything
      # else falls through to the router's 404.
      {status, body} =
        try do
          conn = get(conn, path)
          {conn.status, conn.resp_body}
        rescue
          Plug.Static.InvalidPathError -> {400, ""}
          Phoenix.Router.NoRouteError -> {404, ""}
        end

      assert status in [400, 404]
      refute body =~ "defmodule"
    end
  end

  test "the live socket refuses a page from any other origin", %{conn: conn} do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        conn =
          conn
          |> put_req_header("origin", "http://attacker.example")
          |> get("/live/websocket?vsn=2.0.0")

        assert conn.status == 403
      end)

    assert log =~ "Could not check origin"
  end

  test "the endpoint is configured for loopback only" do
    config = Application.fetch_env!(:dashboard, DashboardWeb.Endpoint)

    assert config[:http][:ip] == {127, 0, 0, 1}
    assert config[:check_origin] == ["//localhost", "//127.0.0.1"]
  end

  test "pages carry a content security policy without inline code", %{conn: conn} do
    start_supervised!({Dashboard.Poller, source: {Dashboard.Source.Demo, []}})
    [policy] = conn |> get("/") |> get_resp_header("content-security-policy")

    assert policy =~ "default-src 'self'"
    refute policy =~ "unsafe-inline"
  end
end
