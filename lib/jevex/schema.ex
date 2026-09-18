defmodule Jevex.Schema do
  @moduledoc """
  Compile-time declarations for reusable batches of typed Jev questions.

  Start with `use Jevex` for decisions that compose directly with Elixir
  expressions. Use this advanced interface when several questions belong in
  one reusable batch and the result should have a named struct and typespec.

      defmodule Ticket do
        use Jevex.Schema

        noul :urgent, "Does the ticket require immediate action?"
        choice :department, "Which team should handle this?", %{
          billing: "Payments and invoices",
          support: "Technical assistance"
        }
        score :severity, "How severe is the incident?", ["Low", "High"]
      end

  `Ticket.questions/0` returns the low-level question map.
  `Ticket.evaluate(client, state, opts)` returns `{:ok, %Ticket{}}` with typed answer
  structs, or `{:error, %Jevex.Error{}}`. `evaluate!/3` raises on errors.
  Evaluation options are forwarded to `Jevex.evaluate/4`, including fallback
  clients, callbacks, and confidence thresholds. The options default to `[]`.
  Fallback callbacks return `Jevex.Response` structs with string IDs and choices,
  not schema structs; successful results are converted after validation.

  Declarations accept literals only: no function calls, interpolation, module
  attributes, or arbitrary quoted code are evaluated. Invalid questions, empty
  schemas, duplicate fields, and reserved fields fail compilation. For dynamic
  questions use `Jevex.Question` and `Jevex.evaluate/3` directly.

  Atom choice keys are restored using a closed lookup table of declared atoms;
  network responses never create atoms. Probability-map keys stay strings, as in
  the native response. The generated `t/0` type narrows atom
  choices to their literal union. Elixir typespecs cannot express individual
  string values, so string choices use `String.t()` and runtime validation.
  Typespecs support static analysis; they do not make Elixir a statically typed
  language. The response decoder validates external data before construction.

  ## Examples

  Compile a literal schema and inspect its generated questions without an API key:

      iex> ast = quote do
      ...>   defmodule Jevex.Schema.DocumentedTriage do
      ...>     use Jevex.Schema
      ...>     noul :urgent, "Urgent?"
      ...>     choice :team, "Team?", %{billing: "Payments", support: "Technical"}
      ...>     score :impact, "Impact?", ["Low", "High"]
      ...>   end
      ...> end
      iex> [{schema, _bytecode}] = Code.compile_quoted(ast)
      iex> schema.questions()["team"].criteria
      %{"billing" => "Payments", "support" => "Technical"}
      iex> Map.keys(struct(schema)) |> Enum.sort()
      [:__struct__, :impact, :team, :urgent]
      iex> Jevex.Question.encode(schema.questions()["impact"])
      %{"type" => "score", "instructions" => "Impact?", "criteria" => ["Low", "High"]}
  """

  @reserved [:__struct__, :__exception__, :__meta__]

  @doc """
  Installs declaration macros and the before-compile callback via `use Jevex.Schema`.

  Accepts no options. Generates a result struct with required fields, a `t/0`
  type, `questions/0`, `evaluate/2,3`, and `evaluate!/2,3`. An empty schema or
  invalid declaration raises `CompileError`; this macro makes no network calls.
  """
  @spec __using__(Macro.t()) :: Macro.t()
  defmacro __using__(opts) do
    if opts != [], do: compile_error!(__CALLER__, "Jevex.Schema does not accept options")

    quote do
      import Jevex.Schema, only: [noul: 2, noul: 3, choice: 3, score: 3]
      Module.register_attribute(__MODULE__, :jevex_fields, accumulate: true)
      @before_compile Jevex.Schema
    end
  end

  @doc """
  Declares a noul question whose answer contains a yes probability in 0..1.

  `name` must be a non-reserved literal atom. Instructions and optional criteria
  follow `Jevex.Question.noul/2`; criteria may contain only true/false keys.
  All arguments must be literals. Invalid declarations raise `CompileError`.

      noul :urgent, "Urgent?", %{true: "Act now", false: "Can wait"}
  """
  @spec noul(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro noul(name, text, criteria \\ nil) do
    declare(__CALLER__, :noul, name, text, criteria)
  end

  @doc """
  Declares a choice question with a literal map of 1 to 255 options.

  Option keys may be non-boolean, non-nil atoms or nonempty strings. Their values
  follow `Jevex.Question.choice/2`. Atom keys are restored only for the selected
  choice; probability keys remain strings. Atom/string collisions, duplicate
  literal keys, computed arguments, and invalid fields raise `CompileError`.

      choice :team, "Team?", %{billing: "Payments", support: "Technical"}
  """
  @spec choice(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro choice(name, text, choices) do
    declare(__CALLER__, :choice, name, text, choices)
  end

  @doc """
  Declares a score question with 2 to 10 literal ordered rubric entries.

  Entries follow `Jevex.Question.score/2` and correspond to zero-based levels.
  The returned answer contains a numeric score, not a selected label. Invalid
  fields, entries, or nonliteral arguments raise `CompileError`.

      score :impact, "Impact?", ["Low", "Medium", "High"]
  """
  @spec score(Macro.t(), Macro.t(), Macro.t()) :: Macro.t()
  defmacro score(name, text, labels) do
    declare(__CALLER__, :score, name, text, labels)
  end

  defp declare(env, kind, name_ast, text_ast, spec_ast) do
    unless env.module && is_nil(env.function),
      do: compile_error!(env, "Jevex.Schema declarations must appear at module level")

    name = literal!(name_ast, env)
    text = literal!(text_ast, env)
    spec = literal!(spec_ast, env)

    unless is_atom(name) && name not in [nil, true, false] && name not in @reserved &&
             Regex.match?(~r/^[a-z][a-zA-Z0-9_]*[!?]?$/, Atom.to_string(name)) do
      compile_error!(
        env,
        "schema field must be a non-reserved literal atom, got: #{inspect(name)}"
      )
    end

    quote do
      Jevex.Schema.__register__(
        __MODULE__,
        unquote(kind),
        unquote(name),
        unquote(Macro.escape(text)),
        unquote(Macro.escape(spec)),
        unquote(env.file),
        unquote(env.line)
      )
    end
  end

  @doc """
  Internal compile-time registration hook emitted by the declaration macros.

  Stores one validated question on the module being compiled. `file` and `line`
  identify the declaration for `CompileError` diagnostics. Returns `:ok` after
  registration. This is an implementation hook, not a dynamic-question API;
  application code should use the macros or `Jevex.Question` constructors.
  """
  @spec __register__(
          module(),
          :noul | :choice | :score,
          atom(),
          term(),
          term(),
          String.t(),
          pos_integer()
        ) :: :ok
  def __register__(module, kind, name, text, spec, file, line) do
    env = %{file: file, line: line}
    fields = Module.get_attribute(module, :jevex_fields) || []

    if Enum.any?(fields, fn {existing, _, _} -> existing == name end),
      do: compile_error!(env, "duplicate Jevex.Schema field: #{inspect(name)}")

    {wire_spec, conversions} = normalize_spec(kind, spec, env)

    Code.ensure_compiled!(Jevex.Question)

    question =
      try do
        apply(Jevex.Question, constructor(kind), [text, wire_spec])
      rescue
        e in [ArgumentError, Jevex.Error] -> compile_error!(env, Exception.message(e))
      end

    Module.put_attribute(module, :jevex_fields, {name, question, conversions})
  end

  defp constructor(:noul), do: :noul!
  defp constructor(:choice), do: :choice!
  defp constructor(:score), do: :score!

  defp normalize_spec(:choice, spec, env) when is_map(spec) do
    conversions =
      Map.new(spec, fn {key, _} ->
        unless (is_atom(key) and key not in [nil, true, false]) or is_binary(key),
          do: compile_error!(env, "choice keys must be atoms or strings")

        {to_string(key), key}
      end)

    if map_size(conversions) != map_size(spec),
      do: compile_error!(env, "choice keys collide after conversion to strings")

    {Map.new(spec, fn {key, value} -> {to_string(key), value} end), conversions}
  end

  defp normalize_spec(_kind, spec, _env), do: {spec, nil}

  @doc """
  Internal compiler callback that emits the schema struct, types, and functions.

  Called automatically by the compiler after declarations have been registered.
  Returns generated AST and raises `CompileError` when no fields were declared.
  Application code should not invoke this callback directly.
  """
  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(env) do
    fields = env.module |> Module.get_attribute(:jevex_fields) |> Enum.reverse()
    if fields == [], do: compile_error!(env, "Jevex.Schema requires at least one question")
    names = Enum.map(fields, &elem(&1, 0))
    questions = Map.new(fields, fn {name, question, _} -> {Atom.to_string(name), question} end)

    types =
      Enum.map(fields, fn {name, question, conversions} ->
        {name, answer_type(question, conversions)}
      end)

    mappings = Enum.map(fields, fn {name, _, conversions} -> {name, conversions} end)

    quote do
      @enforce_keys unquote(names)
      defstruct unquote(names)

      @typedoc "Typed answers for every declared field; atom choices use their exact declared union."
      @type t :: %__MODULE__{unquote_splicing(types)}

      @doc """
      Returns the compile-time validated question map with string IDs.

      The map can be passed to `Jevex.evaluate/4` to retain response model and
      usage metadata, or to `Jevex.HTTP.post/3` for untyped backend-normalized JSON.
      This function performs no requests and needs no client or credentials.
      """
      @spec questions() :: %{required(String.t()) => Jevex.Question.t()}
      def questions, do: unquote(Macro.escape(questions))

      @doc """
      Evaluates state and returns `{:ok, schema_struct}` or a structured error.

      Accepts all `Jevex.evaluate/4` confidence and fallback options. Successful
      answers are validated before conversion; selected atom choices are restored
      from the declaration, while probability-map keys stay strings. The result
      omits response model and usage metadata; use `questions/0` with the direct
      API when those are needed. Errors are returned as `{:error, Jevex.Error.t()}`.
      """
      @spec evaluate(Jevex.Client.t(), term(), Jevex.Fallback.options()) ::
              {:ok, t()} | {:error, Jevex.Error.t()}
      def evaluate(client, state, opts \\ []) do
        with {:ok, response} <- Jevex.evaluate(client, state, questions(), opts) do
          values =
            Enum.map(unquote(Macro.escape(mappings)), fn {name, conversions} ->
              answer = Map.fetch!(response.answers, Atom.to_string(name))

              answer =
                if conversions do
                  %{answer | choice: Map.fetch!(conversions, answer.choice)}
                else
                  answer
                end

              {name, answer}
            end)

          {:ok, struct!(__MODULE__, values)}
        end
      end

      @doc """
      Evaluates state, returning the schema struct or raising `Jevex.Error`.

      Uses the same validation, confidence gates, and fallback policy as
      `evaluate/3`. The options default to an empty list.
      """
      @spec evaluate!(Jevex.Client.t(), term(), Jevex.Fallback.options()) :: t()
      def evaluate!(client, state, opts \\ []) do
        case evaluate(client, state, opts) do
          {:ok, result} -> result
          {:error, error} -> raise error
        end
      end
    end
  end

  defp answer_type(_question, conversions) when is_map(conversions) do
    values = Map.values(conversions)
    atoms = values |> Enum.filter(&is_atom/1) |> Enum.sort()
    types = if Enum.any?(values, &is_binary/1), do: atoms ++ [quote(do: String.t())], else: atoms
    union = Enum.reduce(types, fn type, acc -> {:|, [], [acc, type]} end)
    quote do: Jevex.Answer.Choice.t(unquote(union))
  end

  defp answer_type(%{type: type}, nil) when type in [:noul, "noul"],
    do: quote(do: Jevex.Answer.Noul.t())

  defp answer_type(_question, nil), do: quote(do: Jevex.Answer.Score.t())

  defp literal!(value, _env) when is_atom(value) or is_binary(value) or is_number(value),
    do: value

  defp literal!({:-, _, [value]}, _env) when is_number(value), do: -value
  defp literal!({:+, _, [value]}, _env) when is_number(value), do: value

  defp literal!(list, env) when is_list(list), do: Enum.map(list, &literal!(&1, env))

  defp literal!({:%{}, _, pairs}, env) do
    decoded = Enum.map(pairs, fn {key, value} -> {literal!(key, env), literal!(value, env)} end)
    result = Map.new(decoded)

    if map_size(result) != length(decoded),
      do: compile_error!(env, "duplicate keys in literal map")

    result
  end

  defp literal!(_, env), do: compile_error!(env, "Jevex.Schema declarations accept literals only")

  defp compile_error!(env, message),
    do: raise(CompileError, file: env.file, line: env.line, description: message)
end
