# AGENTS.md

Instructions for AI coding agents working in this repository. Keep it short
and factual; every line here is sent to the model on every turn.

## Build and test

```sh
make          # library units into build/, CLI into bin/llmkit
make test     # builds and runs the offline suite (must stay at 0 failures)
make leaks    # same suite under heaptrc (must stay at 0 unfreed blocks)
make examples # every program in examples/
```

Free Pascal 3.2.2, `{$mode objfpc}{$H+}`. Only FPC-distribution units:
`fphttpclient`, `opensslsockets`, `fpjson`, `fgl`, `fpcunit`. Do not add
external dependencies.

Builds must stay clean under `-vw` (warnings shown). Fix new warnings rather
than silencing them; `crtbegin.o`/`crtend.o` linker warnings come from the
local toolchain and are not ours.

Tests never touch the network: provider tests run against the in-process fake
vendor in `tests/TestSupport.pas` on 127.0.0.1.

## Conventions

- Types `TFoo`, interfaces `IFoo`, exceptions `EFoo`; fields `FFoo`,
  parameters `AFoo`, two-space indent, `begin`/`end` on their own lines.
- Unit names are dotted: `LLMKit.Thing`, providers `LLMKit.Provider.Vendor`,
  file name matching the unit name exactly.
- Ownership is explicit and documented: a message owns its parts, a request
  owns its messages and tools, a response owns its parts. Anything a function
  returns is the caller's to free unless the comment says otherwise. Keep
  `make leaks` at zero.
- Public declarations get a short comment saying what the caller must know
  (ownership, units, failure mode) - not a restatement of the signature.
- Providers fail before the network: capability checks live in
  `TLLMProvider.Capabilities` and `TLLMClientBase.CheckParts/CheckTools`, and
  raise `ELLMUnsupported`.
- Vendor failures become `EAPIError` with a cross-vendor `TAPIErrorKind`; do
  not let raw `EHTTPClient` escape a provider.
- Serialise wire bodies with `CompactJSON`, never `AsJSON` directly, so
  fpjson's padding stays out of requests.
- Never log, echo or persist API keys; keys come from `TClientOptions` or the
  environment variable named in the README table.
- Commit messages: imperative subject under 72 characters, a body explaining
  why, and the `Co-Authored-By` trailer the agent was given.

## Layout

- `src/` - core model (`LLMKit.Core`), routing (`LLMKit.Registry`), transport
  (`LLMKit.HTTP`, `LLMKit.JSONUtil`), extras (`LLMKit.Stream`, `LLMKit.Tools`,
  `LLMKit.Catalog`) and the `LLMKit` façade that re-exports them.
- `src/providers/` - one unit per wire format.
  `LLMKit.Provider.OpenAICompat` is the shared `/chat/completions` base that
  DeepSeek, x.ai, Groq, OpenRouter, Hugging Face and custom endpoints
  configure through `TCompatConfig` + `TCompatQuirks`; prefer extending it
  over copying it.
- `tests/` - `TestCore` (model, sink, errors, catalog, collector),
  `TestRouting` (name resolution, capabilities), `TestWire` (end-to-end per
  provider), `TestTools`, `TestSupport` (fake vendor, scripted chatter).
  A new provider needs a `TestWire` case asserting both the JSON sent and the
  response decoded; a new routing rule needs a `TestRouting` case.
- `cmd/llmkit.pas` - CLI. `examples/` - small single-topic programs.
- `build/` and `bin/` are generated; never commit them.

Prices in `src/LLMKit.Catalog.pas` are hand-entered and indicative. If you
change a figure, verify it against the vendor's pricing page and bump
`CatalogDataAsOf` in the same commit.
