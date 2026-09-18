defmodule Jevex.Backend do
  @moduledoc """
  HTTP protocol adapter for Jev inference services.

  Adapters supply connection defaults, encode already validated native questions,
  add protocol headers, and normalize decoded JSON responses. The client owns
  authentication, transport, retries, size limits, and final response validation.
  Never include credentials in defaults or errors. `endpoint` is a complete URL,
  not a base URL. Missing metadata must remain missing rather than be invented.

  Implement all five callbacks to use a custom module as `backend: MyBackend`.
  """

  @type defaults :: %{endpoint: String.t() | nil, model: String.t() | nil}
  @doc "Provides a full endpoint URL and model defaults, or a sanitized configuration error."
  @callback defaults(keyword()) :: {:ok, defaults()} | {:error, Jevex.Error.t()}
  @doc "Builds a JSON-encodable request map from validated state and native questions."
  @callback encode(String.t(), term(), %{String.t() => map()}) :: map()
  @doc "Returns provider-specific headers, excluding bearer authentication owned by the client."
  @callback headers(String.t()) :: [{String.t(), String.t()}]
  @doc "Normalizes decoded wire data into the native answer representation, without inventing missing metadata."
  @callback decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  @doc "Returns true when the provider contract permits missing response metadata."
  @callback partial_metadata?() :: boolean()
end
