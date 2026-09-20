{ End-to-end provider tests against an in-process fake vendor on 127.0.0.1.

  Each test asserts both halves of the contract: the JSON that went out on
  the wire and the response model that came back.
}
unit TestWire;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpcunit, testregistry, fpjson,
  LLMKit.Core, LLMKit.JSONUtil, LLMKit.Registry, LLMKit.Providers,
  LLMKit.Stream, TestSupport;

type
  TWireTestCase = class(TTestCase)
  protected
    FStopAfter: Integer;
    FChunks: TStringList;
    procedure SetUp; override;
    procedure TearDown; override;
    function Record_(const AChunk: TLLMChunk): Boolean;
    function Sent: TJSONData;
  end;

  TOpenAIWireTest = class(TWireTestCase)
  published
    procedure ChatSendsResponsesAPIShape;
    procedure ChatParsesTextToolsAndUsage;
    procedure StreamCollectsDeltas;
    procedure EmbeddingsUseTheEmbeddingsEndpoint;
  end;

  TAnthropicWireTest = class(TWireTestCase)
  published
    procedure ChatSendsMessagesAPIShape;
    procedure CachePlacesBreakpoints;
    procedure ThinkingReplacesTemperature;
    procedure UsageCountsCacheTokensAsInput;
    procedure CountTokensHitsTheFreeEndpoint;
    procedure StreamHandlesBlocksAndSignatures;
  end;

  TCompatWireTest = class(TWireTestCase)
  published
    procedure ChatCompletionsShape;
    procedure ToolCallsRoundTrip;
    procedure StreamStopsWhenAsked;
  end;

  TOllamaWireTest = class(TWireTestCase)
  published
    procedure ChatUsesApiChat;
    procedure StreamReadsNDJSON;
    procedure EmbedReadsEmbeddingsArray;
  end;

  TOtherProviderWireTest = class(TWireTestCase)
  published
    procedure CohereRerankSortsAndKeepsDocuments;
    procedure VoyageEmbedsWithInputType;
    procedure VertexBuildsContentsAndPath;
  end;

  TWireErrorTest = class(TWireTestCase)
  published
    procedure RateLimitBecomesTypedError;
    procedure ContextLengthIsDetected;
    procedure UnsupportedPartsNeverReachTheWire;
  end;

implementation

procedure TWireTestCase.SetUp;
begin
  FChunks := TStringList.Create;
  FStopAfter := -1;
  Vendor.Reset;
end;

procedure TWireTestCase.TearDown;
begin
  FChunks.Free;
end;

function TWireTestCase.Record_(const AChunk: TLLMChunk): Boolean;
begin
  case AChunk.Kind of
    ckText: FChunks.Add('text:' + AChunk.Text);
    ckReasoning: FChunks.Add('reasoning:' + AChunk.Text + AChunk.Signature);
    ckToolCall: FChunks.Add(Format('tool:%d:%s:%s:%s',
      [AChunk.Index, AChunk.ToolCallID, AChunk.ToolName, AChunk.ArgumentsDelta]));
    ckFinish: FChunks.Add(Format('finish:%s:%d/%d',
      [FinishReasonToString(AChunk.FinishReason), AChunk.Usage.InputTokens,
       AChunk.Usage.OutputTokens]));
  end;
  Result := (FStopAfter < 0) or (FChunks.Count < FStopAfter);
end;

function TWireTestCase.Sent: TJSONData;
begin
  Result := Vendor.BodyJSON;
end;

{ ---- OpenAI ---- }

procedure TOpenAIWireTest.ChatSendsResponsesAPIShape;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"id":"resp_1","model":"gpt-5","status":"completed",' +
    '"output":[{"type":"message","content":[{"type":"output_text",' +
    '"text":"hi"}]}]}');
  Chat := OpenChatter('gpt-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.SystemPrompt := 'be brief';
    Req.Add(UserText('hello'));
    Req.MaxTokens := OptInt(64);
    Req.AddTool('weather', 'current weather',
      '{"type":"object","properties":{"city":{"type":"string"}}}');
    Resp := Chat.Chat(Req);
    Resp.Free;
  finally
    Req.Free;
  end;
  AssertEquals('/responses', Vendor.Path);
  AssertEquals('POST', Vendor.Method);
  AssertEquals('Bearer test-key', Vendor.Header('authorization'));
  Body := Sent;
  try
    AssertEquals('gpt-5', JStr(Body, 'model'));
    AssertEquals('be brief', JStr(Body, 'instructions'));
    AssertEquals('user', JStr(Body, 'input.0.role'));
    AssertEquals('input_text', JStr(Body, 'input.0.content.0.type'));
    AssertEquals('hello', JStr(Body, 'input.0.content.0.text'));
    AssertEquals(64, JInt(Body, 'max_output_tokens'));
    AssertEquals('function', JStr(Body, 'tools.0.type'));
    AssertEquals('weather', JStr(Body, 'tools.0.name'));
    AssertEquals('string', JStr(Body, 'tools.0.parameters.properties.city.type'));
  finally
    Body.Free;
  end;
end;

procedure TOpenAIWireTest.ChatParsesTextToolsAndUsage;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Calls: TPartList;
begin
  Vendor.Reply('{"id":"resp_2","model":"gpt-5","status":"completed",' +
    '"output":[' +
    '{"type":"reasoning","summary":[{"type":"summary_text","text":"think"}]},' +
    '{"type":"message","content":[{"type":"output_text","text":"answer"}]},' +
    '{"type":"function_call","call_id":"call_9","name":"weather",' +
    '"arguments":"{\"city\":\"Cape Town\"}"}],' +
    '"usage":{"input_tokens":30,"output_tokens":12,' +
    '"input_tokens_details":{"cached_tokens":20},' +
    '"output_tokens_details":{"reasoning_tokens":5}}}');
  Chat := OpenChatter('gpt-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('hello'));
    Resp := Chat.Chat(Req);
    try
      AssertEquals('answer', Resp.Text);
      AssertEquals('think', Resp.ReasoningText);
      AssertEquals(30, Resp.Usage.InputTokens);
      AssertEquals(20, Resp.Usage.CachedInputTokens);
      AssertEquals(5, Resp.Usage.ReasoningTokens);
      AssertTrue(Resp.FinishReason = frToolCalls);
      Calls := Resp.ToolCalls;
      try
        AssertEquals(1, Calls.Count);
        AssertEquals('call_9', Calls[0].ID);
        AssertEquals('{"city":"Cape Town"}', Calls[0].Arguments);
      finally
        Calls.Free;
      end;
      AssertTrue('raw JSON is kept', Pos('resp_2', Resp.Raw) > 0);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure TOpenAIWireTest.StreamCollectsDeltas;
var
  Streamer: IStreamer;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.ReplyEvents([
    'event: response.output_text.delta',
    'data: {"type":"response.output_text.delta","delta":"Hel"}',
    '',
    'event: response.output_text.delta',
    'data: {"type":"response.output_text.delta","delta":"lo"}',
    '',
    'event: response.completed',
    'data: {"type":"response.completed","response":{"status":"completed",' +
      '"usage":{"input_tokens":7,"output_tokens":2}}}',
    '']);
  Streamer := OpenStreamer('gpt-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('hello'));
    Resp := Collect(Streamer, Req, @Record_);
    try
      AssertEquals('Hello', Resp.Text);
      AssertEquals(7, Resp.Usage.InputTokens);
      AssertEquals(2, Resp.Usage.OutputTokens);
      AssertTrue(Resp.FinishReason = frStop);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  AssertEquals(3, FChunks.Count);
  AssertEquals('text:Hel', FChunks[0]);
  AssertEquals('finish:stop:7/2', FChunks[2]);
  Body := Sent;
  try
    AssertTrue('stream flag', JBool(Body, 'stream'));
  finally
    Body.Free;
  end;
end;

procedure TOpenAIWireTest.EmbeddingsUseTheEmbeddingsEndpoint;
var
  Embedder: IEmbedder;
  Req: TEmbedRequest;
  Resp: TEmbedResponse;
begin
  Vendor.Reply('{"model":"text-embedding-3-small","data":[' +
    '{"index":1,"embedding":[0.5,0.25]},{"index":0,"embedding":[1,2]}],' +
    '"usage":{"prompt_tokens":4}}');
  Embedder := OpenEmbedder('text-embedding-3-small', VendorOptions);
  Req := TEmbedRequest.Create('text-embedding-3-small', ['a', 'b']);
  try
    Resp := Embedder.Embed(Req);
    try
      AssertEquals('/embeddings', Vendor.Path);
      AssertEquals(2, Resp.Count);
      AssertEquals(2, Resp.Dimensions);
      { results are placed by index, not arrival order }
      AssertEquals(1.0, Resp.Embeddings[0][0], 0.0001);
      AssertEquals(0.5, Resp.Embeddings[1][0], 0.0001);
      AssertEquals(4, Resp.Usage.InputTokens);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

{ ---- Anthropic ---- }

procedure TAnthropicWireTest.ChatSendsMessagesAPIShape;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"id":"msg_1","model":"claude-sonnet-4-5",' +
    '"content":[{"type":"text","text":"hi"}],"stop_reason":"end_turn"}');
  Chat := OpenChatter('claude-sonnet-4-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.SystemPrompt := 'be brief';
    Req.Add(UserText('hello'));
    Req.Temperature := OptFloat(0.3);
    Resp := Chat.Chat(Req);
    Resp.Free;
  finally
    Req.Free;
  end;
  AssertEquals('/messages', Vendor.Path);
  AssertEquals('test-key', Vendor.Header('x-api-key'));
  AssertEquals('2023-06-01', Vendor.Header('anthropic-version'));
  AssertEquals('', Vendor.Header('authorization'));
  Body := Sent;
  try
    AssertEquals('claude-sonnet-4-5', JStr(Body, 'model'));
    AssertEquals('be brief', JStr(Body, 'system'));
    AssertEquals(4096, JInt(Body, 'max_tokens'));
    AssertEquals('user', JStr(Body, 'messages.0.role'));
    AssertEquals('hello', JStr(Body, 'messages.0.content.0.text'));
    AssertEquals(0.3, JFloat(Body, 'temperature'), 0.0001);
  finally
    Body.Free;
  end;
end;

procedure TAnthropicWireTest.CachePlacesBreakpoints;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"id":"msg_2","content":[{"type":"text","text":"ok"}]}');
  Chat := OpenChatter('claude-sonnet-4-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.SystemPrompt := 'long standing instructions';
    Req.AddTool('weather', 'w', '{"type":"object"}');
    Req.Add(UserText('first'));
    Req.Add(AssistantText('answer'));
    Req.Add(UserText('second'));
    Req.Cache.Enabled := True;
    Req.Cache.System := True;
    Req.Cache.Tools := True;
    Req.Cache.Turns := 1;
    Req.Cache.TTL := '1h';
    Resp := Chat.Chat(Req);
    Resp.Free;
  finally
    Req.Free;
  end;
  Body := Sent;
  try
    AssertEquals('ephemeral', JStr(Body, 'system.0.cache_control.type'));
    AssertEquals('1h', JStr(Body, 'system.0.cache_control.ttl'));
    AssertEquals('ephemeral', JStr(Body, 'tools.0.cache_control.type'));
    { the last user turn carries the moving breakpoint, the first does not }
    AssertEquals('ephemeral',
      JStr(Body, 'messages.2.content.0.cache_control.type'));
    AssertFalse(JHas(Body, 'messages.0.content.0.cache_control'));
  finally
    Body.Free;
  end;
end;

procedure TAnthropicWireTest.ThinkingReplacesTemperature;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"id":"msg_3","content":[{"type":"text","text":"ok"}]}');
  Chat := OpenChatter('claude-sonnet-4-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('hard question'));
    Req.Temperature := OptFloat(0.7);
    Req.Reasoning.Enabled := True;
    Req.Reasoning.Effort := 'high';
    Req.Reasoning.Summary := 'auto';
    Resp := Chat.Chat(Req);
    Resp.Free;
  finally
    Req.Free;
  end;
  Body := Sent;
  try
    AssertEquals(16384, JInt(Body, 'max_tokens'));
    AssertEquals('enabled', JStr(Body, 'thinking.type'));
    AssertTrue('budget below max_tokens',
      JInt(Body, 'thinking.budget_tokens') < JInt(Body, 'max_tokens'));
    { OpenAI's "auto" is translated to Anthropic's word }
    AssertEquals('summarized', JStr(Body, 'thinking.display'));
    AssertFalse('temperature is rejected alongside thinking',
      JHas(Body, 'temperature'));
  finally
    Body.Free;
  end;
end;

procedure TAnthropicWireTest.UsageCountsCacheTokensAsInput;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Vendor.Reply('{"id":"msg_4","model":"claude-sonnet-4-5",' +
    '"content":[{"type":"thinking","thinking":"hmm","signature":"sig1"},' +
    '{"type":"text","text":"done"},' +
    '{"type":"tool_use","id":"toolu_1","name":"weather",' +
    '"input":{"city":"Cape Town"}}],' +
    '"stop_reason":"tool_use",' +
    '"usage":{"input_tokens":10,"output_tokens":4,' +
    '"cache_read_input_tokens":100,"cache_creation_input_tokens":50}}');
  Chat := OpenChatter('claude-sonnet-4-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('hello'));
    Resp := Chat.Chat(Req);
    try
      AssertEquals(160, Resp.Usage.InputTokens); { 10 + 100 + 50 }
      AssertEquals(100, Resp.Usage.CachedInputTokens);
      AssertEquals(50, Resp.Usage.CacheWriteTokens);
      AssertEquals('done', Resp.Text);
      AssertEquals('sig1', Resp.Parts[0].Signature);
      AssertTrue(Resp.FinishReason = frToolCalls);
      AssertEquals('{"city":"Cape Town"}', Resp.Parts[2].Arguments);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure TAnthropicWireTest.CountTokensHitsTheFreeEndpoint;
var
  Counter: ITokenCounter;
  Req: TLLMRequest;
  Body: TJSONData;
  N: Integer;
begin
  Vendor.Reply('{"input_tokens":2095}');
  Counter := OpenTokenCounter('claude-opus-4-1', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('how many tokens is this?'));
    N := Counter.CountTokens(Req);
  finally
    Req.Free;
  end;
  AssertEquals(2095, N);
  AssertEquals('/messages/count_tokens', Vendor.Path);
  Body := Sent;
  try
    AssertFalse('max_tokens is not allowed here', JHas(Body, 'max_tokens'));
  finally
    Body.Free;
  end;
end;

procedure TAnthropicWireTest.StreamHandlesBlocksAndSignatures;
var
  Streamer: IStreamer;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Calls: TPartList;
begin
  Vendor.ReplyEvents([
    'event: message_start',
    'data: {"type":"message_start","message":{"usage":{"input_tokens":25,' +
      '"cache_read_input_tokens":5}}}',
    '',
    'event: content_block_start',
    'data: {"type":"content_block_start","index":0,' +
      '"content_block":{"type":"thinking"}}',
    '',
    'event: content_block_delta',
    'data: {"type":"content_block_delta","index":0,' +
      '"delta":{"type":"thinking_delta","thinking":"weighing"}}',
    '',
    'event: content_block_delta',
    'data: {"type":"content_block_delta","index":0,' +
      '"delta":{"type":"signature_delta","signature":"sig-xyz"}}',
    '',
    'event: content_block_start',
    'data: {"type":"content_block_start","index":1,' +
      '"content_block":{"type":"tool_use","id":"toolu_7","name":"weather"}}',
    '',
    'event: content_block_delta',
    'data: {"type":"content_block_delta","index":1,' +
      '"delta":{"type":"input_json_delta","partial_json":"{\"city\":\"CPT\"}"}}',
    '',
    'event: message_delta',
    'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},' +
      '"usage":{"output_tokens":42}}',
    '']);
  Streamer := OpenStreamer('claude-sonnet-4-5', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('weather?'));
    Resp := Collect(Streamer, Req, @Record_);
    try
      AssertEquals('weighing', Resp.ReasoningText);
      AssertEquals('sig-xyz', Resp.Parts[0].Signature);
      AssertEquals(30, Resp.Usage.InputTokens); { 25 + 5 cached }
      AssertEquals(42, Resp.Usage.OutputTokens);
      AssertTrue(Resp.FinishReason = frToolCalls);
      Calls := Resp.ToolCalls;
      try
        AssertEquals(1, Calls.Count);
        AssertEquals('toolu_7', Calls[0].ID);
        AssertEquals('weather', Calls[0].Name);
        AssertEquals('{"city":"CPT"}', Calls[0].Arguments);
      finally
        Calls.Free;
      end;
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

{ ---- OpenAI-compatible providers ---- }

procedure TCompatWireTest.ChatCompletionsShape;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"id":"c1","model":"llama-3.3-70b-versatile",' +
    '"choices":[{"finish_reason":"stop","message":{"role":"assistant",' +
    '"content":"hello there"}}],' +
    '"usage":{"prompt_tokens":8,"completion_tokens":3,' +
    '"prompt_tokens_details":{"cached_tokens":4}}}');
  Chat := OpenChatter('groq/llama-3.3-70b-versatile', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.SystemPrompt := 'be brief';
    Req.Add(UserText('hi'));
    Req.Stop := TStringArray.Create('END');
    Resp := Chat.Chat(Req);
    try
      AssertEquals('hello there', Resp.Text);
      AssertEquals(8, Resp.Usage.InputTokens);
      AssertEquals(4, Resp.Usage.CachedInputTokens);
      AssertTrue(Resp.FinishReason = frStop);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  AssertEquals('/chat/completions', Vendor.Path);
  Body := Sent;
  try
    AssertEquals('llama-3.3-70b-versatile', JStr(Body, 'model'));
    AssertEquals('system', JStr(Body, 'messages.0.role'));
    AssertEquals('be brief', JStr(Body, 'messages.0.content'));
    AssertEquals('hi', JStr(Body, 'messages.1.content'));
    AssertEquals('END', JStr(Body, 'stop.0'));
  finally
    Body.Free;
  end;
end;

procedure TCompatWireTest.ToolCallsRoundTrip;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"id":"c2","choices":[{"finish_reason":"tool_calls",' +
    '"message":{"role":"assistant","content":null,"tool_calls":[' +
    '{"id":"call_1","type":"function","function":{"name":"weather",' +
    '"arguments":"{\"city\":\"CPT\"}"}}]}}]}');
  Chat := OpenChatter('deepseek-chat', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.AddTool('weather', 'w', '{"type":"object"}');
    Req.ToolChoice := 'auto';
    Req.Add(UserText('weather?'));
    Resp := Chat.Chat(Req);
    try
      AssertTrue(Resp.HasToolCalls);
      { feed the tool result back and check the next request's shape }
      Req.Add(Resp.ToMessage);
      Req.Add(ToolMessage('call_1', 'weather', '20C and clear'));
    finally
      Resp.Free;
    end;
    Vendor.Reply('{"id":"c3","choices":[{"finish_reason":"stop",' +
      '"message":{"content":"It is 20C."}}]}');
    Resp := Chat.Chat(Req);
    try
      AssertEquals('It is 20C.', Resp.Text);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  Body := Sent;
  try
    AssertEquals('auto', JStr(Body, 'tool_choice'));
    AssertEquals('assistant', JStr(Body, 'messages.1.role'));
    AssertEquals('call_1', JStr(Body, 'messages.1.tool_calls.0.id'));
    AssertEquals('weather',
      JStr(Body, 'messages.1.tool_calls.0.function.name'));
    AssertEquals('tool', JStr(Body, 'messages.2.role'));
    AssertEquals('call_1', JStr(Body, 'messages.2.tool_call_id'));
    AssertEquals('20C and clear', JStr(Body, 'messages.2.content'));
  finally
    Body.Free;
  end;
end;

procedure TCompatWireTest.StreamStopsWhenAsked;
var
  Streamer: IStreamer;
  Req: TLLMRequest;
  Finished: Boolean;
begin
  Vendor.ReplyEvents([
    'data: {"choices":[{"delta":{"content":"one"}}]}',
    '',
    'data: {"choices":[{"delta":{"content":"two"}}]}',
    '',
    'data: {"choices":[{"delta":{"content":"three"}}]}',
    '',
    'data: [DONE]',
    '']);
  FStopAfter := 2;
  Streamer := OpenStreamer('groq/llama-3.3-70b-versatile', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('count'));
    Finished := Streamer.Stream(Req, @Record_);
  finally
    Req.Free;
  end;
  AssertFalse('Stream reports that the sink stopped it', Finished);
  AssertEquals(2, FChunks.Count);
  AssertEquals('text:two', FChunks[1]);
end;

{ ---- Ollama ---- }

procedure TOllamaWireTest.ChatUsesApiChat;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"model":"llama3.2:3b","message":{"role":"assistant",' +
    '"content":"local hello"},"done":true,"done_reason":"stop",' +
    '"prompt_eval_count":11,"eval_count":6}');
  Chat := OpenChatter('llama3.2:3b', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('hi'));
    Req.Temperature := OptFloat(0.1);
    Req.MaxTokens := OptInt(50);
    Resp := Chat.Chat(Req);
    try
      AssertEquals('local hello', Resp.Text);
      AssertEquals(11, Resp.Usage.InputTokens);
      AssertEquals(6, Resp.Usage.OutputTokens);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  AssertEquals('/api/chat', Vendor.Path);
  Body := Sent;
  try
    AssertEquals('llama3.2:3b', JStr(Body, 'model'));
    AssertFalse(JBool(Body, 'stream'));
    AssertEquals(0.1, JFloat(Body, 'options.temperature'), 0.0001);
    AssertEquals(50, JInt(Body, 'options.num_predict'));
  finally
    Body.Free;
  end;
end;

procedure TOllamaWireTest.StreamReadsNDJSON;
var
  Streamer: IStreamer;
  Req: TLLMRequest;
  Resp: TLLMResponse;
begin
  Vendor.ReplyLines([
    '{"message":{"content":"par"},"done":false}',
    '{"message":{"content":"tial"},"done":false}',
    '{"message":{"content":""},"done":true,"done_reason":"stop",' +
      '"prompt_eval_count":3,"eval_count":9}']);
  Streamer := OpenStreamer('llama3.2:3b', VendorOptions);
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('hi'));
    Resp := Collect(Streamer, Req, @Record_);
    try
      AssertEquals('partial', Resp.Text);
      AssertEquals(3, Resp.Usage.InputTokens);
      AssertEquals(9, Resp.Usage.OutputTokens);
      AssertTrue(Resp.FinishReason = frStop);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  AssertEquals(3, FChunks.Count);
end;

procedure TOllamaWireTest.EmbedReadsEmbeddingsArray;
var
  Embedder: IEmbedder;
  Req: TEmbedRequest;
  Resp: TEmbedResponse;
begin
  Vendor.Reply('{"model":"nomic-embed-text","embeddings":[[0.1,0.2,0.3]],' +
    '"prompt_eval_count":5}');
  Embedder := OpenEmbedder('nomic-embed-text:latest', VendorOptions);
  Req := TEmbedRequest.Create('nomic-embed-text:latest', ['text']);
  try
    Resp := Embedder.Embed(Req);
    try
      AssertEquals('/api/embed', Vendor.Path);
      AssertEquals(1, Resp.Count);
      AssertEquals(3, Resp.Dimensions);
      AssertEquals(5, Resp.Usage.InputTokens);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

{ ---- Cohere, Voyage, Vertex ---- }

procedure TOtherProviderWireTest.CohereRerankSortsAndKeepsDocuments;
var
  Reranker: IReranker;
  Req: TRerankRequest;
  Resp: TRerankResponse;
begin
  Vendor.Reply('{"results":[{"index":2,"relevance_score":0.91},' +
    '{"index":0,"relevance_score":0.42}],' +
    '"meta":{"billed_units":{"input_tokens":17}}}');
  Reranker := OpenReranker('rerank-v3.5', VendorOptions);
  Req := TRerankRequest.Create('rerank-v3.5', 'go iterators',
    ['unrelated', 'also unrelated', 'iterators in go']);
  Req.TopN := OptInt(2);
  try
    Resp := Reranker.Rerank(Req);
    try
      AssertEquals('/rerank', Vendor.Path);
      AssertEquals(2, Resp.Count);
      AssertEquals(2, Resp.Results[0].Index);
      AssertEquals('iterators in go', Resp.Results[0].Document);
      AssertEquals(0.91, Resp.Results[0].Score, 0.0001);
      AssertEquals(17, Resp.Usage.InputTokens);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure TOtherProviderWireTest.VoyageEmbedsWithInputType;
var
  Embedder: IEmbedder;
  Req: TEmbedRequest;
  Resp: TEmbedResponse;
  Body: TJSONData;
begin
  Vendor.Reply('{"model":"voyage-3-large","data":[' +
    '{"index":0,"embedding":[0.1,0.2]},{"index":1,"embedding":[0.3,0.4]}],' +
    '"usage":{"total_tokens":6}}');
  Embedder := OpenEmbedder('voyage-3-large', VendorOptions);
  Req := TEmbedRequest.Create('voyage-3-large', ['first', 'second']);
  Req.InputType := eiDocument;
  try
    Resp := Embedder.Embed(Req);
    try
      AssertEquals('/embeddings', Vendor.Path);
      AssertEquals(2, Resp.Count);
      AssertEquals(6, Resp.Usage.InputTokens);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  Body := Sent;
  try
    AssertEquals('document', JStr(Body, 'input_type'));
    AssertEquals('second', JStr(Body, 'input.1'));
  finally
    Body.Free;
  end;
end;

procedure TOtherProviderWireTest.VertexBuildsContentsAndPath;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Opts: TClientOptions;
  Body: TJSONData;
begin
  Vendor.Reply('{"modelVersion":"gemini-2.5-flash","candidates":[{' +
    '"content":{"role":"model","parts":[{"text":"salut"}]},' +
    '"finishReason":"STOP"}],' +
    '"usageMetadata":{"promptTokenCount":9,"candidatesTokenCount":3,' +
    '"thoughtsTokenCount":2}}');
  Opts := VendorOptions.WithProject('my-project').WithLocation('europe-west1');
  Chat := OpenChatter('gemini-2.5-flash', Opts);
  Req := TLLMRequest.Create;
  try
    Req.SystemPrompt := 'be brief';
    Req.Add(UserText('bonjour'));
    Resp := Chat.Chat(Req);
    try
      AssertEquals('salut', Resp.Text);
      AssertEquals(9, Resp.Usage.InputTokens);
      AssertEquals(5, Resp.Usage.OutputTokens); { 3 + 2 thinking }
      AssertEquals(2, Resp.Usage.ReasoningTokens);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
  { the ':' is percent-encoded so FPC's URI parser leaves the path alone }
  AssertEquals('/projects/my-project/locations/europe-west1/publishers/' +
    'google/models/gemini-2.5-flash%3AgenerateContent', Vendor.Path);
  Body := Sent;
  try
    AssertEquals('user', JStr(Body, 'contents.0.role'));
    AssertEquals('bonjour', JStr(Body, 'contents.0.parts.0.text'));
    AssertEquals('be brief', JStr(Body, 'systemInstruction.parts.0.text'));
  finally
    Body.Free;
  end;
end;

{ ---- errors ---- }

procedure TWireErrorTest.RateLimitBecomesTypedError;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Caught: EAPIError;
begin
  Vendor.Reply('{"error":{"message":"Rate limit reached","type":"rate_limit_error"}}',
    429);
  Chat := OpenChatter('gpt-5', VendorOptions);
  Req := TLLMRequest.Create;
  Caught := nil;
  try
    Req.Add(UserText('hi'));
    try
      Chat.Chat(Req).Free;
    except
      on E: EAPIError do
        Caught := EAPIError(Exception(AcquireExceptionObject));
    end;
    AssertTrue('an EAPIError is raised', Caught <> nil);
    AssertEquals(429, Caught.StatusCode);
    AssertEquals('openai', Caught.Provider);
    AssertEquals('rate_limit_error', Caught.Code);
    AssertTrue(IsRateLimited(Caught));
    AssertTrue(Caught.IsRetryable);
    AssertTrue('the raw body is kept', Pos('Rate limit', Caught.Raw) > 0);
  finally
    Caught.Free;
    Req.Free;
  end;
end;

procedure TWireErrorTest.ContextLengthIsDetected;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Detected: Boolean;
begin
  Vendor.Reply('{"error":{"message":"prompt is too long: 250000 tokens > ' +
    '200000 maximum","type":"invalid_request_error"}}', 400);
  Chat := OpenChatter('claude-sonnet-4-5', VendorOptions);
  Req := TLLMRequest.Create;
  Detected := False;
  try
    Req.Add(UserText('...'));
    try
      Chat.Chat(Req).Free;
    except
      on E: EAPIError do
        Detected := IsContextLength(E);
    end;
  finally
    Req.Free;
  end;
  AssertTrue('context length is recognised across vendors', Detected);
end;

procedure TWireErrorTest.UnsupportedPartsNeverReachTheWire;
var
  Chat: IChatter;
  Req: TLLMRequest;
  Raised: Boolean;
  Data: TBytes;
begin
  Vendor.Reply('{"should":"not be used"}');
  Chat := OpenChatter('deepseek-chat', VendorOptions);
  Req := TLLMRequest.Create;
  Raised := False;
  try
    Data := StringToBytes('not really a png');
    Req.Add(UserMessage([TextPart('what is this?'), ImagePart(Data, 'image/png')]));
    try
      Chat.Chat(Req).Free;
    except
      on E: ELLMUnsupported do
        Raised := True;
    end;
  finally
    Req.Free;
  end;
  AssertTrue('image parts are rejected up front', Raised);
  AssertEquals('nothing was sent', '', Vendor.Body);
end;

initialization
  RegisterTest(TOpenAIWireTest);
  RegisterTest(TAnthropicWireTest);
  RegisterTest(TCompatWireTest);
  RegisterTest(TOllamaWireTest);
  RegisterTest(TOtherProviderWireTest);
  RegisterTest(TWireErrorTest);

end.
