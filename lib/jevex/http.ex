defmodule Jevex.HTTP do
  @moduledoc """
  Low-level Jev request layer, usable without macros or typed response structs.

  `post/3` accepts a state and a map (or keyword list) of `Jevex.Question`s.
  It validates input, applies the selected backend protocol, handles bounded
  retries, and returns the normalized response map. Use `Jevex.evaluate/3` when
  you need validated typed answers as well.

  Only 429 and 529 are retried. Retry-After seconds and HTTP dates are honored;
  if the delay exceeds the configured cap, the error is returned immediately
  rather than retrying earlier than the server requested. Other failures use
  tagged errors. Raw error bodies and request state are never logged or retained.
  """
  alias Jevex.{Client, Error, Question}

  @doc "Posts one evaluation and returns the backend-normalized JSON response."
  @spec post(Client.t(), term(), map() | keyword()) :: {:ok, map()} | {:error, Error.t()}
  def post(client, state, questions) do
    with {:ok, questions} <- questions(questions) do
      request(client, state, questions)
    end
  end

  @doc false
  @spec request(Client.t(), term(), map()) :: {:ok, map()} | {:error, Error.t()}
  def request(%Client{} = client, state, questions) do
    with :ok <- Client.validate(client),
         :ok <- state_shape(state),
         {:ok, key} <- Client.credential(client),
         encoded = Map.new(questions, fn {id, q} -> {id, Question.encode(q)} end),
         payload = client.backend.encode(client.model, state, encoded),
         {:ok, body} <- encode(payload, client.max_request_bytes) do
      request = %{
        url: client.endpoint,
        headers:
          [
            {"authorization", "Bearer " <> key},
            {"content-type", "application/json"},
            {"accept", "application/json"}
          ] ++ client.backend.headers(client.model),
        body: body
      }

      send_request(client, request, 0)
    end
  rescue
    e in Error -> {:error, e}
  end

  def request(_, _, _), do: invalid("expected a Jevex.Client")

  @doc false
  @spec questions(term()) :: {:ok, %{String.t() => Question.t()}} | {:error, Error.t()}
  def questions(questions) when is_map(questions) and not is_struct(questions),
    do: normalize_questions(Map.to_list(questions))

  def questions(questions) when is_list(questions) do
    if proper_list?(questions),
      do: normalize_questions(questions),
      else: invalid("questions must be a proper list")
  end

  def questions(_), do: invalid("questions must be a nonempty map or keyword list")

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_), do: false

  defp normalize_questions([]), do: invalid("questions must not be empty")

  defp normalize_questions(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {id, q}, {:ok, acc} when is_atom(id) or is_binary(id) ->
        id = to_string(id)

        with true <- id != "" and String.valid?(id) and not Map.has_key?(acc, id),
             :ok <- Question.validate(q) do
          {:cont, {:ok, Map.put(acc, id, q)}}
        else
          false -> {:halt, invalid("question IDs must be nonempty, unique strings or atoms")}
          error -> {:halt, error}
        end

      _, _ ->
        {:halt, invalid("invalid question entry")}
    end)
  end

  defp state_shape(state)
       when is_binary(state) or is_list(state) or (is_map(state) and not is_struct(state)) do
    if json_value?(state),
      do: :ok,
      else: invalid("state must contain only JSON-compatible values")
  end

  defp state_shape(_), do: invalid("state must be a string, JSON object, or array")

  defp json_value?(value) when is_binary(value), do: String.valid?(value)
  defp json_value?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json_value?([]), do: true
  defp json_value?([head | tail]), do: json_value?(head) and json_list?(tail)

  defp json_value?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {k, v} ->
      (is_atom(k) or (is_binary(k) and String.valid?(k))) and json_value?(v)
    end)
  end

  defp json_value?(_), do: false
  defp json_list?([]), do: true
  defp json_list?([head | tail]), do: json_value?(head) and json_list?(tail)
  defp json_list?(_), do: false

  defp encode(payload, limit) do
    # strict maps reject atom/string key collisions rather than emitting duplicate JSON keys.
    case Jason.encode(payload, maps: :strict) do
      {:ok, body} when byte_size(body) <= limit -> {:ok, body}
      {:ok, _} -> invalid("request exceeds max_request_bytes")
      {:error, _} -> invalid("request contains invalid JSON data")
    end
  rescue
    _ -> invalid("request contains invalid JSON data")
  end

  defp send_request(client, request, attempt) do
    case transport(client, request) do
      {:ok, %{status: status, headers: headers, body: body}}
      when is_integer(status) and is_map(headers) and is_binary(body) ->
        delay = retry_after(headers)

        cond do
          byte_size(body) > client.max_response_bytes ->
            response_error("response exceeds max_response_bytes")

          status in [429, 529] and attempt < client.max_retries and
              (is_nil(delay) or delay <= client.max_retry_delay) ->
            wait =
              delay ||
                min(
                  trunc(:math.pow(2, attempt) * 250) + :rand.uniform(100),
                  client.max_retry_delay
                )

            Process.sleep(wait)
            send_request(client, request, attempt + 1)

          status in 200..299 ->
            decode(client.backend, body)

          true ->
            {:error,
             %Error{
               kind: :http,
               message: "Jev request failed with HTTP #{status}",
               status: status,
               request_id: header(headers, "x-request-id"),
               retry_after: delay
             }}
        end

      {:ok, _} ->
        response_error("transport returned an invalid response")

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, _} ->
        {:error, %Error{kind: :transport, message: "Jev request could not be completed"}}

      _ ->
        response_error("transport returned an invalid result")
    end
  end

  defp transport(client, request) do
    client.transport.request(request, client)
  rescue
    _ -> {:error, :transport_failure}
  catch
    _, _ -> {:error, :transport_failure}
  end

  defp decode(backend, body) do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) -> backend.decode(value)
      _ -> response_error("response must be a JSON object")
    end
  end

  defp retry_after(headers) do
    case header(headers, "retry-after") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {seconds, ""} when seconds >= 0 -> seconds * 1000
          _ -> retry_date(value)
        end
    end
  end

  defp retry_date(value) do
    case Req.Utils.parse_http_date(value) do
      {:ok, date} -> max(DateTime.diff(date, DateTime.utc_now(), :millisecond), 0)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp header(headers, name) do
    case Map.get(headers, name) do
      [value | _] when is_binary(value) -> value
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp invalid(message), do: {:error, %Error{kind: :validation, message: message}}
  defp response_error(message), do: {:error, %Error{kind: :response, message: message}}
end
