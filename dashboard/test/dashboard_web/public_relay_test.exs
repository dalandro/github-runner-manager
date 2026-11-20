defmodule DashboardWeb.PublicRelayTest do
  # Not async: tests set the application's relay settings and use the one
  # inbox and limiter the relay has.
  use DashboardWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Dashboard.Relay.{Inbox, Limiter}
  alias DashboardWeb.ViewerAuth

  @public_host "relay.example.dev"
  @password "viewer-password-for-tests"
  @token String.duplicate("t", 32)

  defp relay(settings) do
    Application.put_env(
      :dashboard,
      :relay,
      [push_tokens: @token, interval_seconds: 5, viewer_password: @password] ++ settings
    )

    on_exit(fn -> Application.delete_env(:dashboard, :relay) end)
    start_supervised!(Inbox)
    start_supervised!({Limiter, push_interval_ms: 0})
    Dashboard.subscribe()
    start_supervised!({Dashboard.Poller, source: {Dashboard.Source.Demo, []}})
    assert_receive {:snapshot, %Dashboard.Snapshot{}}
    :ok
  end

  defp public_relay(_context), do: relay(public_host: @public_host)
  defp loopback_relay(_context), do: relay([])

  defp public(conn), do: Map.put(conn, :host, @public_host)

  defp with_password(conn, password \\ @password) do
    put_req_header(conn, "authorization", "Basic " <> Base.encode64("viewer:" <> password))
  end

  defp from(conn, address), do: put_req_header(conn, "fly-client-ip", address)

  defp asked?(conn) do
    conn.status == 401 and conn.halted and not (conn.resp_body =~ "org/") and
      get_resp_header(conn, "www-authenticate") == [
        ~s(Basic realm="runner status", charset="UTF-8")
      ]
  end

  describe "a public relay" do
    setup :public_relay

    test "asks for the password and shows nothing without it", %{conn: conn} do
      assert conn |> public() |> get("/") |> asked?()
      assert conn |> public() |> with_password("wrong-password") |> get("/") |> asked?()
    end

    test "shows the board for the password, and the live socket mounts", %{conn: conn} do
      conn = conn |> public() |> with_password() |> get("/")
      assert html_response(conn, 200) =~ "org/mobile-app"

      # The signed session alone is enough from now on, as on the live socket.
      conn = conn |> recycle() |> public()
      assert conn |> get("/") |> html_response(200) =~ "org/mobile-app"
      assert {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#runner-mobile-app")
    end

    test "a new password ends every session, on the page and on the socket", %{conn: conn} do
      conn = conn |> public() |> with_password() |> get("/")
      session = conn |> recycle() |> public() |> get("/") |> get_session()

      relay_settings = Application.get_env(:dashboard, :relay)

      Application.put_env(
        :dashboard,
        :relay,
        Keyword.put(relay_settings, :viewer_password, @password <> "-new")
      )

      assert conn |> recycle() |> public() |> get("/") |> asked?()

      assert {:halt, _socket} =
               ViewerAuth.on_mount(:require_viewer, %{}, session, %Phoenix.LiveView.Socket{})
    end

    test "the session cookie is a credential: Secure, HttpOnly, SameSite=Strict, 12 hours",
         %{conn: conn} do
      conn = conn |> public() |> with_password() |> get("/")

      assert %{secure: true, same_site: "Strict", max_age: 43_200} =
               conn.resp_cookies["_grm_dashboard"]

      [cookie] = get_resp_header(conn, "set-cookie")
      assert cookie =~ "; HttpOnly"
    end

    test "locks a client out after ten wrong passwords, before comparing", %{conn: conn} do
      for _attempt <- 1..10 do
        assert conn
               |> public()
               |> from("198.51.100.7")
               |> with_password("wrong-password")
               |> get("/")
               |> asked?()
      end

      conn = conn |> public() |> from("198.51.100.7") |> with_password() |> get("/")
      assert conn.status == 429
      assert get_resp_header(conn, "retry-after") == ["600"]
      refute conn.resp_body =~ "org/"

      # Another client is counted on its own.
      other = build_conn() |> public() |> from("198.51.100.8") |> with_password() |> get("/")
      assert html_response(other, 200) =~ "org/mobile-app"
    end

    test "a right password costs nothing, however often the browser sends it", %{conn: conn} do
      for _request <- 1..20 do
        assert conn
               |> public()
               |> from("198.51.100.7")
               |> with_password()
               |> get("/")
               |> html_response(200)
      end
    end

    test "a signed-in viewer is not locked out by others' wrong passwords", %{conn: conn} do
      signed_in = conn |> public() |> from("198.51.100.7") |> with_password() |> get("/")

      for _attempt <- 1..10 do
        build_conn()
        |> public()
        |> from("198.51.100.7")
        |> with_password("wrong-password")
        |> get("/")
      end

      assert signed_in
             |> recycle()
             |> public()
             |> from("198.51.100.7")
             |> with_password()
             |> get("/")
             |> html_response(200)
    end

    test "tells browsers to keep to HTTPS and search engines to stay away", %{conn: conn} do
      for conn <- [
            conn |> public() |> get("/"),
            conn |> public() |> with_password() |> get("/"),
            conn |> public() |> get("/robots.txt"),
            conn
            |> public()
            |> put_req_header("content-type", "application/json")
            |> post("/ingest", "")
          ] do
        assert get_resp_header(conn, "strict-transport-security") == ["max-age=31536000"]
        assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
      end
    end

    test "lets its socket connect under the public name", %{conn: conn} do
      [policy] =
        conn
        |> public()
        |> with_password()
        |> get("/")
        |> get_resp_header("content-security-policy")

      assert policy =~ "wss://#{@public_host}:*"
    end

    test "answers robots.txt under any name, for Fly's health check, and nothing else",
         %{conn: conn} do
      check = conn |> Map.put(:host, "172.19.0.2") |> get("/robots.txt")
      assert check.status == 200
      assert check.resp_body =~ "Disallow: /"

      assert (conn |> Map.put(:host, "172.19.0.2") |> with_password() |> get("/")).status == 403

      assert (conn |> Map.put(:host, "other.example.dev") |> with_password() |> get("/")).status ==
               403
    end

    test "logs neither the password nor the push token", %{conn: conn} do
      Logger.put_process_level(self(), :debug)

      log =
        capture_log([level: :debug], fn ->
          conn |> public() |> with_password() |> get("/")
          conn |> public() |> with_password("wrong-password") |> get("/")

          conn
          |> public()
          |> put_req_header("authorization", "Bearer #{@token}")
          |> put_req_header("content-type", "application/json")
          |> post("/ingest", "not json")
        end)

      refute log =~ @password
      refute log =~ Base.encode64("viewer:" <> @password)
      refute log =~ @token
    end
  end

  describe "a relay on loopback" do
    setup :loopback_relay

    test "takes a viewer password too, but sends no public headers", %{conn: conn} do
      assert conn |> get("/") |> asked?()

      conn = conn |> with_password() |> get("/")
      assert html_response(conn, 200) =~ "org/mobile-app"
      assert get_resp_header(conn, "strict-transport-security") == []
    end

    test "ignores Fly-Client-IP: anyone could send it here", %{conn: conn} do
      for attempt <- 1..10 do
        conn |> from("198.51.100.#{attempt}") |> with_password("wrong-password") |> get("/")
      end

      assert (conn |> from("198.51.100.99") |> with_password() |> get("/")).status == 429
    end

    test "answers robots.txt under its own names only", %{conn: conn} do
      assert (conn |> Map.put(:host, "172.19.0.2") |> get("/robots.txt")).status == 403
    end
  end
end
