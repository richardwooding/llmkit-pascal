{ LLMKit.Providers - registers the built-in providers.

  Registration order is match priority for bare model names: OpenAI,
  Anthropic, Vertex, DeepSeek, x.ai, Cohere, VoyageAI by prefix, then Ollama
  for anything with a ":tag", then Hugging Face for "org/model". Providers
  reachable only through a "prefix/" route (Groq, OpenRouter) match nothing on
  their own.

  Add a private OpenAI-compatible endpoint with:

    Cfg := NewCompatConfig('vllm', 'http://gpu-box:8000/v1');
    Cfg.KeyOptional := True;
    Cfg.Quirks.Images := True;
    RegisterProvider(TOpenAICompatProvider.Create(Cfg));
    Chat := OpenChatter('vllm/my-finetune');
}
unit LLMKit.Providers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, LLMKit.Core, LLMKit.HTTP, LLMKit.Registry,
  LLMKit.Provider.OpenAICompat, LLMKit.Provider.OpenAI,
  LLMKit.Provider.Anthropic, LLMKit.Provider.Vertex, LLMKit.Provider.Ollama,
  LLMKit.Provider.Cohere, LLMKit.Provider.Voyage;

{ Registers every built-in provider. Called automatically when this unit is
  used; calling it again is harmless. }
procedure RegisterDefaultProviders;
{ A config with the usual defaults filled in. }
function NewCompatConfig(const AID, ABaseURL: string): TCompatConfig;

implementation

function NewCompatConfig(const AID, ABaseURL: string): TCompatConfig;
begin
  Result := TCompatConfig.New(AID, ABaseURL);
end;

function DeepSeekConfig: TCompatConfig;
begin
  Result := TCompatConfig.New('deepseek', 'https://api.deepseek.com/v1');
  Result.EnvKeys := StringArrayOf(['DEEPSEEK_API_KEY']);
  Result.Prefixes := StringArrayOf(['deepseek-']);
end;

function XAIConfig: TCompatConfig;
begin
  Result := TCompatConfig.New('xai', 'https://api.x.ai/v1');
  Result.Aliases := StringArrayOf(['grok']);
  Result.EnvKeys := StringArrayOf(['XAI_API_KEY']);
  Result.Prefixes := StringArrayOf(['grok-']);
  Result.Quirks.Images := True;
  Result.Quirks.Reasoning := True;
end;

function GroqConfig: TCompatConfig;
begin
  Result := TCompatConfig.New('groq', 'https://api.groq.com/openai/v1');
  Result.EnvKeys := StringArrayOf(['GROQ_API_KEY']);
  Result.Quirks.Images := True;
  Result.Quirks.Reasoning := True;
end;

function OpenRouterConfig: TCompatConfig;
begin
  Result := TCompatConfig.New('openrouter', 'https://openrouter.ai/api/v1');
  Result.Aliases := StringArrayOf(['or']);
  Result.EnvKeys := StringArrayOf(['OPENROUTER_API_KEY']);
  Result.Quirks.Images := True;
  Result.Quirks.Files := True;
  Result.Quirks.Embeddings := True;
  Result.Quirks.Reasoning := True;
  Result.Quirks.JSONSchema := True;
end;

function HuggingFaceConfig: TCompatConfig;
begin
  Result := TCompatConfig.New('huggingface', 'https://router.huggingface.co/v1');
  Result.Aliases := StringArrayOf(['hf']);
  Result.EnvKeys := StringArrayOf(['HF_TOKEN', 'HUGGINGFACE_API_KEY']);
  Result.MatchSlashNames := True;
  Result.Quirks.Images := True;
  Result.Quirks.Embeddings := True;
  Result.Quirks.StreamUsage := False;
end;

var
  GRegistered: Boolean = False;

procedure RegisterDefaultProviders;
begin
  if GRegistered then
    Exit;
  GRegistered := True;
  RegisterProvider(TOpenAIProvider.Create);
  RegisterProvider(TAnthropicProvider.Create);
  RegisterProvider(TVertexProvider.Create);
  RegisterProvider(TOpenAICompatProvider.Create(DeepSeekConfig));
  RegisterProvider(TOpenAICompatProvider.Create(XAIConfig));
  RegisterProvider(TCohereProvider.Create);
  RegisterProvider(TVoyageProvider.Create);
  RegisterProvider(TOpenAICompatProvider.Create(GroqConfig));
  RegisterProvider(TOpenAICompatProvider.Create(OpenRouterConfig));
  RegisterProvider(TOpenAICompatProvider.Create(HuggingFaceConfig));
  RegisterProvider(TOllamaProvider.Create);
end;

initialization
  RegisterDefaultProviders;

end.
