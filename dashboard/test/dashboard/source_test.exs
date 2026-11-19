defmodule Dashboard.SourceTest do
  use ExUnit.Case, async: true

  alias Dashboard.{Fixtures, Source, Status}
  alias Dashboard.Relay.Inbox
  alias Dashboard.Source.{Command, Demo, Relay}

  describe "Command" do
    @describetag :tmp_dir

    defp script(tmp_dir, body) do
      path = Path.join(tmp_dir, "grm-status")
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      path
    end

    test "runs the command with --json and parses its output", %{tmp_dir: tmp_dir} do
      fixture = Demo.default_path()
      command = script(tmp_dir, ~s([ "$#" = 1 ] && [ "$1" = --json ] && cat "#{fixture}"\n))

      assert {:ok, %Status{} = status} = Command.fetch(command: command)
      assert status.generated_at == Fixtures.now()
    end

    test "reports a failing command with its exit status", %{tmp_dir: tmp_dir} do
      command = script(tmp_dir, "echo broken; exit 2\n")

      assert {:error, {:exit_status, 2, "broken\n"}} = Command.fetch(command: command)
    end

    test "reports output that is not a status document", %{tmp_dir: tmp_dir} do
      assert {:error, {:invalid_json, _message}} =
               Command.fetch(command: script(tmp_dir, "echo capacity 6\n"))

      assert {:error, {:unsupported_schema, 9}} =
               Command.fetch(command: script(tmp_dir, ~s(echo '{"schema": 9}'\n)))
    end

    test "gives up on a command that hangs", %{tmp_dir: tmp_dir} do
      command = script(tmp_dir, "sleep 30\n")

      assert {:error, :timeout} = Command.fetch(command: command, timeout_seconds: 1)
    end

    test "reports a command that does not exist", %{tmp_dir: tmp_dir} do
      assert {:error, {:exit_status, status, _output}} =
               Command.fetch(command: Path.join(tmp_dir, "missing"))

      assert status in [126, 127]
    end
  end

  describe "Demo" do
    test "serves the bundled document as if it were generated now" do
      now = Fixtures.now() + 86_400 * 30

      assert {:ok, %Status{generated_at: ^now} = status} = Demo.fetch(now: now)
      assert length(status.runners) == 8
    end

    test "ages advance with the replay cycle and then start over" do
      recorded = Fixtures.status()
      start = 6_000_000

      waits =
        for offset <- [0, 45, 599, 600] do
          {:ok, status} = Demo.fetch(now: start + offset)
          [first | _rest] = Dashboard.Overview.queue(status.slots)
          start + offset - first.since
        end

      recorded_wait = Dashboard.Overview.longest_wait(recorded.slots, recorded.generated_at)
      assert waits == Enum.map([0, 45, 599, 0], &(&1 + recorded_wait))
    end

    test "a job's arrival moves with its record, and an unknown one stays unknown" do
      recorded = Fixtures.status()
      {:ok, status} = Demo.fetch(now: 6_000_000)

      for {before, now} <- Enum.zip(recorded.slots.records, status.slots.records) do
        if before.job.queued_at,
          do: assert(now.since - now.job.queued_at == before.since - before.job.queued_at),
          else: assert(now.job.queued_at == nil)
      end
    end

    test "the load drifts a little around the recorded value" do
      for now <- 1..40 do
        {:ok, status} = Demo.fetch(now: 5_000_000 + now)
        assert_in_delta status.host.load_1m, 4.31, 0.41
      end
    end

    test "serves another document when given a path" do
      assert {:error, {:unreadable, "the demo file"}} =
               Demo.fetch(path: "/nonexistent/status.json")
    end
  end

  describe "Relay" do
    setup do
      %{status: Fixtures.status(), inbox: start_supervised!({Inbox, name: nil})}
    end

    test "waits for the first push", %{inbox: inbox} do
      assert Relay.fetch(inbox: inbox, interval_seconds: 5, now: 1_000) ==
               {:error, :no_push_yet}
    end

    test "serves the latest push, read when it arrived, until it is stale", context do
      :ok = Inbox.offer(context.inbox, context.status, 1_000)
      options = [inbox: context.inbox, interval_seconds: 5]

      assert Relay.fetch([now: 1_000] ++ options) == {:ok, context.status, 1_000}
      assert Relay.fetch([now: 1_030] ++ options) == {:ok, context.status, 1_000}
      assert Relay.fetch([now: 1_031] ++ options) == {:error, {:no_push, 1_000}}
    end

    test "allows a slower host more time", context do
      :ok = Inbox.offer(context.inbox, context.status, 1_000)

      assert {:ok, _status, 1_000} =
               Relay.fetch(inbox: context.inbox, interval_seconds: 60, now: 1_180)

      assert {:error, {:no_push, 1_000}} =
               Relay.fetch(inbox: context.inbox, interval_seconds: 60, now: 1_181)
    end
  end

  test "every error has a sentence for the page" do
    errors = [
      :timeout,
      {:exit_status, 2, "x"},
      {:unreadable, "the demo file"},
      {:crashed, "x"},
      {:invalid_json, "x"},
      {:invalid_field, "capacity"},
      {:unsupported_schema, 2},
      :no_push_yet,
      {:no_push, 1_000}
    ]

    for error <- errors do
      assert Source.describe_error(error) =~ ~r/^[a-z]/
    end
  end
end
