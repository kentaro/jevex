# Decision syntax in ordinary Elixir

`use Jevex` imports `~>` and `~>>`. Both accept the same Noul, Choice, and Score
expressions, use the same client and confidence policy, and perform the same
response validation. `~>` returns a scalar and raises `Jevex.Error` on failure.
`~>>` returns `{:ok, scalar}` or `{:error, %Jevex.Error{}}`.

There is no special loop, branching construct, schema, or result wrapper to learn
for the scalar form. The examples below are ordinary functions in a module with
`use Jevex`.

## Four forms across three answer kinds

```elixir
defmodule DecisionValues do
  use Jevex

  def needs_attention?(ticket), do: ticket ~> "Does this need attention?"
  def urgency(ticket), do: ticket ~> {:noul, "Is this urgent?"}

  def team(ticket) do
    ticket ~> {"Which team?", billing: "Payments", support: "Technical issues"}
  end

  def severity(ticket) do
    ticket ~> {"How severe?", ["Low", "Medium", "High"]}
  end
end
```

| Form | Accepted answer becomes |
| --- | --- |
| Question string | Boolean from the noul yes probability using `p >= truth_threshold` |
| `{:noul, question}` | Raw noul yes probability in 0..1 |
| `{question, keyword_or_map}` | One original choice key, retaining its atom/string type |
| `{question, ordered_levels}` | Numeric score in `0..(length(levels) - 1)` |

The default truth threshold is 0.5. Raw noul ignores truth conversion, but still
passes through any configured certainty gate and fallback. Scores may be
fractional and are not necessarily normalized to 0..1. Choice rubrics accept 1 to
255 options; score rubrics accept 2 to 10 levels. A map with string choice keys
returns strings, for example `{"Language?", %{"en" => "English", "fr" => "French"}}`.

All examples below can use `~>>` instead when tagged error handling is required;
do not use a tagged result itself as an `if` condition because tuples are truthy.

## Pipelines, captures, and grouping

Filter with boolean noul, then group retained tickets by Choice:

```elixir
def queues(tickets) do
  tickets
  |> Enum.filter(&(&1 ~> "Does this need attention?"))
  |> Enum.group_by(&(&1 ~> {"Which team?", billing: "Payments", support: "Technical"}))
end
```

For `n` input tickets and `k` retained tickets, this performs `n + k` primary
evaluations. The capture does not batch its calls. Each expression retains normal
Elixir evaluation semantics and can raise before collection traversal completes.

## Mapping probabilities and sorting scores

Preserve raw probabilities for calibration work or later numerical processing:

```elixir
def probabilities(tickets) do
  Enum.map(tickets, fn ticket -> {ticket, ticket ~> {:noul, "Is this urgent?"}} end)
end

def ranked(tickets) do
  Enum.sort_by(tickets, &(&1 ~> {"How severe?", ["Low", "Medium", "High"]}), :desc)
end
```

Each function makes one evaluation per input element. `Enum.sort_by/3` computes
one key per element; putting inference in an `Enum.sort/2` comparator can repeat
requests many times. If a score will also be displayed, retain it explicitly:

```elixir
def ranked_with_scores(tickets) do
  tickets
  |> Enum.map(fn ticket -> {ticket, ticket ~> {"How severe?", ["Low", "Medium", "High"]}} end)
  |> Enum.sort_by(&elem(&1, 1), :desc)
end
```

This reuses each computed score. There is no implicit cache when the same
expression appears again in source or is evaluated again later.

## Comprehensions

A `for` filter can use boolean noul, and its body can use Choice:

```elixir
def assignments(tickets) do
  for ticket <- tickets,
      ticket ~> "Does this need attention?" do
    {ticket, ticket ~> {"Which team?", billing: "Payments", support: "Technical"}}
  end
end
```

The filter evaluates once per input. The body evaluates only for retained tickets.
As with the pipeline, `n` inputs and `k` retained tickets require `n + k` primary
evaluations. No schema declaration is involved.

## Lazy streams and early termination

```elixir
def first_urgent(tickets, limit) do
  tickets
  |> Stream.filter(&(&1 ~> "Does this need attention?"))
  |> Enum.take(limit)
end
```

Constructing the stream makes no requests. Consumption starts evaluation, and
`Enum.take/2` stops after the requested number of matches. Finding five matching
tickets may require more than five questions, or may inspect the whole input.
Re-enumerating the stream performs requests again. To take five scored inputs
regardless of filtering, use `Stream.map/2` followed by `Enum.take(5)`.

## Reductions and `cond`

Raw noul is a number and can participate in ordinary accumulation:

```elixir
def total_urgency_probability(tickets) do
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
```

The reduction evaluates once per input. `priority/1` makes one evaluation and
reuses it in all branches. Summing model probabilities does not establish their
calibration or correctness. If a `cond` condition itself contains an operator,
only conditions reached before the first true branch are evaluated.

## Function-clause dispatch and guards

Compute a decision first, then dispatch using normal clauses and guards:

```elixir
def route(ticket) do
  team = ticket ~> {"Which team?", billing: "Payments", support: "Technical"}
  dispatch(team, ticket)
end

defp dispatch(:billing, ticket), do: {:billing_queue, ticket}
defp dispatch(:support, ticket), do: {:support_queue, ticket}

def urgency_band(ticket) do
  probability = ticket ~> {:noul, "Is this urgent?"}
  band(probability)
end

defp band(probability) when probability >= 0.9, do: :high
defp band(probability) when probability <= 0.1, do: :low
defp band(_probability), do: :review
```

Inference is forbidden inside guards and match patterns. Passing a previously
computed number or choice to a guard or pattern is ordinary Elixir and makes no
additional request. Inference is also forbidden in module bodies so compilation
cannot trigger a request. Functions, anonymous functions, and an IEx import are
supported contexts.

## Tagged results with `with` and `reduce_while`

Use `~>>` when failures belong in the return value:

```elixir
def assess(ticket) do
  with {:ok, urgent?} <- ticket ~>> "Does this need attention?",
       {:ok, probability} <- ticket ~>> {:noul, "Is this urgent?"},
       {:ok, team} <- ticket ~>> {"Which team?", billing: "Payments", support: "Technical"},
       {:ok, severity} <- ticket ~>> {"How severe?", ["Low", "Medium", "High"]} do
    {:ok, %{attention?: urgent?, urgency: probability, team: team, severity: severity}}
  end
end
```

A successful call makes four primary evaluations. The first error exits the
`with`, so later questions are not sent. A successful `{:ok, false}` still matches
`{:ok, urgent?}` and continues; use `{:ok, true}` if false should stop that chain.
The boolean and raw forms here intentionally ask separately to demonstrate both;
if both values are needed from one answer, request raw noul once and compare it.

Stop a collection traversal on the first evaluation error:

```elixir
def teams_until_error(tickets) do
  result =
    Enum.reduce_while(tickets, {:ok, []}, fn ticket, {:ok, acc} ->
      case ticket ~>> {"Which team?", billing: "Payments", support: "Technical"} do
        {:ok, team} -> {:cont, {:ok, [{ticket, team} | acc]}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)

  case result do
    {:ok, assignments} -> {:ok, Enum.reverse(assignments)}
    error -> error
  end
end
```

The tagged operator handles `Jevex.Error` failures from evaluation. It is not a
general exception boundary for arbitrary caller code in an operand. Invalid
static literal expressions still raise `CompileError` during compilation.

## `if`, `case`, and short-circuiting

```elixir
def action(ticket) do
  if ticket != nil and (ticket ~> "Does this need attention?") do
    case ticket ~> {"Which team?", billing: "Payments", support: "Technical"} do
      :billing -> :billing_queue
      :support -> :support_queue
    end
  else
    :no_action
  end
end
```

A nil ticket causes zero evaluations. Otherwise the boolean question runs once;
the choice question runs only for a true answer. Parenthesize operator expressions
when combining operators to make precedence clear. Both operators evaluate each
of their operands exactly once and retain normal Elixir short-circuit behavior.

## Explicit bounded concurrency

```elixir
def concurrent_scores(tickets) do
  tickets
  |> Task.async_stream(
    fn ticket -> ticket ~>> {"How severe?", ["Low", "Medium", "High"]} end,
    max_concurrency: 4,
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
```

Tasks, concurrency, ordering, and task timeout are explicitly owned by the
application. Task exits are distinct from tagged inference errors. At most four
task evaluations run simultaneously here; each can still perform its own retries
or fallback. Concurrency reduces elapsed time, not the number of questions or
requests. Choose limits appropriate to the provider, and allow enough task time
for configured HTTP timeouts, retry delays, and fallback. Taking fewer task
results can still start additional work due to concurrent scheduling.

## Dynamic expressions

```elixir
def decide(state, expression), do: state ~>> expression
```

Literal questions are checked during macro expansion without executing arbitrary
quoted code. Computed questions are evaluated once and checked at runtime. A
runtime expression can be any of the four forms described above. Choice options
may be a keyword list or map; an ordered non-keyword list is a score rubric.

## Configuration

Start with the official TypeSafe API in `config/runtime.exs`:

```elixir
import Config

config :jevex, :client,
  backend: :typesafe,
  api_key: {:system, "TYPESAFE_API_KEY"}

config :jevex, :syntax,
  truth_threshold: 0.5,
  min_confidence: 0.8,
  min_noul_certainty: 0.9,
  on_error: :lolipop,
  on_low_confidence: :lolipop

config :jevex, TicketTools,
  truth_threshold: 0.7,
  min_noul_certainty: 0.95
```

Client defaults specify connection settings. Global syntax settings specify
conversion and evaluation policy. Calling-module settings override global syntax
settings with a shallow keyword merge; an explicit `client` replaces the entire
global syntax `client` entry. A keyword client then passes through
`Jevex.Client.new/1` and its application/provider default rules. Configuration is
read for each expression at runtime.

| Syntax option | Meaning |
| --- | --- |
| `client` | Client struct or client keyword options; default `Jevex.Client.new!/0` |
| `truth_threshold` | Inclusive boolean yes threshold in 0..1; default 0.5 |
| `min_confidence` | Minimum Choice/Score confidence in 0..1; missing confidence fails |
| `min_noul_certainty` | Minimum `max(p, 1 - p)` in 0.5..1, for boolean and raw noul |
| `on_error` | Backup after transport failures or HTTP 429, 529, or 5xx |
| `on_low_confidence` | Backup when an explicit confidence gate fails |

To use **Lolipop AI Gateway** for one module while retaining the global TypeSafe
client, provide `LOLIPOP_AI_GATEWAY_API_KEY` and configure:

```elixir
config :jevex, TicketTools,
  client: [backend: :lolipop, api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"}]
```

Changing `config :jevex, :client` instead switches the default for all modules.
Provider changes clear inherited provider-specific credentials, endpoints, model,
and account settings. Environment credentials are read on every request. See
[backends](backends.md) for other routers and their protocol restrictions.

## Confidence and fallback semantics

An underlying noul of 0.1 has certainty 0.9 and becomes false at the default truth
threshold. Raw noul returns 0.1. An underlying noul of 0.51 becomes true but has
certainty only 0.51. The `min_noul_certainty` gate applies to both output forms;
`truth_threshold` only changes boolean conversion. Choice and Score instead use
the provider's confidence field, and missing metadata fails a configured gate.

`on_low_confidence` requires at least one gate. Without a backup, a failed gate
raises `Jevex.Error` with `kind: :low_confidence` through `~>`, or returns that error
through `~>>`. The backup must satisfy the same gates; there is no recursive
fallback chain. Each client's bounded HTTP retries remain separate. Authentication,
validation, and malformed-response errors do not trigger `on_error`.

Syntax fallback actions accept a backend atom such as `:lolipop`, a client keyword
list such as `[backend: :lolipop, timeout: 10_000]`, a `Jevex.Client`, or a callback.
A callback receives `reason`, `error`, `response`, `state`, `questions`, and the
primary `client`. It must return `{:ok, %Jevex.Response{}}` or
`{:error, %Jevex.Error{}}`, not a scalar:

```elixir
backup = Jevex.Client.new!(backend: :lolipop)
current = Application.get_env(:jevex, :syntax, [])

Application.put_env(:jevex, :syntax,
  Keyword.put(current, :on_error, fn %{state: state, questions: questions} ->
    Jevex.evaluate(backup, state, questions)
  end)
)
```

Preserve the supplied question IDs and direct-API string choice values. Successful
callback responses are revalidated before confidence checks and scalar extraction.
Callbacks run in the caller's process; context can contain sensitive state and
client settings. The tagged operator changes error presentation, not the policy.

## Advanced access and validation boundaries

For explicit batching or full probability distributions, confidence, model, and
usage, use `Jevex.evaluate/4`. Optional `Jevex.Schema` declarations support reusable
typed batches; they are not needed for syntax. `Schema.questions/0` can be passed
to the direct API to retain full response metadata.

Choice strings are matched back to keys supplied by the caller and never interned
as new atoms. Typespecs support static analysis, while runtime checks enforce
option membership, numeric bounds, and protocol coverage. These checks do not
establish factual accuracy or probability calibration. Offline fixtures demonstrate
execution semantics, not live service availability or model quality.
