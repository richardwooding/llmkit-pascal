# llmkit-pascal

One Free Pascal client for eleven AI back-ends. Pick a model by name, code
against small single-method interfaces, and swap vendors without touching
call sites.

```pascal
uses LLMKit;

var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Chat := OpenChatter('claude-sonnet-4-5');
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('Explain iterators in one paragraph.'));
    Resp := Chat.Chat(Req);
    try
      WriteLn(Resp.Text);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;
```

A Pascal port of the design of
[github.com/richardwooding/llmkit](https://github.com/richardwooding/llmkit):
same message model, same routing rules, same "fail before the network call"
promise, expressed with interfaces, method pointers and explicit ownership
instead of generics and iterators.

Free Pascal 3.2.2, no external dependencies: `fphttpclient`, `opensslsockets`
and `fpjson` from the FPC distribution are all it uses.

## Why

**Small interfaces.** `IChatter`, `IStreamer`, `IEmbedder`, `IReranker` and
`ITokenCounter` have one method each. Ask for exactly what you need with
`OpenChatter`, `OpenStreamer`, `OpenEmbedder`, `OpenReranker` or
`OpenTokenCounter`; a provider that lacks the capability raises
`ELLMUnsupported` at construction, before any network call.

**Model-name routing.** `gpt-5`, `claude-sonnet-4-5`, `gemini-2.5-pro`,
`deepseek-reasoner`, `grok-4`, `command-a-03-2025`, `voyage-3-large` and
`llama3.2:3b` resolve on their own. Anything ambiguous takes a prefix:
`groq/llama-3.3-70b-versatile`, `openrouter/openai/gpt-4o`,
`hf/meta-llama/Llama-3.3-70B-Instruct`. Bare open-weight names fall back to a
local Ollama daemon.

**One message model.** Text, images, audio, documents, reasoning, tool calls
and tool results are typed parts; each provider maps what it supports and
rejects the rest up front.

**Streaming as events.** `Stream` takes a `TChunkEvent` method pointer and
calls it per chunk while the response is still arriving; return `False` and
the connection closes at once. `Collect` turns a stream back into a
`TLLMResponse`, reassembling tool-call arguments and reasoning blocks (with
their signatures) so the result can be appended to `Request.Messages`.

**Escape hatches.** `Request.Extra` and `Request.ProviderOptions` merge raw
JSON into the wire body; every response keeps its raw JSON in `Response.Raw`.

## Build

```sh
make            # library units in build/, CLI in bin/llmkit
make test       # 65 offline tests, including an in-process fake vendor
make leaks      # the same suite under heaptrc
make examples   # examples/*.pas into bin/
```

Use the library from your own program with
`fpc -Fu/path/to/src -Fu/path/to/src/providers yourprogram.pas`.

## Providers

| Provider | Names | Chat | Stream | Embed | Rerank | Count | Tools | Image | Audio | File | Cache hints | Auth |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| OpenAI (Responses API) | `gpt-*`, `o1/o3/o4*`, `text-embedding-3-*` | ✅ | ✅ | ✅ | – | – | ✅ | ✅ | – | ✅ | auto | `OPENAI_API_KEY` |
| Anthropic | `claude-*` | ✅ | ✅ | – | – | ✅ | ✅ | ✅ | – | ✅ | ✅ | `ANTHROPIC_API_KEY` |
| Vertex AI (REST) | `gemini-*`, `text-embedding-*` | ✅ | ✅ | ✅ | – | ✅ | ✅ | ✅ | ✅ | ✅ | auto | `GOOGLE_ACCESS_TOKEN` + `GOOGLE_CLOUD_PROJECT` |
| DeepSeek | `deepseek-*` | ✅ | ✅ | – | – | – | ✅¹ | – | – | – | auto | `DEEPSEEK_API_KEY` |
| x.ai (Grok) | `grok-*` | ✅ | ✅ | – | – | – | ✅ | ✅ | – | – | auto | `XAI_API_KEY` |
| Cohere | `command*`, `embed-*`, `rerank-*` | ✅ | ✅ | ✅ | ✅ | – | ✅ | ✅ | – | – | – | `COHERE_API_KEY` |
| VoyageAI | `voyage-*` | – | – | ✅ | ✅ | – | – | – | – | – | – | `VOYAGE_API_KEY` |
| Groq | `groq/…` | ✅ | ✅ | – | – | – | ✅ | ✅ | – | – | auto | `GROQ_API_KEY` |
| OpenRouter | `openrouter/…` | ✅ | ✅ | ✅ | – | – | ✅ | ✅ | – | ✅ | auto | `OPENROUTER_API_KEY` |
| Hugging Face | `org/model`, `hf/…` | ✅ | ✅ | ✅ | – | – | ✅ | ✅ | – | – | – | `HF_TOKEN` |
| Ollama | `name:tag`, bare fallback | ✅ | ✅ | ✅ | – | – | ✅ | ✅ | – | – | – | `OLLAMA_HOST` |

¹ `deepseek-reasoner` rejects tool definitions, so `capTools` is dropped for
that model and a request carrying tools fails with `ELLMUnsupported`.

"auto" providers cache prompt prefixes on their own and ignore
`Request.Cache`; Anthropic needs explicit `cache_control` breakpoints, which
`Request.Cache` places.

Every provider reads its key from the environment variable shown, or from
`TClientOptions.WithAPIKey`. `WithBaseURL`, `WithHeader`, `WithTimeout`,
`WithProject`, `WithLocation` and `WithOrganization` apply where relevant:

```pascal
Chat := OpenChatter('gpt-5',
  Options.WithAPIKey(MyKey).WithTimeout(30000).WithHeader('X-Trace', ID));
```

## Usage

### Streaming

```pascal
type
  TPrinter = class
    function OnChunk(const AChunk: TLLMChunk): Boolean;
  end;

function TPrinter.OnChunk(const AChunk: TLLMChunk): Boolean;
begin
  if AChunk.Kind = ckText then
    Write(AChunk.Text);
  Result := True;   { False stops the stream and closes the socket }
end;

Streamer := OpenStreamer('llama3.2:3b');
Resp := Collect(Streamer, Req, @Printer.OnChunk);
```

`Collect` without a callback just consumes the stream and returns the
assembled response; `TChunkCollector` is available on its own if you want to
accumulate and forward at the same time.

### Reasoning

```pascal
Req.Reasoning.Enabled := True;
Req.Reasoning.Effort := 'high';
Req.Reasoning.Summary := 'auto';
```

`Effort` steers how hard the model thinks. `Summary` asks for readable
thinking instead of empty blocks: Anthropic's `thinking.display` takes
`summarized`, `omitted` or `updates`, OpenAI's `reasoning.summary` takes
`auto`, `concise` or `detailed`, and each provider translates the other's
"show me a summary" value, so one setting works everywhere. Anthropic's
`max_tokens` defaults to 16384 when thinking is on, because thinking counts
against it, and a thinking budget is derived from `Effort` unless
`BudgetTokens` is set.

### Prompt caching

```pascal
Req.Cache.Enabled := True;
Req.Cache.System := True;
Req.Cache.Tools := True;
Req.Cache.Turns := 1;
Req.Cache.TTL := '1h';
```

On Anthropic this places `cache_control` breakpoints after the tool
definitions, after the system prompt and on the last `Turns` user turns, at
most four in total, stable prefix first. Every other provider caches prefixes
automatically and ignores the field. `Usage.CachedInputTokens` and
`Usage.CacheWriteTokens` report what was served from and written to the
cache; both are included in `Usage.InputTokens`, which is the whole prompt on
every provider (Anthropic reports them separately on the wire; the client
adds them back in).

### Counting tokens

```pascal
Counter := OpenTokenCounter('claude-opus-4-1');
N := Counter.CountTokens(Req);     { POST /messages/count_tokens, free }
```

Only Anthropic exposes a counting endpoint; `OpenTokenCounter` on another
provider raises `ELLMUnsupported`.

### Tool calling

```pascal
Tools := TToolSet.Create;
Tools.Add('weather', @Weather.Lookup);       { or a plain function }
Req.AddTool('weather', 'Current weather for a city',
  '{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}');
Resp := RunTools(Chat, Req, Tools, 5);
```

`RunTools` appends assistant and tool messages to `Req.Messages` until the
model stops calling tools, feeding handler exceptions back as error results.
Unknown tool names come back to the model as errors rather than raising.

### Multimodal input

```pascal
Req.Add(UserMessage([
  TextPart('Summarise the chart and the report.'),
  ImagePart(PNGBytes, 'image/png'),
  FilePart(PDFBytes, 'application/pdf', 'report.pdf')]));
```

Providers that cannot accept a part raise `ELLMUnsupported` before sending
anything.

### Embeddings and reranking

```pascal
Embedder := OpenEmbedder('voyage-3-large');
EmbedReq := TEmbedRequest.Create('voyage-3-large', ['first', 'second']);
EmbedReq.InputType := eiDocument;
EmbedResp := Embedder.Embed(EmbedReq);       { EmbedResp.Embeddings }

Reranker := OpenReranker('rerank-v3.5');
RerankResp := Reranker.Rerank(TRerankRequest.Create('rerank-v3.5',
  'go iterators', Docs));                    { best first }
```

### Model catalog

```pascal
uses LLMKit.Catalog;

Info := Lookup('anthropic/claude-sonnet-4-5-20250929');
if Info.Known then
  WriteLn(Info.ContextWindow, ' ', Info.MaxOutput, ' ', Info.Cost(Resp.Usage));
```

`Lookup` strips `provider/` prefixes and Vertex `@version` suffixes and
resolves dated snapshots by prefix; anything it does not know comes back with
`Known = False` and a zero cost rather than a guess. `RegisterModel`
overrides or adds rows.

The bundled table is hand-entered from vendor pricing pages as of
`CatalogDataAsOf` (2025-10-01) and is **indicative only**: rates change,
regional and batch pricing differ, and rerank endpoints bill per search
rather than per token. Check the figures before you bill anyone.

### Custom OpenAI-compatible endpoints

```pascal
Cfg := TCompatConfig.New('vllm', 'http://gpu-box:8000/v1');
Cfg.KeyOptional := True;
Cfg.Quirks.Images := True;
RegisterProvider(TOpenAICompatProvider.Create(Cfg));

Chat := OpenChatter('vllm/my-finetune');
```

### Errors, retries and rate limits

Provider failures are `EAPIError` with the HTTP status, the vendor error code,
a cross-vendor `Kind` and any `Retry-After` hint:

```pascal
try
  Resp := Chat.Chat(Req);
except
  on E: EAPIError do
    if IsRateLimited(E) then
      Sleep(Max(E.RetryAfter, 1) * 1000)
    else if IsContextLength(E) then
      TrimHistory;
end;
```

llmkit-pascal does not retry and does not cache. Both belong in a layer you
put around it.

## Command line

```sh
llmkit chat -m claude-sonnet-4-5 "Explain iterators in one paragraph"
echo "Summarise this" | llmkit chat -m llama3.2:3b --stream -v
llmkit embed -m voyage-3-large "first" "second"
llmkit rerank -m rerank-v3.5 -q "go iterators" doc1 doc2 doc3
llmkit count -m claude-opus-4-1 "how long is this?"
llmkit resolve gpt-5 openrouter/openai/gpt-4o meta-llama/Llama-3.3-70B-Instruct
llmkit models claude
```

## Resolution rules

1. If the text before the first `/` is a registered provider id or alias,
   that provider gets the rest (`openrouter/openai/gpt-4o`).
2. Otherwise the first provider whose `Matches` accepts the bare name wins,
   in registration order: OpenAI, Anthropic, Vertex, DeepSeek, x.ai, Cohere,
   VoyageAI by prefix; Ollama for anything with a `:tag`; Hugging Face for
   `org/model`.
3. Otherwise the fallback: `SetFallback`, then `LLMKIT_DEFAULT_PROVIDER`,
   then `ollama`.

## Units

| Unit | What is in it |
|---|---|
| `LLMKit` | façade: types, factories and helpers in one `uses` |
| `LLMKit.Core` | parts, messages, requests, responses, usage, errors, interfaces |
| `LLMKit.Registry` | `TClientOptions`, provider base class, routing, `Open*` |
| `LLMKit.HTTP` | JSON and SSE/NDJSON transport, error classification |
| `LLMKit.JSONUtil` | nil-safe fpjson helpers, base64, compact serialisation |
| `LLMKit.Client` | client base class and part/tool capability checks |
| `LLMKit.Stream` | `Collect`, `TChunkCollector` |
| `LLMKit.Tools` | `TToolSet`, `RunTools` |
| `LLMKit.Catalog` | context windows, output limits, list prices |
| `LLMKit.Providers` | registers the built-ins; helper for custom endpoints |
| `LLMKit.Provider.*` | one unit per wire format |

## Memory ownership

* A message owns its parts, a request owns its messages and tools, a response
  owns its parts: free the top object and the rest goes with it.
* Helper constructors (`UserText`, `ImagePart`, …) hand ownership to the
  caller; adding them to a message or request transfers it.
* `Chat`, `Embed`, `Rerank` and `Collect` return objects the caller frees.
* `Response.ToolCalls` returns a list that does **not** own its items.
* Clients are reference-counted interfaces; there is nothing to free.

The test suite runs clean under `heaptrc` (`make leaks`): 0 unfreed blocks.

## Differences from the Go original

* **No Vertex AI over gRPC** and **no Google ADC**: Free Pascal ships neither
  gRPC nor an oauth2 credential chain. The Vertex provider is REST only and
  takes a bearer token from `GOOGLE_ACCESS_TOKEN`
  (`gcloud auth print-access-token`) or `WithAPIKey`.
* **Streaming is a callback**, not an iterator: Pascal has no `iter.Seq2`, and
  FPC 3.2.2 has no anonymous functions, so `Stream` takes a method pointer and
  a `False` return stops it.
* **No `context.Context`**: cancellation is "return False from the chunk
  event", and deadlines are `WithTimeout` on the client options.
* **Capabilities are explicit** (`TCapability`) because there is no generic
  `Open[T]`; the registry checks them before the client is built, which is
  where `Open[T]` would have failed.
* Vertex paths percent-encode the `:` in `:generateContent`, because FPC's
  `ParseURI` otherwise appends a stray `/`.

## Testing

`make test` runs 65 tests with no network access: routing and capability
rules, request bodies and response decoding for every provider against an
in-process fake vendor on `127.0.0.1`, SSE and NDJSON parsing including
events split across socket writes, stream cancellation, the tool loop, error
classification and the catalog.

## License

MIT.
