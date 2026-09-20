{ TestSupport - an in-process fake vendor and a scripted chatter.

  Everything here runs on 127.0.0.1; no test touches the network.
}
unit TestSupport;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, DateUtils, SyncObjs, fphttpserver, fphttpclient, httpdefs, fpjson,
  LLMKit.Core, LLMKit.JSONUtil, LLMKit.Registry;

const
  FakeVendorPort = 18131;

type
  TFakeVendor = class
  private
    FServer: TFPHTTPServer;
    FThread: TThread;
    FLock: TCriticalSection;
    FPath: string;
    FMethod: string;
    FBody: string;
    FHeaders: TStringList;
    FStatus: Integer;
    FReply: string;
    FContentType: string;
    procedure HandleRequest(Sender: TObject;
      var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  public
    constructor Create;
    destructor Destroy; override;
    function BaseURL: string;
    { Next reply. }
    procedure Reply(const ABody: string; AStatus: Integer = 200;
      const AContentType: string = 'application/json');
    { Next reply as an event stream; lines are sent verbatim. }
    procedure ReplyEvents(const ALines: array of string);
    procedure ReplyLines(const ALines: array of string);
    { Last request seen. }
    function Path: string;
    function Method: string;
    function Body: string;
    function Header(const AName: string): string;
    { Parsed body; the caller frees it. }
    function BodyJSON: TJSONData;
    procedure Reset;
  end;

  { A chatter that returns canned responses in order, recording requests. }
  TScriptedChatter = class(TInterfacedObject, ILLMClient, IChatter)
  private
    FReplies: TStringList;
    FIndex: Integer;
    FSeenToolResults: TStringList;
    FTurns: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Each script entry is "text" or "tool:<id>:<name>:<argsjson>". }
    procedure Push(const AScript: string);
    function ProviderID: string;
    function ModelID: string;
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    property Turns: Integer read FTurns;
    property SeenToolResults: TStringList read FSeenToolResults;
  end;

{ The shared fake vendor; created on first use, closed at shutdown. }
function Vendor: TFakeVendor;
{ Options pointing at the fake vendor. }
function VendorOptions: TClientOptions;

implementation

type
  TServerThread = class(TThread)
  public
    Server: TFPHTTPServer;
    procedure Execute; override;
  end;

procedure TServerThread.Execute;
begin
  try
    Server.Active := True;
  except
    { the server is stopped by freeing it }
  end;
end;

constructor TFakeVendor.Create;
var
  T: TServerThread;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FHeaders := TStringList.Create;
  FStatus := 200;
  FContentType := 'application/json';
  FServer := TFPHTTPServer.Create(nil);
  FServer.Port := FakeVendorPort;
  FServer.Threaded := True;
  FServer.OnRequest := @HandleRequest;
  T := TServerThread.Create(True);
  T.FreeOnTerminate := False;
  T.Server := FServer;
  FThread := T;
  T.Start;
  Sleep(250); { let it bind }
end;

destructor TFakeVendor.Destroy;
var
  Deadline: TDateTime;
begin
  if FServer <> nil then
  begin
    FServer.Active := False;
    { The accept loop only notices once a connection arrives. }
    try
      TFPHTTPClient.SimpleGet(BaseURL + '/shutdown');
    except
      on Exception do ;
    end;
    Deadline := IncSecond(Now, 2);
    while (FThread <> nil) and not FThread.Finished and (Now < Deadline) do
      Sleep(20);
  end;
  { A thread still stuck in accept is left alone: this is a test process
    that is about to exit, and freeing the server under it would crash. }
  if (FThread <> nil) and FThread.Finished then
  begin
    FThread.Free;
    FServer.Free;
  end;
  FThread := nil;
  FServer := nil;
  FHeaders.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TFakeVendor.HandleRequest(Sender: TObject;
  var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
begin
  if Sender = nil then ;
  FLock.Enter;
  try
    FPath := ARequest.URI;
    FMethod := ARequest.Method;
    FBody := ARequest.Content;
    FHeaders.Clear;
    FHeaders.Values['authorization'] := ARequest.Authorization;
    FHeaders.Values['content-type'] := ARequest.ContentType;
    FHeaders.Values['user-agent'] := ARequest.UserAgent;
    FHeaders.Values['accept'] := ARequest.Accept;
    FHeaders.Values['x-api-key'] := ARequest.GetCustomHeader('x-api-key');
    FHeaders.Values['anthropic-version'] :=
      ARequest.GetCustomHeader('anthropic-version');
    AResponse.Code := FStatus;
    AResponse.ContentType := FContentType;
    AResponse.Content := FReply;
  finally
    FLock.Leave;
  end;
  AResponse.SendContent;
end;

function TFakeVendor.BaseURL: string;
begin
  Result := Format('http://127.0.0.1:%d', [FakeVendorPort]);
end;

procedure TFakeVendor.Reply(const ABody: string; AStatus: Integer;
  const AContentType: string);
begin
  FLock.Enter;
  try
    FReply := ABody;
    FStatus := AStatus;
    FContentType := AContentType;
  finally
    FLock.Leave;
  end;
end;

procedure TFakeVendor.ReplyEvents(const ALines: array of string);
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to High(ALines) do
    S := S + ALines[I] + #10;
  Reply(S, 200, 'text/event-stream');
end;

procedure TFakeVendor.ReplyLines(const ALines: array of string);
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 0 to High(ALines) do
    S := S + ALines[I] + #10;
  Reply(S, 200, 'application/x-ndjson');
end;

function TFakeVendor.Path: string;
begin
  FLock.Enter;
  try
    Result := FPath;
  finally
    FLock.Leave;
  end;
end;

function TFakeVendor.Method: string;
begin
  FLock.Enter;
  try
    Result := FMethod;
  finally
    FLock.Leave;
  end;
end;

function TFakeVendor.Body: string;
begin
  FLock.Enter;
  try
    Result := FBody;
  finally
    FLock.Leave;
  end;
end;

function TFakeVendor.Header(const AName: string): string;
begin
  FLock.Enter;
  try
    Result := FHeaders.Values[LowerCase(AName)];
  finally
    FLock.Leave;
  end;
end;

function TFakeVendor.BodyJSON: TJSONData;
begin
  Result := ParseJSON(Body);
end;

procedure TFakeVendor.Reset;
begin
  FLock.Enter;
  try
    FPath := '';
    FMethod := '';
    FBody := '';
    FHeaders.Clear;
    FReply := '';
    FStatus := 200;
    FContentType := 'application/json';
  finally
    FLock.Leave;
  end;
end;

{ TScriptedChatter }

constructor TScriptedChatter.Create;
begin
  inherited Create;
  FReplies := TStringList.Create;
  FSeenToolResults := TStringList.Create;
end;

destructor TScriptedChatter.Destroy;
begin
  FReplies.Free;
  FSeenToolResults.Free;
  inherited Destroy;
end;

procedure TScriptedChatter.Push(const AScript: string);
begin
  FReplies.Add(AScript);
end;

function TScriptedChatter.ProviderID: string;
begin
  Result := 'scripted';
end;

function TScriptedChatter.ModelID: string;
begin
  Result := 'scripted-1';
end;

function TScriptedChatter.Chat(ARequest: TLLMRequest): TLLMResponse;
var
  Script, ID, Name, Args: string;
  I, J, P: Integer;
  Msg: TLLMMessage;
begin
  Inc(FTurns);
  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    for J := 0 to Msg.Parts.Count - 1 do
      if Msg.Parts[J].Kind = pkToolResult then
        FSeenToolResults.Add(Msg.Parts[J].Name + '=' + Msg.Parts[J].Text);
  end;

  Result := TLLMResponse.Create;
  Result.Provider := 'scripted';
  Result.Model := 'scripted-1';
  if FIndex > FReplies.Count - 1 then
  begin
    Result.Add(TextPart('no script left'));
    Exit;
  end;
  Script := FReplies[FIndex];
  Inc(FIndex);
  if Copy(Script, 1, 5) = 'tool:' then
  begin
    Script := Copy(Script, 6, MaxInt);
    P := Pos(':', Script);
    ID := Copy(Script, 1, P - 1);
    Script := Copy(Script, P + 1, MaxInt);
    P := Pos(':', Script);
    Name := Copy(Script, 1, P - 1);
    Args := Copy(Script, P + 1, MaxInt);
    Result.Add(ToolCallPart(ID, Name, Args));
    Result.FinishReason := frToolCalls;
  end
  else
  begin
    Result.Add(TextPart(Script));
    Result.FinishReason := frStop;
  end;
end;

var
  GVendor: TFakeVendor;

function Vendor: TFakeVendor;
begin
  if GVendor = nil then
    GVendor := TFakeVendor.Create;
  Result := GVendor;
end;

function VendorOptions: TClientOptions;
begin
  Result := TClientOptions.Default.WithAPIKey('test-key')
    .WithBaseURL(Vendor.BaseURL).WithTimeout(5000);
end;

finalization
  FreeAndNil(GVendor);

end.
