defmodule Jevex.Answer.Noul do
  @moduledoc """
  A validated yes probability in the inclusive range 0 to 1.

  Syntax extracts this probability with `{:noul, question}` or converts it to
  a boolean for a string question. Explicit evaluation preserves this struct.

  `noul` is numeric, not a boolean: a value near zero means "no", near one
  means "yes", and near 0.5 indicates uncertainty. The optional evaluation gate
  `min_noul_certainty` uses `max(p, 1 - p)` rather than the probability of yes.

  Constructed directly, this struct does not validate its value. Normally obtain
  answers from `Jevex.Response.decode/3` or `Jevex.evaluate/4`.

      iex> answer = %Jevex.Answer.Noul{noul: 0.1}
      iex> max(answer.noul, 1 - answer.noul)
      0.9
  """
  @enforce_keys [:noul]
  defstruct [:noul]
  @typedoc "A yes probability; runtime decoding enforces the inclusive 0..1 bound."
  @type t :: %__MODULE__{noul: number()}
end

defmodule Jevex.Answer.Choice do
  @moduledoc """
  A selected option with optional probabilities and confidence.

  Syntax extracts the original declared choice key. Use explicit evaluation
  when the complete distribution or provider-reported confidence is needed.

  The direct API returns `choice` as a string. A schema may restore a declared
  atom choice using its closed lookup table. `probabilities`, when present,
  always uses string keys, includes every declared option, and sums to one
  within the decoder's tolerance. `confidence`, when present, is in 0..1.
  Supported router protocols may omit either metadata field; absence is `nil`,
  not zero. Confidence is provider-reported; it is not recomputed from the
  selected option's probability.

  Use `t/1` for a schema's specific choice type and `t/0` for direct responses.
  Struct construction alone does not validate any field.

      iex> answer = %Jevex.Answer.Choice{choice: :billing, probabilities: %{"billing" => 0.8, "support" => 0.2}, confidence: 0.8}
      iex> {answer.choice, answer.probabilities["billing"]}
      {:billing, 0.8}
  """
  @enforce_keys [:choice, :probabilities, :confidence]
  defstruct [:choice, :probabilities, :confidence]

  @typedoc "A choice answer whose selected value has the supplied type."
  @type t(choice_value) :: %__MODULE__{
          choice: choice_value,
          probabilities: %{String.t() => number()} | nil,
          confidence: number() | nil
        }
  @typedoc "A direct-API answer with a string selected value."
  @type t :: t(String.t())
end

defmodule Jevex.Answer.Score do
  @moduledoc """
  A numeric score across zero-based rubric levels with legend and metadata.

  Syntax extracts the numeric score from a question and its ordered levels.
  Explicit evaluation retains the legend and optional metadata in this struct.

  For `n` rubric entries, `score` is within 0..(n - 1) and may be fractional.
  The provider reports the score; the decoder checks bounds but does not require
  it to equal the weighted average of the supplied probability distribution.
  `legend` maps string level indices to rubric entries. Its coverage and value
  shapes are checked, but supplied legend descriptions need not exactly match
  the original text. In partial-metadata mode, an omitted legend is reconstructed
  from the requested rubric.

  `probabilities` and `confidence` may be `nil` for supported router protocols.
  Present distributions cover every level and sum to one within the decoder's
  tolerance; confidence is in 0..1. Direct struct construction does not validate.

      iex> answer = %Jevex.Answer.Score{score: 0.75, legend: %{"0" => "Low", "1" => "High"}, probabilities: %{"0" => 0.25, "1" => 0.75}, confidence: 0.75}
      iex> {answer.score, answer.legend["1"]}
      {0.75, "High"}
  """
  @enforce_keys [:score, :legend, :probabilities, :confidence]
  defstruct [:score, :legend, :probabilities, :confidence]

  @typedoc "A bounded numeric score, level legend, and optional provider metadata."
  @type t :: %__MODULE__{
          score: number(),
          legend: %{String.t() => Jevex.Question.entry()},
          probabilities: %{String.t() => number()} | nil,
          confidence: number() | nil
        }
end

defmodule Jevex.Answer do
  @moduledoc """
  The tagged union of the explicit evaluation API's validated answer structs.

  Syntax operators extract scalar decisions; this union is useful for typed
  batches, response inspection, and custom fallback implementations.

  Pattern-match on `Jevex.Answer.Noul`, `Jevex.Answer.Choice`, or
  `Jevex.Answer.Score` to distinguish answer kinds. The union uses string choice
  values; schema-specific choice atoms are represented by the schema's generated
  `t:t/0` type and `t:Jevex.Answer.Choice.t/1`.
  """
  @typedoc "Any of the three answer kinds returned by the direct API."
  @type t :: Jevex.Answer.Noul.t() | Jevex.Answer.Choice.t() | Jevex.Answer.Score.t()
end
