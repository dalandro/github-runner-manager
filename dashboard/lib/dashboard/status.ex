defmodule Dashboard.Status do
  @moduledoc """
  One reading of the host, as printed by `grm-status --json` (schema 1,
  documented in `docs/status-json.md`).

  `parse/1` is the boundary: maps with string keys come in, structs with known
  shapes come out, and anything unexpected is an error instead of a `nil` that
  surfaces later in a template. Times stay as epoch seconds, as the tools write
  them; `Dashboard.Overview` turns them into durations.
  """

  alias __MODULE__.{
    DeviceLock,
    Event,
    Host,
    LockHolder,
    Runner,
    SlotRecord,
    Slots,
    StaleHolder,
    Worker
  }

  @schema 1

  @enforce_keys [:generated_at, :host, :runners, :workers, :slots, :device_lock, :events]
  defstruct [:generated_at, :host, :runners, :workers, :slots, :device_lock, :events]

  @type t :: %__MODULE__{
          generated_at: non_neg_integer(),
          host: Host.t(),
          runners: [Runner.t()],
          workers: [Worker.t()],
          slots: Slots.t(),
          device_lock: DeviceLock.t(),
          events: [Event.t()]
        }

  @type error ::
          {:invalid_json, String.t()}
          | {:unsupported_schema, term()}
          | {:invalid_field, String.t()}

  defmodule Host do
    @moduledoc "Load and memory readings with the thresholds `wait-for-load` applies."
    @enforce_keys [:cpus, :load_1m, :max_load, :memory_available_mb, :min_memory_mb]
    defstruct [:cpus, :load_1m, :max_load, :memory_available_mb, :min_memory_mb]

    @type t :: %__MODULE__{
            cpus: pos_integer() | nil,
            load_1m: number() | nil,
            max_load: number() | nil,
            memory_available_mb: non_neg_integer() | nil,
            min_memory_mb: non_neg_integer() | nil
          }
  end

  defmodule Runner do
    @moduledoc "A configured runner, its systemd unit state and its job worker, if any."
    @enforce_keys [:name, :repository, :units, :labels, :unit, :unit_state, :worker_pid]
    defstruct [:name, :repository, :units, :labels, :unit, :unit_state, :worker_pid]

    @type t :: %__MODULE__{
            name: String.t(),
            repository: String.t(),
            units: pos_integer() | nil,
            labels: String.t(),
            unit: String.t(),
            unit_state: String.t(),
            worker_pid: pos_integer() | nil
          }
  end

  defmodule Worker do
    @moduledoc "A busy job worker and the runner directory its executable lives in."
    @enforce_keys [:pid, :directory]
    defstruct [:pid, :directory]

    @type t :: %__MODULE__{
            pid: pos_integer(),
            directory: String.t()
          }
  end

  defmodule SlotRecord do
    @moduledoc "One job known to the slot gate: holding units, queued for them, or parked."
    @enforce_keys [:kind, :ticket, :holder_pid, :units, :label, :since, :unparking]
    defstruct [:kind, :ticket, :holder_pid, :units, :label, :since, :unparking]

    @type kind :: :holding | :queued | :parked
    @type t :: %__MODULE__{
            kind: kind(),
            ticket: non_neg_integer(),
            holder_pid: pos_integer(),
            units: pos_integer(),
            label: String.t(),
            since: non_neg_integer() | nil,
            unparking: boolean()
          }
  end

  defmodule Slots do
    @moduledoc "The weighted job-slot pool."
    @enforce_keys [:capacity, :used, :max_wait_seconds, :records]
    defstruct [:capacity, :used, :max_wait_seconds, :records]

    @type t :: %__MODULE__{
            capacity: pos_integer(),
            used: non_neg_integer(),
            max_wait_seconds: non_neg_integer() | nil,
            records: [Dashboard.Status.SlotRecord.t()]
          }
  end

  defmodule LockHolder do
    @moduledoc "What the device-lock wrapper recorded about itself."
    @enforce_keys [:repository, :run_id, :job, :pid, :since, :alive]
    defstruct [:repository, :run_id, :job, :pid, :since, :alive]

    @type t :: %__MODULE__{
            repository: String.t(),
            run_id: String.t(),
            job: String.t(),
            pid: non_neg_integer() | nil,
            since: non_neg_integer() | nil,
            alive: boolean()
          }
  end

  defmodule StaleHolder do
    @moduledoc "A process the watchdog would report: it holds the lock but is not the wrapper."
    @enforce_keys [:pid, :fd, :age_seconds, :command]
    defstruct [:pid, :fd, :age_seconds, :command]

    @type t :: %__MODULE__{
            pid: pos_integer(),
            fd: non_neg_integer(),
            age_seconds: non_neg_integer(),
            command: String.t()
          }
  end

  defmodule DeviceLock do
    @moduledoc "The exclusive device lock and the watchdog's view of it."
    @enforce_keys [:state, :holder, :watchdog_min_age_seconds, :watchdog_kill, :stale]
    defstruct [:state, :holder, :watchdog_min_age_seconds, :watchdog_kill, :stale]

    @type state :: :absent | :free | :held
    @type t :: %__MODULE__{
            state: state(),
            holder: Dashboard.Status.LockHolder.t() | nil,
            watchdog_min_age_seconds: non_neg_integer() | nil,
            watchdog_kill: boolean(),
            stale: [Dashboard.Status.StaleHolder.t()]
          }
  end

  defmodule Event do
    @moduledoc "One line of the gates' event log."
    @enforce_keys [:at, :kind, :subject, :detail]
    defstruct [:at, :kind, :subject, :detail]

    @type t :: %__MODULE__{
            at: non_neg_integer(),
            kind: String.t(),
            subject: String.t(),
            detail: String.t()
          }
  end

  @doc "Decodes and parses the JSON text printed by `grm-status --json`."
  @spec decode(binary()) :: {:ok, t()} | {:error, error()}
  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, document} -> parse(document)
      {:error, error} -> {:error, {:invalid_json, Exception.message(error)}}
    end
  end

  @doc "Parses a decoded status document, rejecting schemas this reader does not know."
  @spec parse(term()) :: {:ok, t()} | {:error, error()}
  def parse(%{"schema" => @schema} = document) do
    {:ok,
     %__MODULE__{
       generated_at: integer!(document, "generated_at"),
       host: host!(map!(document, "host")),
       runners: document |> list!("runners") |> Enum.map(&runner!/1),
       workers:
         document |> Map.put_new("workers", []) |> list!("workers") |> Enum.map(&worker!/1),
       slots: slots!(map!(document, "slots")),
       device_lock: device_lock!(map!(document, "device_lock")),
       events: document |> list!("events") |> Enum.map(&event!/1)
     }}
  catch
    {:invalid_field, _name} = error -> {:error, error}
  end

  def parse(%{"schema" => other}), do: {:error, {:unsupported_schema, other}}
  def parse(_other), do: {:error, {:unsupported_schema, nil}}

  defp host!(host) do
    %Host{
      cpus: optional_integer!(host, "cpus"),
      load_1m: optional_number!(host, "load_1m"),
      max_load: optional_number!(host, "max_load"),
      memory_available_mb: optional_integer!(host, "memory_available_mb"),
      min_memory_mb: optional_integer!(host, "min_memory_mb")
    }
  end

  defp runner!(runner) when is_map(runner) do
    %Runner{
      name: string!(runner, "name"),
      repository: string!(runner, "repository"),
      units: optional_integer!(runner, "units"),
      labels: string!(runner, "labels"),
      unit: string!(runner, "unit"),
      unit_state: string!(runner, "unit_state"),
      worker_pid: optional_integer!(runner, "worker_pid")
    }
  end

  defp runner!(_other), do: throw({:invalid_field, "runners"})

  defp worker!(worker) when is_map(worker) do
    %Worker{
      pid: integer!(worker, "pid"),
      directory: string!(worker, "directory")
    }
  end

  defp worker!(_other), do: throw({:invalid_field, "workers"})

  defp slots!(slots) do
    %Slots{
      capacity: integer!(slots, "capacity"),
      used: integer!(slots, "used"),
      max_wait_seconds: optional_integer!(slots, "max_wait_seconds"),
      records: slots |> list!("records") |> Enum.map(&slot_record!/1)
    }
  end

  defp slot_record!(record) when is_map(record) do
    %SlotRecord{
      kind: record |> string!("kind") |> slot_kind!(),
      ticket: integer!(record, "ticket"),
      holder_pid: integer!(record, "holder_pid"),
      units: integer!(record, "units"),
      label: string!(record, "label"),
      since: optional_integer!(record, "since"),
      unparking: boolean!(record, "unparking")
    }
  end

  defp slot_record!(_other), do: throw({:invalid_field, "slots.records"})

  # Explicit clauses instead of String.to_existing_atom/1: the set is closed and
  # an unknown kind is a schema violation, not a new atom.
  defp slot_kind!("holding"), do: :holding
  defp slot_kind!("queued"), do: :queued
  defp slot_kind!("parked"), do: :parked
  defp slot_kind!(_other), do: throw({:invalid_field, "slots.records.kind"})

  defp device_lock!(lock) do
    watchdog = map!(lock, "watchdog")

    %DeviceLock{
      state: lock |> string!("state") |> lock_state!(),
      holder: lock_holder!(Map.get(lock, "holder")),
      watchdog_min_age_seconds: optional_integer!(watchdog, "min_age_seconds"),
      watchdog_kill: boolean!(watchdog, "kill"),
      stale: watchdog |> list!("stale") |> Enum.map(&stale_holder!/1)
    }
  end

  defp lock_state!("absent"), do: :absent
  defp lock_state!("free"), do: :free
  defp lock_state!("held"), do: :held
  defp lock_state!(_other), do: throw({:invalid_field, "device_lock.state"})

  defp lock_holder!(nil), do: nil

  defp lock_holder!(holder) when is_map(holder) do
    %LockHolder{
      repository: string!(holder, "repository"),
      run_id: string!(holder, "run_id"),
      job: string!(holder, "job"),
      pid: optional_integer!(holder, "pid"),
      since: optional_integer!(holder, "since"),
      alive: boolean!(holder, "alive")
    }
  end

  defp lock_holder!(_other), do: throw({:invalid_field, "device_lock.holder"})

  defp stale_holder!(holder) when is_map(holder) do
    %StaleHolder{
      pid: integer!(holder, "pid"),
      fd: integer!(holder, "fd"),
      age_seconds: integer!(holder, "age_seconds"),
      command: string!(holder, "command")
    }
  end

  defp stale_holder!(_other), do: throw({:invalid_field, "device_lock.watchdog.stale"})

  defp event!(event) when is_map(event) do
    %Event{
      at: integer!(event, "at"),
      kind: string!(event, "kind"),
      subject: string!(event, "subject"),
      detail: string!(event, "detail")
    }
  end

  defp event!(_other), do: throw({:invalid_field, "events"})

  defp map!(map, key), do: fetch!(map, key, &is_map/1)
  defp list!(map, key), do: fetch!(map, key, &is_list/1)
  defp string!(map, key), do: fetch!(map, key, &is_binary/1)
  defp boolean!(map, key), do: fetch!(map, key, &is_boolean/1)
  defp integer!(map, key), do: fetch!(map, key, &non_negative_integer?/1)

  defp optional_integer!(map, key),
    do: fetch!(map, key, &(is_nil(&1) or non_negative_integer?(&1)))

  defp optional_number!(map, key), do: fetch!(map, key, &(is_nil(&1) or is_number(&1)))

  defp non_negative_integer?(value), do: is_integer(value) and value >= 0

  defp fetch!(map, key, valid?) do
    case Map.fetch(map, key) do
      {:ok, value} -> if valid?.(value), do: value, else: throw({:invalid_field, key})
      :error -> throw({:invalid_field, key})
    end
  end
end
