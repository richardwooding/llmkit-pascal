{ The message model, the SSE line sink, error classification and the catalog. }
unit TestCore;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, fpjson,
  LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP, LLMKit.Catalog, LLMKit.Stream;

type
  TCoreTest = class(TTestCase)
  published
    procedure MessagesOwnTheirParts;
    procedure ResponseTextSkipsReasoning;
    procedure ResponseToMessageClonesParts;
    procedure RequestCloneIsDeep;
    procedure UsageAdds;
    procedure FinishReasonsAreCrossVendor;
    procedure Base64RoundTrips;
    procedure JSONPathsAreNilSafe;
    procedure ExtrasMergeOverBody;
  end;

  TSinkTest = class(TTestCase)
  private
    FLines: TStringList;
    FStopAfter: Integer;
    function Collect(const ALine: string): Boolean;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure SplitsLinesAcrossWrites;
    procedure HandlesCRLFAndFlush;
    procedure StopsWhenHandlerSaysSo;
  end;

  TErrorTest = class(TTestCase)
  published
    procedure StatusMapsToKind;
    procedure ContextLengthBeatsStatus;
    procedure ExtractsVendorShapes;
    procedure JoinsURLs;
  end;

  TCatalogTest = class(TTestCase)
  published
    procedure LooksUpExactNames;
    procedure StripsPrefixAndVersion;
    procedure ResolvesDatedSnapshots;
    procedure UnknownIsNotGuessed;
    procedure CostsUseCacheRates;
    procedure RegisterOverrides;
  end;

  TCollectorTest = class(TTestCase)
  published
    procedure ReassemblesTextAndTools;
    procedure KeepsReasoningSignature;
  end;

implementation

{ TCoreTest }

procedure TCoreTest.MessagesOwnTheirParts;
var
  Msg: TLLMMessage;
begin
  Msg := UserMessage([TextPart('a'), TextPart('b')]);
  try
    AssertEquals(2, Msg.Parts.Count);
    AssertEquals('ab', Msg.Text);
    AssertEquals('user', RoleToString(Msg.Role));
  finally
    Msg.Free; { must free both parts; run under -gh to confirm }
  end;
end;

procedure TCoreTest.ResponseTextSkipsReasoning;
var
  Resp: TLLMResponse;
begin
  Resp := TLLMResponse.Create;
  try
    Resp.Add(ReasoningPart('thinking', 'sig'));
    Resp.Add(TextPart('answer'));
    Resp.Add(ToolCallPart('id1', 'weather', '{"city":"Cape Town"}'));
    AssertEquals('answer', Resp.Text);
    AssertEquals('thinking', Resp.ReasoningText);
    AssertTrue(Resp.HasToolCalls);
  finally
    Resp.Free;
  end;
end;

procedure TCoreTest.ResponseToMessageClonesParts;
var
  Resp: TLLMResponse;
  Msg: TLLMMessage;
begin
  Resp := TLLMResponse.Create;
  Resp.Add(TextPart('hello'));
  Resp.Add(ToolCallPart('id1', 'weather', '{}'));
  Msg := Resp.ToMessage;
  try
    Resp.Free; { the message must survive the response }
    AssertEquals(2, Msg.Parts.Count);
    AssertEquals('hello', Msg.Text);
    AssertEquals('id1', Msg.Parts[1].ID);
  finally
    Msg.Free;
  end;
end;

procedure TCoreTest.RequestCloneIsDeep;
var
  Req, Copy: TLLMRequest;
begin
  Req := TLLMRequest.Create('gpt-5');
  try
    Req.AddUserText('hi');
    Req.AddTool('weather', 'get weather', '{"type":"object"}');
    Req.Temperature := OptFloat(0.5);
    Req.Extra.Add('service_tier', 'flex');
    Copy := Req.Clone;
    try
      Req.Messages[0].Parts[0].Text := 'changed';
      AssertEquals('hi', Copy.Messages[0].Text);
      AssertEquals(1, Copy.Tools.Count);
      AssertTrue(Copy.Temperature.HasValue);
      AssertEquals('flex', Copy.Extra.Get('service_tier', ''));
    finally
      Copy.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure TCoreTest.UsageAdds;
var
  A, B: TUsage;
begin
  A := Default(TUsage);
  B := Default(TUsage);
  A.InputTokens := 10;
  A.OutputTokens := 5;
  B.InputTokens := 1;
  B.CachedInputTokens := 7;
  A.Add(B);
  AssertEquals(11, A.InputTokens);
  AssertEquals(7, A.CachedInputTokens);
  AssertEquals(16, A.TotalTokens);
end;

procedure TCoreTest.FinishReasonsAreCrossVendor;
begin
  AssertTrue(ParseFinishReason('end_turn') = frStop);        { anthropic }
  AssertTrue(ParseFinishReason('COMPLETE') = frStop);        { cohere }
  AssertTrue(ParseFinishReason('STOP') = frStop);            { vertex }
  AssertTrue(ParseFinishReason('max_tokens') = frLength);
  AssertTrue(ParseFinishReason('tool_use') = frToolCalls);   { anthropic }
  AssertTrue(ParseFinishReason('TOOL_CALL') = frToolCalls);  { cohere }
  AssertTrue(ParseFinishReason('tool_calls') = frToolCalls); { openai }
  AssertTrue(ParseFinishReason('nonsense') = frUnknown);
end;

procedure TCoreTest.Base64RoundTrips;
var
  Data, Back: TBytes;
  Encoded: string;
begin
  Data := StringToBytes('binary'#0'payload');
  Encoded := Base64FromBytes(Data);
  Back := BytesFromBase64(Encoded);
  AssertEquals(Length(Data), Length(Back));
  AssertEquals(BytesToString(Data), BytesToString(Back));
  AssertEquals('data:image/png;base64,' + Encoded, DataURL(Data, 'image/png'));
end;

procedure TCoreTest.JSONPathsAreNilSafe;
var
  D: TJSONData;
begin
  D := ParseJSON('{"a":{"b":[{"c":7}]},"s":"x","f":1.5,"t":true}');
  try
    AssertEquals(7, JInt(D, 'a.b.0.c'));
    AssertEquals('x', JStr(D, 's'));
    AssertEquals(1.5, JFloat(D, 'f'), 0.0001);
    AssertTrue(JBool(D, 't'));
    AssertEquals(0, JInt(D, 'a.b.9.c'));
    AssertEquals('fallback', JStr(D, 'missing.path', 'fallback'));
    AssertTrue(JArray(D, 's') = nil);
    AssertFalse(JHas(D, 'nope'));
  finally
    D.Free;
  end;
  AssertTrue(TryParseJSON('{not json') = nil);
end;

procedure TCoreTest.ExtrasMergeOverBody;
var
  Req: TLLMRequest;
  Body: TJSONObject;
begin
  Req := TLLMRequest.Create('gpt-5');
  Body := TJSONObject.Create(['model', 'gpt-5', 'temperature', 0.2]);
  try
    Req.Extra.Add('service_tier', 'flex');
    Req.Extra.Add('temperature', 0.9);
    Req.ProviderOptions.Add('anthropic', TJSONObject.Create(['top_k', 5]));
    ApplyExtras(Body, Req, 'openai');
    AssertEquals('flex', Body.Get('service_tier', ''));
    AssertEquals(0.9, Body.Get('temperature', 0.0), 0.0001);
    AssertTrue('provider options for others are ignored',
      Body.IndexOfName('top_k') < 0);
    ApplyExtras(Body, Req, 'anthropic');
    AssertEquals(5, Body.Get('top_k', 0));
  finally
    Body.Free;
    Req.Free;
  end;
end;

{ TSinkTest }

procedure TSinkTest.SetUp;
begin
  FLines := TStringList.Create;
  FStopAfter := -1;
end;

procedure TSinkTest.TearDown;
begin
  FLines.Free;
end;

function TSinkTest.Collect(const ALine: string): Boolean;
begin
  FLines.Add(ALine);
  Result := (FStopAfter < 0) or (FLines.Count < FStopAfter);
end;

procedure TSinkTest.SplitsLinesAcrossWrites;
var
  Sink: TLineSink;
  Part: string;
begin
  Sink := TLineSink.Create(@Collect);
  try
    Part := 'data: {"a":1}'#10'data: {"b"';
    Sink.Write(Part[1], Length(Part));
    AssertEquals(1, FLines.Count);
    Part := ':2}'#10#10;
    Sink.Write(Part[1], Length(Part));
    AssertEquals(3, FLines.Count);
    AssertEquals('data: {"a":1}', FLines[0]);
    AssertEquals('data: {"b":2}', FLines[1]);
    AssertEquals('', FLines[2]);
  finally
    Sink.Free;
  end;
end;

procedure TSinkTest.HandlesCRLFAndFlush;
var
  Sink: TLineSink;
  Part: string;
begin
  Sink := TLineSink.Create(@Collect);
  try
    Part := 'one'#13#10'two';
    Sink.Write(Part[1], Length(Part));
    AssertEquals(1, FLines.Count);
    AssertEquals('one', FLines[0]);
    Sink.Flush;
    AssertEquals(2, FLines.Count);
    AssertEquals('two', FLines[1]);
  finally
    Sink.Free;
  end;
end;

procedure TSinkTest.StopsWhenHandlerSaysSo;
var
  Sink: TLineSink;
  Part: string;
  Stopped: Boolean;
begin
  FStopAfter := 2;
  Stopped := False;
  Sink := TLineSink.Create(@Collect);
  try
    Part := 'a'#10'b'#10'c'#10;
    try
      Sink.Write(Part[1], Length(Part));
    except
      on ELLMStreamStop do
        Stopped := True;
    end;
    AssertTrue('the sink aborts the read', Stopped);
    AssertEquals(2, FLines.Count);
    AssertTrue(Sink.Stopped);
  finally
    Sink.Free;
  end;
end;

{ TErrorTest }

procedure TErrorTest.StatusMapsToKind;
begin
  AssertTrue(ClassifyStatus(401, 'bad key', '') = aekAuth);
  AssertTrue(ClassifyStatus(403, '', '') = aekPermission);
  AssertTrue(ClassifyStatus(404, '', '') = aekNotFound);
  AssertTrue(ClassifyStatus(429, '', '') = aekRateLimited);
  AssertTrue(ClassifyStatus(500, '', '') = aekServer);
  AssertTrue(ClassifyStatus(529, '', '') = aekOverloaded);
  AssertTrue(ClassifyStatus(422, '', '') = aekInvalidRequest);
end;

procedure TErrorTest.ContextLengthBeatsStatus;
var
  Err: EAPIError;
begin
  AssertTrue(ClassifyStatus(400,
    'This model''s maximum context length is 8192 tokens', '') = aekContextLength);
  AssertTrue(ClassifyStatus(400, 'prompt is too long: 250000 tokens', '') =
    aekContextLength);
  AssertTrue(ClassifyStatus(200, 'rate limit reached', '') = aekRateLimited);
  Err := EAPIError.Create('openai', 429, 'rate_limit_exceeded', 'slow down',
    aekRateLimited, 30, '{}');
  try
    AssertTrue(IsRateLimited(Err));
    AssertFalse(IsContextLength(Err));
    AssertTrue(Err.IsRetryable);
    AssertEquals(30, Err.RetryAfter);
    AssertTrue(Pos('HTTP 429', Err.Message) > 0);
  finally
    Err.Free;
  end;
end;

procedure TErrorTest.ExtractsVendorShapes;
var
  Msg, Code: string;
begin
  ExtractError('{"error":{"message":"bad","type":"invalid_request_error"}}', Msg, Code);
  AssertEquals('bad', Msg);
  AssertEquals('invalid_request_error', Code);
  ExtractError('{"error":"model not found"}', Msg, Code);
  AssertEquals('model not found', Msg);
  ExtractError('{"message":"cohere says no"}', Msg, Code);
  AssertEquals('cohere says no', Msg);
  ExtractError('plain text failure', Msg, Code);
  AssertEquals('plain text failure', Msg);
end;

procedure TErrorTest.JoinsURLs;
begin
  AssertEquals('https://x/v1/chat', JoinURL('https://x/v1', '/chat'));
  AssertEquals('https://x/v1/chat', JoinURL('https://x/v1/', 'chat'));
  AssertEquals('https://other/y', JoinURL('https://x/v1', 'https://other/y'));
end;

{ TCatalogTest }

procedure TCatalogTest.LooksUpExactNames;
var
  M: TModelInfo;
begin
  M := Lookup('claude-sonnet-4-5');
  AssertTrue('known', M.Known);
  AssertEquals(200000, M.ContextWindow);
  AssertEquals('anthropic', M.Provider);
end;

procedure TCatalogTest.StripsPrefixAndVersion;
begin
  AssertEquals('gemini-2.5-pro', NormaliseModelName('gemini-2.5-pro@default'));
  AssertEquals('claude-sonnet-4-5',
    NormaliseModelName('anthropic/claude-sonnet-4-5'));
  AssertEquals('gpt-4o', NormaliseModelName('openrouter/openai/gpt-4o'));
  AssertTrue(Lookup('openrouter/openai/gpt-4o').Known);
end;

procedure TCatalogTest.ResolvesDatedSnapshots;
var
  M: TModelInfo;
begin
  M := Lookup('claude-sonnet-4-5-20250929');
  AssertTrue('dated snapshot resolves by prefix', M.Known);
  AssertEquals('claude-sonnet-4-5', M.Name);
end;

procedure TCatalogTest.UnknownIsNotGuessed;
var
  M: TModelInfo;
  U: TUsage;
begin
  M := Lookup('some-private-finetune');
  AssertFalse(M.Known);
  AssertEquals(0, M.ContextWindow);
  U := Default(TUsage);
  U.InputTokens := 1000000;
  AssertEquals(0.0, M.Cost(U), 0.000001);
end;

procedure TCatalogTest.CostsUseCacheRates;
var
  M: TModelInfo;
  U: TUsage;
begin
  M := Lookup('claude-sonnet-4-5');
  U := Default(TUsage);
  U.InputTokens := 1000000;      { includes the cached and written tokens }
  U.CachedInputTokens := 500000;
  U.CacheWriteTokens := 100000;
  U.OutputTokens := 1000000;
  { 0.4M plain at 3.00 + 0.5M cached at 0.30 + 0.1M written at 3.75 + 1M out at 15 }
  AssertEquals(1.2 + 0.15 + 0.375 + 15.0, M.Cost(U), 0.0001);
end;

procedure TCatalogTest.RegisterOverrides;
var
  Info, Back: TModelInfo;
begin
  Info := Default(TModelInfo);
  Info.Name := 'my-finetune';
  Info.Provider := 'vllm';
  Info.ContextWindow := 32768;
  Info.InputCost := 1.0;
  RegisterModel(Info);
  Back := Lookup('vllm/my-finetune');
  AssertTrue(Back.Known);
  AssertEquals(32768, Back.ContextWindow);
end;

{ TCollectorTest }

procedure TCollectorTest.ReassemblesTextAndTools;
var
  C: TChunkCollector;
  Chunk: TLLMChunk;
  Resp: TLLMResponse;
  Calls: TPartList;
begin
  C := TChunkCollector.Create;
  try
    Chunk := Default(TLLMChunk);
    Chunk.Kind := ckText;
    Chunk.Text := 'Hel';
    C.OnChunk(Chunk);
    Chunk.Text := 'lo';
    C.OnChunk(Chunk);

    Chunk := Default(TLLMChunk);
    Chunk.Kind := ckToolCall;
    Chunk.Index := 0;
    Chunk.ToolCallID := 'call_1';
    Chunk.ToolName := 'weather';
    C.OnChunk(Chunk);
    Chunk := Default(TLLMChunk);
    Chunk.Kind := ckToolCall;
    Chunk.Index := 0;
    Chunk.ArgumentsDelta := '{"city":';
    C.OnChunk(Chunk);
    Chunk.ArgumentsDelta := '"Cape Town"}';
    C.OnChunk(Chunk);

    Chunk := Default(TLLMChunk);
    Chunk.Kind := ckFinish;
    Chunk.FinishReason := frToolCalls;
    Chunk.Usage.InputTokens := 12;
    Chunk.Usage.OutputTokens := 34;
    C.OnChunk(Chunk);

    Resp := C.BuildResponse('openai', 'gpt-5');
    try
      AssertEquals('Hello', Resp.Text);
      AssertEquals(12, Resp.Usage.InputTokens);
      AssertEquals(34, Resp.Usage.OutputTokens);
      AssertTrue(Resp.FinishReason = frToolCalls);
      Calls := Resp.ToolCalls;
      try
        AssertEquals(1, Calls.Count);
        AssertEquals('call_1', Calls[0].ID);
        AssertEquals('weather', Calls[0].Name);
        AssertEquals('{"city":"Cape Town"}', Calls[0].Arguments);
      finally
        Calls.Free;
      end;
    finally
      Resp.Free;
    end;
  finally
    C.Free;
  end;
end;

procedure TCollectorTest.KeepsReasoningSignature;
var
  C: TChunkCollector;
  Chunk: TLLMChunk;
  Resp: TLLMResponse;
begin
  C := TChunkCollector.Create;
  try
    Chunk := Default(TLLMChunk);
    Chunk.Kind := ckReasoning;
    Chunk.Text := 'step one ';
    C.OnChunk(Chunk);
    Chunk.Text := 'step two';
    C.OnChunk(Chunk);
    Chunk := Default(TLLMChunk);
    Chunk.Kind := ckReasoning;
    Chunk.Signature := 'sig-abc';
    C.OnChunk(Chunk);
    Resp := C.BuildResponse('anthropic', 'claude-sonnet-4-5');
    try
      AssertEquals('step one step two', Resp.ReasoningText);
      AssertEquals('sig-abc', Resp.Parts[0].Signature);
    finally
      Resp.Free;
    end;
  finally
    C.Free;
  end;
end;

initialization
  RegisterTest(TCoreTest);
  RegisterTest(TSinkTest);
  RegisterTest(TErrorTest);
  RegisterTest(TCatalogTest);
  RegisterTest(TCollectorTest);

end.
