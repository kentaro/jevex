defmodule Jevex.CoreDoctestTest do
  use ExUnit.Case, async: true

  doctest Jevex
  doctest Jevex.HTTP
  doctest Jevex.Fallback
  doctest Jevex.Error
  doctest Jevex.Transport
  doctest Jevex.Transport.Req
end
