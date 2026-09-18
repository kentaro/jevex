# Validation record

Date: 2026-09-18. Local environment: Elixir 1.20.2, Erlang/OTP 29.0.4, macOS.
CI is included but has not been run on GitHub; the Elixir 1.17/OTP 27 matrix is
not represented here as an observed result.

## Automated checks

- `mix test --cover`: 76 passing cases (75 tests + 1 doctest), 3 live tests
  excluded; line coverage above 96% (the configured minimum is 85%).
- `mix compile --warnings-as-errors`: passed.
- `mix dialyzer`: passed with no warnings, including the fallback implementation.
- `mix docs --warnings-as-errors`: passed; HTML, Markdown and EPUB generated.
- `mix hex.build`: passed; local package built, not published.
- `mix run examples/triage.exs`: offline schema/transport example passed.

The suite includes compile-time DSL failures and generated choice types, strict
question/response validation, all built-in backend wire contracts, credential
redaction, retry limits/Retry-After, real loopback HTTP, redirect refusal,
streamed response size limits, application configuration, and fallback policies.

## Authenticated Lolipop validation

One initial dynamic API request successfully returned all three primitive types
and passed strict decoding. An additional explicit live suite passed all three:

1. Schema evaluation of Noul, Choice and Score via the real Lolipop API.
2. Simulated connection error followed by successful real Lolipop fallback.
3. Simulated ambiguous Noul response followed by real Lolipop fallback, satisfying
   the configured certainty threshold.

Only synthetic test messages were sent. The user's designated 1Password item was
read at runtime; credentials were not written into the source, tests, package,
logs or this report. Failure/ambiguity on the primary were deterministic fixtures,
not deliberately caused service outages. No assertion assumes that a model will
always return the same judgment.

To run live tests, supply `LOLIPOP_AI_GATEWAY_API_KEY` through your own secret
manager and explicitly run:

```sh
mix test --include live test/jevex/live_test.exs
```

These requests use provider resources and may be billable. Default `mix test`
never makes an authenticated remote request.

## Other backend coverage

TypeSafe, OpenRouter, Cloudflare and Vercel are implemented against the primary
contracts linked in [backend contracts](guides/backend-contracts.md), and their
request/response behavior is verified with fixtures. Their authenticated inference
has **not** been tested with live keys. Alpha/experimental endpoints can change.

This is a local source deliverable. It has not been published to Hex or GitHub.
