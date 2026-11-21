defmodule Dashboard.Estimate do
  @moduledoc """
  Pure functions that turn how long a job's recent runs took
  (`Dashboard.Status.Job`, `recent_durations`) into how long this run is
  expected to take and how far along it is, the way Rundeck shows a running
  job against its average duration.

  The expected time is the median of the newest ten samples, so one run that
  hung or failed early does not move it much. Below three samples there is no
  estimate. Nothing here reads a clock; `elapsed` is an argument.
  """

  @window 10
  @minimum 3

  @type state :: :no_estimate | :no_progress | :on_track | :over
  @type t :: %{
          state: state(),
          samples: non_neg_integer(),
          expected: non_neg_integer() | nil,
          percent: non_neg_integer() | nil,
          left: non_neg_integer() | nil,
          over_by: non_neg_integer() | nil
        }

  @doc """
  The estimate for a run `elapsed` seconds in, from earlier runs' durations in
  seconds, oldest first. `percent` is elapsed as a share of the expected time
  and goes past 100 once the run is over it. `elapsed` is `nil` when unknown.
  """
  @spec estimate([non_neg_integer()], non_neg_integer() | nil) :: t()
  def estimate(durations, elapsed) do
    samples = Enum.take(durations, -@window)
    count = length(samples)

    cond do
      count < @minimum ->
        %{
          state: :no_estimate,
          samples: count,
          expected: nil,
          percent: nil,
          left: nil,
          over_by: nil
        }

      elapsed == nil ->
        %{
          state: :no_progress,
          samples: count,
          expected: median(samples),
          percent: nil,
          left: nil,
          over_by: nil
        }

      true ->
        progress(median(samples), elapsed, count)
    end
  end

  @doc "What the estimate means for the person watching, in a few words."
  @spec words(t()) :: String.t()
  def words(%{state: :no_estimate, samples: 0}), do: "no estimate yet"

  def words(%{state: :no_estimate, samples: samples}),
    do: "no estimate yet: #{samples} of #{@minimum} runs"

  def words(%{state: :no_progress, expected: expected}), do: "usually about #{about(expected)}"
  def words(%{state: :on_track, left: left}) when left < 60, do: "under a minute left"
  def words(%{state: :on_track, left: left}), do: "about #{div(left + 59, 60)} min left"
  def words(%{state: :over, over_by: over_by}) when over_by < 60, do: "just over expected"
  def words(%{state: :over, over_by: over_by}), do: "#{div(over_by, 60)} min over expected"

  @doc "A duration rounded to whole minutes, or hours and minutes past an hour."
  @spec about(non_neg_integer()) :: String.t()
  def about(seconds) when seconds < 60, do: "under a minute"

  def about(seconds) do
    minutes = div(seconds + 30, 60)

    case {div(minutes, 60), rem(minutes, 60)} do
      {0, minutes} -> "#{minutes} min"
      {hours, 0} -> "#{hours} h"
      {hours, minutes} -> "#{hours} h #{minutes} min"
    end
  end

  defp progress(expected, elapsed, count) do
    %{
      state: if(elapsed > expected, do: :over, else: :on_track),
      samples: count,
      expected: expected,
      percent: div(elapsed * 100, max(expected, 1)),
      left: max(expected - elapsed, 0),
      over_by: max(elapsed - expected, 0)
    }
  end

  defp median(samples) do
    sorted = Enum.sort(samples)
    middle = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1,
      do: Enum.at(sorted, middle),
      else: div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
  end
end
