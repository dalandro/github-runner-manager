defmodule Dashboard.Relay.Ingest do
  @moduledoc """
  The two decisions about a push, as pure functions: may this request push
  (`authorize/2`), and does its document replace the last one (`accept/3`).
  `DashboardWeb.IngestController` wires them to the request and
  `Dashboard.Relay.Inbox`.
  """

  alias Dashboard.Status

  @typedoc "The latest accepted push and when it arrived (epoch seconds)."
  @type latest :: %{status: Status.t(), received_at: non_neg_integer()}

  # After this long without an accepted push, an older document is taken as
  # the host's clock having stepped back, not as a replay.
  @clock_step_seconds 600

  @doc """
  `:ok` when the request carries exactly one `Authorization: Bearer <token>`
  header and the token is one of `tokens`. Every token is compared in
  constant time.
  """
  @spec authorize([String.t()], [String.t()]) :: :ok | {:error, :unauthorized}
  def authorize([header], tokens) do
    with [scheme, token] <- String.split(header, " ", parts: 2),
         "bearer" <- String.downcase(scheme, :ascii),
         true <- token != "" and Enum.any?(tokens, &Plug.Crypto.secure_compare(&1, token)) do
      :ok
    else
      _refused -> {:error, :unauthorized}
    end
  end

  def authorize(_headers, _tokens), do: {:error, :unauthorized}

  @doc """
  The new latest push, or `{:error, :older}` when the document was generated
  before the last accepted one (a replay, or pushes overtaking each other).
  An older document is accepted once the last push is over ten minutes old:
  the host's clock may have stepped back.
  """
  @spec accept(latest() | nil, Status.t(), non_neg_integer()) ::
          {:ok, latest()} | {:error, :older}
  def accept(%{status: last, received_at: at}, %Status{} = status, now)
      when status.generated_at < last.generated_at and now - at <= @clock_step_seconds,
      do: {:error, :older}

  def accept(_latest, %Status{} = status, now), do: {:ok, %{status: status, received_at: now}}
end
