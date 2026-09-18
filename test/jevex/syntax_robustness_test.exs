defmodule Jevex.SyntaxRobustnessTest do
  use ExUnit.Case, async: false
  alias Jevex.{Answer, Error, Response, Syntax}

  defmodule Operators do
    use Jevex
    def scalar(state, expression), do: state ~> expression
    def tagged(state, expression), do: state ~>> expression
    def scalar_operands(left, right), do: left.() ~> right.()
    def tagged_operands(left, right), do: left.() ~>> right.()
  end

  defmodule Transport do
    @behaviour Jevex.Transport
    @impl true
    def request(request, client) do
      Process.put(:robust_requests, Process.get(:robust_requests, 0) + 1)
      send(self(), {:robust_request, Jason.decode!(request.body), client.model})
      [next | rest] = Process.get(:robust_answers, [])
      Process.put(:robust_answers, rest)

      case next do
        {:error, _} = error ->
          error

        {:http, status} ->
          {:ok, %{status: status, headers: %{}, body: "{}"}}

        answer ->
          body = %{
            "model" => "fixture",
            "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
            "answers" => %{"decision" => answer}
          }

          {:ok, %{status: 200, headers: %{}, body: Jason.encode!(body)}}
      end
    end
  end

  setup do
    original = Map.new([:client, :syntax, Operators], &{&1, Application.fetch_env(:jevex, &1)})

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:jevex, key, value)
        {key, :error} -> Application.delete_env(:jevex, key)
      end)
    end)

    Application.put_env(:jevex, :client, api_key: "fixture", transport: Transport, max_retries: 0)
    Application.delete_env(:jevex, :syntax)
    Application.delete_env(:jevex, Operators)
    Process.put(:robust_requests, 0)
    :ok
  end

  defp noul(value), do: %{"type" => "noul", "noul" => value}

  defp choice(value),
    do: %{
      "type" => "choice",
      "choice" => value,
      "probabilities" => %{"a" => 0.1, "b" => 0.9},
      "confidence" => 0.9
    }

  defp score(value),
    do: %{
      "type" => "score",
      "score" => value,
      "legend" => %{"0" => "low", "1" => "high"},
      "probabilities" => %{"0" => 0.25, "1" => 0.75},
      "confidence" => 0.9
    }

  defp local_noul(value),
    do: %Response{model: nil, usage: nil, answers: %{"decision" => %Answer.Noul{noul: value}}}

  test "every expression form has identical scalar and tagged success semantics" do
    cases = [
      {"Yes?", noul(0), false},
      {"Yes?", noul(1), true},
      {{:noul, "Yes?"}, noul(0), 0},
      {{:noul, "Yes?"}, noul(1), 1},
      {{"Which?", [a: "A", b: "B"]}, choice("b"), :b},
      {{"Which?", %{"a" => "A", "b" => "B"}}, choice("b"), "b"},
      {{"Score?", ["low", "high"]}, score(0.75), 0.75}
    ]

    for {expression, answer, expected} <- cases do
      Process.put(:robust_answers, [answer, answer])
      assert Operators.scalar("state", expression) === expected
      assert Operators.tagged("state", expression) === {:ok, expected}
    end

    assert Process.get(:robust_requests) == length(cases) * 2
  end

  test "raw Noul certainty includes both tails and exact endpoints independent of truth threshold" do
    for operator <- [&Operators.scalar/2, &Operators.tagged/2],
        {probability, certainty} <- [{0, 1}, {1, 1}, {0.5, 0.5}, {0.25, 0.75}, {0.75, 0.75}] do
      Application.put_env(:jevex, :syntax, truth_threshold: 1, min_noul_certainty: certainty)
      Process.put(:robust_answers, [noul(probability)])
      result = operator.("state", {:noul, "Yes?"})
      assert result === probability or result === {:ok, probability}
    end
  end

  test "tagged raw Noul fallback retains a strong negative and cannot chain when backup is uncertain" do
    for {backup, expected} <- [{0.05, {:ok, 0.05}}, {0.5, :low_confidence}] do
      Application.put_env(:jevex, :syntax,
        truth_threshold: 1,
        min_noul_certainty: 0.9,
        on_low_confidence: fn context ->
          send(self(), {:low_fallback, context.reason})
          {:ok, local_noul(backup)}
        end,
        on_error: fn _ -> flunk("must not chain fallbacks") end
      )

      Process.put(:robust_answers, [noul(0.5)])
      result = Operators.tagged("state", {:noul, "Yes?"})

      if expected == :low_confidence,
        do: assert(match?({:error, %Error{kind: :low_confidence}}, result)),
        else: assert(result == expected)

      assert_received {:low_fallback, :low_confidence}
      refute_received {:low_fallback, _}
    end

    assert Process.get(:robust_requests) == 2
  end

  test "tagged raw Noul error fallback is gated too and auth never invokes it" do
    Application.put_env(:jevex, :syntax,
      min_noul_certainty: 0.9,
      on_error: fn _ ->
        send(self(), :error_fallback)
        {:ok, local_noul(0.5)}
      end
    )

    Process.put(:robust_answers, [{:error, :offline}, {:http, 401}])
    assert {:error, %Error{kind: :low_confidence}} = Operators.tagged("state", {:noul, "Yes?"})
    assert_received :error_fallback
    assert {:error, %Error{kind: :http, status: 401}} = Operators.tagged("state", {:noul, "Yes?"})
    refute_received :error_fallback
  end

  test "malformed global and module settings produce configuration errors without requests" do
    invalid_settings = [
      nil,
      true,
      1,
      "settings",
      %{},
      MapSet.new(),
      [:client],
      [{"client", []}],
      [truth_threshold: 0.5, truth_threshold: 0.8],
      [{:client, []} | :bad]
    ]

    for settings <- invalid_settings, key <- [:syntax, Operators] do
      Application.delete_env(:jevex, :syntax)
      Application.delete_env(:jevex, Operators)
      Application.put_env(:jevex, key, settings)
      assert {:error, %Error{kind: :configuration}} = Operators.tagged("state", {:noul, "Yes?"})
    end

    assert Process.get(:robust_requests) == 0
  end

  test "malformed caller, client options and fallback actions never leak clause exceptions" do
    for caller <- [1, "module", [], %{}, self(), fn -> :ok end] do
      assert {:error, %Error{kind: :configuration}} = Syntax.evaluate("state", "Yes?", caller)
    end

    bad_client = [
      nil,
      true,
      1,
      %{},
      %{__struct__: Jevex.Client},
      Map.delete(Jevex.Client.new!(), :endpoint),
      [:bad],
      [{"api_key", "secret"}],
      [{:api_key, "secret"} | :bad]
    ]

    for value <- bad_client, key <- [:client, :on_error] do
      Application.put_env(:jevex, :syntax, [{key, value}])
      assert {:error, %Error{kind: :configuration}} = Operators.tagged("state", "Yes?")
    end

    for value <- [fn -> :wrong_arity end, fn _, _ -> :wrong_arity end, {:system, "SECRET"}] do
      Application.put_env(:jevex, :syntax, on_error: value)
      assert {:error, %Error{kind: :configuration}} = Operators.tagged("state", "Yes?")
    end

    assert Process.get(:robust_requests) == 0
  end

  test "malformed dynamic expressions including improper arrays remain typed errors" do
    expressions = [
      <<255>>,
      {:noul, nil},
      {:noul, <<255>>},
      {"Score?", ["low" | :bad]},
      {"Choose?", %{<<255>> => nil}},
      {"Choose?", [a: :not_json]},
      {"Score?", [nil, fn -> :bad end]},
      %{question: "Yes?"}
    ]

    for expression <- expressions do
      assert {:error, %Error{kind: :validation}} = Operators.tagged("state", expression)
    end

    assert Process.get(:robust_requests) == 0
  end

  test "decision helper rejects forged answer structs with missing required keys" do
    answers = [
      {%Answer.Noul{noul: 0.8}, {:noul, "Yes?"}, [:noul]},
      {%Answer.Choice{choice: "b", probabilities: nil, confidence: nil},
       {"Choose?", [a: "A", b: "B"]}, [:choice, :probabilities, :confidence]},
      {%Answer.Score{score: 0.75, legend: nil, probabilities: nil, confidence: nil},
       {"Score?", ["low", "high"]}, [:score, :legend, :probabilities, :confidence]}
    ]

    for {answer, expression, keys} <- answers, key <- keys do
      error = assert_raise Error, fn -> Syntax.decision!(Map.delete(answer, key), expression) end
      assert error.kind == :response
    end
  end

  test "fallback callbacks cannot leak exceptions via forged successful structs" do
    valid = local_noul(0.95)

    forged = [
      Map.delete(valid, :answers),
      Map.delete(valid, :usage),
      %{valid | answers: %{"decision" => Map.delete(%Answer.Noul{noul: 0.95}, :noul)}},
      %{
        valid
        | answers: %{
            "decision" =>
              Map.delete(
                %Answer.Choice{choice: "b", probabilities: nil, confidence: nil},
                :confidence
              )
          }
      }
    ]

    for response <- forged do
      Application.put_env(:jevex, :syntax, on_error: fn _ -> {:ok, response} end)
      Process.put(:robust_answers, [{:error, :offline}])
      assert {:error, %Error{kind: :response}} = Operators.tagged("state", {:noul, "Yes?"})
    end
  end

  test "exceptions and throws in either operand remain caller exceptions with no request" do
    for operator <- [&Operators.scalar_operands/2, &Operators.tagged_operands/2] do
      right = fn ->
        send(self(), :right_reached)
        "Yes?"
      end

      assert_raise ArgumentError, "operand", fn ->
        operator.(
          fn ->
            send(self(), :left_reached)
            raise ArgumentError, "operand"
          end,
          right
        )
      end

      assert_received :left_reached
      refute_received :left_reached
      refute_received :right_reached

      left = fn ->
        send(self(), :left_reached)
        "state"
      end

      assert catch_throw(
               operator.(left, fn ->
                 send(self(), :right_reached)
                 throw(:operand_throw)
               end)
             ) == :operand_throw

      assert_received :left_reached
      assert_received :right_reached
      refute_received :left_reached
      refute_received :right_reached
    end

    assert Process.get(:robust_requests) == 0
  end

  test "literal duplicate nested JSON keys fail compilation before any request" do
    for {operator, name} <- [{"~>", "Scalar"}, {"~>>", "Tagged"}] do
      source =
        "defmodule Jevex.SyntaxRobustnessTest.Duplicate#{name} do\nuse Jevex\ndef run(s), do: s #{operator} {\"Choose?\", %{a: %{nested: \"first\", nested: \"second\"}, b: nil}}\nend"

      assert_raise CompileError, fn -> Code.compile_string(source) end
    end

    assert Process.get(:robust_requests) == 0
  end

  test "dynamic tagged expression is deferred at expansion and runs once at invocation" do
    source = """
    defmodule Jevex.SyntaxRobustnessTest.DeferredTagged do
      use Jevex
      def run(s), do: s ~>> expression()
      defp expression do
        send(self(), :dynamic_expression)
        {:noul, "Yes?"}
      end
    end
    """

    [{module, _}] = Code.compile_string(source)
    refute_received :dynamic_expression
    assert Process.get(:robust_requests) == 0
    Process.put(:robust_answers, [noul(0.75)])
    assert module.run("state") == {:ok, 0.75}
    assert_received :dynamic_expression
    refute_received :dynamic_expression
    assert Process.get(:robust_requests) == 1
  end
end
