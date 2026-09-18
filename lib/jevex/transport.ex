defmodule Jevex.Transport do
  @moduledoc """
  Injectable HTTP boundary. Implementations receive an encoded POST request
  and client settings, and return a status, headers, and raw JSON body.
  Header names should be lowercase. Transport errors must not contain secrets.
  """
  @type request :: %{url: String.t(), headers: [{String.t(), String.t()}], body: binary()}
  @type response :: %{status: pos_integer(), headers: map(), body: binary()}
  @callback request(request(), Jevex.Client.t()) :: {:ok, response()} | {:error, term()}
end

defmodule Jevex.Transport.Req do
  @moduledoc "Default HTTPS transport. Disables redirects and Req's automatic retries."
  @behaviour Jevex.Transport

  @impl true
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
