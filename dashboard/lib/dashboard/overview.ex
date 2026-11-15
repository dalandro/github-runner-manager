defmodule Dashboard.Overview do
  @moduledoc """
  Pure functions that turn a `Dashboard.Status` into what the page states:
  who is doing what, how full the pool is, who waits and for how long, whether
  the device lock is healthy, and whether the load gate is open.

  Nothing here reads a clock or a process; `now` is always an argument (epoch
  seconds), so every derived value can be tested with plain data.
  """

  alias Dashboard.Status
  alias Dashboard.Status.{DeviceLock, Host, Runner, SlotRecord, Slots}

  @type activity :: :running | :queued | :parked | :idle | :down

  @doc """
  What each runner is doing, in configuration order.

  A runner's job is matched to its slot record through the worker pid, which is
  the holder the job hooks register.

    * `:down` - the systemd unit is not active
    * `:idle` - the unit is up and no job worker is running
    * `:queued` - a job is waiting for slot units
    * `:parked` - a job gave its units back while it waits for the device
    * `:running` - a job is running (holding units, or outside the slot gate)
  """
  @spec runners(Status.t()) :: [
          %{runner: Runner.t(), activity: activity(), record: SlotRecord.t() | nil}
        ]
  def runners(%Status{runners: runners, slots: %Slots{records: records}}) do
    by_holder = Map.new(records, &{&1.holder_pid, &1})

    Enum.map(runners, fn runner ->
      record = runner.worker_pid && Map.get(by_holder, runner.worker_pid)
      %{runner: runner, activity: activity(runner, record), record: record}
    end)
  end

  defp activity(%Runner{unit_state: state}, _record) when state != "active", do: :down
  defp activity(%Runner{worker_pid: nil}, _record), do: :idle
  defp activity(_runner, %SlotRecord{kind: :queued}), do: :queued
  defp activity(_runner, %SlotRecord{kind: :parked}), do: :parked
  defp activity(_runner, _record), do: :running

  @doc "Counts runners per activity, for the summary line."
  @spec runner_counts(Status.t()) :: %{activity() => non_neg_integer()}
  def runner_counts(%Status{} = status) do
    counts = status |> runners() |> Enum.frequencies_by(& &1.activity)
    Map.merge(%{running: 0, queued: 0, parked: 0, idle: 0, down: 0}, counts)
  end

  @doc """
  How full the pool is. `used` can exceed `capacity`: the gate admits an
  oversized job alone and admits anyone after the maximum wait.
  """
  @spec utilisation(Slots.t()) :: %{
          used: non_neg_integer(),
          capacity: pos_integer(),
          free: non_neg_integer(),
          percent: non_neg_integer(),
          overcommitted: boolean()
        }
  def utilisation(%Slots{used: used, capacity: capacity}) do
    %{
      used: used,
      capacity: capacity,
      free: max(capacity - used, 0),
      percent: if(capacity > 0, do: round(used * 100 / capacity), else: 0),
      overcommitted: used > capacity
    }
  end

  @doc "Records holding units, longest-held first; records without a time come last."
  @spec holders(Slots.t()) :: [SlotRecord.t()]
  def holders(%Slots{records: records}) do
    records
    |> Enum.filter(&(&1.kind == :holding))
    |> Enum.sort_by(&{is_nil(&1.since), &1.since, &1.ticket})
  end

  @doc """
  Who is waiting for units, in the order the gate will admit them: jobs asking
  for their parked units back first, then the queue, each by ticket.
  """
  @spec queue(Slots.t()) :: [SlotRecord.t()]
  def queue(%Slots{records: records}) do
    records
    |> Enum.filter(&(&1.kind == :queued or (&1.kind == :parked and &1.unparking)))
    |> Enum.sort_by(&{&1.kind == :queued, &1.ticket})
  end

  @doc "Jobs that returned their units and are waiting for the device, not for units."
  @spec parked(Slots.t()) :: [SlotRecord.t()]
  def parked(%Slots{records: records}) do
    records
    |> Enum.filter(&(&1.kind == :parked and not &1.unparking))
    |> Enum.sort_by(& &1.ticket)
  end

  @doc "Seconds since an epoch time, never negative; `nil` when the time is unknown."
  @spec elapsed(non_neg_integer() | nil, non_neg_integer()) :: non_neg_integer() | nil
  def elapsed(nil, _now), do: nil
  def elapsed(since, now), do: max(now - since, 0)

  @doc "The longest current wait in the queue, in seconds, or `nil` when nobody waits."
  @spec longest_wait(Slots.t(), non_neg_integer()) :: non_neg_integer() | nil
  def longest_wait(%Slots{} = slots, now) do
    slots
    |> queue()
    |> Enum.map(&elapsed(&1.since, now))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  @doc """
  Whether a waiting job has passed the gate's maximum wait, after which the
  gate admits it regardless of capacity.
  """
  @spec overdue?(SlotRecord.t(), Slots.t(), non_neg_integer()) :: boolean()
  def overdue?(%SlotRecord{since: since}, %Slots{max_wait_seconds: max_wait}, now)
      when is_integer(since) and is_integer(max_wait),
      do: now - since >= max_wait

  def overdue?(_record, _slots, _now), do: false

  @doc """
  The device lock in one word.

    * `:absent` - never used on this host
    * `:free` - nobody holds it
    * `:held` - held by a live wrapper, nothing suspicious
    * `:orphaned` - held, but no live wrapper claims it; the watchdog will call
      it stale once the holding process is old enough
    * `:stale` - the watchdog reports at least one stale holder
  """
  @spec lock_condition(DeviceLock.t()) :: :absent | :free | :held | :orphaned | :stale
  def lock_condition(%DeviceLock{stale: [_ | _]}), do: :stale
  def lock_condition(%DeviceLock{state: :held, holder: %{alive: true}}), do: :held
  def lock_condition(%DeviceLock{state: :held}), do: :orphaned
  def lock_condition(%DeviceLock{state: state}), do: state

  @doc """
  The load gate as `wait-for-load` evaluates it: open when load is strictly
  below the limit and available memory is at or above the minimum. A missing
  reading is `:unknown`, and an unknown reading does not open the gate.
  """
  @spec load_gate(Host.t()) :: %{
          load: :ok | :over | :unknown,
          memory: :ok | :under | :unknown,
          open: boolean()
        }
  def load_gate(%Host{} = host) do
    load = compare_load(host.load_1m, host.max_load)
    memory = compare_memory(host.memory_available_mb, host.min_memory_mb)
    %{load: load, memory: memory, open: load == :ok and memory == :ok}
  end

  defp compare_load(nil, _maximum), do: :unknown
  defp compare_load(_load, nil), do: :unknown
  defp compare_load(load, maximum) when load < maximum, do: :ok
  defp compare_load(_load, _maximum), do: :over

  defp compare_memory(nil, _minimum), do: :unknown
  defp compare_memory(_available, nil), do: :unknown
  defp compare_memory(available, minimum) when available >= minimum, do: :ok
  defp compare_memory(_available, _minimum), do: :under

  @doc """
  Position of a reading on a meter, as a whole percentage clamped to 0..100.
  The scale is the caller's choice; the page uses twice the threshold for load
  so the limit sits mid-scale.
  """
  @spec meter_percent(number() | nil, number() | nil) :: non_neg_integer()
  def meter_percent(nil, _scale), do: 0
  def meter_percent(_value, nil), do: 0
  def meter_percent(_value, scale) when scale <= 0, do: 0
  def meter_percent(value, scale), do: (value * 100 / scale) |> round() |> max(0) |> min(100)

  @doc """
  A duration in the two most significant units: `"42s"`, `"3m 05s"`,
  `"2h 07m"`, `"3d 04h"`. Unknown durations render as an em dash.
  """
  @spec format_duration(non_neg_integer() | nil) :: String.t()
  def format_duration(nil), do: "—"
  def format_duration(seconds) when seconds < 60, do: "#{seconds}s"

  def format_duration(seconds) when seconds < 3600,
    do: "#{div(seconds, 60)}m #{pad(rem(seconds, 60))}s"

  def format_duration(seconds) when seconds < 86_400,
    do: "#{div(seconds, 3600)}h #{pad(div(rem(seconds, 3600), 60))}m"

  def format_duration(seconds),
    do: "#{div(seconds, 86_400)}d #{pad(div(rem(seconds, 86_400), 3600))}h"

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")

  @doc "Memory in gigabytes with one decimal, from mebibytes as the tools report them."
  @spec format_memory(non_neg_integer() | nil) :: String.t()
  def format_memory(nil), do: "—"
  def format_memory(megabytes), do: :erlang.float_to_binary(megabytes / 1024, decimals: 1)
end
