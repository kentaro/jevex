defmodule Jevex.RequestBoundaryTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error, HTTP, Question}

  defmodule NeverTransport do
    @behaviour Jevex.Transport
    def request(_, _) do
      send(self(), :request_sent)
      {:error, :unexpected_network}
    end
  end

  defp client do
    Client.new!(
      backend: :typesafe,
      api_key: fn ->
        send(self(), :credential_read)
        "fixture"
      end,
      transport: NeverTransport,
      max_retries: 0
    )
  end

  test "public request validates malformed questions before credentials or transport" do
    question = Question.noul!("Urgent?")

    malformed = [
      nil,
      :bad,
      1,
      "bad",
      [],
      %{},
      [question],
      [{"x", question} | :bad],
      %{"x" => :bad},
      %{"x" => Map.delete(question, :criteria)},
      %{"x" => question, x: question},
      [{"x", question}, {"x", question}]
    ]

    for questions <- malformed do
      assert {:error, %Error{kind: :validation}} = HTTP.request(client(), "state", questions)
    end

    refute_receive :credential_read
    refute_receive :request_sent
  end

  test "invalid state trees are rejected before credentials or transport" do
    questions = %{"x" => Question.noul!("Urgent?")}

    for state <- [
          nil,
          10,
          :bad,
          true,
          fn -> :bad end,
          self(),
          {"tuple"},
          <<255>>,
          ["valid" | :bad],
          %{nested: [fn -> :bad end]},
          %{1 => "invalid key"},
          %{nested: %URI{}}
        ] do
      assert {:error, %Error{kind: :validation}} = HTTP.request(client(), state, questions)
    end

    refute_receive :credential_read
    refute_receive :request_sent
  end

  test "invalid JSON key collisions and oversized bodies do not resolve credentials" do
    questions = %{"x" => Question.noul!("Urgent?")}

    assert {:error, %Error{kind: :validation}} =
             HTTP.request(client(), %{"same" => 1, same: 2}, questions)

    assert {:error, %Error{kind: :validation}} =
             HTTP.request(%{client() | max_request_bytes: 8}, "state", questions)

    refute_receive :credential_read
    refute_receive :request_sent
  end

  test "question encoding rejects each missing required struct field with the documented error" do
    question = Question.noul!("Sensitive sample instruction")

    for value <- [
          nil,
          :bad,
          %{},
          Map.delete(question, :type),
          Map.delete(question, :instructions),
          Map.delete(question, :criteria)
        ] do
      assert {:error, %Error{kind: :validation}} = Question.validate(value)
      error = assert_raise Error, fn -> Question.encode(value) end
      refute error.message =~ "Sensitive sample instruction"
    end
  end
end
