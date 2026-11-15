defmodule Dashboard.Source do
  @moduledoc """
  Where a status reading comes from. The poller holds a `{module, options}`
  pair and calls `fetch/1`; it never knows whether the reading is real.

  Implementations: `Dashboard.Source.Command` (the host's own
  `grm-status --json`) and `Dashboard.Source.Demo` (the bundled sample).
  """

  alias Dashboard.Status

  @type t :: {module(), keyword()}
  @type error ::
          Status.error()
          | {:exit_status, non_neg_integer(), String.t()}
          | {:unreadable, String.t()}
          | {:crashed, String.t()}
          | :timeout

  @callback fetch(options :: keyword()) :: {:ok, Status.t()} | {:error, error()}

  @doc "Whether the source serves sample data, so the page can say so."
  @callback demo?() :: boolean()

  @doc "One reading from the given source."
  @spec fetch(t()) :: {:ok, Status.t()} | {:error, error()}
  def fetch({module, options}), do: module.fetch(options)

  @doc "A sentence for the page; the full reason belongs in the log."
  @spec describe_error(error()) :: String.t()
  def describe_error(:timeout), do: "the status command did not finish in time"

  def describe_error({:exit_status, status, _output}),
    do: "the status command exited with #{status}"

  def describe_error({:unreadable, what}), do: "cannot read #{what}"
  def describe_error({:crashed, _reason}), do: "the reader crashed"
  def describe_error({:invalid_json, _message}), do: "the status output is not valid JSON"

  def describe_error({:invalid_field, field}),
    do: "the status output has an unexpected #{field} field"

  def describe_error({:unsupported_schema, version}),
    do: "the status output uses schema #{inspect(version)}, this dashboard reads schema 1"
end
