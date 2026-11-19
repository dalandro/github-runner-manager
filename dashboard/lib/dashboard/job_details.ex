defmodule Dashboard.JobDetails do
  @moduledoc """
  Pure functions that turn what the job hook recorded about a slot holder's
  job (`Dashboard.Status.Job`) into what the job's detail view states: the
  pull request, the branch, the short commit, and links to the run, the pull
  request and the commit on the job's GitHub server.

  Every field may be unknown, and a filtered status document may replace names
  with aliases. A link is built only from parts that have the exact shape
  GitHub gives them, so an unknown or aliased value is shown as text, never
  linked, and nothing from the status document can make a link go elsewhere.
  Nothing here reads a clock or the network; `now` is an argument.
  """

  alias Dashboard.Status.{Job, SlotRecord}

  @default_server "https://github.com"
  @server ~r/\Ahttps?:\/\/[A-Za-z0-9.-]+(:[0-9]{1,5})?\z/
  @repository ~r/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/
  @run_id ~r/\A[0-9]+\z/
  @sha ~r/\A[0-9a-fA-F]{7,64}\z/
  @pull_request_ref ~r/\Arefs\/pull\/([1-9][0-9]*)\/(merge|head)\z/
  @pull_request_events ~w(pull_request pull_request_target pull_request_review pull_request_review_comment)

  @type details :: %{
          repository: String.t() | nil,
          repository_url: String.t() | nil,
          workflow: String.t() | nil,
          job: String.t() | nil,
          run_id: String.t() | nil,
          run_attempt: non_neg_integer() | nil,
          run_url: String.t() | nil,
          pull_request: pos_integer() | :none | nil,
          pull_request_title: String.t() | nil,
          pull_request_url: String.t() | nil,
          branch: String.t() | nil,
          short_sha: String.t() | nil,
          commit_url: String.t() | nil,
          event: String.t() | nil,
          actor: String.t() | nil,
          runner: String.t() | nil
        }

  @doc """
  Everything the detail view shows about a slot holder's job. `pull_request`
  is `:none` when the event is known and is not about a pull request, and
  `nil` when it is unknown. A record from before job records still names its
  repository: the slot label is the repository the hook registered.
  """
  @spec describe(SlotRecord.t()) :: details()
  def describe(%SlotRecord{job: %Job{} = job} = record) do
    repository = job.repository || label_repository(record.label)
    base = base_url(job.server_url, repository)
    pull_request = pull_request(job)

    %{
      repository: repository,
      repository_url: base,
      workflow: job.workflow,
      job: job.job,
      run_id: job.run_id,
      run_attempt: job.run_attempt,
      run_url: link(base, "/actions/runs/", job.run_id, @run_id),
      pull_request: pull_request || no_pull_request(job.event),
      pull_request_title: job.pull_request_title,
      pull_request_url: pull_request && base && "#{base}/pull/#{pull_request}",
      branch: branch(job),
      short_sha: short_sha(job.sha),
      commit_url: link(base, "/commit/", job.sha, @sha),
      event: job.event,
      actor: job.actor,
      runner: job.runner
    }
  end

  @doc """
  The pull request a job belongs to: the number the hook read from the event
  payload, else the one a pull request ref names (`refs/pull/7/merge`).
  """
  @spec pull_request(Job.t()) :: pos_integer() | nil
  def pull_request(%Job{pull_request: number}) when is_integer(number) and number > 0,
    do: number

  def pull_request(%Job{ref: ref}) when is_binary(ref) do
    case Regex.run(@pull_request_ref, ref) do
      [_ref, number, _kind] -> String.to_integer(number)
      nil -> nil
    end
  end

  def pull_request(_job), do: nil

  @doc """
  The branch the job runs for: a pull request's head branch, else the branch
  or tag its ref names. `nil` when unknown.
  """
  @spec branch(Job.t()) :: String.t() | nil
  def branch(%Job{head_ref: head}) when is_binary(head) and head != "", do: head
  def branch(%Job{ref: "refs/heads/" <> branch}) when branch != "", do: branch
  def branch(%Job{ref: "refs/tags/" <> tag}) when tag != "", do: tag <> " (tag)"
  def branch(_job), do: nil

  @doc """
  When the job reached the host (its start hook ran), when it got its slot
  units, and how long it has been on the host. A queued record's own time
  stands in for an unknown arrival; a parked job's start is unknown, since
  its record's time moved on when it parked.
  """
  @spec times(SlotRecord.t(), non_neg_integer()) :: %{
          queued_at: non_neg_integer() | nil,
          started_at: non_neg_integer() | nil,
          elapsed: non_neg_integer() | nil
        }
  def times(%SlotRecord{kind: kind, since: since, job: %Job{queued_at: queued_at}}, now) do
    queued_at = queued_at || if(kind == :queued, do: since)
    started_at = if kind == :holding, do: since
    first = queued_at || started_at

    %{queued_at: queued_at, started_at: started_at, elapsed: first && max(now - first, 0)}
  end

  defp label_repository(label), do: if(repository?(label), do: label)

  defp base_url(server, repository) do
    server = server || @default_server

    if Regex.match?(@server, server) and repository?(repository),
      do: "#{server}/#{repository}"
  end

  # Segments of only dots pass the pattern but would walk up the server's paths.
  defp repository?(name) when is_binary(name) do
    Regex.match?(@repository, name) and
      not Enum.any?(String.split(name, "/"), &(String.trim(&1, ".") == ""))
  end

  defp repository?(_name), do: false

  defp short_sha(sha) when is_binary(sha),
    do: if(Regex.match?(@sha, sha), do: String.slice(sha, 0, 7))

  defp short_sha(_sha), do: nil

  defp link(nil, _path, _value, _shape), do: nil
  defp link(_base, _path, nil, _shape), do: nil

  defp link(base, path, value, shape),
    do: if(Regex.match?(shape, value), do: base <> path <> value)

  defp no_pull_request(nil), do: nil
  defp no_pull_request(event) when event in @pull_request_events, do: nil
  defp no_pull_request(_event), do: :none
end
