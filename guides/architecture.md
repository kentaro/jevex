# Architecture

Jevex separates syntax from requests. `Jevex.Schema` compiles declarations into
ordinary questions, a result struct, and small functions that call `Jevex.evaluate/3`.
It does not own HTTP, authentication, retries, or provider-specific behavior.

## Evaluation path

```text
Schema.evaluate(client, state)              Dynamic question constructors
          |                                           |
          +------------> Jevex.evaluate/3 <-----------+
                                  |
                         Jevex.HTTP.request/3
                      validation / JSON / credentials
                      retry policy / response limits
                                  |
                      Jevex.Backend implementation
                    endpoint / model / protocol mapping
                                  |
                        Jevex.Transport.request/2
                         Req POST by default
                                  |
                      backend JSON normalization
                                  |
                         Jevex.Response.decode/3
                    coverage / types / bounds / metadata
                                  |
                        %Jevex.Response{answers: ...}
                                  |
                   schema field and choice lookup tables
                                  |
                            %YourSchema{}
```

The macro path returns only the schema result. The direct path retains model,
usage, and all typed answers in `Jevex.Response`. Use the direct API with
`YourSchema.questions/0` if both reusable declarations and response metadata are
needed.

## Contracts by layer

| Layer | Responsibility | Output |
| --- | --- | --- |
| `Jevex.Question` | Validate question kinds, instructions, and rubrics | Valid question structs and native JSON maps |
| `Jevex.Client` | Validate runtime backend, endpoint, credentials source, and limits | Immutable client |
| `Jevex.HTTP` | Validate inputs, encode requests, resolve credentials, retry, bound responses | Backend-normalized JSON map or error |
| `Jevex.Backend` | Map native questions to a provider protocol and normalize responses | Protocol defaults and JSON transformation |
| `Jevex.Transport` | Perform a POST request with configured time/size limits | HTTP status, headers, raw body |
| `Jevex.Response` | Validate returned answers against their requested questions | `Jevex.Response` with typed answers |
| `Jevex.Schema` | Compile declarations and map validated answers into named fields | User-defined result struct |

`Jevex.HTTP.post/3` is intentionally lower level than `Jevex.evaluate/3`: it does
not provide typed answer validation. Applications should ordinarily use the latter.
Question IDs are normalized to strings before a request. Ambiguous IDs, such as
`:urgent` and `"urgent"` in the same map, are rejected.

## Schema compilation

`use Jevex.Schema` imports `noul/2`, `noul/3`, `choice/3`, and `score/3`. Each macro
parses literal AST without evaluating user expressions. It validates the field
name, rejects duplicate declarations, and delegates question validation to
`Jevex.Question`. The before-compile callback emits:

1. A struct with every declared field in `@enforce_keys`.
2. A `t/0` typespec with the answer type for each field.
3. `questions/0`, returning the validated low-level map.
4. `evaluate/2,3` and `evaluate!/2,3`, delegating requests and evaluation options
   to `Jevex.evaluate/4`.

Module attributes, function calls, interpolation, and other computed arguments
are deliberately unsupported. Dynamic input belongs in the direct API. This also
means macro expansion cannot run a supplied expression as a side effect.

Atom choice keys compile into a closed string-to-atom lookup table. The native
response decoder first verifies membership; the schema then restores the declared
atom for the selected choice. String choices remain strings, and probabilities
retain string keys, even when the selected choice is an atom.

Typespecs express atom unions precisely but use `String.t()` for string choices
and `number()` for probabilities. Runtime checks handle constraints that these
specs cannot express. Neither structs nor typespecs prevent a caller from manually
constructing invalid values; constructors and validated evaluation functions are
the supported boundaries.

## Evaluation policy

Confidence gates and fallbacks belong to `Jevex.evaluate`, above HTTP and response
validation. They work for both dynamic questions and schemas. Transport retries
handle retryable HTTP statuses; evaluation fallback can select another client or
invoke an application callback after a transport/transient HTTP error or
insufficient confidence. Authentication, validation, and malformed-response
failures do not trigger error fallback.

A `min_confidence` gate applies to Choice and Score answers. Missing confidence
fails the gate. Noul answers use a separate `min_noul_certainty` gate based on
`max(p, 1 - p)`; certainty is distinct from the probability of "yes". Fallback is
one step, and its result must satisfy the configured gates. There is no recursive
fallback chain. Only after evaluation and its policy succeed does the schema
convert declared fields and choices.

## Runtime configuration

Schemas are provider-independent. Backend and transport selection lives in
`Jevex.Client`, allowing one schema to run against multiple providers without
recompilation. `Client.new/1` merges application configuration and explicit options
with backend defaults. Existing client structs do not change when application
configuration changes; build a new client to pick up new configuration.

Credentials supplied as `{:system, name}` or a zero-arity function are resolved on
every request. The schema never reads or embeds a credential. Each request runs
synchronously in the caller's process; there is no background request queue,
schema process, or DSL-owned supervision tree.

## Extending and testing

A custom endpoint using the native protocol can use `backend: :custom` with an
explicit full `endpoint` and `model`. A different protocol implements
`Jevex.Backend`: `defaults/1`, `encode/3`, `headers/1`, `decode/1`, and
`partial_metadata?/0`. It must preserve the meaning of missing metadata rather
than manufacture confidence or token counts. The HTTP layer supplies bearer
authentication, and the response layer supplies final semantic validation.

For isolated tests, implement `Jevex.Transport` and pass `transport: MyTransport`.
The transport receives encoded JSON plus client settings, and returns raw JSON
with status and headers. This exercises the real encoder, decoder, and schema
without external services. `examples/triage.exs` demonstrates this approach.

Tests cover compile-time schema failures, response shape and probability checks,
backend transformations, error handling, and the injected HTTP boundary. Live
service compatibility additionally requires authenticated requests; passing
fixture tests alone does not establish it. See the backend and reliability guides
for protocol-specific caveats and request limits.
