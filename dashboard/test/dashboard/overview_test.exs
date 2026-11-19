defmodule Dashboard.OverviewTest do
  use ExUnit.Case, async: true

  alias Dashboard.{Fixtures, Overview}
  alias Dashboard.Status.{Host, Slots}

  describe "runners/1" do
    test "matches each runner to its job through the worker pid" do
      activities =
        Fixtures.status()
        |> Overview.runners()
        |> Map.new(&{&1.runner.name, &1.activity})

      assert activities == %{
               "mobile-app" => :running,
               "tablet-app" => :parked,
               "web-app" => :running,
               "data-pipeline" => :queued,
               "api" => :queued,
               "docs-site" => :idle,
               "infra-tools" => :idle,
               "legacy-tools" => :down
             }
    end

    test "a unit that is not active is down even with a worker left behind" do
      status =
        Fixtures.status(fn document ->
          update_in(document, ["runners", Access.at(0)], &Map.put(&1, "unit_state", "failed"))
        end)

      assert %{activity: :down} = status |> Overview.runners() |> hd()
    end

    test "a runner whose job asks for its parked units back waits for slots again" do
      status =
        Fixtures.status(fn document ->
          update_in(document, ["slots", "records", Access.at(1)], &Map.put(&1, "unparking", true))
        end)

      assert %{activity: :queued} =
               status |> Overview.runners() |> Enum.find(&(&1.runner.name == "tablet-app"))
    end

    test "a job without a slot record still counts as running" do
      status = Fixtures.status(&put_in(&1, ["slots", "records"], []))

      assert %{activity: :running, record: nil} = status |> Overview.runners() |> hd()
    end

    test "counts every activity, including the absent ones" do
      assert Overview.runner_counts(Fixtures.status()) ==
               %{running: 2, queued: 2, parked: 1, idle: 2, down: 1}

      assert Overview.runner_counts(Fixtures.unused_status()) ==
               %{running: 0, queued: 0, parked: 0, idle: 0, down: 0}
    end
  end

  describe "unlisted_workers/1" do
    test "are the busy workers no configured runner claims" do
      status =
        Fixtures.status(fn document ->
          Map.update!(document, "workers", fn workers ->
            workers ++ [%{"pid" => 60_001, "directory" => "/srv/runners/other"}]
          end)
        end)

      assert [%{pid: 60_001, directory: "/srv/runners/other"}] = Overview.unlisted_workers(status)
      assert Overview.unlisted_workers(Fixtures.status()) == []
    end
  end

  describe "utilisation/1" do
    test "reports used, free and percent" do
      assert Overview.utilisation(%Slots{capacity: 6, used: 5, max_wait_seconds: 1, records: []}) ==
               %{used: 5, capacity: 6, free: 1, percent: 83, overcommitted: false}
    end

    test "flags overcommit and never reports negative free units" do
      assert %{free: 0, percent: 133, overcommitted: true} =
               Overview.utilisation(%Slots{
                 capacity: 6,
                 used: 8,
                 max_wait_seconds: 1,
                 records: []
               })
    end
  end

  describe "holders/1, queue/1 and parked/1" do
    test "holders are the holding records, longest first" do
      assert ["org/mobile-app", "org/web-app"] =
               Fixtures.status().slots |> Overview.holders() |> Enum.map(& &1.label)
    end

    test "the queue is in ticket order" do
      assert [42, 43] = Fixtures.status().slots |> Overview.queue() |> Enum.map(& &1.ticket)
    end

    test "a job asking for its parked units back goes ahead of the queue" do
      slots =
        Fixtures.status(fn document ->
          update_in(document, ["slots", "records", Access.at(1)], &Map.put(&1, "unparking", true))
        end).slots

      assert ["org/tablet-app", "org/data-pipeline", "org/api"] =
               slots |> Overview.queue() |> Enum.map(& &1.label)

      assert Overview.parked(slots) == []
    end

    test "parked jobs are not in the queue" do
      slots = Fixtures.status().slots

      assert ["org/tablet-app"] = slots |> Overview.parked() |> Enum.map(& &1.label)
      refute "org/tablet-app" in (slots |> Overview.queue() |> Enum.map(& &1.label))
    end
  end

  describe "jobs/1, queue_position/2, job_activity/1 and runner_for/2" do
    test "every job the slot gate knows, in ticket order" do
      assert [38, 40, 41, 42, 43] =
               Fixtures.status().slots |> Overview.jobs() |> Enum.map(& &1.ticket)
    end

    test "a waiting job's place in the admission order, and none for the others" do
      slots = Fixtures.status().slots
      [mobile, tablet, _web, pipeline, api] = Overview.jobs(slots)

      assert Overview.queue_position(slots, pipeline) == {1, 2}
      assert Overview.queue_position(slots, api) == {2, 2}
      assert Overview.queue_position(slots, mobile) == nil
      assert Overview.queue_position(slots, tablet) == nil
    end

    test "what a job is doing, in the runner words" do
      slots =
        Fixtures.status(fn document ->
          update_in(document, ["slots", "records", Access.at(4)], fn record ->
            Map.merge(record, %{"kind" => "parked", "unparking" => true})
          end)
        end).slots

      assert [:running, :parked, :running, :queued, :queued] =
               slots |> Overview.jobs() |> Enum.map(&Overview.job_activity/1)
    end

    test "the configured runner whose worker is the job's holder" do
      status = Fixtures.status()
      [mobile | _] = Overview.jobs(status.slots)

      assert %{name: "mobile-app"} = Overview.runner_for(status, mobile)
      assert Overview.runner_for(%{status | runners: []}, mobile) == nil
    end
  end

  describe "waits" do
    test "elapsed/2 is never negative and passes unknown through" do
      assert Overview.elapsed(100, 160) == 60
      assert Overview.elapsed(200, 160) == 0
      assert Overview.elapsed(nil, 160) == nil
    end

    test "longest_wait/2 is the oldest queued job" do
      assert Overview.longest_wait(Fixtures.status().slots, Fixtures.now()) == 108
      assert Overview.longest_wait(Fixtures.unused_status().slots, Fixtures.now()) == nil
    end

    test "overdue?/3 is true from the maximum wait on" do
      slots = Fixtures.status().slots
      [first | _rest] = Overview.queue(slots)

      refute Overview.overdue?(first, slots, first.since + slots.max_wait_seconds - 1)
      assert Overview.overdue?(first, slots, first.since + slots.max_wait_seconds)
      refute Overview.overdue?(%{first | since: nil}, slots, Fixtures.now())
    end
  end

  describe "lock_condition/1" do
    test "follows the lock state when a live wrapper holds it" do
      assert Overview.lock_condition(Fixtures.status().device_lock) == :held
      assert Overview.lock_condition(Fixtures.unused_status().device_lock) == :absent
    end

    test "held without a live wrapper is orphaned" do
      lock = Fixtures.status(&put_in(&1, ["device_lock", "holder", "alive"], false)).device_lock
      assert Overview.lock_condition(lock) == :orphaned

      lock = Fixtures.status(&put_in(&1, ["device_lock", "holder"], nil)).device_lock
      assert Overview.lock_condition(lock) == :orphaned
    end

    test "any watchdog finding makes it stale" do
      assert Overview.lock_condition(Fixtures.stale_lock_status().device_lock) == :stale
    end
  end

  describe "load_gate/1" do
    defp host(fields) do
      struct!(
        %Host{cpus: 6, load_1m: 1.0, max_load: 6, memory_available_mb: 4096, min_memory_mb: 3072},
        fields
      )
    end

    test "is open below the load limit with enough memory" do
      assert Overview.load_gate(host([])) == %{load: :ok, memory: :ok, open: true}
    end

    test "load at the limit closes it; memory at the minimum does not" do
      assert %{load: :over, open: false} = Overview.load_gate(host(load_1m: 6.0))
      assert %{memory: :ok, open: true} = Overview.load_gate(host(memory_available_mb: 3072))
      assert %{memory: :under, open: false} = Overview.load_gate(host(memory_available_mb: 3071))
    end

    test "a missing reading is unknown and does not open the gate" do
      assert %{load: :unknown, open: false} = Overview.load_gate(host(load_1m: nil))
      assert %{memory: :unknown, open: false} = Overview.load_gate(host(memory_available_mb: nil))
    end
  end

  describe "busy?/1" do
    test "is true while any job runs, waits or is parked" do
      assert Overview.busy?(Fixtures.status())
      refute Overview.busy?(Fixtures.idle_status())
      refute Overview.busy?(Fixtures.unused_status())
    end

    test "counts a job on a runner missing from GRM_RUNNERS" do
      status =
        Fixtures.idle_status(fn document ->
          Map.put(document, "workers", [%{"pid" => 60_001, "directory" => "/srv/runners/other"}])
        end)

      assert Overview.busy?(status)
    end
  end

  describe "verdict/2" do
    test "an idle host is all clear" do
      assert %{level: :clear, headline: "All clear: nothing running, nothing waiting"} =
               Overview.verdict(Fixtures.idle_status(), Fixtures.now())
    end

    test "running jobs with nobody waiting are all clear, with the free units" do
      verdict = Overview.verdict(running_status(& &1), Fixtures.now())

      assert %{level: :clear, headline: "All clear: 2 jobs running"} = verdict
      assert Enum.any?(verdict.details, &(&1 =~ "1 of 6 units free"))
    end

    test "jobs waiting for units or for the device make it a waiting verdict, with reasons" do
      status =
        Fixtures.status(
          &update_in(&1, ["runners", Access.at(7)], fn runner ->
            Map.put(runner, "unit_state", "active")
          end)
        )

      verdict = Overview.verdict(status, Fixtures.now())

      assert %{level: :waiting, headline: "3 jobs waiting"} = verdict
      assert Enum.any?(verdict.details, &(&1 =~ "2 jobs waiting for slot units, longest"))

      assert Enum.any?(
               verdict.details,
               &(&1 =~ "1 job waiting for the device, held by org/mobile-app")
             )

      assert Enum.any?(verdict.details, &(&1 =~ "2 jobs running"))
    end

    test "a runner down needs attention ahead of anyone waiting, and names it" do
      verdict = Overview.verdict(Fixtures.status(), Fixtures.now())

      assert %{level: :attention, headline: "1 runner down: legacy-tools"} = verdict
      assert Enum.any?(verdict.details, &(&1 =~ "waiting for slot units"))
    end

    test "a stale or unclaimed device lock needs attention" do
      assert %{level: :attention, headline: "Device lock is stale"} =
               Overview.verdict(idle_with_lock(Fixtures.stale_lock_status()), Fixtures.now())

      unclaimed = Fixtures.idle_status(&put_in(&1, ["device_lock"], held_lock(false)))

      assert %{level: :attention, headline: "Device lock held with no live wrapper"} =
               Overview.verdict(unclaimed, Fixtures.now())
    end

    test "several problems are all in the headline" do
      status =
        Fixtures.stale_lock_status()
        |> then(
          &%{
            &1
            | runners: Enum.map(&1.runners, fn runner -> %{runner | unit_state: "failed"} end)
          }
        )

      assert %{level: :attention, headline: "8 runners down: " <> _ = headline} =
               Overview.verdict(status, Fixtures.now())

      assert headline =~ " · Device lock is stale"
    end

    test "no runners configured is its own problem" do
      assert %{level: :attention, headline: "No runners configured"} =
               Overview.verdict(Fixtures.unused_status(), Fixtures.now())
    end

    test "jobs on runners missing from GRM_RUNNERS need attention" do
      status =
        Fixtures.idle_status(fn document ->
          Map.put(document, "workers", [%{"pid" => 60_001, "directory" => "/srv/runners/other"}])
        end)

      verdict = Overview.verdict(status, Fixtures.now())

      assert %{level: :attention, headline: "1 job on a runner not in GRM_RUNNERS"} = verdict
      assert Enum.any?(verdict.details, &(&1 =~ "1 job running"))
    end

    test "a job on an unlisted runner that waits for units is waiting, not running" do
      status =
        Fixtures.idle_status(fn document ->
          document
          |> Map.put("workers", [%{"pid" => 60_001, "directory" => "/srv/runners/other"}])
          |> put_in(["slots", "records"], [slot_record("queued", 60_001)])
        end)

      verdict = Overview.verdict(status, Fixtures.now())

      assert Enum.any?(verdict.details, &(&1 =~ "1 job waiting for slot units"))
      refute Enum.any?(verdict.details, &(&1 =~ "running"))
    end

    test "a slot holder no runner or worker accounts for still counts as running" do
      status =
        Fixtures.idle_status(fn document ->
          document
          |> put_in(["slots", "records"], [slot_record("holding", 70_001)])
          |> put_in(["slots", "used"], 2)
        end)

      assert %{level: :clear, headline: "All clear: 1 job running"} =
               Overview.verdict(status, Fixtures.now())
    end

    defp slot_record(kind, holder_pid) do
      %{
        "kind" => kind,
        "ticket" => 50,
        "holder_pid" => holder_pid,
        "units" => 2,
        "label" => "org/other",
        "since" => Fixtures.now() - 30,
        "unparking" => false
      }
    end

    test "a load gate holding heavy steps while jobs run is a detail, not a level" do
      status = running_status(&put_in(&1, ["host", "load_1m"], 7.2))

      verdict = Overview.verdict(status, Fixtures.now())

      assert verdict.level == :clear
      assert "Heavy steps are held: load 7.20, limit 6" in verdict.details
    end

    defp held_lock(alive) do
      %{
        "state" => "held",
        "holder" => %{
          "repository" => "org/mobile-app",
          "run_id" => "8123456789",
          "job" => "e2e-android",
          "pid" => 51_644,
          "since" => Fixtures.now() - 60,
          "alive" => alive
        },
        "watchdog" => %{"min_age_seconds" => 600, "kill" => false, "stale" => []}
      }
    end

    # The demo reading with every runner up and only the two holders busy.
    defp running_status(transform) do
      Fixtures.status(fn document ->
        document
        |> Map.update!("runners", fn runners ->
          Enum.map(runners, fn runner ->
            runner = Map.put(runner, "unit_state", "active")

            if runner["worker_pid"] in [51_120, 52_877],
              do: runner,
              else: Map.put(runner, "worker_pid", nil)
          end)
        end)
        |> Map.put("workers", [])
        |> update_in(["slots", "records"], fn records ->
          Enum.filter(records, &(&1["kind"] == "holding"))
        end)
        |> transform.()
      end)
    end

    defp idle_with_lock(status), do: %{Fixtures.idle_status() | device_lock: status.device_lock}
  end

  describe "gate_summary/2" do
    test "an open gate lets heavy steps start" do
      assert Overview.gate_summary(host([]), true) ==
               %{state: :open, tone: :plain, sentence: "Heavy steps may start"}
    end

    test "a closed gate is a warning only while work is running or waiting" do
      assert Overview.gate_summary(host(load_1m: 7.2), true) ==
               %{
                 state: :holding,
                 tone: :warn,
                 sentence: "Heavy steps are held: load 7.20, limit 6"
               }

      assert Overview.gate_summary(host(load_1m: 7.2), false) ==
               %{
                 state: :would_hold,
                 tone: :plain,
                 sentence: "Would hold heavy steps: load 7.20, limit 6"
               }
    end

    test "names every reason the gate is closed" do
      assert %{sentence: "Heavy steps are held: load 7.20, limit 6; 2.0 GB free, minimum 3.0 GB"} =
               Overview.gate_summary(host(load_1m: 7.2, memory_available_mb: 2048), true)

      assert %{sentence: "Would hold heavy steps: load reading unavailable"} =
               Overview.gate_summary(host(load_1m: nil), false)
    end
  end

  describe "times_limit/2" do
    test "says how far over the limit a reading is, since the meter saturates" do
      assert Overview.times_limit(15.36, 8) == "1.9× the limit"
      assert Overview.times_limit(6.0, 6) == "1.0× the limit"
      assert Overview.times_limit(5.9, 6) == nil
      assert Overview.times_limit(nil, 6) == nil
      assert Overview.times_limit(7.0, nil) == nil
    end
  end

  describe "quiet?/2" do
    test "a panel with something to show is not quiet" do
      for panel <- [:queue, :slots, :device_lock, :events] do
        refute Overview.quiet?(Fixtures.status(), panel), "#{panel} should not be quiet"
      end
    end

    test "an unused host has every collapsible panel quiet" do
      for panel <- [:queue, :slots, :device_lock, :events] do
        assert Overview.quiet?(Fixtures.unused_status(), panel), "#{panel} should be quiet"
      end
    end

    test "a free lock is quiet; a held one is not" do
      assert Overview.quiet?(Fixtures.idle_status(), :device_lock)
      refute Overview.quiet?(Fixtures.stale_lock_status(), :device_lock)
    end

    test "slots with only parked jobs, or only queued jobs, are judged on their own" do
      parked_only =
        Fixtures.status(
          &update_in(&1, ["slots"], fn slots ->
            slots
            |> Map.put("used", 0)
            |> Map.update!("records", fn records ->
              Enum.filter(records, fn record -> record["kind"] == "parked" end)
            end)
          end)
        )

      queued_only =
        Fixtures.status(
          &update_in(&1, ["slots"], fn slots ->
            slots
            |> Map.put("used", 0)
            |> Map.update!("records", fn records ->
              Enum.filter(records, fn record -> record["kind"] == "queued" end)
            end)
          end)
        )

      refute Overview.quiet?(parked_only, :slots)
      assert Overview.quiet?(parked_only, :queue)
      assert Overview.quiet?(queued_only, :slots)
      refute Overview.quiet?(queued_only, :queue)
    end
  end

  describe "freshness_label/3" do
    test "says when the host was last read and when the picture last changed" do
      assert Overview.freshness_label(998, 940, 1_000) ==
               "updated 2s ago · last change 1m 00s ago"

      assert Overview.freshness_label(1_000, 1_000, 1_000) ==
               "updated 0s ago · last change 0s ago"
    end

    test "leaves out a change time it does not have" do
      assert Overview.freshness_label(1_000, nil, 1_000) == "updated 0s ago"
    end
  end

  describe "formatting" do
    test "format_duration/1 shows the two most significant units" do
      assert Overview.format_duration(0) == "0s"
      assert Overview.format_duration(42) == "42s"
      assert Overview.format_duration(60) == "1m 00s"
      assert Overview.format_duration(185) == "3m 05s"
      assert Overview.format_duration(7_620) == "2h 07m"
      assert Overview.format_duration(273_600) == "3d 04h"
      assert Overview.format_duration(nil) == "—"
    end

    test "format_memory/1 converts to gigabytes" do
      assert Overview.format_memory(3072) == "3.0"
      assert Overview.format_memory(5270) == "5.1"
      assert Overview.format_memory(nil) == "—"
    end

    test "meter_percent/2 clamps to the scale" do
      assert Overview.meter_percent(3, 12) == 25
      assert Overview.meter_percent(30, 12) == 100
      assert Overview.meter_percent(nil, 12) == 0
      assert Overview.meter_percent(3, nil) == 0
      assert Overview.meter_percent(3, 0) == 0
    end
  end
end
