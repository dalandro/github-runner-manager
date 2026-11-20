defmodule DashboardWeb.RelayLoginTest do
  use ExUnit.Case, async: true

  alias DashboardWeb.RelayLogin

  @password "correct-horse-battery-staple"
  @secret String.duplicate("secret-key-base-", 4)

  defp basic(user_and_password), do: "Basic " <> Base.encode64(user_and_password)

  describe "check/2" do
    test "takes the password under any user name" do
      assert RelayLogin.check([basic("viewer:#{@password}")], @password) == :ok
      assert RelayLogin.check([basic(":#{@password}")], @password) == :ok
      assert RelayLogin.check(["basic " <> Base.encode64("x:#{@password}")], @password) == :ok
    end

    test "keeps a colon inside the password" do
      assert RelayLogin.check([basic("viewer:a:#{@password}")], "a:" <> @password) == :ok
    end

    test "is missing without basic credentials: the browser has not asked yet" do
      for headers <- [[], ["Bearer #{@password}"]] do
        assert RelayLogin.check(headers, @password) == :missing
      end
    end

    test "is wrong for a wrong password or a malformed header" do
      for headers <- [
            [basic("viewer:#{@password}x")],
            [basic("viewer:")],
            [basic(@password)],
            ["Basic not-base64!"],
            ["Basic"],
            [basic("viewer:#{@password}"), basic("viewer:#{@password}")]
          ] do
        assert RelayLogin.check(headers, @password) == :wrong
      end
    end
  end

  describe "session_valid?/4" do
    setup do
      %{session: RelayLogin.session(@password, @secret, 1_000)}
    end

    test "holds for the password it was made with, for twelve hours", %{session: session} do
      assert RelayLogin.session_valid?(session, @password, @secret, 1_000)
      assert RelayLogin.session_valid?(session, @password, @secret, 1_000 + 12 * 3600)
      refute RelayLogin.session_valid?(session, @password, @secret, 1_001 + 12 * 3600)
      refute RelayLogin.session_valid?(session, @password, @secret, 999)
    end

    test "ends when the password or the secret key base changes", %{session: session} do
      refute RelayLogin.session_valid?(session, @password <> "-new", @secret, 1_000)
      refute RelayLogin.session_valid?(session, @password, @secret <> "-new", 1_000)
    end

    test "holds neither the password nor anything without a key", %{session: session} do
      refute inspect(session) =~ @password
      assert RelayLogin.session(@password, @secret <> "-other", 1_000) != session
      refute RelayLogin.session_valid?(%{}, @password, @secret, 1_000)
      refute RelayLogin.session_valid?(%{"viewer_at" => 1_000}, @password, @secret, 1_000)
    end
  end
end
