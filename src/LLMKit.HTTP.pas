{ LLMKit.HTTP - JSON and server-sent-event transport shared by all providers.

  Streaming does not buffer the whole body: the response is written into a
  TStream sink that splits lines as they arrive, so chunks surface while the
  request is still open. Returning False from a handler aborts the read and
  closes the connection at once.
}
unit LLMKit.HTTP;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fphttpclient, opensslsockets, fpjson,
  LLMKit.Core, LLMKit.JSONUtil;

type
  THeaderPair = record
    Name: string;
    Value: string;
  end;

  THeaderArray = array of THeaderPair;

  TSSEEvent = record
    EventName: string;
    Data: string;
    ID: string;
  end;

  { Return False to stop the stream. }
  TSSEHandler = function(const AEvent: TSSEEvent): Boolean of object;
  TLineHandler = function(const ALine: string): Boolean of object;

  { Internal: raised inside the sink when a handler asks to stop. }
  ELLMStreamStop = class(Exception);

  { Splits an incoming byte stream into lines without buffering it all. }
  TLineSink = class(TStream)
  private
    FBuffer: string;
    FRaw: string;
    FBufferAll: Boolean;
    FHandler: TLineHandler;
    FStopped: Boolean;
  public
    constructor Create(AHandler: TLineHandler);
    function Write(const Buffer; Count: LongInt): LongInt; override;
    function Read(var Buffer; Count: LongInt): LongInt; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    { Dispatches a trailing line that was not newline terminated. }
    procedure Flush;
    property Stopped: Boolean read FStopped;
    { Set once the status line says the reply is an error body, not a stream. }
    property BufferAll: Boolean read FBufferAll write FBufferAll;
    property Raw: string read FRaw;
  end;

  { One provider's HTTP client: base URL, auth headers, timeouts and the
    vendor error mapping. }
  TTransport = class
  private
    FProviderID: string;
    FBaseURL: string;
    FTimeoutMS: Integer;
    FHeaders: THeaderArray;
    FSSEHandler: TSSEHandler;
    FEvent: TSSEEvent;
    FEventHasData: Boolean;
    FLastStatus: Integer;
    FLastRetryAfter: Integer;
    FSink: TLineSink;
    procedure HeadersReceived(Sender: TObject);
      function NewClient: TFPHTTPClient;
    procedure ApplyHeaders(AClient: TFPHTTPClient);
    function SSELine(const ALine: string): Boolean;
    function DispatchEvent: Boolean;
    procedure RaiseForStatus(AClient: TFPHTTPClient; const ABody: string);
  public
    constructor Create(const AProviderID, ABaseURL: string; ATimeoutMS: Integer);
    procedure SetHeader(const AName, AValue: string);
    function URL(const APath: string): string;
    { Sends ABody (which the caller still owns) and returns parsed JSON that
      the caller must free. Raises EAPIError on a non-2xx reply. }
    function PostJSON(const APath: string; ABody: TJSONObject): TJSONData;
    function PostJSONText(const APath, ABody: string): string;
    function GetJSON(const APath: string): TJSONData;
    { Streams text/event-stream. Returns False when a handler stopped it. }
    function PostSSE(const APath: string; ABody: TJSONObject;
      AOnEvent: TSSEHandler): Boolean;
    { Streams newline-delimited JSON (Ollama). }
    function PostLines(const APath: string; ABody: TJSONObject;
      AOnLine: TLineHandler): Boolean;
    property ProviderID: string read FProviderID;
    property BaseURL: string read FBaseURL write FBaseURL;
    property TimeoutMS: Integer read FTimeoutMS write FTimeoutMS;
  end;

{ Percent-encodes a ':' in the last path segment; see TTransport.URL. }
function EncodeLastSegmentColon(const APath: string): string;
{ Maps an HTTP status and error text onto the cross-vendor classification. }
function ClassifyStatus(AStatus: Integer; const AMessage, ACode: string): TAPIErrorKind;
{ Pulls message/code out of the error shapes used by the supported vendors. }
procedure ExtractError(const ABody: string; out AMessage, ACode: string);
function JoinURL(const ABase, APath: string): string;

implementation

function EncodeLastSegmentColon(const APath: string): string;
var
  Slash, Query, I: Integer;
begin
  Result := APath;
  Query := Pos('?', Result);
  if Query = 0 then
    Query := Length(Result) + 1;
  Slash := 0;
  for I := 1 to Query - 1 do
    if Result[I] = '/' then
      Slash := I;
  for I := Query - 1 downto Slash + 1 do
    if Result[I] = ':' then
      Result := Copy(Result, 1, I - 1) + '%3A' + Copy(Result, I + 1, MaxInt);
end;

function JoinURL(const ABase, APath: string): string;
begin
  if APath = '' then
    Exit(ABase);
  if (Pos('http://', APath) = 1) or (Pos('https://', APath) = 1) then
    Exit(APath);
  Result := ABase;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
  if APath[1] = '/' then
    Result := Result + APath
  else
    Result := Result + '/' + APath;
end;

function ClassifyStatus(AStatus: Integer; const AMessage, ACode: string): TAPIErrorKind;
var
  M: string;
begin
  M := LowerCase(AMessage + ' ' + ACode);
  if (Pos('context length', M) > 0) or (Pos('context_length', M) > 0) or
     (Pos('maximum context', M) > 0) or (Pos('too many tokens', M) > 0) or
     (Pos('prompt is too long', M) > 0) or (Pos('string too long', M) > 0) or
     (Pos('context window', M) > 0) then
    Exit(aekContextLength);
  if (Pos('rate limit', M) > 0) or (Pos('rate_limit', M) > 0) or
     (Pos('quota', M) > 0) then
    Exit(aekRateLimited);
  if (Pos('overloaded', M) > 0) then
    Exit(aekOverloaded);
  case AStatus of
    400, 422: Result := aekInvalidRequest;
    401: Result := aekAuth;
    403: Result := aekPermission;
    404: Result := aekNotFound;
    408: Result := aekTimeout;
    413: Result := aekContextLength;
    429: Result := aekRateLimited;
    500, 502, 504: Result := aekServer;
    503, 529: Result := aekOverloaded;
  else
    if AStatus >= 500 then
      Result := aekServer
    else
      Result := aekUnknown;
  end;
end;

procedure ExtractError(const ABody: string; out AMessage, ACode: string);
var
  D, ErrNode: TJSONData;
begin
  AMessage := '';
  ACode := '';
  D := TryParseJSON(ABody);
  if D = nil then
  begin
    AMessage := Trim(Copy(ABody, 1, 500));
    Exit;
  end;
  try
    ErrNode := JGet(D, 'error');
    if (ErrNode <> nil) and (ErrNode.JSONType = jtObject) then
    begin
      { OpenAI, Anthropic, Vertex, OpenRouter }
      AMessage := JStr(ErrNode, 'message');
      ACode := JStr(ErrNode, 'code');
      if ACode = '' then
        ACode := JStr(ErrNode, 'type');
      if ACode = '' then
        ACode := JStr(ErrNode, 'status');
    end
    else if (ErrNode <> nil) and (ErrNode.JSONType = jtString) then
      { Ollama, Hugging Face }
      AMessage := ErrNode.AsString;
    if AMessage = '' then
      { Cohere, VoyageAI }
      AMessage := JStr(D, 'message');
    if AMessage = '' then
      AMessage := JStr(D, 'detail');
    if AMessage = '' then
      AMessage := Trim(Copy(ABody, 1, 500));
  finally
    D.Free;
  end;
end;

{ TLineSink }

constructor TLineSink.Create(AHandler: TLineHandler);
begin
  inherited Create;
  FHandler := AHandler;
end;

function TLineSink.Write(const Buffer; Count: LongInt): LongInt;
var
  Incoming, Line: string;
  P: Integer;
begin
  Result := Count;
  if Count <= 0 then
    Exit;
  Incoming := '';
  SetLength(Incoming, Count);
  Move(Buffer, Incoming[1], Count);
  if FBufferAll then
  begin
    FRaw := FRaw + Incoming;
    Exit;
  end;
  FBuffer := FBuffer + Incoming;
  repeat
    P := Pos(#10, FBuffer);
    if P = 0 then
      Break;
    Line := Copy(FBuffer, 1, P - 1);
    Delete(FBuffer, 1, P);
    if (Line <> '') and (Line[Length(Line)] = #13) then
      SetLength(Line, Length(Line) - 1);
    if not FHandler(Line) then
    begin
      FStopped := True;
      raise ELLMStreamStop.Create('stream stopped by handler');
    end;
  until False;
end;

function TLineSink.Read(var Buffer; Count: LongInt): LongInt;
begin
  { write-only sink }
  FillChar(Buffer, 0, 0);
  if Count = 0 then ;
  Result := 0;
end;

function TLineSink.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  if (Offset = 0) and (Origin = soCurrent) then ;
  Result := 0;
end;

procedure TLineSink.Flush;
var
  Line: string;
begin
  if FStopped or FBufferAll or (Trim(FBuffer) = '') then
    Exit;
  Line := FBuffer;
  FBuffer := '';
  if (Line <> '') and (Line[Length(Line)] = #13) then
    SetLength(Line, Length(Line) - 1);
  if not FHandler(Line) then
    FStopped := True;
end;

{ TTransport }

constructor TTransport.Create(const AProviderID, ABaseURL: string;
  ATimeoutMS: Integer);
begin
  inherited Create;
  FProviderID := AProviderID;
  FBaseURL := ABaseURL;
  FTimeoutMS := ATimeoutMS;
  FLastRetryAfter := -1;
end;

procedure TTransport.SetHeader(const AName, AValue: string);
var
  I: Integer;
begin
  for I := 0 to High(FHeaders) do
    if SameText(FHeaders[I].Name, AName) then
    begin
      FHeaders[I].Value := AValue;
      Exit;
    end;
  SetLength(FHeaders, Length(FHeaders) + 1);
  FHeaders[High(FHeaders)].Name := AName;
  FHeaders[High(FHeaders)].Value := AValue;
end;

function TTransport.URL(const APath: string): string;
begin
  { FPC's ParseURI mis-splits a ':' in the last path segment - Vertex's
    ":generateContent" - and the client then sends a stray trailing '/'.
    Percent-encoding the colon is equivalent per RFC 3986 and avoids it. }
  Result := JoinURL(FBaseURL, EncodeLastSegmentColon(APath));
end;

function TTransport.NewClient: TFPHTTPClient;
begin
  Result := TFPHTTPClient.Create(nil);
  Result.AllowRedirect := True;
  Result.KeepConnection := False;
  if FTimeoutMS > 0 then
  begin
    Result.IOTimeout := FTimeoutMS;
    Result.ConnectTimeout := FTimeoutMS;
  end;
  ApplyHeaders(Result);
end;

procedure TTransport.ApplyHeaders(AClient: TFPHTTPClient);
var
  I: Integer;
begin
  AClient.AddHeader('User-Agent', 'llmkit-pascal/' + LLMKitVersion);
  AClient.AddHeader('Accept', 'application/json');
  AClient.AddHeader('Content-Type', 'application/json');
  for I := 0 to High(FHeaders) do
    AClient.AddHeader(FHeaders[I].Name, FHeaders[I].Value);
end;

procedure TTransport.RaiseForStatus(AClient: TFPHTTPClient; const ABody: string);
var
  Msg, Code, RA: string;
  Retry: Integer;
begin
  FLastStatus := AClient.ResponseStatusCode;
  if (FLastStatus >= 200) and (FLastStatus < 300) then
    Exit;
  ExtractError(ABody, Msg, Code);
  RA := AClient.GetHeader(AClient.ResponseHeaders, 'Retry-After');
  if (RA = '') or not TryStrToInt(Trim(RA), Retry) then
    Retry := -1;
  FLastRetryAfter := Retry;
  raise EAPIError.Create(FProviderID, FLastStatus, Code, Msg,
    ClassifyStatus(FLastStatus, Msg, Code), Retry, ABody);
end;

function TTransport.PostJSONText(const APath, ABody: string): string;
var
  Client: TFPHTTPClient;
  Response: TStringStream;
begin
  Client := NewClient;
  try
    Client.RequestBody := TStringStream.Create(ABody);
    Response := TStringStream.Create('');
    try
      try
        Client.HTTPMethod('POST', URL(APath), Response, []);
      except
        on E: EAPIError do
          raise;
        on E: Exception do
          raise EAPIError.Create(FProviderID, 0, '', E.Message, aekNetwork, -1, '');
      end;
      Result := Response.DataString;
      RaiseForStatus(Client, Result);
    finally
      Response.Free;
    end;
  finally
    Client.RequestBody.Free;
    Client.RequestBody := nil;
    Client.Free;
  end;
end;

function TTransport.PostJSON(const APath: string; ABody: TJSONObject): TJSONData;
var
  Text: string;
begin
  Text := PostJSONText(APath, CompactJSON(ABody));
  Result := ParseJSON(Text);
end;

function TTransport.GetJSON(const APath: string): TJSONData;
var
  Client: TFPHTTPClient;
  Response: TStringStream;
  Text: string;
begin
  Client := NewClient;
  try
    Response := TStringStream.Create('');
    try
      try
        Client.HTTPMethod('GET', URL(APath), Response, []);
      except
        on E: EAPIError do
          raise;
        on E: Exception do
          raise EAPIError.Create(FProviderID, 0, '', E.Message, aekNetwork, -1, '');
      end;
      Text := Response.DataString;
      RaiseForStatus(Client, Text);
    finally
      Response.Free;
    end;
  finally
    Client.Free;
  end;
  Result := ParseJSON(Text);
end;

function TTransport.DispatchEvent: Boolean;
begin
  Result := True;
  if not FEventHasData then
    Exit;
  Result := FSSEHandler(FEvent);
  FEvent.EventName := '';
  FEvent.Data := '';
  FEvent.ID := '';
  FEventHasData := False;
end;

function TTransport.SSELine(const ALine: string): Boolean;
var
  Field, Value: string;
  P: Integer;
begin
  if ALine = '' then
    Exit(DispatchEvent);
  if ALine[1] = ':' then
    Exit(True); { comment / keep-alive }
  P := Pos(':', ALine);
  if P = 0 then
  begin
    Field := ALine;
    Value := '';
  end
  else
  begin
    Field := Copy(ALine, 1, P - 1);
    Value := Copy(ALine, P + 1, MaxInt);
    if (Value <> '') and (Value[1] = ' ') then
      Delete(Value, 1, 1);
  end;
  if Field = 'data' then
  begin
    if FEventHasData and (FEvent.Data <> '') then
      FEvent.Data := FEvent.Data + #10 + Value
    else
      FEvent.Data := Value;
    FEventHasData := True;
  end
  else if Field = 'event' then
  begin
    FEvent.EventName := Value;
    FEventHasData := True;
  end
  else if Field = 'id' then
    FEvent.ID := Value;
  Result := True;
end;

function TTransport.PostSSE(const APath: string; ABody: TJSONObject;
  AOnEvent: TSSEHandler): Boolean;
begin
  FSSEHandler := AOnEvent;
  FEvent.EventName := '';
  FEvent.Data := '';
  FEvent.ID := '';
  FEventHasData := False;
  Result := PostLines(APath, ABody, @SSELine);
end;

function TTransport.PostLines(const APath: string; ABody: TJSONObject;
  AOnLine: TLineHandler): Boolean;
var
  Client: TFPHTTPClient;
  Stopped: Boolean;
begin
  Client := NewClient;
  Client.AddHeader('Accept', 'text/event-stream');
  { OnHeaders switches the sink to buffering when the reply is an error, so
    the vendor message survives instead of being parsed as chunks. }
  Client.OnHeaders := @HeadersReceived;
  FSink := TLineSink.Create(AOnLine);
  Stopped := False;
  try
    Client.RequestBody := TStringStream.Create(CompactJSON(ABody));
    try
      try
        Client.HTTPMethod('POST', URL(APath), FSink, []);
        FSink.Flush;
      except
        on ELLMStreamStop do
          Stopped := True;
        on E: EAPIError do
          raise;
        on E: Exception do
        begin
          if Client.ResponseStatusCode >= 400 then
            RaiseForStatus(Client, FSink.Raw)
          else
            raise EAPIError.Create(FProviderID, 0, '', E.Message, aekNetwork,
              -1, '');
        end;
      end;
      if not Stopped then
        RaiseForStatus(Client, FSink.Raw);
      Result := not Stopped;
    finally
      Client.RequestBody.Free;
      Client.RequestBody := nil;
    end;
  finally
    FreeAndNil(FSink);
    Client.Free;
  end;
end;

procedure TTransport.HeadersReceived(Sender: TObject);
begin
  if (FSink <> nil) and (TFPHTTPClient(Sender).ResponseStatusCode >= 400) then
    FSink.BufferAll := True;
end;

end.
