defmodule Jevex do
  @moduledoc """
  Jev decisions as Elixir expressions, with a separate typed request API.

  `use Jevex` imports two operators. `~>` returns a scalar and raises
  `Jevex.Error` on evaluation failure; `~>>` returns `{:ok, value}` or
  `{:error, error}` for `with` chains and explicit recovery.

  Jev's three kinds fit ordinary Elixir data transformations: Noul supplies a
  probability (or a boolean), Choice supplies a declared key, and Score supplies
  a fractional number on an ordered rubric.

      defmodule Tickets do
        use Jevex

        def group(tickets) do
          tickets
          |> Enum.filter(&(&1 ~> "Does this require attention?"))
          |> Enum.group_by(&(&1 ~> {"Which team?", billing: "Invoices", support: "Bugs"}))
        end

        def risk(ticket), do: ticket ~> {:noul, "Will this affect customers?"}

        def severity(ticket), do: ticket ~> {"How severe?", ["Low", "Medium", "High"]}

        def assess(ticket) do
          with {:ok, risk} <- ticket ~>> {:noul, "Will this affect customers?"},
               {:ok, severity} <- ticket ~>> {"How severe?", ["Low", "Medium", "High"]} do
            {:ok, %{risk: risk, severity: severity}}
          end
        end
      end

  Compose these values with pipelines, captures, comprehensions, `Enum`, `Stream`,
  function clauses, and ordinary conditionals. Each reached operator makes one
  evaluation; retries and fallback can add HTTP requests. Lazy streams defer
  requests until consumption. Compute values before matching them in a function
  head or guard: inference itself is not permitted there or in module bodies.

  Start with the official TypeSafe API through `config :jevex, :client`.
  Routers such as Lolipop use the same expressions with runtime configuration.
  `Jevex.Syntax` documents both operators, all expression forms, confidence gates,
  and fallback. The decision syntax guide gives complete composition examples.

  ## Lower-level API

  For batching and complete probability metadata, use `Jevex.Schema` or construct
  questions directly:

      client = Jevex.Client.new!(backend: :typesafe)
      questions = %{urgent: Jevex.Question.noul!("Does this need immediate action?")}
      # Jevex.evaluate(client, "The checkout is down", questions)

  Results are `{:ok, %Jevex.Response{}}` or `{:error, %Jevex.Error{}}`.
  Wire answer IDs remain strings. Schemas provide declared atom fields and
  closed-set choice atoms without interning any server-provided strings.

  ## Complete offline example

  This fixture exercises the same validation and typed result path as an actual
  request, without using a credential or making a network connection. For real
  inference, omit `:transport` and use a runtime credential source.

      iex> defmodule DocumentationTransport do
      ...>   @behaviour Jevex.Transport
      ...>   def request(_request, _client) do
      ...>     body = Jason.encode!(%{
      ...>       model: "fixture",
      ...>       answers: %{urgent: %{type: "noul", noul: 0.95}},
      ...>       usage: %{input_tokens: 10, output_tokens: 2}
      ...>     })
      ...>     {:ok, %{status: 200, headers: %{}, body: body}}
      ...>   end
      ...> end; :ok
      :ok
      iex> client = Jevex.Client.new!(backend: :typesafe, api_key: "fixture", transport: DocumentationTransport)
      iex> questions = %{urgent: Jevex.Question.noul!("Does this need immediate action?")}
      iex> {:ok, response} = Jevex.evaluate(client, "Checkout is down", questions)
      iex> response.answers["urgent"]
      %Jevex.Answer.Noul{noul: 0.95}
      iex> response.usage
      %{"input_tokens" => 10, "output_tokens" => 2}
      iex> {:error, error} = Jevex.evaluate(client, "Checkout is down", questions, min_noul_certainty: 0.99)
      iex> error.kind
      :low_confidence
  """
  alias Jevex.{Client, Error, Fallback, HTTP, Response}

  @doc """
  Imports Jev's decision operators into the calling module.

  Write `use Jevex` in an ordinary Elixir module, then use `state ~> question`
  or `state ~>> question` in its functions. No client is constructed and no request is made by `use`.
  This macro accepts no options: configure `:jevex, :client` and
  `:jevex, :syntax` at runtime, or set syntax options under the caller's module.
  For IEx, `import Jevex.Syntax, only: [~>: 2, ~>>: 2]` imports the same operators.
  """
  @spec __using__(Macro.t()) :: Macro.t()
  defmacro __using__(opts) do
    if opts != [] do
      raise CompileError,
        file: __CALLER__.file,
        line: __CALLER__.line,
        description: "use Jevex accepts no options; configure the client and syntax at runtime"
    end

    quote do
      import Jevex.Syntax, only: [~>: 2, ~>>: 2]
    end
  end

  @doc """
  Evaluates questions, validating every answer and optional confidence policy.

  Options (all are optional):

    * `:on_error` — a backup `Jevex.Client` or one-argument callback. Only
      transport errors and HTTP 429, 529, and 5xx invoke this fallback.
      Authentication, validation, and malformed-response failures do not.
    * `:on_low_confidence` — a backup client or callback for threshold failures.
    * `:min_confidence` — inclusive minimum, from 0 to 1, for Choice/Score.
      Missing confidence fails an explicitly configured threshold.
    * `:min_noul_certainty` — inclusive minimum, from 0.5 to 1, for Noul's
      `max(p, 1 - p)`. Noul is not affected by `:min_confidence`.

  A callback receives `t:Jevex.Fallback.context/0` and must return
  `{:ok, %Jevex.Response{}}` or `{:error, %Jevex.Error{}}`. Its response is
  revalidated against the requested questions. Exceptions are sanitized.
  Exactly one fallback is allowed; the fallback must also satisfy the thresholds.
  An unmet threshold without a fallback returns `kind: :low_confidence`.
  All options are validated before sending the first request.

  ## Examples

  Invalid evaluation options fail before credential resolution or network I/O:

      iex> client = Jevex.Client.new!(backend: :typesafe)
      iex> questions = %{urgent: Jevex.Question.noul!("Urgent?")}
      iex> {:error, error} = Jevex.evaluate(client, "state", questions, min_confidence: 1.5)
      iex> error.kind
      :configuration

      # Jevex.evaluate(primary, state, questions,
      #   on_error: backup,
      #   on_low_confidence: backup,
      #   min_confidence: 0.8,
      #   min_noul_certainty: 0.9)
  """
  @spec evaluate(Client.t(), term(), map() | keyword(), Fallback.options()) ::
          {:ok, Response.t()} | {:error, Error.t()}
  def evaluate(client, state, questions, opts \\ [])

  def evaluate(%Client{} = client, state, questions, opts) do
    with :ok <- Fallback.validate_options(opts),
         {:ok, questions} <- HTTP.questions(questions) do
      result = evaluate_once(client, state, questions)
      Fallback.resolve(result, client, state, questions, opts)
    end
  end

  def evaluate(_, _, _, _),
    do: {:error, %Error{kind: :configuration, message: "expected a Jevex.Client"}}

  defp evaluate_once(client, state, questions) do
    with {:ok, body} <- HTTP.request(client, state, questions) do
      Response.decode(body, questions, allow_partial_metadata: client.backend.partial_metadata?())
    end
  end

  @doc """
  Evaluates questions and returns the validated response, raising on failure.

  Accepts the same options as `evaluate/4`. Use the non-bang function when
  errors belong in a `with` chain or need recovery through pattern matching.

      iex> client = Jevex.Client.new!(backend: :typesafe)
      iex> Jevex.evaluate!(client, "state", %{})
      ** (Jevex.Error) questions must not be empty
  """
  @spec evaluate!(Client.t(), term(), map() | keyword(), Fallback.options()) :: Response.t()
  def evaluate!(client, state, questions, opts \\ []) do
    case evaluate(client, state, questions, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end
end
