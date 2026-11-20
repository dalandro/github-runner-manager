defmodule DashboardWeb.IngestControllerTest do
  # Not async: tests set the application's relay settings and use the one
  # inbox the controller writes to.
  use DashboardWeb.ConnCase, async: false

  alias Dashboard.Relay.{Inbox, Limiter}
  alias Dashboard.{Fixtures, Status}
  alias DashboardWeb.IngestController

  @token String.duplicate("t", 32)
  @old_token String.duplicate("o", 40)

  defp relay_mode(context) do
    Application.put_env(:dashboard, :relay,
      push_tokens: "#{@token},#{@old_token}",
      interval_seconds: 5
    )

    on_exit(fn -> Application.delete_env(:dashboard, :relay) end)
    start_supervised!(Inbox)
    # Most tests push several times in a row; the rate limit has its own.
    start_supervised!({Limiter, name: Limiter.viewers()})

    start_supervised!(
      {Limiter, name: Limiter.pushes(), push_interval_ms: context[:push_interval_ms] || 0}
    )

    :ok
  end

  defp push_document(conn, body, token \\ @token) do
    conn
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> post("/ingest", body)
  end

  defp demo_document, do: File.read!(Dashboard.Source.Demo.default_path())

  describe "in relay mode" do
    setup :relay_mode

    test "accepts a status document and says when to push next", %{conn: conn} do
      conn = push_document(conn, demo_document())

      assert json_response(conn, 200) == %{"next_push_seconds" => 5}
      assert %{status: %Status{} = status, received_at: at} = Inbox.latest(Inbox)
      assert status == Fixtures.status()
      assert_in_delta at, System.system_time(:second), 5
    end

    test "accepts every configured token, for rotation", %{conn: conn} do
      assert conn |> push_document(demo_document(), @old_token) |> json_response(200)
    end

    test "refuses a push without the right token and keeps nothing", %{conn: conn} do
      for headers <- [[], [{"authorization", "Bearer #{@token}x"}], [{"authorization", @token}]] do
        conn =
          headers
          |> Enum.reduce(conn, fn {name, value}, conn -> put_req_header(conn, name, value) end)
          |> put_req_header("content-type", "application/json")
          |> post("/ingest", demo_document())

        assert json_response(conn, 401)["error"] =~ "push token"
        assert get_resp_header(conn, "www-authenticate") == ["Bearer"]
      end

      assert Inbox.latest(Inbox) == nil
    end

    test "takes a document of exactly the size cap and refuses one byte more", %{conn: conn} do
      document = demo_document()

      padded =
        document <> String.duplicate(" ", IngestController.max_bytes() - byte_size(document))

      assert conn |> push_document(padded <> " ") |> json_response(413)
      assert Inbox.latest(Inbox) == nil
      assert conn |> push_document(padded) |> json_response(200)
    end

    test "checks the token before the size", %{conn: conn} do
      padded = demo_document() <> String.duplicate(" ", IngestController.max_bytes())

      assert conn |> push_document(padded, @token <> "x") |> json_response(401)
    end

    test "refuses a body that is not a schema 1 status document", %{conn: conn} do
      for body <- ["not json", ~s({"schema": 2}), ~s({"schema": 1})] do
        assert conn |> push_document(body) |> json_response(422)
      end

      assert Inbox.latest(Inbox) == nil
    end

    test "a refusal repeats nothing that was sent", %{conn: conn} do
      marker = "pushed-marker-" <> String.duplicate("x", 200)

      for body <- [
            Jason.encode!(%{"schema" => marker}),
            "#{marker} is not json",
            Fixtures.document() |> put_in(["slots", "capacity"], marker) |> Jason.encode!()
          ] do
        conn = push_document(conn, body)

        assert json_response(conn, 422)
        refute conn.resp_body =~ "pushed-marker"
      end
    end

    test "refuses a document older than the last one accepted", %{conn: conn} do
      newer =
        Fixtures.document()
        |> Map.update!("generated_at", &(&1 + 60))
        |> Jason.encode!()

      assert conn |> push_document(newer) |> json_response(200)
      assert conn |> push_document(demo_document()) |> json_response(409)
      assert Inbox.latest(Inbox).status.generated_at == Fixtures.now() + 60
    end

    test "answers JSON to a client that asks for HTML", %{conn: conn} do
      conn = conn |> put_req_header("accept", "text/html") |> push_document("not json")

      assert json_response(conn, 422)["error"]
    end

    @tag push_interval_ms: 1_000
    test "takes one push a second", %{conn: conn} do
      assert conn |> push_document(demo_document()) |> json_response(200)

      conn = push_document(conn, demo_document())
      assert json_response(conn, 429)["error"] =~ "one push a second"
      assert get_resp_header(conn, "retry-after") == ["1"]
    end

    test "after ten wrong tokens refuses the client's guesses for ten minutes", %{conn: conn} do
      for _attempt <- 1..10 do
        assert conn |> push_document(demo_document(), @token <> "x") |> json_response(401)
      end

      conn = push_document(conn, demo_document(), @token <> "x")
      assert json_response(conn, 429)["error"] =~ "too many wrong push tokens"
      assert [seconds] = get_resp_header(conn, "retry-after")
      assert String.to_integer(seconds) in 599..600
      assert Inbox.latest(Inbox) == nil
    end

    test "takes a right token whatever others guessed, so the board never goes stale for it",
         %{conn: conn} do
      for client <- 1..10, _attempt <- 1..10 do
        conn
        |> Map.put(:remote_ip, {198, 51, 100, client})
        |> push_document(demo_document(), @token <> "x")
      end

      assert conn |> push_document(demo_document(), @token <> "x") |> json_response(429)
      assert conn |> push_document(demo_document()) |> json_response(200)
    end

    test "counts no right token, so a busy host is never locked out", %{conn: conn} do
      for _attempt <- 1..20 do
        assert conn |> push_document(demo_document()) |> json_response(200)
      end
    end

    test "sets no cookie", %{conn: conn} do
      conn = push_document(conn, demo_document())

      assert conn.status == 200
      assert get_resp_header(conn, "set-cookie") == []
    end
  end

  test "outside relay mode the route does not exist", %{conn: conn} do
    conn = push_document(conn, demo_document())

    assert conn.status == 404
    refute conn.resp_body =~ "next_push_seconds"
  end
end
