{ The tool-calling loop. }
unit TestTools;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, fpjson,
  LLMKit.Core, LLMKit.JSONUtil, LLMKit.Tools, TestSupport;

type
  TToolLoopTest = class(TTestCase)
  private
    FCalls: TStringList;
    function Weather(const AArguments: string): string;
    function Broken(const AArguments: string): string;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure UnknownToolIsReportedToTheModel;
    procedure HandlerErrorsBecomeToolResults;
    procedure LoopRunsUntilTheModelStops;
    procedure TurnLimitReturnsTheToolCall;
    procedure ConversationKeepsAssistantAndToolTurns;
  end;

implementation

procedure TToolLoopTest.SetUp;
begin
  FCalls := TStringList.Create;
end;

procedure TToolLoopTest.TearDown;
begin
  FCalls.Free;
end;

function TToolLoopTest.Weather(const AArguments: string): string;
var
  Data: TJSONData;
begin
  FCalls.Add(AArguments);
  Data := TryParseJSON(AArguments);
  try
    Result := Format('20C in %s', [JStr(Data, 'city', 'nowhere')]);
  finally
    Data.Free;
  end;
end;

function TToolLoopTest.Broken(const AArguments: string): string;
begin
  if AArguments = '' then ;
  Result := '';
  raise Exception.Create('upstream is down');
end;

procedure TToolLoopTest.LoopRunsUntilTheModelStops;
var
  Chatter: IChatter;
  Scripted: TScriptedChatter;
  Tools: TToolSet;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Scripted := TScriptedChatter.Create;
  Chatter := Scripted;
  Tools := TToolSet.Create;
  Req := TLLMRequest.Create('scripted-1');
  try
    Scripted.Push('tool:call_1:weather:{"city":"Cape Town"}');
    Scripted.Push('It is 20C in Cape Town.');
    Tools.Add('weather', @Weather);
    Req.Add(UserText('weather in Cape Town?'));
    Resp := RunTools(Chatter, Req, Tools, 5);
    try
      AssertEquals('It is 20C in Cape Town.', Resp.Text);
      AssertEquals(2, Scripted.Turns);
      AssertEquals(1, FCalls.Count);
      AssertEquals('{"city":"Cape Town"}', FCalls[0]);
      AssertEquals('weather=20C in Cape Town', Scripted.SeenToolResults[0]);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
    Tools.Free;
  end;
end;

procedure TToolLoopTest.UnknownToolIsReportedToTheModel;
var
  Chatter: IChatter;
  Scripted: TScriptedChatter;
  Tools: TToolSet;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Scripted := TScriptedChatter.Create;
  Chatter := Scripted;
  Tools := TToolSet.Create;
  Req := TLLMRequest.Create('scripted-1');
  try
    Scripted.Push('tool:call_1:missing:{}');
    Scripted.Push('sorry about that');
    Req.Add(UserText('go'));
    Resp := RunTools(Chatter, Req, Tools, 3);
    try
      AssertEquals('sorry about that', Resp.Text);
      AssertEquals('missing=unknown tool: missing',
        Scripted.SeenToolResults[0]);
      AssertTrue('the result is flagged as an error',
        Req.Messages[2].Parts[0].IsError);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
    Tools.Free;
  end;
end;

procedure TToolLoopTest.HandlerErrorsBecomeToolResults;
var
  Chatter: IChatter;
  Scripted: TScriptedChatter;
  Tools: TToolSet;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Scripted := TScriptedChatter.Create;
  Chatter := Scripted;
  Tools := TToolSet.Create;
  Req := TLLMRequest.Create('scripted-1');
  try
    Scripted.Push('tool:call_1:broken:{}');
    Scripted.Push('I will try later');
    Tools.Add('broken', @Broken);
    Req.Add(UserText('go'));
    Resp := RunTools(Chatter, Req, Tools, 3);
    try
      AssertEquals('I will try later', Resp.Text);
      AssertTrue('the exception text reaches the model',
        Pos('upstream is down', Scripted.SeenToolResults[0]) > 0);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
    Tools.Free;
  end;
end;

procedure TToolLoopTest.TurnLimitReturnsTheToolCall;
var
  Chatter: IChatter;
  Scripted: TScriptedChatter;
  Tools: TToolSet;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Scripted := TScriptedChatter.Create;
  Chatter := Scripted;
  Tools := TToolSet.Create;
  Req := TLLMRequest.Create('scripted-1');
  try
    Scripted.Push('tool:call_1:weather:{"city":"A"}');
    Scripted.Push('tool:call_2:weather:{"city":"B"}');
    Scripted.Push('never reached');
    Tools.Add('weather', @Weather);
    Req.Add(UserText('go'));
    Resp := RunTools(Chatter, Req, Tools, 2);
    try
      AssertTrue('the loop gives up with the tool call in hand',
        Resp.HasToolCalls);
      AssertEquals(2, Scripted.Turns);
      AssertEquals(1, FCalls.Count);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
    Tools.Free;
  end;
end;

procedure TToolLoopTest.ConversationKeepsAssistantAndToolTurns;
var
  Chatter: IChatter;
  Scripted: TScriptedChatter;
  Tools: TToolSet;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Scripted := TScriptedChatter.Create;
  Chatter := Scripted;
  Tools := TToolSet.Create;
  Req := TLLMRequest.Create('scripted-1');
  try
    Scripted.Push('tool:call_1:weather:{"city":"Cape Town"}');
    Scripted.Push('done');
    Tools.Add('weather', @Weather);
    Req.Add(UserText('weather?'));
    Resp := RunTools(Chatter, Req, Tools, 4);
    Resp.Free;
    AssertEquals(3, Req.Messages.Count);
    AssertTrue(Req.Messages[0].Role = lrUser);
    AssertTrue(Req.Messages[1].Role = lrAssistant);
    AssertTrue(Req.Messages[1].HasKind(pkToolCall));
    AssertTrue(Req.Messages[2].Role = lrTool);
    AssertEquals('call_1', Req.Messages[2].Parts[0].ID);
  finally
    Req.Free;
    Tools.Free;
  end;
end;

initialization
  RegisterTest(TToolLoopTest);

end.
