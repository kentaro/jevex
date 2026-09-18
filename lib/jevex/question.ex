defmodule Jevex.Question do
  @moduledoc """
  A validated native Jev question for explicit, typed evaluation.

  Use `Jevex.Syntax` for concise decisions inside ordinary Elixir code. Construct
  questions here when you need structured instructions, dynamic rubrics, or
  several judgments in one `Jevex.evaluate/4` request.

  Instructions and rubric entries accept strings, JSON objects, arrays, or `nil`.
  Nested JSON values may also be numbers and booleans. Atom object keys are
  normalized to strings; ambiguous keys such as `:yes` and `"yes"` are rejected.
  Arbitrary structs, tuples, functions, and non-JSON atoms are rejected.

      iex> Jevex.Question.noul!("Is this urgent?").type
      :noul

  Prefer constructors over constructing the struct directly. `validate/1` also
  checks manually constructed structs. `encode/1` raises `Jevex.Error` if invalid.
  """
  alias Jevex.Error

  @typedoc "A JSON value after object keys have been normalized to strings."
  @type json ::
          nil | boolean() | number() | String.t() | [json()] | %{optional(String.t()) => json()}
  @typedoc "A normalized instruction or rubric entry; a scalar number is not an entry."
  @type entry :: nil | String.t() | [json()] | %{optional(String.t()) => json()}
  @typedoc "Input JSON values may also use atom object keys, which are normalized."
  @type input_json ::
          nil
          | boolean()
          | number()
          | String.t()
          | [input_json()]
          | %{optional(String.t() | atom()) => input_json()}
  @typedoc "Accepted instruction and rubric entry input, before normalization."
  @type input_entry ::
          nil | String.t() | [input_json()] | %{optional(String.t() | atom()) => input_json()}
  @typedoc "A validated question; use the constructors to enforce rubric constraints."
  @type t :: %__MODULE__{
          type: :noul | :choice | :score,
          instructions: entry(),
          criteria: nil | %{optional(String.t()) => entry()} | [entry()]
        }
  @enforce_keys [:type, :instructions]
  defstruct [:type, :instructions, :criteria]

  @doc """
  Creates a yes-probability question with optional criteria for `true` and `false`.

  Returns `{:ok, question}` after normalizing atom object keys to strings, or
  `{:error, %Jevex.Error{kind: :validation}}` for invalid instructions or criteria.
  Criteria may be `nil` or a map containing only `"true"` and `"false"` keys
  (or their atom equivalents); either criterion may be omitted.

      iex> {:ok, question} = Jevex.Question.noul("Urgent?", %{true: "Act now", false: "Can wait"})
      iex> question.criteria
      %{"true" => "Act now", "false" => "Can wait"}
      iex> question.type
      :noul
  """
  @spec noul(input_entry(), map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def noul(instructions, criteria \\ nil), do: build(:noul, instructions, criteria)

  @doc """
  Creates a choice question with 1 to 255 options mapped to rubric entries.

  Option keys must be nonempty strings or atoms that normalize to nonempty
  strings. Colliding atom/string keys are rejected. Returns `{:ok, question}`
  or a validation error; no option string is converted into an atom.

      iex> {:ok, question} = Jevex.Question.choice("Team?", %{billing: "Payments", support: "Technical"})
      iex> question.criteria
      %{"billing" => "Payments", "support" => "Technical"}
      iex> {:error, error} = Jevex.Question.choice("Team?", %{})
      iex> error.kind
      :validation
  """
  @spec choice(input_entry(), map()) :: {:ok, t()} | {:error, Error.t()}
  def choice(instructions, criteria), do: build(:choice, instructions, criteria)

  @doc """
  Creates a score question with 2 to 10 ordered rubric entries.

  Entries correspond to zero-based score levels, so two entries describe a
  score range of 0 to 1. Returns `{:ok, question}` or a validation error.

      iex> {:ok, question} = Jevex.Question.score("Impact?", ["Low", "High"])
      iex> question.criteria
      ["Low", "High"]
      iex> {:error, error} = Jevex.Question.score("Impact?", ["Only one level"])
      iex> error.kind
      :validation
  """
  @spec score(input_entry(), [input_entry()]) :: {:ok, t()} | {:error, Error.t()}
  def score(instructions, criteria), do: build(:score, instructions, criteria)

  @doc """
  Returns a validated noul question, raising `Jevex.Error` on invalid input.

      iex> Jevex.Question.noul!(%{instruction: "Urgent?"}).instructions
      %{"instruction" => "Urgent?"}
  """
  @spec noul!(input_entry(), map() | nil) :: t()
  def noul!(instructions, criteria \\ nil), do: unwrap(noul(instructions, criteria))

  @doc """
  Returns a validated choice question, raising `Jevex.Error` on invalid input.

      iex> Jevex.Question.choice!("Team?", %{"billing" => "Payments"}).type
      :choice
      iex> Jevex.Question.choice!("Team?", %{})
      ** (Jevex.Error) choice requires at least one option
  """
  @spec choice!(input_entry(), map()) :: t()
  def choice!(instructions, criteria), do: unwrap(choice(instructions, criteria))

  @doc """
  Returns a validated score question, raising `Jevex.Error` on invalid input.

      iex> Jevex.Question.score!("Impact?", ["Low", "High"]).type
      :score
  """
  @spec score!(input_entry(), [input_entry()]) :: t()
  def score!(instructions, criteria), do: unwrap(score(instructions, criteria))

  @doc """
  Checks a question, including structs constructed or updated directly.

  Returns `:ok` when the question can be normalized and validated, or
  `{:error, %Jevex.Error{kind: :validation}}`. It does not mutate its argument;
  use `encode/1` to obtain the normalized wire representation.

      iex> question = Jevex.Question.score!("Impact?", ["Low", "High"])
      iex> Jevex.Question.validate(question)
      :ok
      iex> {:error, error} = Jevex.Question.validate(%{question | criteria: []})
      iex> error.kind
      :validation
  """
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{type: type, instructions: instructions, criteria: criteria}) do
    case build(type, instructions, criteria) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def validate(_), do: invalid("expected a Jevex.Question")

  @doc """
  Returns the normalized string-keyed native API map for a question struct.

  Revalidates the struct and raises `Jevex.Error` for invalid question contents.
  The argument must be a `Jevex.Question` struct. Absent noul criteria are omitted
  rather than encoded as a `"criteria": null` property.

      iex> Jevex.Question.encode(Jevex.Question.noul!("Urgent?"))
      %{"type" => "noul", "instructions" => "Urgent?"}
      iex> Jevex.Question.encode(Jevex.Question.score!("Impact?", ["Low", "High"]))
      %{"type" => "score", "instructions" => "Impact?", "criteria" => ["Low", "High"]}
  """
  @spec encode(t()) :: map()
  def encode(%__MODULE__{type: type, instructions: instructions, criteria: criteria}) do
    q = unwrap(build(type, instructions, criteria))
    encoded = %{"type" => Atom.to_string(q.type), "instructions" => q.instructions}
    if is_nil(q.criteria), do: encoded, else: Map.put(encoded, "criteria", q.criteria)
  end

  def encode(_), do: raise(Error, kind: :validation, message: "expected a Jevex.Question")

  defp build(type, instructions, criteria) when type in [:noul, :choice, :score] do
    with {:ok, instructions} <- entry(instructions),
         {:ok, criteria} <- criteria(type, criteria) do
      {:ok, %__MODULE__{type: type, instructions: instructions, criteria: criteria}}
    end
  end

  defp build(_, _, _), do: invalid("unknown question type")

  defp criteria(:noul, nil), do: {:ok, nil}

  defp criteria(type, value)
       when type in [:noul, :choice] and is_map(value) and not is_struct(value) do
    with {:ok, normalized} <- json(value),
         true <- Enum.all?(normalized, fn {_, v} -> match?({:ok, _}, entry(v)) end) do
      cond do
        type == :noul and not Enum.all?(Map.keys(normalized), &(&1 in ["true", "false"])) ->
          invalid("noul criteria only accept true and false keys")

        type == :choice and map_size(normalized) == 0 ->
          invalid("choice requires at least one option")

        type == :choice and map_size(normalized) > 255 ->
          invalid("choice permits at most 255 options")

        type == :choice and Map.has_key?(normalized, "") ->
          invalid("choice option keys must not be empty")

        true ->
          {:ok, normalized}
      end
    else
      _ -> invalid("criteria must contain valid rubric entries with unambiguous keys")
    end
  end

  defp criteria(:score, values) when is_list(values) and length(values) in 2..10 do
    normalize_list(values, &entry/1)
  end

  defp criteria(_, _), do: invalid("invalid criteria shape; score requires 2 to 10 levels")

  defp entry(value) when is_nil(value) or is_binary(value) or is_list(value) or is_map(value),
    do: json(value)

  defp entry(_), do: invalid("rubric entries must be strings, objects, arrays, or nil")

  defp json(value) when is_nil(value) or is_boolean(value) or is_number(value), do: {:ok, value}

  defp json(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: invalid("JSON strings must be valid UTF-8")
  end

  defp json(value) when is_list(value), do: normalize_list(value, &json/1)

  defp json(value) when is_map(value) and not is_struct(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with {:ok, key} <- key(key),
           false <- Map.has_key?(acc, key),
           {:ok, value} <- json(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, invalid("JSON objects require unique string or atom keys and JSON values")}
      end
    end)
  end

  defp json(_), do: invalid("value is not JSON-compatible")
  defp key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp key(key) when is_binary(key), do: json(key)
  defp key(_), do: invalid("invalid JSON object key")

  defp normalize_list(values, fun) do
    normalize_list(values, fun, [])
  end

  defp normalize_list([], _fun, acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_list([value | tail], fun, acc) do
    case fun.(value) do
      {:ok, value} -> normalize_list(tail, fun, [value | acc])
      error -> error
    end
  end

  defp normalize_list(_, _, _), do: invalid("JSON arrays must be proper lists")

  defp unwrap({:ok, value}), do: value
  defp unwrap({:error, error}), do: raise(error)
  defp invalid(message), do: {:error, %Error{kind: :validation, message: message}}
end
