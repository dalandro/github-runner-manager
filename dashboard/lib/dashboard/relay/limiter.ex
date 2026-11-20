defmodule Dashboard.Relay.Limiter do
  @moduledoc """
  A `Dashboard.Relay.Throttle` in a process, because sign-ins and pushes
  arrive on many request processes at once. Each call runs one throttle
  function inside the process, so a check and its count cannot be split by
  another request. Only addresses and times are held here: no password or
  token ever reaches this process.

  A relay runs two, so neither kind of guess fills the other's global cap:
  `#{inspect(__MODULE__)}.Viewers` for viewer passwords, and
  `#{inspect(__MODULE__)}.Pushes` for push tokens and the push rate.
  """

  use Agent

  alias Dashboard.Relay.Throttle

  @viewers Module.concat(__MODULE__, Viewers)
  @pushes Module.concat(__MODULE__, Pushes)

  @doc "The limiter for viewer passwords."
  @spec viewers() :: atom()
  def viewers, do: @viewers

  @doc "The limiter for push tokens and the push rate."
  @spec pushes() :: atom()
  def pushes, do: @pushes

  @doc "Options: `:name` (required, also the child id) and `:push_interval_ms` (default 1000; tests take 0)."
  def child_spec(options) do
    %{id: Keyword.fetch!(options, :name), start: {__MODULE__, :start_link, [options]}}
  end

  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(options) do
    throttle = Throttle.new(Keyword.take(options, [:push_interval_ms]))
    Agent.start_link(fn -> throttle end, name: Keyword.fetch!(options, :name))
  end

  @doc "Counts an attempt by a client, or refuses it with the seconds to wait (`Throttle.attempt/3`)."
  @spec attempt(Agent.agent(), Throttle.key()) :: :ok | {:error, pos_integer()}
  def attempt(limiter, key) do
    update(limiter, &Throttle.attempt(&1, key, now()))
  end

  @doc "Takes back a client's latest attempt: it was right (`Throttle.forgive/2`)."
  @spec forgive(Agent.agent(), Throttle.key()) :: :ok
  def forgive(limiter, key), do: Agent.update(limiter, &Throttle.forgive(&1, key))

  @doc "Takes a push, or refuses it with the seconds to wait (`Throttle.accept_push/2`)."
  @spec accept_push(Agent.agent()) :: :ok | {:error, pos_integer()}
  def accept_push(limiter), do: update(limiter, &Throttle.accept_push(&1, now()))

  defp update(limiter, function) do
    Agent.get_and_update(limiter, fn throttle ->
      case function.(throttle) do
        {:ok, throttle} -> {:ok, throttle}
        {:error, seconds} -> {{:error, seconds}, throttle}
      end
    end)
  end

  defp now, do: System.monotonic_time(:millisecond)
end
