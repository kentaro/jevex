defmodule Jevex.HTTPTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error, HTTP, Question}

  defmodule Transport do
    @behaviour Jevex.Transport
    def request(request, _) do
      send(self(), {:request, request})
      [response | rest] = Process.get(:responses)
      Process.put(:responses, rest)

      case response do
        :raise -> raise "SECRET"
        :exit -> exit(:closed)
        other -> other
      end
    end
  end

  defp client(opts \\ []),
    do: Client.new!([api_key: "secret", transport: Transport, max_retry_delay: 0] ++ opts)

  defp questions, do: %{urgent: Question.noul!("Urgent?")}

  defp reply(status, body \\ "{}", headers \\ %{}),
    do: {:ok, %{status: status, body: body, headers: headers}}

  defp ok_body,
    do:
      Jason.encode!(%{
        model: "jev-latest",
        answers: %{urgent: %{type: "noul", noul: 0.8}},
        usage: %{input_tokens: 1, output_tokens: 1}
      })

  test "low-level HTTP and typed evaluation work without macros" do
    Process.put(:responses, [reply(200, ok_body()), reply(200, ok_body())])
    assert {:ok, %{"answers" => _}} = HTTP.post(client(), "state", questions())

    assert {:ok, %{answers: %{"urgent" => %Jevex.Answer.Noul{noul: 0.8}}}} =
             Jevex.evaluate(client(), "state", questions())

    assert_receive {:request, request}
    assert request.url == "https://api.typesafe.ai/v1/systemone"
    assert {"authorization", "Bearer secret"} in request.headers
    assert Jason.decode!(request.body)["questions"]["urgent"]["type"] == "noul"
  end

  test "429 and 529 retry to the configured bound" do
    Process.put(:responses, [reply(429), reply(529), reply(200, ok_body())])
    assert {:ok, _} = HTTP.post(client(), "state", questions())
    assert Process.get(:responses) == []
    Process.put(:responses, [reply(429), reply(429), reply(529)])
    assert {:error, %Error{status: 529}} = HTTP.post(client(), "state", questions())
  end

  test "Retry-After above cap returns immediately; zero can retry" do
    Process.put(:responses, [reply(429, "{}", %{"retry-after" => ["120"]})])
    assert {:error, %Error{retry_after: 120_000}} = HTTP.post(client(), "state", questions())
    Process.put(:responses, [reply(429, "{}", %{"retry-after" => "0"}), reply(200, "{}")])
    assert {:ok, %{}} = HTTP.post(client(), "state", questions())
  end

  test "HTTP dates and malformed Retry-After are handled" do
    date = DateTime.utc_now() |> DateTime.add(3600) |> Req.Utils.format_http_date()
    Process.put(:responses, [reply(429, "{}", %{"retry-after" => date})])
    assert {:error, %Error{retry_after: delay}} = HTTP.post(client(), "state", questions())
    assert delay > 3_500_000
    Process.put(:responses, [reply(429, "{}", %{"retry-after" => "garbage"}), reply(200)])
    assert {:ok, _} = HTTP.post(client(), "state", questions())
  end

  test "nonretryable HTTP errors have safe metadata and no body" do
    for status <- [301, 400, 401, 403, 422, 500, 503] do
      Process.put(:responses, [reply(status, "secret state", %{"x-request-id" => ["req-123"]})])

      assert {:error, %Error{status: ^status, request_id: "req-123"} = error} =
               HTTP.post(client(), "state", questions())

      refute inspect(error) =~ "secret"
    end
  end

  test "transport failures, exits, and exceptions are sanitized without retry" do
    for failure <- [{:error, "secret"}, :raise, :exit] do
      Process.put(:responses, [failure])

      assert {:error, %Error{kind: :transport} = error} =
               HTTP.post(client(), "state", questions())

      refute inspect(error) =~ "SECRET"
      assert Process.get(:responses) == []
    end
  end

  test "invalid response bytes and shape are rejected" do
    for body <- ["not json", "null", "[]", "123"] do
      Process.put(:responses, [reply(200, body)])
      assert {:error, %Error{kind: :response}} = HTTP.post(client(), "state", questions())
    end

    Process.put(:responses, [{:ok, %{status: 200}}])
    assert {:error, %Error{kind: :response}} = HTTP.post(client(), "state", questions())
    Process.put(:responses, [:unexpected])
    assert {:error, %Error{kind: :response}} = HTTP.post(client(), "state", questions())
  end

  test "input validation occurs before transport" do
    for qs <- [
          %{},
          [],
          [{:urgent, Question.noul!("x")}, {:urgent, Question.noul!("y")}],
          %{:urgent => Question.noul!("x"), "urgent" => Question.noul!("y")},
          %{x: "bad"},
          [{12, "bad"}],
          :invalid
        ] do
      assert {:error, %Error{kind: :validation}} = HTTP.post(client(), "state", qs)
    end

    for state <- [nil, 3, true, {:tuple}, self()] do
      assert {:error, %Error{kind: :validation}} = HTTP.post(client(), state, questions())
    end

    assert {:error, %Error{kind: :validation}} =
             HTTP.post(client(), %{f: fn -> :ok end}, questions())

    assert {:error, _} = HTTP.post(client(), %{:a => 1, "a" => 2}, questions())
    assert {:error, _} = HTTP.post(client(), "state", [{:q, Question.noul!("x")} | :bad])
    assert {:error, _} = HTTP.post(client(), [1 | :bad], questions())
    assert {:error, _} = HTTP.post(client(), %{nested: %{f: :non_json_atom}}, questions())
    refute_receive {:request, _}
  end

  test "request and response size limits" do
    assert {:error, %Error{kind: :validation}} =
             HTTP.post(client(max_request_bytes: 1), "state", questions())

    Process.put(:responses, [reply(200, "too large")])

    assert {:error, %Error{kind: :response}} =
             HTTP.post(client(max_response_bytes: 1), "state", questions())
  end

  test "credentials are resolved for each request and sanitized on failure" do
    c = client(api_key: fn -> Process.get(:key) end)
    Process.put(:key, "one")
    Process.put(:responses, [reply(200), reply(200)])
    assert {:ok, _} = HTTP.post(c, "state", questions())
    assert_receive {:request, first}
    assert {"authorization", "Bearer one"} in first.headers
    Process.put(:key, "two")
    assert {:ok, _} = HTTP.post(c, "state", questions())
    assert_receive {:request, second}
    assert {"authorization", "Bearer two"} in second.headers

    assert {:error, _} =
             HTTP.post(client(api_key: fn -> raise "SECRET" end), "state", questions())

    assert {:error, _} =
             HTTP.post(client(api_key: {:system, "JEVEX_MISSING_TEST_KEY"}), "state", questions())

    assert {:error, _} =
             HTTP.post(client(api_key: fn -> throw(:secret) end), "state", questions())
  end

  test "typed and bang API reject malformed answers" do
    Process.put(:responses, [reply(200), reply(200)])
    assert {:error, %Error{kind: :response}} = Jevex.evaluate(client(), "state", questions())
    assert_raise Error, fn -> Jevex.evaluate!(client(), "state", questions()) end
    assert {:error, _} = Jevex.evaluate(:invalid, "state", questions())
  end
end
