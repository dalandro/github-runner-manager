defmodule Dashboard.EstimateTest do
  use ExUnit.Case, async: true

  alias Dashboard.Estimate

  describe "estimate/2" do
    test "gives no estimate below three samples" do
      assert %{state: :no_estimate, samples: 0, expected: nil, percent: nil} =
               Estimate.estimate([], 100)

      assert %{state: :no_estimate, samples: 2} = Estimate.estimate([300, 320], 100)
    end

    test "expects the median of the samples" do
      assert %{expected: 300, samples: 3} = Estimate.estimate([900, 300, 280], 0)
      # An even count takes the mean of the middle two, rounded down.
      assert %{expected: 305, samples: 4} = Estimate.estimate([280, 300, 311, 900], 0)
    end

    test "uses only the newest ten samples, the last in the list" do
      old = List.duplicate(5_000, 20)
      recent = [100, 110, 120, 130, 140, 150, 160, 170, 180, 190]

      assert %{expected: 145, samples: 10} = Estimate.estimate(old ++ recent, 0)
    end

    test "is on track, with the time left, until elapsed passes the expected time" do
      assert Estimate.estimate([600, 600, 600], 150) ==
               %{
                 state: :on_track,
                 samples: 3,
                 expected: 600,
                 percent: 25,
                 left: 450,
                 over_by: 0
               }

      assert %{state: :on_track, percent: 100, left: 0} = Estimate.estimate([600, 600, 600], 600)
    end

    test "is over once elapsed passes the expected time; the percent is not capped" do
      assert Estimate.estimate([600, 600, 600], 900) ==
               %{state: :over, samples: 3, expected: 600, percent: 150, left: 0, over_by: 300}
    end

    test "a zero expected time is over as soon as any time has passed" do
      assert %{state: :on_track, percent: 0} = Estimate.estimate([0, 0, 0], 0)
      assert %{state: :over, over_by: 5} = Estimate.estimate([0, 0, 0], 5)
    end

    test "with enough samples but an unknown elapsed time, has an expectation and no progress" do
      assert Estimate.estimate([600, 600, 600], nil) ==
               %{
                 state: :no_progress,
                 samples: 3,
                 expected: 600,
                 percent: nil,
                 left: nil,
                 over_by: nil
               }
    end
  end

  describe "words/1" do
    test "says how long is left in whole minutes, rounded up" do
      assert Estimate.words(Estimate.estimate([1_200, 1_200, 1_200], 0)) == "about 20 min left"
      assert Estimate.words(Estimate.estimate([1_200, 1_200, 1_200], 1_100)) == "about 2 min left"

      assert Estimate.words(Estimate.estimate([1_200, 1_200, 1_200], 1_170)) ==
               "under a minute left"
    end

    test "says how far over the expected time a job is" do
      assert Estimate.words(Estimate.estimate([600, 600, 600], 630)) == "just over expected"
      assert Estimate.words(Estimate.estimate([600, 600, 600], 790)) == "3 min over expected"
    end

    test "says when there is no estimate, and why" do
      assert Estimate.words(Estimate.estimate([], 10)) == "no estimate yet"

      assert Estimate.words(Estimate.estimate([600, 600], 10)) ==
               "no estimate yet: 2 of 3 runs"

      assert Estimate.words(Estimate.estimate([600, 600, 600], nil)) == "usually about 10 min"
    end
  end

  describe "about/1" do
    test "rounds a duration to minutes, or hours and minutes" do
      assert Estimate.about(20) == "under a minute"
      assert Estimate.about(89) == "1 min"
      assert Estimate.about(90) == "2 min"
      assert Estimate.about(3_600) == "1 h"
      assert Estimate.about(4_830) == "1 h 21 min"
    end
  end
end
