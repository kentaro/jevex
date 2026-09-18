# Jevex

Jevex is an Elixir client for Jev probabilistic evaluations, with an optional
macro DSL for reusable, typed schemas. It keeps HTTP requests, backend protocols,
response validation, and schema syntax separate.

It includes adapters for the official TypeSafe API, ロリポップ！AIゲートウェイ,
OpenRouter, Cloudflare Workers AI, Vercel AI Gateway, and custom native endpoints.
These use each service's evaluation protocol; they are not generic Chat
Completions adapters. See the [backend guide](guides/backends.md) for endpoint,
model, authentication, and protocol limitations.

## Installation

Requires Elixir 1.17 or later and an OTP version supported by your Elixir release.
This project has **not been published to Hex**. Add the delivered source as a path
dependency in your application's `mix.exs`:

```elixir
defp deps do
  [
    {:jevex, path: "../jevex"}
  ]
end
```

Adjust the path to the actual checkout, then run `mix deps.get`.

## Quick start

Declare questions in a module. Schema declarations contain no credentials or
backend settings, so the same schema works with different clients.

```elixir
defmodule MyApp.Triage do
  use Jevex.Schema

  noul :urgent, "Does this ticket require immediate action?"

  choice :department, "Which team should handle this ticket?", %{
    billing: "Invoices, charges, and payments",
    support: "Technical problems and outages"
  }

  score :severity, "How severe is the problem?", [
    "Minor inconvenience",
    "Important functionality impaired",
    "Service unavailable"
  ]
end
```

Provide `LOLIPOP_AI_GATEWAY_API_KEY` in the process environment, then evaluate:

```elixir
with {:ok, client} <- Jevex.Client.new(backend: :lolipop),
     {:ok, result} <- MyApp.Triage.evaluate(client, %{
       subject: "Checkout is down",
       body: "Nobody can complete a purchase."
     }) do
  case result do
    %MyApp.Triage{
      urgent: %Jevex.Answer.Noul{noul: probability},
      department: %Jevex.Answer.Choice{choice: :support}
    } when probability >= 0.8 ->
      {:escalate, result.severity.score}

    %MyApp.Triage{department: %Jevex.Answer.Choice{choice: team}} ->
      {:route, team}
  end
else
  {:error, %Jevex.Error{kind: kind, message: message}} ->
    {:evaluation_failed, kind, message}
end
```

A noul is a **yes probability between 0 and 1**, not a boolean. A score is numeric,
within `0..(number_of_levels - 1)`; three levels mean scores between 0 and 2,
including fractional scores. The schema result contains answer structs, not
unwrapped scalars. Confidence and probability distributions may be `nil` on
protocols that omit them; do not infer confidence from missing metadata.

Schema choice keys declared as atoms become declared atoms in `answer.choice`.
String choices stay strings. `answer.probabilities` always retains string keys:

```elixir
# For a schema choice declared as %{billing: "...", support: "..."}:
# result.department.choice          => :billing
# result.department.probabilities   => %{"billing" => 0.8, "support" => 0.2}
```

`MyApp.Triage.evaluate!/2` returns the schema struct or raises `Jevex.Error`.
`MyApp.Triage.questions/0` exposes the validated question map for direct requests.

### 日本語クイックスタート

質問を `use Jevex.Schema` のモジュールに宣言し、接続先は実行時に指定します。
ロリポップ！AIゲートウェイは `backend: :lolipop` を指定し、環境変数
`LOLIPOP_AI_GATEWAY_API_KEY` に API キーを設定してください。

```elixir
defmodule Inquiry do
  use Jevex.Schema
  noul :urgent, "すぐに対応が必要ですか？"
  choice :team, "どの担当に振り分けますか？", %{
    billing: "請求・支払い",
    support: "技術的な問い合わせ"
  }
  score :severity, "影響の大きさは？", ["小さい", "大きい"]
end

client = Jevex.Client.new!(backend: :lolipop)
# API 呼び出しが発生します。
{:ok, result} = Inquiry.evaluate(client, "支払いが二重に請求されています")
# result.urgent.noul は 0〜1 の確率です。
# result.team.choice は :billing または :support です。
```

マクロの引数にはリテラルだけを指定します。動的な質問は次の低レイヤー API を
使って組み立てます。型仕様による静的解析に加え、外部レスポンスは実行時に検証します。
モデルの判断内容が正しいことまで保証する仕組みではありません。

## Direct API: dynamic questions and full metadata

The macro layer is optional. Use constructors and the client directly when
questions are assembled at runtime or when you need model and token usage data:

```elixir
questions = %{
  "urgent" => Jevex.Question.noul!("Is immediate action needed?"),
  "team" => Jevex.Question.choice!("Responsible team?", %{
    "billing" => "Invoices and payments",
    "support" => "Technical issues"
  })
}

client = Jevex.Client.new!(backend: :typesafe)

case Jevex.evaluate(client, "My invoice was charged twice", questions) do
  {:ok, %Jevex.Response{answers: answers, model: model, usage: usage}} ->
    {answers["team"].choice, model, usage}

  {:error, %Jevex.Error{} = error} ->
    {:error, error}
end
```

Direct answer IDs and choice values remain strings; atom conversion is only a
schema convenience. `Jevex.evaluate!/3` raises on failure. Question constructors
also have non-bang variants, such as `Jevex.Question.choice/2`, returning tagged
results. Instructions and rubric entries support JSON strings, objects, arrays,
and `nil`; state must be a string, JSON object, or array that Jason can encode.
Top-level state structs and scalar numbers/booleans are rejected.

For lower-level integration, `Jevex.HTTP.post/3` handles the request and backend
normalization but does **not** decode typed answers. Normally use
`Jevex.evaluate/3`, which adds `Jevex.Response` validation.

## Fallbacks and confidence gates

Evaluation options are per call. They are independent of transport retries and
work with both schemas and `Jevex.evaluate/4`:

```elixir
primary = Jevex.Client.new!(
  backend: :lolipop,
  api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"}
)

backup = Jevex.Client.new!(
  backend: :typesafe,
  api_key: {:system, "TYPESAFE_API_KEY"}
)

MyApp.Triage.evaluate(primary, "Checkout is down",
  on_error: backup,
  on_low_confidence: backup,
  min_confidence: 0.8,
  min_noul_certainty: 0.9
)
```

`on_error` applies to transport failures and HTTP 429, 529, or 5xx after the
primary client exhausts its retries. Authentication, validation, and malformed
response errors do not trigger it. `on_low_confidence` applies
when an otherwise valid result misses a configured gate. `min_confidence` checks
Choice and Score confidence (0..1); missing confidence fails a configured gate.
`min_noul_certainty` checks `max(p, 1 - p)` for noul answers and accepts thresholds
between 0.5 and 1. A strong "no" is therefore certain even though its yes
probability is low. Without a configured gate, valid probabilities are returned
without this application-level filtering.

`on_low_confidence` requires at least one confidence threshold.

Fallbacks do not recursively trigger further fallbacks. The backup must satisfy
the same confidence gates; an insufficient backup result returns a
`:low_confidence` error. A fallback can also be a one-argument callback:

```elixir
MyApp.Triage.evaluate(primary, "Checkout is down",
  on_error: fn %{state: state, questions: questions} ->
    Jevex.evaluate(backup, state, questions)
  end
)
```

The callback receives a map containing `reason` (`:error` or `:low_confidence`),
`error`, `response`, `state`, `questions`, and the primary `client`. `error` is
present for an error; `response` contains the validated result for low confidence.
It must return `{:ok, %Jevex.Response{}}` or `{:error, %Jevex.Error{}}`, including
when called through a schema. Return direct-API answers with string IDs and choice
values, not a schema struct. Successful callback responses are validated again
and must satisfy the configured gates. Callbacks execute in the caller's process;
they should implement an explicit recovery policy.

## Configuration

Application-wide defaults can be supplied in `config/runtime.exs`:

```elixir
import Config

config :jevex, :client,
  backend: :lolipop,
  api_key: {:system, "LOLIPOP_AI_GATEWAY_API_KEY"},
  timeout: 30_000,
  connect_timeout: 5_000,
  max_retries: 2
```

Construct an immutable client from those defaults, or override individual options:

```elixir
client = Jevex.Client.new!()
short_timeout_client = Jevex.Client.new!(timeout: 5_000, max_retries: 0)

# Switching backends selects that provider's defaults, including its key variable.
other_client = Jevex.Client.new!(
  backend: :openrouter,
  api_key: {:system, "OPENROUTER_API_KEY"}
)
```

Explicit options override application defaults, which override backend defaults.
Changing `backend` clears inherited provider-specific key, endpoint, model and
account settings, so a default provider's credential is not sent to another one.
An environment credential is read on every request; a missing key is reported
when requesting, not when constructing the client. Literal strings and zero-arity
credential functions are also supported. Avoid putting secrets in source code.

Useful runtime limits include `max_request_bytes` (default 1 MiB),
`max_response_bytes` (4 MiB), and `max_retry_delay` (30,000 ms). Timeouts apply per
attempt; retries can extend total elapsed time. See [reliability](guides/reliability.md).

## Type guarantees and boundaries

- Invalid schema declarations fail compilation: empty schemas, duplicate or
  reserved fields, invalid rubrics, colliding choice keys, and nonliteral inputs.
- Generated structs require all fields and have a `t/0` typespec. Atom choices
  produce types such as `Jevex.Answer.Choice.t(:billing | :support)`.
- Elixir remains dynamically typed. Typespecs support tools such as Dialyzer;
  they do not prevent arbitrary caller code from constructing invalid structs.
- Individual string literals and probability bounds cannot be expressed by
  these typespecs. Runtime validation enforces choice membership, answer types,
  required coverage, numeric bounds, and supplied probability distributions.
- Schema decoding never creates atoms from external strings. It uses only
  choice atoms already present in the declaration.
- Response validation guarantees protocol conformance, not the truth, accuracy,
  calibration, or suitability of a model's judgment.

## Running the example and checks

From this project's directory:

```sh
mix deps.get
mix run examples/triage.exs          # Deterministic fixture; no API key or network
mix run examples/triage.exs --live   # One real request to Lolipop; requires its key
mix test
mix format --check-formatted
mix compile --warnings-as-errors
mix docs --warnings-as-errors
mix dialyzer
```

The offline example validates the same client, request, decoder, and schema path
using an injected transport. It is not evidence of a successful live service call.

Read the [architecture guide](guides/architecture.md), [backend guide](guides/backends.md),
and [reliability guide](guides/reliability.md) for the full contracts.

## License

MIT. See `LICENSE`.
