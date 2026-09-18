# jevex 0.1

## Contract

An Elixir library with three independent layers: validated typed questions and
answers, a configurable low-level HTTP client, and a compile-time schema DSL.
The same schema can evaluate through different clients without recompilation.

Backends are selected per client or through application configuration; endpoint,
model and credential sources are runtime configuration. A backend behaviour
allows custom request/response protocols without changing the DSL.

Support the native Jev protocol through TypeSafe and Lolipop, and documented
decision protocols of OpenRouter, Vercel and Cloudflare where publicly specified.
Never send Jev evaluations to a chat-completions endpoint.

## Quality

Validate declarations at compile time and validate all network responses before
exposing typed answers. Preserve Noul probabilities, Choice distributions and
Score fractional values. No conversion of untrusted strings to atoms.

Use TLS by default, disable redirects, redact credentials in inspection, bound
timeouts and retries, and do not retry ambiguous transport failures by default.
Test with deterministic injected HTTP responses; live tests must be explicit.
Document actual guarantees and distinguish contract tests from live validation.

## Deliverable

Runnable Mix package with source, tests, examples, English API reference,
Japanese quickstart, backend configuration guide, reliability and architecture
guides, CI and package build verification. No publication is requested.
