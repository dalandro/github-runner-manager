defmodule Dashboard.SnapshotTest do
  use ExUnit.Case, async: true

  alias Dashboard.{Fixtures, Snapshot}

  test "a failure keeps the last reading and dates the staleness from it" do
    good = Snapshot.succeed(%Snapshot{}, Fixtures.status(), 1_000)
    failed = good |> Snapshot.fail(:timeout, 1_010) |> Snapshot.fail(:timeout, 1_020)

    assert failed.status == good.status
    assert failed.error == :timeout
    assert failed.stale_since == 1_000
  end

  test "failing before any reading dates the staleness from the first failure" do
    failed = %Snapshot{} |> Snapshot.fail(:timeout, 1_010) |> Snapshot.fail(:timeout, 1_020)

    assert failed.status == nil
    assert failed.stale_since == 1_010
  end

  test "a good reading clears the failure" do
    recovered =
      %Snapshot{} |> Snapshot.fail(:timeout, 1_010) |> Snapshot.succeed(Fixtures.status(), 1_020)

    assert %Snapshot{error: nil, stale_since: nil, fetched_at: 1_020} = recovered
  end

  test "readings that differ only in their timestamps are the same picture" do
    status = Fixtures.status()
    old = Snapshot.succeed(%Snapshot{}, status, 1_000)
    new = Snapshot.succeed(old, %{status | generated_at: status.generated_at + 2}, 1_002)

    refute Snapshot.changed?(old, new)
  end

  test "a different reading, a failure and a recovery are all changes" do
    status = Fixtures.status()
    old = Snapshot.succeed(%Snapshot{}, status, 1_000)
    busier = %{status | slots: %{status.slots | used: 6}}

    assert Snapshot.changed?(old, Snapshot.succeed(old, busier, 1_002))
    assert Snapshot.changed?(old, Snapshot.fail(old, :timeout, 1_002))
    assert Snapshot.changed?(Snapshot.fail(old, :timeout, 1_002), old)
  end
end
