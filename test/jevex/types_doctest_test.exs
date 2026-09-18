defmodule Jevex.TypesDoctestTest do
  use ExUnit.Case, async: true

  # Jevex.Question doctests are registered by question_test.exs.
  doctest Jevex.Answer.Noul
  doctest Jevex.Answer.Choice
  doctest Jevex.Answer.Score
  doctest Jevex.Response
  doctest Jevex.Schema
end
