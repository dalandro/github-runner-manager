defmodule Dashboard.StatusTest do
  use ExUnit.Case, async: true

  alias Dashboard.{Fixtures, Status}
  alias Dashboard.Status.{DeviceLock, Job, LockHolder, Runner, SlotRecord, Worker}

  describe "parse/1" do
    test "turns the demo document into structs" do
      assert {:ok, %Status{} = status} = Status.parse(Fixtures.document())

      assert status.generated_at == Fixtures.now()
      assert status.host.load_1m == 4.31
      assert status.slots.capacity == 6

      assert %Runner{name: "mobile-app", repository: "org/mobile-app", unit_state: "active"} =
               hd(status.runners)

      assert [:holding, :parked, :holding, :queued, :queued] =
               Enum.map(status.slots.records, & &1.kind)

      assert %DeviceLock{state: :held, holder: %LockHolder{job: "e2e-android", alive: true}} =
               status.device_lock

      assert length(status.events) == 11

      assert %Worker{pid: 51_120, directory: "/srv/runners/mobile-app"} = hd(status.workers)
    end

    test "a document without workers, from an older producer, has none" do
      assert {:ok, %Status{workers: []}} =
               Fixtures.document() |> Map.delete("workers") |> Status.parse()
    end

    test "gives each slot record the job its hooks recorded" do
      assert %SlotRecord{
               job: %Job{
                 repository: "org/mobile-app",
                 workflow: "Android",
                 job: "e2e-android",
                 run_id: "8123456789",
                 run_attempt: 1,
                 ref: "refs/pull/57/merge",
                 pull_request: 57,
                 pull_request_title: "Keep drafts while offline",
                 queued_at: 1_767_267_932,
                 recent_durations: [1380, 1512, 1446, 1620, 1498, 1555, 1471, 1532, 1590, 1489]
               }
             } = hd(Fixtures.status().slots.records)
    end

    test "a job without recent durations, or with null, has none" do
      status =
        Fixtures.status(fn document ->
          document
          |> update_in(
            ["slots", "records", Access.at(0), "job"],
            &Map.delete(&1, "recent_durations")
          )
          |> put_in(["slots", "records", Access.at(1), "job", "recent_durations"], nil)
        end)

      assert [
               %SlotRecord{job: %Job{recent_durations: []}},
               %SlotRecord{job: %Job{recent_durations: []}} | _
             ] =
               status.slots.records
    end

    test "accepts more recent durations than the producer sends; the estimate takes ten" do
      status =
        Fixtures.status(
          &put_in(
            &1,
            ["slots", "records", Access.at(0), "job", "recent_durations"],
            List.duplicate(600, 11)
          )
        )

      assert length(hd(status.slots.records).job.recent_durations) == 11
    end

    test "rejects recent durations that are not a bounded list of whole seconds" do
      for durations <- [600, [600, -1], [600, 1.5], ["600"], List.duplicate(600, 101)] do
        assert {:error, {:invalid_field, "recent_durations"}} =
                 Fixtures.document()
                 |> put_in(
                   ["slots", "records", Access.at(0), "job", "recent_durations"],
                   durations
                 )
                 |> Status.parse()
      end
    end

    test "a record without a job, a null job, or a job missing fields, is unknown" do
      status =
        Fixtures.status(fn document ->
          document
          |> update_in(["slots", "records", Access.at(0)], &Map.delete(&1, "job"))
          |> update_in(["slots", "records", Access.at(1), "job"], &Map.take(&1, ["repository"]))
          |> put_in(["slots", "records", Access.at(2), "job"], nil)
        end)

      assert [
               %SlotRecord{job: %Job{} = empty},
               %SlotRecord{job: partial},
               %SlotRecord{job: filtered} | _
             ] = status.slots.records

      assert empty == %Job{}
      assert partial == %Job{repository: "org/tablet-app"}
      assert filtered == %Job{}
    end

    test "rejects a job field of the wrong type" do
      assert {:error, {:invalid_field, "pull_request"}} =
               Fixtures.document()
               |> put_in(["slots", "records", Access.at(0), "job", "pull_request"], "57")
               |> Status.parse()

      assert {:error, {:invalid_field, "slots.records.job"}} =
               Fixtures.document()
               |> put_in(["slots", "records", Access.at(0), "job"], "org/mobile-app")
               |> Status.parse()
    end

    test "accepts the nulls the schema allows" do
      status =
        Fixtures.status(fn document ->
          document
          |> put_in(["host", "load_1m"], nil)
          |> put_in(["host", "memory_available_mb"], nil)
          |> update_in(["slots", "records", Access.at(0)], &Map.put(&1, "since", nil))
          |> put_in(["device_lock", "holder"], nil)
        end)

      assert status.host.load_1m == nil
      assert %SlotRecord{since: nil} = hd(status.slots.records)
      assert status.device_lock.holder == nil
    end

    test "rejects a schema version it does not know" do
      assert {:error, {:unsupported_schema, 2}} =
               Status.parse(Map.put(Fixtures.document(), "schema", 2))

      assert {:error, {:unsupported_schema, nil}} = Status.parse(%{})
      assert {:error, {:unsupported_schema, nil}} = Status.parse([])
    end

    test "names the field when a value has the wrong type or is missing" do
      assert {:error, {:invalid_field, "capacity"}} =
               Fixtures.document() |> put_in(["slots", "capacity"], "six") |> Status.parse()

      assert {:error, {:invalid_field, "host"}} =
               Fixtures.document() |> Map.delete("host") |> Status.parse()

      assert {:error, {:invalid_field, "directory"}} =
               Fixtures.document()
               |> update_in(["workers", Access.at(0)], &Map.delete(&1, "directory"))
               |> Status.parse()

      assert {:error, {:invalid_field, "workers"}} =
               Fixtures.document() |> Map.put("workers", [51_120]) |> Status.parse()

      assert {:error, {:invalid_field, "ticket"}} =
               Fixtures.document()
               |> update_in(["slots", "records", Access.at(0)], &Map.put(&1, "ticket", -1))
               |> Status.parse()
    end

    test "rejects numbers no host reports, which the page could not do arithmetic on" do
      for {path, value} <- [
            {["slots", "capacity"], Integer.pow(2, 53)},
            {["host", "memory_available_mb"], Integer.pow(10, 400)},
            {["host", "load_1m"], 1.0e308},
            {["host", "load_1m"], -0.5},
            {["host", "max_load"], 1.0e-300},
            {["host", "max_load"], 2_000_000}
          ] do
        field = List.last(path)

        assert {:error, {:invalid_field, ^field}} =
                 Fixtures.document() |> put_in(path, value) |> Status.parse(),
               "accepted #{inspect(value)} for #{field}"
      end

      assert {:ok, _status} =
               Fixtures.document()
               |> put_in(["host", "load_1m"], 0)
               |> put_in(["host", "max_load"], 0.01)
               |> put_in(["slots", "capacity"], Integer.pow(2, 53) - 1)
               |> Status.parse()
    end

    test "rejects kinds and states outside the schema instead of making atoms" do
      assert {:error, {:invalid_field, "slots.records.kind"}} =
               Fixtures.document()
               |> update_in(["slots", "records", Access.at(0)], &Map.put(&1, "kind", "sleeping"))
               |> Status.parse()

      assert {:error, {:invalid_field, "device_lock.state"}} =
               Fixtures.document() |> put_in(["device_lock", "state"], "jammed") |> Status.parse()
    end
  end

  describe "decode/1" do
    test "parses JSON text" do
      assert {:ok, %Status{}} = Status.decode(Jason.encode!(Fixtures.document()))
    end

    test "reports text that is not JSON" do
      assert {:error, {:invalid_json, message}} = Status.decode("capacity 6 used 0")
      assert is_binary(message)
    end
  end
end
