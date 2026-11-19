defmodule Dashboard.Relay.IngestTest do
  use ExUnit.Case, async: true

  alias Dashboard.Fixtures
  alias Dashboard.Relay.Ingest

  @token String.duplicate("a", 32)
  @other String.duplicate("b", 40)

  describe "authorize/2" do
    test "accepts any configured token as a bearer credential" do
      assert Ingest.authorize(["Bearer #{@token}"], [@token, @other]) == :ok
      assert Ingest.authorize(["Bearer #{@other}"], [@token, @other]) == :ok
      assert Ingest.authorize(["bearer #{@token}"], [@token]) == :ok
    end

    test "refuses a missing, wrong or malformed credential" do
      for headers <- [
            [],
            ["Bearer"],
            ["Bearer "],
            ["Bearer #{@other}"],
            ["Bearer #{@token}x"],
            ["Bearer #{String.slice(@token, 0..-2//1)}"],
            ["Basic #{@token}"],
            [@token],
            ["Bearer #{@token}", "Bearer #{@token}"]
          ] do
        assert Ingest.authorize(headers, [@token]) == {:error, :unauthorized},
               "accepted #{inspect(headers)}"
      end
    end

    test "refuses everything when no token is configured" do
      assert Ingest.authorize(["Bearer "], []) == {:error, :unauthorized}
      assert Ingest.authorize(["Bearer #{@token}"], []) == {:error, :unauthorized}
    end
  end

  describe "accept/3" do
    setup do
      status = Fixtures.status()
      %{status: status, generated_at: status.generated_at}
    end

    defp generated(status, at), do: %{status | generated_at: at}

    test "the first push is accepted and stamped with its arrival", %{status: status} do
      assert Ingest.accept(nil, status, 1_000) == {:ok, %{status: status, received_at: 1_000}}
    end

    test "a newer or equally new push replaces the last one", context do
      last = %{status: context.status, received_at: 1_000}
      newer = generated(context.status, context.generated_at + 5)

      assert Ingest.accept(last, newer, 1_005) == {:ok, %{status: newer, received_at: 1_005}}

      assert Ingest.accept(last, context.status, 1_001) ==
               {:ok, %{status: context.status, received_at: 1_001}}
    end

    test "an older push is refused while the last one is recent", context do
      last = %{status: context.status, received_at: 1_000}
      older = generated(context.status, context.generated_at - 1)

      assert Ingest.accept(last, older, 1_005) == {:error, :older}
      assert Ingest.accept(last, older, 1_600) == {:error, :older}
    end

    test "an older push is accepted after ten quiet minutes: the host clock stepped back",
         context do
      last = %{status: context.status, received_at: 1_000}
      older = generated(context.status, context.generated_at - 3_600)

      assert Ingest.accept(last, older, 1_601) == {:ok, %{status: older, received_at: 1_601}}
    end
  end
end
