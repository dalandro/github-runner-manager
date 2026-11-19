defmodule Dashboard.JobDetailsTest do
  use ExUnit.Case, async: true

  alias Dashboard.{Fixtures, JobDetails}
  alias Dashboard.Status.{Job, SlotRecord}

  defp record(job, changes \\ []) do
    struct!(
      %SlotRecord{
        kind: :holding,
        ticket: 41,
        holder_pid: 52_877,
        units: 2,
        label: "org/web-app",
        since: 1_000,
        unparking: false,
        job: job
      },
      changes
    )
  end

  describe "pull_request/1" do
    test "takes the number the hook recorded from the event payload" do
      assert JobDetails.pull_request(%Job{pull_request: 57, ref: "refs/heads/main"}) == 57
    end

    test "derives the number from a pull request ref" do
      assert JobDetails.pull_request(%Job{ref: "refs/pull/212/merge"}) == 212
      assert JobDetails.pull_request(%Job{ref: "refs/pull/7/head"}) == 7
    end

    test "is nil for a branch, a tag, a malformed ref or no ref" do
      assert JobDetails.pull_request(%Job{ref: "refs/heads/main"}) == nil
      assert JobDetails.pull_request(%Job{ref: "refs/tags/v1.2"}) == nil
      assert JobDetails.pull_request(%Job{ref: "refs/pull/x/merge"}) == nil
      assert JobDetails.pull_request(%Job{ref: "refs/pull/0/merge"}) == nil
      assert JobDetails.pull_request(%Job{ref: "refs/pull/12/merge/extra"}) == nil
      assert JobDetails.pull_request(%Job{}) == nil
    end
  end

  describe "branch/1" do
    test "a pull request's head branch comes first" do
      assert JobDetails.branch(%Job{head_ref: "fix/late-rows", ref: "refs/pull/212/merge"}) ==
               "fix/late-rows"
    end

    test "otherwise the branch or tag the ref names" do
      assert JobDetails.branch(%Job{ref: "refs/heads/release/2.0"}) == "release/2.0"
      assert JobDetails.branch(%Job{ref: "refs/tags/v1.2"}) == "v1.2 (tag)"
    end

    test "is nil for a pull request ref without its head branch, or no ref" do
      assert JobDetails.branch(%Job{ref: "refs/pull/212/merge"}) == nil
      assert JobDetails.branch(%Job{head_ref: ""}) == nil
      assert JobDetails.branch(%Job{}) == nil
    end
  end

  describe "describe/1" do
    test "links the repository, run, pull request and commit on the recorded server" do
      # The demo records an example server, so its invented names link nowhere real.
      details = Fixtures.status().slots.records |> hd() |> JobDetails.describe()

      assert details.repository == "org/mobile-app"
      assert details.repository_url == "https://github.example.com/org/mobile-app"

      assert details.run_url ==
               "https://github.example.com/org/mobile-app/actions/runs/8123456789"

      assert details.pull_request == 57
      assert details.pull_request_title == "Keep drafts while offline"
      assert details.pull_request_url == "https://github.example.com/org/mobile-app/pull/57"
      assert details.branch == "feature/offline-drafts"
      assert details.short_sha == "3f9a1c2"

      assert details.commit_url ==
               "https://github.example.com/org/mobile-app/commit/3f9a1c27d84be5a0c6f1e2d93b7a4c58e1d06b72"

      assert %{workflow: "Android", job: "e2e-android", event: "pull_request"} = details
      assert %{actor: "dev-alex", runner: "mobile-app", run_id: "8123456789"} = details
    end

    test "a server of its own, such as GitHub Enterprise, keeps its links" do
      details =
        JobDetails.describe(
          record(%Job{
            repository: "team/tool",
            run_id: "5",
            server_url: "https://git.example.com:8443"
          })
        )

      assert details.run_url == "https://git.example.com:8443/team/tool/actions/runs/5"
    end

    test "a record from before job records falls back to its label and knows nothing else" do
      details = JobDetails.describe(record(%Job{}))

      assert details.repository == "org/web-app"
      assert details.repository_url == "https://github.com/org/web-app"

      assert %{
               run_url: nil,
               pull_request: nil,
               pull_request_url: nil,
               commit_url: nil,
               branch: nil,
               short_sha: nil,
               workflow: nil,
               event: nil
             } = details
    end

    test "a push or a manual run has no pull request, rather than an unknown one" do
      assert JobDetails.describe(record(%Job{event: "push", ref: "refs/heads/main"})).pull_request ==
               :none

      assert JobDetails.describe(record(%Job{event: "workflow_dispatch"})).pull_request == :none
      assert JobDetails.describe(record(%Job{event: "pull_request"})).pull_request == nil
    end

    test "an event that may belong to a pull request, or an unknown one, leaves it unknown" do
      for event <- ["issue_comment", "check_run", "event-1", nil] do
        assert JobDetails.describe(record(%Job{event: event})).pull_request == nil
      end
    end

    test "names that are not owner/name, such as aliases or the default label, get no links" do
      for repository <- ["runner-1", "org/../x", "org/a b", "https://evil.example/x", "org/."] do
        details =
          JobDetails.describe(
            record(%Job{repository: repository, run_id: "1", pull_request: 3, sha: "abcdef1"})
          )

        assert details.repository == repository

        assert %{repository_url: nil, run_url: nil, pull_request_url: nil, commit_url: nil} =
                 details
      end

      assert JobDetails.describe(record(%Job{}, label: "job")).repository_url == nil
    end

    test "fields that do not have their expected shape are shown but never linked" do
      for server <- [
            "javascript:alert(1)",
            "https://github.com/evil",
            "ftp://example.com",
            "https://..",
            "https://-",
            ""
          ] do
        details = JobDetails.describe(record(%Job{repository: "org/web-app", server_url: server}))
        assert details.repository_url == nil
      end

      details =
        JobDetails.describe(
          record(%Job{repository: "org/web-app", run_id: "12a", sha: "not-a-sha"})
        )

      assert %{run_url: nil, commit_url: nil, short_sha: nil, run_id: "12a"} = details

      for sha <- ["abcdef1", String.duplicate("a", 39), String.duplicate("a", 41)] do
        assert %{commit_url: nil, short_sha: nil} =
                 JobDetails.describe(record(%Job{repository: "org/web-app", sha: sha}))
      end

      sha256 = String.duplicate("b", 64)

      assert JobDetails.describe(record(%Job{repository: "org/web-app", sha: sha256})).commit_url ==
               "https://github.com/org/web-app/commit/" <> sha256
    end
  end

  describe "times/2" do
    test "a running job: when it reached the host, when it got its units, and how long since" do
      times =
        JobDetails.times(
          record(%Job{queued_at: 900}, kind: :holding, since: 1_000),
          1_300
        )

      assert times == %{queued_at: 900, started_at: 1_000, elapsed: 400}
    end

    test "a queued job has not started; without a record its queue time is the record's" do
      assert JobDetails.times(record(%Job{}, kind: :queued, since: 1_000), 1_060) ==
               %{queued_at: 1_000, started_at: nil, elapsed: 60}
    end

    test "a parked job's start is unknown once its record moved on" do
      assert JobDetails.times(record(%Job{}, kind: :parked, since: 1_000), 1_060) ==
               %{queued_at: nil, started_at: nil, elapsed: nil}
    end
  end
end
