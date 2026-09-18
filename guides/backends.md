# Backend configuration

The schema describes questions, and the client selects a backend at runtime.
A schema never embeds an API key, URL, or provider.

```elixir
primary = Jevex.Client.new!(backend: :lolipop)
backup = Jevex.Client.new!(backend: :typesafe)

Ticket.evaluate(primary, ticket,
  on_error: backup,
  min_confidence: 0.8,
  min_noul_certainty: 0.9,
  on_low_confidence: backup
)
```

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
  backend: :lolipop,
  api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"},
  timeout: 15_000,
  max_retries: 2
```

`Jevex.Client.new!()` reads these defaults when constructed. Explicit options
win. Existing clients remain unchanged when application settings change;
switching `backend` explicitly clears inherited credentials, endpoint, model and
account ID and uses the new provider's defaults unless explicitly supplied.
credential environment variables are resolved afresh on every evaluation.
Retries for one evaluation use its originally resolved credential.

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
