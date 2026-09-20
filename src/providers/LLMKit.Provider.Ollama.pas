{ LLMKit.Provider.Ollama - a local daemon over /api/chat and /api/embed.

  Streams newline-delimited JSON rather than SSE. Host comes from OLLAMA_HOST
  (default http://localhost:11434) and no API key is needed. This is also the
  fallback provider for bare open-weight model names.
}
unit LLMKit.Provider.Ollama;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client, LLMKit.Provider.OpenAICompat;

const
  OllamaDefaultHost = 'http://localhost:11434';

type
  TOllamaClient = class(TLLMClientBase, IChatter, IStreamer, IEmbedder)
  private
    FOnChunk: TChunkEvent;
    function BuildBody(ARequest: TLLMRequest; AStream: Boolean): TJSONObject;
    function BuildMessages(ARequest: TLLMRequest): TJSONArray;
    function BuildTools(ARequest: TLLMRequest): TJSONArray;
    function HandleLine(const ALine: string): Boolean;
  public
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
  end;

  TOllamaProvider = class(TLLMProvider)
  public
    function ID: string; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
  end;

function ParseOllamaResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
function OllamaHost: string;

implementation

function OllamaHost: string;
var
  Host: string;
begin
  Host := GetEnvironmentVariable('OLLAMA_HOST');
  if Host = '' then
    Exit(OllamaDefaultHost);
  if (Pos('http://', Host) <> 1) and (Pos('https://', Host) <> 1) then
    Host := 'http://' + Host;
  Result := Host;
end;

function ParseOllamaUsage(AJSON: TJSONData): TUsage;
begin
  Result := Default(TUsage);
  Result.InputTokens := JInt(AJSON, 'prompt_eval_count');
  Result.OutputTokens := JInt(AJSON, 'eval_count');
end;

procedure ParseOllamaToolCalls(AResponse: TLLMResponse; AMessage: TJSONData);
  forward;

function ParseOllamaResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
var
  Msg: TJSONData;
  S: string;
begin
  Result := TLLMResponse.Create;
  try
    Result.Provider := 'ollama';
    Result.Raw := ARaw;
    Result.Model := JStr(AJSON, 'model');
    Result.Usage := ParseOllamaUsage(AJSON);
    Result.FinishReason := ParseFinishReason(JStr(AJSON, 'done_reason', 'stop'));
    Msg := JGet(AJSON, 'message');
    if Msg = nil then
      Exit;
    S := JStr(Msg, 'thinking');
    if S <> '' then
      Result.Add(ReasoningPart(S, ''));
    S := JStr(Msg, 'content');
    if S <> '' then
      Result.Add(TextPart(S));
    ParseOllamaToolCalls(Result, Msg);
    if Result.HasToolCalls then
      Result.FinishReason := frToolCalls;
  except
    Result.Free;
    raise;
  end;
end;

procedure ParseOllamaToolCalls(AResponse: TLLMResponse; AMessage: TJSONData);
var
  Calls: TJSONArray;
  Args: TJSONData;
  I: Integer;
  ArgText, ID: string;
begin
  Calls := JArray(AMessage, 'tool_calls');
  if Calls = nil then
    Exit;
  for I := 0 to Calls.Count - 1 do
  begin
    Args := JGet(Calls.Items[I], 'function.arguments');
    if Args <> nil then
      ArgText := CompactJSON(Args)
    else
      ArgText := '{}';
    { Ollama does not mint call ids; synthesise stable ones. }
    ID := JStr(Calls.Items[I], 'id');
    if ID = '' then
      ID := Format('call_%d', [I + 1]);
    AResponse.Add(ToolCallPart(ID, JStr(Calls.Items[I], 'function.name'),
      ArgText));
  end;
end;

{ TOllamaClient }

function TOllamaClient.BuildMessages(ARequest: TLLMRequest): TJSONArray;
var
  I, J: Integer;
  Msg: TLLMMessage;
  Part: TLLMPart;
  Obj: TJSONObject;
  Images, Calls: TJSONArray;
  Fn: TJSONObject;
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
        begin
          Obj := TJSONObject.Create(['role', 'tool',
            'content', Msg.Parts[J].Text]);
          JSetStr(Obj, 'tool_name', Msg.Parts[J].Name);
          Result.Add(Obj);
        end;
      Continue;
    end;
    Obj := TJSONObject.Create(['role', RoleToString(Msg.Role),
      'content', Msg.Text]);
    Images := nil;
    Calls := nil;
    for J := 0 to Msg.Parts.Count - 1 do
    begin
      Part := Msg.Parts[J];
      if Part.Kind = pkImage then
      begin
        if Images = nil then
          Images := TJSONArray.Create;
        Images.Add(Base64FromBytes(Part.Data));
      end
      else if Part.Kind = pkToolCall then
      begin
        if Calls = nil then
          Calls := TJSONArray.Create;
        Fn := TJSONObject.Create(['name', Part.Name]);
        if Part.Arguments <> '' then
          JSetRaw(Fn, 'arguments', Part.Arguments)
        else
          Fn.Add('arguments', TJSONObject.Create);
        Calls.Add(TJSONObject.Create(['function', Fn]));
      end
      else if (Part.Kind = pkReasoning) and (Part.Text <> '') then
        Obj.Add('thinking', Part.Text);
    end;
    if Images <> nil then
      Obj.Add('images', Images);
    if Calls <> nil then
      Obj.Add('tool_calls', Calls);
    Result.Add(Obj);
  end;
end;

function TOllamaClient.BuildTools(ARequest: TLLMRequest): TJSONArray;
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

function TOllamaClient.BuildBody(ARequest: TLLMRequest;
  AStream: Boolean): TJSONObject;
var
  Options: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('model', FModel);
    Result.Add('messages', BuildMessages(ARequest));
    if ARequest.Tools.Count > 0 then
      Result.Add('tools', BuildTools(ARequest));
    Result.Add('stream', AStream);
    if ARequest.Reasoning.Enabled then
      Result.Add('think', True);
    if ARequest.ResponseFormat = 'json_object' then
      Result.Add('format', 'json')
    else if ARequest.ResponseFormat <> '' then
      JSetRaw(Result, 'format', ARequest.ResponseFormat);
    Options := TJSONObject.Create;
    JSetOpt(Options, 'temperature', ARequest.Temperature);
    JSetOpt(Options, 'top_p', ARequest.TopP);
    JSetOpt(Options, 'seed', ARequest.Seed);
    if ARequest.MaxTokens.HasValue then
      Options.Add('num_predict', ARequest.MaxTokens.Value);
    if Length(ARequest.Stop) > 0 then
      Options.Add('stop', JStrings(ARequest.Stop));
    if Options.Count > 0 then
      Result.Add('options', Options)
    else
      Options.Free;
    ApplyExtras(Result, ARequest, 'ollama');
  except
    Result.Free;
    raise;
  end;
end;

function TOllamaClient.Chat(ARequest: TLLMRequest): TLLMResponse;
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
    Text := FTransport.PostJSONText('/api/chat', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := ParseOllamaResponse(Data, Text);
  finally
    Data.Free;
  end;
end;

function TOllamaClient.HandleLine(const ALine: string): Boolean;
var
  Data: TJSONData;
  Chunk: TLLMChunk;
  Msg: TJSONData;
  Calls: TJSONArray;
  Args: TJSONData;
  I: Integer;
  S: string;
begin
  Result := True;
  if Trim(ALine) = '' then
    Exit;
  Data := TryParseJSON(ALine);
  if Data = nil then
    Exit;
  try
    Msg := JGet(Data, 'message');
    Chunk := Default(TLLMChunk);
    Chunk.Raw := ALine;
    if Msg <> nil then
    begin
      S := JStr(Msg, 'thinking');
      if S <> '' then
      begin
        Chunk.Kind := ckReasoning;
        Chunk.Text := S;
        if not FOnChunk(Chunk) then
          Exit(False);
      end;
      S := JStr(Msg, 'content');
      if S <> '' then
      begin
        Chunk := Default(TLLMChunk);
        Chunk.Raw := ALine;
        Chunk.Kind := ckText;
        Chunk.Text := S;
        if not FOnChunk(Chunk) then
          Exit(False);
      end;
      Calls := JArray(Msg, 'tool_calls');
      if Calls <> nil then
        for I := 0 to Calls.Count - 1 do
        begin
          Chunk := Default(TLLMChunk);
          Chunk.Raw := ALine;
          Chunk.Kind := ckToolCall;
          Chunk.Index := I;
          Chunk.ToolCallID := Format('call_%d', [I + 1]);
          Chunk.ToolName := JStr(Calls.Items[I], 'function.name');
          Args := JGet(Calls.Items[I], 'function.arguments');
          if Args <> nil then
            Chunk.ArgumentsDelta := CompactJSON(Args);
          if not FOnChunk(Chunk) then
            Exit(False);
        end;
    end;
    if JBool(Data, 'done') then
    begin
      Chunk := Default(TLLMChunk);
      Chunk.Raw := ALine;
      Chunk.Kind := ckFinish;
      Chunk.Usage := ParseOllamaUsage(Data);
      Chunk.FinishReason := ParseFinishReason(JStr(Data, 'done_reason', 'stop'));
      Result := FOnChunk(Chunk);
    end;
  finally
    Data.Free;
  end;
end;

function TOllamaClient.Stream(ARequest: TLLMRequest;
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
    Result := FTransport.PostLines('/api/chat', Body, @HandleLine);
  finally
    Body.Free;
  end;
end;

function TOllamaClient.Embed(ARequest: TEmbedRequest): TEmbedResponse;
var
  Body: TJSONObject;
  Text: string;
  Data: TJSONData;
  Items: TJSONArray;
  I: Integer;
begin
  Need(capEmbed, 'embeddings');
  Body := TJSONObject.Create;
  try
    Body.Add('model', FModel);
    Body.Add('input', JStrings(ARequest.Inputs));
    Text := FTransport.PostJSONText('/api/embed', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TEmbedResponse.Create;
    Result.Provider := 'ollama';
    Result.Model := JStr(Data, 'model', FModel);
    Result.Raw := Text;
    Result.Usage.InputTokens := JInt(Data, 'prompt_eval_count');
    Items := JArray(Data, 'embeddings');
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

{ TOllamaProvider }

function TOllamaProvider.ID: string;
begin
  Result := 'ollama';
end;

function TOllamaProvider.Matches(const AModel: string): Boolean;
begin
  { "llama3.2:3b", "qwen3:8b": a tag makes it unambiguous. }
  Result := (Pos(':', AModel) > 0) and (Pos('/', AModel) = 0);
end;

function TOllamaProvider.Capabilities(const AModel: string): TCapabilities;
begin
  if AModel = '' then ;
  Result := [capChat, capStream, capEmbed, capTools, capImages, capReasoning];
end;

function TOllamaProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
var
  Cfg: TCompatConfig;
begin
  Cfg := TCompatConfig.New('ollama', OllamaHost);
  Cfg.KeyOptional := True;
  Result := TOllamaClient.Create('ollama', AModel, Capabilities(AModel),
    CompatTransport(Cfg, AOptions));
end;

end.
