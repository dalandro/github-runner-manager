defmodule Dashboard.Relay.InboxTest do
  use ExUnit.Case, async: true

  alias Dashboard.Fixtures
  alias Dashboard.Relay.Inbox

  test "holds nothing until the first push, then the latest accepted one" do
    inbox = start_supervised!({Inbox, name: nil})
    status = Fixtures.status()
    newer = %{status | generated_at: status.generated_at + 5}
    older = %{status | generated_at: status.generated_at - 5}

    assert Inbox.latest(inbox) == nil

    assert Inbox.offer(inbox, status, 1_000) == :ok
    assert Inbox.offer(inbox, newer, 1_005) == :ok
    assert Inbox.offer(inbox, older, 1_006) == {:error, :older}

    assert Inbox.latest(inbox) == %{status: newer, received_at: 1_005}
  end
end
