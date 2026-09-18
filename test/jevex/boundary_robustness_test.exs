defmodule Jevex.BoundaryRobustnessTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error, Question, Response}

  defmodule TrapTransport do
    @behaviour Jevex.Transport
    def request(_, _) do
      send(self(), :unexpected_request)
      {:error, :unavailable}
    end
  end

  defp client, do: Client.new!(api_key: "private-key", transport: TrapTransport)
  defp questions, do: %{"decision" => Question.noul!("Urgent?")}

  defp body do
    %{
      "model" => "fixture",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "answers" => %{"decision" => %{"type" => "noul", "noul" => 0.8}}
    }
  end

  test "every missing client field is rejected before any request" do
    valid = client()

    for field <- Map.keys(Map.from_struct(valid)) do
      broken = Map.delete(valid, field)
      assert {:error, %Error{kind: :configuration} = error} = Client.validate(broken)
      refute inspect(error) =~ "private"
      assert {:error, %Error{kind: :configuration}} = Jevex.evaluate(broken, "state", questions())
    end

    refute_receive :unexpected_request
  end

  test "client validation and credential lookup reject malformed values safely" do
    for value <- [nil, :invalid, %{}, %{__struct__: Client}, []] do
      assert {:error, %Error{kind: :configuration}} = Client.validate(value)
      assert {:error, %Error{kind: :configuration}} = Client.credential(value)
    end
  end

  test "client options reject duplicate and malformed keys" do
    for opts <- [
          [backend: :typesafe, backend: :lolipop],
          [timeout: 1, timeout: 2],
          [api_key: "private-one", api_key: "private-two"],
          [unknown: 1],
          [{:timeout, 1} | :invalid],
          ["timeout"],
          nil
        ] do
      assert {:error, %Error{kind: :configuration} = error} = Client.new(opts)
      refute inspect(error) =~ "private"
    end
  end

  test "response options reject unknown duplicate and nonboolean settings" do
    for opts <- [
          :bad,
          nil,
          %{},
          [allow_partial_metadata: :yes],
          [allow_partial_metadata: 1],
          [allow_partial_metadata: nil],
          [allow_partial_metadata: true, allow_partial_metadata: false],
          [typo: true],
          [{:allow_partial_metadata, true} | :invalid]
        ] do
      assert {:error, %Error{kind: :response}} = Response.decode(body(), questions(), opts)

      assert {:error, %Error{kind: :response}} =
               Response.decode(Jason.encode!(body()), questions(), opts)
    end
  end

  test "structs cannot impersonate JSON maps at response boundaries" do
    assert {:error, %Error{kind: :response}} = Response.decode(body(), %URI{})

    assert {:error, %Error{kind: :response}} =
             Response.decode(%{body() | "answers" => %URI{}}, questions())

    assert {:error, %Error{kind: :response}} =
             Response.decode(%{body() | "usage" => %URI{}}, questions(),
               allow_partial_metadata: true
             )

    forged = Map.put(body(), :__struct__, URI)
    assert {:error, %Error{kind: :response}} = Response.decode(forged, questions())

    forged_answer = %{"type" => "noul", "noul" => 0.8, :__struct__ => URI}

    assert {:error, %Error{kind: :response}} =
             Response.decode(put_in(body(), ["answers", "decision"], forged_answer), questions())
  end

  test "valid explicit false and true options retain strict and router modes" do
    assert {:ok, _} = Response.decode(body(), questions(), allow_partial_metadata: false)
    partial = Map.drop(body(), ["model", "usage"])
    assert {:error, _} = Response.decode(partial, questions(), allow_partial_metadata: false)

    assert {:ok, %{model: nil, usage: nil}} =
             Response.decode(partial, questions(), allow_partial_metadata: true)
  end
end
