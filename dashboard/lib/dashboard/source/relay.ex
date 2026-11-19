defmodule Dashboard.Source.Relay do
  @moduledoc """
  Serves the status document the runner host last pushed
  (`Dashboard.Relay.Inbox`), read at the time it arrived. Once no push has
  arrived for `Dashboard.Relay.stale_after/1` seconds the read fails with
  `{:no_push, received_at}`, so the page keeps the last picture and marks it
  stale; before the first push it fails with `:no_push_yet`.

  Options: `:inbox` (default `Dashboard.Relay.Inbox`), `:interval_seconds`
  (default `Dashboard.Relay.interval_seconds/0`) and `:now`.
  """

  @behaviour Dashboard.Source

  alias Dashboard.Relay
  alias Dashboard.Relay.Inbox

  @impl true
  def demo?, do: false

  @impl true
  def relay?, do: true

  @impl true
  def fetch(options) do
    inbox = Keyword.get(options, :inbox, Inbox)
    interval = Keyword.get_lazy(options, :interval_seconds, &Relay.interval_seconds/0)
    now = Keyword.get_lazy(options, :now, fn -> System.system_time(:second) end)

    case Inbox.latest(inbox) do
      nil ->
        {:error, :no_push_yet}

      %{status: status, received_at: at} ->
        if now - at <= Relay.stale_after(interval),
          do: {:ok, status, at},
          else: {:error, {:no_push, at}}
    end
  end
end
