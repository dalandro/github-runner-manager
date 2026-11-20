defmodule Dashboard.RelayTest do
  # Not async: check_boot!/0 tests set the application's relay settings.
  use ExUnit.Case, async: false

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

  describe "parse_public_host!/1" do
    test "is nil when unset, and a plain host name lower-cased" do
      assert Relay.parse_public_host!(nil) == nil
      assert Relay.parse_public_host!(" Relay-Board.Example.dev ") == "relay-board.example.dev"
    end

    test "refuses a URL, a port, a wildcard, a list or a loopback name" do
      for setting <- [
            "",
            "https://relay.example.dev",
            "relay.example.dev:443",
            "*.example.dev",
            "a.example.dev,b.example.dev",
            "localhost",
            "127.0.0.1"
          ] do
        assert_raise ArgumentError, ~r/GRM_RELAY_PUBLIC_HOST/, fn ->
          Relay.parse_public_host!(setting)
        end
      end
    end
  end

  describe "parse_viewer_password!/1" do
    test "is nil when unset, and the password as given otherwise" do
      assert Relay.parse_viewer_password!(nil) == nil
      assert Relay.parse_viewer_password!("abcdefghijklmnop") == "abcdefghijklmnop"
    end

    test "refuses a short password or one with spaces, without repeating it" do
      for password <- ["", "fifteen-chars-x", "sixteen chars xx", "sixteen-chars-x\t"] do
        error = assert_raise ArgumentError, fn -> Relay.parse_viewer_password!(password) end

        assert error.message =~ "GRM_RELAY_VIEWER_PASSWORD"
        assert password == "" or not (error.message =~ password)
      end
    end
  end

  describe "check_boot!/0" do
    setup do
      on_exit(fn ->
        Application.delete_env(:dashboard, :relay)
        Application.delete_env(:dashboard, :viewers)
      end)
    end

    defp relay(settings) do
      Application.put_env(
        :dashboard,
        :relay,
        [push_tokens: @token, interval_seconds: 5] ++ settings
      )
    end

    test "a public relay needs a viewer password" do
      relay(public_host: "relay.example.dev")

      assert_raise ArgumentError, ~r/GRM_RELAY_VIEWER_PASSWORD/, &Relay.check_boot!/0

      relay(public_host: "relay.example.dev", viewer_password: String.duplicate("p", 24))
      assert Relay.check_boot!() == :ok
      assert Relay.public?() and Relay.login_required?()
    end

    test "a public relay refuses a viewer list: no proxy vouches for that header" do
      relay(public_host: "relay.example.dev", viewer_password: String.duplicate("p", 24))
      Application.put_env(:dashboard, :viewers, "viewer@example.com")

      assert_raise ArgumentError, ~r/GRM_DASHBOARD_VIEWERS/, &Relay.check_boot!/0
    end

    test "a loopback relay needs no password, and takes one" do
      relay([])
      assert Relay.check_boot!() == :ok
      refute Relay.public?() or Relay.login_required?()

      relay(viewer_password: String.duplicate("p", 24))
      assert Relay.check_boot!() == :ok
      assert Relay.login_required?() and not Relay.public?()
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
