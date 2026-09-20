{ LLMKit - one façade unit for the common API.

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

  Everything here is a re-export; the units it wraps can also be used
  directly when more control is needed.
}
unit LLMKit;

{$mode objfpc}{$H+}
{$WRITEABLECONST OFF}

interface

uses
  SysUtils, LLMKit.Core, LLMKit.Registry, LLMKit.Stream,
  LLMKit.Tools, LLMKit.Catalog, LLMKit.Providers,
  LLMKit.Provider.OpenAICompat;

type
  { core model }
  TLLMRequest = LLMKit.Core.TLLMRequest;
  TLLMResponse = LLMKit.Core.TLLMResponse;
  TLLMMessage = LLMKit.Core.TLLMMessage;
  TLLMPart = LLMKit.Core.TLLMPart;
  TLLMTool = LLMKit.Core.TLLMTool;
  TLLMChunk = LLMKit.Core.TLLMChunk;
  TChunkEvent = LLMKit.Core.TChunkEvent;
  TUsage = LLMKit.Core.TUsage;
  TEmbedRequest = LLMKit.Core.TEmbedRequest;
  TEmbedResponse = LLMKit.Core.TEmbedResponse;
  TRerankRequest = LLMKit.Core.TRerankRequest;
  TRerankResponse = LLMKit.Core.TRerankResponse;
  TRerankResult = LLMKit.Core.TRerankResult;
  TReasoningConfig = LLMKit.Core.TReasoningConfig;
  TCacheConfig = LLMKit.Core.TCacheConfig;
  TCapability = LLMKit.Core.TCapability;
  TCapabilities = LLMKit.Core.TCapabilities;
  TFinishReason = LLMKit.Core.TFinishReason;
  TChunkKind = LLMKit.Core.TChunkKind;
  TLLMRole = LLMKit.Core.TLLMRole;
  TLLMPartKind = LLMKit.Core.TLLMPartKind;
  TEmbedInputType = LLMKit.Core.TEmbedInputType;
  TOptFloat = LLMKit.Core.TOptFloat;
  TOptInt = LLMKit.Core.TOptInt;
  TOptBool = LLMKit.Core.TOptBool;
  TPartList = LLMKit.Core.TPartList;

  { interfaces }
  ILLMClient = LLMKit.Core.ILLMClient;
  IChatter = LLMKit.Core.IChatter;
  IStreamer = LLMKit.Core.IStreamer;
  IEmbedder = LLMKit.Core.IEmbedder;
  IReranker = LLMKit.Core.IReranker;
  ITokenCounter = LLMKit.Core.ITokenCounter;

  { errors }
  ELLMError = LLMKit.Core.ELLMError;
  EAPIError = LLMKit.Core.EAPIError;
  ELLMUnsupported = LLMKit.Core.ELLMUnsupported;
  ELLMNoProvider = LLMKit.Core.ELLMNoProvider;
  ELLMInvalidRequest = LLMKit.Core.ELLMInvalidRequest;

  { registry }
  TClientOptions = LLMKit.Registry.TClientOptions;
  TLLMProvider = LLMKit.Registry.TLLMProvider;
  TResolution = LLMKit.Registry.TResolution;

  { extras }
  TToolSet = LLMKit.Tools.TToolSet;
  TToolMethod = LLMKit.Tools.TToolMethod;
  TToolProc = LLMKit.Tools.TToolProc;
  TChunkCollector = LLMKit.Stream.TChunkCollector;
  TModelInfo = LLMKit.Catalog.TModelInfo;
  TCompatConfig = LLMKit.Provider.OpenAICompat.TCompatConfig;
  TOpenAICompatProvider = LLMKit.Provider.OpenAICompat.TOpenAICompatProvider;

const
  Version = LLMKit.Core.LLMKitVersion;

  { Enumeration values, so "uses LLMKit" alone is enough. }
  lrSystem: TLLMRole = LLMKit.Core.lrSystem;
  lrUser: TLLMRole = LLMKit.Core.lrUser;
  lrAssistant: TLLMRole = LLMKit.Core.lrAssistant;
  lrTool: TLLMRole = LLMKit.Core.lrTool;

  pkText: TLLMPartKind = LLMKit.Core.pkText;
  pkImage: TLLMPartKind = LLMKit.Core.pkImage;
  pkAudio: TLLMPartKind = LLMKit.Core.pkAudio;
  pkFile: TLLMPartKind = LLMKit.Core.pkFile;
  pkReasoning: TLLMPartKind = LLMKit.Core.pkReasoning;
  pkToolCall: TLLMPartKind = LLMKit.Core.pkToolCall;
  pkToolResult: TLLMPartKind = LLMKit.Core.pkToolResult;

  ckText: TChunkKind = LLMKit.Core.ckText;
  ckReasoning: TChunkKind = LLMKit.Core.ckReasoning;
  ckToolCall: TChunkKind = LLMKit.Core.ckToolCall;
  ckFinish: TChunkKind = LLMKit.Core.ckFinish;

  frUnknown: TFinishReason = LLMKit.Core.frUnknown;
  frStop: TFinishReason = LLMKit.Core.frStop;
  frLength: TFinishReason = LLMKit.Core.frLength;
  frToolCalls: TFinishReason = LLMKit.Core.frToolCalls;
  frContentFilter: TFinishReason = LLMKit.Core.frContentFilter;
  frRefusal: TFinishReason = LLMKit.Core.frRefusal;

  eiDocument: TEmbedInputType = LLMKit.Core.eiDocument;
  eiQuery: TEmbedInputType = LLMKit.Core.eiQuery;

  capChat: TCapability = LLMKit.Core.capChat;
  capStream: TCapability = LLMKit.Core.capStream;
  capEmbed: TCapability = LLMKit.Core.capEmbed;
  capRerank: TCapability = LLMKit.Core.capRerank;
  capCountTokens: TCapability = LLMKit.Core.capCountTokens;
  capTools: TCapability = LLMKit.Core.capTools;
  capImages: TCapability = LLMKit.Core.capImages;
  capFiles: TCapability = LLMKit.Core.capFiles;
  capReasoning: TCapability = LLMKit.Core.capReasoning;
  capCacheHints: TCapability = LLMKit.Core.capCacheHints;

{ factories }
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

{ routing }
function Resolve(const AName: string): TResolution;
function ResolveToString(const AName: string): string;
function CapabilitiesOf(const AName: string): TCapabilities;
procedure SetFallback(const AProviderID: string);
procedure RegisterProvider(AProvider: TLLMProvider);
function Options: TClientOptions;

{ optional scalars }
function OptFloat(AValue: Double): TOptFloat;
function OptInt(AValue: Integer): TOptInt;
function OptBool(AValue: Boolean): TOptBool;

{ formatting }
function FinishReasonToString(AReason: TFinishReason): string;
function CapabilitiesToString(ACaps: TCapabilities): string;
function RoleToString(ARole: TLLMRole): string;

{ messages }
function UserText(const AText: string): TLLMMessage;
function SystemText(const AText: string): TLLMMessage;
function AssistantText(const AText: string): TLLMMessage;
function UserMessage(const AParts: array of TLLMPart): TLLMMessage;
function TextPart(const AText: string): TLLMPart;
function ImagePart(const AData: TBytes; const AMimeType: string): TLLMPart;
function FilePart(const AData: TBytes; const AMimeType, AFilename: string): TLLMPart;
function ToolResultPart(const AID, AName, AContent: string): TLLMPart;
function ToolMessage(const AID, AName, AContent: string): TLLMMessage;

{ streaming and tools }
function Collect(AStreamer: IStreamer; ARequest: TLLMRequest): TLLMResponse;
function Collect(AStreamer: IStreamer; ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): TLLMResponse;
function RunTools(AChatter: IChatter; ARequest: TLLMRequest; ATools: TToolSet;
  AMaxTurns: Integer): TLLMResponse;

{ catalog }
function LookupModel(const AName: string): TModelInfo;

{ errors }
function IsRateLimited(E: Exception): Boolean;
function IsContextLength(E: Exception): Boolean;
function IsUnsupported(E: Exception): Boolean;

implementation

function OpenChatter(const AName: string): IChatter;
begin
  Result := LLMKit.Registry.OpenChatter(AName);
end;

function OpenChatter(const AName: string; const AOptions: TClientOptions): IChatter;
begin
  Result := LLMKit.Registry.OpenChatter(AName, AOptions);
end;

function OpenStreamer(const AName: string): IStreamer;
begin
  Result := LLMKit.Registry.OpenStreamer(AName);
end;

function OpenStreamer(const AName: string; const AOptions: TClientOptions): IStreamer;
begin
  Result := LLMKit.Registry.OpenStreamer(AName, AOptions);
end;

function OpenEmbedder(const AName: string): IEmbedder;
begin
  Result := LLMKit.Registry.OpenEmbedder(AName);
end;

function OpenEmbedder(const AName: string; const AOptions: TClientOptions): IEmbedder;
begin
  Result := LLMKit.Registry.OpenEmbedder(AName, AOptions);
end;

function OpenReranker(const AName: string): IReranker;
begin
  Result := LLMKit.Registry.OpenReranker(AName);
end;

function OpenReranker(const AName: string; const AOptions: TClientOptions): IReranker;
begin
  Result := LLMKit.Registry.OpenReranker(AName, AOptions);
end;

function OpenTokenCounter(const AName: string): ITokenCounter;
begin
  Result := LLMKit.Registry.OpenTokenCounter(AName);
end;

function OpenTokenCounter(const AName: string;
  const AOptions: TClientOptions): ITokenCounter;
begin
  Result := LLMKit.Registry.OpenTokenCounter(AName, AOptions);
end;

function Resolve(const AName: string): TResolution;
begin
  Result := LLMKit.Registry.Resolve(AName);
end;

function ResolveToString(const AName: string): string;
begin
  Result := LLMKit.Registry.ResolveToString(AName);
end;

function CapabilitiesOf(const AName: string): TCapabilities;
begin
  Result := LLMKit.Registry.CapabilitiesOf(AName);
end;

procedure SetFallback(const AProviderID: string);
begin
  LLMKit.Registry.SetFallback(AProviderID);
end;

procedure RegisterProvider(AProvider: TLLMProvider);
begin
  LLMKit.Registry.RegisterProvider(AProvider);
end;

function Options: TClientOptions;
begin
  Result := TClientOptions.Default;
end;

function OptFloat(AValue: Double): TOptFloat;
begin
  Result := LLMKit.Core.OptFloat(AValue);
end;

function OptInt(AValue: Integer): TOptInt;
begin
  Result := LLMKit.Core.OptInt(AValue);
end;

function OptBool(AValue: Boolean): TOptBool;
begin
  Result := LLMKit.Core.OptBool(AValue);
end;

function FinishReasonToString(AReason: TFinishReason): string;
begin
  Result := LLMKit.Core.FinishReasonToString(AReason);
end;

function CapabilitiesToString(ACaps: TCapabilities): string;
begin
  Result := LLMKit.Core.CapabilitiesToString(ACaps);
end;

function RoleToString(ARole: TLLMRole): string;
begin
  Result := LLMKit.Core.RoleToString(ARole);
end;

function UserText(const AText: string): TLLMMessage;
begin
  Result := LLMKit.Core.UserText(AText);
end;

function SystemText(const AText: string): TLLMMessage;
begin
  Result := LLMKit.Core.SystemText(AText);
end;

function AssistantText(const AText: string): TLLMMessage;
begin
  Result := LLMKit.Core.AssistantText(AText);
end;

function UserMessage(const AParts: array of TLLMPart): TLLMMessage;
begin
  Result := LLMKit.Core.UserMessage(AParts);
end;

function TextPart(const AText: string): TLLMPart;
begin
  Result := LLMKit.Core.TextPart(AText);
end;

function ImagePart(const AData: TBytes; const AMimeType: string): TLLMPart;
begin
  Result := LLMKit.Core.ImagePart(AData, AMimeType);
end;

function FilePart(const AData: TBytes; const AMimeType, AFilename: string): TLLMPart;
begin
  Result := LLMKit.Core.FilePart(AData, AMimeType, AFilename);
end;

function ToolResultPart(const AID, AName, AContent: string): TLLMPart;
begin
  Result := LLMKit.Core.ToolResultPart(AID, AName, AContent, False);
end;

function ToolMessage(const AID, AName, AContent: string): TLLMMessage;
begin
  Result := LLMKit.Core.ToolMessage(AID, AName, AContent, False);
end;

function Collect(AStreamer: IStreamer; ARequest: TLLMRequest): TLLMResponse;
begin
  Result := LLMKit.Stream.Collect(AStreamer, ARequest);
end;

function Collect(AStreamer: IStreamer; ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): TLLMResponse;
begin
  Result := LLMKit.Stream.Collect(AStreamer, ARequest, AOnChunk);
end;

function RunTools(AChatter: IChatter; ARequest: TLLMRequest; ATools: TToolSet;
  AMaxTurns: Integer): TLLMResponse;
begin
  Result := LLMKit.Tools.RunTools(AChatter, ARequest, ATools, AMaxTurns);
end;

function LookupModel(const AName: string): TModelInfo;
begin
  Result := LLMKit.Catalog.Lookup(AName);
end;

function IsRateLimited(E: Exception): Boolean;
begin
  Result := LLMKit.Core.IsRateLimited(E);
end;

function IsContextLength(E: Exception): Boolean;
begin
  Result := LLMKit.Core.IsContextLength(E);
end;

function IsUnsupported(E: Exception): Boolean;
begin
  Result := LLMKit.Core.IsUnsupported(E);
end;

end.
