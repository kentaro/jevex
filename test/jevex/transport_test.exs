defmodule Jevex.TransportTest do
  use ExUnit.Case, async: true
  alias Jevex.{Client, Error, HTTP, Question}

  # Exercise the real Req/Finch socket boundary without calling any remote API.
  defp server(response) when is_binary(response) do
    server(fn socket, _parent -> :gen_tcp.send(socket, response) end)
  end

  defp server(handler) when is_function(handler, 2) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    parent = self()

    pid =
      spawn(fn ->
        case :gen_tcp.accept(listener, 5000) do
          {:ok, socket} ->
            try do
              {:ok, bytes} = :gen_tcp.recv(socket, 0, 5000)
              send(parent, {:wire_request, bytes})
              handler.(socket, parent)
            after
              :gen_tcp.close(socket)
            end

          {:error, :closed} ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      # Stalled/trickling servers must not survive the test; :normal would be
      # ignored by another process that is not trapping exits.
      if Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    "http://127.0.0.1:#{port}/v1/systemone"
  end

  defp client(url, opts \\ []) do
    Client.new!(Keyword.merge([endpoint: url, api_key: "socket-test", max_retries: 0], opts))
  end

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

  test "a stalled HTTP/1 response respects the configured receive timeout" do
    url =
      server(fn _socket, _parent ->
        # Keep the accepted connection open without sending response headers.
        receive do
          :finish -> :ok
        after
          5000 -> :ok
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :transport}} =
             HTTP.post(client(url, timeout: 100, connect_timeout: 500), "example", %{
               q: Question.noul!("Question?")
             })

    elapsed = System.monotonic_time(:millisecond) - started
    assert_receive {:wire_request, _}
    # This deliberately loose ceiling checks bounded behavior, not precision.
    assert elapsed < 2000
  end

  test "HTTP/1 complete-response timeout stops chunks arriving below the inactivity timeout" do
    url =
      server(fn socket, parent ->
        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
          )

        trickle(socket, parent, 1)
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :transport}} =
             HTTP.post(client(url, timeout: 500, connect_timeout: 500), "example", %{
               q: Question.noul!("Question?")
             })

    elapsed = System.monotonic_time(:millisecond) - started
    assert_receive {:wire_request, _}
    assert_receive {:trickled_chunk, 1}
    assert_receive {:trickled_chunk, 2}
    refute_received :trickle_completed
    # Without request_timeout, 25 ms chunks keep a 500 ms inactivity timeout
    # alive for the entire 2.5-second response. This is a generous bound for
    # Finch's best-effort HTTP/1 timeout, not a strict end-to-end deadline.
    assert elapsed < 2000
  end

  defp trickle(socket, parent, 101) do
    if :gen_tcp.send(socket, "2\r\n{}\r\n0\r\n\r\n") == :ok do
      send(parent, :trickle_completed)
    end
  end

  defp trickle(socket, parent, index) do
    case :gen_tcp.send(socket, "1\r\n \r\n") do
      :ok ->
        send(parent, {:trickled_chunk, index})

        receive do
          :finish -> :ok
        after
          25 -> trickle(socket, parent, index + 1)
        end

      {:error, _} ->
        :ok
    end
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
