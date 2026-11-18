defmodule Dashboard.PollerTest do
  use ExUnit.Case, async: true

  alias Dashboard.{Fixtures, Poller, Snapshot, StubSource}

  # Each test gets its own poller and topic, so they can run concurrently.
  defp start_poller(context, results, options \\ []) do
    {:ok, script} = StubSource.start_link(results)
    topic = "status:#{inspect(context.test)}"
    Phoenix.PubSub.subscribe(Dashboard.PubSub, topic)

    options =
      Keyword.merge(
        [source: {StubSource, script: script}, interval: 10, name: nil, topic: topic],
        options
      )

    start_supervised!({Poller, options})
  end

  test "publishes the first reading and serves it to late joiners", context do
    status = Fixtures.status()
    poller = start_poller(context, [{:ok, status}])

    assert_receive {:snapshot, %Snapshot{status: ^status, error: nil, demo: false}}
    assert %Snapshot{status: ^status} = Poller.snapshot(poller)
  end

  test "does not publish a reading that shows the same picture", context do
    status = Fixtures.status()
    later = %{status | generated_at: status.generated_at + 2}
    poller = start_poller(context, [{:ok, status}, {:ok, later}])

    assert_receive {:snapshot, %Snapshot{changed_at: changed_at}}
    refute_receive {:snapshot, _snapshot}, 100
    # A page opened now is told when the picture changed, not when it was read.
    assert %Snapshot{changed_at: ^changed_at} = Poller.snapshot(poller)
    assert is_integer(changed_at)
  end

  test "publishes when the picture changes", context do
    status = Fixtures.status()
    busier = %{status | slots: %{status.slots | used: 6}}
    start_poller(context, [{:ok, status}, {:ok, busier}])

    assert_receive {:snapshot, %Snapshot{status: ^status}}
    assert_receive {:snapshot, %Snapshot{status: ^busier}}
  end

  test "publishes new load and memory readings without moving the change time", context do
    status = Fixtures.status()
    sampled = %{status | host: %{status.host | load_1m: 5.02, memory_available_mb: 5_190}}
    # Over a second apart, so a moved change time would show in epoch seconds.
    start_poller(context, [{:ok, status}, {:ok, sampled}], interval: 1_100)

    assert_receive {:snapshot, %Snapshot{status: ^status, changed_at: changed_at}}
    assert_receive {:snapshot, %Snapshot{status: ^sampled, changed_at: ^changed_at}}, 2_000
  end

  test "a failed read keeps the last reading, marks it stale, and recovers", context do
    status = Fixtures.status()
    start_poller(context, [{:ok, status}, {:error, :timeout}, {:ok, status}])

    assert_receive {:snapshot, %Snapshot{error: nil}}

    assert_receive {:snapshot, %Snapshot{status: ^status, error: :timeout, stale_since: since}}
    assert is_integer(since)

    assert_receive {:snapshot, %Snapshot{status: ^status, error: nil, stale_since: nil}}
  end

  test "a failure before any reading is published without data", context do
    start_poller(context, [{:error, {:exit_status, 2, "boom"}}])

    assert_receive {:snapshot, %Snapshot{status: nil, error: {:exit_status, 2, "boom"}}}
    # The same failure again is not news.
    refute_receive {:snapshot, _snapshot}, 100
  end

  test "survives a source that crashes and reports it as a failed read", context do
    import ExUnit.CaptureLog

    status = Fixtures.status()

    log =
      capture_log(fn ->
        poller = start_poller(context, [:crash, {:ok, status}])

        assert_receive {:snapshot, %Snapshot{status: nil, error: {:crashed, _reason}}}
        assert_receive {:snapshot, %Snapshot{status: ^status, error: nil}}
        assert Process.alive?(poller)
      end)

    assert log =~ "status read failed"
  end

  defmodule HangingSource do
    @behaviour Dashboard.Source

    @impl true
    def demo?, do: false

    @impl true
    def fetch(_options), do: Process.sleep(:infinity)
  end

  test "snapshot/1 answers while a read is still running", context do
    poller =
      start_supervised!(
        {Poller, source: {HangingSource, []}, name: nil, topic: "#{context.test}"}
      )

    assert %Snapshot{status: nil, error: nil} = Poller.snapshot(poller)
  end

  test "a read that outlives the deadline is killed and reported as a timeout", context do
    import ExUnit.CaptureLog

    capture_log(fn ->
      start_poller(context, [], source: {HangingSource, []}, read_timeout: 20)

      assert_receive {:snapshot, %Snapshot{status: nil, error: :timeout}}
    end)
  end

  test "says whether its source is the demo", context do
    poller =
      start_supervised!(
        {Poller, source: {Dashboard.Source.Demo, []}, name: nil, topic: "#{context.test}"}
      )

    assert %Snapshot{demo: true} = Poller.snapshot(poller)
  end

  describe "delay/3" do
    test "is the interval while reads succeed" do
      assert Poller.delay(2_000, 30_000, 0) == 2_000
    end

    test "doubles per consecutive failure up to the cap" do
      assert Enum.map(1..6, &Poller.delay(2_000, 30_000, &1)) ==
               [4_000, 8_000, 16_000, 30_000, 30_000, 30_000]
    end

    test "never goes below the interval or overflows on a long outage" do
      assert Poller.delay(60_000, 30_000, 3) == 60_000
      assert Poller.delay(2_000, 30_000, 100_000) == 30_000
    end
  end
end
