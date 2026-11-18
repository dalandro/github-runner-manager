defmodule Dashboard.Snapshot do
  @moduledoc """
  What the poller knows: the last good reading, and whether the newest attempt
  failed. A failure keeps the last reading and marks it stale instead of
  blanking the page.
  """

  alias Dashboard.{Source, Status}

  defstruct status: nil,
            fetched_at: nil,
            changed_at: nil,
            error: nil,
            stale_since: nil,
            demo: false

  @type t :: %__MODULE__{
          status: Status.t() | nil,
          fetched_at: non_neg_integer() | nil,
          changed_at: non_neg_integer() | nil,
          error: Source.error() | nil,
          stale_since: non_neg_integer() | nil,
          demo: boolean()
        }

  @doc "Records a successful reading taken at `now` (epoch seconds)."
  @spec succeed(t(), Status.t(), non_neg_integer()) :: t()
  def succeed(%__MODULE__{} = snapshot, %Status{} = status, now),
    do: %{snapshot | status: status, fetched_at: now, error: nil, stale_since: nil}

  @doc """
  Records a failed attempt at `now`. The data has been stale since the last
  good reading, or since the first failure when there never was one.
  """
  @spec fail(t(), Source.error(), non_neg_integer()) :: t()
  def fail(%__MODULE__{} = snapshot, error, now),
    do: %{
      snapshot
      | error: error,
        stale_since: snapshot.stale_since || snapshot.fetched_at || now
    }

  @doc """
  Whether a subscriber would see a difference. Two good readings that differ
  only in when they were generated or fetched are the same picture.
  """
  @spec changed?(t(), t()) :: boolean()
  def changed?(%__MODULE__{} = old, %__MODULE__{} = new), do: comparable(old) != comparable(new)

  @doc "Whether a good reading arrived with a different fetch time."
  @spec read_since?(t(), t()) :: boolean()
  def read_since?(%__MODULE__{} = old, %__MODULE__{status: %Status{}, error: nil} = new),
    do: new.fetched_at != old.fetched_at

  def read_since?(%__MODULE__{}, %__MODULE__{}), do: false

  @doc """
  Whether the runner, slot, queue, lock or event picture changed. Load and
  memory are sampled on every reading, and a stale holder's age grows with
  every reading; neither counts, nor do failures and read times.
  """
  @spec state_changed?(t(), t()) :: boolean()
  def state_changed?(%__MODULE__{status: old}, %__MODULE__{status: new}),
    do: state(old) != state(new)

  @doc "Marks `now` as the moment the picture last changed."
  @spec mark_changed(t(), non_neg_integer()) :: t()
  def mark_changed(%__MODULE__{} = snapshot, now), do: %{snapshot | changed_at: now}

  defp state(nil), do: nil

  defp state(%Status{} = status),
    do: %{
      status
      | generated_at: nil,
        host: %{status.host | load_1m: nil, memory_available_mb: nil},
        device_lock: %{
          status.device_lock
          | stale: Enum.map(status.device_lock.stale, &%{&1 | age_seconds: nil})
        }
    }

  defp comparable(%__MODULE__{status: status} = snapshot) do
    %{
      snapshot
      | fetched_at: nil,
        changed_at: nil,
        status: status && %{status | generated_at: nil}
    }
  end
end
