# Changelog

## 0.1.0 — 2026-09-18

- Elixir 1.20 support, locally verified with Elixir 1.20.2 / OTP 29.0.4;
  CI matrix covers Elixir 1.17 / OTP 27 and Elixir 1.20 / OTP 29.
- Elixir expression operators: `~>` for scalars and `~>>` for tagged results.
- Noul boolean/probability, declared Choice keys, and fractional Score expressions.
- Runtime syntax configuration, module overrides, confidence gates and fallback.
- Composition with pipelines, captures, comprehensions, streams and `with`.
- Separate configurable client/HTTP transport, typed data, and optional batch schemas.
- English documentation rewritten around expression syntax and Elixir composition.
- Native TypeSafe and Lolipop backends, OpenRouter alpha Decisions, Cloudflare
  Workers AI, Vercel experimental evaluation-model, and custom adapter support.
- Compile-time declarations, typed answer structures, strict response validation.
- Bounded retries, credential redaction, TLS, redirect refusal and size limits.
- Defensive validation of malformed structs, callback results and option lists.
- Invalid request bodies fail before credential resolution.
- HTTP/1 complete-response and pool checkout timeouts, tested over real loopback sockets.
- Per-evaluation error and confidence fallback to a client or callback.
- Runtime configuration, guides, examples, offline tests and opt-in live testing.
