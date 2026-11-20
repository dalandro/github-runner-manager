defmodule Dashboard.Relay.ThrottleTest do
  use ExUnit.Case, async: true

  alias Dashboard.Relay.Throttle

  @minute 60_000
  @start 1_000_000

  # Makes n attempts from key, a second apart from `at`, none of them forgiven.
  defp fail(throttle, key, n, at \\ @start) do
    Enum.reduce(0..(n - 1)//1, throttle, fn step, throttle ->
      assert {:ok, throttle} = Throttle.attempt(throttle, key, at + step * 1_000)
      throttle
    end)
  end

  describe "attempt/3 for one client" do
    test "allows ten wrong attempts in ten minutes, then refuses for ten minutes" do
      throttle = fail(Throttle.new(), "198.51.100.7", 10)
      last = @start + 9_000

      assert {:error, 600} = Throttle.attempt(throttle, "198.51.100.7", last + 1)
      assert {:error, 1} = Throttle.attempt(throttle, "198.51.100.7", last + 10 * @minute - 1)
      assert {:ok, _throttle} = Throttle.attempt(throttle, "198.51.100.7", last + 10 * @minute)
    end

    test "does not count refused attempts, so waiting is enough" do
      throttle = fail(Throttle.new(), "198.51.100.7", 10)

      throttle =
        Enum.reduce(1..50, throttle, fn step, throttle ->
          assert {:error, _seconds} =
                   Throttle.attempt(throttle, "198.51.100.7", @start + 9_000 + step)

          throttle
        end)

      assert {:ok, _throttle} =
               Throttle.attempt(throttle, "198.51.100.7", @start + 9_000 + 10 * @minute)
    end

    test "does not count forgiven attempts: a right password costs nothing" do
      throttle =
        Enum.reduce(1..30, Throttle.new(), fn step, throttle ->
          assert {:ok, throttle} = Throttle.attempt(throttle, "198.51.100.7", @start + step)
          Throttle.forgive(throttle, "198.51.100.7")
        end)

      assert {:ok, _throttle} = Throttle.attempt(throttle, "198.51.100.7", @start + 31)
    end

    test "forgets wrong attempts older than ten minutes" do
      throttle = fail(Throttle.new(), "198.51.100.7", 9)
      throttle = fail(throttle, "198.51.100.7", 9, @start + 10 * @minute + 9_000)

      assert {:ok, _throttle} = Throttle.attempt(throttle, "198.51.100.7", @start + 11 * @minute)
    end

    test "counts each client on its own" do
      throttle = fail(Throttle.new(), "198.51.100.7", 10)

      assert {:ok, _throttle} = Throttle.attempt(throttle, "198.51.100.8", @start + 10_000)
    end
  end

  describe "attempt/3 across clients" do
    test "refuses everyone after a hundred wrong attempts in an hour" do
      throttle =
        Enum.reduce(1..100, Throttle.new(), fn client, throttle ->
          assert {:ok, throttle} = Throttle.attempt(throttle, "client-#{client}", @start + client)
          throttle
        end)

      assert {:error, seconds} = Throttle.attempt(throttle, "client-new", @start + 101)
      assert seconds in 3599..3600

      assert {:ok, _throttle} =
               Throttle.attempt(throttle, "client-new", @start + 1 + 60 * @minute)
    end

    test "keeps nothing about a client once its attempts are old" do
      throttle = fail(Throttle.new(), "198.51.100.7", 10)

      assert {:ok, throttle} =
               Throttle.attempt(throttle, "198.51.100.8", @start + 2 * 60 * @minute)

      assert Throttle.clients(throttle) == ["198.51.100.8"]
    end
  end

  describe "push/2" do
    test "takes one push per interval" do
      throttle = Throttle.new(push_interval_ms: 1_000)

      assert {:ok, throttle} = Throttle.push(throttle, @start)
      assert {:error, 1} = Throttle.push(throttle, @start + 999)
      assert {:ok, _throttle} = Throttle.push(throttle, @start + 1_000)
    end

    test "takes every push with no interval" do
      throttle = Throttle.new(push_interval_ms: 0)

      assert {:ok, throttle} = Throttle.push(throttle, @start)
      assert {:ok, _throttle} = Throttle.push(throttle, @start)
    end
  end

  describe "client_key/1" do
    test "is the address for IPv4 and the /64 network for IPv6" do
      assert Throttle.client_key({198, 51, 100, 7}) == "198.51.100.7"

      assert Throttle.client_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) ==
               Throttle.client_key({0x2001, 0xDB8, 1, 2, 9, 9, 9, 9})

      refute Throttle.client_key({0x2001, 0xDB8, 1, 2, 3, 4, 5, 6}) ==
               Throttle.client_key({0x2001, 0xDB8, 1, 3, 3, 4, 5, 6})
    end

    test "reads an IPv4 address mapped into IPv6 as IPv4" do
      assert Throttle.client_key({0, 0, 0, 0, 0, 0xFFFF, 0xC633, 0x6407}) == "198.51.100.7"
    end
  end
end
