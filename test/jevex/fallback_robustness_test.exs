defmodule Jevex.FallbackRobustnessTest do
  use ExUnit.Case, async: true
  alias Jevex.{Answer, Client, Error, Question, Response}

  defmodule Unavailable do
    @behaviour Jevex.Transport
    def request(_, _), do: {:error, :connection_unavailable}
  end

  defp client, do: Client.new!(api_key: "private-key", transport: Unavailable)

  defp response(answer) do
    %Response{model: "private-model", usage: nil, answers: %{"decision" => answer}}
  end

  defp assert_safe_failure(candidate, question) do
    assert {:error, %Error{kind: :response} = error} =
             Jevex.evaluate(client(), "private-state", %{decision: question},
               on_error: fn _ -> {:ok, candidate} end
             )

    refute inspect(error) =~ "private"
  end

  test "callback response structs with deleted required fields return safe errors" do
    valid = response(%Answer.Noul{noul: 0.8})

    for field <- [:answers, :model, :usage] do
      assert_safe_failure(Map.delete(valid, field), Question.noul!("Urgent?"))
    end
  end

  test "callback answer structs with deleted fields never leak KeyError" do
    cases = [
      {%Answer.Noul{noul: 0.8}, Question.noul!("Urgent?"), [:noul]},
      {%Answer.Choice{choice: "private-choice", probabilities: nil, confidence: nil},
       Question.choice!("Which?", %{"private-choice" => nil}),
       [:choice, :probabilities, :confidence]},
      {%Answer.Score{
         score: 0.8,
         legend: %{"0" => "Low", "1" => "High"},
         probabilities: nil,
         confidence: nil
       }, Question.score!("Risk?", ["Low", "High"]),
       [:score, :legend, :probabilities, :confidence]}
    ]

    for {answer, question, fields} <- cases, field <- fields do
      assert_safe_failure(response(Map.delete(answer, field)), question)
    end
  end

  test "malformed answer maps and unexpected callback results return safe errors" do
    for answers <- [nil, [], :invalid, %URI{host: "private-host"}, %{"decision" => :invalid}] do
      assert_safe_failure(
        %{response(%Answer.Noul{noul: 0.8}) | answers: answers},
        Question.noul!("Urgent?")
      )
    end

    for candidate <- [nil, %{}, %{__struct__: Response}, %URI{host: "private-host"}] do
      assert_safe_failure(candidate, Question.noul!("Urgent?"))
    end
  end

  test "intact responses preserve router metadata absence and confidence gates" do
    question = Question.choice!("Which?", %{"billing" => nil})
    valid = response(%Answer.Choice{choice: "billing", probabilities: nil, confidence: nil})
    callback = fn _ -> {:ok, valid} end

    assert {:ok, result} =
             Jevex.evaluate(client(), "state", %{decision: question}, on_error: callback)

    assert result.answers["decision"].confidence == nil

    assert {:error, %Error{kind: :low_confidence}} =
             Jevex.evaluate(client(), "state", %{decision: question},
               on_error: callback,
               min_confidence: 0.8
             )
  end
end
