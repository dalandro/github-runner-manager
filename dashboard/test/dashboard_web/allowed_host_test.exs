defmodule DashboardWeb.AllowedHostTest do
  # Not async: some tests set the application's allowed hosts.
  use DashboardWeb.ConnCase, async: false

  alias DashboardWeb.AllowedHosts

  @extra_host "runner-host.private.example"

  defp allow_extra_host(_context) do
    Application.put_env(:dashboard, :allowed_hosts, @extra_host)
    on_exit(fn -> Application.delete_env(:dashboard, :allowed_hosts) end)
  end

  defp socket_status(conn, origin) do
    conn
    |> put_req_header("origin", origin)
    |> get("/live/websocket?vsn=2.0.0")
    |> Map.fetch!(:status)
  end

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
      assert conn.resp_body =~ "does not answer to that host name"
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
        for origin <- [
              "http://attacker.example",
              "https://#{@extra_host}",
              "https://localhost.attacker.example",
              "ftp://localhost"
            ] do
          assert socket_status(conn, origin) == 403
        end
      end)

    assert log =~ "Could not check origin"
  end

  test "the live socket accepts a page from a loopback origin", %{conn: conn} do
    for origin <- ["http://localhost:4290", "http://127.0.0.1:4290"] do
      refute socket_status(conn, origin) == 403
    end
  end

  test "the endpoint listens on loopback and checks origins against the allowed hosts" do
    config = Application.fetch_env!(:dashboard, DashboardWeb.Endpoint)

    assert config[:http][:ip] == {127, 0, 0, 1}
    assert config[:check_origin] == {AllowedHosts, :origin_allowed?, []}
  end

  test "forwarded headers do not make a foreign Host acceptable", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "attacker.example")
      |> put_req_header("x-forwarded-host", "localhost")
      |> put_req_header("forwarded", "host=localhost")
      |> get("/")

    assert conn.status == 403
  end

  describe "with an extra allowed host" do
    setup :allow_extra_host

    test "answers to it, in any letter case, and still to loopback", %{conn: conn} do
      for host <- [@extra_host, String.upcase(@extra_host), "localhost"] do
        assert %{status: 200} = conn |> Map.put(:host, host) |> get("/robots.txt")
      end
    end

    test "still refuses every other Host, including near misses", %{conn: conn} do
      for host <- [
            "attacker.example",
            "x.#{@extra_host}",
            "#{@extra_host}.attacker.example",
            "#{@extra_host}.",
            "private.example"
          ] do
        assert %{status: 403} = conn |> Map.put(:host, host) |> get("/")
      end
    end

    test "the live socket accepts its origin and refuses others", %{conn: conn} do
      refute socket_status(conn, "https://#{@extra_host}") == 403

      ExUnit.CaptureLog.capture_log(fn ->
        assert socket_status(conn, "https://attacker.example") == 403
        assert socket_status(conn, "https://x.#{@extra_host}") == 403
      end)
    end

    test "a forwarded host is not read: only Host and Origin count", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, "attacker.example")
        |> put_req_header("x-forwarded-host", @extra_host)
        |> get("/")

      assert conn.status == 403
    end

    test "the content security policy names its secure socket", %{conn: conn} do
      start_supervised!({Dashboard.Poller, source: {Dashboard.Source.Demo, []}})

      [policy] =
        conn
        |> Map.put(:host, @extra_host)
        |> get("/")
        |> get_resp_header("content-security-policy")

      assert policy =~
               "connect-src 'self' ws://localhost:* ws://127.0.0.1:* wss://#{@extra_host}:*;"
    end
  end

  describe "the allowed hosts setting" do
    test "defaults to no extra names" do
      assert AllowedHosts.parse!(nil) == []
      assert AllowedHosts.parse!("") == []
      assert AllowedHosts.list() == ["localhost", "127.0.0.1"]
    end

    test "takes comma-separated names, trimmed, lower-cased and de-duplicated" do
      assert AllowedHosts.parse!(" Runner-Host.private.example , host2,host2,") ==
               ["runner-host.private.example", "host2"]
    end

    test "rejects anything that is not a plain host name" do
      for setting <- [
            "*.private.example",
            "*",
            "https://host.example",
            "host.example:443",
            "host.example/path",
            "host example",
            ".example",
            "host..example",
            "-host.example",
            "user@host.example",
            "[::1]"
          ] do
        assert_raise ArgumentError, ~r/plain host names/, fn -> AllowedHosts.parse!(setting) end
      end
    end

    test "an origin needs an allowed host and a web scheme" do
      assert AllowedHosts.origin_allowed?(URI.parse("http://localhost:4290"))
      refute AllowedHosts.origin_allowed?(URI.parse("https://attacker.example"))
      refute AllowedHosts.origin_allowed?(URI.parse("file://localhost"))
      refute AllowedHosts.origin_allowed?(URI.parse("null"))
    end

    test "letter case is folded for ASCII only, so a look-alike letter does not match" do
      Application.put_env(:dashboard, :allowed_hosts, "kube.example")
      on_exit(fn -> Application.delete_env(:dashboard, :allowed_hosts) end)

      assert AllowedHosts.allowed?("KUBE.example")
      # U+212A, the Kelvin sign, lower-cases to "k" under Unicode rules.
      refute AllowedHosts.allowed?("\u212Aube.example")
      refute AllowedHosts.origin_allowed?(%URI{scheme: "https", host: "\u212Aube.example"})
    end
  end

  test "pages carry a content security policy without inline code", %{conn: conn} do
    start_supervised!({Dashboard.Poller, source: {Dashboard.Source.Demo, []}})
    [policy] = conn |> get("/") |> get_resp_header("content-security-policy")

    assert policy =~ "default-src 'self'"
    assert policy =~ "connect-src 'self' ws://localhost:* ws://127.0.0.1:*;"
    refute policy =~ "unsafe-inline"
    refute policy =~ "wss:"
  end
end
