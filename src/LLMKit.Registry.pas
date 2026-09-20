{ LLMKit.Registry - provider registration, model-name routing and factories.

  Resolution rules, in order:
    1. text before the first '/' that names a registered provider or alias
       wins and the rest is the model ("openrouter/openai/gpt-4o");
    2. otherwise the first provider whose Matches accepts the bare name
       (registration order is priority);
    3. otherwise the fallback: SetFallback, then LLMKIT_DEFAULT_PROVIDER,
       then "ollama".

  Asking for a capability a provider lacks fails with ELLMUnsupported at
  construction, before any network call.
}
unit LLMKit.Registry;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, fgl, LLMKit.Core, LLMKit.HTTP;

type
  { Per-client settings. A value type, so it is safe to pass around and
    modify without ownership questions. }
  TClientOptions = record
    APIKey: string;
    BaseURL: string;
    Organization: string;  { OpenAI }
    Project: string;       { OpenAI / Vertex }
    Location: string;      { Vertex }
    TimeoutMS: Integer;
    Headers: THeaderArray;
    class function Default: TClientOptions; static;
    function WithAPIKey(const AValue: string): TClientOptions;
    function WithBaseURL(const AValue: string): TClientOptions;
    function WithProject(const AValue: string): TClientOptions;
    function WithLocation(const AValue: string): TClientOptions;
    function WithOrganization(const AValue: string): TClientOptions;
    function WithTimeout(AMilliseconds: Integer): TClientOptions;
    function WithHeader(const AName, AValue: string): TClientOptions;
  end;

  { Base class for providers. Registration order is match priority. }
  TLLMProvider = class
  public
    function ID: string; virtual; abstract;
    { Extra names accepted as a "prefix/" route. }
    function Aliases: TStringArray; virtual;
    { True when this provider owns a bare model name. }
    function Matches(const AModel: string): Boolean; virtual;
    { What this provider can do for AModel, checked before construction. }
    function Capabilities(const AModel: string): TCapabilities; virtual; abstract;
    { Builds a client for AModel; never returns nil. }
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; virtual; abstract;
  end;

  TProviderList = specialize TFPGObjectList<TLLMProvider>;

  TResolution = record
    ProviderID: string;
    Model: string;
    Provider: TLLMProvider;
  end;

{ Registers AProvider, taking ownership. A provider with the same id is
  replaced, which is how custom OpenAI-compatible endpoints are added. }
procedure RegisterProvider(AProvider: TLLMProvider);
function FindProvider(const AID: string): TLLMProvider;
function RegisteredProviders: TProviderList;
procedure UnregisterProvider(const AID: string);
procedure SetFallback(const AProviderID: string);
function FallbackProvider: string;

{ Routes a model name. Raises ELLMNoProvider when nothing can serve it. }
function Resolve(const AName: string): TResolution;
function ResolveToString(const AName: string): string;

function OpenClient(const AName: string): ILLMClient;
function OpenClient(const AName: string; const AOptions: TClientOptions): ILLMClient;
function OpenChatter(const AName: string): IChatter;
function OpenChatter(const AName: string; const AOptions: TClientOptions): IChatter;
function OpenStreamer(const AName: string): IStreamer;
function OpenStreamer(const AName: string; const AOptions: TClientOptions): IStreamer;
function OpenEmbedder(const AName: string): IEmbedder;
function OpenEmbedder(const AName: string; const AOptions: TClientOptions): IEmbedder;
function OpenReranker(const AName: string): IReranker;
function OpenReranker(const AName: string; const AOptions: TClientOptions): IReranker;
function OpenTokenCounter(const AName: string): ITokenCounter;
function OpenTokenCounter(const AName: string;
  const AOptions: TClientOptions): ITokenCounter;

{ Capabilities of whatever AName resolves to. }
function CapabilitiesOf(const AName: string): TCapabilities;

{ Helpers shared by providers. }
function EnvOr(const AName, ADefault: string): string;
function HasPrefix(const AValue, APrefix: string): Boolean;
function SplitPrefix(const AValue: string; out AHead, ATail: string): Boolean;

implementation

var
  GProviders: TProviderList;
  GFallback: string;

{ TClientOptions }

class function TClientOptions.Default: TClientOptions;
begin
  Result := System.Default(TClientOptions);
  Result.TimeoutMS := 120000;
end;

function TClientOptions.WithAPIKey(const AValue: string): TClientOptions;
begin
  Result := Self;
  Result.APIKey := AValue;
end;

function TClientOptions.WithBaseURL(const AValue: string): TClientOptions;
begin
  Result := Self;
  Result.BaseURL := AValue;
end;

function TClientOptions.WithProject(const AValue: string): TClientOptions;
begin
  Result := Self;
  Result.Project := AValue;
end;

function TClientOptions.WithLocation(const AValue: string): TClientOptions;
begin
  Result := Self;
  Result.Location := AValue;
end;

function TClientOptions.WithOrganization(const AValue: string): TClientOptions;
begin
  Result := Self;
  Result.Organization := AValue;
end;

function TClientOptions.WithTimeout(AMilliseconds: Integer): TClientOptions;
begin
  Result := Self;
  Result.TimeoutMS := AMilliseconds;
end;

function TClientOptions.WithHeader(const AName, AValue: string): TClientOptions;
var
  I: Integer;
begin
  Result := Self;
  Result.Headers := Copy(Self.Headers, 0, Length(Self.Headers));
  for I := 0 to High(Result.Headers) do
    if SameText(Result.Headers[I].Name, AName) then
    begin
      Result.Headers[I].Value := AValue;
      Exit;
    end;
  SetLength(Result.Headers, Length(Result.Headers) + 1);
  Result.Headers[High(Result.Headers)].Name := AName;
  Result.Headers[High(Result.Headers)].Value := AValue;
end;

{ TLLMProvider }

function TLLMProvider.Aliases: TStringArray;
begin
  Result := nil;
end;

function TLLMProvider.Matches(const AModel: string): Boolean;
begin
  if AModel = '' then ;
  Result := False;
end;

{ registry }

procedure RegisterProvider(AProvider: TLLMProvider);
var
  I: Integer;
begin
  if AProvider = nil then
    Exit;
  for I := 0 to GProviders.Count - 1 do
    if SameText(GProviders[I].ID, AProvider.ID) then
    begin
      GProviders[I] := AProvider; { owned list frees the old one }
      Exit;
    end;
  GProviders.Add(AProvider);
end;

function FindProvider(const AID: string): TLLMProvider;
var
  I, J: Integer;
  Names: TStringArray;
begin
  for I := 0 to GProviders.Count - 1 do
  begin
    if SameText(GProviders[I].ID, AID) then
      Exit(GProviders[I]);
    Names := GProviders[I].Aliases;
    for J := 0 to High(Names) do
      if SameText(Names[J], AID) then
        Exit(GProviders[I]);
  end;
  Result := nil;
end;

function RegisteredProviders: TProviderList;
begin
  Result := GProviders;
end;

procedure UnregisterProvider(const AID: string);
var
  I: Integer;
begin
  for I := GProviders.Count - 1 downto 0 do
    if SameText(GProviders[I].ID, AID) then
      GProviders.Delete(I);
end;

procedure SetFallback(const AProviderID: string);
begin
  GFallback := AProviderID;
end;

function FallbackProvider: string;
begin
  Result := GFallback;
  if Result = '' then
    Result := GetEnvironmentVariable('LLMKIT_DEFAULT_PROVIDER');
  if Result = '' then
    Result := 'ollama';
end;

function Resolve(const AName: string): TResolution;
var
  Head, Tail: string;
  P: TLLMProvider;
  I: Integer;
begin
  Result.ProviderID := '';
  Result.Model := AName;
  Result.Provider := nil;
  if Trim(AName) = '' then
    raise ELLMNoProvider.Create('empty model name');

  if SplitPrefix(AName, Head, Tail) and (Tail <> '') then
  begin
    P := FindProvider(Head);
    if P <> nil then
    begin
      Result.Provider := P;
      Result.ProviderID := P.ID;
      Result.Model := Tail;
      Exit;
    end;
  end;

  for I := 0 to GProviders.Count - 1 do
    if GProviders[I].Matches(AName) then
    begin
      Result.Provider := GProviders[I];
      Result.ProviderID := GProviders[I].ID;
      Result.Model := AName;
      Exit;
    end;

  P := FindProvider(FallbackProvider);
  if P = nil then
    raise ELLMNoProvider.CreateFmt(
      'no provider for model %s (fallback %s is not registered)',
      [AName, FallbackProvider]);
  Result.Provider := P;
  Result.ProviderID := P.ID;
  Result.Model := AName;
end;

function ResolveToString(const AName: string): string;
var
  R: TResolution;
begin
  R := Resolve(AName);
  Result := R.ProviderID + '/' + R.Model;
end;

function OpenClient(const AName: string): ILLMClient;
begin
  Result := OpenClient(AName, TClientOptions.Default);
end;

function OpenClient(const AName: string; const AOptions: TClientOptions): ILLMClient;
var
  R: TResolution;
begin
  R := Resolve(AName);
  Result := R.Provider.NewClient(R.Model, AOptions);
  if Result = nil then
    raise ELLMNoProvider.CreateFmt('%s returned no client for %s',
      [R.ProviderID, R.Model]);
end;

function CapabilitiesOf(const AName: string): TCapabilities;
var
  R: TResolution;
begin
  R := Resolve(AName);
  Result := R.Provider.Capabilities(R.Model);
end;

{ Fails before the client is built, the way Open[T] does in llmkit. }
procedure RequireCapability(const AName: string; ACap: TCapability;
  const AWhat: string; out AResolution: TResolution);
begin
  AResolution := Resolve(AName);
  if not (ACap in AResolution.Provider.Capabilities(AResolution.Model)) then
    raise ELLMUnsupported.CreateFmt('%s (model %s) does not support %s',
      [AResolution.ProviderID, AResolution.Model, AWhat]);
end;

function OpenCapable(const AName: string; ACap: TCapability;
  const AWhat: string; const AOptions: TClientOptions): ILLMClient;
var
  R: TResolution;
begin
  RequireCapability(AName, ACap, AWhat, R);
  Result := R.Provider.NewClient(R.Model, AOptions);
  if Result = nil then
    raise ELLMNoProvider.CreateFmt('%s returned no client for %s',
      [R.ProviderID, R.Model]);
end;

function OpenChatter(const AName: string): IChatter;
begin
  Result := OpenChatter(AName, TClientOptions.Default);
end;

function OpenChatter(const AName: string; const AOptions: TClientOptions): IChatter;
begin
  if not Supports(OpenCapable(AName, capChat, 'chat', AOptions), IChatter, Result) then
    raise ELLMUnsupported.CreateFmt('%s does not implement IChatter', [AName]);
end;

function OpenStreamer(const AName: string): IStreamer;
begin
  Result := OpenStreamer(AName, TClientOptions.Default);
end;

function OpenStreamer(const AName: string; const AOptions: TClientOptions): IStreamer;
begin
  if not Supports(OpenCapable(AName, capStream, 'streaming', AOptions),
       IStreamer, Result) then
    raise ELLMUnsupported.CreateFmt('%s does not implement IStreamer', [AName]);
end;

function OpenEmbedder(const AName: string): IEmbedder;
begin
  Result := OpenEmbedder(AName, TClientOptions.Default);
end;

function OpenEmbedder(const AName: string; const AOptions: TClientOptions): IEmbedder;
begin
  if not Supports(OpenCapable(AName, capEmbed, 'embeddings', AOptions),
       IEmbedder, Result) then
    raise ELLMUnsupported.CreateFmt('%s does not implement IEmbedder', [AName]);
end;

function OpenReranker(const AName: string): IReranker;
begin
  Result := OpenReranker(AName, TClientOptions.Default);
end;

function OpenReranker(const AName: string; const AOptions: TClientOptions): IReranker;
begin
  if not Supports(OpenCapable(AName, capRerank, 'reranking', AOptions),
       IReranker, Result) then
    raise ELLMUnsupported.CreateFmt('%s does not implement IReranker', [AName]);
end;

function OpenTokenCounter(const AName: string): ITokenCounter;
begin
  Result := OpenTokenCounter(AName, TClientOptions.Default);
end;

function OpenTokenCounter(const AName: string;
  const AOptions: TClientOptions): ITokenCounter;
begin
  if not Supports(OpenCapable(AName, capCountTokens, 'token counting', AOptions),
       ITokenCounter, Result) then
    raise ELLMUnsupported.CreateFmt('%s does not implement ITokenCounter', [AName]);
end;

function EnvOr(const AName, ADefault: string): string;
begin
  Result := GetEnvironmentVariable(AName);
  if Result = '' then
    Result := ADefault;
end;

function HasPrefix(const AValue, APrefix: string): Boolean;
begin
  Result := (APrefix <> '') and (Length(AValue) >= Length(APrefix)) and
            SameText(Copy(AValue, 1, Length(APrefix)), APrefix);
end;

function SplitPrefix(const AValue: string; out AHead, ATail: string): Boolean;
var
  P: Integer;
begin
  P := Pos('/', AValue);
  Result := P > 1;
  if Result then
  begin
    AHead := Copy(AValue, 1, P - 1);
    ATail := Copy(AValue, P + 1, MaxInt);
  end
  else
  begin
    AHead := AValue;
    ATail := '';
  end;
end;

initialization
  GProviders := TProviderList.Create(True);

finalization
  FreeAndNil(GProviders);

end.
