{ Streaming: print chunks as they arrive and keep the assembled turn.

    ./streaming llama3.2:3b "Count to five"
}
program streaming;

{$mode objfpc}{$H+}

uses
  SysUtils, LLMKit;

type
  TPrinter = class
    { Returning False here stops the stream and closes the connection. }
    function OnChunk(const AChunk: TLLMChunk): Boolean;
  end;

function TPrinter.OnChunk(const AChunk: TLLMChunk): Boolean;
begin
  if AChunk.Kind = ckText then
  begin
    Write(AChunk.Text);
    Flush(Output);
  end;
  Result := True;
end;

var
  Streamer: IStreamer;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Printer: TPrinter;
  Model: string;

begin
  Model := ParamStr(1);
  if Model = '' then
    Model := 'llama3.2:3b';

  Streamer := OpenStreamer(Model);
  Printer := TPrinter.Create;
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText(ParamStr(2)));
    { Collect reassembles text, reasoning and tool-call arguments while the
      printer sees every chunk. }
    Resp := Collect(Streamer, Req, @Printer.OnChunk);
    try
      WriteLn;
      WriteLn(Format('[%d tokens out, finished: %s]',
        [Resp.Usage.OutputTokens, FinishReasonToString(Resp.FinishReason)]));
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
    Printer.Free;
  end;
end.
