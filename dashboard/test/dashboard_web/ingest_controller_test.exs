defmodule DashboardWeb.IngestControllerTest do
  # Not async: tests set the application's relay settings and use the one
  # inbox the controller writes to.
  use DashboardWeb.ConnCase, async: false

  alias Dashboard.Relay.Inbox
  alias Dashboard.{Fixtures, Status}
  alias DashboardWeb.IngestController

  @token String.duplicate("t", 32)
  @old_token String.duplicate("o", 40)

  defp relay_mode(_context) do
    Application.put_env(:dashboard, :relay,
      push_tokens: "#{@token},#{@old_token}",
      interval_seconds: 5
    )

    on_exit(fn -> Application.delete_env(:dashboard, :relay) end)
    start_supervised!(Inbox)
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

    test "refuses a document over the size cap", %{conn: conn} do
      padded = demo_document() <> String.duplicate(" ", IngestController.max_bytes())

      assert conn |> push_document(padded) |> json_response(413)
      assert Inbox.latest(Inbox) == nil
    end

    test "refuses a body that is not a schema 1 status document", %{conn: conn} do
      for body <- ["not json", ~s({"schema": 2}), ~s({"schema": 1})] do
        assert conn |> push_document(body) |> json_response(422)
      end

      assert Inbox.latest(Inbox) == nil
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
