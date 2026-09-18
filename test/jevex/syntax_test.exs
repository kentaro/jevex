defmodule Jevex.SyntaxTest do
  use ExUnit.Case, async: false
  alias Jevex.{Client, Error}

  defmodule Transport do
    @behaviour Jevex.Transport
    @impl true
    def request(request, client) do
      body = Jason.decode!(request.body)
      send(self(), {:syntax_request, body, client})
      [answer | rest] = Process.get(:syntax_answers, [])
      Process.put(:syntax_answers, rest)

      case answer do
        {:error, reason} ->
          {:error, reason}

        {:http, status} ->
          {:ok, %{status: status, headers: %{}, body: "{}"}}

        value ->
          [id] = Map.keys(body["questions"])

          response = %{
            model: client.model,
            answers: %{id => value},
            usage: %{input_tokens: 1, output_tokens: 1}
          }

          {:ok, %{status: 200, headers: %{}, body: Jason.encode!(response)}}
      end
    end
  end

  defmodule Decisions do
    use Jevex
    def urgent?(state), do: state ~> "Is this urgent?"
    def branch(state), do: if(state ~> "Is this urgent?", do: :escalate, else: :wait)

    def route(state) do
      case state ~> {"Who should handle this?", billing: "Payments", support: "Technical"} do
        :billing -> :finance_queue
        :support -> :support_queue
      end
    end

    def string_route(state), do: state ~> {"Who?", %{"external" => "Vendor", internal: "Staff"}}
    def impact(state), do: state ~> {"How severe?", ["Low", "Medium", "High"]}
    def dynamic(state, expression), do: state ~> expression
    def select(states), do: Enum.filter(states, &(&1 ~> "Is this urgent?"))
    def short_circuit(state), do: false and state ~> "Is this urgent?"
    def once(state_fun, expression_fun), do: state_fun.() ~> expression_fun.()
    def probability(state), do: state ~> {:noul, "Is this urgent?"}
    def result(state, expression), do: state ~>> expression
    def result_once(lhs, rhs), do: lhs.() ~>> rhs.()

    def assess(state) do
      with {:ok, p} <- state ~>> {:noul, "Is this urgent?"},
           {:ok, team} <- state ~>> {"Who?", billing: "Payments", support: "Technical"} do
        {:ok, {p, team}}
      end
    end

    def lazy(states), do: states |> Stream.filter(&(&1 ~> "Is this urgent?")) |> Stream.take(1)
    def comprehension(states), do: for(state <- states, state ~> "Is this urgent?", do: state)

    def dispatch(state), do: handle(state ~> {"Who?", billing: "Payments", support: "Technical"})
    defp handle(:billing), do: :finance
    defp handle(:support), do: :engineering

    def weighted(states),
      do:
        Enum.reduce(states, 0, fn {state, weight}, acc ->
          acc + weight * (state ~> {:noul, "Is this urgent?"})
        end)

    def collect(states) do
      Enum.reduce_while(states, {:ok, []}, fn state, {:ok, values} ->
        case state ~>> {:noul, "Is this urgent?"} do
          {:ok, p} -> {:cont, {:ok, [p | values]}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  defmodule OtherDecisions do
    use Jevex
    def urgent?(state), do: state ~> "Is this urgent?"
  end

  setup do
    keys = [:client, :syntax, Decisions, OtherDecisions]
    original = Map.new(keys, &{&1, Application.fetch_env(:jevex, &1)})

    on_exit(fn ->
      for {key, value} <- original do
        case value do
          {:ok, config} -> Application.put_env(:jevex, key, config)
          :error -> Application.delete_env(:jevex, key)
        end
      end
    end)

    Application.put_env(:jevex, :client,
      backend: :typesafe,
      api_key: "fixture",
      transport: Transport,
      max_retries: 0
    )

    for key <- [:syntax, Decisions, OtherDecisions], do: Application.delete_env(:jevex, key)
    :ok
  end

  defp noul(p), do: %{type: "noul", noul: p}

  defp choice(value, confidence \\ 0.9),
    do: %{
      type: "choice",
      choice: value,
      confidence: confidence,
      probabilities:
        if(value == "billing",
          do: %{"billing" => 0.9, "support" => 0.1},
          else: %{"billing" => 0.1, "support" => 0.9}
        )
    }

  test "raw Noul preserves probability independently of truth threshold with confidence policy" do
    Application.put_env(:jevex, :syntax, truth_threshold: 0.99, min_noul_certainty: 0.8)
    Process.put(:syntax_answers, [noul(0.85), noul(0.6)])
    assert Decisions.probability("ticket") == 0.85
    assert_raise Error, fn -> Decisions.probability("ticket") end
  end

  test "tagged syntax composes with with and stops on a failure" do
    Process.put(:syntax_answers, [noul(0.85), choice("billing")])
    assert Decisions.assess("ticket") == {:ok, {0.85, :billing}}
    Process.put(:syntax_answers, [{:error, :offline}, choice("support")])
    assert {:error, %Error{kind: :transport}} = Decisions.assess("ticket")
    assert Process.get(:syntax_answers) == [choice("support")]
  end

  test "tagged syntax returns false as success and catches validation failures" do
    Process.put(:syntax_answers, [noul(0.1)])
    assert Decisions.result("ticket", "Urgent?") == {:ok, false}
    assert {:error, %Error{kind: :validation}} = Decisions.result("ticket", nil)
    assert {:error, %Error{kind: :validation}} = Jevex.Syntax.evaluate("ticket", nil)
  end

  test "tagged operands run once and application exceptions are not hidden" do
    Process.put(:syntax_answers, [noul(0.9)])

    lhs = fn ->
      send(self(), :left_operand)
      "ticket"
    end

    rhs = fn ->
      send(self(), :right_operand)
      "Urgent?"
    end

    assert Decisions.result_once(lhs, rhs) == {:ok, true}
    assert_receive :left_operand
    assert_receive :right_operand
    refute_receive :left_operand
    refute_receive :right_operand

    assert_raise RuntimeError, "caller bug", fn ->
      Decisions.result_once(fn -> raise "caller bug" end, rhs)
    end
  end

  test "lazy streams defer requests and stop when demand is satisfied" do
    Process.put(:syntax_answers, [noul(0.1), noul(0.9), noul(0.8)])
    stream = Decisions.lazy(["later", "now", "unreached"])
    refute_receive {:syntax_request, _, _}
    assert Enum.to_list(stream) == ["now"]
    assert Process.get(:syntax_answers) == [noul(0.8)]
  end

  test "comprehensions, function clauses, and weighted reductions consume scalar values" do
    Process.put(:syntax_answers, [noul(0.9), noul(0.1), choice("support"), noul(0.8), noul(0.2)])
    assert Decisions.comprehension(["now", "later"]) == ["now"]
    assert Decisions.dispatch("ticket") == :engineering
    assert_in_delta Decisions.weighted([{"first", 10}, {"second", 5}]), 9.0, 0.0001
  end

  test "reduce_while stops requesting after tagged error" do
    Process.put(:syntax_answers, [noul(0.9), {:error, :offline}, noul(0.8)])
    assert {:error, %Error{kind: :transport}} = Decisions.collect(["first", "second", "third"])
    assert Process.get(:syntax_answers) == [noul(0.8)]
  end

  test "text questions return real booleans in ordinary if expressions" do
    Process.put(:syntax_answers, [noul(0.9), noul(0.1), noul(0.5), noul(0.1)])
    assert Decisions.urgent?("ticket") == true
    assert Decisions.urgent?("ticket") == false
    assert Decisions.branch("ticket") == :escalate
    assert Decisions.branch("ticket") == :wait
  end

  test "choice expressions work directly with case and preserve declared key types" do
    Process.put(:syntax_answers, [
      choice("billing"),
      %{
        type: "choice",
        choice: "internal",
        confidence: 1,
        probabilities: %{"external" => 0, "internal" => 1}
      }
    ])

    assert Decisions.route("ticket") == :finance_queue
    assert Decisions.string_route("ticket") == :internal
  end

  test "ordered descriptions return fractional scores" do
    Process.put(:syntax_answers, [
      %{
        type: "score",
        score: 1.5,
        confidence: 0.7,
        legend: %{"0" => "Low", "1" => "Medium", "2" => "High"},
        probabilities: %{"0" => 0.0, "1" => 0.5, "2" => 0.5}
      }
    ])

    assert Decisions.impact("ticket") == 1.5
  end

  test "operands are each evaluated once and short circuiting skips requests" do
    Process.put(:syntax_answers, [noul(0.9)])

    lhs = fn ->
      send(self(), :lhs)
      "ticket"
    end

    rhs = fn ->
      send(self(), :rhs)
      "Urgent?"
    end

    assert Decisions.once(lhs, rhs)
    assert_receive :lhs
    assert_receive :rhs
    refute_receive :lhs
    refute_receive :rhs
    assert_receive {:syntax_request, _, _}
    refute Decisions.short_circuit("ticket")
    refute_receive {:syntax_request, _, _}
  end

  test "operator composes with Enum and dynamic questions" do
    Process.put(:syntax_answers, [noul(0.9), noul(0.1), noul(0.8)])
    assert Decisions.select(["urgent", "later"]) == ["urgent"]
    assert Decisions.dynamic("ticket", "Urgent?") == true
  end

  test "runtime threshold changes take effect without recompilation" do
    Process.put(:syntax_answers, [noul(0.7), noul(0.7)])
    assert Decisions.urgent?("ticket")
    Application.put_env(:jevex, :syntax, truth_threshold: 0.8)
    refute Decisions.urgent?("ticket")
  end

  test "module settings override global syntax settings" do
    Application.put_env(:jevex, :syntax, truth_threshold: 0.8)

    Application.put_env(:jevex, Decisions,
      truth_threshold: 0.6,
      client: [backend: :lolipop, api_key: "router"]
    )

    Process.put(:syntax_answers, [noul(0.7), noul(0.7)])
    assert Decisions.urgent?("ticket")
    refute OtherDecisions.urgent?("ticket")
    assert_receive {:syntax_request, _, %{backend: Jevex.Backends.Lolipop, api_key: "router"}}
    assert_receive {:syntax_request, _, %{backend: Jevex.Backends.TypeSafe, api_key: "fixture"}}
  end

  test "syntax can use an explicit runtime client struct" do
    c = Client.new!(backend: :lolipop, api_key: "router")
    Application.put_env(:jevex, :syntax, client: c)
    Process.put(:syntax_answers, [noul(0.9)])
    assert Decisions.urgent?("ticket")
    assert_receive {:syntax_request, _, %{backend: Jevex.Backends.Lolipop}}
  end

  test "connection errors raise rather than evaluating as false" do
    Process.put(:syntax_answers, [{:error, :offline}])
    error = assert_raise Error, fn -> Decisions.branch("ticket") end
    assert error.kind == :transport
  end

  test "configured connection fallback returns the backup scalar" do
    backup = Client.new!(backend: :lolipop, api_key: "backup")
    Application.put_env(:jevex, :syntax, on_error: backup)
    Process.put(:syntax_answers, [{:error, :offline}, noul(0.9)])
    assert Decisions.urgent?("ticket")
    assert_receive {:syntax_request, _, %{backend: Jevex.Backends.TypeSafe}}
    assert_receive {:syntax_request, _, %{backend: Jevex.Backends.Lolipop}}
  end

  test "backend keyword fallback resolves credentials at runtime" do
    Application.put_env(:jevex, :syntax, on_error: [backend: :lolipop, api_key: "backup"])
    Process.put(:syntax_answers, [{:error, :offline}, noul(0.1)])
    refute Decisions.urgent?("ticket")
    assert_receive {:syntax_request, _, %{backend: Jevex.Backends.Lolipop, api_key: "backup"}}
  end

  test "backend atom fallback uses its own provider key variable" do
    name = "LOLIPOP_AI_GATEWAY_API_KEY"
    original = System.get_env(name)

    on_exit(fn ->
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end)

    System.put_env(name, "backup-env")
    Application.put_env(:jevex, :syntax, on_error: :lolipop)
    Process.put(:syntax_answers, [{:error, :offline}, noul(0.9)])
    assert Decisions.urgent?("ticket")
    assert_receive {:syntax_request, _, %{api_key: {:system, ^name}}}
  end

  test "Noul certainty is separate from boolean truth threshold" do
    Application.put_env(:jevex, :syntax, min_noul_certainty: 0.9)
    Process.put(:syntax_answers, [noul(0.05), noul(0.6)])
    refute Decisions.urgent?("ticket")
    error = assert_raise Error, fn -> Decisions.urgent?("ticket") end
    assert error.kind == :low_confidence
  end

  test "low-confidence fallback obeys the same thresholds and does not loop" do
    Application.put_env(:jevex, :syntax,
      min_confidence: 0.8,
      on_low_confidence: [backend: :lolipop, api_key: "backup"]
    )

    Process.put(:syntax_answers, [choice("billing", 0.4), choice("billing", 0.95)])
    assert Decisions.route("ticket") == :finance_queue
    Process.put(:syntax_answers, [choice("billing", 0.4), choice("billing", 0.5)])
    error = assert_raise Error, fn -> Decisions.route("ticket") end
    assert error.kind == :low_confidence
    assert Process.get(:syntax_answers) == []
  end

  test "unknown returned choices cannot become atoms" do
    Process.put(:syntax_answers, [
      %{
        type: "choice",
        choice: "untrusted_external_value",
        confidence: 1,
        probabilities: %{"billing" => 1, "support" => 0}
      }
    ])

    error = assert_raise Error, fn -> Decisions.route("ticket") end
    assert error.kind == :response
  end

  test "invalid dynamic expressions and settings fail before network I/O" do
    for expression <- [
          nil,
          12,
          {"Which?", []},
          {"Which?", %{"a" => nil, a: nil}},
          {"Which?", [a: nil, a: nil]},
          {"Which?", %{nil => "None"}},
          {"Which?", %{true => "Yes", false => "No"}},
          {"Score?", ["one"]}
        ] do
      assert_raise Error, fn -> Decisions.dynamic("ticket", expression) end
    end

    for config <- [
          [truth_threshold: 1.1],
          [truth_threshold: :bad],
          [unknown: true],
          [min_confidence: 2],
          [on_error: :unknown],
          :bad
        ] do
      Application.put_env(:jevex, :syntax, config)
      assert_raise Error, fn -> Decisions.urgent?("ticket") end
    end

    refute_receive {:syntax_request, _, _}
  end

  test "invalid literal expressions are rejected before they can be called" do
    for {name, expression} <- [
          {"EmptyChoice", ~s|{"Which?", %{}}|},
          {"DuplicateChoice", ~s|{"Which?", %{a: "First", a: "Second"}}|},
          {"KeyCollision", ~s|{"Which?", %{"a" => "First", a: "Second"}}|},
          {"InvalidScore", ~s|{"Score?", ["Only"]}|},
          {"NilChoice", ~s|{"Which?", %{nil => "None"}}|}
        ] do
      source =
        "defmodule Jevex.SyntaxTest.Bad#{name} do\nuse Jevex\ndef run(state), do: state ~> #{expression}\nend"

      assert_raise CompileError, fn -> Code.compile_string(source) end
    end
  end

  test "dynamic question construction is not executed by macro expansion" do
    source = """
    defmodule Jevex.SyntaxTest.DeferredQuestion do
      use Jevex
      def run(state), do: state ~> question()
      defp question do
        send(self(), :built_question)
        "Urgent?"
      end
    end
    """

    [{module, _}] = Code.compile_string(source)
    refute_receive :built_question
    Process.put(:syntax_answers, [noul(0.9)])
    assert module.run("ticket")
    assert_receive :built_question
    refute_receive :built_question
  end

  test "fallback callbacks receive a typed response and their result remains validated" do
    callback = fn %{reason: :low_confidence, questions: %{"decision" => _}} ->
      {:ok,
       %Jevex.Response{
         model: "local",
         usage: nil,
         answers: %{"decision" => %Jevex.Answer.Noul{noul: 0.95}}
       }}
    end

    Application.put_env(:jevex, :syntax, min_noul_certainty: 0.9, on_low_confidence: callback)
    Process.put(:syntax_answers, [noul(0.5)])
    assert Decisions.urgent?("ticket")
    assert_receive {:syntax_request, _, _}
    refute_receive {:syntax_request, _, _}
  end

  test "syntax cannot perform inference at compile time, in guards, or patterns" do
    for operator <- ["~>", "~>>"],
        {name, body} <- [
          {"ModuleLevel", ~s("state" ~> "Question?")},
          {"Guard", ~s|def f(x) when x ~> "Question?", do: x|},
          {"Pattern", ~s|def f(x ~> "Question?"), do: x|}
        ] do
      body = String.replace(body, "~>", operator)
      suffix = if operator == "~>", do: "Scalar", else: "Tagged"
      source = "defmodule Jevex.SyntaxTest.Invalid#{name}#{suffix} do\nuse Jevex\n#{body}\nend"
      assert_raise CompileError, fn -> Code.compile_string(source) end
    end

    assert_raise CompileError, fn ->
      Code.compile_string(
        "defmodule Jevex.SyntaxTest.InvalidUse do\nuse Jevex, backend: :typesafe\nend"
      )
    end
  end
end
