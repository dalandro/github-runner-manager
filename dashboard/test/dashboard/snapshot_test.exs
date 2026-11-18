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

  test "load and memory moving is news to show, but not a change of state" do
    status = Fixtures.status()
    old = Snapshot.succeed(%Snapshot{}, status, 1_000)
    sampled = %{status | host: %{status.host | load_1m: 5.02, memory_available_mb: 5_190}}
    new = Snapshot.succeed(old, sampled, 1_002)

    assert Snapshot.changed?(old, new)
    refute Snapshot.state_changed?(old, new)
  end

  test "a stale holder growing older is not a change of state" do
    status = Fixtures.stale_lock_status()
    old = Snapshot.succeed(%Snapshot{}, status, 1_000)
    [holder] = status.device_lock.stale
    older = put_in(status.device_lock.stale, [%{holder | age_seconds: holder.age_seconds + 2}])

    refute Snapshot.state_changed?(old, Snapshot.succeed(old, older, 1_002))
  end

  test "the first reading and a different runner, slot or lock picture change state" do
    status = Fixtures.status()
    old = Snapshot.succeed(%Snapshot{}, status, 1_000)
    busier = %{status | slots: %{status.slots | used: 6}}
    freed = %{status | device_lock: %{status.device_lock | state: :free, holder: nil}}

    assert Snapshot.state_changed?(%Snapshot{}, old)
    assert Snapshot.state_changed?(old, Snapshot.succeed(old, busier, 1_002))
    assert Snapshot.state_changed?(old, Snapshot.succeed(old, freed, 1_002))
  end

  test "a failure and a recovery to the same picture are not changes of state" do
    old = Snapshot.succeed(%Snapshot{}, Fixtures.status(), 1_000)
    failed = Snapshot.fail(old, :timeout, 1_002)

    refute Snapshot.state_changed?(old, failed)
    refute Snapshot.state_changed?(failed, Snapshot.succeed(failed, old.status, 1_004))
  end
end
