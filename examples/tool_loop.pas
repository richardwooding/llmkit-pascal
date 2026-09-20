{ Tool calling: declare a tool, let RunTools drive the conversation.

    ./tool_loop gpt-5
}
program tool_loop;

{$mode objfpc}{$H+}

uses
  SysUtils, fpjson, LLMKit, LLMKit.JSONUtil;

type
  TWeather = class
    function Lookup(const AArguments: string): string;
  end;

function TWeather.Lookup(const AArguments: string): string;
var
  Args: TJSONData;
  City: string;
begin
  Args := TryParseJSON(AArguments);
  try
    City := JStr(Args, 'city', 'nowhere');
  finally
    Args.Free;
  end;
  { A real implementation would call a weather service here. }
  Result := Format('{"city":"%s","temperature_c":20,"sky":"clear"}', [City]);
end;

var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Tools: TToolSet;
  Weather: TWeather;
  Model: string;

begin
  Model := ParamStr(1);
  if Model = '' then
    Model := 'gpt-5';

  Chat := OpenChatter(Model);
  Weather := TWeather.Create;
  Tools := TToolSet.Create;
  Req := TLLMRequest.Create;
  try
    Tools.Add('weather', @Weather.Lookup);
    Req.AddTool('weather', 'Current weather for a city',
      '{"type":"object","properties":{"city":{"type":"string"}},' +
      '"required":["city"]}');
    Req.Add(UserText('What is the weather in Cape Town?'));

    { Chats, runs tools, appends the results and chats again, at most 5 times. }
    Resp := RunTools(Chat, Req, Tools, 5);
    try
      WriteLn(Resp.Text);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
    Tools.Free;
    Weather.Free;
  end;
end.
