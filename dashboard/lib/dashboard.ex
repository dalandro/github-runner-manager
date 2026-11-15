defmodule Dashboard do
  @moduledoc """
  A read-only view of a host running github-runner-manager.

  `Dashboard.Poller` reads the host through a `Dashboard.Source`, parses the
  reading into a `Dashboard.Status`, and publishes `Dashboard.Snapshot`s.
  The web layer needs only the two functions below.
  """

  alias Dashboard.{Poller, Snapshot}

  @doc "The latest snapshot."
  @spec snapshot() :: Snapshot.t()
  def snapshot, do: Poller.snapshot()

  @doc "Subscribes the caller to `{:snapshot, %Dashboard.Snapshot{}}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Dashboard.PubSub, Poller.topic())
end
