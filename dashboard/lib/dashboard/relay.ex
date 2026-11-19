defmodule Dashboard.Relay do
  @moduledoc """
  Relay mode: instead of reading a host, the dashboard shows the status
  document a runner host last pushed to `POST /ingest`
  (`DashboardWeb.IngestController`). The board, parser and templates are the
  same; only the source differs (`Dashboard.Source.Relay`).

  A relay never runs `grm-status` and opens no connection: it can only wait
  for the next push. For now it listens on loopback like every other mode.

  Settings, from `config/runtime.exs` (`config :dashboard, :relay, ...`),
  validated at boot by `check_boot!/0`:

    * `:push_tokens` - `GRM_RELAY_PUSH_TOKENS`, comma-separated; a push must
      carry one of them as a bearer token. More than one lets a new token
      overlap the old while it is rotated.
    * `:interval_seconds` - `GRM_RELAY_INTERVAL_SECONDS`, how often the host
      is asked to push (default 5).
  """

  @min_token_length 32
  @interval_range 2..900

  @doc "Whether this dashboard runs as a relay."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:dashboard, :relay) != nil

  @doc "Fails the boot on a missing or invalid relay setting, in relay mode only."
  @spec check_boot!() :: :ok
  def check_boot! do
    if enabled?() do
      push_tokens()
      interval_seconds()
    end

    :ok
  end

  @doc "The accepted push tokens. Raises on an invalid setting."
  @spec push_tokens() :: [String.t()]
  def push_tokens, do: parse_tokens!(setting(:push_tokens))

  @doc "Seconds between pushes, as told to the host. Raises on an invalid setting."
  @spec interval_seconds() :: pos_integer()
  def interval_seconds, do: check_interval!(setting(:interval_seconds))

  @doc """
  The tokens in a comma-separated setting. Raises `ArgumentError` when there
  is none, or one is shorter than #{@min_token_length} characters or has
  spaces or control characters. The message never repeats a token.
  """
  @spec parse_tokens!(String.t() | nil) :: [String.t()]
  def parse_tokens!(setting) do
    tokens =
      (setting || "")
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      tokens == [] ->
        raise ArgumentError,
              "GRM_RELAY_PUSH_TOKENS: relay mode needs at least one push token"

      Enum.any?(tokens, &(String.length(&1) < @min_token_length)) ->
        raise ArgumentError,
              "GRM_RELAY_PUSH_TOKENS: each push token needs #{@min_token_length} or more characters"

      not Enum.all?(tokens, &String.match?(&1, ~r/\A[[:graph:]]+\z/)) ->
        raise ArgumentError,
              "GRM_RELAY_PUSH_TOKENS: push tokens are visible characters only, no spaces"

      true ->
        tokens
    end
  end

  @doc "The interval if it is whole seconds in #{inspect(@interval_range)}; raises otherwise."
  @spec check_interval!(term()) :: pos_integer()
  def check_interval!(seconds) when is_integer(seconds) and seconds in @interval_range,
    do: seconds

  def check_interval!(seconds) do
    raise ArgumentError,
          "GRM_RELAY_INTERVAL_SECONDS must be whole seconds from " <>
            "#{@interval_range.first} to #{@interval_range.last}, got: #{inspect(seconds)}"
  end

  @doc """
  Seconds without a push after which the last one is stale: three missed
  pushes, and never under 30 seconds, so one slow push is not an outage.
  """
  @spec stale_after(pos_integer()) :: pos_integer()
  def stale_after(interval_seconds), do: max(3 * interval_seconds, 30)

  defp setting(key), do: Application.get_env(:dashboard, :relay, []) |> Keyword.get(key)
end
