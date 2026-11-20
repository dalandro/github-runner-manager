defmodule DashboardWeb.IngestController do
  @moduledoc """
  `POST /ingest`: the one route that takes input, and only in relay mode
  (`Dashboard.Relay`). A runner host sends its `grm-status --json` document
  here with a push token; an accepted document becomes what the page shows.

  The checks run cheapest first: the token, then one push a second
  (`Dashboard.Relay.Limiter`), then the size (the body is read only after the
  token passed, and at most `@max_bytes` of it), then the schema, then the
  order (`Dashboard.Relay.Inbox.offer/3`). A wrong token counts against the
  client, as a wrong viewer password does, and a locked-out client's guesses
  get 429. A right token is never counted or refused for others' guesses:
  the token is too long to guess, and the board must not go stale. The reply to a
  good push is the number of seconds until the next one; a refusal names its
  reason and echoes nothing that was sent.
  """

  use Phoenix.Controller, formats: [:json]

  import Plug.Conn

  alias Dashboard.{Relay, Status}
  alias Dashboard.Relay.{Inbox, Ingest, Limiter}
  alias DashboardWeb.Client

  # A busy host's document is about 9 KB; a push is never near this.
  @max_bytes 128 * 1024

  @doc "The largest document accepted, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  def create(conn, _params) do
    with :ok <- Ingest.authorize(get_req_header(conn, "authorization"), Relay.push_tokens()),
         :ok <- Limiter.accept_push(Limiter.pushes()) do
      read_document(conn)
    else
      {:error, :unauthorized} ->
        case Limiter.attempt(Limiter.pushes(), Client.key(conn)) do
          :ok -> refuse(conn, :unauthorized)
          {:error, seconds} -> throttled(conn, seconds, "too many wrong push tokens")
        end

      {:error, seconds} ->
        throttled(conn, seconds, "one push a second at most")
    end
  end

  defp read_document(conn) do
    # An adapter may return more than `length`, so the size is checked too.
    case read_body(conn, length: @max_bytes) do
      {:ok, body, conn} when byte_size(body) <= @max_bytes -> offer(conn, body)
      {:ok, _body, conn} -> refuse(conn, :too_large)
      {:more, _partial, conn} -> refuse(conn, :too_large)
      {:error, _reason} -> refuse(conn, :unreadable)
    end
  end

  defp offer(conn, body) do
    with {:ok, status} <- Status.decode(body),
         :ok <- Inbox.offer(Inbox, status, System.system_time(:second)) do
      json(conn, %{next_push_seconds: Relay.interval_seconds()})
    else
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, :unauthorized) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> reply(401, "push token missing or not accepted")
  end

  defp refuse(conn, :too_large), do: reply(conn, 413, "document over #{@max_bytes} bytes")
  defp refuse(conn, :unreadable), do: reply(conn, 400, "request body could not be read")

  defp refuse(conn, :older),
    do: reply(conn, 409, "document is older than the last accepted one")

  defp refuse(conn, {:invalid_json, _message}),
    do: reply(conn, 422, "document is not valid JSON")

  # Field names come from the parser, never from the document.
  defp refuse(conn, {:invalid_field, field}),
    do: reply(conn, 422, "document has an unexpected #{field} field")

  defp refuse(conn, {:unsupported_schema, _version}),
    do: reply(conn, 422, "document is not schema 1")

  defp throttled(conn, seconds, error) do
    conn
    |> put_resp_header("retry-after", Integer.to_string(seconds))
    |> reply(429, error)
  end

  defp reply(conn, status, error), do: conn |> put_status(status) |> json(%{error: error})
end
