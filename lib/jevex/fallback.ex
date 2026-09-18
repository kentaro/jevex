defmodule Jevex.Fallback do
  @moduledoc """
  A single-attempt fallback and confidence policy for `Jevex.evaluate/4`.

  Supply a backup `Jevex.Client` or a callback accepting the context below.
  The context's questions use normalized string IDs, and `client` identifies
  the primary client. On `:error`, `response` is nil; on `:low_confidence`,
  `error` is nil. The context contains request state and credentials through
  the client: treat it as sensitive and do not log it indiscriminately.

  Callback responses must use ordinary `Jevex.Response` and `Jevex.Answer`
  structs with string answer IDs and string choices, just like dynamic
  evaluation. Metadata may be nil where routers omit it; a configured
  confidence threshold still rejects missing confidence. Callback responses
  are checked for coverage, answer types, rubric options and distributions.

  A backup's error or insufficient confidence terminates the evaluation;
  it never triggers another fallback, even when both fallback options are set.
  Each client may still use its own bounded HTTP retry policy.
  """
  alias Jevex.{Answer, Client, Error, Question, Response}

  @type context :: %{
          reason: :error | :low_confidence,
          error: Error.t() | nil,
          response: Response.t() | nil,
          state: term(),
          questions: %{String.t() => Question.t()},
          client: Client.t()
        }
  @type action :: Client.t() | (context() -> {:ok, Response.t()} | {:error, Error.t()})
  @type options :: [
          on_error: action(),
          on_low_confidence: action(),
          min_confidence: number(),
          min_noul_certainty: number()
        ]
  @keys [:on_error, :on_low_confidence, :min_confidence, :min_noul_certainty]

  @doc """
  Validates an evaluation's fallback actions and confidence thresholds.

  Called before sending the primary request. Unknown or duplicate keys, invalid
  backup clients, unsupported callback arities, and out-of-range thresholds
  return a configuration error. A low-confidence action requires at least one
  threshold. Credential sources are not resolved during this check.

      iex> Jevex.Fallback.validate_options(min_confidence: 0.8, min_noul_certainty: 0.9)
      :ok

      iex> {:error, error} = Jevex.Fallback.validate_options(min_confidence: 1.1)
      iex> error.kind
      :configuration

      iex> backup = Jevex.Client.new!(backend: :typesafe)
      iex> {:error, error} = Jevex.Fallback.validate_options(on_low_confidence: backup)
      iex> error.kind
      :configuration
  """
  @spec validate_options(term()) :: :ok | {:error, Error.t()}
  def validate_options(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- Enum.all?(keys, &(&1 in @keys)),
         true <- length(keys) == length(Enum.uniq(keys)),
         :ok <- validate_actions(opts),
         true <- valid_threshold?(opts, :min_confidence, 0),
         true <- valid_threshold?(opts, :min_noul_certainty, 0.5),
         true <-
           not Keyword.has_key?(opts, :on_low_confidence) or
             Keyword.has_key?(opts, :min_confidence) or
             Keyword.has_key?(opts, :min_noul_certainty) do
      :ok
    else
      {:error, _} = error -> error
      _ -> configuration_error()
    end
  end

  defp validate_actions(opts) do
    Enum.reduce_while([:on_error, :on_low_confidence], :ok, fn key, :ok ->
      case Keyword.fetch(opts, key) do
        :error ->
          {:cont, :ok}

        {:ok, %Client{} = client} ->
          case Client.validate(client) do
            :ok -> {:cont, :ok}
            _ -> {:halt, configuration_error()}
          end

        {:ok, fun} when is_function(fun, 1) ->
          {:cont, :ok}

        _ ->
          {:halt, configuration_error()}
      end
    end)
  end

  defp valid_threshold?(opts, key, min) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, value} -> is_number(value) and value >= min and value <= 1
    end
  end

  @doc """
  Applies a validated fallback policy to an already validated evaluation result.

  This function integrates the policy with the evaluation layer. Its caller
  must first call `validate_options/1` and validate successful responses through
  `Jevex.Response`. Use `Jevex.evaluate/4` for the complete public entry point.
  The supplied question map uses normalized string IDs.

  Returns the primary result if no action is needed. Otherwise invokes at most
  one matching backup client or callback. Successful fallback responses are
  revalidated and must pass the same thresholds; no fallback chain is followed.

  ## Examples

  A strong negative Noul answer meets a certainty threshold:

      iex> client = Jevex.Client.new!(backend: :typesafe)
      iex> questions = %{"urgent" => Jevex.Question.noul!("Urgent?")}
      iex> response = %Jevex.Response{model: "fixture", usage: nil, answers: %{"urgent" => %Jevex.Answer.Noul{noul: 0.05}}}
      iex> Jevex.Fallback.resolve({:ok, response}, client, "state", questions, min_noul_certainty: 0.9) == {:ok, response}
      true

  A callback can recover a transport failure without another network request:

      iex> client = Jevex.Client.new!(backend: :typesafe)
      iex> questions = %{"urgent" => Jevex.Question.noul!("Urgent?")}
      iex> answer = %Jevex.Response{model: "local-policy", usage: nil, answers: %{"urgent" => %Jevex.Answer.Noul{noul: 0.95}}}
      iex> failure = %Jevex.Error{kind: :transport, message: "Connection unavailable"}
      iex> fallback = fn %{reason: :error, error: %{kind: :transport}} -> {:ok, answer} end
      iex> {:ok, recovered} = Jevex.Fallback.resolve({:error, failure}, client, "state", questions, on_error: fallback)
      iex> recovered.answers["urgent"].noul
      0.95
  """
  @spec resolve({:ok, Response.t()} | {:error, Error.t()}, Client.t(), term(), map(), options()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def resolve({:ok, response} = result, client, state, questions, opts) do
    if sufficient?(response, opts) do
      result
    else
      context = context(:low_confidence, nil, response, client, state, questions)

      case Keyword.fetch(opts, :on_low_confidence) do
        {:ok, action} -> run(action, context, opts)
        :error -> low_confidence()
      end
    end
  end

  def resolve({:error, error} = result, client, state, questions, opts) do
    if eligible_error?(error) and Keyword.has_key?(opts, :on_error) do
      run(
        Keyword.fetch!(opts, :on_error),
        context(:error, error, nil, client, state, questions),
        opts
      )
    else
      result
    end
  end

  defp context(reason, error, response, client, state, questions),
    do: %{
      reason: reason,
      error: error,
      response: response,
      state: state,
      questions: questions,
      client: client
    }

  defp eligible_error?(%Error{kind: :transport}), do: true

  defp eligible_error?(%Error{kind: :http, status: status}),
    do: status in [429, 529] or status in 500..599

  defp eligible_error?(_), do: false

  defp run(action, context, opts) do
    with {:ok, response} <- invoke(action, context),
         {:ok, response} <- validate_response(response, context.questions) do
      if sufficient?(response, opts), do: {:ok, response}, else: low_confidence()
    end
  end

  defp invoke(%Client{} = client, context),
    do: Jevex.evaluate(client, context.state, context.questions)

  defp invoke(fun, context) do
    case fun.(context) do
      {:ok, %Response{} = response} -> {:ok, response}
      {:error, %Error{} = error} -> {:error, error}
      _ -> callback_error()
    end
  rescue
    _ -> callback_error()
  catch
    _, _ -> callback_error()
  end

  # Reconstruct the wire shape and use the same boundary validator as HTTP.
  defp validate_response(%Response{} = response, questions) do
    with true <- is_map(response.answers) and not is_struct(response.answers),
         {:ok, answers} <- encode_answers(response.answers) do
      body =
        %{"answers" => answers}
        |> put_metadata("model", response.model)
        |> put_metadata("usage", response.usage)

      Response.decode(body, questions, allow_partial_metadata: true)
    else
      _ -> callback_error()
    end
  end

  defp encode_answers(answers) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case encode_answer(answer) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, id, value)}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp encode_answer(%Answer.Noul{noul: value}), do: {:ok, %{"type" => "noul", "noul" => value}}

  defp encode_answer(%Answer.Choice{} = answer) do
    {:ok,
     %{"type" => "choice", "choice" => answer.choice}
     |> put_metadata("probabilities", answer.probabilities)
     |> put_metadata("confidence", answer.confidence)}
  end

  defp encode_answer(%Answer.Score{} = answer) do
    {:ok,
     %{"type" => "score", "score" => answer.score}
     |> put_metadata("legend", answer.legend)
     |> put_metadata("probabilities", answer.probabilities)
     |> put_metadata("confidence", answer.confidence)}
  end

  defp encode_answer(_), do: :error
  defp put_metadata(map, _, nil), do: map
  defp put_metadata(map, key, value), do: Map.put(map, key, value)

  defp sufficient?(response, opts) do
    Enum.all?(response.answers, fn {_, answer} ->
      case answer do
        %Answer.Noul{noul: value} -> meets?(max(value, 1 - value), opts, :min_noul_certainty)
        %Answer.Choice{confidence: value} -> meets?(value, opts, :min_confidence)
        %Answer.Score{confidence: value} -> meets?(value, opts, :min_confidence)
      end
    end)
  end

  defp meets?(value, opts, key) do
    case Keyword.fetch(opts, key) do
      :error -> true
      {:ok, threshold} -> is_number(value) and value >= threshold
    end
  end

  defp low_confidence,
    do:
      {:error,
       %Error{
         kind: :low_confidence,
         message: "evaluation does not meet the configured confidence thresholds"
       }}

  defp callback_error,
    do:
      {:error,
       %Error{
         kind: :response,
         message: "fallback callback failed or returned an invalid response"
       }}

  defp configuration_error,
    do:
      {:error,
       %Error{
         kind: :configuration,
         message: "invalid fallback options, action, or confidence threshold"
       }}
end
