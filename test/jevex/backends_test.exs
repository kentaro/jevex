defmodule Jevex.BackendsTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error, Question}

  defmodule Transport do
    @behaviour Jevex.Transport
    @impl true
    def request(request, _client) do
      send(self(), {:backend_request, request})
      {:ok, %{status: 200, headers: %{}, body: Jason.encode!(Process.get(:backend_body))}}
    end
  end

  defp client(backend, opts \\ []) do
    Client.new!(
      Keyword.merge([backend: backend, api_key: "backend-test-key", transport: Transport], opts)
    )
  end

  defp questions, do: %{urgent: Question.noul!("Urgent?")}

  defp native do
    %{
      "model" => "reported-model",
      "answers" => %{"urgent" => %{"type" => "noul", "noul" => 0.8}},
      "usage" => %{"input_tokens" => 12, "output_tokens" => 3}
    }
  end

  defp request_body do
    assert_receive {:backend_request, request}
    assert {"authorization", "Bearer backend-test-key"} in request.headers
    assert {"content-type", "application/json"} in request.headers
    {request, Jason.decode!(request.body)}
  end

  test "native backends send their dedicated endpoints and model identifiers" do
    for {backend, url, model, opts} <- [
          {:typesafe, "https://api.typesafe.ai/v1/systemone", "jev-latest", []},
          {:lolipop, "https://ai-gateway.lolipop.jp/v1/systemone", "typesafe/jev-latest", []},
          {:openrouter, "https://openrouter.ai/api/alpha/decisions", "typesafe/jev-1.13", []},
          {:custom, "http://127.0.0.1:9876/inference", "private-jev",
           [endpoint: "http://127.0.0.1:9876/inference", model: "private-jev"]}
        ] do
      Process.put(:backend_body, native())
      assert {:ok, response} = Jevex.evaluate(client(backend, opts), "hello", questions())
      assert response.model == "reported-model"
      assert response.answers["urgent"].noul == 0.8
      {request, body} = request_body()
      assert request.url == url

      assert body == %{
               "model" => model,
               "state" => "hello",
               "questions" => %{"urgent" => %{"type" => "noul", "instructions" => "Urgent?"}}
             }

      refute Enum.any?(request.headers, fn {key, _} -> String.starts_with?(key, "ai-") end)
    end
  end

  test "Lolipop auto and model overrides reach the native body" do
    Process.put(:backend_body, native())
    assert {:ok, _} = Jevex.evaluate(client(:lolipop, model: "auto"), "hello", questions())
    {_request, body} = request_body()
    assert body["model"] == "auto"
  end

  test "Cloudflare wraps input and accepts direct and success-envelope responses" do
    for response <- [native(), %{"success" => true, "result" => native()}] do
      Process.put(:backend_body, response)

      assert {:ok, result} =
               Jevex.evaluate(
                 client(:cloudflare, account_id: "account_123-abc"),
                 %{ticket: 1},
                 questions()
               )

      assert result.answers["urgent"].noul == 0.8
      {request, body} = request_body()
      assert request.url == "https://api.cloudflare.com/client/v4/accounts/account_123-abc/ai/run"

      assert body == %{
               "model" => "typesafe/jev",
               "input" => %{
                 "state" => %{"ticket" => 1},
                 "questions" => %{"urgent" => %{"type" => "noul", "instructions" => "Urgent?"}}
               }
             }
    end
  end

  test "Cloudflare malformed IDs fail configuration before transport" do
    for account <- [
          nil,
          "",
          "../escape",
          "a/b",
          "a?b",
          "a#b",
          "a%2Fb",
          "a\nb",
          "a b",
          "日本",
          String.duplicate("a", 129)
        ] do
      assert {:error, %Error{kind: :configuration}} =
               Client.new(
                 backend: :cloudflare,
                 account_id: account,
                 api_key: "key",
                 transport: Transport
               )
    end

    refute_receive {:backend_request, _}
  end

  test "Cloudflare failure envelopes never become successful evaluations" do
    for body <- [
          %{"success" => false, "result" => native()},
          %{"success" => true, "result" => []}
        ] do
      Process.put(:backend_body, body)

      assert {:error, %Error{kind: :response}} =
               Jevex.evaluate(client(:cloudflare, account_id: "abc"), "hello", questions())

      request_body()
    end
  end

  test "Vercel places model in headers, transforms noul, and normalizes usage" do
    Process.put(:backend_body, %{
      "answers" => %{"urgent" => %{"type" => "boolean", "probability" => 0.75}},
      "usage" => %{"inputTokens" => 10, "outputTokens" => 4}
    })

    assert {:ok, result} =
             Jevex.evaluate(client(:vercel, model: "typesafe-ai/jev"), "hello", questions())

    assert result.model == nil
    assert result.usage == %{"input_tokens" => 10, "output_tokens" => 4}
    assert result.answers["urgent"].noul == 0.75
    {request, body} = request_body()
    assert request.url == "https://ai-gateway.vercel.sh/v4/ai/evaluation-model"

    for header <- [
          {"ai-model-id", "typesafe-ai/jev"},
          {"ai-evaluation-model-specification-version", "4"},
          {"ai-gateway-protocol-version", "0.0.1"},
          {"ai-gateway-auth-method", "api-key"}
        ] do
      assert header in request.headers
    end

    assert body == %{
             "state" => "hello",
             "questions" => %{"urgent" => %{"type" => "boolean", "instructions" => "Urgent?"}}
           }

    refute Map.has_key?(body, "model")
  end

  test "Vercel supports all question types without inventing optional metadata" do
    qs = %{
      urgent: Question.noul!("Urgent?", %{true: "now", false: "later"}),
      route: Question.choice!("Team?", %{billing: "Money", other: nil}),
      risk: Question.score!("Risk?", ["Low", "High"])
    }

    Process.put(:backend_body, %{
      "answers" => %{
        "urgent" => %{"type" => "boolean", "probability" => 0.6},
        "route" => %{"type" => "choice", "choice" => "billing"},
        "risk" => %{"type" => "score", "score" => 0.3}
      }
    })

    assert {:ok, result} = Jevex.evaluate(client(:vercel), "hello", qs)
    assert result.model == nil
    assert result.usage == nil
    assert result.answers["route"].probabilities == nil
    assert result.answers["route"].confidence == nil
    assert result.answers["risk"].probabilities == nil
    assert result.answers["risk"].confidence == nil
    assert result.answers["risk"].legend == %{"0" => "Low", "1" => "High"}
    {_request, body} = request_body()
    assert body["questions"]["urgent"]["criteria"] == %{"true" => "now", "false" => "later"}
    assert body["questions"]["route"]["type"] == "choice"
    assert body["questions"]["risk"]["type"] == "score"
  end

  test "OpenRouter accepts omitted decision metadata while native backends reject it" do
    qs = %{route: Question.choice!("Team?", %{billing: nil, other: nil})}
    body = %{native() | "answers" => %{"route" => %{"type" => "choice", "choice" => "billing"}}}
    Process.put(:backend_body, body)
    assert {:ok, result} = Jevex.evaluate(client(:openrouter), "hello", qs)
    assert result.answers["route"].confidence == nil
    request_body()

    for backend <- [:typesafe, :lolipop] do
      assert {:error, %Error{kind: :response}} = Jevex.evaluate(client(backend), "hello", qs)
      request_body()
    end
  end

  test "Vercel malformed response objects and boolean probabilities are rejected" do
    for body <- [
          %{},
          %{"answers" => []},
          %{"answers" => %{"urgent" => %{"type" => "boolean", "probability" => 1.2}}},
          %{"answers" => %{"urgent" => %{"type" => "boolean"}}},
          %{
            "answers" => %{"urgent" => %{"type" => "boolean", "probability" => 0.9}},
            "usage" => %{"inputTokens" => nil, "outputTokens" => 1}
          }
        ] do
      Process.put(:backend_body, body)

      assert {:error, %Error{kind: :response}} =
               Jevex.evaluate(client(:vercel), "hello", questions())

      request_body()
    end
  end
end
