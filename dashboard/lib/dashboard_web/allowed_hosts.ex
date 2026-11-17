defmodule DashboardWeb.AllowedHosts do
  @moduledoc """
  The host names this dashboard answers to: the two loopback names, plus any
  the operator lists in `GRM_DASHBOARD_ALLOWED_HOSTS` (comma-separated).

  The extra names exist for one setup: a proxy on this machine that puts the
  loopback port on a private network under its own name (see
  `docs/remote-access.md`). The server still listens on 127.0.0.1 only; a
  listed name widens which `Host` and `Origin` values are believed, nothing
  else. Names match exactly: no wildcards, no suffixes, no ports.

  One list feeds the three places a name is checked, so they cannot drift:
  the `Host` header (`DashboardWeb.Plugs.AllowedHost`), the origin of the
  live socket (`origin_allowed?/1`, the endpoint's `check_origin`) and the
  content security policy (`content_security_policy/0`).

  Only what the browser itself sends is read. `X-Forwarded-*` headers are
  ignored: anything that can reach the port can set them.
  """

  @loopback ~w(localhost 127.0.0.1)
  @label "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
  @host_name Regex.compile!("\\A#{@label}(\\.#{@label})*\\z")

  @doc "Every allowed name, loopback first. Raises on an invalid setting."
  @spec list() :: [String.t()]
  def list, do: @loopback ++ parse!(Application.get_env(:dashboard, :allowed_hosts))

  @doc "Whether the operator allowed any name beyond loopback."
  @spec extra?() :: boolean()
  def extra?, do: list() != @loopback

  @doc """
  The names in a comma-separated setting, lower-cased. Raises `ArgumentError`
  for anything that is not a plain host name, so a typo such as a URL, a port
  or a wildcard stops the boot instead of being half-applied.
  """
  @spec parse!(String.t() | nil) :: [String.t()]
  def parse!(nil), do: []

  def parse!(setting) when is_binary(setting) do
    setting
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&host_name!/1)
    |> Enum.uniq()
  end

  @doc "Whether a `Host` header value (without its port) is an allowed name."
  @spec allowed?(String.t() | nil) :: boolean()
  def allowed?(host) when is_binary(host), do: String.downcase(host, :ascii) in list()
  def allowed?(_host), do: false

  @doc """
  Whether a page from this origin may open the live socket: its host must be
  an allowed name. The scheme must be `http` or `https`; the port is not
  compared, as with Phoenix's own `//host` origins.
  """
  @spec origin_allowed?(URI.t()) :: boolean()
  def origin_allowed?(%URI{scheme: scheme, host: host}) when scheme in ["http", "https"],
    do: allowed?(host)

  def origin_allowed?(%URI{}), do: false

  @doc """
  The policy sent with every page. `'self'` covers the live socket in current
  browsers; the explicit socket origins are for those that do not count a
  WebSocket as same-origin. An extra name is reached through an HTTPS proxy,
  so its socket is `wss`, on whichever port the proxy serves.
  """
  @spec content_security_policy() :: String.t()
  def content_security_policy do
    sockets =
      Enum.map(@loopback, &"ws://#{&1}:*") ++ Enum.map(list() -- @loopback, &"wss://#{&1}:*")

    "default-src 'self'; img-src 'self' data:; " <>
      "connect-src 'self' #{Enum.join(sockets, " ")}; " <>
      "frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
  end

  defp host_name!(name) do
    name = String.downcase(name, :ascii)

    if byte_size(name) <= 253 and Regex.match?(@host_name, name) do
      name
    else
      raise ArgumentError,
            "GRM_DASHBOARD_ALLOWED_HOSTS takes plain host names separated by commas " <>
              "(no scheme, port, path or wildcard), got: #{inspect(name)}"
    end
  end
end
