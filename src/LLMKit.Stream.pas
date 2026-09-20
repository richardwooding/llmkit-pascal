{ LLMKit.Stream - turning a stream back into a response.

  Collect ranges over a stream and reassembles text, reasoning (with the
  signatures providers need on the next turn) and tool-call arguments that
  arrive in fragments, so the result can be appended to Request.Messages.
}
unit LLMKit.Stream;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, LLMKit.Core;

type
  { Accumulates chunks; useful on its own when a caller wants to both print
    and keep the assistant turn. }
  TChunkCollector = class
  private
    FText: string;
    FReasoning: string;
    FSignature: string;
    FCalls: array of record
      Index: Integer;
      ID: string;
      Name: string;
      Arguments: string;
    end;
    FUsage: TUsage;
    FFinishReason: TFinishReason;
    FPassThrough: TChunkEvent;
    function SlotFor(AIndex: Integer; const AID: string): Integer;
  public
    constructor Create;
    { The sink to hand to IStreamer.Stream. }
    function OnChunk(const AChunk: TLLMChunk): Boolean;
    { Builds the assistant turn; the caller owns it. }
    function BuildResponse(const AProvider, AModel: string): TLLMResponse;
    { Optional: every chunk is forwarded here as well (e.g. to print it). }
    property PassThrough: TChunkEvent read FPassThrough write FPassThrough;
    property Usage: TUsage read FUsage;
    property FinishReason: TFinishReason read FFinishReason;
    property Text: string read FText;
  end;

{ Consumes the whole stream and returns the assembled response. }
function Collect(AStreamer: IStreamer; ARequest: TLLMRequest): TLLMResponse;
{ Same, but every chunk is also handed to AOnChunk first (return False to
  stop early; whatever arrived so far is still returned). }
function Collect(AStreamer: IStreamer; ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): TLLMResponse;

implementation

constructor TChunkCollector.Create;
begin
  inherited Create;
  FFinishReason := frUnknown;
end;

function TChunkCollector.SlotFor(AIndex: Integer; const AID: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(FCalls) do
    if (FCalls[I].Index = AIndex) or
       ((AID <> '') and (FCalls[I].ID = AID)) then
      Exit(I);
  SetLength(FCalls, Length(FCalls) + 1);
  Result := High(FCalls);
  FCalls[Result].Index := AIndex;
  FCalls[Result].ID := AID;
end;

function TChunkCollector.OnChunk(const AChunk: TLLMChunk): Boolean;
var
  Slot: Integer;
begin
  Result := True;
  case AChunk.Kind of
    ckText:
      FText := FText + AChunk.Text;
    ckReasoning:
      begin
        FReasoning := FReasoning + AChunk.Text;
        if AChunk.Signature <> '' then
          FSignature := FSignature + AChunk.Signature;
      end;
    ckToolCall:
      begin
        Slot := SlotFor(AChunk.Index, AChunk.ToolCallID);
        if AChunk.ToolCallID <> '' then
          FCalls[Slot].ID := AChunk.ToolCallID;
        if AChunk.ToolName <> '' then
          FCalls[Slot].Name := AChunk.ToolName;
        FCalls[Slot].Arguments := FCalls[Slot].Arguments + AChunk.ArgumentsDelta;
      end;
    ckFinish:
      begin
        if AChunk.Usage.InputTokens > 0 then
          FUsage.InputTokens := AChunk.Usage.InputTokens;
        if AChunk.Usage.OutputTokens > 0 then
          FUsage.OutputTokens := AChunk.Usage.OutputTokens;
        if AChunk.Usage.CachedInputTokens > 0 then
          FUsage.CachedInputTokens := AChunk.Usage.CachedInputTokens;
        if AChunk.Usage.CacheWriteTokens > 0 then
          FUsage.CacheWriteTokens := AChunk.Usage.CacheWriteTokens;
        if AChunk.Usage.ReasoningTokens > 0 then
          FUsage.ReasoningTokens := AChunk.Usage.ReasoningTokens;
        if AChunk.FinishReason <> frUnknown then
          FFinishReason := AChunk.FinishReason;
      end;
  end;
  if FPassThrough <> nil then
    Result := FPassThrough(AChunk);
end;

function TChunkCollector.BuildResponse(const AProvider,
  AModel: string): TLLMResponse;
var
  I: Integer;
  Args: string;
begin
  Result := TLLMResponse.Create;
  Result.Provider := AProvider;
  Result.Model := AModel;
  Result.Usage := FUsage;
  Result.FinishReason := FFinishReason;
  if (FReasoning <> '') or (FSignature <> '') then
    Result.Add(ReasoningPart(FReasoning, FSignature));
  if FText <> '' then
    Result.Add(TextPart(FText));
  for I := 0 to High(FCalls) do
  begin
    Args := FCalls[I].Arguments;
    if Args = '' then
      Args := '{}';
    Result.Add(ToolCallPart(FCalls[I].ID, FCalls[I].Name, Args));
  end;
  if Result.HasToolCalls and (Result.FinishReason = frUnknown) then
    Result.FinishReason := frToolCalls;
end;

function Collect(AStreamer: IStreamer; ARequest: TLLMRequest): TLLMResponse;
begin
  Result := Collect(AStreamer, ARequest, nil);
end;

function Collect(AStreamer: IStreamer; ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): TLLMResponse;
var
  Collector: TChunkCollector;
begin
  if AStreamer = nil then
    raise ELLMInvalidRequest.Create('Collect: streamer is nil');
  Collector := TChunkCollector.Create;
  try
    Collector.PassThrough := AOnChunk;
    AStreamer.Stream(ARequest, @Collector.OnChunk);
    Result := Collector.BuildResponse(AStreamer.ProviderID, AStreamer.ModelID);
  finally
    Collector.Free;
  end;
end;

end.
