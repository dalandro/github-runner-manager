defmodule DashboardWeb.ViewerAuthTest do
  # Not async: tests set the application's allowed hosts and viewers.
  use DashboardWeb.ConnCase, async: false

  alias DashboardWeb.{StatusLive, Viewers}

  @extra_host "runner-host.private.example"
  @viewer "viewer@example.com"
  @header "tailscale-user-login"

  defp put_setting(key, value) do
    Application.put_env(:dashboard, key, value)
    on_exit(fn -> Application.delete_env(:dashboard, key) end)
  end

  defp behind_proxy(_context) do
    put_setting(:allowed_hosts, @extra_host)
    put_setting(:viewers, "#{@viewer}, second@example.com")
    start_demo_poller()
  end

  # Waits for the first reading, so pages show data.
  defp start_demo_poller do
    Dashboard.subscribe()
    start_supervised!({Dashboard.Poller, source: {Dashboard.Source.Demo, []}})
    assert_receive {:snapshot, %Dashboard.Snapshot{}}
    :ok
  end

  defp proxied(conn, headers) do
    Enum.reduce(headers, Map.put(conn, :host, @extra_host), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end

  defp refused?(conn) do
    conn.status == 403 and conn.halted and not (conn.resp_body =~ "org/")
  end

  describe "behind a proxy with a viewer list" do
    setup :behind_proxy

    test "a listed identity sees the page and its live socket mounts", %{conn: conn} do
      conn = proxied(conn, [{@header, "Viewer@Example.com"}])

      assert conn |> get("/") |> html_response(200) =~ "org/mobile-app"
      assert {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#runner-mobile-app")
    end

    test "an unlisted identity gets 403 and no data", %{conn: conn} do
      conn = conn |> proxied([{@header, "stranger@example.com"}]) |> get("/")

      assert refused?(conn)
      assert conn.resp_body =~ "not on this dashboard's viewer list"
    end

    test "a request without the identity header gets 403", %{conn: conn} do
      assert conn |> proxied([]) |> get("/") |> refused?()
    end

    test "two identity headers get 403", %{conn: conn} do
      conn =
        conn
        |> Map.put(:host, @extra_host)
        |> Map.update!(:req_headers, &[{@header, @viewer}, {@header, "x@example.com"} | &1])
        |> get("/")

      assert refused?(conn)
    end

    test "a refusal drops the session cookie", %{conn: conn} do
      conn = conn |> proxied([{@header, @viewer}]) |> get("/")
      assert %{"_grm_dashboard" => _} = conn.resp_cookies

      conn =
        conn
        |> recycle()
        |> proxied([{@header, "stranger@example.com"}])
        |> get("/")

      assert refused?(conn)
      assert %{max_age: 0} = conn.resp_cookies["_grm_dashboard"]
    end

    test "a loopback name with a proxy's forwarding headers needs an identity too", %{conn: conn} do
      for header <- ["x-forwarded-for", "forwarded", "x-real-ip", "via", "tailscale-user-name"] do
        conn =
          conn
          |> Map.put(:host, "localhost")
          |> put_req_header(header, "192.0.2.1")
          |> get("/")

        assert refused?(conn), "#{header} was not treated as proxied"
      end
    end

    test "loopback without proxy headers still works, as through an SSH tunnel", %{conn: conn} do
      assert conn |> get("/") |> html_response(200) =~ "org/mobile-app"
      assert {:ok, _view, _html} = live(conn, "/")
    end

    test "the session cookie is Secure and expires", %{conn: conn} do
      cookie = conn |> proxied([{@header, @viewer}]) |> get("/") |> Map.fetch!(:resp_cookies)

      assert %{secure: true, max_age: max_age, same_site: "Strict"} =
               cookie["_grm_dashboard"]

      assert max_age == Viewers.max_age()
    end

    test "a socket whose session names no viewer is refused", %{conn: conn} do
      conn = Map.put(conn, :host, @extra_host)

      assert {:error, {:redirect, %{to: "/"}}} = live_isolated(conn, StatusLive, session: %{})
    end

    test "a socket whose session names an unlisted or stale viewer is refused", %{conn: conn} do
      conn = Map.put(conn, :host, @extra_host)
      now = System.system_time(:second)

      for session <- [
            %{"viewer" => "stranger@example.com", "viewer_at" => now},
            %{"viewer" => @viewer, "viewer_at" => now - Viewers.max_age() - 1},
            %{"viewer" => @viewer, "viewer_at" => "now"},
            %{"viewer" => @viewer}
          ] do
        assert {:error, {:redirect, %{to: "/"}}} =
                 live_isolated(conn, StatusLive, session: session)
      end

      assert {:ok, _view, _html} =
               live_isolated(conn, StatusLive,
                 session: %{"viewer" => @viewer, "viewer_at" => now}
               )
    end

    test "a socket from a loopback page carrying forwarding headers is refused", %{conn: conn} do
      conn = put_req_header(conn, "x-forwarded-for", "192.0.2.1")

      assert {:error, {:redirect, %{to: "/"}}} = live_isolated(conn, StatusLive, session: %{})
    end
  end

  describe "without a viewer list" do
    setup do
      start_demo_poller()
    end

    test "loopback works as before, with no identity and a plain session cookie", %{conn: conn} do
      conn = get(conn, "/")

      assert html_response(conn, 200) =~ "org/mobile-app"
      refute conn.resp_cookies["_grm_dashboard"][:secure]
      assert {:ok, _view, _html} = live(build_conn(:get, "http://localhost/"), "/")
    end

    test "a socket mounts without a viewer in the session", %{conn: conn} do
      assert {:ok, _view, _html} = live_isolated(conn, StatusLive, session: %{})
    end
  end

  describe "the viewer settings" do
    test "default to no viewers and the proxy's login header" do
      assert Viewers.parse!(nil) == []
      assert Viewers.parse!(" ") == []
      assert Viewers.list() == []
      assert Viewers.header() == @header
    end

    test "take comma-separated identities, trimmed, lower-cased and de-duplicated" do
      assert Viewers.parse!(" Viewer@Example.com ,b@example.com,b@example.com,") ==
               [@viewer, "b@example.com"]
    end

    test "reject identities with spaces, control characters or non-ASCII" do
      for setting <- ["a b@example.com", "a\tb", "café@example.com", String.duplicate("a", 255)] do
        assert_raise ArgumentError, ~r/GRM_DASHBOARD_VIEWERS/, fn -> Viewers.parse!(setting) end
      end
    end

    test "the header name must be a plain lower-case header name" do
      put_setting(:viewer_header, "X-Auth-User")
      assert Viewers.header() == "x-auth-user"

      for name <- ["x auth", "x:auth", ""] do
        put_setting(:viewer_header, name)
        assert_raise ArgumentError, ~r/GRM_DASHBOARD_VIEWER_HEADER/, fn -> Viewers.header() end
      end
    end

    test "boot refuses an extra allowed host with no viewer list" do
      put_setting(:allowed_hosts, @extra_host)

      assert_raise ArgumentError, ~r/GRM_DASHBOARD_VIEWERS/, fn -> Viewers.check_boot!() end

      put_setting(:viewers, @viewer)
      assert Viewers.check_boot!() == :ok
    end

    test "boot accepts loopback only with no viewer list" do
      assert Viewers.check_boot!() == :ok
    end
  end
end
