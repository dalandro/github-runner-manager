defmodule DashboardWeb.Plugs.AllowedHost do
  @moduledoc """
  Refuses requests whose `Host` header is not an allowed name
  (`DashboardWeb.AllowedHosts`: the loopback names unless the operator adds
  more).

  Binding to 127.0.0.1 keeps other machines out, but a web page open in a
  browser on this machine can still reach a loopback port through DNS
  rebinding: a hostname the attacker controls is re-pointed at 127.0.0.1 and
  the browser treats the dashboard as that site's own origin. Such a request
  carries the attacker's hostname in `Host`, so checking it closes the hole
  for pages and static files. Phoenix dispatches sockets before endpoint
  plugs, so the live socket is covered by `check_origin` instead, which reads
  the same list.
  An SSH tunnel is unaffected: the browser still asks for `localhost`.

  A public relay answers `/robots.txt` under any name: Fly's health check
  asks the machine directly, not under the public name, and the file is the
  same for everyone.
  """

  @behaviour Plug

  import Plug.Conn

  alias DashboardWeb.AllowedHosts

  @impl true
  def init(options), do: options

  @impl true
  def call(%Plug.Conn{host: host} = conn, _options) do
    if AllowedHosts.allowed?(host) or health_check?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(:forbidden, "This dashboard does not answer to that host name.\n")
      |> halt()
    end
  end

  defp health_check?(%Plug.Conn{method: method, path_info: ["robots.txt"]})
       when method in ["GET", "HEAD"],
       do: Dashboard.Relay.public?()

  defp health_check?(_conn), do: false
end
