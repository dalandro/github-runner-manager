defmodule Dashboard.Poller do
  @moduledoc """
  Polls a `Dashboard.Source` and publishes the result.

  This is a process because it owns three things a function cannot: the timer,
  the last good reading (served to every page that mounts), and the failure
  count behind the backoff. Each read runs in a supervised task, so a slow or
  crashing status command neither blocks `snapshot/1` nor takes the poller
  down; at most one read is in flight, and a read still running after
  `:read_timeout` is killed and counted as a failure.

  A new `Dashboard.Snapshot` is broadcast as `{:snapshot, snapshot}` only when
  it differs from the previous one (see `Dashboard.Snapshot.changed?/2`).
  An unchanged good reading broadcasts `{:read_at, fetched_at}` when its read
  time differs.
  The change time tracks runners, slots, queue, lock and events; load and
  memory are sampled on every reading (see `Dashboard.Snapshot.state_changed?/2`).

  After a failed read the next attempt waits `interval * 2^failures`, capped at
  `:max_backoff`; one good read returns to `:interval`.

  Options: `:source` (required), `:interval`, `:max_backoff` and
  `:read_timeout` in milliseconds, `:name`, `:pubsub`, `:topic`, `:task_supervisor`.
  """

  use GenServer

  require Logger

  alias Dashboard.{Snapshot, Source}

  @default_topic "status"

  @type option ::
          {:source, Source.t()}
          | {:interval, pos_integer()}
          | {:max_backoff, pos_integer()}
          | {:read_timeout, pos_integer()}
          | {:name, GenServer.name()}
          | {:pubsub, atom()}
          | {:topic, String.t()}
          | {:task_supervisor, Supervisor.supervisor()}

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "The latest snapshot. Cheap: it never waits for a read."
  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @doc "The topic snapshots are broadcast on by default."
  @spec topic() :: String.t()
  def topic, do: @default_topic

  @impl true
  def init(options) do
    {module, _source_options} = source = Keyword.fetch!(options, :source)

    state = %{
      source: source,
      interval: Keyword.get(options, :interval, 2_000),
      max_backoff: Keyword.get(options, :max_backoff, 30_000),
      read_timeout: Keyword.get(options, :read_timeout, 20_000),
      pubsub: Keyword.get(options, :pubsub, Dashboard.PubSub),
      topic: Keyword.get(options, :topic, @default_topic),
      task_supervisor: Keyword.get(options, :task_supervisor, Dashboard.TaskSupervisor),
      snapshot: %Snapshot{demo: module.demo?(), relay: module.relay?()},
      failures: 0,
      task: nil
    }

    {:ok, state, {:continue, :poll}}
  end

  @impl true
  def handle_continue(:poll, state), do: {:noreply, start_read(state)}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state.snapshot, state}

  @impl true
  def handle_info(:poll, state), do: {:noreply, start_read(state)}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_read(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish_read(state, {:error, {:crashed, inspect(reason)}})}
  end

  def handle_info({:read_deadline, ref}, %{task: %Task{ref: ref} = task} = state) do
    result =
      case Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _killed_or_exited -> {:error, :timeout}
      end

    {:noreply, finish_read(state, result)}
  end

  # A deadline for a read that already finished, or a late task message.
  def handle_info(_message, state), do: {:noreply, state}

  defp start_read(%{task: nil} = state) do
    task = Task.Supervisor.async_nolink(state.task_supervisor, Source, :fetch, [state.source])
    Process.send_after(self(), {:read_deadline, task.ref}, state.read_timeout)
    %{state | task: task}
  end

  defp start_read(state), do: state

  defp finish_read(state, result) do
    now = System.system_time(:second)

    {snapshot, failures} =
      case result do
        {:ok, status} ->
          {Snapshot.succeed(state.snapshot, status, now), 0}

        # A pushed reading was taken when it arrived, not when it was polled.
        {:ok, status, read_at} ->
          {Snapshot.succeed(state.snapshot, status, read_at), 0}

        {:error, error} ->
          if state.failures == 0, do: Logger.warning("status read failed: #{inspect(error)}")
          {Snapshot.fail(state.snapshot, error, now), state.failures + 1}
      end

    # Every page shares the state change time; load and memory still update.
    # Only a good reading changes the picture, so it changed when it was read.
    snapshot =
      if Snapshot.state_changed?(state.snapshot, snapshot) do
        Snapshot.mark_changed(snapshot, snapshot.fetched_at)
      else
        snapshot
      end

    cond do
      Snapshot.changed?(state.snapshot, snapshot) ->
        Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:snapshot, snapshot})

      Snapshot.read_since?(state.snapshot, snapshot) ->
        Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:read_at, snapshot.fetched_at})

      true ->
        :ok
    end

    Process.send_after(self(), :poll, delay(state.interval, state.max_backoff, failures))
    %{state | snapshot: snapshot, failures: failures, task: nil}
  end

  @doc """
  Milliseconds until the next read: the interval, doubled per consecutive
  failure, capped at the maximum backoff.
  """
  @spec delay(pos_integer(), pos_integer(), non_neg_integer()) :: pos_integer()
  def delay(interval, _max_backoff, 0), do: interval

  def delay(interval, max_backoff, failures) do
    # 2^20 intervals is far past any cap; bounding the exponent keeps the
    # arithmetic small however long an outage lasts.
    min(interval * Integer.pow(2, min(failures, 20)), max(max_backoff, interval))
  end
end
