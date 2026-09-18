defmodule Jevex do
  @moduledoc """
  Typed Jev evaluations with interchangeable backends and an optional schema DSL.

  For reusable declarations, see `Jevex.Schema`. For dynamic questions:

      client = Jevex.Client.new!(backend: :lolipop)
      questions = %{urgent: Jevex.Question.noul!("Does this need immediate action?")}
      # Jevex.evaluate(client, "The checkout is down", questions)

  Results are `{:ok, %Jevex.Response{}}` or `{:error, %Jevex.Error{}}`.
  Wire answer IDs remain strings. Schemas provide declared atom fields and
  closed-set choice atoms without interning any server-provided strings.
  """
  alias Jevex.{Client, Error, Fallback, HTTP, Response}

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

  @doc "Like `evaluate/4`, but raises `Jevex.Error` on failure."
  @spec evaluate!(Client.t(), term(), map() | keyword(), Fallback.options()) :: Response.t()
  def evaluate!(client, state, questions, opts \\ []) do
    case evaluate(client, state, questions, opts) do
      {:ok, response} -> response
      {:error, error} -> raise error
    end
  end
end
