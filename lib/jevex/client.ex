defmodule Jevex.Client do
  @moduledoc """
  Runtime connection settings shared by Jevex syntax and explicit evaluation.

  Start with `use Jevex` and configure the official TypeSafe client at runtime.
  Both decision operators use this client underneath; construct clients directly
  for per-request provider selection, typed batches, or transport injection.

      {:ok, client} = Jevex.Client.new(
        backend: :typesafe,
        api_key: {:system, "TYPESAFE_API_KEY"}
      )

  Built-ins: `:typesafe`, `:lolipop`, `:openrouter`, `:cloudflare`, `:vercel`,
  and `:custom` (the native protocol with explicit endpoint and model).
  You can also supply a module implementing `Jevex.Backend`.

  Application defaults come from `config :jevex, :client, [...]`; explicit
  options take precedence. Environment credentials are resolved per request,
  so rotation does not require recompilation. `api_key` also accepts a string
  or a zero-arity function returning a string.

  Requests never follow redirects. HTTPS is mandatory except for loopback
  HTTP endpoints. `max_retries` defaults to 2 and only retries 429/529;
  ambiguous transport failures are not retried. `timeout` and `connect_timeout`
  are milliseconds per attempt; retry delay is bounded by `max_retry_delay`.

  `transport` is a module implementing `Jevex.Transport`. Use it to supply a
  deterministic test transport, rather than disabling TLS verification.
  """
  alias Jevex.Error

  @enforce_keys [:backend, :endpoint, :model, :api_key]
  @derive {Inspect, only: [:backend, :model, :timeout, :max_retries]}
  defstruct [
    :backend,
    :endpoint,
    :model,
    :api_key,
    timeout: 30_000,
    connect_timeout: 5_000,
    max_retries: 2,
    max_retry_delay: 30_000,
    max_request_bytes: 1_048_576,
    max_response_bytes: 4_194_304,
    transport: Jevex.Transport.Req
  ]

  @type credential :: String.t() | {:system, String.t()} | (-> String.t())
  @type t :: %__MODULE__{
          backend: module(),
          endpoint: String.t(),
          model: String.t(),
          api_key: credential(),
          timeout: pos_integer(),
          connect_timeout: pos_integer(),
          max_retries: non_neg_integer(),
          max_retry_delay: non_neg_integer(),
          max_request_bytes: pos_integer(),
          max_response_bytes: pos_integer(),
          transport: module()
        }
  @keys ~w(backend endpoint model api_key account_id timeout connect_timeout max_retries max_retry_delay max_request_bytes max_response_bytes transport)a

  @doc """
  Builds and validates connection settings; explicit options override application defaults.

  Construction validates the credential source but does not resolve an environment
  variable or call a credential resolver. No network request is made. When changing
  the configured backend, provider-specific application defaults are discarded to
  avoid sending the old provider's credential to a different host.

      iex> {:ok, client} = Jevex.Client.new(backend: :typesafe, api_key: "example-key")
      iex> {client.backend, client.model}
      {Jevex.Backends.TypeSafe, "jev-latest"}

      iex> {:error, error} = Jevex.Client.new(timeout: 0)
      iex> error.kind
      :configuration
  """
  @spec new(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def new(opts \\ []) do
    defaults = Application.get_env(:jevex, :client, [])

    with :ok <- keyword_options(defaults),
         :ok <- keyword_options(opts),
         defaults = backend_defaults(defaults, opts),
         opts = Keyword.merge(defaults, opts),
         {:ok, backend} <- backend(Keyword.get(opts, :backend, :typesafe)),
         {:ok, preset} <- backend.defaults(opts),
         values = Keyword.drop(opts, [:account_id]) |> Map.new(),
         values = Map.merge(preset, values) |> Map.put(:backend, backend),
         values = Map.put_new(values, :api_key, default_key(backend)),
         client = struct(__MODULE__, values),
         :ok <- validate(client) do
      {:ok, client}
    end
  end

  @doc """
  Like `new/1`, raising `Jevex.Error` on invalid configuration.

  Client inspection excludes credentials and endpoint URLs.

      iex> client = Jevex.Client.new!(backend: :typesafe, api_key: "example-secret")
      iex> String.contains?(inspect(client), "example-secret")
      false
  """
  @spec new!(keyword()) :: t()
  def new!(opts \\ []) do
    case new(opts) do
      {:ok, client} -> client
      {:error, error} -> raise error
    end
  end

  @doc """
  Validates a client struct, including endpoint safety and transport callbacks.

  This is also called before requests, so modifying an existing struct cannot
  bypass configuration validation. It checks the credential source's shape;
  `credential/1` resolves and validates the actual value separately.

      iex> client = Jevex.Client.new!(backend: :typesafe, api_key: "example-key")
      iex> Jevex.Client.validate(client)
      :ok
      iex> {:error, error} = Jevex.Client.validate(%{client | endpoint: "http://example.com/inference"})
      iex> error.kind
      :configuration
  """
  @spec validate(t()) :: :ok | {:error, Error.t()}
  def validate(
        %__MODULE__{
          endpoint: _,
          model: _,
          api_key: _,
          timeout: _,
          connect_timeout: _,
          max_request_bytes: _,
          max_response_bytes: _,
          max_retries: _,
          max_retry_delay: _,
          transport: _,
          backend: _
        } = c
      ) do
    cond do
      not valid_endpoint?(c.endpoint) ->
        invalid(
          "endpoint must be HTTPS (or loopback HTTP), with no credentials, query, or fragment"
        )

      not (is_binary(c.model) and String.valid?(c.model) and byte_size(c.model) > 0 and
               not control?(c.model)) ->
        invalid("model must be a nonempty UTF-8 string without control characters")

      not valid_credential?(c.api_key) ->
        invalid("api_key must be a nonempty string, {:system, name}, or zero-arity function")

      not Enum.all?(
        [c.timeout, c.connect_timeout, c.max_request_bytes, c.max_response_bytes],
        &(is_integer(&1) and &1 > 0)
      ) ->
        invalid("timeouts and size limits must be positive integers")

      not (is_integer(c.max_retries) and c.max_retries in 0..10) ->
        invalid("max_retries must be between 0 and 10")

      not (is_integer(c.max_retry_delay) and c.max_retry_delay in 0..300_000) ->
        invalid("max_retry_delay must be between 0 and 300000 ms")

      not callback_module?(c.transport, request: 2) ->
        invalid("transport must implement Jevex.Transport")

      not callback_module?(c.backend,
        defaults: 1,
        encode: 3,
        headers: 1,
        decode: 1,
        partial_metadata?: 0
      ) ->
        invalid("backend must implement Jevex.Backend")

      true ->
        :ok
    end
  end

  def validate(_), do: invalid("expected a complete Jevex.Client")

  @doc """
  Resolves and validates the credential for one request.

  Accepts a literal key, an environment-variable reference, or a zero-arity
  resolver. Resolvers run on every call, allowing credential rotation. Exceptions,
  throws, and exits become sanitized configuration errors. Do not log the returned
  key; the caller adds it only to the authorization header.

      iex> client = Jevex.Client.new!(backend: :typesafe, api_key: fn -> "rotated-example-key" end)
      iex> Jevex.Client.credential(client)
      {:ok, "rotated-example-key"}

      iex> client = Jevex.Client.new!(backend: :typesafe, api_key: fn -> raise "private-detail" end)
      iex> {:error, error} = Jevex.Client.credential(client)
      iex> {error.kind, String.contains?(inspect(error), "private-detail")}
      {:configuration, false}
  """
  @spec credential(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def credential(%__MODULE__{api_key: source}) do
    key =
      case source do
        {:system, name} -> System.get_env(name)
        fun when is_function(fun, 0) -> fun.()
        value -> value
      end

    if is_binary(key) and String.valid?(key) and byte_size(key) > 0 and not control?(key),
      do: {:ok, key},
      else: invalid("API credential is missing or invalid")
  rescue
    _ -> invalid("API credential could not be resolved")
  catch
    _, _ -> invalid("API credential could not be resolved")
  end

  def credential(_), do: invalid("expected a Jevex.Client with an API credential source")

  defp keyword_options(opts) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in @keys)) and
         length(Keyword.keys(opts)) == length(Enum.uniq(Keyword.keys(opts))),
       do: :ok,
       else: invalid("client options must be a keyword list of unique documented options")
  end

  # Changing providers must not send the application default provider's key to
  # a different host, or silently keep its endpoint/model.
  defp backend_defaults(defaults, opts) do
    if Keyword.has_key?(opts, :backend) and
         Keyword.get(opts, :backend) != Keyword.get(defaults, :backend, :typesafe) do
      Keyword.drop(defaults, [:api_key, :endpoint, :model, :account_id])
    else
      defaults
    end
  end

  defp backend(name) do
    module =
      case name do
        :typesafe -> Jevex.Backends.TypeSafe
        :lolipop -> Jevex.Backends.Lolipop
        :openrouter -> Jevex.Backends.OpenRouter
        :cloudflare -> Jevex.Backends.Cloudflare
        :vercel -> Jevex.Backends.Vercel
        :custom -> Jevex.Backends.Custom
        other -> other
      end

    if callback_module?(module,
         defaults: 1,
         encode: 3,
         headers: 1,
         decode: 1,
         partial_metadata?: 0
       ) do
      {:ok, module}
    else
      invalid("unknown backend or missing Jevex.Backend callbacks")
    end
  end

  defp default_key(backend) do
    name =
      case backend do
        Jevex.Backends.Lolipop -> "LOLIPOP_AI_GATEWAY_API_KEY"
        Jevex.Backends.OpenRouter -> "OPENROUTER_API_KEY"
        Jevex.Backends.Cloudflare -> "CLOUDFLARE_API_TOKEN"
        Jevex.Backends.Vercel -> "AI_GATEWAY_API_KEY"
        _ -> "TYPESAFE_API_KEY"
      end

    {:system, name}
  end

  defp valid_endpoint?(url) when is_binary(url) do
    with true <- String.valid?(url),
         {:ok, uri} <- URI.new(url) do
      scheme_ok =
        uri.scheme == "https" or
          (uri.scheme == "http" and uri.host in ["localhost", "127.0.0.1", "::1"])

      scheme_ok and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo) and
        is_nil(uri.query) and is_nil(uri.fragment) and not control?(url) and
        is_integer(uri.port) and uri.port in 1..65535
    else
      _ -> false
    end
  end

  defp valid_endpoint?(_), do: false

  defp valid_credential?({:system, name}),
    do: is_binary(name) and String.valid?(name) and name != "" and not control?(name)

  defp valid_credential?(fun) when is_function(fun, 0), do: true

  defp valid_credential?(key),
    do: is_binary(key) and String.valid?(key) and key != "" and not control?(key)

  defp control?(s), do: String.match?(s, ~r/[\x00-\x20\x7f]/)

  defp callback_module?(m, callbacks) when is_atom(m) do
    Code.ensure_loaded?(m) and Enum.all?(callbacks, fn {f, a} -> function_exported?(m, f, a) end)
  end

  defp callback_module?(_, _), do: false
  defp invalid(message), do: {:error, %Error{kind: :configuration, message: message}}
end
