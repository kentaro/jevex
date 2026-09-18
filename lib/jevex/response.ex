defmodule Jevex.Response do
  @moduledoc """
  The full validated response returned by explicit typed evaluation.

  `Jevex.Syntax` extracts a boolean, probability, choice key, or score from this
  representation. Use `Jevex.evaluate/4` directly when you need answer metadata,
  reported model information, usage, or a batch of answers.

  `decode/2` accepts a JSON string or decoded string-keyed map and the original
  question map. It verifies answer coverage and types, option/level coverage,
  probability ranges and sums (absolute tolerance `1.0e-4`), confidence, score
  bounds, and token counts. Unknown metadata fields are ignored. Answer IDs,
  choice options, and level keys stay strings; decoding never creates atoms.

  Pass `allow_partial_metadata: true` for router responses that omit confidence,
  probabilities, or the score legend. Missing confidence/probabilities become
  `nil`; a missing legend is reconstructed from the question rubric. Metadata
  that is present must still be valid (explicit `null` is not treated as absent).
  Missing top-level model and usage are also represented by `nil` in router
  mode. Native responses should use the strict default.

  Protocol failures return a sanitized `Jevex.Error` without retaining the body.
  """
  alias Jevex.{Answer, Error, Question}
  @enforce_keys [:model, :answers, :usage]
  defstruct [:model, :answers, :usage]

  @typedoc "A decoded response with string answer IDs; router metadata may be absent."
  @type t :: %__MODULE__{
          model: String.t() | nil,
          answers: %{String.t() => Answer.t()},
          usage: %{String.t() => non_neg_integer()} | nil
        }
  @tolerance 1.0e-4

  @doc """
  Decodes a JSON body or string-keyed map against the exact requested questions.

  Returns `{:ok, response}` or `{:error, %Jevex.Error{kind: :response}}` for
  malformed JSON, mismatched answer coverage, or invalid values. Question IDs
  must already be strings and questions must be valid `Jevex.Question` structs.
  Unknown response metadata is ignored. No response strings are interned as atoms.

  The only option is `allow_partial_metadata: true` (default `false`), used by
  supported routers. It permits absent model, usage fields, confidence,
  probabilities, and score legend. Explicit null metadata remains invalid.
  Missing confidence and probabilities become `nil`; missing score legend is
  derived from the rubric. Supplied metadata is always validated.

  Choice distributions must cover all options, sum to one within `1.0e-4`, and
  assign the selected choice the highest probability (ties within the same
  tolerance are accepted). Score distributions cover all zero-based levels;
  scores are checked for bounds, not equality to their weighted average.

  ## Examples

  Decode all three answer kinds without making a network request:

      iex> questions = %{
      ...>   "urgent" => Jevex.Question.noul!("Urgent?"),
      ...>   "team" => Jevex.Question.choice!("Team?", %{billing: "Payments", support: "Technical"}),
      ...>   "impact" => Jevex.Question.score!("Impact?", ["Low", "High"])
      ...> }
      iex> body = %{
      ...>   "model" => "jev-example",
      ...>   "usage" => %{"input_tokens" => 10, "output_tokens" => 5},
      ...>   "answers" => %{
      ...>     "urgent" => %{"type" => "noul", "noul" => 0.9},
      ...>     "team" => %{"type" => "choice", "choice" => "billing", "probabilities" => %{"billing" => 0.8, "support" => 0.2}, "confidence" => 0.8},
      ...>     "impact" => %{"type" => "score", "score" => 0.75, "legend" => %{"0" => "Low", "1" => "High"}, "probabilities" => %{"0" => 0.25, "1" => 0.75}, "confidence" => 0.75}
      ...>   }
      ...> }
      iex> {:ok, response} = Jevex.Response.decode(Jason.encode!(body), questions)
      iex> response.answers["urgent"]
      %Jevex.Answer.Noul{noul: 0.9}
      iex> response.answers["team"].choice
      "billing"
      iex> response.answers["impact"].score
      0.75
      iex> response.usage
      %{"input_tokens" => 10, "output_tokens" => 5}
      iex> malformed = put_in(body, ["answers", "urgent", "noul"], 1.5)
      iex> {:error, error} = Jevex.Response.decode(malformed, questions)
      iex> error.kind
      :response

  Omitted router metadata remains absent rather than being fabricated:

      iex> questions = %{"team" => Jevex.Question.choice!("Team?", %{billing: "Payments"})}
      iex> body = %{"answers" => %{"team" => %{"type" => "choice", "choice" => "billing"}}}
      iex> {:ok, response} = Jevex.Response.decode(body, questions, allow_partial_metadata: true)
      iex> {response.model, response.usage, response.answers["team"].confidence, response.answers["team"].probabilities}
      {nil, nil, nil, nil}
      iex> {:error, error} = Jevex.Response.decode(body, questions)
      iex> error.kind
      :response

  Invalid JSON returns a structured error:

      iex> {:error, error} = Jevex.Response.decode("not json", %{})
      iex> {error.kind, error.message}
      {:response, "response is not valid JSON"}
  """
  @spec decode(binary() | map(), %{String.t() => Question.t()}, allow_partial_metadata: boolean()) ::
          {:ok, t()} | {:error, Error.t()}
  def decode(body, questions, opts \\ []) do
    with :ok <- validate_options(opts) do
      do_decode(body, questions, opts)
    end
  end

  defp do_decode(body, questions, opts) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> do_decode(decoded, questions, opts)
      {:error, _} -> invalid("response is not valid JSON")
    end
  end

  defp do_decode(%{"answers" => answers} = body, questions, opts)
       when is_map(answers) and not is_struct(answers) and is_map(questions) and
              not is_struct(questions) and not is_struct(body) do
    model = Map.get(body, "model")
    usage = Map.get(body, "usage")
    partial? = Keyword.get(opts, :allow_partial_metadata, false)

    with true <- valid_questions?(questions),
         true <- same_keys?(answers, questions),
         true <-
           (is_binary(model) and byte_size(model) > 0 and String.valid?(model)) or
             (partial? and not Map.has_key?(body, "model")),
         true <- valid_usage?(usage, partial?) or (partial? and not Map.has_key?(body, "usage")),
         {:ok, decoded} <- decode_answers(answers, questions, opts) do
      {:ok,
       %__MODULE__{
         model: model,
         answers: decoded,
         usage:
           if(is_map(usage), do: Map.take(usage, ["input_tokens", "output_tokens"]), else: nil)
       }}
    else
      _ -> invalid("response does not match the requested questions or usage schema")
    end
  end

  defp do_decode(_, _, _), do: invalid("response must contain model, answers, and usage")

  defp validate_options(opts) do
    if Keyword.keyword?(opts) and
         Enum.all?(opts, fn {key, value} ->
           key == :allow_partial_metadata and is_boolean(value)
         end) and length(opts) <= 1 do
      :ok
    else
      invalid("response options must contain only one boolean allow_partial_metadata option")
    end
  end

  defp valid_questions?(questions) do
    map_size(questions) > 0 and
      Enum.all?(questions, fn {id, q} -> is_binary(id) and Question.validate(q) == :ok end)
  end

  defp valid_usage?(usage, true) when is_map(usage) and not is_struct(usage) do
    Enum.all?(["input_tokens", "output_tokens"], fn key ->
      case Map.fetch(usage, key) do
        :error -> true
        {:ok, count} -> is_integer(count) and count >= 0
      end
    end)
  end

  defp valid_usage?(%{"input_tokens" => input, "output_tokens" => output} = usage, false)
       when not is_struct(usage) do
    is_integer(input) and input >= 0 and is_integer(output) and output >= 0
  end

  defp valid_usage?(_, _), do: false

  defp decode_answers(answers, questions, opts) do
    Enum.reduce_while(answers, {:ok, %{}}, fn {id, answer}, {:ok, acc} ->
      case decode_answer(
             metadata(answer, Question.encode(Map.fetch!(questions, id)), opts),
             Question.encode(Map.fetch!(questions, id))
           ) do
        {:ok, answer} -> {:cont, {:ok, Map.put(acc, id, answer)}}
        error -> {:halt, error}
      end
    end)
  end

  defp decode_answer(%{"type" => "noul", "noul" => value}, %{"type" => "noul"}) do
    if probability?(value),
      do: {:ok, %Answer.Noul{noul: value}},
      else: invalid("invalid noul probability")
  end

  defp decode_answer(
         %{
           "type" => "choice",
           "choice" => choice,
           "probabilities" => probs,
           "confidence" => confidence
         },
         %{"type" => "choice", "criteria" => criteria}
       ) do
    if is_binary(choice) and Map.has_key?(criteria, choice) and
         optional_distribution?(probs, criteria) and
         optional_probability?(confidence) and
         highest?(probs, choice) do
      {:ok,
       %Answer.Choice{
         choice: choice,
         probabilities: missing_to_nil(probs),
         confidence: missing_to_nil(confidence)
       }}
    else
      invalid("invalid choice answer or probability distribution")
    end
  end

  defp decode_answer(
         %{
           "type" => "score",
           "score" => score,
           "legend" => legend,
           "probabilities" => probs,
           "confidence" => confidence
         },
         %{"type" => "score", "criteria" => criteria}
       ) do
    levels =
      criteria
      |> Enum.with_index()
      |> Map.new(fn {entry, index} -> {Integer.to_string(index), entry} end)

    if is_number(score) and score >= 0 and score <= length(criteria) - 1 and is_map(legend) and
         not is_struct(legend) and
         same_keys?(legend, levels) and valid_legend?(legend) and
         optional_distribution?(probs, levels) and
         optional_probability?(confidence) do
      {:ok,
       %Answer.Score{
         score: score,
         legend: legend,
         probabilities: missing_to_nil(probs),
         confidence: missing_to_nil(confidence)
       }}
    else
      invalid("invalid score answer, legend, or probability distribution")
    end
  end

  defp decode_answer(_, _),
    do: invalid("answer type or required fields do not match the question")

  defp metadata(answer, question, opts) when is_map(answer) and not is_struct(answer) do
    cond do
      Enum.any?(["confidence", "probabilities"], &(Map.get(answer, &1) == :jevex_missing)) ->
        :invalid

      Keyword.get(opts, :allow_partial_metadata, false) ->
        answer =
          answer
          |> Map.put_new("confidence", :jevex_missing)
          |> Map.put_new("probabilities", :jevex_missing)

        case question do
          %{"type" => "score", "criteria" => criteria} ->
            legend =
              criteria
              |> Enum.with_index()
              |> Map.new(fn {entry, i} -> {Integer.to_string(i), entry} end)

            Map.put_new(answer, "legend", legend)

          _ ->
            answer
        end

      true ->
        answer
    end
  end

  defp metadata(_, _, _), do: :invalid
  defp missing_to_nil(:jevex_missing), do: nil
  defp missing_to_nil(value), do: value
  defp optional_probability?(:jevex_missing), do: true
  defp optional_probability?(value), do: probability?(value)
  defp optional_distribution?(:jevex_missing, _), do: true
  defp optional_distribution?(probs, expected), do: distribution?(probs, expected)
  defp highest?(:jevex_missing, _), do: true

  defp highest?(probs, choice),
    do: Map.fetch!(probs, choice) >= Enum.max(Map.values(probs)) - @tolerance

  defp valid_legend?(legend),
    do: Enum.all?(legend, fn {_, value} -> match?({:ok, _}, Question.noul(value)) end)

  defp probability?(value), do: is_number(value) and value >= 0 and value <= 1

  defp distribution?(probs, expected) when is_map(probs) and not is_struct(probs) do
    same_keys?(probs, expected) and Enum.all?(Map.values(probs), &probability?/1) and
      abs(Enum.sum(Map.values(probs)) - 1) <= @tolerance
  end

  defp distribution?(_, _), do: false
  defp same_keys?(left, right), do: MapSet.new(Map.keys(left)) == MapSet.new(Map.keys(right))
  defp invalid(message), do: {:error, %Error{kind: :response, message: message}}
end
