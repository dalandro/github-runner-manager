defmodule Dashboard.Relay.Throttle do
  @moduledoc """
  The rate limits of a public relay, as pure functions on a struct:
  `Dashboard.Relay.Limiter` holds one and the request processes ask it.

    * Sign-in and push attempts, per client: an attempt counts as wrong until
      it is forgiven (`forgive/2`, once the password or token matched), so
      parallel requests cannot slip past the count. Ten wrong attempts in ten
      minutes lock the client out for ten minutes; a refused attempt is not
      counted, so waiting is always enough.
    * Across clients: a hundred wrong attempts in an hour refuse every attempt
      until the oldest is an hour old. That caps guessing from many addresses,
      and bounds what is kept: a client is remembered only while one of its
      wrong attempts or its lock is recent.
    * Pushes: one accepted push per interval (a second by default).

  A client is an IPv4 address or an IPv6 /64 network, which one machine
  usually holds whole (`client_key/1`). Times are milliseconds.
  """

  @per_client 10
  @client_window 10 * 60_000
  @lockout 10 * 60_000
  @global 100
  @global_window 60 * 60_000

  defstruct failures: %{}, locks: %{}, global: [], last_push: nil, push_interval_ms: 1_000

  @type key :: String.t()
  @type t :: %__MODULE__{
          failures: %{key() => [integer()]},
          locks: %{key() => integer()},
          global: [integer()],
          last_push: integer() | nil,
          push_interval_ms: non_neg_integer()
        }

  @doc "A throttle with nothing counted. Option: `:push_interval_ms` (default 1000)."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{push_interval_ms: Keyword.get(options, :push_interval_ms, 1_000)}
  end

  @doc """
  Counts an attempt by `key` at `now`, or refuses it with the seconds to wait.
  The attempt stays counted as wrong unless `forgive/2` follows.
  """
  @spec attempt(t(), key(), integer()) :: {:ok, t()} | {:error, pos_integer()}
  def attempt(%__MODULE__{} = throttle, key, now) do
    throttle = prune(throttle, now)

    cond do
      until = throttle.locks[key] ->
        {:error, seconds(until - now)}

      length(throttle.global) >= @global ->
        {:error, seconds(List.last(throttle.global) + @global_window - now)}

      true ->
        failures = [now | Map.get(throttle.failures, key, [])]

        locks =
          if length(failures) >= @per_client,
            do: Map.put(throttle.locks, key, now + @lockout),
            else: throttle.locks

        {:ok,
         %{
           throttle
           | failures: Map.put(throttle.failures, key, failures),
             locks: locks,
             global: [now | throttle.global]
         }}
    end
  end

  @doc "Takes back the latest attempt by `key`: it turned out right."
  @spec forgive(t(), key()) :: t()
  def forgive(%__MODULE__{} = throttle, key) do
    case Map.get(throttle.failures, key, []) do
      [_latest | earlier] ->
        %{
          throttle
          | failures: put_or_drop(throttle.failures, key, earlier),
            locks:
              if(length(earlier) < @per_client,
                do: Map.delete(throttle.locks, key),
                else: throttle.locks
              ),
            global: tl(throttle.global)
        }

      [] ->
        throttle
    end
  end

  @doc "Takes a push at `now`, or refuses it with the seconds to wait."
  @spec push(t(), integer()) :: {:ok, t()} | {:error, pos_integer()}
  def push(%__MODULE__{last_push: last, push_interval_ms: interval}, now)
      when is_integer(last) and now - last < interval,
      do: {:error, seconds(last + interval - now)}

  def push(%__MODULE__{} = throttle, now), do: {:ok, %{throttle | last_push: now}}

  @doc "The clients remembered, for tests: those with recent wrong attempts or a lock."
  @spec clients(t()) :: [key()]
  def clients(%__MODULE__{failures: failures, locks: locks}) do
    (Map.keys(failures) ++ Map.keys(locks)) |> Enum.uniq() |> Enum.sort()
  end

  @doc "The key an address is counted under: IPv4 as is, IPv6 by its /64 network."
  @spec client_key(:inet.ip_address()) :: key()
  def client_key({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    client_key({div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)})
  end

  def client_key({_, _, _, _} = address), do: address |> :inet.ntoa() |> to_string()

  def client_key({a, b, c, d, _, _, _, _}) do
    ({a, b, c, d, 0, 0, 0, 0} |> :inet.ntoa() |> to_string()) <> "/64"
  end

  defp prune(throttle, now) do
    failures =
      for {key, times} <- throttle.failures,
          recent = Enum.filter(times, &(&1 > now - @client_window)),
          recent != [],
          into: %{},
          do: {key, recent}

    %{
      throttle
      | failures: failures,
        locks: for({key, until} <- throttle.locks, until > now, into: %{}, do: {key, until}),
        global: Enum.filter(throttle.global, &(&1 > now - @global_window))
    }
  end

  defp put_or_drop(map, key, []), do: Map.delete(map, key)
  defp put_or_drop(map, key, value), do: Map.put(map, key, value)

  defp seconds(milliseconds), do: max(div(milliseconds + 999, 1_000), 1)
end
