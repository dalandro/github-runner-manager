defmodule Dashboard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # A mistyped host name or viewer, or an extra host with no viewer list,
    # stops the boot here, not on the first request.
    DashboardWeb.AllowedHosts.list()
    DashboardWeb.Viewers.check_boot!()

    children =
      [
        {Phoenix.PubSub, name: Dashboard.PubSub},
        {Task.Supervisor, name: Dashboard.TaskSupervisor}
      ] ++ poller() ++ [DashboardWeb.Endpoint]

    # rest_for_one: the poller broadcasts through PubSub and reads through the
    # task supervisor, and pages ask the poller for its snapshot, so each
    # child depends on the ones before it.
    Supervisor.start_link(children, strategy: :rest_for_one, name: Dashboard.Supervisor)
  end

  defp poller do
    if Application.get_env(:dashboard, :start_poller, true) do
      [{Dashboard.Poller, Application.fetch_env!(:dashboard, Dashboard.Poller)}]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    DashboardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
