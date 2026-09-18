defmodule Jevex.Error do
  @moduledoc """
  A safe error returned at configuration, request, and response boundaries.

  `kind` distinguishes `:configuration`, `:validation`, `:transport`, `:http`,
  `:response`, and `:low_confidence` failures. Errors deliberately omit raw bodies, URLs, state,
  credentials, and transport exception messages, which can contain secrets.
  `retry_after` is a delay in milliseconds, when supplied by the server.
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
end
