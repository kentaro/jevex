# Reliability, fallback, and type guarantees

Use `~>>` to compose decisions with normal Elixir error handling. It returns a
tagged result containing the same scalar that `~>` returns directly. `~>` raises
`Jevex.Error` on failure; a failed inference never silently becomes `false`.

```elixir
defmodule Support do
  use Jevex

  def triage(message) do
    with {:ok, urgent?} <- message ~>> "Does this need immediate action?",
         {:ok, team} <- message ~>> {"Which team?", billing: "Payments", support: "Technical"} do
      {:ok, %{urgent?: urgent?, team: team}}
    end
  end
end
```

Each operator is an inference request. The second request in this `with` runs
only if the first succeeds. If the judgments can run independently over the
same state, use `Jevex.evaluate/4` to batch them in a single request instead.
See [backend configuration](backends.md) for official API setup and a typed
batch example; the [syntax guide](syntax.md) covers scalar expressions.

## What is guaranteed

Syntax validates static literal questions at compilation and dynamic questions
at runtime. Each operand is evaluated once. Choices are mapped back only to
keys supplied by your program, and accepted results have the expression's
declared shape: boolean, probability, choice key, or numeric score.

The advanced schema DSL additionally generates a struct and typespec, including
closed unions for atom choices. All answers returned by syntax and typed
evaluation pass runtime validation against the original questions. Question
IDs, answer types, permitted choices, score bounds, distributions and usage
are checked. No strings from a network response become new atoms.

Elixir is dynamically typed. Typespecs help Dialyzer; they cannot stop callers
from constructing invalid structs. The request boundary revalidates questions
and client settings. Model judgments remain probabilistic. A valid typed answer
can be factually wrong, and a confidence threshold is not a correctness proof.

## Connection-error fallback

```elixir
# config/runtime.exs
import Config

config :jevex, :client, backend: :typesafe
config :jevex, :syntax, on_error: :lolipop
```

Both operators now use Lolipop as a backup for eligible TypeSafe failures. The
syntax shorthand constructs a separate client with Lolipop's own credentials.
Fallback configuration is runtime policy, not part of each decision expression.

Fallback occurs after the primary client's retries are exhausted. Eligible
errors are connection/transport errors and HTTP 429 or 5xx responses (including
529). Invalid credentials (401/403), malformed requests (422), configuration,
validation and invalid response errors are returned directly. Switching
providers will not silently conceal these problems.

Transport failures are never automatically retried by the HTTP layer because
the provider may already have processed the request. Explicit `on_error` opts
into another attempt and may cause another charge. Fallback sends the same
state to the selected backup; choose providers appropriate for that data.

## Confidence fallback

```elixir
# config/runtime.exs
config :jevex, :syntax,
  truth_threshold: 0.5,
  min_confidence: 0.8,
  min_noul_certainty: 0.9,
  on_low_confidence: :lolipop
```

`truth_threshold` only converts an accepted yes probability into the boolean
returned by a string question. `{:noul, question}` returns the probability
unchanged. Both forms still pass through `min_noul_certainty` when configured.
Every applicable answer must meet its confidence/certainty threshold. Equality
passes, including at the boolean conversion threshold.

- `min_confidence` applies to Choice and Score's reported confidence, not the
  winning option's probability. Missing confidence does not pass a threshold.
- `min_noul_certainty` applies to `max(p, 1 - p)` for Noul's Yes probability.
  A threshold of 0.9 accepts `p <= 0.1` or `p >= 0.9`. This is a derived
  certainty rule, not a provider-reported confidence value.
- Thresholds are opt-in. With none configured, valid responses are returned
  regardless of confidence.
- Specifying `on_low_confidence` requires at least one threshold.

Fallback performs one evaluation of the full question set. It never chains to
another fallback. The backup has its own bounded retry policy, and must satisfy
the same thresholds. If it does not, the result is
`{:error, %Jevex.Error{kind: :low_confidence}}`. This error is also returned when
thresholds are unmet without a fallback. Backup errors are returned directly.

## Custom fallback functions

Either fallback option also accepts a one-argument function. With an explicit
typed batch, pass the policy directly to `Jevex.evaluate/4`:

```elixir
on_low = fn %{reason: :low_confidence, response: response} ->
  # Persist or enqueue for review here if your application requires it.
  # `response` is already typed; this sample returns a domain handoff error.
  _ = response
  {:error, %Jevex.Error{kind: :low_confidence, message: "Human review required"}}
end

Jevex.evaluate(primary, state, questions,
  min_confidence: 0.8,
  on_low_confidence: on_low
)
```

The callback receives `Jevex.Fallback.context()`: reason, primary client, state,
normalized questions, and the error or response that triggered fallback.
Return `{:ok, %Jevex.Response{}}` with **string** IDs and choices, or
`{:error, %Jevex.Error{}}`. Returned responses are revalidated and must pass the
same thresholds. Arbitrary callback return values and exceptions are sanitized.
Callbacks run synchronously in the caller and must enforce their own deadlines.
Context includes sensitive state; avoid indiscriminate logging.

The same function can be installed as a syntax policy in runtime configuration.
It must return a typed response, not a scalar or an already converted schema
struct: Jevex validates it before `~>` or `~>>` extracts the requested value.
For a schema batch, `Ticket.evaluate(client, state, policy)` forwards the same
options and converts the validated result into its generated struct afterward.

## Retry behavior

Only 429 and 529 retry automatically. The initial request plus `max_retries`
is the maximum attempt count. Delays use exponential backoff and jitter, bounded
by `max_retry_delay`. Retry-After seconds and HTTP dates take precedence. If the
server requests a longer delay than the cap, the HTTP error is returned; Jevex
never retries sooner than that instruction. Request credentials are held fixed
for those attempts. 5xx errors other than 529 can trigger configured fallback
but do not automatically retry on the same provider.

## Provider metadata

TypeSafe and Lolipop responses require full native metadata. OpenRouter and
Vercel permit omitted confidence/distributions; Jevex returns `nil`, not made-up
certainty. Missing model/usage is also `nil`. Present router usage may contain
only the token counts actually reported; missing counts are not zero. A missing
Score legend is reconstructed from the request rubric. Explicit invalid values
are rejected even in partial-metadata mode. All Answer probability-map keys
remain strings, including with a schema that restores the selected atom choice.

## Error safety and tests

Default errors retain kind, status, request ID and Retry-After, not raw server
bodies, state, keys or transport exception messages. Custom adapters/callbacks
are trusted code and are responsible for their own error messages.

The automated suite uses fake transports and real loopback sockets. It covers
actual JSON/auth headers, refusal to follow redirects, response size enforcement,
retries, malformed responses, declaration failures, generated types and fallback
paths. Live tests are excluded by default. See `VALIDATION.md` for exactly which
providers have been exercised with real credentials.

## Timeout boundaries

The default Req transport sets receive inactivity and complete-response timeouts
from `timeout`, and connection/pool checkout limits from `connect_timeout`.
Finch's complete-response timeout is best-effort and applies only to HTTP/1;
HTTP/2 retains the receive inactivity timeout. These are per-attempt limits,
not an exact wall-clock deadline for an evaluation including retries, fallback,
credential resolvers, or custom callbacks. Use an application-level supervised
task deadline when that overall limit is required.

Loopback tests cover stalled responses, slow HTTP/1 chunk streams, oversize
bodies, redirects, and refused connections. Invalid request shapes and payload
encoding failures are rejected before credential resolution or transport.
