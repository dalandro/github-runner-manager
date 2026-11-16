defmodule DashboardWeb.StatusLive do
  @moduledoc """
  The dashboard page. It holds two assigns that change: the latest
  `Dashboard.Snapshot`, pushed by the poller over PubSub, and `now`, a
  one-second clock so waits and hold times count up between readings.

  Everything shown is derived from those two in `Dashboard.Overview`; the
  page keeps no state of its own and handles no events from the browser.
  """

  use DashboardWeb, :live_view

  import DashboardWeb.StatusComponents

  alias Dashboard.Snapshot

  @tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe before reading, so a snapshot published in between is not lost.
    if connected?(socket) do
      Dashboard.subscribe()
      :timer.send_interval(@tick_ms, :tick)
    end

    {:ok,
     socket
     |> assign(:page_title, "Runner host")
     |> assign(:now, System.system_time(:second))
     |> assign(:snapshot, Dashboard.snapshot())}
  end

  @impl true
  def handle_info({:snapshot, %Snapshot{} = snapshot}, socket) do
    {:noreply, assign(socket, :snapshot, snapshot)}
  end

  def handle_info(:tick, socket) do
    {:noreply, assign(socket, :now, System.system_time(:second))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="page">
      <.page_header snapshot={@snapshot} now={@now} />

      <div class="notice notice-bad offline" role="alert">
        <.icon name={:problem} />
        <p>
          <strong>Disconnected from the dashboard.</strong>
          What you see is no longer updating. Reconnecting…
        </p>
      </div>

      <.stale_notice :if={@snapshot.error && @snapshot.status} snapshot={@snapshot} now={@now} />

      <main :if={@snapshot.status} id="overview">
        <.summary status={@snapshot.status} now={@now} />

        <div class="columns">
          <div class="column">
            <.runners_card status={@snapshot.status} now={@now} />
            <.slots_card slots={@snapshot.status.slots} now={@now} />
            <.queue_card slots={@snapshot.status.slots} now={@now} />
          </div>
          <div class="column">
            <.device_lock_card lock={@snapshot.status.device_lock} now={@now} />
            <.host_card host={@snapshot.status.host} />
            <.events_card events={@snapshot.status.events} now={@now} />
          </div>
        </div>
      </main>

      <.no_reading :if={!@snapshot.status} snapshot={@snapshot} />

      <footer class="page-footer">
        <p>
          Read-only view of <code>grm-status --json</code>. Listens on this machine only: never
          expose this port; look from elsewhere through an SSH tunnel or a private-network proxy.
        </p>
      </footer>
    </div>
    """
  end
end
