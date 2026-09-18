defmodule Jevex.Transport do
  @moduledoc """
  Injectable HTTP boundary. Implementations receive an encoded POST request
  and client settings, and return a status, headers, and raw JSON body.
  Header names should be lowercase. Transport errors must not contain secrets.

  Implement `c:request/2` and set `transport: YourModule` when constructing a
  `Jevex.Client`. The client calls the transport in the caller's process. A
  custom transport must enforce its own timeout and body-size limits and must
  not log credentials or state. See `Jevex` for a complete offline fixture.
  """
  @type request :: %{url: String.t(), headers: [{String.t(), String.t()}], body: binary()}
  @type response :: %{status: pos_integer(), headers: map(), body: binary()}
  @doc """
  Sends an encoded POST request and returns a raw HTTP response or a failure.

  The request contains a full URL, header pairs, and a JSON binary. Successful
  transport return values include the HTTP status even for 4xx/5xx responses;
  classification and retry policy belong to `Jevex.HTTP`. Connection failures
  return `{:error, reason}`. Prefer a safe atom reason to an exception containing
  a URL or request data. Responses use lowercase header names, with values as
  strings or lists of strings, and an undecoded binary body.
  """
  @callback request(request(), Jevex.Client.t()) :: {:ok, response()} | {:error, term()}
end

defmodule Jevex.Transport.Req do
  @moduledoc """
  Default HTTP transport built on Req and Finch.

  TLS verification follows Req's secure defaults. Redirects, compression,
  automatic retries, and JSON decoding are disabled. The transport stops
  receiving when `max_response_bytes` is exceeded. The HTTP layer owns retry
  policy and validates JSON after receiving the body.

  Applications normally configure `Jevex.Client` rather than call this module
  directly. Client validation requires HTTPS except for loopback HTTP tests;
  direct calls to this transport do not independently validate the URL.
  """
  @behaviour Jevex.Transport

  @impl true
  @doc """
  Sends one POST attempt with the client's timeout and response-size limits.

  Returns `{:ok, %{status: status, headers: headers, body: binary}}` for completed
  HTTP responses, including errors and redirects. Connection failures become
  `{:error, :request_failed}`; an exceeded body limit returns a `Jevex.Error`
  with kind `:response`. No raw transport exception is exposed.
  """
  @spec request(Jevex.Transport.request(), Jevex.Client.t()) ::
          {:ok, Jevex.Transport.response()} | {:error, :request_failed | Jevex.Error.t()}
  def request(request, client) do
    result =
      Req.request(
        method: :post,
        url: request.url,
        headers: request.headers,
        body: request.body,
        receive_timeout: client.timeout,
        connect_options: [timeout: client.connect_timeout],
        retry: false,
        redirect: false,
        compressed: false,
        decode_body: false,
        into: fn {:data, chunk}, {req, resp} ->
          body = (resp.body || "") <> chunk

          if byte_size(body) <= client.max_response_bytes do
            {:cont, {req, %{resp | body: body}}}
          else
            {:halt,
             {req, %Jevex.Error{kind: :response, message: "response exceeds max_response_bytes"}}}
          end
        end
      )

    case result do
      {:ok, response} ->
        {:ok, %{status: response.status, headers: response.headers, body: response.body}}

      {:error, %Jevex.Error{} = error} ->
        {:error, error}

      {:error, _} ->
        {:error, :request_failed}
    end
  end
end
