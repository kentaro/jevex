# Validation record

Date: 2026-09-18. Local environment: Elixir 1.20.2, Erlang/OTP 29.0.4, macOS.
CI is included but has not been run on GitHub; the Elixir 1.17/OTP 27 matrix is
not represented here as an observed result.

## Automated checks

- `mix test --cover`: 193 passing cases (131 tests + 62 doctests), 4 live tests
  excluded; line coverage 97.24% (the configured minimum is 85%).
- `mix compile --warnings-as-errors`: passed.
- `mix dialyzer`: passed with no warnings, including the fallback implementation.
- `mix docs --warnings-as-errors`: passed; HTML, Markdown and EPUB generated.
- `mix hex.publish --dry-run --yes`: passed; package and documentation build checks.
- `mix hex.build`: passed; standard Hex tarball built, not published.
- Unpacked package compiled and passed a separate consumer test using all four
  scalar forms, tagged results, and lazy streams; only runtime dependencies installed.
- `mix run examples/syntax.exs`: offline expression and composition examples passed.
- `mix run examples/triage.exs`: advanced offline schema/transport example passed.
- Module, function, macro and callback documentation coverage: passed. All
  authored API documentation is present and English; README and guides are also
  English. Doctests exercise documented examples without network requests.
- All 38 fenced Elixir blocks in README/guides parse; all 7 complete example
  modules compile. Generated documentation links were checked locally.

The suite includes both operator return forms, raw Noul probability, operand-once
evaluation, lazy stream demand, comprehensions, function clauses, weighted
reductions, short-circuiting after tagged errors, forbidden compile contexts,
and compile-time schema failures and generated choice types, strict
question/response validation, all built-in backend wire contracts, credential
redaction, retry limits/Retry-After, real loopback HTTP, redirect refusal,
streamed response size limits, application configuration, and fallback policies. Adversarial cases include missing struct fields, malformed
callback returns, invalid decoder options, duplicate configuration keys, and
credential resolution ordering. Socket tests cover stalls and slow HTTP/1 chunks.

## Authenticated Lolipop validation

One initial dynamic API request successfully returned all three primitive types
and passed strict decoding. The explicit live suites passed these four cases:

1. Schema evaluation of Noul, Choice and Score via the real Lolipop API.
2. Simulated connection error followed by successful real Lolipop fallback.
3. Simulated ambiguous Noul response followed by real Lolipop fallback, satisfying
   the configured certainty threshold.
4. Expression syntax through Lolipop: boolean Noul, raw Noul in a tagged result,
   declared Choice atoms, and a bounded Score (four real requests).

Only synthetic test messages were sent. The user's designated 1Password item was
read at runtime; credentials were not written into the source, tests, package,
logs or this report. Failure/ambiguity on the primary were deterministic fixtures,
not deliberately caused service outages. No assertion assumes that a model will
always return the same judgment.

To run live tests, supply `LOLIPOP_AI_GATEWAY_API_KEY` through your own secret
manager and explicitly run:

```sh
mix test --include live test/jevex/live_test.exs test/jevex/syntax_live_test.exs
```

These requests use provider resources and may be billable. Default `mix test`
never makes an authenticated remote request.

## Other backend coverage

TypeSafe, OpenRouter, Cloudflare and Vercel are implemented against the primary
contracts linked in [backend contracts](guides/backend-contracts.md), and their
request/response behavior is verified with fixtures. Their authenticated inference
has **not** been tested with live keys. Alpha/experimental endpoints can change.

The release artifact is a standard Hex package tarball, with source and English
documentation. The source is available on [GitHub](https://github.com/kentaro/jevex); the package
has not been published to Hex. Registry installation
and hosted HexDocs are therefore not claimed as verified.
