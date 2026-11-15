defmodule DashboardWeb.ViewOnlyTest do
  @moduledoc """
  The page is view-only by construction: the web layer has no code that could
  receive an action from the browser. This test flags the usual ways one
  would appear, so adding the first is a decision, not an accident. It is a
  tripwire, not a proof: review still has to look at new plugs and modules.
  """

  use ExUnit.Case, async: true

  @sources "lib/dashboard_web/**/*.{ex,heex}"

  # Event bindings, event and parameter handlers, client-pushed events and forms.
  # phx-update and phx-track-static only steer rendering, so they pass.
  @forbidden [
    ~r/phx-(click|submit|change|blur|focus|key|window|viewport|capture|value|hook|trigger|auto)/,
    ~r/handle_event/,
    ~r/handle_params/,
    ~r/\bpush\(/,
    ~r/<\.?form\b/,
    ~r/<(input|select|textarea)\b/
  ]

  test "no template or module in the web layer can take an action from the browser" do
    files = Path.wildcard(@sources)
    assert length(files) >= 8, "expected the web layer under #{@sources}"

    offences =
      for file <- files,
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          pattern <- @forbidden,
          Regex.match?(pattern, line),
          do: "#{file}:#{number}: #{String.trim(line)}"

    assert offences == []
  end

  test "the router has one route, and it only reads" do
    assert [%{verb: :get, path: "/"}] = Phoenix.Router.routes(DashboardWeb.Router)
  end
end
