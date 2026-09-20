{ LLMKit.Provider.OpenAI - the Responses API (/v1/responses).

  Chat, streaming, tools, images, PDFs and reasoning summaries, plus
  /v1/embeddings for the text-embedding-3 family. Key: OPENAI_API_KEY.
}
unit LLMKit.Provider.OpenAI;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client, LLMKit.Provider.OpenAICompat;

const
  OpenAIDefaultBaseURL = 'https://api.openai.com/v1';

type
  TOpenAIClient = class(TLLMClientBase, IChatter, IStreamer, IEmbedder)
  private
    FOnChunk: TChunkEvent;
    FToolIndex: Integer;
    function BuildBody(ARequest: TLLMRequest; AStream: Boolean): TJSONObject;
    function BuildInput(ARequest: TLLMRequest): TJSONArray;
    function BuildTools(ARequest: TLLMRequest): TJSONArray;
    function HandleEvent(const AEvent: TSSEEvent): Boolean;
    function Emit(const AChunk: TLLMChunk): Boolean;
  public
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
  end;

  TOpenAIProvider = class(TLLMProvider)
  public
    function ID: string; override;
    function Aliases: TStringArray; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
  end;

function ParseResponsesAPI(AJSON: TJSONData; const ARaw: string): TLLMResponse;
function IsOpenAIEmbeddingModel(const AModel: string): Boolean;

implementation

function IsOpenAIEmbeddingModel(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'text-embedding');
end;

function ParseResponsesUsage(AJSON: TJSONData): TUsage;
var
  U: TJSONData;
begin
  Result := Default(TUsage);
  U := JGet(AJSON, 'usage');
  if U = nil then
    Exit;
  Result.InputTokens := JInt(U, 'input_tokens');
  Result.OutputTokens := JInt(U, 'output_tokens');
  Result.CachedInputTokens := JInt(U, 'input_tokens_details.cached_tokens');
  Result.ReasoningTokens := JInt(U, 'output_tokens_details.reasoning_tokens');
end;

function ParseResponsesAPI(AJSON: TJSONData; const ARaw: string): TLLMResponse;
var
  Output, Content, Summary: TJSONArray;
  Item: TJSONData;
  I, J: Integer;
  Kind, Text, Status: string;
  Part: TLLMPart;
begin
  Result := TLLMResponse.Create;
  try
    Result.Provider := 'openai';
    Result.Raw := ARaw;
    Result.ID := JStr(AJSON, 'id');
    Result.Model := JStr(AJSON, 'model');
    Result.Usage := ParseResponsesUsage(AJSON);
    Status := JStr(AJSON, 'status');
    if Status = 'incomplete' then
      Result.FinishReason := ParseFinishReason(
        JStr(AJSON, 'incomplete_details.reason'))
    else
      Result.FinishReason := ParseFinishReason(Status);
    Output := JArray(AJSON, 'output');
    if Output = nil then
      Exit;
    for I := 0 to Output.Count - 1 do
    begin
      Item := Output.Items[I];
      Kind := JStr(Item, 'type');
      if Kind = 'message' then
      begin
        Content := JArray(Item, 'content');
        if Content <> nil then
          for J := 0 to Content.Count - 1 do
          begin
            Text := JStr(Content.Items[J], 'text');
            if JStr(Content.Items[J], 'type') = 'refusal' then
            begin
              Result.FinishReason := frRefusal;
              Text := JStr(Content.Items[J], 'refusal');
            end;
            if Text <> '' then
              Result.Add(TextPart(Text));
          end;
      end
      else if Kind = 'reasoning' then
      begin
        Text := '';
        Summary := JArray(Item, 'summary');
        if Summary <> nil then
          for J := 0 to Summary.Count - 1 do
            Text := Text + JStr(Summary.Items[J], 'text');
        Part := ReasoningPart(Text, JStr(Item, 'id'));
        Part.Redacted := Text = '';
        Result.Add(Part);
      end
      else if (Kind = 'function_call') or (Kind = 'custom_tool_call') then
      begin
        Result.Add(ToolCallPart(JStr(Item, 'call_id'), JStr(Item, 'name'),
          JStr(Item, 'arguments')));
        Result.FinishReason := frToolCalls;
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ TOpenAIClient }

function TOpenAIClient.BuildInput(ARequest: TLLMRequest): TJSONArray;
var
  I, J: Integer;
  Msg: TLLMMessage;
  Part: TLLMPart;
  Content: TJSONArray;
  Obj: TJSONObject;
  Ref, TextType: string;
begin
  Result := TJSONArray.Create;
  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    if Msg.Role = lrTool then
    begin
      for J := 0 to Msg.Parts.Count - 1 do
        if Msg.Parts[J].Kind = pkToolResult then
          Result.Add(TJSONObject.Create([
            'type', 'function_call_output',
            'call_id', Msg.Parts[J].ID,
            'output', Msg.Parts[J].Text]));
      Continue;
    end;

    { Tool calls are top level items, not message content. }
    for J := 0 to Msg.Parts.Count - 1 do
      if Msg.Parts[J].Kind = pkToolCall then
        Result.Add(TJSONObject.Create([
          'type', 'function_call',
          'call_id', Msg.Parts[J].ID,
          'name', Msg.Parts[J].Name,
          'arguments', Msg.Parts[J].Arguments]));

    if Msg.Role = lrAssistant then
      TextType := 'output_text'
    else
      TextType := 'input_text';
    Content := TJSONArray.Create;
    for J := 0 to Msg.Parts.Count - 1 do
    begin
      Part := Msg.Parts[J];
      case Part.Kind of
        pkText:
          Content.Add(TJSONObject.Create(['type', TextType, 'text', Part.Text]));
        pkImage:
          begin
            if Part.URL <> '' then
              Ref := Part.URL
            else
              Ref := DataURL(Part.Data, Part.MimeType);
            Content.Add(TJSONObject.Create([
              'type', 'input_image', 'image_url', Ref]));
          end;
        pkFile:
          begin
            Obj := TJSONObject.Create(['type', 'input_file']);
            if Part.Filename <> '' then
              Obj.Add('filename', Part.Filename);
            if Part.URL <> '' then
              Obj.Add('file_url', Part.URL)
            else
              Obj.Add('file_data', DataURL(Part.Data, Part.MimeType));
            Content.Add(Obj);
          end;
      end;
    end;
    if Content.Count = 0 then
    begin
      Content.Free;
      Continue;
    end;
    Result.Add(TJSONObject.Create([
      'role', RoleToString(Msg.Role),
      'content', Content]));
  end;
end;

function TOpenAIClient.BuildTools(ARequest: TLLMRequest): TJSONArray;
var
  I: Integer;
  Obj: TJSONObject;
  Tool: TLLMTool;
begin
  Result := TJSONArray.Create;
  for I := 0 to ARequest.Tools.Count - 1 do
  begin
    Tool := ARequest.Tools[I];
    Obj := TJSONObject.Create(['type', 'function', 'name', Tool.Name]);
    JSetStr(Obj, 'description', Tool.Description);
    if Tool.Parameters <> '' then
      JSetRaw(Obj, 'parameters', Tool.Parameters);
    if Tool.StrictSchema then
      Obj.Add('strict', True);
    Result.Add(Obj);
  end;
end;

function TOpenAIClient.BuildBody(ARequest: TLLMRequest;
  AStream: Boolean): TJSONObject;
var
  Reasoning, Format: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('model', FModel);
    Result.Add('input', BuildInput(ARequest));
    JSetStr(Result, 'instructions', ARequest.SystemPrompt);
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
            'type', 'function', 'name', ARequest.ToolChoice]));
      end;
    end;
    JSetOpt(Result, 'temperature', ARequest.Temperature);
    JSetOpt(Result, 'top_p', ARequest.TopP);
    if ARequest.MaxTokens.HasValue then
      Result.Add('max_output_tokens', ARequest.MaxTokens.Value);
    if ARequest.Reasoning.Enabled then
    begin
      Reasoning := TJSONObject.Create;
      JSetStr(Reasoning, 'effort', ARequest.Reasoning.Effort);
      { "summarized" is Anthropic's word for the same thing. }
      if ARequest.Reasoning.Summary = 'summarized' then
        Reasoning.Add('summary', 'auto')
      else if ARequest.Reasoning.Summary = 'omitted' then
        { no summary requested }
      else
        JSetStr(Reasoning, 'summary', ARequest.Reasoning.Summary);
      Result.Add('reasoning', Reasoning);
    end;
    if ARequest.ResponseFormat = 'json_object' then
      Result.Add('text', TJSONObject.Create(['format',
        TJSONObject.Create(['type', 'json_object'])]))
    else if ARequest.ResponseFormat <> '' then
    begin
      Format := TJSONObject.Create(['type', 'json_schema', 'name', 'response',
        'strict', True]);
      JSetRaw(Format, 'schema', ARequest.ResponseFormat);
      Result.Add('text', TJSONObject.Create(['format', Format]));
    end;
    if AStream then
      Result.Add('stream', True);
    ApplyExtras(Result, ARequest, 'openai');
  except
    Result.Free;
    raise;
  end;
end;

function TOpenAIClient.Chat(ARequest: TLLMRequest): TLLMResponse;
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
    Text := FTransport.PostJSONText('/responses', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := ParseResponsesAPI(Data, Text);
  finally
    Data.Free;
  end;
end;

function TOpenAIClient.Emit(const AChunk: TLLMChunk): Boolean;
begin
  Result := FOnChunk(AChunk);
end;

function TOpenAIClient.HandleEvent(const AEvent: TSSEEvent): Boolean;
var
  Data: TJSONData;
  Chunk: TLLMChunk;
  EventType, Delta, ItemType: string;
  Item: TJSONData;
begin
  Result := True;
  if (AEvent.Data = '') or (AEvent.Data = '[DONE]') then
    Exit;
  Data := TryParseJSON(AEvent.Data);
  if Data = nil then
    Exit;
  try
    EventType := AEvent.EventName;
    if EventType = '' then
      EventType := JStr(Data, 'type');
    Chunk := Default(TLLMChunk);
    Chunk.Raw := AEvent.Data;
    Delta := JStr(Data, 'delta');

    if EventType = 'response.output_text.delta' then
    begin
      Chunk.Kind := ckText;
      Chunk.Text := Delta;
      Result := Emit(Chunk);
    end
    else if (EventType = 'response.reasoning_summary_text.delta') or
            (EventType = 'response.reasoning_text.delta') then
    begin
      Chunk.Kind := ckReasoning;
      Chunk.Text := Delta;
      Result := Emit(Chunk);
    end
    else if EventType = 'response.output_item.added' then
    begin
      Item := JGet(Data, 'item');
      ItemType := JStr(Item, 'type');
      if ItemType = 'function_call' then
      begin
        Chunk.Kind := ckToolCall;
        Chunk.Index := JInt(Data, 'output_index', FToolIndex);
        Chunk.ToolCallID := JStr(Item, 'call_id');
        Chunk.ToolName := JStr(Item, 'name');
        FToolIndex := Chunk.Index;
        Result := Emit(Chunk);
      end;
    end
    else if EventType = 'response.function_call_arguments.delta' then
    begin
      Chunk.Kind := ckToolCall;
      Chunk.Index := JInt(Data, 'output_index', FToolIndex);
      Chunk.ArgumentsDelta := Delta;
      Result := Emit(Chunk);
    end
    else if (EventType = 'response.completed') or
            (EventType = 'response.incomplete') or
            (EventType = 'response.failed') then
    begin
      Chunk.Kind := ckFinish;
      Chunk.Usage := ParseResponsesUsage(JGet(Data, 'response'));
      if EventType = 'response.incomplete' then
        Chunk.FinishReason := ParseFinishReason(
          JStr(Data, 'response.incomplete_details.reason'))
      else
        Chunk.FinishReason := ParseFinishReason(
          JStr(Data, 'response.status', 'stop'));
      Result := Emit(Chunk);
    end;
  finally
    Data.Free;
  end;
end;

function TOpenAIClient.Stream(ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): Boolean;
var
  Body: TJSONObject;
begin
  Need(capStream, 'streaming');
  CheckParts(ARequest);
  CheckTools(ARequest);
  FOnChunk := AOnChunk;
  FToolIndex := 0;
  Body := BuildBody(ARequest, True);
  try
    Result := FTransport.PostSSE('/responses', Body, @HandleEvent);
  finally
    Body.Free;
  end;
end;

function TOpenAIClient.Embed(ARequest: TEmbedRequest): TEmbedResponse;
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
    Text := FTransport.PostJSONText('/embeddings', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TEmbedResponse.Create;
    Result.Provider := 'openai';
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

{ TOpenAIProvider }

function TOpenAIProvider.ID: string;
begin
  Result := 'openai';
end;

function TOpenAIProvider.Aliases: TStringArray;
begin
  Result := StringArrayOf(['oai']);
end;

function TOpenAIProvider.Matches(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'gpt-') or HasPrefix(AModel, 'chatgpt-') or
            HasPrefix(AModel, 'o1') or HasPrefix(AModel, 'o3') or
            HasPrefix(AModel, 'o4') or HasPrefix(AModel, 'text-embedding-') or
            HasPrefix(AModel, 'davinci') or HasPrefix(AModel, 'babbage');
end;

function TOpenAIProvider.Capabilities(const AModel: string): TCapabilities;
begin
  if IsOpenAIEmbeddingModel(AModel) then
    Exit([capEmbed]);
  Result := [capChat, capStream, capTools, capImages, capFiles, capReasoning];
end;

function TOpenAIProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
var
  Cfg: TCompatConfig;
  Transport: TTransport;
begin
  Cfg := TCompatConfig.New('openai', OpenAIDefaultBaseURL);
  Cfg.EnvKeys := StringArrayOf(['OPENAI_API_KEY']);
  Transport := CompatTransport(Cfg, AOptions);
  if AOptions.Organization <> '' then
    Transport.SetHeader('OpenAI-Organization', AOptions.Organization);
  if AOptions.Project <> '' then
    Transport.SetHeader('OpenAI-Project', AOptions.Project);
  Result := TOpenAIClient.Create('openai', AModel, Capabilities(AModel),
    Transport);
end;

end.
