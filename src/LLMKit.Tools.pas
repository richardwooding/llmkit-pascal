{ LLMKit.Tools - the small tool-calling loop.

  RunTools appends assistant and tool messages to Request.Messages until the
  model stops calling tools, feeding handler failures back as error results.
  It is a loop, not an agent framework: bring your own planning and memory.
}
unit LLMKit.Tools;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fgl, LLMKit.Core;

type
  { Receives the raw JSON arguments and returns the tool output. }
  TToolMethod = function(const AArguments: string): string of object;
  TToolProc = function(const AArguments: string): string;

  TToolEntry = class
  public
    Name: string;
    Method: TToolMethod;
    Proc: TToolProc;
    function Invoke(const AArguments: string): string;
  end;

  TToolEntryList = specialize TFPGObjectList<TToolEntry>;

  { Name to implementation map handed to RunTools. }
  TToolSet = class
  private
    FEntries: TToolEntryList;
    function Find(const AName: string): TToolEntry;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const AName: string; AMethod: TToolMethod);
    procedure Add(const AName: string; AProc: TToolProc);
    function Has(const AName: string): Boolean;
    { Runs the tool; unknown names and exceptions come back as errors. }
    function Invoke(const AName, AArguments: string;
      out AIsError: Boolean): string;
    function Count: Integer;
  end;

{ Chats until the model stops calling tools or AMaxTurns is reached, adding
  every assistant turn and tool result to ARequest.Messages. Returns the final
  response, which the caller owns. }
function RunTools(AChatter: IChatter; ARequest: TLLMRequest; ATools: TToolSet;
  AMaxTurns: Integer): TLLMResponse;

implementation

function TToolEntry.Invoke(const AArguments: string): string;
begin
  if Method <> nil then
    Result := Method(AArguments)
  else if Proc <> nil then
    Result := Proc(AArguments)
  else
    Result := '';
end;

constructor TToolSet.Create;
begin
  inherited Create;
  FEntries := TToolEntryList.Create(True);
end;

destructor TToolSet.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

function TToolSet.Find(const AName: string): TToolEntry;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    if FEntries[I].Name = AName then
      Exit(FEntries[I]);
  Result := nil;
end;

procedure TToolSet.Add(const AName: string; AMethod: TToolMethod);
var
  Entry: TToolEntry;
begin
  Entry := Find(AName);
  if Entry = nil then
  begin
    Entry := TToolEntry.Create;
    Entry.Name := AName;
    FEntries.Add(Entry);
  end;
  Entry.Method := AMethod;
  Entry.Proc := nil;
end;

procedure TToolSet.Add(const AName: string; AProc: TToolProc);
var
  Entry: TToolEntry;
begin
  Entry := Find(AName);
  if Entry = nil then
  begin
    Entry := TToolEntry.Create;
    Entry.Name := AName;
    FEntries.Add(Entry);
  end;
  Entry.Proc := AProc;
  Entry.Method := nil;
end;

function TToolSet.Has(const AName: string): Boolean;
begin
  Result := Find(AName) <> nil;
end;

function TToolSet.Count: Integer;
begin
  Result := FEntries.Count;
end;

function TToolSet.Invoke(const AName, AArguments: string;
  out AIsError: Boolean): string;
var
  Entry: TToolEntry;
begin
  AIsError := False;
  Entry := Find(AName);
  if Entry = nil then
  begin
    AIsError := True;
    Exit(Format('unknown tool: %s', [AName]));
  end;
  try
    Result := Entry.Invoke(AArguments);
  except
    on E: Exception do
    begin
      AIsError := True;
      Result := Format('%s: %s', [E.ClassName, E.Message]);
    end;
  end;
end;

function RunTools(AChatter: IChatter; ARequest: TLLMRequest; ATools: TToolSet;
  AMaxTurns: Integer): TLLMResponse;
var
  Turn, I: Integer;
  Response: TLLMResponse;
  Calls: TPartList;
  ToolMsg: TLLMMessage;
  Output: string;
  Failed: Boolean;
begin
  if AChatter = nil then
    raise ELLMInvalidRequest.Create('RunTools: chatter is nil');
  if ARequest = nil then
    raise ELLMInvalidRequest.Create('RunTools: request is nil');
  if ATools = nil then
    raise ELLMInvalidRequest.Create('RunTools: tool set is nil');
  if AMaxTurns <= 0 then
    AMaxTurns := 1;

  Result := nil;
  for Turn := 1 to AMaxTurns do
  begin
    Response := AChatter.Chat(ARequest);
    if not Response.HasToolCalls then
      Exit(Response);
    if Turn = AMaxTurns then
      Exit(Response); { out of turns: hand back the tool calls unanswered }

    ARequest.Add(Response.ToMessage);
    ToolMsg := TLLMMessage.Create(lrTool);
    Calls := Response.ToolCalls;
    try
      for I := 0 to Calls.Count - 1 do
      begin
        Output := ATools.Invoke(Calls[I].Name, Calls[I].Arguments, Failed);
        ToolMsg.Add(ToolResultPart(Calls[I].ID, Calls[I].Name, Output, Failed));
      end;
    finally
      Calls.Free;
      Response.Free;
    end;
    ARequest.Add(ToolMsg);
  end;
end;

end.
