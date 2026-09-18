defmodule Jevex.Backends.Native do
  @moduledoc false
  @spec encode(String.t(), term(), map()) :: map()
  def encode(model, state, questions),
    do: %{"model" => model, "state" => state, "questions" => questions}

  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  def decode(body) when is_map(body), do: {:ok, body}

  def decode(_),
    do: {:error, %Jevex.Error{kind: :response, message: "backend response must be a JSON object"}}
end

defmodule Jevex.Backends.TypeSafe do
  @moduledoc "Direct TypeSafe System One API. Uses `jev-latest` and the native question protocol."
  @behaviour Jevex.Backend
  @impl true
  @spec defaults(keyword()) :: {:ok, Jevex.Backend.defaults()} | {:error, Jevex.Error.t()}
  def defaults(_opts),
    do: {:ok, %{endpoint: "https://api.typesafe.ai/v1/systemone", model: "jev-latest"}}

  @impl true
  @spec encode(String.t(), term(), map()) :: map()
  defdelegate encode(model, state, questions), to: Jevex.Backends.Native
  @impl true
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(_model), do: []
  @impl true
  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  defdelegate decode(body), to: Jevex.Backends.Native
  @impl true
  @spec partial_metadata?() :: boolean()
  def partial_metadata?, do: false
end

defmodule Jevex.Backends.Lolipop do
  @moduledoc """
  ロリポップ！AIゲートウェイ's native `/v1/systemone` API.

  Defaults to `typesafe/jev-latest`. An explicit `model: "auto"` asks the gateway
  to choose an available probabilistic-decision model.
  """
  @behaviour Jevex.Backend
  @impl true
  @spec defaults(keyword()) :: {:ok, Jevex.Backend.defaults()} | {:error, Jevex.Error.t()}
  def defaults(_opts),
    do:
      {:ok,
       %{endpoint: "https://ai-gateway.lolipop.jp/v1/systemone", model: "typesafe/jev-latest"}}

  @impl true
  @spec encode(String.t(), term(), map()) :: map()
  defdelegate encode(model, state, questions), to: Jevex.Backends.Native
  @impl true
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(_model), do: []
  @impl true
  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  defdelegate decode(body), to: Jevex.Backends.Native
  @impl true
  @spec partial_metadata?() :: boolean()
  def partial_metadata?, do: false
end

defmodule Jevex.Backends.OpenRouter do
  @moduledoc """
  OpenRouter's alpha Decisions endpoint, which is separate from Chat Completions.

  Uses the pinned `typesafe/jev-1.13` model. This alpha contract permits omitted
  answer metadata; Jevex preserves absent confidence and probabilities as nil.
  """
  @behaviour Jevex.Backend
  @impl true
  @spec defaults(keyword()) :: {:ok, Jevex.Backend.defaults()} | {:error, Jevex.Error.t()}
  def defaults(_opts),
    do:
      {:ok, %{endpoint: "https://openrouter.ai/api/alpha/decisions", model: "typesafe/jev-1.13"}}

  @impl true
  @spec encode(String.t(), term(), map()) :: map()
  defdelegate encode(model, state, questions), to: Jevex.Backends.Native
  @impl true
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(_model), do: []
  @impl true
  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  defdelegate decode(body), to: Jevex.Backends.Native
  @impl true
  @spec partial_metadata?() :: boolean()
  def partial_metadata?, do: true
end

defmodule Jevex.Backends.Cloudflare do
  @moduledoc """
  Cloudflare Workers AI REST `/ai/run` adapter for `typesafe/jev`.

  Supply `account_id: "your-account-id"`. Only ASCII letters, numbers, hyphens,
  and underscores are accepted, preventing account IDs from altering URL paths.
  The token requires Account > Workers AI > Read permission. The request wraps
  native state and questions in `input`; responses may be direct or use the
  standard Cloudflare `success`/`result` envelope.
  """
  @behaviour Jevex.Backend
  @impl true
  @spec defaults(keyword()) :: {:ok, Jevex.Backend.defaults()} | {:error, Jevex.Error.t()}
  def defaults(opts) do
    case Keyword.get(opts, :account_id) do
      account when is_binary(account) ->
        if Regex.match?(~r/\A[A-Za-z0-9_-]{1,128}\z/, account) do
          {:ok,
           %{
             endpoint: "https://api.cloudflare.com/client/v4/accounts/#{account}/ai/run",
             model: "typesafe/jev"
           }}
        else
          invalid_account()
        end

      _ ->
        invalid_account()
    end
  end

  @impl true
  @spec encode(String.t(), term(), map()) :: map()
  def encode(model, state, questions),
    do: %{"model" => model, "input" => %{"state" => state, "questions" => questions}}

  @impl true
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(_model), do: []
  @impl true
  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  def decode(%{"success" => true, "result" => result}) when is_map(result), do: {:ok, result}

  def decode(%{"success" => _}),
    do:
      {:error,
       %Jevex.Error{
         kind: :response,
         message: "Cloudflare returned an unsuccessful or invalid envelope"
       }}

  def decode(body), do: Jevex.Backends.Native.decode(body)
  @impl true
  @spec partial_metadata?() :: boolean()
  def partial_metadata?, do: false

  defp invalid_account,
    do:
      {:error,
       %Jevex.Error{
         kind: :configuration,
         message:
           "cloudflare account_id must be a nonempty ASCII URL segment of at most 128 characters"
       }}
end

defmodule Jevex.Backends.Vercel do
  @moduledoc """
  Vercel AI Gateway's experimental v4 evaluation-model protocol.

  Model selection uses `ai-model-id`; the JSON body contains state and questions.
  Native `noul` questions become `boolean`, and boolean answer probabilities are
  converted back to `noul`. Usage keys are normalized to snake_case. Missing
  confidence, distributions, and usage stay absent. This protocol follows the
  official AI SDK implementation and can change independently of Chat Completions.
  """
  @behaviour Jevex.Backend
  @impl true
  @spec defaults(keyword()) :: {:ok, Jevex.Backend.defaults()} | {:error, Jevex.Error.t()}
  def defaults(_opts),
    do:
      {:ok,
       %{
         endpoint: "https://ai-gateway.vercel.sh/v4/ai/evaluation-model",
         model: "typesafe-ai/jev"
       }}

  @impl true
  @spec encode(String.t(), term(), map()) :: map()
  def encode(_model, state, questions) do
    questions =
      Map.new(questions, fn
        {id, %{"type" => "noul"} = question} -> {id, Map.put(question, "type", "boolean")}
        pair -> pair
      end)

    %{"state" => state, "questions" => questions}
  end

  @impl true
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(model),
    do: [
      {"ai-model-id", model},
      {"ai-evaluation-model-specification-version", "4"},
      {"ai-gateway-protocol-version", "0.0.1"},
      {"ai-gateway-auth-method", "api-key"}
    ]

  @impl true
  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  def decode(%{"answers" => answers} = body) when is_map(answers) do
    answers =
      Map.new(answers, fn
        {id, %{"type" => "boolean", "probability" => probability}} ->
          {id, %{"type" => "noul", "noul" => probability}}

        pair ->
          pair
      end)

    body = Map.put(body, "answers", answers)

    body =
      case Map.fetch(body, "usage") do
        {:ok, usage} when is_map(usage) ->
          normalized =
            usage
            |> rename("inputTokens", "input_tokens")
            |> rename("outputTokens", "output_tokens")

          Map.put(body, "usage", normalized)

        _ ->
          body
      end

    {:ok, body}
  end

  def decode(_),
    do:
      {:error,
       %Jevex.Error{kind: :response, message: "Vercel response must contain an answers object"}}

  @impl true
  @spec partial_metadata?() :: boolean()
  def partial_metadata?, do: true

  defp rename(map, old, new) do
    case Map.fetch(map, old) do
      :error -> map
      {:ok, value} -> map |> Map.delete(old) |> Map.put(new, value)
    end
  end
end

defmodule Jevex.Backends.Custom do
  @moduledoc "Native System One protocol with an explicitly configured endpoint and model."
  @behaviour Jevex.Backend
  @impl true
  @spec defaults(keyword()) :: {:ok, Jevex.Backend.defaults()} | {:error, Jevex.Error.t()}
  def defaults(_opts), do: {:ok, %{endpoint: nil, model: nil}}
  @impl true
  @spec encode(String.t(), term(), map()) :: map()
  defdelegate encode(model, state, questions), to: Jevex.Backends.Native
  @impl true
  @spec headers(String.t()) :: [{String.t(), String.t()}]
  def headers(_model), do: []
  @impl true
  @spec decode(term()) :: {:ok, map()} | {:error, Jevex.Error.t()}
  defdelegate decode(body), to: Jevex.Backends.Native
  @impl true
  @spec partial_metadata?() :: boolean()
  def partial_metadata?, do: false
end
