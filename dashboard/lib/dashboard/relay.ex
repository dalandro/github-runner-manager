defmodule Dashboard.Relay do
  @moduledoc """
  Relay mode: instead of reading a host, the dashboard shows the status
  document a runner host last pushed to `POST /ingest`
  (`DashboardWeb.IngestController`). The board, parser and templates are the
  same; only the source differs (`Dashboard.Source.Relay`).

  A relay never runs `grm-status` and opens no connection: it can only wait
  for the next push. It listens on loopback like every other mode, unless it
  is given a public host name: then it listens on every interface, as it must
  behind Fly's proxy, and only in relay mode (`config/runtime.exs`). A public
  relay needs a viewer password, which the browser asks for
  (`DashboardWeb.Plugs.RelayLogin`); the rate limits are
  `Dashboard.Relay.Throttle`'s. See docs/relay.md.

  Settings, from `config/runtime.exs` (`config :dashboard, :relay, ...`),
  validated at boot by `check_boot!/0`:

    * `:push_tokens` - `GRM_RELAY_PUSH_TOKENS`, comma-separated; a push must
      carry one of them as a bearer token. More than one lets a new token
      overlap the old while it is rotated.
    * `:interval_seconds` - `GRM_RELAY_INTERVAL_SECONDS`, how often the host
      is asked to push (default 5).
    * `:public_host` - `GRM_RELAY_PUBLIC_HOST`, the one name the relay is
      served under on the internet (such as `<your-app-name>.fly.dev`); unset,
      loopback only.
    * `:viewer_password` - `GRM_RELAY_VIEWER_PASSWORD`, what the browser's
      password prompt must be given; needed with a public host, optional
      without one.
  """

  @min_token_length 32
  @min_password_length 16
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
      viewer_password()

      cond do
        not public?() ->
          :ok

        viewer_password() == nil ->
          raise ArgumentError,
                "GRM_RELAY_PUBLIC_HOST needs GRM_RELAY_VIEWER_PASSWORD: a public relay " <>
                  "is never served without a password"

        DashboardWeb.Viewers.required?() ->
          raise ArgumentError,
                "GRM_DASHBOARD_VIEWERS trusts a private-network proxy's identity header; " <>
                  "a public relay has no such proxy, so it takes GRM_RELAY_VIEWER_PASSWORD only"

        true ->
          :ok
      end
    end

    :ok
  end

  @doc "The public host name, or nil for loopback only. Raises on an invalid setting."
  @spec public_host() :: String.t() | nil
  def public_host, do: parse_public_host!(setting(:public_host))

  @doc "Whether this relay is served on the internet."
  @spec public?() :: boolean()
  def public?, do: enabled?() and public_host() != nil

  @doc "The viewer password, or nil. Raises on an invalid setting."
  @spec viewer_password() :: String.t() | nil
  def viewer_password, do: parse_viewer_password!(setting(:viewer_password))

  @doc "Whether the page asks for the viewer password."
  @spec login_required?() :: boolean()
  def login_required?, do: enabled?() and viewer_password() != nil

  @doc """
  The public host name in a setting, lower-cased, or nil when unset. Raises
  `ArgumentError` for anything but one plain host name that is not loopback.
  """
  @spec parse_public_host!(String.t() | nil) :: String.t() | nil
  def parse_public_host!(nil), do: nil

  def parse_public_host!(setting) when is_binary(setting) do
    name = setting |> String.trim() |> String.downcase(:ascii)

    if DashboardWeb.AllowedHosts.host_name?(name) and
         not DashboardWeb.AllowedHosts.loopback?(name) do
      name
    else
      raise ArgumentError,
            "GRM_RELAY_PUBLIC_HOST takes one plain host name that is not loopback " <>
              "(no scheme, port, path, wildcard or list), got: #{inspect(setting)}"
    end
  end

  @doc """
  The viewer password in a setting, or nil when unset. Raises `ArgumentError`
  when it is shorter than #{@min_password_length} characters or has spaces or
  control characters. The message never repeats the password.
  """
  @spec parse_viewer_password!(String.t() | nil) :: String.t() | nil
  def parse_viewer_password!(nil), do: nil

  def parse_viewer_password!(setting) when is_binary(setting) do
    if String.length(setting) >= @min_password_length and
         String.match?(setting, ~r/\A[[:graph:]]+\z/u) do
      setting
    else
      raise ArgumentError,
            "GRM_RELAY_VIEWER_PASSWORD needs #{@min_password_length} or more visible " <>
              "characters and no spaces"
    end
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
