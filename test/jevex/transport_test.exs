defmodule Jevex.TransportTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error, HTTP, Question}

  # Exercise the real Req/Finch socket boundary without calling any remote API.
  defp server(response) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5000)
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
        send(parent, {:wire_request, bytes})
        :ok = :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(pid), do: Process.exit(pid, :normal)
    end)

    "http://127.0.0.1:#{port}/v1/systemone"
  end

  defp client(url, opts \\ []),
    do: Client.new!([endpoint: url, api_key: "socket-test", max_retries: 0] ++ opts)

  test "real transport sends JSON/auth and reads a bounded response" do
    body =
      Jason.encode!(%{
        model: "test",
        answers: %{q: %{type: "noul", noul: 0.9}},
        usage: %{input_tokens: 1, output_tokens: 1}
      })

    url =
      server(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n#{body}"
      )

    assert {:ok, %{answers: %{"q" => %{noul: 0.9}}}} =
             Jevex.evaluate(client(url), "example", %{q: Question.noul!("Question?")})

    assert_receive {:wire_request, bytes}
    assert bytes =~ "POST /v1/systemone"
    assert String.downcase(bytes) =~ "authorization: bearer socket-test"
  end

  test "redirect is returned as an error instead of forwarding the credential" do
    url =
      server(
        "HTTP/1.1 302 Found\r\nLocation: https://example.com/never-follow\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
      )

    assert {:error, %Error{kind: :http, status: 302}} =
             HTTP.post(client(url), "example", %{q: Question.noul!("Question?")})
  end

  test "oversized response is halted with a response error at the socket boundary" do
    body = String.duplicate("a", 100)
    url = server("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n#{body}")

    assert {:error, %Error{kind: :response}} =
             HTTP.post(client(url, max_response_bytes: 20), "example", %{
               q: Question.noul!("Question?")
             })
  end

  test "connection failures return a sanitized transport error" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :gen_tcp.close(listener)

    assert {:error, %Error{kind: :transport}} =
             HTTP.post(client("http://127.0.0.1:#{port}"), "example", %{
               q: Question.noul!("Question?")
             })
  end
end
