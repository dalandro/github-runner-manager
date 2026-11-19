defmodule Dashboard.StubSource do
  @moduledoc """
  A source for tests: replays a scripted list of results, repeating the last.

      {:ok, script} = StubSource.start_link([{:ok, status}, {:error, :timeout}])
      {Dashboard.StubSource, script: script}
  """

  @behaviour Dashboard.Source

  @spec start_link([{:ok, Dashboard.Status.t()} | {:error, term()} | :crash]) :: Agent.on_start()
  def start_link(results), do: Agent.start_link(fn -> results end)

  @impl true
  def demo?, do: false

  @impl true
  def relay?, do: false

  @impl true
  def fetch(options) do
    result =
      Agent.get_and_update(Keyword.fetch!(options, :script), fn
        [last] -> {last, [last]}
        [next | rest] -> {next, rest}
      end)

    if result == :crash, do: raise("scripted crash"), else: result
  end
end
