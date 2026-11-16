defmodule DashboardWeb.Plugs.RequireViewer do
  @moduledoc """
  With a viewer list (`DashboardWeb.Viewers`), refuses every request unless
  it carries exactly one identity header naming a listed viewer, loopback
  requests included: a loopback `Host` proves nothing, since a forwarder that
  adds no header passes the client's `Host` through. A refusal is a 403 with no data and drops the session. An
  accepted identity and the time are written to the signed session, which is
  what `DashboardWeb.ViewerAuth` checks when the live socket mounts.

  Without a list it does nothing: loopback only, as before.
  """

  @behaviour Plug

  import Plug.Conn

  alias DashboardWeb.Viewers

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    if Viewers.required?(), do: check(conn), else: conn
  end

  defp check(conn) do
    case get_req_header(conn, Viewers.header()) do
      [identity] ->
        if Viewers.listed?(identity), do: admit(conn, identity), else: refuse(conn)

      _none_or_several ->
        refuse(conn)
    end
  end

  defp admit(conn, identity) do
    conn
    |> put_session("viewer", String.downcase(String.trim(identity), :ascii))
    |> put_session("viewer_at", System.system_time(:second))
  end

  defp refuse(conn) do
    conn
    |> configure_session(drop: true)
    |> put_resp_content_type("text/plain")
    |> send_resp(:forbidden, "You are not on this dashboard's viewer list.\n")
    |> halt()
  end
end
