# Verified backend contracts

This is the wire-reference companion to [backend configuration](backends.md).
Start with `use Jevex` and the official TypeSafe configuration there. Both
`~>` and `~>>`, as well as explicit batched evaluation, pass through the same
adapters described below. The syntax does not assume providers share an HTTP
endpoint or identical response fields.

Checked against public primary sources on 2026-09-18. Jev makes typed decisions;
none of these adapters sends a Chat Completions request. Lolipop was subsequently
verified with authenticated inference; see [Validation](../VALIDATION.md).
Other providers have contract tests but no authenticated live verification.

| Backend | Full POST endpoint | Default model |
| --- | --- | --- |
| TypeSafe | `https://api.typesafe.ai/v1/systemone` | `jev-latest` |
| Lolipop | `https://ai-gateway.lolipop.jp/v1/systemone` | `typesafe/jev-latest` |
| OpenRouter | `https://openrouter.ai/api/alpha/decisions` | `typesafe/jev-1.13` |
| Cloudflare | `https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/run` | `typesafe/jev` |
| Vercel | `https://ai-gateway.vercel.sh/v4/ai/evaluation-model` | `typesafe-ai/jev` |

All requests use JSON and `Authorization: Bearer <credential>`. Credentials are
resolved by the client at request time; adapters never own credentials. `~>`
extracts a scalar after validation, and `~>>` wraps that scalar in an `:ok`
tuple. To inspect the metadata discussed here, use `Jevex.evaluate/4` and its
typed `Jevex.Response` rather than an operator.

## Native protocol: TypeSafe and Lolipop

The request is `{model, state, questions}`. `questions` maps caller-selected IDs
to typed questions. State and instructions accept a string, object, or array.
Question IDs are returned unchanged and are not instructions for the model.

| Question | Criteria | Answer |
| --- | --- | --- |
| `noul` | Optional object with `true` and `false` descriptions | `type`, `noul` probability |
| `choice` | Nonempty option-to-description map; null means no description | `type`, `choice`, `probabilities`, `confidence` |
| `score` | At least two ordered descriptions, indexed from zero | `type`, `score`, `legend`, `probabilities`, `confidence` |

Descriptions support JSON structure as well as text. Choice probabilities cover
all options; score probabilities cover all level indices as strings. A score is
a probability-weighted value and may fall between levels. Confidence describes
the distribution and is not the selected option's probability. Noul does not
return confidence. Responses contain `model`, `answers`, and
`usage: {input_tokens, output_tokens}`.

Lolipop also accepts `model: "auto"`, selecting an available model whose output
modality is `probabilistic_decision`. The fixed default avoids silently opting
into model selection. A temporary launch promotion is not a library guarantee.

Sources:

- [TypeSafe HTTP API](https://docs.typesafe.ai/api)
- [Structured descriptions](https://docs.typesafe.ai/primitives/advanced)
- [Confidence semantics](https://docs.typesafe.ai/confidence)
- [Lolipop probabilistic-decision guide](https://ai-gateway.lolipop.jp/docs/guides/features/probabilistic-decision)
- [Lolipop Jev announcement](https://lolipop.jp/ai/gateway/info/product/2026-09-18/)

## OpenRouter

The alpha Decisions API uses the native body and answer types. It additionally
documents request fields `provider`, `trace`, `session_id`, and `user`, and
response metadata `id`, `provider`, and `usage.cost`. These routing extensions
are not exposed by the initial Jevex client interface. Extend the backend to use
them. The adapter pins `typesafe/jev-1.13`; callers can choose another model.

OpenRouter's schema marks choice and score distributions, confidence, and score
legends as optional. Missing confidence and probabilities become `nil`; a
missing score legend is reconstructed from the question's known rubric. Jevex
does not manufacture certainty. Its OpenAPI score schema permits one level, but Jevex intentionally
retains the native TypeSafe minimum of two.

The endpoint is rooted at `/api/alpha/decisions`, without `/v1`. The documentation
also includes a global `/api/v1` server prefix, which must not be concatenated
to this full path. An unauthenticated route probe returned 401 at the documented
root path and 404 at `/api/v1/alpha/decisions` and
`/api/v1/api/alpha/decisions`. This verifies route presence, not inference.

Sources:

- [Decisions OpenAPI](https://openrouter.ai/docs/api/api-reference/alphadecisions/submit-a-decisions-questions-and-answers-request)
- [Jev model card](https://openrouter.ai/typesafe/jev-1.13/)

## Cloudflare

Requests wrap native state and questions in `input`:

```json
{"model":"typesafe/jev","input":{"state":"A customer message","questions":{"urgent":{"type":"noul","instructions":"Is this urgent?"}}}}
```

The account ID is validated as one ASCII URL segment. Authentication requires
**Account > Workers AI > Read**, including for third-party models. An AI Gateway
management token alone is insufficient. Gateway configuration headers are not
needed by the documented Jev request.

The Jev model page shows a native response object. The adapter also accepts the
standard `{success: true, result: {...}}` envelope and rejects unsuccessful
envelopes. The actual authenticated REST envelope has not been independently
verified; this defensive normalization does not imply every response uses it.

Sources:

- [Cloudflare Jev request and response examples](https://developers.cloudflare.com/ai/models/typesafe/jev/)
- [Cloudflare REST API and token permissions](https://developers.cloudflare.com/ai-gateway/usage/rest-api/)

## Vercel

This adapter follows the official AI SDK's experimental evaluation-model v4
wire implementation. It is separate from Vercel's OpenAI-compatible endpoints.

In addition to bearer authorization, it sends:

```text
ai-model-id: typesafe-ai/jev
ai-evaluation-model-specification-version: 4
ai-gateway-protocol-version: 0.0.1
ai-gateway-auth-method: api-key
```

The body contains `{state, questions}` and has no model field. The SDK also
supports `providerOptions`, which the initial Jevex interface does not expose.

| Native representation | Vercel wire representation |
| --- | --- |
| Question `type: "noul"` | Question `type: "boolean"`; instructions and criteria unchanged |
| Question `choice` or `score` | Unchanged |
| Answer `{type: "noul", noul: p}` | Answer `{type: "boolean", probability: p}` |
| `usage.input_tokens` | `usage.inputTokens` |
| `usage.output_tokens` | `usage.outputTokens` |

Choice and score wire answers may omit probabilities. Confidence and legend do
not appear in the SDK's declared answer schema. Usage is optional, and its two
counts are individually optional. The SDK's response wrapper uses the requested
model ID as metadata; the HTTP response itself need not report a model. Jevex
leaves the actual response model and missing counts unknown instead of claiming
the requested model was necessarily the one used or that absent usage was zero.

The wire schema also permits `rounding`, `warnings`, and `providerMetadata`.
These metadata fields are not guarantees that the evaluated decision is correct.
The adapter normalizes only wire names; final validation and optional-metadata
handling belong to `Jevex.Response`.

Sources:

- [Vercel Jev model card](https://vercel.com/ai-gateway/models/jev)
- [Evaluation adapter and response schema](https://github.com/vercel/ai/blob/main/packages/gateway/src/gateway-evaluation-model.ts)
- [Base URL and authorization headers](https://github.com/vercel/ai/blob/main/packages/gateway/src/gateway-provider.ts)
- [Header names](https://github.com/vercel/ai/blob/main/packages/gateway/src/gateway-headers.ts)
- [Evaluation question types](https://github.com/vercel/ai/blob/main/packages/provider/src/evaluation-model/v4/evaluation-model-v4-question.ts)

## Errors and verification limits

TypeSafe specifically documents 401, 422, 429, and 529; it recommends exponential
backoff for 429 and 529. Provider rate limits and pricing remain external
configuration and must not be hard-coded as timeless facts. These adapters have
source-based contract coverage. Lolipop also has authenticated validation as
recorded in [Validation](../VALIDATION.md); that result does not establish live
compatibility for the other providers.
OpenRouter alpha and Vercel experimental contracts should be rechecked when
upgrading. `Custom` supports a self-hosted native-compatible endpoint, requiring
an explicit endpoint and model; it does not promise compatibility with arbitrary
OpenAI-compatible routers.
