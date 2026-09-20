{ LLMKit.Provider.Anthropic - the Messages API (/v1/messages).

  Chat, streaming, tools, images, PDFs, extended thinking with replayable
  signatures, explicit prompt-cache breakpoints and the free token counting
  endpoint. Key: ANTHROPIC_API_KEY.

  Usage note: Anthropic reports cache reads and writes outside input_tokens;
  llmkit's contract is that InputTokens is the whole prompt, so they are added
  back in and also reported separately.
}
unit LLMKit.Provider.Anthropic;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client, LLMKit.Provider.OpenAICompat;

const
  AnthropicDefaultBaseURL = 'https://api.anthropic.com/v1';
  AnthropicVersion = '2023-06-01';
  AnthropicDefaultMaxTokens = 4096;
  { Thinking counts against max_tokens, so the default is raised. }
  AnthropicThinkingMaxTokens = 16384;
  AnthropicMaxCacheBreakpoints = 4;

type
  TAnthropicClient = class(TLLMClientBase, IChatter, IStreamer, ITokenCounter)
  private
    FOnChunk: TChunkEvent;
    FBlockKinds: array of string;
    FToolIDs: array of string;
    function BuildBody(ARequest: TLLMRequest; AStream: Boolean): TJSONObject;
    function BuildMessages(ARequest: TLLMRequest): TJSONArray;
    function BuildSystem(ARequest: TLLMRequest): TJSONData;
    function BuildTools(ARequest: TLLMRequest): TJSONArray;
    function BlockKind(AIndex: Integer): string;
    procedure SetBlock(AIndex: Integer; const AKind, AToolID: string);
    function HandleEvent(const AEvent: TSSEEvent): Boolean;
  public
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
    function CountTokens(ARequest: TLLMRequest): Integer;
  end;

  TAnthropicProvider = class(TLLMProvider)
  public
    function ID: string; override;
    function Aliases: TStringArray; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
  end;

function ParseAnthropicResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
function ParseAnthropicUsage(AJSON: TJSONData): TUsage;
{ Number of trailing user turns that should carry a cache breakpoint. }
function CacheTurnIndexes(ARequest: TLLMRequest; ATurns: Integer): TStringArray;

implementation

function ParseAnthropicUsage(AJSON: TJSONData): TUsage;
var
  U: TJSONData;
begin
  Result := Default(TUsage);
  U := JGet(AJSON, 'usage');
  if U = nil then
    Exit;
  Result.CachedInputTokens := JInt(U, 'cache_read_input_tokens');
  Result.CacheWriteTokens := JInt(U, 'cache_creation_input_tokens');
  Result.InputTokens := JInt(U, 'input_tokens') + Result.CachedInputTokens +
    Result.CacheWriteTokens;
  Result.OutputTokens := JInt(U, 'output_tokens');
end;

function ParseAnthropicResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
var
  Content: TJSONArray;
  Item, Input: TJSONData;
  I: Integer;
  Kind: string;
  Part: TLLMPart;
begin
  Result := TLLMResponse.Create;
  try
    Result.Provider := 'anthropic';
    Result.Raw := ARaw;
    Result.ID := JStr(AJSON, 'id');
    Result.Model := JStr(AJSON, 'model');
    Result.Usage := ParseAnthropicUsage(AJSON);
    Result.FinishReason := ParseFinishReason(JStr(AJSON, 'stop_reason'));
    Content := JArray(AJSON, 'content');
    if Content = nil then
      Exit;
    for I := 0 to Content.Count - 1 do
    begin
      Item := Content.Items[I];
      Kind := JStr(Item, 'type');
      if Kind = 'text' then
        Result.Add(TextPart(JStr(Item, 'text')))
      else if Kind = 'thinking' then
        Result.Add(ReasoningPart(JStr(Item, 'thinking'), JStr(Item, 'signature')))
      else if Kind = 'redacted_thinking' then
      begin
        Part := ReasoningPart('', JStr(Item, 'data'));
        Part.Redacted := True;
        Result.Add(Part);
      end
      else if Kind = 'tool_use' then
      begin
        Input := JGet(Item, 'input');
        if Input <> nil then
          Result.Add(ToolCallPart(JStr(Item, 'id'), JStr(Item, 'name'),
            CompactJSON(Input)))
        else
          Result.Add(ToolCallPart(JStr(Item, 'id'), JStr(Item, 'name'), '{}'));
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

function CacheTurnIndexes(ARequest: TLLMRequest; ATurns: Integer): TStringArray;
var
  I, Found: Integer;
begin
  Result := nil;
  if ATurns <= 0 then
    Exit;
  Found := 0;
  for I := ARequest.Messages.Count - 1 downto 0 do
  begin
    if ARequest.Messages[I].Role <> lrUser then
      Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := IntToStr(I);
    Inc(Found);
    if Found >= ATurns then
      Break;
  end;
end;

function CacheControl: TJSONObject;
begin
  Result := TJSONObject.Create(['type', 'ephemeral']);
end;

function CacheControlTTL(const ATTL: string): TJSONObject;
begin
  Result := CacheControl;
  if (ATTL <> '') and (ATTL <> '5m') then
    Result.Add('ttl', ATTL);
end;

{ TAnthropicClient }

function TAnthropicClient.BuildSystem(ARequest: TLLMRequest): TJSONData;
var
  Block: TJSONObject;
  Arr: TJSONArray;
begin
  if ARequest.SystemPrompt = '' then
    Exit(nil);
  if not (ARequest.Cache.Enabled and ARequest.Cache.System) then
    Exit(TJSONString.Create(ARequest.SystemPrompt));
  Block := TJSONObject.Create(['type', 'text', 'text', ARequest.SystemPrompt]);
  Block.Add('cache_control', CacheControlTTL(ARequest.Cache.TTL));
  Arr := TJSONArray.Create;
  Arr.Add(Block);
  Result := Arr;
end;

function TAnthropicClient.BuildTools(ARequest: TLLMRequest): TJSONArray;
var
  I: Integer;
  Obj: TJSONObject;
  Tool: TLLMTool;
begin
  Result := TJSONArray.Create;
  for I := 0 to ARequest.Tools.Count - 1 do
  begin
    Tool := ARequest.Tools[I];
    Obj := TJSONObject.Create(['name', Tool.Name]);
    JSetStr(Obj, 'description', Tool.Description);
    if Tool.Parameters <> '' then
      JSetRaw(Obj, 'input_schema', Tool.Parameters)
    else
      Obj.Add('input_schema', TJSONObject.Create(['type', 'object',
        'properties', TJSONObject.Create]));
    { One breakpoint after the whole tool block, which is the stable prefix. }
    if ARequest.Cache.Enabled and ARequest.Cache.Tools and
       (I = ARequest.Tools.Count - 1) then
      Obj.Add('cache_control', CacheControlTTL(ARequest.Cache.TTL));
    Result.Add(Obj);
  end;
end;

function TAnthropicClient.BuildMessages(ARequest: TLLMRequest): TJSONArray;
var
  I, J, Budget: Integer;
  Msg: TLLMMessage;
  Part: TLLMPart;
  Content: TJSONArray;
  Obj, Source: TJSONObject;
  Marks: TStringArray;

  function Marked(AIndex: Integer): Boolean;
  var
    K: Integer;
  begin
    for K := 0 to High(Marks) do
      if Marks[K] = IntToStr(AIndex) then
        Exit(True);
    Result := False;
  end;

begin
  Result := TJSONArray.Create;
  Marks := nil;
  Budget := AnthropicMaxCacheBreakpoints;
  if ARequest.Cache.Enabled then
  begin
    if ARequest.Cache.System and (ARequest.SystemPrompt <> '') then
      Dec(Budget);
    if ARequest.Cache.Tools and (ARequest.Tools.Count > 0) then
      Dec(Budget);
    if Budget > 0 then
      Marks := CacheTurnIndexes(ARequest, Min(ARequest.Cache.Turns, Budget));
  end;

  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    if Msg.Role = lrSystem then
      Continue; { carried by the system field }
    Content := TJSONArray.Create;
    for J := 0 to Msg.Parts.Count - 1 do
    begin
      Part := Msg.Parts[J];
      case Part.Kind of
        pkText:
          Content.Add(TJSONObject.Create(['type', 'text', 'text', Part.Text]));
        pkReasoning:
          if Part.Redacted then
            Content.Add(TJSONObject.Create(['type', 'redacted_thinking',
              'data', Part.Signature]))
          else
            Content.Add(TJSONObject.Create(['type', 'thinking',
              'thinking', Part.Text, 'signature', Part.Signature]));
        pkImage:
          begin
            if Part.URL <> '' then
              Source := TJSONObject.Create(['type', 'url', 'url', Part.URL])
            else
              Source := TJSONObject.Create([
                'type', 'base64',
                'media_type', Part.MimeType,
                'data', Base64FromBytes(Part.Data)]);
            Content.Add(TJSONObject.Create(['type', 'image', 'source', Source]));
          end;
        pkFile:
          begin
            if Part.URL <> '' then
              Source := TJSONObject.Create(['type', 'url', 'url', Part.URL])
            else
              Source := TJSONObject.Create([
                'type', 'base64',
                'media_type', Part.MimeType,
                'data', Base64FromBytes(Part.Data)]);
            Obj := TJSONObject.Create(['type', 'document', 'source', Source]);
            JSetStr(Obj, 'title', Part.Filename);
            Content.Add(Obj);
          end;
        pkToolCall:
          begin
            Obj := TJSONObject.Create(['type', 'tool_use', 'id', Part.ID,
              'name', Part.Name]);
            if Part.Arguments <> '' then
              JSetRaw(Obj, 'input', Part.Arguments)
            else
              Obj.Add('input', TJSONObject.Create);
            Content.Add(Obj);
          end;
        pkToolResult:
          begin
            Obj := TJSONObject.Create(['type', 'tool_result',
              'tool_use_id', Part.ID, 'content', Part.Text]);
            if Part.IsError then
              Obj.Add('is_error', True);
            Content.Add(Obj);
          end;
      end;
    end;
    if Content.Count = 0 then
    begin
      Content.Free;
      Continue;
    end;
    if (Marked(I) or Msg.CacheHint) and (Content.Items[Content.Count - 1].JSONType = jtObject) then
      TJSONObject(Content.Items[Content.Count - 1]).Add('cache_control',
        CacheControlTTL(ARequest.Cache.TTL));
    if Msg.Role = lrAssistant then
      Result.Add(TJSONObject.Create(['role', 'assistant', 'content', Content]))
    else
      { tool results travel as a user turn on Anthropic }
      Result.Add(TJSONObject.Create(['role', 'user', 'content', Content]));
  end;
end;

function TAnthropicClient.BuildBody(ARequest: TLLMRequest;
  AStream: Boolean): TJSONObject;
var
  Thinking: TJSONObject;
  SystemNode: TJSONData;
  MaxTokens, Budget: Integer;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('model', FModel);
    Result.Add('messages', BuildMessages(ARequest));
    SystemNode := BuildSystem(ARequest);
    if SystemNode <> nil then
      Result.Add('system', SystemNode);
    if ARequest.MaxTokens.HasValue then
      MaxTokens := ARequest.MaxTokens.Value
    else if ARequest.Reasoning.Enabled then
      MaxTokens := AnthropicThinkingMaxTokens
    else
      MaxTokens := AnthropicDefaultMaxTokens;
    Result.Add('max_tokens', MaxTokens);
    if ARequest.Tools.Count > 0 then
    begin
      Result.Add('tools', BuildTools(ARequest));
      if ARequest.ToolChoice = 'auto' then
        Result.Add('tool_choice', TJSONObject.Create(['type', 'auto']))
      else if ARequest.ToolChoice = 'required' then
        Result.Add('tool_choice', TJSONObject.Create(['type', 'any']))
      else if ARequest.ToolChoice = 'none' then
        Result.Add('tool_choice', TJSONObject.Create(['type', 'none']))
      else if ARequest.ToolChoice <> '' then
        Result.Add('tool_choice', TJSONObject.Create(['type', 'tool',
          'name', ARequest.ToolChoice]));
    end;
    if ARequest.Reasoning.Enabled then
    begin
      Budget := ARequest.Reasoning.BudgetTokens;
      if Budget <= 0 then
      begin
        if ARequest.Reasoning.Effort = 'low' then
          Budget := 2048
        else if ARequest.Reasoning.Effort = 'high' then
          Budget := MaxTokens - (MaxTokens div 4)
        else
          Budget := MaxTokens div 2;
      end;
      if Budget >= MaxTokens then
        Budget := MaxTokens - 1024;
      if Budget < 1024 then
        Budget := 1024;
      Thinking := TJSONObject.Create(['type', 'enabled',
        'budget_tokens', Budget]);
      { OpenAI's summary words mean "show me a summary" here too. }
      if (ARequest.Reasoning.Summary = 'auto') or
         (ARequest.Reasoning.Summary = 'concise') or
         (ARequest.Reasoning.Summary = 'detailed') or
         (ARequest.Reasoning.Summary = 'summarized') then
        Thinking.Add('display', 'summarized')
      else
        JSetStr(Thinking, 'display', ARequest.Reasoning.Summary);
      Result.Add('thinking', Thinking);
    end
    else
    begin
      { Anthropic rejects temperature together with thinking. }
      JSetOpt(Result, 'temperature', ARequest.Temperature);
      JSetOpt(Result, 'top_p', ARequest.TopP);
    end;
    if Length(ARequest.Stop) > 0 then
      Result.Add('stop_sequences', JStrings(ARequest.Stop));
    if AStream then
      Result.Add('stream', True);
    ApplyExtras(Result, ARequest, 'anthropic');
  except
    Result.Free;
    raise;
  end;
end;

function TAnthropicClient.Chat(ARequest: TLLMRequest): TLLMResponse;
var
  Body: TJSONObject;
  Text: string;
  Data: TJSONData;
begin
  Need(capChat, 'chat');
  CheckParts(ARequest);
  CheckTools(ARequest);
  Body := BuildBody(ARequest, False);
  try
    Text := FTransport.PostJSONText('/messages', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := ParseAnthropicResponse(Data, Text);
  finally
    Data.Free;
  end;
end;

function TAnthropicClient.BlockKind(AIndex: Integer): string;
begin
  if (AIndex >= 0) and (AIndex <= High(FBlockKinds)) then
    Result := FBlockKinds[AIndex]
  else
    Result := '';
end;

procedure TAnthropicClient.SetBlock(AIndex: Integer; const AKind, AToolID: string);
begin
  if AIndex < 0 then
    Exit;
  if AIndex > High(FBlockKinds) then
  begin
    SetLength(FBlockKinds, AIndex + 1);
    SetLength(FToolIDs, AIndex + 1);
  end;
  FBlockKinds[AIndex] := AKind;
  FToolIDs[AIndex] := AToolID;
end;

function TAnthropicClient.HandleEvent(const AEvent: TSSEEvent): Boolean;
var
  Data: TJSONData;
  Chunk: TLLMChunk;
  EventType, DeltaType, Kind: string;
  Index: Integer;
begin
  Result := True;
  if AEvent.Data = '' then
    Exit;
  Data := TryParseJSON(AEvent.Data);
  if Data = nil then
    Exit;
  try
    EventType := AEvent.EventName;
    if EventType = '' then
      EventType := JStr(Data, 'type');
    Index := JInt(Data, 'index', 0);
    Chunk := Default(TLLMChunk);
    Chunk.Raw := AEvent.Data;
    Chunk.Index := Index;

    if EventType = 'content_block_start' then
    begin
      Kind := JStr(Data, 'content_block.type');
      SetBlock(Index, Kind, JStr(Data, 'content_block.id'));
      if Kind = 'tool_use' then
      begin
        Chunk.Kind := ckToolCall;
        Chunk.ToolCallID := JStr(Data, 'content_block.id');
        Chunk.ToolName := JStr(Data, 'content_block.name');
        Result := FOnChunk(Chunk);
      end;
    end
    else if EventType = 'content_block_delta' then
    begin
      DeltaType := JStr(Data, 'delta.type');
      if DeltaType = 'text_delta' then
      begin
        Chunk.Kind := ckText;
        Chunk.Text := JStr(Data, 'delta.text');
        Result := FOnChunk(Chunk);
      end
      else if DeltaType = 'thinking_delta' then
      begin
        Chunk.Kind := ckReasoning;
        Chunk.Text := JStr(Data, 'delta.thinking');
        Result := FOnChunk(Chunk);
      end
      else if DeltaType = 'signature_delta' then
      begin
        Chunk.Kind := ckReasoning;
        Chunk.Signature := JStr(Data, 'delta.signature');
        Result := FOnChunk(Chunk);
      end
      else if DeltaType = 'input_json_delta' then
      begin
        Chunk.Kind := ckToolCall;
        Chunk.ToolCallID := FToolIDs[Index];
        Chunk.ArgumentsDelta := JStr(Data, 'delta.partial_json');
        Result := FOnChunk(Chunk);
      end;
    end
    else if EventType = 'message_start' then
    begin
      Chunk.Kind := ckFinish;
      Chunk.Usage := ParseAnthropicUsage(JGet(Data, 'message'));
      Chunk.FinishReason := frUnknown;
      { Report the prompt cost as soon as it is known, without a reason. }
      if Chunk.Usage.InputTokens > 0 then
        Result := FOnChunk(Chunk);
    end
    else if EventType = 'message_delta' then
    begin
      Chunk.Kind := ckFinish;
      Chunk.Usage := ParseAnthropicUsage(Data);
      Chunk.FinishReason := ParseFinishReason(JStr(Data, 'delta.stop_reason'));
      Result := FOnChunk(Chunk);
    end;
  finally
    Data.Free;
  end;
end;

function TAnthropicClient.Stream(ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): Boolean;
var
  Body: TJSONObject;
begin
  Need(capStream, 'streaming');
  CheckParts(ARequest);
  CheckTools(ARequest);
  FOnChunk := AOnChunk;
  FBlockKinds := nil;
  FToolIDs := nil;
  SetLength(FBlockKinds, 8);
  SetLength(FToolIDs, 8);
  Body := BuildBody(ARequest, True);
  try
    Result := FTransport.PostSSE('/messages', Body, @HandleEvent);
  finally
    Body.Free;
  end;
end;

function TAnthropicClient.CountTokens(ARequest: TLLMRequest): Integer;
var
  Body: TJSONObject;
  Data: TJSONData;
  Idx: Integer;
begin
  Need(capCountTokens, 'token counting');
  Body := BuildBody(ARequest, False);
  try
    { The counting endpoint rejects generation settings. }
    Idx := Body.IndexOfName('max_tokens');
    if Idx >= 0 then
      Body.Delete(Idx);
    Idx := Body.IndexOfName('stream');
    if Idx >= 0 then
      Body.Delete(Idx);
    Data := FTransport.PostJSON('/messages/count_tokens', Body);
  finally
    Body.Free;
  end;
  try
    Result := JInt(Data, 'input_tokens');
  finally
    Data.Free;
  end;
end;

{ TAnthropicProvider }

function TAnthropicProvider.ID: string;
begin
  Result := 'anthropic';
end;

function TAnthropicProvider.Aliases: TStringArray;
begin
  Result := StringArrayOf(['claude']);
end;

function TAnthropicProvider.Matches(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'claude');
end;

function TAnthropicProvider.Capabilities(const AModel: string): TCapabilities;
begin
  if AModel = '' then ;
  Result := [capChat, capStream, capTools, capImages, capFiles, capReasoning,
             capCountTokens, capCacheHints];
end;

function TAnthropicProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
var
  Cfg: TCompatConfig;
  Transport: TTransport;
begin
  Cfg := TCompatConfig.New('anthropic', AnthropicDefaultBaseURL);
  Cfg.EnvKeys := StringArrayOf(['ANTHROPIC_API_KEY']);
  Cfg.AuthHeader := 'x-api-key';
  Cfg.AuthScheme := '';
  Transport := CompatTransport(Cfg, AOptions);
  Transport.SetHeader('anthropic-version', AnthropicVersion);
  Result := TAnthropicClient.Create('anthropic', AModel, Capabilities(AModel),
    Transport);
end;

end.
