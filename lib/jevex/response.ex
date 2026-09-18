defmodule Jevex.Response do
  @moduledoc """
  Validated native Jev response.

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

  @type t :: %__MODULE__{
          model: String.t() | nil,
          answers: %{String.t() => Answer.t()},
          usage: %{String.t() => non_neg_integer()} | nil
        }
  @tolerance 1.0e-4

  @doc "Decodes and validates a response against the exact requested questions."
  @spec decode(binary() | map(), %{String.t() => Question.t()}, keyword()) ::
          {:ok, t()} | {:error, Error.t()}
  def decode(body, questions, opts \\ [])

  def decode(body, questions, opts) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decode(decoded, questions, opts)
      {:error, _} -> invalid("response is not valid JSON")
    end
  end

  def decode(%{"answers" => answers} = body, questions, opts)
      when is_map(answers) and is_map(questions) do
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

  def decode(_, _, _), do: invalid("response must contain model, answers, and usage")

  defp valid_questions?(questions) do
    map_size(questions) > 0 and
      Enum.all?(questions, fn {id, q} -> is_binary(id) and Question.validate(q) == :ok end)
  end

  defp valid_usage?(usage, true) when is_map(usage) do
    Enum.all?(["input_tokens", "output_tokens"], fn key ->
      case Map.fetch(usage, key) do
        :error -> true
        {:ok, count} -> is_integer(count) and count >= 0
      end
    end)
  end

  defp valid_usage?(%{"input_tokens" => input, "output_tokens" => output}, false) do
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

  defp metadata(answer, question, opts) when is_map(answer) do
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

  defp metadata(answer, _, _), do: answer
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

  defp distribution?(probs, expected) when is_map(probs) do
    same_keys?(probs, expected) and Enum.all?(Map.values(probs), &probability?/1) and
      abs(Enum.sum(Map.values(probs)) - 1) <= @tolerance
  end

  defp distribution?(_, _), do: false
  defp same_keys?(left, right), do: MapSet.new(Map.keys(left)) == MapSet.new(Map.keys(right))
  defp invalid(message), do: {:error, %Error{kind: :response, message: message}}
end
