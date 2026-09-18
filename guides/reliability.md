# Reliability, fallback, and type guarantees

## What is guaranteed

The schema DSL validates literal declarations at compilation and generates a
struct and typespec, including closed unions for atom choices. All returned
HTTP answers pass runtime validation against the original questions. Question
IDs, answer types, permitted choices, score bounds, distributions and usage
are checked. No strings from a network response become new atoms.

Elixir is dynamically typed. Typespecs help Dialyzer; they cannot stop callers
from constructing invalid structs. The request boundary revalidates questions
and client settings. Model judgments remain probabilistic. A valid typed answer
can be factually wrong, and a confidence threshold is not a correctness proof.

## Connection-error fallback

```elixir
backup = Jevex.Client.new!(backend: :typesafe)
Ticket.evaluate(primary, state, on_error: backup)
```

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
Ticket.evaluate(primary, state,
  min_confidence: 0.8,
  min_noul_certainty: 0.9,
  on_low_confidence: backup
)
```

Every applicable answer must meet its threshold. Equality passes.

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

Either fallback option also accepts a one-argument function:

```elixir
on_low = fn %{reason: :low_confidence, response: response} ->
  # Persist or enqueue for review here if your application requires it.
  # `response` is already typed; this sample returns a domain handoff error.
  _ = response
  {:error, %Jevex.Error{kind: :low_confidence, message: "Human review required"}}
end

Ticket.evaluate(primary, state, min_confidence: 0.8, on_low_confidence: on_low)
```

The callback receives `Jevex.Fallback.context()`: reason, primary client, state,
normalized questions, and the error or response that triggered fallback.
Return `{:ok, %Jevex.Response{}}` with **string** IDs and choices, or
`{:error, %Jevex.Error{}}`. Returned responses are revalidated and must pass the
same thresholds. Arbitrary callback return values and exceptions are sanitized.
Callbacks run synchronously in the caller and must enforce their own deadlines.
Context includes sensitive state; avoid indiscriminate logging.

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
