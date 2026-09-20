{ LLMKit.Core - message model, capability interfaces and errors.

  Pascal port of the ideas in github.com/richardwooding/llmkit: one message
  model shared by every provider, small single-method capability interfaces
  and errors that can be classified across vendors.

  Ownership rules
    * A TLLMMessage owns its parts, a TLLMRequest owns its messages and tools,
      a TLLMResponse owns its parts. Free the top object and the rest goes.
    * Helper constructors (UserText, ImagePart, ...) hand ownership to the
      caller; adding them to a message or request transfers it.
}
unit LLMKit.Core;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, fgl, fpjson;

const
  LLMKitVersion = '0.1.0';

type
  TLLMRole = (lrSystem, lrUser, lrAssistant, lrTool);

  TLLMPartKind = (pkText, pkImage, pkAudio, pkFile, pkReasoning,
                  pkToolCall, pkToolResult);

  TFinishReason = (frUnknown, frStop, frLength, frToolCalls, frContentFilter,
                   frRefusal);

  TChunkKind = (ckText, ckReasoning, ckToolCall, ckFinish);

  TEmbedInputType = (eiUnspecified, eiDocument, eiQuery);

  { What a provider can do for a given model. Checked before construction so
    asking for the wrong thing never reaches the network. }
  TCapability = (capChat, capStream, capEmbed, capRerank, capCountTokens,
                 capTools, capImages, capAudio, capFiles, capReasoning,
                 capCacheHints);
  TCapabilities = set of TCapability;

  { Error classification shared by all providers. }
  TAPIErrorKind = (aekUnknown, aekAuth, aekPermission, aekNotFound,
                   aekInvalidRequest, aekContextLength, aekRateLimited,
                   aekOverloaded, aekServer, aekNetwork, aekTimeout);

  ELLMError = class(Exception);
  { Raised before any network call when a provider cannot do what was asked. }
  ELLMUnsupported = class(ELLMError);
  { Raised when a model name cannot be routed to a provider. }
  ELLMNoProvider = class(ELLMError);
  { Raised for malformed requests detected locally. }
  ELLMInvalidRequest = class(ELLMError);

  { Provider failure carrying HTTP status, vendor error code and Retry-After. }
  EAPIError = class(ELLMError)
  private
    FProvider: string;
    FStatusCode: Integer;
    FCode: string;
    FKind: TAPIErrorKind;
    FRetryAfter: Integer; { seconds, -1 when absent }
    FRaw: string;
  public
    constructor Create(const AProvider: string; AStatusCode: Integer;
      const ACode, AMessage: string; AKind: TAPIErrorKind;
      ARetryAfter: Integer; const ARaw: string);
    function IsRateLimited: Boolean;
    function IsContextLength: Boolean;
    function IsRetryable: Boolean;
    property Provider: string read FProvider;
    property StatusCode: Integer read FStatusCode;
    property Code: string read FCode;
    property Kind: TAPIErrorKind read FKind;
    property RetryAfter: Integer read FRetryAfter;
    property Raw: string read FRaw;
  end;

  { Optional scalars: Pascal has no pointer-free "unset" for Double/Integer. }
  TOptFloat = record
    HasValue: Boolean;
    Value: Double;
  end;

  TOptInt = record
    HasValue: Boolean;
    Value: Integer;
  end;

  TOptBool = record
    HasValue: Boolean;
    Value: Boolean;
  end;

  TUsage = record
    InputTokens: Integer;
    OutputTokens: Integer;
    { Part of InputTokens on every provider. }
    CachedInputTokens: Integer;
    CacheWriteTokens: Integer;
    ReasoningTokens: Integer;
    function TotalTokens: Integer;
    procedure Add(const Other: TUsage);
  end;

  { A single typed piece of a message. }
  TLLMPart = class
  public
    Kind: TLLMPartKind;
    Text: string;        { pkText, pkReasoning, pkToolResult }
    MimeType: string;    { pkImage, pkAudio, pkFile }
    Filename: string;    { pkFile }
    Data: TBytes;        { inline bytes for pkImage/pkAudio/pkFile }
    URL: string;         { remote alternative to Data }
    ID: string;          { tool call / tool result id }
    Name: string;        { tool name }
    Arguments: string;   { pkToolCall: raw JSON arguments }
    Signature: string;   { pkReasoning: provider signature to replay }
    Redacted: Boolean;   { pkReasoning: opaque block }
    IsError: Boolean;    { pkToolResult }
    CacheHint: Boolean;  { place a cache breakpoint after this part }
    constructor Create(AKind: TLLMPartKind);
    function Clone: TLLMPart;
    function HasData: Boolean;
  end;

  TPartList = specialize TFPGObjectList<TLLMPart>;

  { One turn of the conversation. Owns its parts. }
  TLLMMessage = class
  private
    FParts: TPartList;
  public
    Role: TLLMRole;
    Name: string;       { optional participant name }
    CacheHint: Boolean; { place a cache breakpoint after this message }
    constructor Create(ARole: TLLMRole);
    destructor Destroy; override;
    { Takes ownership of APart and returns it. }
    function Add(APart: TLLMPart): TLLMPart;
    function AddText(const AText: string): TLLMPart;
    function Clone: TLLMMessage;
    { Concatenation of every pkText part. }
    function Text: string;
    function HasKind(AKind: TLLMPartKind): Boolean;
    property Parts: TPartList read FParts;
  end;

  TMessageList = specialize TFPGObjectList<TLLMMessage>;

  { A function the model may call. Parameters is a JSON Schema object. }
  TLLMTool = class
  public
    Name: string;
    Description: string;
    Parameters: string;
    StrictSchema: Boolean;
    constructor Create(const AName, ADescription, AParameters: string);
    function Clone: TLLMTool;
  end;

  TToolList = specialize TFPGObjectList<TLLMTool>;

  { Effort steers how hard the model thinks; Summary asks for readable
    thinking ("auto", "concise", "detailed", "summarized", "omitted"). }
  TReasoningConfig = record
    Enabled: Boolean;
    Effort: string;
    Summary: string;
    BudgetTokens: Integer;
  end;

  { Explicit prompt-cache breakpoints. Providers that cache prefixes on their
    own ignore this. }
  TCacheConfig = record
    Enabled: Boolean;
    System: Boolean;
    Tools: Boolean;
    Turns: Integer;
    TTL: string;
  end;

  TStringArray = array of string;

  { A chat request. Owns Messages, Tools, Extra and ProviderOptions. }
  TLLMRequest = class
  private
    FMessages: TMessageList;
    FTools: TToolList;
    FExtra: TJSONObject;
    FProviderOptions: TJSONObject;
    function GetExtra: TJSONObject;
    function GetProviderOptions: TJSONObject;
  public
    Model: string;
    SystemPrompt: string;
    ToolChoice: string;    { '', 'auto', 'none', 'required' or a tool name }
    Temperature: TOptFloat;
    TopP: TOptFloat;
    MaxTokens: TOptInt;
    Seed: TOptInt;
    Stop: TStringArray;
    ResponseFormat: string; { '', 'json_object' or a JSON Schema object }
    Reasoning: TReasoningConfig;
    Cache: TCacheConfig;
    constructor Create;
    constructor Create(const AModel: string);
    destructor Destroy; override;
    { Takes ownership. }
    function Add(AMessage: TLLMMessage): TLLMMessage;
    function AddUserText(const AText: string): TLLMMessage;
    function AddTool(ATool: TLLMTool): TLLMTool;
    function AddTool(const AName, ADescription, AParameters: string): TLLMTool;
    function Clone: TLLMRequest;
    { Raw fields merged into the wire body of every provider. }
    property Extra: TJSONObject read GetExtra;
    { Raw fields merged only for the named provider, keyed by provider id. }
    property ProviderOptions: TJSONObject read GetProviderOptions;
    function ExtraOrNil: TJSONObject;
    function ProviderOptionsFor(const AProviderID: string): TJSONObject;
    property Messages: TMessageList read FMessages;
    property Tools: TToolList read FTools;
  end;

  { A chat response. Owns its parts. }
  TLLMResponse = class
  private
    FParts: TPartList;
  public
    ID: string;
    Model: string;
    Provider: string;
    FinishReason: TFinishReason;
    Usage: TUsage;
    Raw: string;  { untouched provider JSON }
    constructor Create;
    destructor Destroy; override;
    function Add(APart: TLLMPart): TLLMPart;
    function Text: string;
    function ReasoningText: string;
    function ToolCalls: TPartList; { new list, does NOT own the parts }
    function HasToolCalls: Boolean;
    { Rebuilds the assistant turn so it can be appended to Request.Messages. }
    function ToMessage: TLLMMessage;
    property Parts: TPartList read FParts;
  end;

  { One streamed event. }
  TLLMChunk = record
    Kind: TChunkKind;
    Text: string;           { ckText / ckReasoning delta }
    Index: Integer;         { tool call index for ckToolCall }
    ToolCallID: string;
    ToolName: string;
    ArgumentsDelta: string;
    Signature: string;
    FinishReason: TFinishReason;
    Usage: TUsage;
    Raw: string;
  end;

  { Return False to stop the stream; the connection is closed at once. }
  TChunkEvent = function(const AChunk: TLLMChunk): Boolean of object;

  TEmbedRequest = class
  public
    Model: string;
    Inputs: TStringArray;
    InputType: TEmbedInputType;
    Dimensions: TOptInt;
    Truncate: TOptBool;
    constructor Create;
    constructor Create(const AModel: string; const AInputs: array of string);
  end;

  TFloatArray = array of Single;
  TEmbeddingArray = array of TFloatArray;

  TEmbedResponse = class
  public
    Model: string;
    Provider: string;
    Embeddings: TEmbeddingArray;
    Usage: TUsage;
    Raw: string;
    function Count: Integer;
    function Dimensions: Integer;
  end;

  TRerankRequest = class
  public
    Model: string;
    Query: string;
    Documents: TStringArray;
    TopN: TOptInt;
    constructor Create;
    constructor Create(const AModel, AQuery: string; const ADocs: array of string);
  end;

  TRerankResult = record
    Index: Integer;
    Score: Double;
    Document: string;
  end;

  TRerankResults = array of TRerankResult;

  TRerankResponse = class
  public
    Model: string;
    Provider: string;
    Results: TRerankResults; { best first }
    Usage: TUsage;
    Raw: string;
    function Count: Integer;
  end;

  { --- capability interfaces: one method each --- }

  ILLMClient = interface
    ['{2F0E4A9E-6C7E-4D39-9B94-9C7A2E1E0001}']
    function ProviderID: string;
    function ModelID: string;
  end;

  IChatter = interface(ILLMClient)
    ['{2F0E4A9E-6C7E-4D39-9B94-9C7A2E1E0002}']
    function Chat(ARequest: TLLMRequest): TLLMResponse;
  end;

  IStreamer = interface(ILLMClient)
    ['{2F0E4A9E-6C7E-4D39-9B94-9C7A2E1E0003}']
    { Calls AOnChunk for each event. Returns False if the sink stopped it. }
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
  end;

  IEmbedder = interface(ILLMClient)
    ['{2F0E4A9E-6C7E-4D39-9B94-9C7A2E1E0004}']
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
  end;

  IReranker = interface(ILLMClient)
    ['{2F0E4A9E-6C7E-4D39-9B94-9C7A2E1E0005}']
    function Rerank(ARequest: TRerankRequest): TRerankResponse;
  end;

  ITokenCounter = interface(ILLMClient)
    ['{2F0E4A9E-6C7E-4D39-9B94-9C7A2E1E0006}']
    function CountTokens(ARequest: TLLMRequest): Integer;
  end;

{ --- optional scalar helpers --- }
function OptFloat(AValue: Double): TOptFloat;
function NoFloat: TOptFloat;
function OptInt(AValue: Integer): TOptInt;
function NoInt: TOptInt;
function OptBool(AValue: Boolean): TOptBool;
function NoBool: TOptBool;

{ --- part constructors --- }
function TextPart(const AText: string): TLLMPart;
function ImagePart(const AData: TBytes; const AMimeType: string): TLLMPart;
function ImageURLPart(const AURL: string): TLLMPart;
function AudioPart(const AData: TBytes; const AMimeType: string): TLLMPart;
function FilePart(const AData: TBytes; const AMimeType, AFilename: string): TLLMPart;
function FileURLPart(const AURL, AMimeType, AFilename: string): TLLMPart;
function ReasoningPart(const AText, ASignature: string): TLLMPart;
function ToolCallPart(const AID, AName, AArguments: string): TLLMPart;
function ToolResultPart(const AID, AName, AContent: string;
  AIsError: Boolean = False): TLLMPart;

{ --- message constructors --- }
function SystemText(const AText: string): TLLMMessage;
function UserText(const AText: string): TLLMMessage;
function AssistantText(const AText: string): TLLMMessage;
function UserMessage(const AParts: array of TLLMPart): TLLMMessage;
function AssistantMessage(const AParts: array of TLLMPart): TLLMMessage;
function ToolMessage(const AID, AName, AContent: string;
  AIsError: Boolean = False): TLLMMessage;

{ --- misc --- }
function RoleToString(ARole: TLLMRole): string;
function StringToRole(const AValue: string): TLLMRole;
function FinishReasonToString(AReason: TFinishReason): string;
function ParseFinishReason(const AValue: string): TFinishReason;
function ErrorKindToString(AKind: TAPIErrorKind): string;
function CapabilityToString(ACap: TCapability): string;
function CapabilitiesToString(ACaps: TCapabilities): string;
{ Classifies an error the way errors.Is(err, ErrRateLimited) does in Go. }
function IsRateLimited(E: Exception): Boolean;
function IsContextLength(E: Exception): Boolean;
function IsUnsupported(E: Exception): Boolean;
{ Raises ELLMUnsupported with the usual wording. }
procedure Unsupported(const AProvider, AWhat: string);

implementation

{ TUsage }

function TUsage.TotalTokens: Integer;
begin
  Result := InputTokens + OutputTokens;
end;

procedure TUsage.Add(const Other: TUsage);
begin
  Inc(InputTokens, Other.InputTokens);
  Inc(OutputTokens, Other.OutputTokens);
  Inc(CachedInputTokens, Other.CachedInputTokens);
  Inc(CacheWriteTokens, Other.CacheWriteTokens);
  Inc(ReasoningTokens, Other.ReasoningTokens);
end;

{ EAPIError }

constructor EAPIError.Create(const AProvider: string; AStatusCode: Integer;
  const ACode, AMessage: string; AKind: TAPIErrorKind; ARetryAfter: Integer;
  const ARaw: string);
var
  Msg: string;
begin
  Msg := AProvider;
  if AStatusCode > 0 then
    Msg := Msg + Format(' (HTTP %d)', [AStatusCode]);
  if ACode <> '' then
    Msg := Msg + ' [' + ACode + ']';
  Msg := Msg + ': ' + AMessage;
  inherited Create(Msg);
  FProvider := AProvider;
  FStatusCode := AStatusCode;
  FCode := ACode;
  FKind := AKind;
  FRetryAfter := ARetryAfter;
  FRaw := ARaw;
end;

function EAPIError.IsRateLimited: Boolean;
begin
  Result := FKind = aekRateLimited;
end;

function EAPIError.IsContextLength: Boolean;
begin
  Result := FKind = aekContextLength;
end;

function EAPIError.IsRetryable: Boolean;
begin
  Result := FKind in [aekRateLimited, aekOverloaded, aekServer, aekNetwork,
                      aekTimeout];
end;

{ TLLMPart }

constructor TLLMPart.Create(AKind: TLLMPartKind);
begin
  inherited Create;
  Kind := AKind;
end;

function TLLMPart.Clone: TLLMPart;
begin
  Result := TLLMPart.Create(Kind);
  Result.Text := Text;
  Result.MimeType := MimeType;
  Result.Filename := Filename;
  Result.Data := Copy(Data, 0, Length(Data));
  Result.URL := URL;
  Result.ID := ID;
  Result.Name := Name;
  Result.Arguments := Arguments;
  Result.Signature := Signature;
  Result.Redacted := Redacted;
  Result.IsError := IsError;
  Result.CacheHint := CacheHint;
end;

function TLLMPart.HasData: Boolean;
begin
  Result := Length(Data) > 0;
end;

{ TLLMMessage }

constructor TLLMMessage.Create(ARole: TLLMRole);
begin
  inherited Create;
  Role := ARole;
  FParts := TPartList.Create(True);
end;

destructor TLLMMessage.Destroy;
begin
  FParts.Free;
  inherited Destroy;
end;

function TLLMMessage.Add(APart: TLLMPart): TLLMPart;
begin
  FParts.Add(APart);
  Result := APart;
end;

function TLLMMessage.AddText(const AText: string): TLLMPart;
begin
  Result := Add(TextPart(AText));
end;

function TLLMMessage.Clone: TLLMMessage;
var
  I: Integer;
begin
  Result := TLLMMessage.Create(Role);
  Result.Name := Name;
  Result.CacheHint := CacheHint;
  for I := 0 to FParts.Count - 1 do
    Result.Add(FParts[I].Clone);
end;

function TLLMMessage.Text: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FParts.Count - 1 do
    if FParts[I].Kind = pkText then
      Result := Result + FParts[I].Text;
end;

function TLLMMessage.HasKind(AKind: TLLMPartKind): Boolean;
var
  I: Integer;
begin
  for I := 0 to FParts.Count - 1 do
    if FParts[I].Kind = AKind then
      Exit(True);
  Result := False;
end;

{ TLLMTool }

constructor TLLMTool.Create(const AName, ADescription, AParameters: string);
begin
  inherited Create;
  Name := AName;
  Description := ADescription;
  Parameters := AParameters;
end;

function TLLMTool.Clone: TLLMTool;
begin
  Result := TLLMTool.Create(Name, Description, Parameters);
  Result.StrictSchema := StrictSchema;
end;

{ TLLMRequest }

constructor TLLMRequest.Create;
begin
  inherited Create;
  FMessages := TMessageList.Create(True);
  FTools := TToolList.Create(True);
end;

constructor TLLMRequest.Create(const AModel: string);
begin
  Create;
  Model := AModel;
end;

destructor TLLMRequest.Destroy;
begin
  FMessages.Free;
  FTools.Free;
  FExtra.Free;
  FProviderOptions.Free;
  inherited Destroy;
end;

function TLLMRequest.GetExtra: TJSONObject;
begin
  if FExtra = nil then
    FExtra := TJSONObject.Create;
  Result := FExtra;
end;

function TLLMRequest.ExtraOrNil: TJSONObject;
begin
  Result := FExtra;
end;

function TLLMRequest.GetProviderOptions: TJSONObject;
begin
  if FProviderOptions = nil then
    FProviderOptions := TJSONObject.Create;
  Result := FProviderOptions;
end;

function TLLMRequest.ProviderOptionsFor(const AProviderID: string): TJSONObject;
var
  Idx: Integer;
begin
  Result := nil;
  if FProviderOptions = nil then
    Exit;
  Idx := FProviderOptions.IndexOfName(AProviderID);
  if (Idx >= 0) and (FProviderOptions.Items[Idx].JSONType = jtObject) then
    Result := TJSONObject(FProviderOptions.Items[Idx]);
end;

function TLLMRequest.Add(AMessage: TLLMMessage): TLLMMessage;
begin
  FMessages.Add(AMessage);
  Result := AMessage;
end;

function TLLMRequest.AddUserText(const AText: string): TLLMMessage;
begin
  Result := Add(UserText(AText));
end;

function TLLMRequest.AddTool(ATool: TLLMTool): TLLMTool;
begin
  FTools.Add(ATool);
  Result := ATool;
end;

function TLLMRequest.AddTool(const AName, ADescription, AParameters: string): TLLMTool;
begin
  Result := AddTool(TLLMTool.Create(AName, ADescription, AParameters));
end;

function TLLMRequest.Clone: TLLMRequest;
var
  I: Integer;
begin
  Result := TLLMRequest.Create(Model);
  Result.SystemPrompt := SystemPrompt;
  Result.ToolChoice := ToolChoice;
  Result.Temperature := Temperature;
  Result.TopP := TopP;
  Result.MaxTokens := MaxTokens;
  Result.Seed := Seed;
  Result.Stop := Copy(Stop, 0, Length(Stop));
  Result.ResponseFormat := ResponseFormat;
  Result.Reasoning := Reasoning;
  Result.Cache := Cache;
  for I := 0 to FMessages.Count - 1 do
    Result.Add(FMessages[I].Clone);
  for I := 0 to FTools.Count - 1 do
    Result.AddTool(FTools[I].Clone);
  if FExtra <> nil then
    Result.FExtra := TJSONObject(FExtra.Clone);
  if FProviderOptions <> nil then
    Result.FProviderOptions := TJSONObject(FProviderOptions.Clone);
end;

{ TLLMResponse }

constructor TLLMResponse.Create;
begin
  inherited Create;
  FParts := TPartList.Create(True);
end;

destructor TLLMResponse.Destroy;
begin
  FParts.Free;
  inherited Destroy;
end;

function TLLMResponse.Add(APart: TLLMPart): TLLMPart;
begin
  FParts.Add(APart);
  Result := APart;
end;

function TLLMResponse.Text: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FParts.Count - 1 do
    if FParts[I].Kind = pkText then
      Result := Result + FParts[I].Text;
end;

function TLLMResponse.ReasoningText: string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to FParts.Count - 1 do
    if FParts[I].Kind = pkReasoning then
      Result := Result + FParts[I].Text;
end;

function TLLMResponse.ToolCalls: TPartList;
var
  I: Integer;
begin
  Result := TPartList.Create(False);
  for I := 0 to FParts.Count - 1 do
    if FParts[I].Kind = pkToolCall then
      Result.Add(FParts[I]);
end;

function TLLMResponse.HasToolCalls: Boolean;
var
  I: Integer;
begin
  for I := 0 to FParts.Count - 1 do
    if FParts[I].Kind = pkToolCall then
      Exit(True);
  Result := False;
end;

function TLLMResponse.ToMessage: TLLMMessage;
var
  I: Integer;
begin
  Result := TLLMMessage.Create(lrAssistant);
  for I := 0 to FParts.Count - 1 do
    Result.Add(FParts[I].Clone);
end;

{ TEmbedRequest }

constructor TEmbedRequest.Create;
begin
  inherited Create;
end;

constructor TEmbedRequest.Create(const AModel: string; const AInputs: array of string);
var
  I: Integer;
begin
  Create;
  Model := AModel;
  SetLength(Inputs, Length(AInputs));
  for I := 0 to High(AInputs) do
    Inputs[I] := AInputs[I];
end;

{ TEmbedResponse }

function TEmbedResponse.Count: Integer;
begin
  Result := Length(Embeddings);
end;

function TEmbedResponse.Dimensions: Integer;
begin
  if Length(Embeddings) = 0 then
    Result := 0
  else
    Result := Length(Embeddings[0]);
end;

{ TRerankRequest }

constructor TRerankRequest.Create;
begin
  inherited Create;
end;

constructor TRerankRequest.Create(const AModel, AQuery: string;
  const ADocs: array of string);
var
  I: Integer;
begin
  Create;
  Model := AModel;
  Query := AQuery;
  SetLength(Documents, Length(ADocs));
  for I := 0 to High(ADocs) do
    Documents[I] := ADocs[I];
end;

{ TRerankResponse }

function TRerankResponse.Count: Integer;
begin
  Result := Length(Results);
end;

{ helpers }

function OptFloat(AValue: Double): TOptFloat;
begin
  Result.HasValue := True;
  Result.Value := AValue;
end;

function NoFloat: TOptFloat;
begin
  Result.HasValue := False;
  Result.Value := 0;
end;

function OptInt(AValue: Integer): TOptInt;
begin
  Result.HasValue := True;
  Result.Value := AValue;
end;

function NoInt: TOptInt;
begin
  Result.HasValue := False;
  Result.Value := 0;
end;

function OptBool(AValue: Boolean): TOptBool;
begin
  Result.HasValue := True;
  Result.Value := AValue;
end;

function NoBool: TOptBool;
begin
  Result.HasValue := False;
  Result.Value := False;
end;

function TextPart(const AText: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkText);
  Result.Text := AText;
end;

function ImagePart(const AData: TBytes; const AMimeType: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkImage);
  Result.Data := AData;
  Result.MimeType := AMimeType;
end;

function ImageURLPart(const AURL: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkImage);
  Result.URL := AURL;
end;

function AudioPart(const AData: TBytes; const AMimeType: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkAudio);
  Result.Data := AData;
  Result.MimeType := AMimeType;
end;

function FilePart(const AData: TBytes; const AMimeType, AFilename: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkFile);
  Result.Data := AData;
  Result.MimeType := AMimeType;
  Result.Filename := AFilename;
end;

function FileURLPart(const AURL, AMimeType, AFilename: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkFile);
  Result.URL := AURL;
  Result.MimeType := AMimeType;
  Result.Filename := AFilename;
end;

function ReasoningPart(const AText, ASignature: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkReasoning);
  Result.Text := AText;
  Result.Signature := ASignature;
end;

function ToolCallPart(const AID, AName, AArguments: string): TLLMPart;
begin
  Result := TLLMPart.Create(pkToolCall);
  Result.ID := AID;
  Result.Name := AName;
  Result.Arguments := AArguments;
end;

function ToolResultPart(const AID, AName, AContent: string;
  AIsError: Boolean): TLLMPart;
begin
  Result := TLLMPart.Create(pkToolResult);
  Result.ID := AID;
  Result.Name := AName;
  Result.Text := AContent;
  Result.IsError := AIsError;
end;

function NewTextMessage(ARole: TLLMRole; const AText: string): TLLMMessage;
begin
  Result := TLLMMessage.Create(ARole);
  Result.AddText(AText);
end;

function SystemText(const AText: string): TLLMMessage;
begin
  Result := NewTextMessage(lrSystem, AText);
end;

function UserText(const AText: string): TLLMMessage;
begin
  Result := NewTextMessage(lrUser, AText);
end;

function AssistantText(const AText: string): TLLMMessage;
begin
  Result := NewTextMessage(lrAssistant, AText);
end;

function BuildMessage(ARole: TLLMRole; const AParts: array of TLLMPart): TLLMMessage;
var
  I: Integer;
begin
  Result := TLLMMessage.Create(ARole);
  for I := 0 to High(AParts) do
    Result.Add(AParts[I]);
end;

function UserMessage(const AParts: array of TLLMPart): TLLMMessage;
begin
  Result := BuildMessage(lrUser, AParts);
end;

function AssistantMessage(const AParts: array of TLLMPart): TLLMMessage;
begin
  Result := BuildMessage(lrAssistant, AParts);
end;

function ToolMessage(const AID, AName, AContent: string;
  AIsError: Boolean): TLLMMessage;
begin
  Result := TLLMMessage.Create(lrTool);
  Result.Add(ToolResultPart(AID, AName, AContent, AIsError));
end;

function RoleToString(ARole: TLLMRole): string;
begin
  case ARole of
    lrSystem: Result := 'system';
    lrUser: Result := 'user';
    lrAssistant: Result := 'assistant';
    lrTool: Result := 'tool';
  else
    Result := 'user';
  end;
end;

function StringToRole(const AValue: string): TLLMRole;
var
  S: string;
begin
  S := LowerCase(AValue);
  if (S = 'system') or (S = 'developer') then
    Result := lrSystem
  else if (S = 'assistant') or (S = 'model') then
    Result := lrAssistant
  else if (S = 'tool') or (S = 'function') then
    Result := lrTool
  else
    Result := lrUser;
end;

function FinishReasonToString(AReason: TFinishReason): string;
begin
  case AReason of
    frStop: Result := 'stop';
    frLength: Result := 'length';
    frToolCalls: Result := 'tool_calls';
    frContentFilter: Result := 'content_filter';
    frRefusal: Result := 'refusal';
  else
    Result := '';
  end;
end;

function ParseFinishReason(const AValue: string): TFinishReason;
var
  S: string;
begin
  S := LowerCase(AValue);
  if (S = 'stop') or (S = 'end_turn') or (S = 'stop_sequence') or
     (S = 'complete') or (S = 'completed') then
    Result := frStop
  else if (S = 'length') or (S = 'max_tokens') or (S = 'model_length') or
          (S = 'incomplete') then
    Result := frLength
  else if (S = 'tool_calls') or (S = 'tool_call') or (S = 'tool_use') or
          (S = 'function_call') or (S = 'tool') then
    Result := frToolCalls
  else if (S = 'content_filter') or (S = 'safety') or (S = 'blocked') then
    Result := frContentFilter
  else if S = 'refusal' then
    Result := frRefusal
  else
    Result := frUnknown;
end;

function ErrorKindToString(AKind: TAPIErrorKind): string;
begin
  case AKind of
    aekAuth: Result := 'auth';
    aekPermission: Result := 'permission';
    aekNotFound: Result := 'not_found';
    aekInvalidRequest: Result := 'invalid_request';
    aekContextLength: Result := 'context_length';
    aekRateLimited: Result := 'rate_limited';
    aekOverloaded: Result := 'overloaded';
    aekServer: Result := 'server';
    aekNetwork: Result := 'network';
    aekTimeout: Result := 'timeout';
  else
    Result := 'unknown';
  end;
end;

function CapabilityToString(ACap: TCapability): string;
begin
  case ACap of
    capChat: Result := 'chat';
    capStream: Result := 'stream';
    capEmbed: Result := 'embed';
    capRerank: Result := 'rerank';
    capCountTokens: Result := 'count';
    capTools: Result := 'tools';
    capImages: Result := 'image';
    capAudio: Result := 'audio';
    capFiles: Result := 'file';
    capReasoning: Result := 'reasoning';
    capCacheHints: Result := 'cache';
  else
    Result := '';
  end;
end;

function CapabilitiesToString(ACaps: TCapabilities): string;
var
  C: TCapability;
begin
  Result := '';
  for C := Low(TCapability) to High(TCapability) do
    if C in ACaps then
    begin
      if Result <> '' then
        Result := Result + ',';
      Result := Result + CapabilityToString(C);
    end;
end;

function IsRateLimited(E: Exception): Boolean;
begin
  Result := (E is EAPIError) and EAPIError(E).IsRateLimited;
end;

function IsContextLength(E: Exception): Boolean;
begin
  Result := (E is EAPIError) and EAPIError(E).IsContextLength;
end;

function IsUnsupported(E: Exception): Boolean;
begin
  Result := E is ELLMUnsupported;
end;

procedure Unsupported(const AProvider, AWhat: string);
begin
  raise ELLMUnsupported.CreateFmt('%s does not support %s', [AProvider, AWhat]);
end;

end.
