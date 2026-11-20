defmodule DashboardWeb.Plugs.RelayLogin do
  @moduledoc """
  With a relay viewer password (`Dashboard.Relay.login_required?/0`), lets a
  page request through only when it carries the password
  (`DashboardWeb.RelayLogin.check/2`) or a recent signed sign-in. Otherwise
  it answers 401 and the browser asks for the password; a wrong one is
  counted against the client (`Dashboard.Relay.Limiter`), and a locked-out
  client gets 429 before anything is compared. A sign-in is recorded in the
  signed session, which `DashboardWeb.ViewerAuth` checks when the live socket
  mounts.

  Without a password it does nothing.
  """

  @behaviour Plug

  import Plug.Conn

  alias Dashboard.Relay
  alias Dashboard.Relay.Limiter
  alias DashboardWeb.{Client, RelayLogin}

  @realm ~s(Basic realm="runner status", charset="UTF-8")

  @impl true
  def init(options), do: options

  @impl true
  def call(conn, _options) do
    if Relay.login_required?(), do: check(conn, Relay.viewer_password()), else: conn
  end

  # A recent sign-in comes first, so a lockout caused by others (the global
  # cap, or a shared address) never shuts out a signed-in viewer.
  defp check(conn, password) do
    cond do
      signed_in?(conn, password) -> conn
      get_req_header(conn, "authorization") == [] -> ask(conn)
      true -> attempt(conn, get_req_header(conn, "authorization"), password)
    end
  end

  defp attempt(conn, headers, password) do
    key = Client.key(conn)

    with :ok <- Limiter.attempt(key),
         :ok <- RelayLogin.check(headers, password) do
      Limiter.forgive(key)
      sign_in(conn, password)
    else
      {:error, seconds} ->
        throttled(conn, seconds)

      :missing ->
        Limiter.forgive(key)
        ask(conn)

      :wrong ->
        ask(conn)
    end
  end

  defp signed_in?(conn, password) do
    RelayLogin.session_valid?(
      get_session(conn),
      password,
      conn.secret_key_base,
      System.system_time(:second)
    )
  end

  # A fresh session on sign-in, so nothing set before it carries over.
  defp sign_in(conn, password) do
    conn.secret_key_base
    |> then(&RelayLogin.session(password, &1, System.system_time(:second)))
    |> Enum.reduce(configure_session(conn, renew: true), fn {key, value}, conn ->
      put_session(conn, key, value)
    end)
  end

  defp ask(conn) do
    conn
    |> configure_session(drop: true)
    |> put_resp_header("www-authenticate", @realm)
    |> put_resp_content_type("text/plain")
    |> send_resp(:unauthorized, "This status board needs its viewer password.\n")
    |> halt()
  end

  defp throttled(conn, seconds) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> put_resp_content_type("text/plain")
    |> send_resp(:too_many_requests, "Too many wrong passwords; try again in #{seconds} s.\n")
    |> halt()
  end
end
