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
