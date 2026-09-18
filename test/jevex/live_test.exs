defmodule Jevex.LiveTest do
  use ExUnit.Case, async: false
  @moduletag :live

  defmodule Triage do
    use Jevex.Schema
    noul(:urgent, "Does this need immediate attention?")

    choice(:department, "Which team should handle this?", %{
      billing: "Payments and invoices",
      technical: "Service outages and bugs"
    })

    score(:severity, "How severe is this issue?", [
      "Cosmetic",
      "Workaround available",
      "Service unavailable"
    ])
  end

  defmodule FailedTransport do
    @behaviour Jevex.Transport
    def request(_, _), do: {:error, :simulated_connection_failure}
  end

  defmodule UncertainTransport do
    @behaviour Jevex.Transport
    def request(_, _) do
      {:ok,
       %{
         status: 200,
         headers: %{},
         body:
           Jason.encode!(%{
             model: "synthetic-fixture",
             usage: %{input_tokens: 0, output_tokens: 0},
             answers: %{urgent: %{type: "noul", noul: 0.5}}
           })
       }}
    end
  end

  setup do
    key = System.fetch_env!("LOLIPOP_AI_GATEWAY_API_KEY")
    {:ok, live: Jevex.Client.new!(backend: :lolipop, api_key: key, max_retries: 0)}
  end

  test "three primitive types through the real Lolipop API and schema", %{live: live} do
    assert {:ok, %Triage{} = answer} =
             Triage.evaluate(
               live,
               "Checkout is unavailable for every customer. Fix it immediately."
             )

    assert answer.department.choice in [:billing, :technical]
    assert is_number(answer.urgent.noul)
    assert is_number(answer.severity.score)
  end

  test "connection failure falls back to the real Lolipop backend", %{live: live} do
    primary = Jevex.Client.new!(api_key: "synthetic", transport: FailedTransport)

    assert {:ok, %Jevex.Response{model: model}} =
             Jevex.evaluate(
               primary,
               "This service is down. Please fix it now.",
               %{urgent: Jevex.Question.noul!("Does this need immediate attention?")},
               on_error: live
             )

    assert is_binary(model)
  end

  test "uncertain fixture falls back to real Lolipop inference", %{live: live} do
    primary = Jevex.Client.new!(api_key: "synthetic", transport: UncertainTransport)

    result =
      Jevex.evaluate(
        primary,
        "Production is down for every customer. Fix it immediately.",
        %{urgent: Jevex.Question.noul!("Does this need immediate attention?")},
        min_noul_certainty: 0.51,
        on_low_confidence: live
      )

    assert {:ok, %Jevex.Response{model: model}} = result
    refute model == "synthetic-fixture"
  end
end
