defmodule Jevex.SyntaxLiveTest do
  use ExUnit.Case, async: false
  @moduletag :live

  defmodule Decisions do
    use Jevex
    def probability(state), do: state ~>> {:noul, "Does this need immediate attention?"}
    def urgent?(state), do: state ~> "Does this need immediate attention?"

    def team(state),
      do:
        state
        ~> {"Which team should handle this?", billing: "Invoices", technical: "Service outages"}

    def impact(state),
      do:
        state
        ~> {"How severe is this issue?",
         ["Cosmetic", "Workaround available", "Service unavailable"]}
  end

  test "the three expression forms return validated scalars through real Lolipop inference" do
    keys = [:syntax, Decisions]
    saved = Map.new(keys, &{&1, Application.fetch_env(:jevex, &1)})

    on_exit(fn ->
      for {key, prior} <- saved do
        case prior do
          {:ok, value} -> Application.put_env(:jevex, key, value)
          :error -> Application.delete_env(:jevex, key)
        end
      end
    end)

    Application.delete_env(:jevex, :syntax)

    client =
      Jevex.Client.new!(
        backend: :lolipop,
        api_key: System.fetch_env!("LOLIPOP_AI_GATEWAY_API_KEY"),
        max_retries: 0
      )

    Application.put_env(:jevex, Decisions, client: client)
    state = "Checkout is unavailable for every customer. Please fix it immediately."

    assert is_boolean(Decisions.urgent?(state))
    assert {:ok, p} = Decisions.probability(state)
    assert is_number(p) and p >= 0 and p <= 1
    assert Decisions.team(state) in [:billing, :technical]
    score = Decisions.impact(state)
    assert is_number(score) and score >= 0 and score <= 2
  end
end
