defmodule Jevex.BackendsDoctestTest do
  use ExUnit.Case, async: true

  doctest Jevex.Backend
  doctest Jevex.Backends.Native
  doctest Jevex.Backends.TypeSafe
  doctest Jevex.Backends.Lolipop
  doctest Jevex.Backends.OpenRouter
  doctest Jevex.Backends.Cloudflare
  doctest Jevex.Backends.Vercel
  doctest Jevex.Backends.Custom
  doctest Jevex.Client
end
