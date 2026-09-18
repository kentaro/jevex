# Publishing Jevex to Hex

Jevex is distributed as the `:jevex` Mix/Hex library. The source repository is
[kentaro/jevex](https://github.com/kentaro/jevex). This guide describes the
maintainer release process.

## Prepare the release

1. Set the intended version in `mix.exs` and update `CHANGELOG.md`. Review the
   supported Elixir requirement and dependency constraints before release.
2. Run the compatibility CI matrix: Elixir 1.17 with OTP 27 and Elixir 1.20 with
   OTP 29. Record actual results in `VALIDATION.md`; configured CI jobs do not
   establish that those environments have passed.
3. Review the English README, syntax and backend guides, module/function docs,
   and doctests together. Keep `~>` and `~>>` examples consistent with the API,
   verify links and code snippets, and preserve live-provider test limitations.
4. Inspect package metadata, license, dependency declarations, and included
   source files. Runtime dependencies are `req` and `jason`; `ex_doc` and
   `dialyxir` are development tools, not consumer runtime requirements.

From the project directory, complete the local checks:

```sh
mix deps.get
mix format --check-formatted
mix compile --warnings-as-errors
mix test --cover
mix dialyzer
mix docs --warnings-as-errors
```

Default tests use offline fixtures and loopback HTTP. Authenticated provider
tests remain opt-in and are documented in [Validation](../VALIDATION.md).

## Build and inspect the Hex package

These commands use Hex 2.5.1 task syntax:

```sh
mix hex.build
mix hex.build --unpack --output /tmp/jevex-release-inspect
mix hex.publish --dry-run --yes
```

Choose a fresh scratch directory for `--output`. `mix hex.build` creates the
standard `jevex-<version>.tar` artifact without publishing. With `--unpack`,
the output path is a directory containing the package source. The dry run
performs local packaging checks without releasing anything, but Hex 2.5.1 still
requires an authenticated maintainer session. CI uses `mix hex.build`, ExDoc, and
unpacked-package compilation instead, without publication credentials. A distribution ZIP
is not a substitute for this Hex artifact or a published dependency.

Review the unpacked file inventory and `mix.exs`. Include the required library
source, license, and source documentation. Exclude credentials, `.env` files,
secret-manager exports, `_build`, `deps`, generated `doc` output, scratch files,
and previous package artifacts. Confirm that the package contains no local
absolute paths needed to compile or run it.

Create a separate temporary Mix consumer using the unpacked source as a path
dependency. Resolve dependencies in that clean project, compile it with warnings
as errors, and exercise the documented syntax with a fake transport. This checks
that the package contents work without the maintainer checkout. It does not
prove registry publication or authenticated provider compatibility.

## Publish only an authorized release

After release authorization, confirm the Hex account and package ownership,
authenticate through the normal Hex workflow, and run:

```sh
mix hex.publish
```

This command publishes the package and automatically builds and publishes
documentation through ExDoc. Review its package summary and confirmation prompt.
Do not put Hex credentials in source files or shell history. Keep CI validation
separate from publication unless an explicit release workflow is configured.

After a successful release, verify the registry version and generated docs, then
fetch `{:jevex, "~> 0.1.0"}` in a fresh consumer (adjust the requirement for the
released version). Update release status and verified links only after that
verification succeeds.

See the official [Hex publishing guide](https://hex.pm/docs/publish) and the
installed `mix help hex.build` / `mix help hex.publish` for authoritative task
options and account setup.
