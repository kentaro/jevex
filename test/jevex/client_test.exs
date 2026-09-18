defmodule Jevex.ClientTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error}

  test "all built-in backends resolve configurable defaults" do
    for backend <- [:typesafe, :lolipop, :openrouter, :vercel] do
      assert {:ok, c} = Client.new(backend: backend)
      assert String.starts_with?(c.endpoint, "https://")

      assert {:ok, override} =
               Client.new(
                 backend: backend,
                 model: "pinned",
                 endpoint: "https://example.com/evaluate"
               )

      assert override.model == "pinned"
    end

    assert {:ok, _} = Client.new(backend: :cloudflare, account_id: "abc123")
    assert {:error, _} = Client.new(backend: :cloudflare, account_id: "../bad")
    assert {:error, _} = Client.new(backend: :cloudflare)
    assert {:error, _} = Client.new(backend: :custom)

    assert {:ok, _} =
             Client.new(backend: :custom, endpoint: "http://127.0.0.1:1234/eval", model: "test")
  end

  test "bad options and insecure endpoints are rejected" do
    for opts <- [
          [backend: :bad],
          [timeout: 0],
          [connect_timeout: -1],
          [max_retries: 11],
          [max_retry_delay: -1],
          [max_response_bytes: 0],
          [transport: String],
          [model: "bad\nheader"],
          [api_key: "bad\nkey"],
          [wat: 1],
          :bad
        ] do
      assert {:error, %Error{kind: :configuration}} = Client.new(opts)
    end

    for endpoint <- [
          "http://example.com",
          "https://user:password@example.com",
          "https://example.com?secret=a",
          "https://example.com#f",
          "relative",
          "https://",
          "https://example.com:nope",
          "https://example.com:99999",
          <<255>>
        ] do
      assert {:error, _} = Client.new(endpoint: endpoint)
    end

    assert_raise Error, fn -> Client.new!(timeout: 0) end
    assert {:error, _} = Client.new(model: <<255>>)
  end

  test "client inspection hides credentials, callback closures and endpoints" do
    c = Client.new!(api_key: "TOPSECRET", endpoint: "https://example.com/secretpath")
    refute inspect(c) =~ "TOPSECRET"
    refute inspect(c) =~ "secretpath"
    assert inspect(c) =~ "TypeSafe"
  end
end
