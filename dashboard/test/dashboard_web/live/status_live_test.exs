defmodule DashboardWeb.StatusLiveTest do
  # Not async: the page reads the one poller registered as Dashboard.Poller.
  use DashboardWeb.ConnCase, async: false

  alias Dashboard.{Fixtures, Poller, Snapshot, StubSource}

  # Starts the poller the page reads, with a scripted first result, and waits
  # until that result is in. The long interval keeps it quiet afterwards; tests
  # publish later snapshots themselves.
  defp start_poller(source) do
    Dashboard.subscribe()
    start_supervised!({Poller, source: source, interval: 3_600_000, max_backoff: 3_600_000})
    assert_receive {:snapshot, %Snapshot{} = snapshot}
    snapshot
  end

  defp stub(result) do
    {:ok, script} = StubSource.start_link([result])
    {StubSource, script: script}
  end

  defp publish(snapshot) do
    Phoenix.PubSub.broadcast(Dashboard.PubSub, Poller.topic(), {:snapshot, snapshot})
  end

  describe "a normal reading" do
    setup do
      %{snapshot: start_poller(stub({:ok, Fixtures.status()}))}
    end

    test "states runners, slots, queue, lock and load", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Runner host"
      assert has_element?(view, "#freshness", "Live")
      refute has_element?(view, "#demo-badge")
      refute has_element?(view, "#stale-notice")

      assert has_element?(view, "#tile-runners", "5 / 8 busy")
      assert has_element?(view, "#tile-runners", "1 down")
      assert has_element?(view, "#tile-slots", "5 / 6 units")
      assert has_element?(view, "#tile-lock", "Held")
      assert has_element?(view, "#tile-gate", "Open")

      assert has_element?(view, "#runner-mobile-app", "Running")
      assert has_element?(view, "#runner-mobile-app", "has the device")
      assert has_element?(view, "#runner-tablet-app", "Waiting for device")
      assert has_element?(view, "#runner-docs-site", "Idle")
      assert has_element?(view, "#runner-legacy-tools", "Down")

      assert has_element?(view, "#device-lock", "e2e-android")
      assert has_element?(view, "#device-lock", "no stale holders")
      assert has_element?(view, "#events li", "org/api")
    end

    test "lists the queue in admission order with what each job needs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#tile-queue", "2 waiting")
      assert has_element?(view, "#queue li:nth-child(1)", "org/data-pipeline")
      assert has_element?(view, "#queue li:nth-child(1)", "needs 2 units")
      assert has_element?(view, "#queue li:nth-child(2)", "org/api")
      assert has_element?(view, "#parked", "org/tablet-app")
    end

    test "updates when the poller publishes a new picture", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, ~p"/")

      status = Fixtures.status(&put_in(&1, ["slots", "records"], []))
      publish(%{snapshot | status: status})

      assert has_element?(view, "#tile-queue", "0 waiting")
      assert has_element?(view, "#queue", "Nobody is waiting")
    end

    test "says so when a waiting job is past the maximum wait", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, ~p"/")

      status =
        Fixtures.status(fn document ->
          update_in(document, ["slots", "records", Access.at(3)], &Map.put(&1, "since", 1))
        end)

      publish(%{snapshot | status: status})

      assert has_element?(view, "#queue li:nth-child(1)", "past the maximum wait")
    end
  end

  test "an unused host gets guidance instead of empty cards", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.unused_status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#runners", "No runners configured")
    assert has_element?(view, "#slots", "No job holds units")
    assert has_element?(view, "#queue", "Nobody is waiting")
    assert has_element?(view, "#events", "Nothing has happened yet")
  end

  test "with no runners listed, the empty state says how to point it at a config", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.unused_status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#runners", "defaults")
    assert has_element?(view, "#runners", "GRM_CONFIG")
  end

  test "a missing lock file is reported as just that", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.unused_status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#device-lock", "No lock file at the path in GRM_DEVICE_LOCK")
    assert has_element?(view, "#tile-lock", "No lock file")
    refute has_element?(view, "#device-lock", "never")
    refute has_element?(view, "#tile-lock", "never")
    refute has_element?(view, "#tile-lock", "Unused")
  end

  test "jobs on runners missing from GRM_RUNNERS are shown, not hidden", %{conn: conn} do
    status =
      Fixtures.status(fn document ->
        document
        |> Map.put("runners", [])
        |> Map.put("workers", [
          %{"pid" => 60_001, "directory" => "/srv/runners/other"},
          %{"pid" => 60_002, "directory" => "/srv/runners/another"}
        ])
      end)

    start_poller(stub({:ok, status}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#tile-runners", "2 jobs on unlisted runners")
    assert has_element?(view, "#unlisted-workers", "2 jobs running on runners not in GRM_RUNNERS")
    assert has_element?(view, "#unlisted-workers", "/srv/runners/other")
    assert has_element?(view, "#unlisted-workers", "pid 60002")
    # With no runners listed the tools may be on defaults; say how to point them at a config.
    assert has_element?(view, "#runners", "GRM_CONFIG")
  end

  test "a stale device lock is called out with the process holding it", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.stale_lock_status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#tile-lock", "Stale")
    assert has_element?(view, "#lock-stale", "adb")
    assert has_element?(view, "#lock-stale", "pid 50112")
    assert has_element?(view, "#lock-stale", "report-only")
    refute has_element?(view, "#device-lock", "no stale holders")
  end

  test "a lock held with no live wrapper is flagged before the watchdog calls it stale", %{
    conn: conn
  } do
    status = Fixtures.status(&put_in(&1, ["device_lock", "holder", "alive"], false))
    start_poller(stub({:ok, status}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#tile-lock", "Unclaimed")
    assert has_element?(view, "#lock-orphaned")
  end

  describe "when the status command fails" do
    import ExUnit.CaptureLog

    test "before any reading: says why, and shows no cards", %{conn: conn} do
      capture_log(fn -> start_poller(stub({:error, {:exit_status, 2, "boom"}})) end)
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#no-reading", "No reading yet")
      assert has_element?(view, "#no-reading", "exited with 2")
      assert has_element?(view, "#freshness", "Stale")
      refute has_element?(view, "#overview")
    end

    test "after a reading: keeps it on screen under a stale notice, then recovers", %{conn: conn} do
      snapshot = start_poller(stub({:ok, Fixtures.status()}))
      {:ok, view, _html} = live(conn, ~p"/")

      publish(Snapshot.fail(snapshot, :timeout, snapshot.fetched_at + 5))

      assert has_element?(view, "#stale-notice", "Stale data")
      assert has_element?(view, "#stale-notice", "did not finish in time")
      assert has_element?(view, "#freshness", "Stale")
      assert has_element?(view, "#tile-slots", "5 / 6 units")

      publish(snapshot)

      refute has_element?(view, "#stale-notice")
      assert has_element?(view, "#freshness", "Live")
    end
  end

  test "demo mode is labelled", %{conn: conn} do
    start_poller({Dashboard.Source.Demo, []})
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#demo-badge", "Demo data")
    assert has_element?(view, "#runner-mobile-app")
  end

  test "the first render, before the socket connects, already has the reading", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.status()}))

    assert conn |> get(~p"/") |> html_response(200) =~ "org/data-pipeline"
  end
end
