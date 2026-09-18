defmodule Jevex.Answer.Noul do
  @moduledoc "A yes probability in the inclusive range 0..1, not a boolean."
  @enforce_keys [:noul]
  defstruct [:noul]
  @type t :: %__MODULE__{noul: number()}
end

defmodule Jevex.Answer.Choice do
  @moduledoc "A selected string option, its full probability distribution, and confidence (0..1). No response strings are converted into atoms."
  @enforce_keys [:choice, :probabilities, :confidence]
  defstruct [:choice, :probabilities, :confidence]

  @type t(choice_value) :: %__MODULE__{
          choice: choice_value,
          probabilities: %{String.t() => number()} | nil,
          confidence: number() | nil
        }
  @type t :: t(String.t())
end

defmodule Jevex.Answer.Score do
  @moduledoc "A probability-weighted score across zero-based rubric levels, their legend and probabilities, and confidence (0..1)."
  @enforce_keys [:score, :legend, :probabilities, :confidence]
  defstruct [:score, :legend, :probabilities, :confidence]

  @type t :: %__MODULE__{
          score: number(),
          legend: %{String.t() => Jevex.Question.entry()},
          probabilities: %{String.t() => number()} | nil,
          confidence: number() | nil
        }
end

defmodule Jevex.Answer do
  @moduledoc "The tagged union of validated native Jev answer structs."
  @type t :: Jevex.Answer.Noul.t() | Jevex.Answer.Choice.t() | Jevex.Answer.Score.t()
end
