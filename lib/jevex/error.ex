defmodule Jevex.Error do
  @moduledoc """
  A safe error returned at configuration, request, and response boundaries.

  `kind` distinguishes `:configuration`, `:validation`, `:transport`, `:http`,
  `:response`, and `:low_confidence` failures. Errors deliberately omit raw bodies, URLs, state,
  credentials, and transport exception messages, which can contain secrets.
  `retry_after` is a delay in milliseconds, when supplied by the server.

  Non-bang APIs return `{:error, error}`; bang APIs raise the same exception.
  Pattern-match on `kind` and `status` for recovery rather than parsing the
  message. HTTP request IDs can help correlate a failure with provider logs.
  Custom adapters and callbacks are responsible for keeping their own messages
  free of secrets.

      iex> error = %Jevex.Error{kind: :http, message: "Rate limited", status: 429, retry_after: 1000}
      iex> {error.kind, error.status, error.retry_after}
      {:http, 429, 1000}
  """
  defexception [:kind, :message, :status, :request_id, :retry_after]

  @type t :: %__MODULE__{
          kind:
            :configuration
            | :validation
            | :transport
            | :http
            | :response
            | :low_confidence,
          message: String.t(),
          status: pos_integer() | nil,
          request_id: String.t() | nil,
          retry_after: non_neg_integer() | nil
        }

  @doc """
  Constructs an exception from keyword fields.

  This implements the standard `Exception` callback used by `raise/2`. Supply
  an English, non-sensitive message and a machine-readable error kind.

      iex> error = Jevex.Error.exception(kind: :validation, message: "Invalid question")
      iex> {error.kind, error.message}
      {:validation, "Invalid question"}
  """
  @impl true
  @spec exception(keyword()) :: t()
  def exception(opts), do: super(opts)

  @doc """
  Returns the exception's human-readable message.

  The message is intended for display, not control flow. Match on error fields
  when deciding whether to retry, fall back, or report a configuration problem.

      iex> error = %Jevex.Error{kind: :configuration, message: "Missing credential"}
      iex> Exception.message(error)
      "Missing credential"
  """
  @impl true
  @spec message(t()) :: String.t()
  def message(error), do: super(error)
end
