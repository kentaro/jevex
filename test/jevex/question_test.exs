defmodule Jevex.QuestionTest do
  use ExUnit.Case, async: true
  alias Jevex.Question
  doctest Jevex.Question

  test "constructs all types and normalizes structured entries" do
    assert %Question{type: :noul} = Question.noul!(nil)

    assert %{
             "instructions" => %{"question" => "urgent?"},
             "criteria" => %{"true" => %{"examples" => ["now", 1, true]}}
           } =
             Question.encode(
               Question.noul!(%{question: "urgent?"}, %{true => %{examples: ["now", 1, true]}})
             )

    assert %Question{criteria: %{"yes" => nil}} = Question.choice!("choose", %{yes: nil})

    assert %Question{criteria: [nil, %{"level" => 1}]} =
             Question.score!("rate", [nil, %{level: 1}])
  end

  test "rejects key collisions at every depth" do
    for criteria <- [%{:a => nil, "a" => nil}, %{a: %{:x => 1, "x" => 2}}] do
      assert {:error, %Jevex.Error{kind: :validation}} = Question.choice("choose", criteria)
    end
  end

  test "rejects malformed criteria and non-JSON entries" do
    for criteria <- [nil, %{}, [], %{a: :atom}, %{1 => nil}, %{a: self()}, %{a: ~D[2026-01-01]}] do
      assert {:error, _} = Question.choice("choose", criteria)
    end

    for criteria <- [[], ["one"], ["one", 2], %{}] do
      assert {:error, _} = Question.score("rate", criteria)
    end

    assert {:error, _} = Question.noul("yes?", %{other: "no"})
    assert {:error, _} = Question.noul(<<255>>)
    assert {:error, _} = Question.noul(12)
    assert {:error, _} = Question.noul(["one" | :bad_tail])
    assert {:error, _} = Question.noul(%{value: {:tuple}})
    assert {:error, _} = Question.validate(%Question{type: :invalid, instructions: "x"})
    assert {:error, _} = Question.validate(%{})
    assert_raise Jevex.Error, fn -> Question.score!("rate", []) end
    assert {:ok, _} = Question.choice("choose", Map.new(1..255, &{to_string(&1), nil}))
    assert {:error, _} = Question.choice("choose", Map.new(1..256, &{to_string(&1), nil}))
    assert {:ok, _} = Question.score("rate", List.duplicate("level", 10))
    assert {:error, _} = Question.score("rate", List.duplicate("level", 11))
  end
end
