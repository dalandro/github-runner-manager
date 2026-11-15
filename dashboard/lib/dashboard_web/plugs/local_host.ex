defmodule DashboardWeb.Plugs.LocalHost do
  @moduledoc """
  Refuses requests whose `Host` header is not a loopback name.

  Binding to 127.0.0.1 keeps other machines out, but a web page open in a
  browser on this machine can still reach a loopback port through DNS
  rebinding: a hostname the attacker controls is re-pointed at 127.0.0.1 and
  the browser treats the dashboard as that site's own origin. Such a request
  carries the attacker's hostname in `Host`, so checking it closes the hole.
  An SSH tunnel is unaffected: the browser still asks for `localhost`.
  """

  @behaviour Plug

  import Plug.Conn

  @allowed ~w(localhost 127.0.0.1)

  @impl true
  def init(options), do: options

  @impl true
  def call(%Plug.Conn{host: host} = conn, _options) when host in @allowed, do: conn

  def call(conn, _options) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(:forbidden, "This dashboard answers only to localhost.\n")
    |> halt()
  end
end
