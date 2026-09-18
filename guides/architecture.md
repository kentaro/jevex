# Architecture

Jevex puts decision syntax above an independent request and validation layer.
`use Jevex` imports two operators. They do not rewrite Elixir control flow or
require a schema. `state ~> question` returns a boolean, raw noul probability,
declared choice key, or numeric score; `state ~>> question` returns the same value
inside `{:ok, value}` or a structured `{:error, error}`. Both expand to ordinary
runtime calls.

## Expression evaluation path

```text
use Jevex
state ~> question                 state ~>> question
        |
Jevex.Syntax.evaluate! / evaluate
  runtime client and module configuration
  one question; confidence/fallback policy
        |
Jevex.evaluate/4  <--- direct question maps or advanced Schema batches
        |
Jevex.HTTP.request/3
  input checks, credentials, JSON, retries, size limits
        |
Jevex.Backend -> Jevex.Transport
  provider protocol -> HTTPS POST
        |
backend JSON normalization
        |
Jevex.Response.decode/3
  coverage, answer types, choice membership, bounds, metadata
        |
Jevex.Fallback
  confidence gates; at most one backup or callback
        |
validated Jevex.Response
        |
syntax scalar extraction
  boolean / raw probability / declared option / score
        |
scalar or {:ok, scalar}; raised or tagged Jevex.Error
```

The direct API returns `Jevex.Response` with typed answer structs, model, and usage
metadata. Both syntax operators extract a scalar after the same validation and
policy; only the error/result presentation differs. Schema batches instead map validated answers into declared struct fields.

## Responsibilities

| Layer | Responsibility | Output |
| --- | --- | --- |
| `Jevex.Syntax` | Expand operators, resolve runtime configuration, construct one question, extract a value | Scalar or tagged scalar/error |
| `Jevex.Question` | Validate instructions, question kinds, and rubrics | Normalized question structs and wire maps |
| `Jevex.Client` | Validate backend, connection settings, credential source, and limits | Immutable client |
| `Jevex.HTTP` | Encode requests, resolve credentials, retry eligible statuses, bound responses | Backend-normalized JSON or error |
| `Jevex.Backend` | Apply provider protocol and response transformations | Defaults, headers, JSON transformation |
| `Jevex.Transport` | Execute one configured POST | HTTP status, headers, raw JSON |
| `Jevex.Response` | Validate answers against the exact questions | Typed answer structs and response metadata |
| `Jevex.Fallback` | Apply confidence gates and one-step recovery | Valid response or structured error |
| `Jevex.Schema` | Compile reusable batch declarations and convert validated answers | Typed batch result struct |

`Jevex.HTTP.post/3` exposes the request layer independently; it does not decode
typed answers. `Jevex.evaluate/4` adds answer validation and optional policy.
Question IDs normalize to strings, and ambiguous atom/string IDs are rejected.

## Macro expansion and ordinary Elixir semantics

Each operator emits a runtime call with the original state and question operands,
each evaluated exactly once. Neither captures nor replaces an enclosing `if`,
`case`, `cond`, `with`, comprehension, collection function, or short-circuit
operator. Ordinary Elixir determines which expressions are reached.

Noul supports two presentations: string questions convert the accepted yes
probability to a boolean, while `{:noul, question}` returns the probability.
Choice maps the selected string back to a supplied atom or string key. Score
preserves the returned numeric value within the requested zero-based rubric range.
No answer kind requires a schema or special branching syntax.

Literal right operands are validated during compilation without executing
arbitrary quoted expressions. Dynamic right operands are evaluated and validated
at runtime. Guards, match patterns, and module-body inference are rejected; an
interactive import is allowed. No request is made while importing the operator.

A reached expression constructs one question and performs one evaluation. There
is no implicit batching, cache, task pool, or background queue. Each configured
retry or fallback can add HTTP requests. Applications needing explicit batching
use the direct API or `Jevex.Schema` rather than combining expression syntax and
assuming a single request.

## Collections, laziness, and error flow

Execution cost follows the surrounding Elixir construct:

| Construct | Evaluation behavior |
| --- | --- |
| `Enum.map`, `Enum.filter`, `Enum.group_by`, `Enum.reduce` | One reached expression per visited element |
| `Enum.sort_by` | One key expression per element; subsequent comparisons reuse keys |
| `for` with a decision filter | Filter for each input, body only for matches |
| `Stream.map` / `Stream.filter` | Deferred until consumption; `take` can stop traversal early |
| `with` using `~>>` | Stops at the first nonmatching tagged result |
| `Enum.reduce_while` using `~>>` | Caller explicitly chooses whether errors halt traversal |
| Function-clause dispatch | Decision computed before matching; clauses make no implicit requests |
| `Task.async_stream` | Explicitly bounded concurrent evaluations with separate task-exit handling |

An error from `~>` raises and interrupts ordinary traversal unless caught.
An error from `~>>` is data for the caller's `with`, `case`, or reducer.
`{:ok, false}` is a successful tagged result, not an error and not a false value
when used directly as an Elixir condition. Programmer errors outside the inference
boundary are not turned into successful-looking decisions.

Streams are not caches: enumerating one again reruns inference. A filtering stream
may inspect many inputs to find a requested number of matches. Concurrent tasks
may start extra work before an early consumer stops; concurrency changes scheduling,
not the number of requested questions. Inference in a sorting comparator can run
repeatedly, so use `sort_by` or precompute scores instead.

## Runtime settings and provider separation

The default syntax client is constructed from `config :jevex, :client`.
`config :jevex, :syntax` supplies global conversion and evaluation policy.
`config :jevex, MyModule` overrides syntax options for that calling module.
The syntax merge is shallow: a module's `client` entry replaces the entire global
syntax `client` value. A keyword client is subsequently processed by
`Jevex.Client.new/1` with its own application-default and provider-default rules.

Syntax configuration is read on every evaluated expression. Client structs are
immutable snapshots; credential sources such as `{:system, name}` are resolved
on each request. Switching providers clears inherited provider-specific keys,
endpoints, model names, and account settings. The syntax macro never embeds a
credential or selects a provider at compilation.

## Confidence and recovery

`truth_threshold` is a scalar conversion setting, not an inference confidence
gate. A string-form noul becomes true when `p >= truth_threshold`; raw noul
preserves `p` regardless of that threshold. The separate `min_noul_certainty`
gate checks `max(p, 1 - p)` for both forms. Choice and Score use the
`min_confidence` gate; absent confidence fails an explicit gate. These rules apply
identically to the scalar and tagged operators.

Policy runs after response decoding and before scalar or schema conversion.
Transport retries handle eligible HTTP responses. Error fallback handles
transport failures and transient HTTP status failures; authentication, validation,
and malformed-response errors do not trigger it. Low-confidence fallback applies
to otherwise valid responses that miss a configured threshold.

Only one fallback is permitted. Backup responses and callback responses undergo
validation and the same confidence gates. An insufficient or failed backup ends
the operation rather than invoking another fallback. Syntax configuration can
expand backend atoms or client keyword lists into clients; the lower-level
policy accepts client structs or callbacks returning typed direct-API responses.

## Advanced batch schemas

`use Jevex.Schema` imports literal declarations and generates a required-field
struct, a `t/0` type, `questions/0`, and tagged/bang evaluation functions.
Unlike the operator's dynamic operands, schema declarations are literal-only.
Invalid or duplicate fields, colliding keys, and invalid rubrics fail compilation.

Schema choice atoms use a closed lookup table. Selected values are restored only
after native response validation; probability maps retain string keys. Schema
results contain typed answer metadata, while full model and usage metadata remain
available through `Jevex.evaluate(client, state, Schema.questions())`.

Typespecs can express declared atom unions but not individual string values or
probability bounds. Runtime validation covers those constraints. Structs can
still be constructed manually with invalid values; supported constructors and
evaluation functions are the validation boundaries. Neither static analysis nor
response validation establishes that a model's judgment is correct.

## Extension and verification

Use `backend: :custom` with an explicit endpoint and model for the native
protocol. A different protocol implements `Jevex.Backend`: `defaults/1`,
`encode/3`, `headers/1`, `decode/1`, and `partial_metadata?/0`. Missing metadata
must remain missing instead of being invented. The common HTTP layer owns bearer
authentication, retries, and limits; the response layer owns validation.

Tests inject `Jevex.Transport` to exercise actual JSON encoding, response decoding,
confidence policy, and scalar/schema conversion without external services.
`examples/syntax.exs` demonstrates Noul, Choice, and Score through pipelines,
captures, comprehensions, lazy streams, reducers, clauses, branching, tagged
`with`, and bounded tasks. Its live mode intentionally uses a compact four-question
assessment. `examples/triage.exs` demonstrates the advanced batch path. Fixtures and doctests
establish local behavior, while live provider compatibility additionally requires
authenticated requests. See [reliability](reliability.md) and
[backend contracts](backend-contracts.md) for operational boundaries.
