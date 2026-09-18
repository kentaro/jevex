defmodule Jevex.Syntax do
  @moduledoc """
  Elixir expressions for Jev decisions, imported by `use Jevex`.

      # state ~> "Is this urgent?"
      # state ~> {:noul, "Is this urgent?"}
      # state ~> {"Which team?", billing: "Payments", support: "Technical issues"}
      # state ~> {"How severe?", ["Low", "Medium", "High"]}
      # state ~>> {:noul, "Is this urgent?"}

  A string asks a Noul question and returns a boolean. `{:noul, question}`
  returns the original probability from 0 to 1, useful for ranking, filtering,
  aggregating, or composing decisions in an `Enum` pipeline. It still uses
  `:min_noul_certainty` and fallback policies, but `:truth_threshold` does not
  change the returned probability. A tuple with a keyword
  list or map of options returns the original declared option key (atom or
  string). Choice keys must be strings or atoms other than `nil`, `true`, and
  `false`. A tuple with an ordered list of levels returns a numeric score.
  `~>/2` returns the scalar and raises `Jevex.Error` on failure. `~>>/2`
  returns `{:ok, scalar}` or `{:error, %Jevex.Error{}}`, allowing explicit
  error handling with `with`, function-clause matching, and result pipelines.
  An inference failure never becomes `false`.

  Both operators support every expression. Use probabilities for ranking and
  aggregation, declared choices for dispatch, and scores for ordered comparison:

      # Enum.map(messages, &(&1 ~> {:noul, "Is this urgent?"}))
      # Enum.map(tickets, &(&1 ~>> {"Which team?", billing: "Payments", support: "Bugs"}))
      # reviews |> Enum.map(&(&1 ~> {"Quality?", ["Poor", "Good", "Excellent"]}))

  A result-returning decision composes with existing fallible functions:

      # with {:ok, state} <- load_ticket(id),
      #      {:ok, team} <- state ~>> {"Which team?", billing: "Payments", support: "Bugs"} do
      #   assign_ticket(id, team)
      # end

  Configure `config :jevex, :syntax, [...]` globally and
  `config :jevex, MyModule, [...]` for a calling module. Module options override
  global options. Configuration is read at runtime, never embedded in the macro.

  Supported options are `:client` (a `Jevex.Client` or its keyword options),
  `:truth_threshold` (0..1; default 0.5), and the four evaluation policy options
  documented in `Jevex.evaluate/4`. Fallback actions additionally accept a backend
  atom such as `:lolipop` or a keyword list of client options. The default client
  is `Jevex.Client.new!/0`. A Noul probability equal to the truth threshold is true.

  Use `:min_noul_certainty` to reject uncertain yes/no answers; this is separate
  from `:truth_threshold`, which only converts the accepted answer to a boolean.
  The same confidence policy applies to the one permitted fallback result.

  Each operand of either operator is evaluated exactly once. Both are allowed in
  function bodies and after an IEx import, but rejected in guards, match patterns,
  and module bodies to prevent inference during compilation. Static literal
  questions are validated at compile time without executing quoted code; dynamic
  expressions receive the same validation at runtime. Server data never creates
  atoms: a choice is matched back to a key already supplied by the caller.
  """
  alias Jevex.{Answer, Client, Error, Fallback, Question, Response}

  @type expression ::
          String.t() | {:noul, String.t()} | {String.t(), keyword() | map() | [Question.entry()]}
  @type decision :: boolean() | atom() | String.t() | number()
  @keys [
    :client,
    :truth_threshold,
    :min_confidence,
    :min_noul_certainty,
    :on_error,
    :on_low_confidence
  ]
  @policy_keys [:min_confidence, :min_noul_certainty, :on_error, :on_low_confidence]

  @doc """
  Evaluates one Jev decision, returning the scalar implied by the question.

  The left operand is the state. The right operand is a string question,
  `{:noul, question}` for its probability, a `{question, options}` choice,
  or a `{question, levels}` score. Configure
  the client at runtime with the `:jevex` application's `:syntax` key.
  """
  @spec Macro.t() ~> Macro.t() :: Macro.t()
  defmacro state ~> expression do
    expand_operator(state, expression, __CALLER__, :evaluate!, "~>")
  end

  @doc """
  Evaluates one Jev decision as `{:ok, scalar}` or `{:error, %Jevex.Error{}}`.

  Supports the same Noul, Choice, and Score expressions and runtime policy as
  `~>/2`. Use it in `with`, result pipelines, or functions that pattern-match
  tagged tuples. Only Jevex errors become error tuples; arbitrary application
  exceptions are not swallowed. Invalid static literals still fail compilation.
  """
  @spec Macro.t() ~>> Macro.t() :: Macro.t()
  defmacro state ~>> expression do
    expand_operator(state, expression, __CALLER__, :evaluate, "~>>")
  end

  defp expand_operator(state, expression, caller, function, operator) do
    if caller.context in [:guard, :match] or
         (not is_nil(caller.module) and is_nil(caller.function)) do
      raise CompileError,
        file: caller.file,
        line: caller.line,
        description:
          "Jevex #{operator} is only allowed in function bodies or an interactive import; it cannot run in guards, matches, or module bodies"
    end

    Code.ensure_compiled!(Question)

    try do
      case literal(expression) do
        {:ok, value} -> prepare!(value)
        :dynamic -> :ok
      end
    rescue
      error in Error ->
        raise CompileError, file: caller.file, line: caller.line, description: error.message
    end

    quote do
      Jevex.Syntax.unquote(function)(unquote(state), unquote(expression), unquote(caller.module))
    end
  end

  @doc """
  Runtime implementation of `~>>/2`, returning a tagged scalar result.

  Accepts the same expressions, caller configuration, and confidence policies
  as `evaluate!/3`. It converts only `Jevex.Error` exceptions into error tuples;
  other application exceptions propagate. Question validation precedes any
  request, so invalid dynamic expressions can be handled without network access:

      iex> result = Jevex.Syntax.evaluate("state", :invalid_expression)
      iex> match?({:error, %Jevex.Error{kind: :validation}}, result)
      true
  """
  @spec evaluate(term(), expression(), module() | nil) :: {:ok, decision()} | {:error, Error.t()}
  def evaluate(state, expression, caller \\ nil) do
    {:ok, evaluate!(state, expression, caller)}
  rescue
    error in Error -> {:error, error}
  end

  @doc """
  Runtime implementation of `~>/2`, also useful for dynamically built questions.

  `caller` selects optional module configuration; leave it nil outside a module.
  Configuration and question validation happen before any request. The result
  is a boolean, a Noul probability, a declared option key, or a score.
  Any error raises `Jevex.Error`.
  """
  @spec evaluate!(term(), expression(), module() | nil) :: decision()
  def evaluate!(state, expression, caller \\ nil) do
    {question, _choices} = prepare!(expression)
    settings = settings!(caller)
    client = configured_client!(Keyword.get(settings, :client, []))
    threshold = threshold!(Keyword.get(settings, :truth_threshold, 0.5))
    policy = settings |> Keyword.take(@policy_keys) |> normalize_actions!()

    case Fallback.validate_options(policy) do
      :ok -> :ok
      {:error, error} -> raise error
    end

    response = Jevex.evaluate!(client, state, %{"decision" => question}, policy)
    decision!(Map.fetch!(response.answers, "decision"), expression, threshold)
  end

  @doc """
  Validates a typed answer against a question expression and extracts its scalar.

  This helper makes no network request. It uses the same answer validation as
  `Jevex.Response.decode/3`, allowing metadata omitted by routers. A malformed
  answer or expression raises `Jevex.Error`. Confidence policies are handled by
  `evaluate!/3`; `truth_threshold` here only converts a valid Noul probability.

      iex> answer = %Jevex.Answer.Noul{noul: 0.8}
      iex> Jevex.Syntax.decision!(answer, "Urgent?", 0.5)
      true

      iex> answer = %Jevex.Answer.Noul{noul: 0.8}
      iex> Jevex.Syntax.decision!(answer, {:noul, "Urgent?"}, 0.95)
      0.8

      iex> answer = %Jevex.Answer.Choice{choice: "billing", probabilities: nil, confidence: nil}
      iex> Jevex.Syntax.decision!(answer, {"Which team?", billing: "Payments", support: "Bugs"}, 0.5)
      :billing

      iex> answer = %Jevex.Answer.Score{score: 1.5, legend: nil, probabilities: nil, confidence: nil}
      iex> Jevex.Syntax.decision!(answer, {"How severe?", ["Low", "Medium", "High"]}, 0.5)
      1.5
  """
  @spec decision!(Answer.t(), expression(), number()) :: decision()
  def decision!(answer, expression, truth_threshold \\ 0.5) do
    {question, choices} = prepare!(expression)
    threshold = threshold!(truth_threshold)
    body = %{"answers" => %{"decision" => encode_answer!(answer)}}

    case Response.decode(body, %{"decision" => question}, allow_partial_metadata: true) do
      {:ok, %Response{answers: %{"decision" => %Answer.Noul{noul: value}}}} ->
        if choices == :raw_noul, do: value, else: value >= threshold

      {:ok, %Response{answers: %{"decision" => %Answer.Choice{choice: value}}}} ->
        Map.fetch!(choices, value)

      {:ok, %Response{answers: %{"decision" => %Answer.Score{score: value}}}} ->
        value

      {:error, error} ->
        raise error
    end
  end

  defp prepare!(expression) when is_binary(expression), do: {Question.noul!(expression), nil}

  defp prepare!({:noul, instructions}) when is_binary(instructions),
    do: {Question.noul!(instructions), :raw_noul}

  defp prepare!({instructions, criteria})
       when is_binary(instructions) and is_map(criteria) and not is_struct(criteria) do
    question = Question.choice!(instructions, criteria)
    {question, choice_keys!(Map.to_list(criteria))}
  end

  defp prepare!({instructions, criteria}) when is_binary(instructions) and is_list(criteria) do
    if Keyword.keyword?(criteria) and criteria != [] do
      keys = choice_keys!(criteria)
      {Question.choice!(instructions, Map.new(criteria)), keys}
    else
      {Question.score!(instructions, criteria), nil}
    end
  end

  defp prepare!(_),
    do:
      fail!(
        :validation,
        "decision expression must be a question string, {:noul, question}, or a {question, options_or_levels} tuple"
      )

  defp choice_keys!(pairs) do
    Enum.reduce(pairs, %{}, fn {key, _}, acc ->
      unless is_binary(key) or (is_atom(key) and key not in [nil, true, false]) do
        fail!(:validation, "syntax choice keys must be strings or non-boolean, non-nil atoms")
      end

      normalized = if is_atom(key), do: Atom.to_string(key), else: key

      if Map.has_key?(acc, normalized),
        do: fail!(:validation, "choice option keys must be unique after normalization")

      Map.put(acc, normalized, key)
    end)
  end

  defp settings!(caller) when is_atom(caller) do
    global = Application.get_env(:jevex, :syntax, [])
    local = if is_nil(caller), do: [], else: Application.get_env(:jevex, caller, [])
    validate_settings!(global)
    validate_settings!(local)
    Keyword.merge(global, local)
  end

  defp settings!(_), do: fail!(:configuration, "syntax caller must be a module or nil")

  defp validate_settings!(settings) do
    if not Keyword.keyword?(settings) or
         not Enum.all?(Keyword.keys(settings), &(&1 in @keys)) or
         length(Keyword.keys(settings)) != length(Enum.uniq(Keyword.keys(settings))) do
      fail!(
        :configuration,
        "syntax configuration must be a keyword list of unique documented options"
      )
    end
  end

  defp configured_client!(%Client{} = client) do
    case Client.validate(client) do
      :ok -> client
      {:error, error} -> raise error
    end
  end

  defp configured_client!(options) when is_list(options), do: Client.new!(options)

  defp configured_client!(_),
    do: fail!(:configuration, "syntax client must be a Jevex.Client or client options")

  defp normalize_actions!(policy) do
    Enum.map(policy, fn
      {key, action} when key in [:on_error, :on_low_confidence] -> {key, action!(action)}
      pair -> pair
    end)
  end

  defp action!(%Client{} = client), do: configured_client!(client)
  defp action!(callback) when is_function(callback, 1), do: callback

  defp action!(backend) when is_atom(backend) and not is_nil(backend) and not is_boolean(backend),
    do: Client.new!(backend: backend)

  defp action!(options) when is_list(options), do: configured_client!(options)

  defp action!(_),
    do:
      fail!(
        :configuration,
        "syntax fallback must be a client, backend, client options, or one-argument callback"
      )

  defp threshold!(value) when is_number(value) and value >= 0 and value <= 1, do: value
  defp threshold!(_), do: fail!(:configuration, "truth_threshold must be a number from 0 to 1")

  defp encode_answer!(%Answer.Noul{noul: value}), do: %{"type" => "noul", "noul" => value}

  defp encode_answer!(%Answer.Choice{
         choice: choice,
         probabilities: probabilities,
         confidence: confidence
       }) do
    %{"type" => "choice", "choice" => choice}
    |> put_metadata("probabilities", probabilities)
    |> put_metadata("confidence", confidence)
  end

  defp encode_answer!(%Answer.Score{
         score: score,
         legend: legend,
         probabilities: probabilities,
         confidence: confidence
       }) do
    %{"type" => "score", "score" => score}
    |> put_metadata("legend", legend)
    |> put_metadata("probabilities", probabilities)
    |> put_metadata("confidence", confidence)
  end

  defp encode_answer!(_), do: fail!(:response, "decision requires a typed Jevex answer")
  defp put_metadata(map, _key, nil), do: map
  defp put_metadata(map, key, value), do: Map.put(map, key, value)
  defp fail!(kind, message), do: raise(Error, kind: kind, message: message)

  # Decode only literal AST nodes. Calls, aliases, attributes and interpolations
  # remain dynamic and are never expanded or executed by this macro.
  defp literal(value) when is_binary(value) or is_atom(value) or is_number(value),
    do: {:ok, value}

  defp literal([]), do: {:ok, []}

  defp literal([head | tail]) do
    with {:ok, head} <- literal(head), {:ok, tail} <- literal(tail), do: {:ok, [head | tail]}
  end

  defp literal({:%{}, _meta, pairs}) do
    with {:ok, pairs} <- literal(pairs) do
      keys = Enum.map(pairs, &elem(&1, 0))

      if length(keys) != MapSet.size(MapSet.new(keys)) do
        fail!(:validation, "literal maps must not contain duplicate keys")
      end

      {:ok, Map.new(pairs)}
    end
  end

  defp literal({:{}, _meta, values}) do
    with {:ok, values} <- literal(values), do: {:ok, List.to_tuple(values)}
  end

  defp literal({left, right}) do
    with {:ok, left} <- literal(left), {:ok, right} <- literal(right), do: {:ok, {left, right}}
  end

  defp literal(_), do: :dynamic
end
