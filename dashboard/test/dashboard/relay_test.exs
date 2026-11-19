defmodule Dashboard.RelayTest do
  use ExUnit.Case, async: true

  alias Dashboard.Relay

  @token String.duplicate("a", 32)

  describe "parse_tokens!/1" do
    test "reads a comma-separated list, trimmed, without duplicates" do
      other = String.duplicate("b", 40)

      assert Relay.parse_tokens!(" #{@token} ,#{other},, #{@token}") == [@token, other]
    end

    test "refuses a missing or empty setting" do
      for setting <- [nil, "", " , "] do
        assert_raise ArgumentError, ~r/at least one push token/, fn ->
          Relay.parse_tokens!(setting)
        end
      end
    end

    test "refuses a short token without repeating it" do
      short = "short-secret-value"

      error = assert_raise ArgumentError, fn -> Relay.parse_tokens!("#{@token},#{short}") end

      assert error.message =~ "32 or more characters"
      refute error.message =~ short
    end

    test "refuses a token with spaces or control characters" do
      for token <- ["#{@token} x", "#{@token}\tx"] do
        assert_raise ArgumentError, fn -> Relay.parse_tokens!(token) end
      end
    end
  end

  describe "check_interval!/1" do
    test "takes whole seconds from 2 to 900" do
      assert Relay.check_interval!(2) == 2
      assert Relay.check_interval!(900) == 900
    end

    test "refuses anything else" do
      for interval <- [1, 901, 0, -5, 2.5, "5", nil] do
        assert_raise ArgumentError, ~r/GRM_RELAY_INTERVAL_SECONDS/, fn ->
          Relay.check_interval!(interval)
        end
      end
    end
  end

  describe "stale_after/1" do
    test "is three missed pushes, and never under 30 seconds" do
      assert Relay.stale_after(5) == 30
      assert Relay.stale_after(10) == 30
      assert Relay.stale_after(20) == 60
      assert Relay.stale_after(300) == 900
    end
  end
end
