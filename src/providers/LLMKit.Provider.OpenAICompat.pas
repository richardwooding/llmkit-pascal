{ LLMKit.Provider.OpenAICompat - the /chat/completions wire format.

  Powers DeepSeek, Groq, x.ai, OpenRouter, Hugging Face and any private
  OpenAI-compatible endpoint (vLLM, LM Studio, llama.cpp, ...) through a
  config record plus a set of quirks. Register one with:

    RegisterProvider(TOpenAICompatProvider.Create(Cfg));
}
unit LLMKit.Provider.OpenAICompat;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils, Classes, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client;

type
  { Differences between vendors that all speak /chat/completions. }
  TCompatQuirks = record
    Tools: Boolean;
    Images: Boolean;
    Audio: Boolean;
    Files: Boolean;
    Embeddings: Boolean;
    Reasoning: Boolean;            { accepts reasoning_effort }
    StreamUsage: Boolean;          { send stream_options.include_usage }
    MaxCompletionTokens: Boolean;  { max_completion_tokens, not max_tokens }
    DeveloperRole: Boolean;        { "developer" instead of "system" }
    NoSystemRole: Boolean;         { fold the system prompt into the first turn }
    JSONSchema: Boolean;           { response_format json_schema }
  end;

  TCompatConfig = record
    ID: string;
    BaseURL: string;
    Aliases: TStringArray;
    { Bare model names starting with one of these belong to this provider. }
    Prefixes: TStringArray;
    { Claim bare "org/model" names, the way Hugging Face does. }
    MatchSlashNames: Boolean;
    { Environment variables searched for the API key, in order. }
    EnvKeys: TStringArray;
    KeyOptional: Boolean;
    ChatPath: string;    { default /chat/completions }
    EmbedPath: string;   { default /embeddings }
    AuthScheme: string;  { default "Bearer" }
    AuthHeader: string;  { default "Authorization" }
    Headers: THeaderArray;
    Quirks: TCompatQuirks;
    class function New(const AID, ABaseURL: string): TCompatConfig; static;
  end;

  TOpenAICompatClient = class(TLLMClientBase, IChatter, IStreamer, IEmbedder)
  private
    FConfig: TCompatConfig;
    { streaming state }
    FOnChunk: TChunkEvent;
    FStopped: Boolean;
    FToolIndex: Integer;
    function BuildBody(ARequest: TLLMRequest; AStream: Boolean): TJSONObject;
    function BuildMessages(ARequest: TLLMRequest): TJSONArray;
    function BuildTools(ARequest: TLLMRequest): TJSONArray;
    function ContentFor(AMessage: TLLMMessage): TJSONData;
    function HandleEvent(const AEvent: TSSEEvent): Boolean;
    function Emit(const AChunk: TLLMChunk): Boolean;
  public
    constructor Create(const AConfig: TCompatConfig; const AModel: string;
      ACaps: TCapabilities; ATransport: TTransport);
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
  end;

  TOpenAICompatProvider = class(TLLMProvider)
  private
    FConfig: TCompatConfig;
  public
    constructor Create(const AConfig: TCompatConfig);
    function ID: string; override;
    function Aliases: TStringArray; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
    property Config: TCompatConfig read FConfig;
  end;

{ Decodes a /chat/completions reply into a response; shared with providers
  that reuse the format. }
function ParseCompatResponse(AJSON: TJSONData; const AProviderID,
  ARaw: string): TLLMResponse;
function ParseCompatUsage(AJSON: TJSONData): TUsage;
{ Builds the transport for a config, honouring options and environment. }
function CompatTransport(const AConfig: TCompatConfig;
  const AOptions: TClientOptions): TTransport;
function LookupAPIKey(const AEnvKeys: TStringArray;
  const AOptions: TClientOptions): string;
procedure ApplyOptionHeaders(ATransport: TTransport;
  const AOptions: TClientOptions);
function StringArrayOf(const AValues: array of string): TStringArray;

implementation

function StringArrayOf(const AValues: array of string): TStringArray;
var
  I: Integer;
begin
  Result := nil;
  SetLength(Result, Length(AValues));
  for I := 0 to High(AValues) do
    Result[I] := AValues[I];
end;

function LookupAPIKey(const AEnvKeys: TStringArray;
  const AOptions: TClientOptions): string;
var
  I: Integer;
begin
  if AOptions.APIKey <> '' then
    Exit(AOptions.APIKey);
  for I := 0 to High(AEnvKeys) do
  begin
    Result := GetEnvironmentVariable(AEnvKeys[I]);
    if Result <> '' then
      Exit;
  end;
  Result := '';
end;

procedure ApplyOptionHeaders(ATransport: TTransport;
  const AOptions: TClientOptions);
var
  I: Integer;
begin
  for I := 0 to High(AOptions.Headers) do
    ATransport.SetHeader(AOptions.Headers[I].Name, AOptions.Headers[I].Value);
end;

{ TCompatConfig }

class function TCompatConfig.New(const AID, ABaseURL: string): TCompatConfig;
begin
  Result := Default(TCompatConfig);
  Result.ID := AID;
  Result.BaseURL := ABaseURL;
  Result.ChatPath := '/chat/completions';
  Result.EmbedPath := '/embeddings';
  Result.AuthScheme := 'Bearer';
  Result.AuthHeader := 'Authorization';
  Result.Quirks.Tools := True;
  Result.Quirks.StreamUsage := True;
end;

function CompatTransport(const AConfig: TCompatConfig;
  const AOptions: TClientOptions): TTransport;
var
  Key, Base, Scheme, Header: string;
  I: Integer;
begin
  Base := AOptions.BaseURL;
  if Base = '' then
    Base := AConfig.BaseURL;
  Key := LookupAPIKey(AConfig.EnvKeys, AOptions);
  if (Key = '') and not AConfig.KeyOptional then
  begin
    if Length(AConfig.EnvKeys) > 0 then
      raise ELLMInvalidRequest.CreateFmt(
        'no API key for %s: set %s or pass WithAPIKey',
        [AConfig.ID, AConfig.EnvKeys[0]])
    else
      raise ELLMInvalidRequest.CreateFmt('no API key for %s', [AConfig.ID]);
  end;
  Result := TTransport.Create(AConfig.ID, Base, AOptions.TimeoutMS);
  if Key <> '' then
  begin
    Scheme := AConfig.AuthScheme;
    Header := AConfig.AuthHeader;
    if Header = '' then
      Header := 'Authorization';
    if Scheme = '' then
      Result.SetHeader(Header, Key)
    else
      Result.SetHeader(Header, Scheme + ' ' + Key);
  end;
  for I := 0 to High(AConfig.Headers) do
    Result.SetHeader(AConfig.Headers[I].Name, AConfig.Headers[I].Value);
  ApplyOptionHeaders(Result, AOptions);
end;

function ParseCompatUsage(AJSON: TJSONData): TUsage;
var
  U: TJSONData;
begin
  Result := Default(TUsage);
  U := JGet(AJSON, 'usage');
  if U = nil then
    Exit;
  Result.InputTokens := JInt(U, 'prompt_tokens');
  Result.OutputTokens := JInt(U, 'completion_tokens');
  if Result.InputTokens = 0 then
    Result.InputTokens := JInt(U, 'input_tokens');
  if Result.OutputTokens = 0 then
    Result.OutputTokens := JInt(U, 'output_tokens');
  Result.CachedInputTokens := JInt(U, 'prompt_tokens_details.cached_tokens');
  if Result.CachedInputTokens = 0 then
    Result.CachedInputTokens := JInt(U, 'prompt_cache_hit_tokens');
  Result.ReasoningTokens := JInt(U, 'completion_tokens_details.reasoning_tokens');
end;

function ParseCompatResponse(AJSON: TJSONData; const AProviderID,
  ARaw: string): TLLMResponse;
var
  Choice, Msg: TJSONData;
  Calls: TJSONArray;
  I: Integer;
  Reasoning, Content: string;
begin
  Result := TLLMResponse.Create;
  try
    Result.Provider := AProviderID;
    Result.Raw := ARaw;
    Result.ID := JStr(AJSON, 'id');
    Result.Model := JStr(AJSON, 'model');
    Result.Usage := ParseCompatUsage(AJSON);
    Choice := JGet(AJSON, 'choices.0');
    if Choice = nil then
      Exit;
    Result.FinishReason := ParseFinishReason(JStr(Choice, 'finish_reason'));
    Msg := JGet(Choice, 'message');
    if Msg = nil then
      Exit;
    Reasoning := JStr(Msg, 'reasoning_content');
    if Reasoning = '' then
      Reasoning := JStr(Msg, 'reasoning');
    if Reasoning <> '' then
      Result.Add(ReasoningPart(Reasoning, ''));
    Content := JStr(Msg, 'content');
    if Content <> '' then
      Result.Add(TextPart(Content));
    Calls := JArray(Msg, 'tool_calls');
    if Calls <> nil then
      for I := 0 to Calls.Count - 1 do
        Result.Add(ToolCallPart(
          JStr(Calls.Items[I], 'id'),
          JStr(Calls.Items[I], 'function.name'),
          JStr(Calls.Items[I], 'function.arguments')));
    if Result.HasToolCalls and (Result.FinishReason = frUnknown) then
      Result.FinishReason := frToolCalls;
  except
    Result.Free;
    raise;
  end;
end;

{ TOpenAICompatClient }

constructor TOpenAICompatClient.Create(const AConfig: TCompatConfig;
  const AModel: string; ACaps: TCapabilities; ATransport: TTransport);
begin
  inherited Create(AConfig.ID, AModel, ACaps, ATransport);
  FConfig := AConfig;
end;

function TOpenAICompatClient.ContentFor(AMessage: TLLMMessage): TJSONData;
var
  I: Integer;
  OnlyText: Boolean;
  Arr: TJSONArray;
  Obj, Inner: TJSONObject;
  Part: TLLMPart;
  Ref: string;
begin
  OnlyText := True;
  for I := 0 to AMessage.Parts.Count - 1 do
    if not (AMessage.Parts[I].Kind in [pkText, pkReasoning, pkToolCall]) then
      OnlyText := False;
  if OnlyText then
    Exit(TJSONString.Create(AMessage.Text));

  Arr := TJSONArray.Create;
  for I := 0 to AMessage.Parts.Count - 1 do
  begin
    Part := AMessage.Parts[I];
    case Part.Kind of
      pkText:
        begin
          Obj := TJSONObject.Create(['type', 'text', 'text', Part.Text]);
          Arr.Add(Obj);
        end;
      pkImage:
        begin
          if Part.URL <> '' then
            Ref := Part.URL
          else
            Ref := DataURL(Part.Data, Part.MimeType);
          Inner := TJSONObject.Create(['url', Ref]);
          Arr.Add(TJSONObject.Create(['type', 'image_url', 'image_url', Inner]));
        end;
      pkAudio:
        begin
          Inner := TJSONObject.Create([
            'data', Base64FromBytes(Part.Data),
            'format', StringReplace(LowerCase(Part.MimeType), 'audio/', '',
                        [rfReplaceAll])]);
          Arr.Add(TJSONObject.Create(['type', 'input_audio',
            'input_audio', Inner]));
        end;
      pkFile:
        begin
          Inner := TJSONObject.Create(['filename', Part.Filename]);
          if Part.URL <> '' then
            Inner.Add('file_data', Part.URL)
          else
            Inner.Add('file_data', DataURL(Part.Data, Part.MimeType));
          Arr.Add(TJSONObject.Create(['type', 'file', 'file', Inner]));
        end;
    end;
  end;
  Result := Arr;
end;

function TOpenAICompatClient.BuildMessages(ARequest: TLLMRequest): TJSONArray;
var
  I, J: Integer;
  Msg: TLLMMessage;
  Obj: TJSONObject;
  Calls: TJSONArray;
  Part: TLLMPart;
  SystemRole: string;
  Pending: string;
begin
  Result := TJSONArray.Create;
  SystemRole := 'system';
  if FConfig.Quirks.DeveloperRole then
    SystemRole := 'developer';
  Pending := ARequest.SystemPrompt;
  if (Pending <> '') and not FConfig.Quirks.NoSystemRole then
  begin
    Result.Add(TJSONObject.Create(['role', SystemRole, 'content', Pending]));
    Pending := '';
  end;

  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    if Msg.Role = lrTool then
    begin
      for J := 0 to Msg.Parts.Count - 1 do
        if Msg.Parts[J].Kind = pkToolResult then
          Result.Add(TJSONObject.Create([
            'role', 'tool',
            'tool_call_id', Msg.Parts[J].ID,
            'content', Msg.Parts[J].Text]));
      Continue;
    end;

    Obj := TJSONObject.Create;
    case Msg.Role of
      lrSystem: Obj.Add('role', SystemRole);
      lrAssistant: Obj.Add('role', 'assistant');
    else
      Obj.Add('role', 'user');
    end;
    if (Pending <> '') and (Msg.Role = lrUser) then
    begin
      Obj.Add('content', Pending + #10#10 + Msg.Text);
      Pending := '';
    end
    else
      Obj.Add('content', ContentFor(Msg));
    if Msg.Name <> '' then
      Obj.Add('name', Msg.Name);
    if Msg.HasKind(pkToolCall) then
    begin
      Calls := TJSONArray.Create;
      for J := 0 to Msg.Parts.Count - 1 do
      begin
        Part := Msg.Parts[J];
        if Part.Kind <> pkToolCall then
          Continue;
        Calls.Add(TJSONObject.Create([
          'id', Part.ID,
          'type', 'function',
          'function', TJSONObject.Create([
            'name', Part.Name,
            'arguments', Part.Arguments])]));
      end;
      Obj.Add('tool_calls', Calls);
    end;
    Result.Add(Obj);
  end;

  if Pending <> '' then
    Result.Insert(0, TJSONObject.Create(['role', 'user', 'content', Pending]));
end;

function TOpenAICompatClient.BuildTools(ARequest: TLLMRequest): TJSONArray;
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
      JSetRaw(Fn, 'parameters', Tool.Parameters)
    else
      Fn.Add('parameters', TJSONObject.Create(['type', 'object',
        'properties', TJSONObject.Create]));
    if Tool.StrictSchema then
      Fn.Add('strict', True);
    Result.Add(TJSONObject.Create(['type', 'function', 'function', Fn]));
  end;
end;

function TOpenAICompatClient.BuildBody(ARequest: TLLMRequest;
  AStream: Boolean): TJSONObject;
var
  Schema: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('model', FModel);
    Result.Add('messages', BuildMessages(ARequest));
    if ARequest.Tools.Count > 0 then
    begin
      Result.Add('tools', BuildTools(ARequest));
      if ARequest.ToolChoice <> '' then
      begin
        if (ARequest.ToolChoice = 'auto') or (ARequest.ToolChoice = 'none') or
           (ARequest.ToolChoice = 'required') then
          Result.Add('tool_choice', ARequest.ToolChoice)
        else
          Result.Add('tool_choice', TJSONObject.Create([
            'type', 'function',
            'function', TJSONObject.Create(['name', ARequest.ToolChoice])]));
      end;
    end;
    JSetOpt(Result, 'temperature', ARequest.Temperature);
    JSetOpt(Result, 'top_p', ARequest.TopP);
    JSetOpt(Result, 'seed', ARequest.Seed);
    if ARequest.MaxTokens.HasValue then
    begin
      if FConfig.Quirks.MaxCompletionTokens then
        Result.Add('max_completion_tokens', ARequest.MaxTokens.Value)
      else
        Result.Add('max_tokens', ARequest.MaxTokens.Value);
    end;
    if Length(ARequest.Stop) > 0 then
      Result.Add('stop', JStrings(ARequest.Stop));
    if ARequest.ResponseFormat = 'json_object' then
      Result.Add('response_format', TJSONObject.Create(['type', 'json_object']))
    else if (ARequest.ResponseFormat <> '') and FConfig.Quirks.JSONSchema then
    begin
      Schema := TJSONObject.Create(['name', 'response', 'strict', True]);
      JSetRaw(Schema, 'schema', ARequest.ResponseFormat);
      Result.Add('response_format', TJSONObject.Create([
        'type', 'json_schema', 'json_schema', Schema]));
    end;
    if ARequest.Reasoning.Enabled and FConfig.Quirks.Reasoning then
      JSetStr(Result, 'reasoning_effort', ARequest.Reasoning.Effort);
    if AStream then
    begin
      Result.Add('stream', True);
      if FConfig.Quirks.StreamUsage then
        Result.Add('stream_options', TJSONObject.Create(['include_usage', True]));
    end;
    ApplyExtras(Result, ARequest, FConfig.ID);
  except
    Result.Free;
    raise;
  end;
end;

function TOpenAICompatClient.Chat(ARequest: TLLMRequest): TLLMResponse;
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
    Text := FTransport.PostJSONText(FConfig.ChatPath, CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := ParseCompatResponse(Data, FConfig.ID, Text);
  finally
    Data.Free;
  end;
end;

function TOpenAICompatClient.Emit(const AChunk: TLLMChunk): Boolean;
begin
  Result := FOnChunk(AChunk);
  if not Result then
    FStopped := True;
end;

function TOpenAICompatClient.HandleEvent(const AEvent: TSSEEvent): Boolean;
var
  Data: TJSONData;
  Delta, Choice: TJSONData;
  Calls: TJSONArray;
  Chunk: TLLMChunk;
  I: Integer;
  S: string;
  U: TUsage;
begin
  Result := True;
  if (AEvent.Data = '') or (AEvent.Data = '[DONE]') then
    Exit;
  Data := TryParseJSON(AEvent.Data);
  if Data = nil then
    Exit;
  try
    Choice := JGet(Data, 'choices.0');
    Delta := JGet(Choice, 'delta');
    if Delta <> nil then
    begin
      S := JStr(Delta, 'reasoning_content');
      if S = '' then
        S := JStr(Delta, 'reasoning');
      if S <> '' then
      begin
        Chunk := Default(TLLMChunk);
        Chunk.Kind := ckReasoning;
        Chunk.Text := S;
        Chunk.Raw := AEvent.Data;
        if not Emit(Chunk) then
          Exit(False);
      end;
      S := JStr(Delta, 'content');
      if S <> '' then
      begin
        Chunk := Default(TLLMChunk);
        Chunk.Kind := ckText;
        Chunk.Text := S;
        Chunk.Raw := AEvent.Data;
        if not Emit(Chunk) then
          Exit(False);
      end;
      Calls := JArray(Delta, 'tool_calls');
      if Calls <> nil then
        for I := 0 to Calls.Count - 1 do
        begin
          Chunk := Default(TLLMChunk);
          Chunk.Kind := ckToolCall;
          Chunk.Index := JInt(Calls.Items[I], 'index', FToolIndex);
          Chunk.ToolCallID := JStr(Calls.Items[I], 'id');
          Chunk.ToolName := JStr(Calls.Items[I], 'function.name');
          Chunk.ArgumentsDelta := JStr(Calls.Items[I], 'function.arguments');
          Chunk.Raw := AEvent.Data;
          if Chunk.Index > FToolIndex then
            FToolIndex := Chunk.Index;
          if not Emit(Chunk) then
            Exit(False);
        end;
    end;
    U := ParseCompatUsage(Data);
    S := JStr(Choice, 'finish_reason');
    if (S <> '') or (U.InputTokens + U.OutputTokens > 0) then
    begin
      Chunk := Default(TLLMChunk);
      Chunk.Kind := ckFinish;
      Chunk.FinishReason := ParseFinishReason(S);
      Chunk.Usage := U;
      Chunk.Raw := AEvent.Data;
      if not Emit(Chunk) then
        Exit(False);
    end;
  finally
    Data.Free;
  end;
end;

function TOpenAICompatClient.Stream(ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): Boolean;
var
  Body: TJSONObject;
begin
  Need(capStream, 'streaming');
  CheckParts(ARequest);
  CheckTools(ARequest);
  FOnChunk := AOnChunk;
  FStopped := False;
  FToolIndex := 0;
  Body := BuildBody(ARequest, True);
  try
    Result := FTransport.PostSSE(FConfig.ChatPath, Body, @HandleEvent);
  finally
    Body.Free;
  end;
end;

function TOpenAICompatClient.Embed(ARequest: TEmbedRequest): TEmbedResponse;
var
  Body: TJSONObject;
  Text: string;
  Data: TJSONData;
  Items: TJSONArray;
  I, Idx: Integer;
begin
  Need(capEmbed, 'embeddings');
  Body := TJSONObject.Create;
  try
    Body.Add('model', FModel);
    Body.Add('input', JStrings(ARequest.Inputs));
    JSetOpt(Body, 'dimensions', ARequest.Dimensions);
    Text := FTransport.PostJSONText(FConfig.EmbedPath, CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TEmbedResponse.Create;
    Result.Provider := FConfig.ID;
    Result.Model := JStr(Data, 'model', FModel);
    Result.Raw := Text;
    Result.Usage := ParseCompatUsage(Data);
    Items := JArray(Data, 'data');
    if Items <> nil then
    begin
      SetLength(Result.Embeddings, Items.Count);
      for I := 0 to Items.Count - 1 do
      begin
        Idx := JInt(Items.Items[I], 'index', I);
        if (Idx < 0) or (Idx >= Items.Count) then
          Idx := I;
        Result.Embeddings[Idx] := FloatsFrom(JArray(Items.Items[I], 'embedding'));
      end;
    end;
  finally
    Data.Free;
  end;
end;

{ TOpenAICompatProvider }

constructor TOpenAICompatProvider.Create(const AConfig: TCompatConfig);
begin
  inherited Create;
  FConfig := AConfig;
  if FConfig.ChatPath = '' then
    FConfig.ChatPath := '/chat/completions';
  if FConfig.EmbedPath = '' then
    FConfig.EmbedPath := '/embeddings';
  if FConfig.AuthHeader = '' then
    FConfig.AuthHeader := 'Authorization';
end;

function TOpenAICompatProvider.ID: string;
begin
  Result := FConfig.ID;
end;

function TOpenAICompatProvider.Aliases: TStringArray;
begin
  Result := FConfig.Aliases;
end;

function TOpenAICompatProvider.Matches(const AModel: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to High(FConfig.Prefixes) do
    if HasPrefix(AModel, FConfig.Prefixes[I]) then
      Exit(True);
  Result := FConfig.MatchSlashNames and (Pos('/', AModel) > 0);
end;

function TOpenAICompatProvider.Capabilities(const AModel: string): TCapabilities;
begin
  Result := [capChat, capStream];
  if FConfig.Quirks.Tools then
    Include(Result, capTools);
  if FConfig.Quirks.Images then
    Include(Result, capImages);
  if FConfig.Quirks.Audio then
    Include(Result, capAudio);
  if FConfig.Quirks.Files then
    Include(Result, capFiles);
  if FConfig.Quirks.Embeddings then
    Include(Result, capEmbed);
  if FConfig.Quirks.Reasoning then
    Include(Result, capReasoning);
  { deepseek-reasoner rejects tool definitions; fail fast like llmkit does. }
  if HasPrefix(AModel, 'deepseek-reasoner') then
    Exclude(Result, capTools);
end;

function TOpenAICompatProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
begin
  Result := TOpenAICompatClient.Create(FConfig, AModel,
    Capabilities(AModel), CompatTransport(FConfig, AOptions));
end;

end.
