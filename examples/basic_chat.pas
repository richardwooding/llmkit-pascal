{ One chat turn against whatever model is named on the command line.

    ./basic_chat claude-sonnet-4-5 "Explain iterators in one paragraph"
}
program basic_chat;

{$mode objfpc}{$H+}

uses
  SysUtils, LLMKit;

var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Info: TModelInfo;
  Model: string;

begin
  Model := ParamStr(1);
  if Model = '' then
    Model := 'claude-sonnet-4-5';

  { Open[Chatter] fails here, before any network call, if the model's
    provider cannot chat. }
  Chat := OpenChatter(Model);

  Req := TLLMRequest.Create;
  try
    Req.SystemPrompt := 'Answer in one paragraph.';
    Req.Add(UserText(ParamStr(2)));
    Req.MaxTokens := OptInt(400);

    Resp := Chat.Chat(Req);
    try
      WriteLn(Resp.Text);
      WriteLn;
      Info := LookupModel(Model);
      WriteLn(Format('%d in / %d out tokens%s',
        [Resp.Usage.InputTokens, Resp.Usage.OutputTokens,
         specialize IfThen<string>(Info.Known,
           ' = ' + Info.CostString(Resp.Usage), '')]));
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end.
