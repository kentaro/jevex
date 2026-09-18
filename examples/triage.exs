# Run with `mix run examples/triage.exs` for a deterministic offline demonstration.
# Add `--live` for the official Jev API; set TYPESAFE_API_KEY first.
# Add `--live --lolipop` for a router example; set LOLIPOP_AI_GATEWAY_API_KEY.

defmodule Jevex.Example.Triage do
  use Jevex.Schema

  noul(:urgent, "Does this ticket require immediate action?")

  choice(:department, "Which team should handle this ticket?", %{
    billing: "Invoices, charges, and payments",
    support: "Technical problems and outages"
  })

  score(:severity, "How severe is the problem?", [
    "Minor inconvenience",
    "Important functionality impaired",
    "Service unavailable"
  ])
end

defmodule Jevex.Example.FixtureTransport do
  @behaviour Jevex.Transport

  @impl true
  def request(request, _client) do
    sent = Jason.decode!(request.body)

    body = %{
      "model" => sent["model"],
      "answers" => %{
        "urgent" => %{"type" => "noul", "noul" => 0.95},
        "department" => %{
          "type" => "choice",
          "choice" => "support",
          "probabilities" => %{"billing" => 0.05, "support" => 0.95},
          "confidence" => 0.95
        },
        "severity" => %{
          "type" => "score",
          "score" => 1.8,
          "legend" => %{
            "0" => "Minor inconvenience",
            "1" => "Important functionality impaired",
            "2" => "Service unavailable"
          },
          "probabilities" => %{"0" => 0.05, "1" => 0.1, "2" => 0.85},
          "confidence" => 0.85
        }
      },
      "usage" => %{"input_tokens" => 12, "output_tokens" => 24}
    }

    {:ok, %{status: 200, headers: %{}, body: Jason.encode!(body)}}
  end
end

defmodule Jevex.Example.Runner do
  alias Jevex.Example.Triage

  def run(args) do
    opts =
      case args do
        [] ->
          IO.puts("Offline fixture response; no network request will be made.")
          [backend: :typesafe, api_key: "fixture-only", transport: Jevex.Example.FixtureTransport]

        ["--live"] ->
          IO.puts("Making one real request to the official Jev API.")
          [backend: :typesafe, api_key: {:system, "TYPESAFE_API_KEY"}]

        ["--live", "--lolipop"] ->
          IO.puts("Making one real request to Lolipop AI Gateway.")
          [backend: :lolipop, api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"}]

        _ ->
          IO.puts(:stderr, "Usage: mix run examples/triage.exs [--live [--lolipop]]")
          System.halt(2)
      end

    state = %{subject: "Checkout is down", body: "Nobody can complete a purchase."}

    with {:ok, client} <- Jevex.Client.new(Keyword.put(opts, :max_retries, 0)),
         {:ok, %Triage{} = result} <- Triage.evaluate(client, state) do
      IO.inspect(result, label: "Typed result")

      case result do
        %Triage{
          urgent: %Jevex.Answer.Noul{noul: probability},
          department: %Jevex.Answer.Choice{choice: :support}
        }
        when probability >= 0.8 ->
          IO.puts("Suggested action: escalate to support (severity #{result.severity.score}).")

        %Triage{department: %Jevex.Answer.Choice{choice: team}} ->
          IO.puts("Suggested action: route to #{team}.")
      end
    else
      {:error, %Jevex.Error{kind: kind, message: message}} ->
        IO.puts(:stderr, "Evaluation failed (#{kind}): #{message}")
        System.halt(1)
    end
  end
end

Jevex.Example.Runner.run(System.argv())
