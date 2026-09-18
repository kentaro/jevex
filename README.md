# Jevex

Jev inference that composes with ordinary Elixir. `use Jevex` adds two operators:
`~>` returns a decision value, and `~>>` returns a tagged result for `with`, `case`,
and explicit recovery. Noul, Choice, and Score work in pipelines, captures,
comprehensions, streams, and function-clause dispatch. No schema is required.

```elixir
defmodule Tickets do
  use Jevex

  def queues(tickets) do
    tickets
    |> Enum.filter(&(&1 ~> "Does this need attention?"))
    |> Enum.group_by(&(&1 ~> {"Which team?", billing: "Payments", support: "Technical"}))
  end

  def most_severe_first(tickets) do
    Enum.sort_by(tickets, &(&1 ~> {"How severe?", ["Low", "Medium", "High"]}), :desc)
  end

  def urgency_probabilities(tickets) do
    Enum.map(tickets, fn ticket -> {ticket, ticket ~> {:noul, "Is this urgent?"}} end)
  end

  def route(ticket) do
    team = ticket ~> {"Which team?", billing: "Payments", support: "Technical"}
    dispatch(team, ticket)
  end

  defp dispatch(:billing, ticket), do: {:billing_queue, ticket}
  defp dispatch(:support, ticket), do: {:support_queue, ticket}

  def assess(ticket) do
    with {:ok, probability} <- ticket ~>> {:noul, "Is this urgent?"},
         {:ok, severity} <- ticket ~>> {"How severe?", ["Low", "Medium", "High"]} do
      {:ok, %{urgency: probability, severity: severity}}
    end
  end
end
```

Start with the official TypeSafe Jev API. Routers, including Lolipop AI Gateway,
use the same expressions with different runtime configuration.

## Installation and the official API

Supports Elixir 1.17 through 1.20 with an OTP version supported by the selected
Elixir release. Local verification uses Elixir 1.20.2 / OTP 29. CI is configured
for Elixir 1.17 / OTP 27 and Elixir 1.20 / OTP 29; those remote CI jobs have not
been run as part of this delivery.

Jevex is packaged for Hex as `:jevex`. **Version 0.1.0 has not yet been published**;
the registry dependency below is the installation form to use after publication,
not a claim that `mix deps.get` can fetch this unreleased version today:

```elixir
defp deps do
  [{:jevex, "~> 0.1.0"}]
end
```

For local development before publication, use the source checkout instead:

```elixir
defp deps do
  [{:jevex, path: "../jevex"}]
end
```

Adjust the local path and run `mix deps.get`. See [publishing](guides/publishing.md)
for the Hex package and release workflow.

Set `TYPESAFE_API_KEY` in the process environment and configure `config/runtime.exs`:

```elixir
import Config

config :jevex, :client,
  backend: :typesafe,
  api_key: {:system, "TYPESAFE_API_KEY"}
```

Call your ordinary functions, such as `Tickets.queues(tickets)` or
`Tickets.assess(ticket)`. Client configuration is read at runtime; no inference
occurs when compiling a module or importing the operators.

## Noul, Choice, and Score

| Question expression | `~>` returns | `~>>` returns on success |
| --- | --- | --- |
| `"Does this need attention?"` | Boolean, using `truth_threshold` | `{:ok, boolean}` |
| `{:noul, "Is this urgent?"}` | Raw yes probability in 0..1 | `{:ok, probability}` |
| `{"Which team?", billing: "Payments", support: "Technical"}` | Declared atom, such as `:billing` | `{:ok, :billing}` |
| `{"Which language?", %{"en" => "English", "fr" => "French"}}` | Declared string, such as `"en"` | `{:ok, "en"}` |
| `{"How severe?", ["Low", "Medium", "High"]}` | Number in 0..2, possibly fractional | `{:ok, score}` |

The string form converts the underlying noul probability with
`p >= truth_threshold` (default 0.5). `{:noul, question}` preserves the probability
and ignores that conversion threshold; configured certainty gates still apply.
Scores span zero through the final rubric index, not a universal 0..1 scale.

`~>` raises `Jevex.Error` on evaluation failure. `~>>` returns
`{:error, %Jevex.Error{}}`. An inference failure never becomes a successful-looking
`false`, zero, or arbitrary choice.

## Ordinary control flow and explicit request counts

`if` and `case` work alongside the collection examples above:

```elixir
defmodule Attention do
  use Jevex

  def action(ticket) do
    if ticket ~> "Does this need attention?" do
      case ticket ~> {"Which team?", billing: "Payments", support: "Technical"} do
        :billing -> :billing_queue
        :support -> :support_queue
      end
    else
      :no_action
    end
  end
end
```

Each reached operator expression performs one single-question evaluation. Retries
and fallback may add HTTP requests. Both operands are evaluated exactly once;
ordinary branching and short-circuiting decide which expressions are reached.
There is no implicit batching, caching, or parallelism.

For `n` tickets, `Tickets.queues/1` evaluates `n` boolean questions plus one choice
for each retained ticket. `Enum.sort_by/3` evaluates each score once per element;
avoid inference inside a sorting comparator, which runs repeatedly. Streams defer
requests until consumed, and bounded concurrency must be requested explicitly.
The [syntax guide](guides/syntax.md) covers `for`, `Stream`, `reduce`, `cond`,
`with`, function clauses, and `Task.async_stream/3` with their evaluation costs.

## Routers

Jevex supports Lolipop AI Gateway, OpenRouter, Cloudflare Workers AI, Vercel AI
Gateway, and custom native endpoints. For **Lolipop AI Gateway**, provide
`LOLIPOP_AI_GATEWAY_API_KEY` and replace the client configuration:

```elixir
config :jevex, :client,
  backend: :lolipop,
  api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"}
```

The expression code stays the same. Adapters use each provider's evaluation
protocol rather than generic Chat Completions. See [backend configuration](guides/backends.md)
and [protocol contracts](guides/backend-contracts.md) for endpoints, models,
authentication, and alpha/experimental limitations.

## Confidence and fallback

Keep syntax policy separate from connection settings:

```elixir
config :jevex, :syntax,
  truth_threshold: 0.5,
  min_confidence: 0.8,
  min_noul_certainty: 0.9,
  on_error: :lolipop,
  on_low_confidence: :lolipop

config :jevex, Tickets,
  truth_threshold: 0.7,
  min_noul_certainty: 0.95
```

Module settings override global syntax options. A module may also set
`client: [backend: :lolipop]`. The backup can be a backend atom, client keyword
options, a `Jevex.Client`, or a callback returning a typed direct-API response.

- `truth_threshold` converts an accepted noul probability to a boolean. It does
  not affect raw-probability output or establish certainty.
- `min_noul_certainty` checks `max(p, 1 - p)` for both noul forms. A confident "no"
  is as certain as a confident "yes"; the threshold must be in 0.5..1.
- `min_confidence` checks Choice/Score metadata in 0..1. Missing confidence fails
  an explicit gate.
- `on_error` handles transport failures and HTTP 429, 529, or 5xx after primary
  retries. It does not handle authentication, validation, or malformed responses.
- `on_low_confidence` requires a configured gate. The backup must pass the same
  gates; a failed or insufficient backup ends evaluation without a fallback loop.

Both operators apply the same policy before returning a value or error. See
[syntax configuration](guides/syntax.md#configuration) for precedence and callbacks.

## Advanced: batching and full metadata

For several questions in one request, or access to full probabilities, confidence,
model, and usage, use the independent direct API:

```elixir
client = Jevex.Client.new!(backend: :typesafe)
questions = %{
  "urgent" => Jevex.Question.noul!("Is this urgent?"),
  "team" => Jevex.Question.choice!("Which team?", %{
    "billing" => "Payments", "support" => "Technical"
  })
}

with {:ok, %Jevex.Response{answers: answers, model: model, usage: usage}} <-
       Jevex.evaluate(client, "My invoice was charged twice", questions) do
  {answers["urgent"].noul, answers["team"].choice, model, usage}
end
```

`Jevex.evaluate/4` accepts per-call confidence and fallback options; its fallback
actions are a client struct or callback. Syntax also accepts backend atoms and
client keyword lists. `Jevex.HTTP.post/3` exposes the request layer independently,
returning normalized JSON without typed answer decoding.

`Jevex.Schema` is optional for reusable typed batches:

```elixir
defmodule TicketBatch do
  use Jevex.Schema
  noul :urgent, "Is this urgent?"
  choice :team, "Which team?", %{billing: "Payments", support: "Technical"}
end

# {:ok, result} = TicketBatch.evaluate(client, ticket)
# {:ok, full_response} = Jevex.evaluate(client, ticket, TicketBatch.questions())
```

Schema fields retain typed answers. Selected atom choices are restored, while
probability maps keep string keys. Direct-API choice values are strings. Supported
routers may omit model, usage, confidence, or distributions; absence is preserved,
not fabricated as zero.

## Guarantees, examples, and checks

The independent request/response layers validate inputs, answer coverage, types,
choice membership, bounds, and distributions. Syntax then extracts a scalar.
Response strings never create atoms. Static literals receive compile-time checks;
dynamic operands receive runtime checks. Inference in guards, match patterns, or
module bodies is rejected. Elixir remains dynamically typed: typespecs aid static
analysis, and runtime validation enforces bounds and membership. Neither guarantees
the truth or calibration of a model's judgment.

```sh
mix deps.get
mix run examples/syntax.exs                  # Diverse offline examples; no network
mix run examples/syntax.exs --live           # Four TypeSafe evaluations
mix run examples/syntax.exs --live --lolipop # Four Lolipop evaluations
mix run examples/triage.exs                  # Advanced offline schema/batch example
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix dialyzer
```

Live syntax mode runs a compact four-expression assessment instead of the full
offline collection tour. Fixture tests and doctests exercise local behavior without
API keys; they do not establish live provider compatibility. Documentation checks
cover authored modules, exported functions, macros, and callbacks. Read
[architecture](guides/architecture.md) and [reliability](guides/reliability.md) for
layer boundaries, limits, and retry behavior.

## License

MIT. See `LICENSE`.
