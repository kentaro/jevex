defmodule Jevex.ResponseTest do
  use ExUnit.Case, async: true
  alias Jevex.{Answer, Question, Response}

  defp questions do
    %{
      "urgent" => Question.noul!("Urgent?"),
      "team" => Question.choice!("Team?", %{sales: nil, support: nil}),
      "level" => Question.score!("Level?", ["low", "high"])
    }
  end

  defp body do
    %{
      "model" => "jev-latest",
      "usage" => %{"input_tokens" => 10, "output_tokens" => 3},
      "answers" => %{
        "urgent" => %{"type" => "noul", "noul" => 0.9},
        "team" => %{
          "type" => "choice",
          "choice" => "support",
          "probabilities" => %{"sales" => 0.1, "support" => 0.9},
          "confidence" => 0.8
        },
        "level" => %{
          "type" => "score",
          "score" => 0.7,
          "legend" => %{"0" => "low", "1" => "high"},
          "probabilities" => %{"0" => 0.3, "1" => 0.7},
          "confidence" => 0.6
        }
      }
    }
  end

  test "decodes all native answers from JSON and retains string choices" do
    assert {:ok, %Response{answers: answers}} =
             Response.decode(Jason.encode!(body()), questions())

    assert %Answer.Noul{noul: 0.9} = answers["urgent"]
    assert %Answer.Choice{choice: "support"} = answers["team"]
    assert %Answer.Score{score: 0.7} = answers["level"]
  end

  test "rejects malformed schema and missing or additional answers" do
    for bad <- [
          nil,
          "broken",
          "[]",
          %{},
          Map.delete(body(), "usage"),
          put_in(body(), ["usage", "input_tokens"], -1),
          update_in(body(), ["answers"], &Map.delete(&1, "team")),
          put_in(body(), ["answers", "extra"], %{})
        ] do
      assert {:error, %Jevex.Error{kind: :response}} = Response.decode(bad, questions())
    end
  end

  test "rejects invalid noul and mismatched types" do
    for bad <- [true, "0.9", nil, -0.1, 1.1] do
      assert {:error, _} =
               Response.decode(put_in(body(), ["answers", "urgent", "noul"], bad), questions())
    end

    assert {:error, _} =
             Response.decode(put_in(body(), ["answers", "urgent", "type"], "score"), questions())
  end

  test "rejects unknown choices and malformed distributions" do
    for probs <- [
          %{"support" => 1},
          %{"support" => 0.7, "sales" => 0.7},
          %{"support" => 0.9, "sales" => -0.1},
          %{"support" => "0.9", "sales" => 0.1},
          nil
        ] do
      assert {:error, _} =
               Response.decode(
                 put_in(body(), ["answers", "team", "probabilities"], probs),
                 questions()
               )
    end

    assert {:error, _} =
             Response.decode(
               put_in(body(), ["answers", "team", "choice"], "new-untrusted-option"),
               questions()
             )

    assert {:error, _} =
             Response.decode(put_in(body(), ["answers", "team", "choice"], "sales"), questions())

    assert {:error, _} =
             Response.decode(put_in(body(), ["answers", "team", "confidence"], 2), questions())
  end

  test "rejects invalid score, legend and level keys" do
    for {field, value} <- [
          {"score", -1},
          {"score", 2},
          {"score", "0.7"},
          {"legend", %{"1" => "low", "2" => "high"}},
          {"legend", %{"0" => 0, "1" => 1}},
          {"probabilities", %{"0" => 0.3, "2" => 0.7}}
        ] do
      assert {:error, _} =
               Response.decode(put_in(body(), ["answers", "level", field], value), questions())
    end
  end

  test "handles invalid original questions without raising" do
    assert {:error, _} = Response.decode(body(), %{"urgent" => nil})
    assert {:error, _} = Response.decode(body(), nil)
  end

  test "router mode preserves absent model and usage as nil" do
    minimal = Map.drop(body(), ["model", "usage"])

    assert {:ok, %Response{model: nil, usage: nil}} =
             Response.decode(minimal, questions(), allow_partial_metadata: true)

    assert {:error, _} = Response.decode(minimal, questions())

    assert {:ok, %Response{usage: %{}}} =
             Response.decode(Map.put(minimal, "usage", %{}), questions(),
               allow_partial_metadata: true
             )

    assert {:ok, %Response{usage: %{"input_tokens" => 5}}} =
             Response.decode(Map.put(minimal, "usage", %{"input_tokens" => 5}), questions(),
               allow_partial_metadata: true
             )

    assert {:error, _} =
             Response.decode(Map.put(minimal, "usage", %{"input_tokens" => nil}), questions(),
               allow_partial_metadata: true
             )

    assert {:error, _} =
             Response.decode(Map.put(minimal, "model", 12), questions(),
               allow_partial_metadata: true
             )
  end

  test "router mode permits missing metadata but rejects explicit invalid values" do
    partial =
      update_in(body(), ["answers"], fn answers ->
        Map.new(answers, fn {id, answer} ->
          {id, Map.drop(answer, ["confidence", "probabilities", "legend"])}
        end)
      end)

    assert {:error, _} = Response.decode(partial, questions())

    assert {:ok, %Response{answers: answers}} =
             Response.decode(partial, questions(), allow_partial_metadata: true)

    assert %Answer.Choice{probabilities: nil, confidence: nil} = answers["team"]

    assert %Answer.Score{
             legend: %{"0" => "low", "1" => "high"},
             probabilities: nil,
             confidence: nil
           } = answers["level"]

    for invalid <- [nil, -1, "0.7"] do
      assert {:error, _} =
               Response.decode(
                 put_in(partial, ["answers", "team", "confidence"], invalid),
                 questions(),
                 allow_partial_metadata: true
               )
    end

    assert {:error, _} =
             Response.decode(
               put_in(partial, ["answers", "team", "choice"], "unknown"),
               questions(),
               allow_partial_metadata: true
             )
  end
end
