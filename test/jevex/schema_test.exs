defmodule Jevex.SchemaTest do
  use ExUnit.Case, async: true

  defmodule Ticket do
    use Jevex.Schema
    noul(:urgent, "Requires immediate action?")
    choice(:department, "Responsible team?", %{billing: "Invoices", support: "Technical"})
    score(:severity, "Severity?", ["Low", "High"])
  end

  defmodule MixedChoice do
    use Jevex.Schema
    choice(:team, "Who?", %{"external" => "Vendor", internal: "Us"})
  end

  defmodule WithCriteria do
    use Jevex.Schema
    noul(:urgent, %{instruction: "Urgent?"}, %{true: "Now", false: "Later"})
  end

  test "declarations produce low-level questions and a struct with required fields" do
    assert %{
             "urgent" => %Jevex.Question{type: :noul},
             "department" => %Jevex.Question{
               criteria: %{"billing" => "Invoices", "support" => "Technical"}
             },
             "severity" => %Jevex.Question{criteria: ["Low", "High"]}
           } = Ticket.questions()

    assert Map.keys(struct(Ticket)) |> Enum.sort() == [
             :__struct__,
             :department,
             :severity,
             :urgent
           ]

    assert_raise ArgumentError, fn -> struct!(Ticket, urgent: nil) end
  end

  test "literal structured instructions and noul criteria retain native semantics" do
    assert %Jevex.Question{
             instructions: %{"instruction" => "Urgent?"},
             criteria: %{"true" => "Now", "false" => "Later"}
           } =
             WithCriteria.questions()["urgent"]

    assert MixedChoice.questions()["team"].criteria == %{
             "external" => "Vendor",
             "internal" => "Us"
           }
  end

  for {label, body, message} <- [
        {:empty, "", "at least one question"},
        {:duplicate, ~s(noul :x, "X"\nnoul :x, "Y"), "duplicate"},
        {:reserved, ~s(noul :__struct__, "X"), "non-reserved"},
        {:string_name, ~s(noul "x", "X"), "non-reserved"},
        {:empty_choice, ~s(choice :x, "X", %{}), "at least one option"},
        {:one_score, ~s(score :x, "X", ["Only"]), "score requires 2 to 10 levels"},
        {:colliding, ~s(choice :x, "X", %{"yes" => "B", yes: "A"}), "collide"},
        {:duplicate_choice, ~s(choice :x, "X", %{yes: "A", yes: "B"}), "duplicate keys"},
        {:bad_key, ~s(choice :x, "X", %{1 => "A"}), "atoms or strings"},
        {:computed, ~s|noul :x, String.upcase("X")|, "literals only"},
        {:attribute, ~s(@question "X"\nnoul :x, @question), "literals only"}
      ] do
    test "rejects #{label} during compilation" do
      module = Module.concat(__MODULE__, unquote(label))
      source = "defmodule #{inspect(module)} do\nuse Jevex.Schema\n#{unquote(body)}\nend"
      assert_raise CompileError, ~r/#{unquote(message)}/, fn -> Code.compile_string(source) end
    end
  end

  test "rejected expressions are never evaluated" do
    refute Process.get(:jevex_schema_injected)

    assert_raise CompileError, ~r/literals only/, fn ->
      Code.compile_string("""
      defmodule Jevex.SchemaTest.UntrustedExpression do
        use Jevex.Schema
        noul :x, Process.put(:jevex_schema_injected, true)
      end
      """)
    end

    refute Process.get(:jevex_schema_injected)
  end

  defmodule Transport do
    @behaviour Jevex.Transport
    def request(request, _client) do
      send(self(), {:schema_request, Jason.decode!(request.body)})

      case Process.get(:schema_response) do
        [next | rest] ->
          Process.put(:schema_response, rest)
          next

        result ->
          result
      end
    end
  end

  test "evaluation maps declared atom choices and preserves probability keys" do
    client = client()
    Process.put(:schema_response, response(ticket_answers()))
    assert {:ok, %Ticket{} = ticket} = Ticket.evaluate(client, %{text: "Invoice overdue"})
    assert ticket.urgent == %Jevex.Answer.Noul{noul: 0.9}
    assert ticket.department.choice == :billing
    assert ticket.department.probabilities == %{"billing" => 0.8, "support" => 0.2}
    assert ticket.severity.score == 0.75
    assert_receive {:schema_request, %{"questions" => questions}}
    assert Map.keys(questions) |> Enum.sort() == ["department", "severity", "urgent"]
    assert %Ticket{} = Ticket.evaluate!(client, "Invoice overdue")
  end

  test "string choices remain strings, including in a mixed-key schema" do
    answer = %{
      "type" => "choice",
      "choice" => "external",
      "probabilities" => %{"external" => 0.9, "internal" => 0.1},
      "confidence" => 0.9
    }

    Process.put(:schema_response, response(%{"team" => answer}))

    assert {:ok, %MixedChoice{team: %Jevex.Answer.Choice{choice: "external"}}} =
             MixedChoice.evaluate(client(), "Vendor issue")
  end

  test "undeclared response choices are rejected before schema conversion without creating atoms" do
    unknown = "jevex_unknown_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
    answers = put_in(ticket_answers(), ["department", "choice"], unknown)
    Process.put(:schema_response, response(answers))
    assert {:error, %Jevex.Error{}} = Ticket.evaluate(client(), "Invoice")
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown) end
  end

  test "transport errors pass through and bang evaluation raises the typed error" do
    Process.put(
      :schema_response,
      {:error, %Jevex.Error{kind: :transport, message: "unavailable"}}
    )

    assert {:error, %Jevex.Error{kind: :transport}} = Ticket.evaluate(client(), "Invoice")
    assert_raise Jevex.Error, fn -> Ticket.evaluate!(client(), "Invoice") end
  end

  test "schema forwards error fallback options and returns a typed backup result" do
    Process.put(:schema_response, [
      {:error, :unavailable},
      response(ticket_answers())
    ])

    assert {:ok, %Ticket{department: %Jevex.Answer.Choice{choice: :billing}}} =
             Ticket.evaluate(client(), "Invoice", on_error: client())

    assert_receive {:schema_request, _}
    assert_receive {:schema_request, _}
  end

  test "schema fallback callbacks receive dynamic questions and return typed responses" do
    Process.put(:schema_response, {:error, :unavailable})

    handler = fn context ->
      assert context.reason == :error
      assert context.state == "Invoice"
      assert context.response == nil
      assert %Jevex.Error{} = context.error
      assert %Jevex.Client{} = context.client
      assert Map.has_key?(context.questions, "department")
      {:ok, wire} = response(ticket_answers())
      Jevex.Response.decode(wire.body, context.questions)
    end

    assert {:ok, %Ticket{department: %Jevex.Answer.Choice{choice: :billing}}} =
             Ticket.evaluate(client(), "Invoice", on_error: handler)

    assert_receive {:schema_request, _}
    refute_received {:schema_request, _}
  end

  test "schema forwards confidence gates and confidence fallback options" do
    low = put_in(ticket_answers(), ["department", "confidence"], 0.2)
    Process.put(:schema_response, [response(low), response(ticket_answers())])

    assert %Ticket{department: %Jevex.Answer.Choice{confidence: 0.8}} =
             Ticket.evaluate!(client(), "Invoice",
               min_confidence: 0.7,
               on_low_confidence: client()
             )

    assert_receive {:schema_request, _}
    assert_receive {:schema_request, _}

    Process.put(:schema_response, response(low))

    assert {:error, %Jevex.Error{kind: :low_confidence}} =
             Ticket.evaluate(client(), "Invoice", min_confidence: 0.7)
  end

  test "the generated type includes exact atom choice alternatives" do
    [{_, beam}] =
      Code.compile_string("""
      defmodule Jevex.SchemaTest.TypeInspection do
        @compile :debug_info
        use Jevex.Schema
        choice :team, "Team?", %{billing: "Invoices", support: "Technical"}
      end
      """)

    assert {:ok, types} = Code.Typespec.fetch_types(beam)
    {:type, declaration} = Enum.find(types, fn {_, {name, _, _}} -> name == :t end)
    rendered = declaration |> Code.Typespec.type_to_quoted() |> Macro.to_string()
    assert rendered =~ "Jevex.Answer.Choice.t(:billing | :support)"
  end

  defp client,
    do:
      Jevex.Client.new!(
        backend: :lolipop,
        api_key: "test-key",
        transport: Transport,
        max_retries: 0
      )

  defp response(answers),
    do:
      {:ok,
       %{
         status: 200,
         headers: %{},
         body:
           Jason.encode!(%{
             "model" => "jev",
             "answers" => answers,
             "usage" => %{"input_tokens" => 1, "output_tokens" => 2}
           })
       }}

  defp ticket_answers do
    %{
      "urgent" => %{"type" => "noul", "noul" => 0.9},
      "department" => %{
        "type" => "choice",
        "choice" => "billing",
        "probabilities" => %{"billing" => 0.8, "support" => 0.2},
        "confidence" => 0.8
      },
      "severity" => %{
        "type" => "score",
        "score" => 0.75,
        "legend" => %{"0" => "Low", "1" => "High"},
        "probabilities" => %{"0" => 0.25, "1" => 0.75},
        "confidence" => 0.75
      }
    }
  end
end
