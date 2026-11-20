defmodule DashboardWeb.Client do
  @moduledoc """
  Who sent a request, for the relay's rate limits (`Dashboard.Relay.Throttle`).

  A public relay sits behind Fly's proxy, so every connection comes from the
  proxy; Fly puts the client's address in `Fly-Client-IP`. That header is read
  in public relay mode only: anywhere else any client could set it. A missing
  or malformed header falls back to the connection's address, which on Fly
  puts all such requests under one key.
  """

  alias Dashboard.Relay
  alias Dashboard.Relay.Throttle

  @doc "The key a request's client is counted under."
  @spec key(Plug.Conn.t()) :: Throttle.key()
  def key(%Plug.Conn{} = conn), do: conn |> address() |> Throttle.client_key()

  defp address(conn) do
    with true <- Relay.public?(),
         [value] <- Plug.Conn.get_req_header(conn, "fly-client-ip"),
         {:ok, address} <-
           value |> String.trim() |> String.to_charlist() |> :inet.parse_strict_address() do
      address
    else
      _not_public_or_unusable -> conn.remote_ip
    end
  end
end
