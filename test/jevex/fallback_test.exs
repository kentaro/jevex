defmodule Jevex.FallbackTest do
  use ExUnit.Case, async: true
  alias Jevex.{Answer, Client, Error, Question, Response}

  defmodule Transport do
    @behaviour Jevex.Transport
    @impl true
    def request(request, client) do
      send(self(), {:sent, client.model, Jason.decode!(request.body)})
      [result | rest] = Process.get(:fallback_responses, [])
      Process.put(:fallback_responses, rest)
      result
    end
  end

  defp client(model \\ "primary"),
    do: Client.new!(model: model, api_key: "test", transport: Transport, max_retries: 0)

  defp questions, do: %{q: Question.choice!("Choose", %{a: nil, b: nil})}

  defp response(confidence \\ 0.9) do
    %Response{
      model: "backup",
      usage: nil,
      answers: %{
        "q" => %Answer.Choice{
          choice: "a",
          probabilities: %{"a" => 0.9, "b" => 0.1},
          confidence: confidence
        }
      }
    }
  end

  defp success(confidence \\ 0.9) do
    body = %{
      "model" => "resolved",
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
      "answers" => %{
        "q" => %{
          "type" => "choice",
          "choice" => "a",
          "probabilities" => %{"a" => 0.9, "b" => 0.1},
          "confidence" => confidence
        }
      }
    }

    {:ok, %{status: 200, headers: %{}, body: Jason.encode!(body)}}
  end

  defp status(code), do: {:ok, %{status: code, headers: %{}, body: "{}"}}

  test "transient failure invokes exactly one backup client" do
    Process.put(:fallback_responses, [{:error, :offline}, success()])

    assert {:ok, %Response{}} =
             Jevex.evaluate(client(), "state", questions(), on_error: client("backup"))

    assert_received {:sent, "primary", %{"state" => "state"}}
    assert_received {:sent, "backup", %{"state" => "state", "questions" => %{"q" => _}}}
    refute_received {:sent, _, _}
  end

  test "only transient HTTP statuses trigger fallback" do
    for code <- [429, 500, 502, 503, 529, 599] do
      Process.put(:fallback_responses, [status(code)])

      assert {:ok, _} =
               Jevex.evaluate(client(), "state", questions(),
                 on_error: fn ctx ->
                   assert ctx.reason == :error
                   assert ctx.error.status == code
                   assert ctx.response == nil
                   assert ctx.state == "state"
                   assert Map.keys(ctx.questions) == ["q"]
                   assert ctx.client.model == "primary"
                   {:ok, response()}
                 end
               )
    end
  end

  test "auth and nontransient errors never trigger fallback" do
    for code <- [400, 401, 403, 404, 422] do
      Process.put(:fallback_responses, [status(code)])

      assert {:error, %Error{kind: :http, status: ^code}} =
               Jevex.evaluate(client(), "state", questions(),
                 on_error: fn _ -> flunk("must not run") end
               )
    end

    assert {:error, %Error{kind: :validation}} =
             Jevex.evaluate(client(), nil, questions(),
               on_error: fn _ -> flunk("must not run") end
             )

    Process.put(:fallback_responses, [{:ok, %{status: 200, headers: %{}, body: "broken"}}])

    assert {:error, %Error{kind: :response}} =
             Jevex.evaluate(client(), "state", questions(),
               on_error: fn _ -> flunk("must not run") end
             )
  end

  test "threshold equality passes and low confidence invokes callback" do
    Process.put(:fallback_responses, [success(0.8)])

    assert {:ok, _} =
             Jevex.evaluate(client(), "state", questions(),
               min_confidence: 0.8,
               on_low_confidence: fn _ -> flunk("must not run") end
             )

    Process.put(:fallback_responses, [success(0.4)])

    assert {:ok, %Response{model: "backup"}} =
             Jevex.evaluate(client(), "state", questions(),
               min_confidence: 0.8,
               on_low_confidence: fn ctx ->
                 assert ctx.reason == :low_confidence
                 assert ctx.error == nil
                 assert ctx.response.answers["q"].confidence == 0.4
                 {:ok, response()}
               end
             )
  end

  test "threshold failures without fallback and on backup return low_confidence" do
    Process.put(:fallback_responses, [success(0.2)])

    assert {:error, %Error{kind: :low_confidence}} =
             Jevex.evaluate(client(), "state", questions(), min_confidence: 0.8)

    Process.put(:fallback_responses, [success(0.2), success(0.3)])

    assert {:error, %Error{kind: :low_confidence}} =
             Jevex.evaluate(client(), "state", questions(),
               min_confidence: 0.8,
               on_low_confidence: client("backup"),
               on_error: fn _ -> flunk("must not recurse") end
             )

    Process.put(:fallback_responses, [{:error, :offline}])

    assert {:error, %Error{kind: :low_confidence}} =
             Jevex.evaluate(client(), "state", questions(),
               min_confidence: 0.8,
               on_error: fn _ -> {:ok, response(0.2)} end,
               on_low_confidence: fn _ -> flunk("must not recurse") end
             )
  end

  test "backup transport failure never invokes another fallback" do
    Process.put(:fallback_responses, [success(0.2), {:error, :offline}])

    assert {:error, %Error{kind: :transport}} =
             Jevex.evaluate(client(), "state", questions(),
               min_confidence: 0.8,
               on_low_confidence: client("backup"),
               on_error: fn _ -> flunk("must not recurse") end
             )
  end

  test "noul certainty uses both tails and is independent of min_confidence" do
    questions = %{q: Question.noul!("Yes?")}

    for {probability, threshold, expected} <- [
          {0.1, 0.9, :ok},
          {0.9, 0.9, :ok},
          {0.5, 0.8, :error}
        ] do
      Process.put(:fallback_responses, [{:error, :offline}])

      fallback = fn _ ->
        {:ok,
         %Response{model: nil, usage: nil, answers: %{"q" => %Answer.Noul{noul: probability}}}}
      end

      result =
        Jevex.evaluate(client(), "state", questions,
          on_error: fallback,
          min_confidence: 1,
          min_noul_certainty: threshold
        )

      assert elem(result, 0) == expected
    end

    Process.put(:fallback_responses, [{:error, :offline}])

    assert {:ok, _} =
             Jevex.evaluate(client(), "state", questions,
               min_confidence: 1,
               on_error: fn _ ->
                 {:ok,
                  %Response{model: nil, usage: nil, answers: %{"q" => %Answer.Noul{noul: 0.5}}}}
               end
             )
  end

  test "missing router confidence is low only when threshold is configured" do
    for opts <- [[], [min_confidence: 0]] do
      Process.put(:fallback_responses, [{:error, :offline}])

      result =
        Jevex.evaluate(
          client(),
          "state",
          questions(),
          opts ++ [on_error: fn _ -> {:ok, response(nil)} end]
        )

      if opts == [],
        do: assert(match?({:ok, _}, result)),
        else: assert(match?({:error, %Error{kind: :low_confidence}}, result))
    end
  end

  test "score confidence is checked and missing score legend can be reconstructed" do
    questions = %{q: Question.score!("Quality?", ["low", "high"])}

    for {confidence, expected} <- [{0.8, :ok}, {0.7, :error}, {nil, :error}] do
      Process.put(:fallback_responses, [{:error, :offline}])

      callback = fn _ ->
        {:ok,
         %Response{
           model: nil,
           usage: nil,
           answers: %{
             "q" => %Answer.Score{
               score: 0.8,
               legend: nil,
               probabilities: nil,
               confidence: confidence
             }
           }
         }}
      end

      assert {^expected, _} =
               Jevex.evaluate(client(), "state", questions,
                 on_error: callback,
                 min_confidence: 0.8
               )
    end
  end

  test "fallback runs after the primary HTTP retries are exhausted" do
    Process.put(:fallback_responses, [status(429), status(429), success()])
    primary = %{client() | max_retries: 1, max_retry_delay: 0}
    assert {:ok, _} = Jevex.evaluate(primary, "state", questions(), on_error: client("backup"))
    assert_received {:sent, "primary", _}
    assert_received {:sent, "primary", _}
    assert_received {:sent, "backup", _}
    refute_received {:sent, _, _}
  end

  test "malformed callback responses are revalidated against the original question" do
    good = response()

    bad_responses = [
      %{good | answers: %{}},
      %{good | answers: nil},
      put_in(good.answers["q"].choice, "unknown"),
      put_in(good.answers["q"].confidence, 2),
      put_in(good.answers["q"].probabilities, %{"a" => 0.3, "b" => 0.3}),
      %{good | answers: %{"q" => %Answer.Noul{noul: 0.9}}},
      %{good | answers: %{"q" => %{choice: "a"}}},
      %{good | usage: %{"input_tokens" => -1}}
    ]

    for bad <- bad_responses do
      Process.put(:fallback_responses, [{:error, :offline}])

      assert {:error, %Error{kind: :response}} =
               Jevex.evaluate(client(), "state", questions(), on_error: fn _ -> {:ok, bad} end)
    end
  end

  test "callback exceptions, exits, throws and invalid results are sanitized" do
    for callback <- [
          fn _ -> raise "SECRET" end,
          fn _ -> exit("SECRET") end,
          fn _ -> throw("SECRET") end,
          fn _ -> {:ok, %{secret: "SECRET"}} end
        ] do
      Process.put(:fallback_responses, [{:error, :offline}])

      assert {:error, %Error{} = error} =
               Jevex.evaluate(client(), "state", questions(), on_error: callback)

      refute inspect(error) =~ "SECRET"
    end
  end

  test "all fallback configuration is validated before primary request" do
    for opts <- [
          [unknown: 1],
          [min_confidence: -1],
          [min_confidence: 1.1],
          [min_confidence: "0.8"],
          [min_noul_certainty: 0.4],
          [on_error: :invalid],
          [on_error: fn -> :ok end],
          [on_low_confidence: client()],
          [on_error: %{client() | endpoint: "http://remote.invalid"}],
          [min_confidence: 0.2, min_confidence: 0.4],
          nil
        ] do
      assert {:error, %Error{kind: :configuration}} =
               Jevex.evaluate(client(), "state", questions(), opts)

      refute_received {:sent, _, _}
    end
  end

  test "bang evaluation raises the resulting policy error" do
    Process.put(:fallback_responses, [success(0.1)])

    assert_raise Error, fn ->
      Jevex.evaluate!(client(), "state", questions(), min_confidence: 0.9)
    end
  end
end
