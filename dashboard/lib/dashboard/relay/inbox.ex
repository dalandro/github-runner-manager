defmodule Dashboard.Relay.Inbox do
  @moduledoc """
  The latest accepted push, in memory only: a restart empties it until the
  host pushes again. A process, because pushes arrive on request processes
  and the poller reads from its own; offering runs `Dashboard.Relay.Ingest.accept/3`
  inside the process, so two pushes cannot both pass the order check.
  """

  use Agent

  alias Dashboard.Relay.Ingest
  alias Dashboard.Status

  @doc "Options: `:name` (default `#{inspect(__MODULE__)}`; `nil` for none)."
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    Agent.start_link(fn -> nil end, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "The latest accepted push, or `nil` before the first."
  @spec latest(Agent.agent()) :: Ingest.latest() | nil
  def latest(inbox), do: Agent.get(inbox, & &1)

  @doc "Keeps `status`, received at `now`, unless it is older than the latest."
  @spec offer(Agent.agent(), Status.t(), non_neg_integer()) :: :ok | {:error, :older}
  def offer(inbox, %Status{} = status, now) do
    Agent.get_and_update(inbox, fn latest ->
      case Ingest.accept(latest, status, now) do
        {:ok, latest} -> {:ok, latest}
        {:error, :older} -> {{:error, :older}, latest}
      end
    end)
  end
end
