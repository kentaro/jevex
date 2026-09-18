defmodule Jevex.Question do
  @moduledoc """
  A validated native Jev question, independent of transport and the macro DSL.

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

  @type json ::
          nil | boolean() | number() | String.t() | [json()] | %{optional(String.t()) => json()}
  @type entry :: nil | String.t() | [json()] | %{optional(String.t()) => json()}
  @type t :: %__MODULE__{
          type: :noul | :choice | :score,
          instructions: entry(),
          criteria: nil | %{optional(String.t()) => entry()} | [entry()]
        }
  @enforce_keys [:type, :instructions]
  defstruct [:type, :instructions, :criteria]

  @doc "Creates a probability-valued yes/no question with optional true/false criteria."
  @spec noul(entry(), map() | nil) :: {:ok, t()} | {:error, Error.t()}
  def noul(instructions, criteria \\ nil), do: build(:noul, instructions, criteria)

  @doc "Creates a choice question with 1 to 255 options mapped to rubric entries."
  @spec choice(entry(), map()) :: {:ok, t()} | {:error, Error.t()}
  def choice(instructions, criteria), do: build(:choice, instructions, criteria)

  @doc "Creates a score question with 2 to 10 ordered rubric entries."
  @spec score(entry(), [entry()]) :: {:ok, t()} | {:error, Error.t()}
  def score(instructions, criteria), do: build(:score, instructions, criteria)

  @doc "Like `noul/2`, but raises `Jevex.Error` on invalid input."
  @spec noul!(entry(), map() | nil) :: t()
  def noul!(instructions, criteria \\ nil), do: unwrap(noul(instructions, criteria))

  @doc "Like `choice/2`, but raises `Jevex.Error` on invalid input."
  @spec choice!(entry(), map()) :: t()
  def choice!(instructions, criteria), do: unwrap(choice(instructions, criteria))

  @doc "Like `score/2`, but raises `Jevex.Error` on invalid input."
  @spec score!(entry(), [entry()]) :: t()
  def score!(instructions, criteria), do: unwrap(score(instructions, criteria))

  @doc "Checks a question, including structs constructed or updated directly."
  @spec validate(term()) :: :ok | {:error, Error.t()}
  def validate(%__MODULE__{type: type, instructions: instructions, criteria: criteria}) do
    case build(type, instructions, criteria) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  def validate(_), do: invalid("expected a Jevex.Question")

  @doc "Returns a normalized string-keyed native API question; raises on invalid input."
  @spec encode(t()) :: map()
  def encode(%__MODULE__{type: type, instructions: instructions, criteria: criteria}) do
    q = unwrap(build(type, instructions, criteria))
    encoded = %{"type" => Atom.to_string(q.type), "instructions" => q.instructions}
    if is_nil(q.criteria), do: encoded, else: Map.put(encoded, "criteria", q.criteria)
  end

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
