# Backend configuration

Start with `use Jevex` and configure the official TypeSafe API at runtime.
Your decision expressions stay the same when you change providers. The syntax
uses `Jevex.Client` underneath; it never embeds API keys or endpoints in macros.

```elixir
# config/runtime.exs
import Config

config :jevex, :client,
  backend: :typesafe,
  api_key: {:system, "TYPESAFE_API_KEY"}
```

```elixir
defmodule Support do
  use Jevex

  def route(message) do
    message ~>> {"Which team should handle this?",
                 billing: "Payments and invoices", support: "Technical issues"}
  end
end
```

`Support.route/1` returns `{:ok, :billing}`, `{:ok, :support}`, or
`{:error, %Jevex.Error{}}`. Use `~>` when you want the scalar directly and intend
errors to raise. Both operators use the same client, validation, and policies.
See the [syntax guide](syntax.md) for boolean, probability, choice, and score
expressions, including composition with `with`, `case`, and `Enum`.

## Switch to a router

For Lolipop AI Gateway, change the client configuration:

```elixir
# config/runtime.exs
config :jevex, :client,
  backend: :lolipop,
  api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"}
```

The same `Support.route/1` function now uses Lolipop's Jev endpoint. A router
must explicitly support the Jev decision protocol; a generic OpenAI-compatible
Chat Completions endpoint is not sufficient.

## Built-in backends

| Backend | Default model | Credential environment variable | Extra setting |
|---|---|---|---|
| `:typesafe` | `jev-latest` | `TYPESAFE_API_KEY` | — |
| `:lolipop` | `typesafe/jev-latest` | `LOLIPOP_AI_GATEWAY_API_KEY` | — |
| `:openrouter` | `typesafe/jev-1.13` | `OPENROUTER_API_KEY` | — |
| `:cloudflare` | `typesafe/jev` | `CLOUDFLARE_API_TOKEN` | `account_id` |
| `:vercel` | `typesafe-ai/jev` | `AI_GATEWAY_API_KEY` | — |
| `:custom` | required | `TYPESAFE_API_KEY` | `endpoint`, `model` |

Full URLs, protocol differences and primary references are in
[Backend contracts](backend-contracts.md). OpenRouter is an alpha API and
Vercel uses the experimental AI SDK v4 evaluation protocol. Model availability
and aliases are controlled by providers. Override `model` to pin a release.

```elixir
Jevex.Client.new!(
  backend: :cloudflare,
  account_id: System.fetch_env!("CLOUDFLARE_ACCOUNT_ID"),
  api_key: {:system, "CLOUDFLARE_API_TOKEN"}
)
```

## Runtime application configuration

```elixir
# config/runtime.exs
import Config

config :jevex, :client,
  backend: :typesafe,
  api_key: {:system, "TYPESAFE_API_KEY"},
  timeout: 15_000,
  max_retries: 2
```

`Jevex.Client.new!()` reads these defaults when constructed. Explicit options
win. Existing clients remain unchanged when application settings change;
switching `backend` explicitly clears inherited credentials, endpoint, model and
account ID and uses the new provider's defaults unless explicitly supplied.
Credential environment variables are resolved afresh on every evaluation.
Retries for one evaluation use its originally resolved credential.

Configure syntax conversion and fallback separately from connection settings:

```elixir
# config/runtime.exs
config :jevex, :syntax,
  truth_threshold: 0.5,
  min_noul_certainty: 0.9,
  on_error: :lolipop,
  on_low_confidence: :lolipop

# Only expressions inside Support use this client override.
config :jevex, Support,
  client: [backend: :typesafe, timeout: 10_000]
```

Module syntax options override global syntax options. A `:client` entry may be
client options or an already constructed `Jevex.Client`; without one, syntax
uses `Jevex.Client.new!/0` and the application client settings. Backend atoms
and client-option lists are shorthand for **syntax** fallback configuration.
The explicit evaluation API takes a backup client or callback instead. See
[reliability](reliability.md) for eligibility, confidence gates, and retry costs.

You can pass `api_key: "..."` or `api_key: fn -> secret_from_vault() end`.
Prefer runtime secret resolution. The resolver should return a nonempty string
and must have its own bounded runtime. Client inspection redacts credentials
and endpoint URLs. No global process or GenServer is required.

## Timeouts and limits

| Option | Default | Meaning |
|---|---:|---|
| `timeout` | 30,000 | response receive timeout in milliseconds, per attempt |
| `connect_timeout` | 5,000 | socket connection timeout in milliseconds |
| `max_retries` | 2 | retries after initial request, only 429/529; range 0–10 |
| `max_retry_delay` | 30,000 | maximum sleep in milliseconds; range 0–300,000 |
| `max_request_bytes` | 1,048,576 | encoded JSON request limit |
| `max_response_bytes` | 4,194,304 | response body limit enforced while receiving |

These are library defaults, not assertions about provider quotas. Set stricter
limits if required by your provider. A retry or fallback increases total latency;
there is no overall evaluation deadline. A custom transport or secret resolver
is responsible for its own timeout behavior.

## Custom endpoints and adapters

A native System One-compatible proxy requires no new module:

```elixir
client = Jevex.Client.new!(
  backend: :custom,
  endpoint: "https://gateway.example.com/v1/systemone",
  model: "jev-latest",
  api_key: {:system, "MY_GATEWAY_KEY"}
)
```

`endpoint` is a full POST URL, not a base URL. HTTPS is required except for
loopback HTTP during testing. Redirects, userinfo, URL queries and fragments
are rejected or disabled so authentication is not accidentally forwarded.

For a different protocol, implement `Jevex.Backend` and pass its module:

```elixir
defmodule MyGateway do
  @behaviour Jevex.Backend

  def defaults(_), do: {:ok, %{endpoint: "https://gateway.example.com/evaluate", model: "jev-latest"}}
  defdelegate encode(model, state, questions), to: Jevex.Backends.TypeSafe
  def headers(_model), do: [{"x-client", "jevex"}]
  defdelegate decode(body), to: Jevex.Backends.TypeSafe
  def partial_metadata?, do: false
end

Jevex.Client.new!(backend: MyGateway, api_key: {:system, "MY_GATEWAY_KEY"})
```

Adapters are trusted application code. `encode/3` receives validated native
question maps. `decode/1` normalizes JSON before `Jevex.Response` validates it.
Authentication is owned by the client; do not add a second Authorization header.
For test injection, implement `Jevex.Transport`; see the offline example.

## Explicit clients and batched questions

Use `Jevex.evaluate/4` when a caller must choose a client per request, send
several questions in one request, or inspect distributions and usage. The syntax
operators each evaluate one question and extract its scalar result.

```elixir
client = Jevex.Client.new!(backend: :typesafe)
backup = Jevex.Client.new!(backend: :lolipop)

questions = %{
  urgent: Jevex.Question.noul!("Does this need immediate action?"),
  department: Jevex.Question.choice!("Which team should handle this?", %{
    billing: "Payments and invoices",
    support: "Technical issues"
  })
}

with {:ok, response} <- Jevex.evaluate(client, message, questions, on_error: backup) do
  {:ok, response.answers["department"].choice, response.usage}
end
```

Dynamic response IDs and choice values stay strings; syntax restores the
declared atom or string choice key. For a reusable named batch with a generated
result struct, use `Jevex.Schema`. Neither advanced interface changes provider
configuration. `Jevex.HTTP.post/3` is the lower request layer for integrations
that need a normalized response map and will handle answer validation themselves.
