{ LLMKit.Catalog - a static table of context windows, output limits and list
  prices.

  Lookup strips "provider/" prefixes and Vertex "@version" suffixes and
  resolves dated snapshots by prefix ("claude-sonnet-4-5-20250929" finds
  "claude-sonnet-4-5"). Anything unknown comes back with Known = False and a
  zero cost rather than a guess.

  The figures are hand-entered from vendor pricing pages as of CatalogDataAsOf
  and are indicative only: rates change, regional and batch pricing differ,
  and rerank endpoints bill per search rather than per token. Treat this as a
  starting table and override it with Register.
}
unit LLMKit.Catalog;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, LLMKit.Core;

const
  CatalogDataAsOf = '2025-10-01';

type
  { Prices are US dollars per million tokens. }
  TModelInfo = record
    Name: string;
    Provider: string;
    ContextWindow: Integer;
    MaxOutput: Integer;
    InputCost: Double;
    OutputCost: Double;
    CacheReadCost: Double;
    CacheWriteCost: Double;
    Capabilities: TCapabilities;
    Known: Boolean;
    { USD for a call that reported AUsage. Cached and cache-write tokens are
      billed at their own rate and removed from the plain input count. }
    function Cost(const AUsage: TUsage): Double;
    function CostString(const AUsage: TUsage): string;
  end;

{ Returns the entry for AName, or Known = False when the table has nothing. }
function Lookup(const AName: string): TModelInfo;
{ Adds or replaces an entry. }
procedure RegisterModel(const AInfo: TModelInfo);
function CatalogCount: Integer;
function CatalogEntry(AIndex: Integer): TModelInfo;
{ Normalises "anthropic/claude-sonnet-4-5" or "gemini-2.5-pro@default". }
function NormaliseModelName(const AName: string): string;

implementation

var
  GModels: array of TModelInfo;

function TModelInfo.Cost(const AUsage: TUsage): Double;
var
  PlainInput: Integer;
begin
  if not Known then
    Exit(0);
  PlainInput := AUsage.InputTokens - AUsage.CachedInputTokens -
    AUsage.CacheWriteTokens;
  if PlainInput < 0 then
    PlainInput := 0;
  Result := (PlainInput / 1000000) * InputCost +
            (AUsage.CachedInputTokens / 1000000) * CacheReadCost +
            (AUsage.CacheWriteTokens / 1000000) * CacheWriteCost +
            (AUsage.OutputTokens / 1000000) * OutputCost;
end;

function TModelInfo.CostString(const AUsage: TUsage): string;
begin
  Result := '$' + FormatFloat('0.000000', Cost(AUsage));
end;

function NormaliseModelName(const AName: string): string;
var
  P: Integer;
begin
  Result := LowerCase(Trim(AName));
  { drop a trailing @version (Vertex) }
  P := Pos('@', Result);
  if P > 0 then
    Result := Copy(Result, 1, P - 1);
  { drop provider prefixes, including nested ones like openrouter/openai/x }
  P := Pos('/', Result);
  while P > 0 do
  begin
    Result := Copy(Result, P + 1, MaxInt);
    P := Pos('/', Result);
  end;
end;

procedure RegisterModel(const AInfo: TModelInfo);
var
  I: Integer;
  Info: TModelInfo;
begin
  Info := AInfo;
  Info.Known := True;
  Info.Name := LowerCase(Info.Name);
  for I := 0 to High(GModels) do
    if GModels[I].Name = Info.Name then
    begin
      GModels[I] := Info;
      Exit;
    end;
  SetLength(GModels, Length(GModels) + 1);
  GModels[High(GModels)] := Info;
end;

function CatalogCount: Integer;
begin
  Result := Length(GModels);
end;

function CatalogEntry(AIndex: Integer): TModelInfo;
begin
  if (AIndex < 0) or (AIndex > High(GModels)) then
    Exit(Default(TModelInfo));
  Result := GModels[AIndex];
end;

function Lookup(const AName: string): TModelInfo;
var
  Name: string;
  I, BestLen: Integer;
begin
  Result := Default(TModelInfo);
  Name := NormaliseModelName(AName);
  if Name = '' then
    Exit;
  for I := 0 to High(GModels) do
    if GModels[I].Name = Name then
      Exit(GModels[I]);
  { dated snapshots: the longest registered name that is a prefix wins }
  BestLen := 0;
  for I := 0 to High(GModels) do
    if (Length(GModels[I].Name) > BestLen) and
       (Copy(Name, 1, Length(GModels[I].Name)) = GModels[I].Name) then
    begin
      Result := GModels[I];
      BestLen := Length(GModels[I].Name);
    end;
end;

procedure Add(const AName, AProvider: string; AContext, AMaxOutput: Integer;
  AIn, AOut, ACacheRead, ACacheWrite: Double; ACaps: TCapabilities);
var
  Info: TModelInfo;
begin
  Info := Default(TModelInfo);
  Info.Name := AName;
  Info.Provider := AProvider;
  Info.ContextWindow := AContext;
  Info.MaxOutput := AMaxOutput;
  Info.InputCost := AIn;
  Info.OutputCost := AOut;
  Info.CacheReadCost := ACacheRead;
  Info.CacheWriteCost := ACacheWrite;
  Info.Capabilities := ACaps;
  RegisterModel(Info);
end;

const
  ChatCaps = [capChat, capStream, capTools];
  VisionCaps = [capChat, capStream, capTools, capImages];
  ThinkCaps = [capChat, capStream, capTools, capImages, capReasoning];
  ClaudeCaps = [capChat, capStream, capTools, capImages, capFiles,
                capReasoning, capCountTokens, capCacheHints];
  GeminiCaps = [capChat, capStream, capTools, capImages, capAudio, capFiles,
                capReasoning, capCountTokens];

procedure Seed;
begin
  { OpenAI }
  Add('gpt-5', 'openai', 400000, 128000, 1.25, 10.00, 0.125, 0, ThinkCaps);
  Add('gpt-5-mini', 'openai', 400000, 128000, 0.25, 2.00, 0.025, 0, ThinkCaps);
  Add('gpt-5-nano', 'openai', 400000, 128000, 0.05, 0.40, 0.005, 0, ThinkCaps);
  Add('gpt-4.1', 'openai', 1047576, 32768, 2.00, 8.00, 0.50, 0, VisionCaps);
  Add('gpt-4.1-mini', 'openai', 1047576, 32768, 0.40, 1.60, 0.10, 0, VisionCaps);
  Add('gpt-4.1-nano', 'openai', 1047576, 32768, 0.10, 0.40, 0.025, 0, VisionCaps);
  Add('gpt-4o', 'openai', 128000, 16384, 2.50, 10.00, 1.25, 0, VisionCaps);
  Add('gpt-4o-mini', 'openai', 128000, 16384, 0.15, 0.60, 0.075, 0, VisionCaps);
  Add('o3', 'openai', 200000, 100000, 2.00, 8.00, 0.50, 0, ThinkCaps);
  Add('o4-mini', 'openai', 200000, 100000, 1.10, 4.40, 0.275, 0, ThinkCaps);
  Add('text-embedding-3-small', 'openai', 8191, 0, 0.02, 0, 0, 0, [capEmbed]);
  Add('text-embedding-3-large', 'openai', 8191, 0, 0.13, 0, 0, 0, [capEmbed]);

  { Anthropic }
  Add('claude-opus-4-1', 'anthropic', 200000, 32000, 15.00, 75.00, 1.50, 18.75,
    ClaudeCaps);
  Add('claude-sonnet-4-5', 'anthropic', 200000, 64000, 3.00, 15.00, 0.30, 3.75,
    ClaudeCaps);
  Add('claude-sonnet-4', 'anthropic', 200000, 64000, 3.00, 15.00, 0.30, 3.75,
    ClaudeCaps);
  Add('claude-haiku-4-5', 'anthropic', 200000, 64000, 1.00, 5.00, 0.10, 1.25,
    ClaudeCaps);
  Add('claude-3-5-haiku', 'anthropic', 200000, 8192, 0.80, 4.00, 0.08, 1.00,
    ClaudeCaps);

  { Google }
  Add('gemini-2.5-pro', 'vertex', 1048576, 65536, 1.25, 10.00, 0.31, 0,
    GeminiCaps);
  Add('gemini-2.5-flash', 'vertex', 1048576, 65536, 0.30, 2.50, 0.075, 0,
    GeminiCaps);
  Add('gemini-2.5-flash-lite', 'vertex', 1048576, 65536, 0.10, 0.40, 0.025, 0,
    GeminiCaps);
  Add('text-embedding-005', 'vertex', 2048, 0, 0.025, 0, 0, 0, [capEmbed]);

  { DeepSeek }
  Add('deepseek-chat', 'deepseek', 131072, 8192, 0.27, 1.10, 0.07, 0, ChatCaps);
  Add('deepseek-reasoner', 'deepseek', 131072, 65536, 0.55, 2.19, 0.14, 0,
    [capChat, capStream, capReasoning]);

  { x.ai }
  Add('grok-4', 'xai', 256000, 0, 3.00, 15.00, 0.75, 0, VisionCaps);
  Add('grok-3-mini', 'xai', 131072, 0, 0.30, 0.50, 0.075, 0, ChatCaps);

  { Cohere }
  Add('command-a-03-2025', 'cohere', 256000, 8192, 2.50, 10.00, 0, 0, VisionCaps);
  Add('command-r-plus-08-2024', 'cohere', 128000, 4096, 2.50, 10.00, 0, 0,
    ChatCaps);
  Add('command-r7b-12-2024', 'cohere', 128000, 4096, 0.0375, 0.15, 0, 0, ChatCaps);
  Add('embed-v4.0', 'cohere', 128000, 0, 0.12, 0, 0, 0, [capEmbed]);
  { rerank bills per search, not per token }
  Add('rerank-v3.5', 'cohere', 4096, 0, 0, 0, 0, 0, [capRerank]);

  { VoyageAI }
  Add('voyage-3-large', 'voyage', 32000, 0, 0.18, 0, 0, 0, [capEmbed]);
  Add('voyage-3.5', 'voyage', 32000, 0, 0.06, 0, 0, 0, [capEmbed]);
  Add('voyage-3.5-lite', 'voyage', 32000, 0, 0.02, 0, 0, 0, [capEmbed]);
  Add('voyage-code-3', 'voyage', 32000, 0, 0.18, 0, 0, 0, [capEmbed]);

  { Local models are free; the context window is the useful part. }
  Add('llama3.2', 'ollama', 131072, 0, 0, 0, 0, 0, ChatCaps);
  Add('llama3.3', 'ollama', 131072, 0, 0, 0, 0, 0, ChatCaps);
  Add('qwen3', 'ollama', 40960, 0, 0, 0, 0, 0, ChatCaps);
  Add('gemma3', 'ollama', 131072, 0, 0, 0, 0, 0, VisionCaps);
  Add('nomic-embed-text', 'ollama', 8192, 0, 0, 0, 0, 0, [capEmbed]);
end;

initialization
  Seed;

end.
