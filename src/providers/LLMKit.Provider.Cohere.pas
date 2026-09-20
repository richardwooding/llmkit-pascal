{ LLMKit.Provider.Cohere - Chat v2, Embed v2 and Rerank v2.

  The only provider here that does all three of chat, embeddings and
  reranking. Key: COHERE_API_KEY.
}
unit LLMKit.Provider.Cohere;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client, LLMKit.Provider.OpenAICompat;

const
  CohereDefaultBaseURL = 'https://api.cohere.com/v2';

type
  TCohereClient = class(TLLMClientBase, IChatter, IStreamer, IEmbedder, IReranker)
  private
    FOnChunk: TChunkEvent;
    function BuildBody(ARequest: TLLMRequest; AStream: Boolean): TJSONObject;
    function BuildMessages(ARequest: TLLMRequest): TJSONArray;
    function BuildTools(ARequest: TLLMRequest): TJSONArray;
    function HandleEvent(const AEvent: TSSEEvent): Boolean;
  public
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
    function Rerank(ARequest: TRerankRequest): TRerankResponse;
  end;

  TCohereProvider = class(TLLMProvider)
  public
    function ID: string; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
  end;

function ParseCohereResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
function IsCohereEmbedModel(const AModel: string): Boolean;
function IsCohereRerankModel(const AModel: string): Boolean;

implementation

function IsCohereEmbedModel(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'embed');
end;

function IsCohereRerankModel(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'rerank');
end;

function ParseCohereUsage(AJSON: TJSONData): TUsage;
begin
  Result := Default(TUsage);
  Result.InputTokens := JInt(AJSON, 'usage.tokens.input_tokens');
  Result.OutputTokens := JInt(AJSON, 'usage.tokens.output_tokens');
  if Result.InputTokens = 0 then
    Result.InputTokens := JInt(AJSON, 'meta.billed_units.input_tokens');
  if Result.OutputTokens = 0 then
    Result.OutputTokens := JInt(AJSON, 'meta.billed_units.output_tokens');
end;

function ParseCohereResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
var
  Content, Calls: TJSONArray;
  I: Integer;
  S: string;
begin
  Result := TLLMResponse.Create;
  try
    Result.Provider := 'cohere';
    Result.Raw := ARaw;
    Result.ID := JStr(AJSON, 'id');
    Result.Usage := ParseCohereUsage(AJSON);
    Result.FinishReason := ParseFinishReason(JStr(AJSON, 'finish_reason'));
    S := JStr(AJSON, 'message.tool_plan');
    if S <> '' then
      Result.Add(ReasoningPart(S, ''));
    Content := JArray(AJSON, 'message.content');
    if Content <> nil then
      for I := 0 to Content.Count - 1 do
        if JStr(Content.Items[I], 'type') = 'text' then
          Result.Add(TextPart(JStr(Content.Items[I], 'text')));
    Calls := JArray(AJSON, 'message.tool_calls');
    if Calls <> nil then
      for I := 0 to Calls.Count - 1 do
        Result.Add(ToolCallPart(JStr(Calls.Items[I], 'id'),
          JStr(Calls.Items[I], 'function.name'),
          JStr(Calls.Items[I], 'function.arguments')));
  except
    Result.Free;
    raise;
  end;
end;

{ TCohereClient }

function TCohereClient.BuildMessages(ARequest: TLLMRequest): TJSONArray;
var
  I, J: Integer;
  Msg: TLLMMessage;
  Part: TLLMPart;
  Obj, Inner: TJSONObject;
  Content, Calls: TJSONArray;
begin
  Result := TJSONArray.Create;
  if ARequest.SystemPrompt <> '' then
    Result.Add(TJSONObject.Create(['role', 'system',
      'content', ARequest.SystemPrompt]));
  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    if Msg.Role = lrTool then
    begin
      for J := 0 to Msg.Parts.Count - 1 do
        if Msg.Parts[J].Kind = pkToolResult then
          Result.Add(TJSONObject.Create(['role', 'tool',
            'tool_call_id', Msg.Parts[J].ID,
            'content', Msg.Parts[J].Text]));
      Continue;
    end;
    Obj := TJSONObject.Create(['role', RoleToString(Msg.Role)]);
    Content := TJSONArray.Create;
    Calls := nil;
    for J := 0 to Msg.Parts.Count - 1 do
    begin
      Part := Msg.Parts[J];
      case Part.Kind of
        pkText:
          Content.Add(TJSONObject.Create(['type', 'text', 'text', Part.Text]));
        pkImage:
          begin
            if Part.URL <> '' then
              Inner := TJSONObject.Create(['url', Part.URL])
            else
              Inner := TJSONObject.Create(['url',
                DataURL(Part.Data, Part.MimeType)]);
            Content.Add(TJSONObject.Create(['type', 'image_url',
              'image_url', Inner]));
          end;
        pkToolCall:
          begin
            if Calls = nil then
              Calls := TJSONArray.Create;
            Calls.Add(TJSONObject.Create([
              'id', Part.ID,
              'type', 'function',
              'function', TJSONObject.Create([
                'name', Part.Name,
                'arguments', Part.Arguments])]));
          end;
      end;
    end;
    if Content.Count > 0 then
      Obj.Add('content', Content)
    else
      Content.Free;
    if Calls <> nil then
      Obj.Add('tool_calls', Calls);
    if (Obj.IndexOfName('content') < 0) and (Calls = nil) then
    begin
      Obj.Free;
      Continue;
    end;
    Result.Add(Obj);
  end;
end;

function TCohereClient.BuildTools(ARequest: TLLMRequest): TJSONArray;
var
  I: Integer;
  Fn: TJSONObject;
  Tool: TLLMTool;
begin
  Result := TJSONArray.Create;
  for I := 0 to ARequest.Tools.Count - 1 do
  begin
    Tool := ARequest.Tools[I];
    Fn := TJSONObject.Create(['name', Tool.Name]);
    JSetStr(Fn, 'description', Tool.Description);
    if Tool.Parameters <> '' then
      JSetRaw(Fn, 'parameters', Tool.Parameters);
    Result.Add(TJSONObject.Create(['type', 'function', 'function', Fn]));
  end;
end;

function TCohereClient.BuildBody(ARequest: TLLMRequest;
  AStream: Boolean): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('model', FModel);
    Result.Add('messages', BuildMessages(ARequest));
    if ARequest.Tools.Count > 0 then
      Result.Add('tools', BuildTools(ARequest));
    JSetOpt(Result, 'temperature', ARequest.Temperature);
    JSetOpt(Result, 'p', ARequest.TopP);
    JSetOpt(Result, 'seed', ARequest.Seed);
    JSetOpt(Result, 'max_tokens', ARequest.MaxTokens);
    if Length(ARequest.Stop) > 0 then
      Result.Add('stop_sequences', JStrings(ARequest.Stop));
    if ARequest.ResponseFormat = 'json_object' then
      Result.Add('response_format', TJSONObject.Create(['type', 'json_object']));
    if AStream then
      Result.Add('stream', True);
    ApplyExtras(Result, ARequest, 'cohere');
  except
    Result.Free;
    raise;
  end;
end;

function TCohereClient.Chat(ARequest: TLLMRequest): TLLMResponse;
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
    Text := FTransport.PostJSONText('/chat', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := ParseCohereResponse(Data, Text);
  finally
    Data.Free;
  end;
end;

function TCohereClient.HandleEvent(const AEvent: TSSEEvent): Boolean;
var
  Data: TJSONData;
  Chunk: TLLMChunk;
  EventType, S: string;
begin
  Result := True;
  if (AEvent.Data = '') or (AEvent.Data = '[DONE]') then
    Exit;
  Data := TryParseJSON(AEvent.Data);
  if Data = nil then
    Exit;
  try
    EventType := JStr(Data, 'type');
    if EventType = '' then
      EventType := AEvent.EventName;
    Chunk := Default(TLLMChunk);
    Chunk.Raw := AEvent.Data;
    Chunk.Index := JInt(Data, 'index', 0);

    if EventType = 'content-delta' then
    begin
      Chunk.Kind := ckText;
      Chunk.Text := JStr(Data, 'delta.message.content.text');
      if Chunk.Text <> '' then
        Result := FOnChunk(Chunk);
    end
    else if EventType = 'tool-plan-delta' then
    begin
      Chunk.Kind := ckReasoning;
      Chunk.Text := JStr(Data, 'delta.message.tool_plan');
      if Chunk.Text <> '' then
        Result := FOnChunk(Chunk);
    end
    else if EventType = 'tool-call-start' then
    begin
      Chunk.Kind := ckToolCall;
      Chunk.ToolCallID := JStr(Data, 'delta.message.tool_calls.id');
      Chunk.ToolName := JStr(Data, 'delta.message.tool_calls.function.name');
      Result := FOnChunk(Chunk);
    end
    else if EventType = 'tool-call-delta' then
    begin
      Chunk.Kind := ckToolCall;
      Chunk.ArgumentsDelta :=
        JStr(Data, 'delta.message.tool_calls.function.arguments');
      Result := FOnChunk(Chunk);
    end
    else if EventType = 'message-end' then
    begin
      Chunk.Kind := ckFinish;
      S := JStr(Data, 'delta.finish_reason');
      Chunk.FinishReason := ParseFinishReason(S);
      Chunk.Usage.InputTokens := JInt(Data, 'delta.usage.tokens.input_tokens');
      Chunk.Usage.OutputTokens := JInt(Data, 'delta.usage.tokens.output_tokens');
      Result := FOnChunk(Chunk);
    end;
  finally
    Data.Free;
  end;
end;

function TCohereClient.Stream(ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): Boolean;
var
  Body: TJSONObject;
begin
  Need(capStream, 'streaming');
  CheckParts(ARequest);
  CheckTools(ARequest);
  FOnChunk := AOnChunk;
  Body := BuildBody(ARequest, True);
  try
    Result := FTransport.PostSSE('/chat', Body, @HandleEvent);
  finally
    Body.Free;
  end;
end;

function TCohereClient.Embed(ARequest: TEmbedRequest): TEmbedResponse;
var
  Body: TJSONObject;
  Text, InputType: string;
  Data: TJSONData;
  Items: TJSONArray;
  I: Integer;
begin
  Need(capEmbed, 'embeddings');
  Body := TJSONObject.Create;
  try
    Body.Add('model', FModel);
    Body.Add('texts', JStrings(ARequest.Inputs));
    Body.Add('embedding_types', TJSONArray.Create(['float']));
    case ARequest.InputType of
      eiQuery: InputType := 'search_query';
      eiDocument: InputType := 'search_document';
    else
      InputType := 'search_document';
    end;
    Body.Add('input_type', InputType);
    JSetOpt(Body, 'output_dimension', ARequest.Dimensions);
    Text := FTransport.PostJSONText('/embed', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TEmbedResponse.Create;
    Result.Provider := 'cohere';
    Result.Model := FModel;
    Result.Raw := Text;
    Result.Usage := ParseCohereUsage(Data);
    Items := JArray(Data, 'embeddings.float');
    if Items <> nil then
    begin
      SetLength(Result.Embeddings, Items.Count);
      for I := 0 to Items.Count - 1 do
        if Items.Items[I].JSONType = jtArray then
          Result.Embeddings[I] := FloatsFrom(TJSONArray(Items.Items[I]));
    end;
  finally
    Data.Free;
  end;
end;

function TCohereClient.Rerank(ARequest: TRerankRequest): TRerankResponse;
var
  Body: TJSONObject;
  Text: string;
  Data: TJSONData;
  Items: TJSONArray;
  I, Idx: Integer;
begin
  Need(capRerank, 'reranking');
  Body := TJSONObject.Create;
  try
    Body.Add('model', FModel);
    Body.Add('query', ARequest.Query);
    Body.Add('documents', JStrings(ARequest.Documents));
    JSetOpt(Body, 'top_n', ARequest.TopN);
    Text := FTransport.PostJSONText('/rerank', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TRerankResponse.Create;
    Result.Provider := 'cohere';
    Result.Model := FModel;
    Result.Raw := Text;
    Result.Usage := ParseCohereUsage(Data);
    Items := JArray(Data, 'results');
    if Items <> nil then
    begin
      SetLength(Result.Results, Items.Count);
      for I := 0 to Items.Count - 1 do
      begin
        Idx := JInt(Items.Items[I], 'index');
        Result.Results[I].Index := Idx;
        Result.Results[I].Score := JFloat(Items.Items[I], 'relevance_score');
        if (Idx >= 0) and (Idx <= High(ARequest.Documents)) then
          Result.Results[I].Document := ARequest.Documents[Idx];
      end;
    end;
  finally
    Data.Free;
  end;
end;

{ TCohereProvider }

function TCohereProvider.ID: string;
begin
  Result := 'cohere';
end;

function TCohereProvider.Matches(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'command') or IsCohereEmbedModel(AModel) or
            IsCohereRerankModel(AModel);
end;

function TCohereProvider.Capabilities(const AModel: string): TCapabilities;
begin
  if IsCohereRerankModel(AModel) then
    Exit([capRerank]);
  if IsCohereEmbedModel(AModel) then
    Exit([capEmbed]);
  Result := [capChat, capStream, capTools, capImages];
end;

function TCohereProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
var
  Cfg: TCompatConfig;
begin
  Cfg := TCompatConfig.New('cohere', CohereDefaultBaseURL);
  Cfg.EnvKeys := StringArrayOf(['COHERE_API_KEY', 'CO_API_KEY']);
  Result := TCohereClient.Create('cohere', AModel, Capabilities(AModel),
    CompatTransport(Cfg, AOptions));
end;

end.
