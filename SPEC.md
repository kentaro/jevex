# Jevex 0.1

## Contract

Jev decisions compose with ordinary Elixir syntax. `use Jevex` imports `~>` for
validated scalars and `~>>` for tagged results. Neither introduces a custom
control-flow language. Noul produces its original probability or a boolean,
Choice produces a declared atom/string key, and Score preserves fractional
values on an ordered rubric.

Expressions belong in ordinary functions, captures, pipelines, comprehensions,
Enum/Stream transformations, with chains, and conditionals. Values can then be
matched by function clauses and guards. Inference in guards, match patterns,
and module bodies is rejected. Each operand is evaluated once; execution follows
Elixir eagerness, laziness, and short-circuit rules. There is no implicit batching,
parallelism, caching, or retry beyond the configured HTTP and fallback policy.

## Layers and configuration

Keep expression macros separate from the typed request API and HTTP transport.
The direct API exposes batch evaluation and full answer metadata; optional schema
declarations provide reusable typed batches. Runtime client and syntax settings
allow provider changes without recompilation. Per-module syntax settings override
global policy. Failure is an exception or error tuple, never a false decision.

Document the official TypeSafe Jev API first, then routers with Lolipop as the
worked example. Support native Jev through TypeSafe/Lolipop and the documented
OpenRouter, Vercel, and Cloudflare decision protocols. Never substitute generic
chat completions. Credential sources are resolved at request time.

## Compatibility

Support Elixir 1.17 through 1.20. The package requirement `~> 1.17` accepts
Elixir 1.20. CI covers 1.17/OTP 27 and 1.20/OTP 29; local verification uses
Elixir 1.20.2/OTP 29.0.4. Keep macros and typespecs compatible across this range.

## Quality

Validate static literal expressions without executing quoted code and validate
all dynamic inputs and responses. Preserve probabilities, choice membership,
and fractional scores. Never create atoms from server values. Confidence gates
and one-step fallback apply equally to both operators and all three primitives.

Use TLS by default, refuse redirects, redact credentials, and bound timeouts,
retries, and payload sizes. Test through deterministic injected HTTP responses;
live tests require explicit opt-in. State protocol guarantees separately from
model accuracy and fixture checks separately from authenticated validation.

## Deliverable

A publication-ready Hex package built by `mix hex.build`, entirely English README/guides/API documentation,
executable composition examples, doctests, tests, CI configuration, and local
package build. Rewrite the documentation around expressions, runtime setup,
idiomatic composition, and then advanced batch/protocol access. No publication.
