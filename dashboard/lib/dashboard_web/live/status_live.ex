defmodule DashboardWeb.StatusLive do
  @moduledoc """
  The status board leads with a verdict and capacity strip, then active cards
  and a compact quiet group. It holds two assigns that change: the latest
  `Dashboard.Snapshot`, updated by snapshot and read-time PubSub messages,
  and `now`, a one-second clock so waits and hold times count up between readings.

  Everything shown is derived from those two in `Dashboard.Overview` and
  `Dashboard.JobDetails`; the page keeps no state of its own and handles no
  events from the browser. A job's detail view is rendered with the board and
  opened by the browser itself (a popover), so opening one sends nothing.
  """

  use DashboardWeb, :live_view

  import DashboardWeb.StatusComponents

  on_mount {DashboardWeb.ViewerAuth, :require_viewer}

  alias Dashboard.{Overview, Snapshot}

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

  def handle_info({:read_at, at}, socket) do
    {:noreply, assign(socket, :snapshot, %{socket.assigns.snapshot | fetched_at: at})}
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

      <main :if={@snapshot.status} id="overview">
        <.verdict_banner snapshot={@snapshot} now={@now} />
        <.capacity_strip status={@snapshot.status} now={@now} />

        <div class="columns">
          <div class="column">
            <.queue_card
              :if={!Overview.quiet?(@snapshot.status, :queue)}
              slots={@snapshot.status.slots}
              now={@now}
            />
            <.runners_card status={@snapshot.status} now={@now} />
            <.slots_card
              :if={!Overview.quiet?(@snapshot.status, :slots)}
              slots={@snapshot.status.slots}
              now={@now}
            />
          </div>
          <div class="column">
            <.device_lock_card
              :if={!Overview.quiet?(@snapshot.status, :device_lock)}
              lock={@snapshot.status.device_lock}
              now={@now}
            />
            <.host_card host={@snapshot.status.host} busy={Overview.busy?(@snapshot.status)} />
            <.events_card
              :if={!Overview.quiet?(@snapshot.status, :events)}
              events={@snapshot.status.events}
              now={@now}
            />
          </div>
        </div>
        <.quiet_group status={@snapshot.status} />

        <div id="job-details">
          <.job_details
            :for={record <- Overview.jobs(@snapshot.status.slots)}
            record={record}
            status={@snapshot.status}
            now={@now}
          />
        </div>
      </main>

      <.no_reading :if={!@snapshot.status} snapshot={@snapshot} />

      <footer class="page-footer">
        <p :if={!@snapshot.relay}>
          Read-only view of <code>grm-status --json</code>. Listens on this machine only: never
          expose this port; look from elsewhere through an SSH tunnel or a private-network proxy.
        </p>
        <p :if={@snapshot.relay} id="relay-footer">
          Read-only view of the <code>grm-status --json</code>
          document the runner host last pushed; this page cannot reach the host.
          Listens on this machine only.
        </p>
      </footer>
    </div>
    """
  end
end
