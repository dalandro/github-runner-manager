defmodule Dashboard.Fixtures do
  @moduledoc """
  Status readings for tests, built from the bundled demo document so they
  always have the real schema. `status/1` takes a function over the raw map,
  which is how a test describes the one thing it changes.
  """

  alias Dashboard.{Source, Status}

  @doc "The time the demo document was generated; tests use it as `now`."
  def now, do: document()["generated_at"]

  @doc "The demo document as decoded JSON."
  def document do
    Source.Demo.default_path() |> File.read!() |> Jason.decode!()
  end

  @doc "The demo reading, optionally with the raw document transformed first."
  def status(transform \\ & &1) do
    {:ok, status} = document() |> transform.() |> Status.parse()
    status
  end

  @doc "A host with no runners listed, no jobs and no lock file."
  def unused_status do
    status(fn document ->
      document
      |> Map.put("runners", [])
      |> Map.put("workers", [])
      |> Map.put("events", [])
      |> put_in(["slots", "records"], [])
      |> put_in(["slots", "used"], 0)
      |> Map.put("device_lock", %{
        "state" => "absent",
        "holder" => nil,
        "watchdog" => %{"min_age_seconds" => 600, "kill" => false, "stale" => []}
      })
    end)
  end

  @doc """
  Every runner up with no job, nobody waiting and the device lock free; the
  events are kept. `transform` runs on the raw document after that.
  """
  def idle_status(transform \\ & &1) do
    status(fn document ->
      document
      |> Map.update!("runners", fn runners ->
        Enum.map(runners, &%{&1 | "unit_state" => "active", "worker_pid" => nil})
      end)
      |> Map.put("workers", [])
      |> put_in(["slots", "records"], [])
      |> put_in(["slots", "used"], 0)
      |> put_in(["device_lock", "state"], "free")
      |> put_in(["device_lock", "holder"], nil)
      |> transform.()
    end)
  end

  @doc "The device lock held by a leaked descriptor: wrapper gone, watchdog reporting."
  def stale_lock_status do
    status(fn document ->
      document
      |> put_in(["device_lock", "holder", "alive"], false)
      |> put_in(["device_lock", "watchdog", "stale"], [
        %{"pid" => 50_112, "fd" => 17, "age_seconds" => 1840, "command" => "adb"}
      ])
    end)
  end
end
