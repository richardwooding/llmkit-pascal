{ Model-name routing, capabilities and the errors raised before any call. }
unit TestRouting;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpcunit, testregistry, LLMKit.Core, LLMKit.Registry,
  LLMKit.Providers;

type
  TRoutingTest = class(TTestCase)
  published
    procedure BareNamesFindTheirProvider;
    procedure PrefixRouteWins;
    procedure NestedPrefixKeepsTheRest;
    procedure AliasesRoute;
    procedure TaggedNamesGoToOllama;
    procedure OrgSlashModelGoesToHuggingFace;
    procedure UnknownNameFallsBack;
    procedure FallbackIsConfigurable;
    procedure EmptyNameFails;
    procedure CapabilitiesPerModel;
    procedure EmbeddingModelCannotChat;
    procedure ChatModelCannotEmbed;
    procedure OnlyAnthropicCountsTokens;
    procedure DeepSeekReasonerRejectsTools;
  end;

implementation

procedure TRoutingTest.BareNamesFindTheirProvider;
begin
  AssertEquals('openai/gpt-5', ResolveToString('gpt-5'));
  AssertEquals('openai/o4-mini', ResolveToString('o4-mini'));
  AssertEquals('anthropic/claude-sonnet-4-5', ResolveToString('claude-sonnet-4-5'));
  AssertEquals('vertex/gemini-2.5-pro', ResolveToString('gemini-2.5-pro'));
  AssertEquals('deepseek/deepseek-reasoner', ResolveToString('deepseek-reasoner'));
  AssertEquals('xai/grok-4', ResolveToString('grok-4'));
  AssertEquals('cohere/command-a-03-2025', ResolveToString('command-a-03-2025'));
  AssertEquals('cohere/rerank-v3.5', ResolveToString('rerank-v3.5'));
  AssertEquals('voyage/voyage-3-large', ResolveToString('voyage-3-large'));
end;

procedure TRoutingTest.PrefixRouteWins;
begin
  AssertEquals('groq/llama-3.3-70b-versatile',
    ResolveToString('groq/llama-3.3-70b-versatile'));
  { the prefix beats the bare-name match }
  AssertEquals('openrouter/gpt-5', ResolveToString('openrouter/gpt-5'));
end;

procedure TRoutingTest.NestedPrefixKeepsTheRest;
begin
  AssertEquals('openrouter/openai/gpt-4o',
    ResolveToString('openrouter/openai/gpt-4o'));
  AssertEquals('huggingface/meta-llama/Llama-3.3-70B-Instruct',
    ResolveToString('hf/meta-llama/Llama-3.3-70B-Instruct'));
end;

procedure TRoutingTest.AliasesRoute;
begin
  AssertEquals('huggingface/x', ResolveToString('hf/x'));
  AssertEquals('anthropic/claude-sonnet-4-5',
    ResolveToString('claude/claude-sonnet-4-5'));
  AssertEquals('vertex/gemini-2.5-flash', ResolveToString('google/gemini-2.5-flash'));
end;

procedure TRoutingTest.TaggedNamesGoToOllama;
begin
  AssertEquals('ollama/llama3.2:3b', ResolveToString('llama3.2:3b'));
  AssertEquals('ollama/qwen3:8b', ResolveToString('qwen3:8b'));
end;

procedure TRoutingTest.OrgSlashModelGoesToHuggingFace;
begin
  AssertEquals('huggingface/meta-llama/Llama-3.3-70B-Instruct',
    ResolveToString('meta-llama/Llama-3.3-70B-Instruct'));
end;

procedure TRoutingTest.UnknownNameFallsBack;
begin
  AssertEquals('ollama/mistral-small', ResolveToString('mistral-small'));
end;

procedure TRoutingTest.FallbackIsConfigurable;
begin
  SetFallback('groq');
  try
    AssertEquals('groq/mistral-small', ResolveToString('mistral-small'));
  finally
    SetFallback('');
  end;
  AssertEquals('ollama/mistral-small', ResolveToString('mistral-small'));
end;

procedure TRoutingTest.EmptyNameFails;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    Resolve('   ');
  except
    on ELLMNoProvider do
      Raised := True;
  end;
  AssertTrue('empty name must not resolve', Raised);
end;

procedure TRoutingTest.CapabilitiesPerModel;
begin
  AssertTrue('claude counts tokens',
    capCountTokens in CapabilitiesOf('claude-sonnet-4-5'));
  AssertTrue('claude takes cache hints',
    capCacheHints in CapabilitiesOf('claude-sonnet-4-5'));
  AssertFalse('gpt-5 has no counting endpoint',
    capCountTokens in CapabilitiesOf('gpt-5'));
  AssertTrue('voyage reranks', capRerank in CapabilitiesOf('voyage/rerank-2.5'));
  AssertFalse('voyage does not chat', capChat in CapabilitiesOf('voyage-3-large'));
end;

procedure TRoutingTest.EmbeddingModelCannotChat;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    OpenChatter('voyage-3-large');
  except
    on E: ELLMUnsupported do
      Raised := True;
  end;
  AssertTrue('chat on an embedding-only provider must fail fast', Raised);
end;

procedure TRoutingTest.ChatModelCannotEmbed;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    OpenEmbedder('claude-sonnet-4-5');
  except
    on E: ELLMUnsupported do
      Raised := True;
  end;
  AssertTrue('anthropic has no embeddings', Raised);
end;

procedure TRoutingTest.OnlyAnthropicCountsTokens;
var
  Raised: Boolean;
begin
  Raised := False;
  try
    OpenTokenCounter('gpt-5');
  except
    on E: ELLMUnsupported do
      Raised := True;
  end;
  AssertTrue('counting is Anthropic only', Raised);
end;

procedure TRoutingTest.DeepSeekReasonerRejectsTools;
begin
  AssertFalse('deepseek-reasoner takes no tools',
    capTools in CapabilitiesOf('deepseek-reasoner'));
  AssertTrue('deepseek-chat takes tools',
    capTools in CapabilitiesOf('deepseek-chat'));
end;

initialization
  RegisterTest(TRoutingTest);

end.
