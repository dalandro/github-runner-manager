defmodule Dashboard.Source.Demo do
  @moduledoc """
  Serves the bundled sample reading (`priv/demo/status.json`) so the page can
  be seen without runners. The same file is the test fixture on both sides of
  the seam: the Bash suite checks its shape against real `grm-status --json`.

  To look alive, the sample is replayed on a loop: every time in it moves so
  that the reading was "generated now", and waits grow for `@cycle_seconds`
  before starting over. The load figure drifts a little around its recorded
  value. Both are functions of the clock alone (`replay/2`), so there is no
  state to keep.

  Options: `:path` to serve another document, for example to look at a rare
  state such as a stale lock.
  """

  @behaviour Dashboard.Source

  alias Dashboard.Status

  @cycle_seconds 600

  @impl true
  def demo?, do: true

  @impl true
  def fetch(options) do
    path = Keyword.get_lazy(options, :path, &default_path/0)
    now = Keyword.get_lazy(options, :now, fn -> System.system_time(:second) end)

    with {:ok, json} <- read(path),
         {:ok, status} <- Status.decode(json) do
      {:ok, replay(status, now)}
    end
  end

  @doc "The path of the bundled sample."
  @spec default_path() :: String.t()
  def default_path, do: Application.app_dir(:dashboard, "priv/demo/status.json")

  @doc """
  Moves a recorded reading to `now`: ages advance by the position in the
  replay cycle and the load drifts by at most ±0.4 around the recorded value.
  """
  @spec replay(Status.t(), non_neg_integer()) :: Status.t()
  def replay(%Status{} = status, now) do
    shift = now - status.generated_at - rem(now, @cycle_seconds)
    move = fn time -> time && time + shift end

    %Status{
      status
      | generated_at: now,
        host: %{status.host | load_1m: drift(status.host.load_1m, now)},
        slots: %{
          status.slots
          | records:
              Enum.map(status.slots.records, fn record ->
                %{
                  record
                  | since: move.(record.since),
                    job: %{record.job | queued_at: move.(record.job.queued_at)}
                }
              end)
        },
        device_lock: %{
          status.device_lock
          | holder:
              status.device_lock.holder && Map.update!(status.device_lock.holder, :since, move)
        },
        events: Enum.map(status.events, &%{&1 | at: move.(&1.at)})
    }
  end

  defp drift(nil, _now), do: nil
  defp drift(load, now), do: Float.round(load + 0.4 * :math.sin(now / 9), 2)

  defp read(path) do
    case File.read(path) do
      {:ok, json} -> {:ok, json}
      {:error, _reason} -> {:error, {:unreadable, "the demo file"}}
    end
  end
end
