defmodule DashboardWeb.RelayLogin do
  @moduledoc """
  The viewer password of a relay (`Dashboard.Relay.viewer_password/0`), as
  pure functions: does a request carry it (`check/2`), and does a signed
  session prove it was given (`session_valid?/4`).

  The browser asks for the password itself (HTTP basic authentication, over
  Fly's TLS), so there is no form and no new input route. The user name is
  ignored. `DashboardWeb.Plugs.RelayLogin` checks each page request and
  records a sign-in in the signed session; `DashboardWeb.ViewerAuth` checks
  that record again when the live socket mounts, as for a viewer list.

  The session holds a keyed digest of the password, never the password: a
  new password or a new `SECRET_KEY_BASE` ends every session at once.
  """

  @max_age 12 * 60 * 60

  @doc "How long, in seconds, a sign-in lasts."
  @spec max_age() :: pos_integer()
  def max_age, do: @max_age

  @doc """
  `:ok` when the request's one `Authorization: Basic` header carries the
  password; `:missing` when there is no basic header (the browser has not
  asked yet); `:wrong` otherwise. Digests of equal length are compared, so
  the time taken says nothing about the password.
  """
  @spec check([String.t()], String.t()) :: :ok | :missing | :wrong
  def check([header], password) do
    case String.split(header, " ", parts: 2) do
      [scheme, credentials] ->
        if String.downcase(scheme, :ascii) == "basic",
          do: check_credentials(credentials, password),
          else: :missing

      [scheme] ->
        if String.downcase(scheme, :ascii) == "basic", do: :wrong, else: :missing
    end
  end

  def check([], _password), do: :missing
  def check(_several, _password), do: :wrong

  @doc "The session values that record a sign-in with `password` at `now` (epoch seconds)."
  @spec session(String.t(), String.t(), integer()) :: %{String.t() => term()}
  def session(password, secret_key_base, now) do
    %{"relay_viewer" => fingerprint(password, secret_key_base), "viewer_at" => now}
  end

  @doc "Whether a session records a sign-in with `password` within `max_age/0` of `now`."
  @spec session_valid?(map(), String.t(), String.t(), integer()) :: boolean()
  def session_valid?(
        %{"relay_viewer" => print, "viewer_at" => at},
        password,
        secret_key_base,
        now
      )
      when is_binary(print) and is_integer(at) do
    Plug.Crypto.secure_compare(print, fingerprint(password, secret_key_base)) and
      (now - at) in 0..@max_age
  end

  def session_valid?(_session, _password, _secret_key_base, _now), do: false

  defp check_credentials(credentials, password) do
    with {:ok, decoded} <- Base.decode64(String.trim(credentials)),
         [_user, given] <- String.split(decoded, ":", parts: 2),
         true <- given != "" and same?(given, password) do
      :ok
    else
      _wrong -> :wrong
    end
  end

  defp same?(given, password) do
    Plug.Crypto.secure_compare(:crypto.hash(:sha256, given), :crypto.hash(:sha256, password))
  end

  defp fingerprint(password, secret_key_base) do
    :hmac
    |> :crypto.mac(:sha256, secret_key_base, "grm-relay-viewer\0" <> password)
    |> Base.url_encode64(padding: false)
  end
end
