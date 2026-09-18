defmodule Jevex.DocumentationTest do
  use ExUnit.Case, async: true

  test "every authored module, exported function, macro, and callback has English documentation" do
    {:ok, modules} = :application.get_key(:jevex, :modules)

    for module <- modules, module != Inspect.Jevex.Client do
      {:docs_v1, _, _, _, module_doc, _, entries} = Code.fetch_docs(module)
      assert_english_doc(module_doc, inspect(module))

      for {{kind, name, arity}, _, _, doc, _} <- entries,
          kind in [:function, :macro, :callback],
          name not in [:__struct__, :__info__, :module_info] do
        assert_english_doc(doc, "#{inspect(module)}.#{name}/#{arity}")
      end
    end
  end

  defp assert_english_doc(doc, label) do
    assert %{"en" => text} = doc, "Missing English documentation: #{label}"
    assert String.trim(text) != "", "Empty documentation: #{label}"

    refute Regex.match?(~r/[\p{Hiragana}\p{Katakana}\p{Han}]/u, text),
           "Non-English documentation: #{label}"
  end
end
