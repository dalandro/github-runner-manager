defmodule DashboardWeb.StatusLiveTest do
  # Not async: the page reads the one poller registered as Dashboard.Poller.
  use DashboardWeb.ConnCase, async: false

  alias Dashboard.{Fixtures, Poller, Snapshot, StubSource}
  alias Dashboard.Relay.Inbox

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

  describe "a reading taken now" do
    # The demo replayed to the clock: each job is on the host for its recorded
    # time plus less than ten minutes, so every estimate keeps its state.
    setup do
      status = Dashboard.Source.Demo.replay(Fixtures.status(), System.system_time(:second))
      %{snapshot: start_poller(stub({:ok, status}))}
    end

    test "each running job shows progress against its usual duration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#runner-mobile-app .estimate-on_track", "min left")
      assert has_element?(view, "#runner-mobile-app svg.estimate-track rect.estimate-fill")
      assert has_element?(view, "#runner-web-app .estimate-over", "over expected")

      assert has_element?(
               view,
               ~s(#runner-web-app svg.estimate-track rect.estimate-fill[width="100%"])
             )

      assert has_element?(view, "#runner-data-pipeline .estimate-no_estimate", "2 of 3 runs")
      refute has_element?(view, "#runner-data-pipeline svg.estimate-track")
    end

    test "a job's view states what it is expected to take and from how many runs", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#job-38 dd", "about 25 min")
      assert has_element?(view, "#job-38 dd", "median of the last 10 runs")
      assert has_element?(view, "#job-38 .estimate-on_track", "min left")
      assert has_element?(view, "#job-41 .estimate-over", "over expected")
      assert has_element?(view, "#job-42 dd", "no estimate yet: 2 of 3 runs")
      assert has_element?(view, "#job-43 dd", "no estimate yet")
    end
  end

  describe "a normal reading" do
    setup do
      %{snapshot: start_poller(stub({:ok, Fixtures.status()}))}
    end

    test "leads with one verdict, then runners, slots, waiting and the gate", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/")

      assert html =~ "Runner host"
      refute has_element?(view, "#demo-badge")
      refute has_element?(view, "#relay-footer")

      assert has_element?(view, "#verdict.verdict-attention", "1 runner down: legacy-tools")
      assert has_element?(view, "#verdict", "2 jobs waiting for slot units")

      assert has_element?(
               view,
               "#verdict",
               "1 job waiting for the device, held by org/mobile-app"
             )

      assert has_element?(view, "#strip-runners", "5 / 8 busy")
      assert has_element?(view, "#strip-runners", "1 down")
      assert has_element?(view, "#strip-slots", "5 / 6 units")
      assert has_element?(view, "#strip-waiting", "3 waiting")
      refute has_element?(view, ".tile")

      assert has_element?(view, "#gate", "Heavy steps may start")
      refute has_element?(view, "#gate.gate-warn")
      refute has_element?(view, "#quiet")

      # Only the headline is announced; the details count up every second.
      assert has_element?(view, "#verdict [role=status] .verdict-headline")
      refute has_element?(view, "#verdict[role=status]")

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

    test "every queued and running job opens its own detail view, without an event", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#queue li:nth-child(1) button[popovertarget="job-42"]})
      assert has_element?(view, ~s{#queue li:nth-child(2) button[popovertarget="job-43"]})
      assert has_element?(view, ~s(#runner-web-app button[popovertarget="job-41"]))
      assert has_element?(view, ~s(#slots button[popovertarget="job-38"]))
      assert has_element?(view, ~s(#parked button[popovertarget="job-40"]))
      refute has_element?(view, "#runner-docs-site button")

      for ticket <- [38, 40, 41, 42, 43] do
        assert has_element?(view, "#job-details #job-#{ticket}[popover][role=dialog]")
      end
    end

    test "a pull request job's view links its run, pull request and commit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#job-38 h2", "org/mobile-app")
      assert has_element?(view, "#job-38", "Android")
      assert has_element?(view, "#job-38", "e2e-android")

      assert has_element?(
               view,
               ~s(#job-38 a[href="https://github.example.com/org/mobile-app/actions/runs/8123456789"][rel="noopener noreferrer"]),
               "8123456789"
             )

      assert has_element?(
               view,
               ~s(#job-38 a[href="https://github.example.com/org/mobile-app/pull/57"]),
               "#57"
             )

      assert has_element?(
               view,
               ~s(#job-38 h2 a[href="https://github.example.com/org/mobile-app"]),
               "org/mobile-app"
             )

      assert has_element?(view, "#job-38", "Keep drafts while offline")
      assert has_element?(view, "#job-38", "feature/offline-drafts")

      assert has_element?(
               view,
               ~s(#job-38 a[href$="/commit/3f9a1c27d84be5a0c6f1e2d93b7a4c58e1d06b72"]),
               "3f9a1c2"
             )

      assert has_element?(view, "#job-38", "dev-alex")
      assert has_element?(view, "#job-38", "Running")
      refute has_element?(view, "#job-38", "Waiting on")
    end

    test "waiting jobs say what they wait for and where they are in the queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#job-40", "Waiting for device")
      assert has_element?(view, "#job-40", "the device lock, held by org/mobile-app")
      assert has_element?(view, "#job-40", "none: push run")
      assert has_element?(view, "#job-42", "slot units: 1 of 2 in the queue, needs 2 units")
      assert has_element?(view, "#job-42", "not yet")
      assert has_element?(view, "#job-40", "gave them back for the device")
      assert has_element?(view, "#job-41", "none: workflow_dispatch run")
      assert has_element?(view, "#job-41", "attempt 2")
    end

    test "a job its hooks recorded nothing about shows unknown, not an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#job-43 h2", "org/api")
      assert has_element?(view, "#job-43 dd", "unknown")
      refute has_element?(view, "#job-43 a[href*=actions]")
      assert has_element?(view, "#job-43", "slot units: 2 of 2 in the queue")
    end

    test "updates when the poller publishes a new picture", %{conn: conn, snapshot: snapshot} do
      {:ok, view, _html} = live(conn, ~p"/")

      status = Fixtures.status(&put_in(&1, ["slots", "records"], []))
      publish(%{snapshot | status: status})

      assert has_element?(view, "#strip-waiting", "0 waiting")
      assert has_element?(view, "#quiet-queue", "Queue: empty")
      refute has_element?(view, "#queue")
    end

    test "says when it last read the host and when the picture last changed", %{
      conn: conn,
      snapshot: snapshot
    } do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#freshness", "updated")
      assert has_element?(view, "#freshness", "last change")

      # A reading with the same picture moves only the read time.
      publish(%{snapshot | fetched_at: 0, changed_at: 0})
      assert view |> element("#freshness") |> render() =~ ~r/updated \d+d \d+h ago/

      Phoenix.PubSub.broadcast(
        Dashboard.PubSub,
        Poller.topic(),
        {:read_at, snapshot.fetched_at + 3_600}
      )

      assert has_element?(view, "#freshness", "updated 0s ago")
      assert view |> element("#freshness") |> render() =~ ~r/last change \d+d \d+h ago/
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

  test "an unused host collapses its empty panels into one quiet group", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.unused_status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#verdict.verdict-attention", "No runners configured")
    assert has_element?(view, "#runners", "No runners configured")

    assert has_element?(view, "#quiet-slots", "0 of 6 units in use")
    assert has_element?(view, "#quiet-queue", "Queue: empty")
    assert has_element?(view, "#quiet-events", "none yet")
    refute has_element?(view, "#slots")
    refute has_element?(view, "#queue")
    refute has_element?(view, "#events")
    refute has_element?(view, "#device-lock")
  end

  test "an idle host is all clear, and a high load only would hold", %{conn: conn} do
    status = Fixtures.idle_status(&put_in(&1, ["host", "load_1m"], 9.0))
    start_poller(stub({:ok, status}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(
             view,
             "#verdict.verdict-clear",
             "All clear: nothing running, nothing waiting"
           )

    assert has_element?(view, "#quiet-device-lock", "Device lock: free")
    assert has_element?(view, "#gate", "Would hold heavy steps: load 9.00, limit 6")
    refute has_element?(view, "#gate.gate-warn")
    assert has_element?(view, "#meter-load", "1.5× the limit")
  end

  test "the gate is a warning when it holds heavy steps while jobs run", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.status(&put_in(&1, ["host", "load_1m"], 7.2))}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#gate.gate-warn", "Heavy steps are held: load 7.20, limit 6")
  end

  test "the limits read as the host's defaults, which a step may override", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#host", "These are the host's defaults")
  end

  test "jobs waiting with nothing broken is a waiting verdict", %{conn: conn} do
    status =
      Fixtures.status(
        &update_in(&1, ["runners", Access.at(7)], fn runner ->
          Map.put(runner, "unit_state", "active")
        end)
      )

    start_poller(stub({:ok, status}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#verdict.verdict-waiting", "3 jobs waiting")
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

    assert has_element?(view, "#quiet-device-lock", "no lock file at GRM_DEVICE_LOCK")
    refute has_element?(view, "#quiet-device-lock", "never")
    refute has_element?(view, "#quiet-device-lock", "Unused")
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

    assert has_element?(view, "#strip-runners", "2 jobs not matched to a runner")

    assert has_element?(
             view,
             "#unlisted-workers",
             "2 jobs running that no runner in GRM_RUNNERS matches"
           )

    assert has_element?(view, "#unlisted-workers", "/srv/runners/other")
    assert has_element?(view, "#worker-60002", "pid 60002")
    # With no runners listed the tools may be on defaults; say how to point them at a config.
    assert has_element?(view, "#runners", "GRM_CONFIG")
  end

  test "a stale device lock is called out with the process holding it", %{conn: conn} do
    start_poller(stub({:ok, Fixtures.stale_lock_status()}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#verdict.verdict-attention", "Device lock is stale")
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

    assert has_element?(view, "#verdict", "Device lock held with no live wrapper")
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

      # The verdict itself turns to the stale message.
      assert has_element?(view, "#verdict.verdict-attention", "Stale data")
      # The announced headline stays put while the age counts up in the details.
      assert has_element?(
               view,
               "#verdict .verdict-headline",
               "Stale data: showing the last good reading"
             )

      assert has_element?(view, "#verdict .verdict-details", "It is")
      assert has_element?(view, "#verdict", "did not finish in time")
      refute has_element?(view, "#verdict", "runner down")
      assert has_element?(view, "#freshness", "Stale")
      assert has_element?(view, "#strip-slots", "5 / 6 units")

      publish(snapshot)

      refute has_element?(view, "#verdict", "Stale data")
      assert has_element?(view, "#freshness", "updated")
    end
  end

  describe "relay mode" do
    setup do
      inbox = start_supervised!({Inbox, name: nil})

      {snapshot, poller} =
        start_relay_poller({Dashboard.Source.Relay, inbox: inbox, interval_seconds: 5})

      assert %Snapshot{status: nil, error: :no_push_yet} = snapshot
      %{inbox: inbox, poller: poller}
    end

    # Polls the inbox often, unlike the quiet poller above.
    defp start_relay_poller(source) do
      Dashboard.subscribe()
      poller = start_supervised!({Poller, source: source, interval: 20, max_backoff: 20})
      assert_receive {:snapshot, %Snapshot{} = snapshot}
      {snapshot, poller}
    end

    # The poller broadcasts to this test and to the page from its own process;
    # once it answers, the page's copy is in the page's mailbox ahead of any
    # question the test asks the page next.
    defp broadcast_done(poller), do: :sys.get_state(poller)

    test "waits for the host's first push, then shows it",
         %{conn: conn, inbox: inbox, poller: poller} do
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, "#no-reading", "No report yet")
      assert has_element?(view, "#no-reading", "has not pushed its status yet")
      refute has_element?(view, "#no-reading", "Check that")
      assert has_element?(view, "#relay-footer", "this page cannot reach the host")

      :ok = Inbox.offer(inbox, Fixtures.status(), System.system_time(:second))

      assert_receive {:snapshot, %Snapshot{error: nil}}
      broadcast_done(poller)
      refute has_element?(view, "#no-reading")
      assert has_element?(view, "#runner-mobile-app", "Running")
      assert has_element?(view, "#freshness", "updated")
    end

    test "keeps the last push and turns stale when pushes stop",
         %{conn: conn, inbox: inbox, poller: poller} do
      now = System.system_time(:second)
      :ok = Inbox.offer(inbox, Fixtures.status(), now)
      assert_receive {:snapshot, %Snapshot{error: nil}}
      {:ok, view, _html} = live(conn, ~p"/")

      # The same document again, as if it had last arrived an hour ago.
      :ok = Inbox.offer(inbox, Fixtures.status(), now - 3_600)

      assert_receive {:snapshot, %Snapshot{error: {:no_push, _at}}}
      broadcast_done(poller)
      assert has_element?(view, "#verdict", "Stale data: showing the last good reading")
      assert has_element?(view, "#verdict", "Waiting: the runner host has not pushed since")
      refute has_element?(view, "#verdict", "Still retrying")
      assert has_element?(view, "#freshness", "Stale")
      assert has_element?(view, "#runner-mobile-app")
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
