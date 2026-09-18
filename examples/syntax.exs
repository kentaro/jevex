# Offline: mix run examples/syntax.exs
# TypeSafe: mix run examples/syntax.exs --live (requires TYPESAFE_API_KEY)
# Lolipop: mix run examples/syntax.exs --live --lolipop
#          (requires LOLIPOP_AI_GATEWAY_API_KEY)
# Offline mode demonstrates many forms. Live mode only runs assess/1: four
# primary evaluations on success, with retries and fallback disabled here.

defmodule Jevex.Example.SyntaxDecisions do
  use Jevex

  def queues(tickets) do
    tickets
    |> Enum.filter(&(&1 ~> "Does this need attention?"))
    |> Enum.group_by(&(&1 ~> {"Which team?", billing: "Payments", support: "Technical"}))
  end

  def probabilities(tickets) do
    Enum.map(tickets, fn ticket -> {ticket.id, ticket ~> {:noul, "Is this urgent?"}} end)
  end

  def ranked(tickets) do
    Enum.sort_by(tickets, &(&1 ~> {"How severe?", ["Low", "Medium", "High"]}), :desc)
  end

  def assignments(tickets) do
    for ticket <- tickets,
        ticket ~> "Does this need attention?" do
      {ticket.id, ticket ~> {"Which team?", billing: "Payments", support: "Technical"}}
    end
  end

  def first_urgent(tickets) do
    tickets
    |> Stream.filter(&(&1 ~> "Does this need attention?"))
    |> Enum.take(1)
  end

  def total_probability(tickets) do
    Enum.reduce(tickets, 0.0, fn ticket, sum ->
      sum + (ticket ~> {:noul, "Is this urgent?"})
    end)
  end

  def priority(ticket) do
    probability = ticket ~> {:noul, "Is this urgent?"}

    cond do
      probability >= 0.9 -> :high
      probability <= 0.1 -> :low
      true -> :review
    end
  end

  def route(ticket) do
    team = ticket ~> {"Which team?", billing: "Payments", support: "Technical"}
    dispatch(team, ticket)
  end

  defp dispatch(:billing, ticket), do: {:billing_queue, ticket.id}
  defp dispatch(:support, ticket), do: {:support_queue, ticket.id}

  def urgency_band(ticket) do
    probability = ticket ~> {:noul, "Is this urgent?"}
    band(probability)
  end

  defp band(probability) when probability >= 0.9, do: :high
  defp band(probability) when probability <= 0.1, do: :low
  defp band(_probability), do: :review

  def action(ticket) do
    if ticket != nil and ticket ~> "Does this need attention?" do
      case ticket ~> {"Which team?", billing: "Payments", support: "Technical"} do
        :billing -> :billing_queue
        :support -> :support_queue
      end
    else
      :no_action
    end
  end

  def assess(ticket) do
    with {:ok, attention?} <- ticket ~>> "Does this need attention?",
         {:ok, probability} <- ticket ~>> {:noul, "Is this urgent?"},
         {:ok, team} <- ticket ~>> {"Which team?", billing: "Payments", support: "Technical"},
         {:ok, severity} <- ticket ~>> {"How severe?", ["Low", "Medium", "High"]} do
      {:ok, %{attention?: attention?, urgency: probability, team: team, severity: severity}}
    end
  end

  def teams_until_error(tickets) do
    result =
      Enum.reduce_while(tickets, {:ok, []}, fn ticket, {:ok, acc} ->
        case ticket ~>> {"Which team?", billing: "Payments", support: "Technical"} do
          {:ok, team} -> {:cont, {:ok, [{ticket.id, team} | acc]}}
          {:error, error} -> {:halt, {:error, error}}
        end
      end)

    case result do
      {:ok, assignments} -> {:ok, Enum.reverse(assignments)}
      error -> error
    end
  end

  def concurrent_scores(tickets) do
    tickets
    |> Task.async_stream(
      fn ticket -> ticket ~>> {"How severe?", ["Low", "Medium", "High"]} end,
      max_concurrency: 2,
      timeout: 60_000,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, {:ok, score}} -> {:ok, score}
      {:ok, {:error, %Jevex.Error{} = error}} -> {:error, error}
      {:exit, reason} -> {:task_exit, reason}
    end)
  end
end

defmodule Jevex.Example.SyntaxFixtureTransport do
  @behaviour Jevex.Transport

  @impl true
  def request(request, _client) do
    Agent.update(__MODULE__, &(&1 + 1))
    sent = Jason.decode!(request.body)
    state = sent["state"]
    answers = Map.new(sent["questions"], fn {id, question} -> {id, answer(question, state)} end)

    body = %{
      "model" => sent["model"],
      "answers" => answers,
      "usage" => %{"input_tokens" => 10, "output_tokens" => 3}
    }

    {:ok, %{status: 200, headers: %{}, body: Jason.encode!(body)}}
  end

  # Fixture answers depend only on the known example IDs; this is not inference.
  defp answer(%{"type" => "noul"}, %{"id" => id}) do
    %{"type" => "noul", "noul" => Map.fetch!(%{1 => 0.95, 2 => 0.1, 3 => 0.8}, id)}
  end

  defp answer(%{"type" => "choice", "criteria" => options}, %{"id" => id}) do
    selected = if id == 1, do: "billing", else: "support"

    probabilities =
      Map.new(options, fn {key, _} -> {key, if(key == selected, do: 1, else: 0)} end)

    %{
      "type" => "choice",
      "choice" => selected,
      "probabilities" => probabilities,
      "confidence" => 0.95
    }
  end

  defp answer(%{"type" => "score", "criteria" => levels}, %{"id" => id}) do
    score = Map.fetch!(%{1 => 1, 2 => 0, 3 => 2}, id)

    legend =
      levels |> Enum.with_index() |> Map.new(fn {text, i} -> {Integer.to_string(i), text} end)

    probabilities =
      Map.new(0..(length(levels) - 1), fn i ->
        {Integer.to_string(i), if(i == score, do: 1, else: 0)}
      end)

    %{
      "type" => "score",
      "score" => score,
      "legend" => legend,
      "probabilities" => probabilities,
      "confidence" => 0.95
    }
  end
end

defmodule Jevex.Example.SyntaxRunner do
  alias Jevex.Example.{SyntaxDecisions, SyntaxFixtureTransport}

  def run(args) do
    {mode, client_options} =
      case args do
        [] ->
          {:ok, _counter} = Agent.start_link(fn -> 0 end, name: SyntaxFixtureTransport)
          IO.puts("Offline collection tour: deterministic fixtures, no network requests.")

          {:offline,
           [backend: :typesafe, api_key: "fixture-only", transport: SyntaxFixtureTransport]}

        ["--live"] ->
          IO.puts(
            "Compact assessment: up to four real evaluations through the official TypeSafe API."
          )

          {:live, [backend: :typesafe, api_key: {:system, "TYPESAFE_API_KEY"}]}

        ["--live", "--lolipop"] ->
          IO.puts("Compact assessment: up to four real evaluations through Lolipop AI Gateway.")
          {:live, [backend: :lolipop, api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"}]}

        _ ->
          IO.puts(:stderr, "Usage: mix run examples/syntax.exs [--live [--lolipop]]")
          System.halt(2)
      end

    Application.put_env(:jevex, :client, Keyword.put(client_options, :max_retries, 0))
    Application.put_env(:jevex, :syntax, truth_threshold: 0.5, min_confidence: 0.8)

    tickets = [
      %{id: 1, subject: "Invoice charged twice"},
      %{id: 2, subject: "Thanks for your help"},
      %{id: 3, subject: "Checkout is down"}
    ]

    case mode do
      :offline -> tour(tickets)
      :live -> show_assessment(List.last(tickets))
    end
  rescue
    error in Jevex.Error -> fail(error)
  end

  defp tour(tickets) do
    IO.inspect(SyntaxDecisions.queues(tickets), label: "Pipeline, captures, group_by")
    IO.inspect(SyntaxDecisions.probabilities(tickets), label: "Raw Noul map")
    IO.inspect(SyntaxDecisions.ranked(tickets) |> Enum.map(& &1.id), label: "Score sort_by")
    IO.inspect(SyntaxDecisions.assignments(tickets), label: "Comprehension")

    IO.inspect(SyntaxDecisions.first_urgent(tickets) |> Enum.map(& &1.id),
      label: "Lazy stream, take(1)"
    )

    IO.inspect(SyntaxDecisions.total_probability(tickets), label: "Noul reduce")
    IO.inspect(SyntaxDecisions.priority(hd(tickets)), label: "One Noul, cond")
    IO.inspect(SyntaxDecisions.route(hd(tickets)), label: "Choice function clauses")
    IO.inspect(SyntaxDecisions.urgency_band(hd(tickets)), label: "Compute Noul before guards")
    IO.inspect(SyntaxDecisions.action(nil), label: "Short-circuit, zero evaluations")
    IO.inspect(SyntaxDecisions.action(hd(tickets)), label: "if and case")
    show_assessment(hd(tickets))
    IO.inspect(SyntaxDecisions.teams_until_error(tickets), label: "Tagged reduce_while")
    IO.inspect(SyntaxDecisions.concurrent_scores(tickets), label: "Bounded async_stream")
    IO.puts("Total fixture evaluations: #{Agent.get(SyntaxFixtureTransport, & &1)}")
  end

  defp show_assessment(ticket) do
    case SyntaxDecisions.assess(ticket) do
      {:ok, result} -> IO.inspect(result, label: "Tagged with: boolean, Noul, Choice, Score")
      {:error, error} -> fail(error)
    end
  end

  defp fail(error) do
    IO.puts(:stderr, "Evaluation failed (#{error.kind}): #{error.message}")
    System.halt(1)
  end
end

Jevex.Example.SyntaxRunner.run(System.argv())
