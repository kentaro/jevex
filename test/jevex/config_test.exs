defmodule Jevex.ConfigTest do
  use ExUnit.Case, async: false

  test "explicit client settings override application defaults" do
    original = Application.fetch_env(:jevex, :client)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:jevex, :client, value)
        :error -> Application.delete_env(:jevex, :client)
      end
    end)

    Application.put_env(:jevex, :client, backend: :lolipop, model: "auto", timeout: 1234)
    assert {:ok, c} = Jevex.Client.new(model: "typesafe/jev-latest")
    assert c.backend == Jevex.Backends.Lolipop
    assert c.model == "typesafe/jev-latest"
    assert c.timeout == 1234

    Application.put_env(:jevex, :client,
      backend: :lolipop,
      api_key: "private-lolipop-key",
      endpoint: "https://ai-gateway.lolipop.jp/v1/systemone",
      model: "auto",
      timeout: 1234
    )

    assert {:ok, other} = Jevex.Client.new(backend: :typesafe)
    assert other.api_key == {:system, "TYPESAFE_API_KEY"}
    assert other.endpoint == "https://api.typesafe.ai/v1/systemone"
    assert other.model == "jev-latest"
    assert other.timeout == 1234
    Application.put_env(:jevex, :client, :invalid)
    assert {:error, _} = Jevex.Client.new()
  end
end
