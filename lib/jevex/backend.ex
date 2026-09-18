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
  @callback defaults(keyword()) :: {:ok, defaults()} | {:error, Jevex.Error.t()}
  @callback encode(String.t(), term(), %{String.t() => map()}) :: map()
  @callback headers(String.t()) :: [{String.t(), String.t()}]
  @callback decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  @callback partial_metadata?() :: boolean()
end
