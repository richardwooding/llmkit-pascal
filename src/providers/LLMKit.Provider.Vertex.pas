{ LLMKit.Provider.Vertex - Gemini on Vertex AI over REST.

  generateContent, streamGenerateContent?alt=sse, countTokens and the
  text-embedding predict endpoint.

  Credentials: Free Pascal has no Google ADC implementation, so the access
  token is taken from GOOGLE_ACCESS_TOKEN (or WithAPIKey) - mint one with
  "gcloud auth print-access-token". Project and location come from
  GOOGLE_CLOUD_PROJECT / GOOGLE_CLOUD_LOCATION or WithProject/WithLocation.
}
unit LLMKit.Provider.Vertex;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client, LLMKit.Provider.OpenAICompat;

const
  VertexDefaultLocation = 'us-central1';

type
  TVertexClient = class(TLLMClientBase, IChatter, IStreamer, IEmbedder,
    ITokenCounter)
  private
    FProject: string;
    FLocation: string;
    FOnChunk: TChunkEvent;
    FToolIndex: Integer;
    function ModelPath(const AMethod: string): string;
    function BuildBody(ARequest: TLLMRequest): TJSONObject;
    function BuildContents(ARequest: TLLMRequest): TJSONArray;
    function BuildTools(ARequest: TLLMRequest): TJSONArray;
    function HandleEvent(const AEvent: TSSEEvent): Boolean;
  public
    constructor Create(const AModel: string; ACaps: TCapabilities;
      ATransport: TTransport; const AProject, ALocation: string);
    function Chat(ARequest: TLLMRequest): TLLMResponse;
    function Stream(ARequest: TLLMRequest; AOnChunk: TChunkEvent): Boolean;
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
    function CountTokens(ARequest: TLLMRequest): Integer;
  end;

  TVertexProvider = class(TLLMProvider)
  public
    function ID: string; override;
    function Aliases: TStringArray; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
  end;

function ParseVertexResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
function IsVertexEmbeddingModel(const AModel: string): Boolean;

implementation

function IsVertexEmbeddingModel(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'text-embedding') or
            HasPrefix(AModel, 'text-multilingual-embedding') or
            HasPrefix(AModel, 'gemini-embedding') or
            HasPrefix(AModel, 'multimodalembedding');
end;

function ParseVertexUsage(AJSON: TJSONData): TUsage;
var
  U: TJSONData;
begin
  Result := Default(TUsage);
  U := JGet(AJSON, 'usageMetadata');
  if U = nil then
    Exit;
  Result.InputTokens := JInt(U, 'promptTokenCount');
  Result.OutputTokens := JInt(U, 'candidatesTokenCount');
  Result.CachedInputTokens := JInt(U, 'cachedContentTokenCount');
  Result.ReasoningTokens := JInt(U, 'thoughtsTokenCount');
  Inc(Result.OutputTokens, Result.ReasoningTokens);
end;

procedure AddVertexParts(AResponse: TLLMResponse; AParts: TJSONArray;
  var AToolIndex: Integer);
var
  I: Integer;
  Item, Args: TJSONData;
  S: string;
begin
  if AParts = nil then
    Exit;
  for I := 0 to AParts.Count - 1 do
  begin
    Item := AParts.Items[I];
    if JHas(Item, 'functionCall') then
    begin
      Args := JGet(Item, 'functionCall.args');
      Inc(AToolIndex);
      if Args <> nil then
        S := CompactJSON(Args)
      else
        S := '{}';
      AResponse.Add(ToolCallPart(Format('call_%d', [AToolIndex]),
        JStr(Item, 'functionCall.name'), S));
    end
    else
    begin
      S := JStr(Item, 'text');
      if S = '' then
        Continue;
      if JBool(Item, 'thought') then
        AResponse.Add(ReasoningPart(S, JStr(Item, 'thoughtSignature')))
      else
        AResponse.Add(TextPart(S));
    end;
  end;
end;

function ParseVertexResponse(AJSON: TJSONData; const ARaw: string): TLLMResponse;
var
  Candidate: TJSONData;
  ToolIndex: Integer;
begin
  Result := TLLMResponse.Create;
  try
    Result.Provider := 'vertex';
    Result.Raw := ARaw;
    Result.ID := JStr(AJSON, 'responseId');
    Result.Model := JStr(AJSON, 'modelVersion');
    Result.Usage := ParseVertexUsage(AJSON);
    Candidate := JGet(AJSON, 'candidates.0');
    if Candidate = nil then
      Exit;
    Result.FinishReason := ParseFinishReason(JStr(Candidate, 'finishReason'));
    ToolIndex := 0;
    AddVertexParts(Result, JArray(Candidate, 'content.parts'), ToolIndex);
    if Result.HasToolCalls then
      Result.FinishReason := frToolCalls;
  except
    Result.Free;
    raise;
  end;
end;

{ TVertexClient }

constructor TVertexClient.Create(const AModel: string; ACaps: TCapabilities;
  ATransport: TTransport; const AProject, ALocation: string);
begin
  inherited Create('vertex', AModel, ACaps, ATransport);
  FProject := AProject;
  FLocation := ALocation;
end;

function TVertexClient.ModelPath(const AMethod: string): string;
begin
  Result := Format('/projects/%s/locations/%s/publishers/google/models/%s:%s',
    [FProject, FLocation, FModel, AMethod]);
end;

function TVertexClient.BuildContents(ARequest: TLLMRequest): TJSONArray;
var
  I, J: Integer;
  Msg: TLLMMessage;
  Part: TLLMPart;
  Parts: TJSONArray;
  Obj: TJSONObject;
  Args: TJSONData;
begin
  Result := TJSONArray.Create;
  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    if Msg.Role = lrSystem then
      Continue;
    Parts := TJSONArray.Create;
    for J := 0 to Msg.Parts.Count - 1 do
    begin
      Part := Msg.Parts[J];
      case Part.Kind of
        pkText:
          Parts.Add(TJSONObject.Create(['text', Part.Text]));
        pkReasoning:
          if Part.Text <> '' then
          begin
            Obj := TJSONObject.Create(['text', Part.Text, 'thought', True]);
            JSetStr(Obj, 'thoughtSignature', Part.Signature);
            Parts.Add(Obj);
          end;
        pkImage, pkAudio, pkFile:
          begin
            if Part.URL <> '' then
              Parts.Add(TJSONObject.Create(['fileData', TJSONObject.Create([
                'mimeType', Part.MimeType, 'fileUri', Part.URL])]))
            else
              Parts.Add(TJSONObject.Create(['inlineData', TJSONObject.Create([
                'mimeType', Part.MimeType,
                'data', Base64FromBytes(Part.Data)])]));
          end;
        pkToolCall:
          begin
            Obj := TJSONObject.Create(['name', Part.Name]);
            if Part.Arguments <> '' then
              JSetRaw(Obj, 'args', Part.Arguments)
            else
              Obj.Add('args', TJSONObject.Create);
            Parts.Add(TJSONObject.Create(['functionCall', Obj]));
          end;
        pkToolResult:
          begin
            Obj := TJSONObject.Create(['name', Part.Name]);
            Args := TryParseJSON(Part.Text);
            if (Args <> nil) and (Args.JSONType = jtObject) then
              Obj.Add('response', Args)
            else
            begin
              Args.Free;
              Obj.Add('response', TJSONObject.Create(['result', Part.Text]));
            end;
            Parts.Add(TJSONObject.Create(['functionResponse', Obj]));
          end;
      end;
    end;
    if Parts.Count = 0 then
    begin
      Parts.Free;
      Continue;
    end;
    if Msg.Role = lrAssistant then
      Result.Add(TJSONObject.Create(['role', 'model', 'parts', Parts]))
    else
      Result.Add(TJSONObject.Create(['role', 'user', 'parts', Parts]));
  end;
end;

function TVertexClient.BuildTools(ARequest: TLLMRequest): TJSONArray;
var
  I: Integer;
  Decls: TJSONArray;
  Obj: TJSONObject;
  Tool: TLLMTool;
begin
  Decls := TJSONArray.Create;
  for I := 0 to ARequest.Tools.Count - 1 do
  begin
    Tool := ARequest.Tools[I];
    Obj := TJSONObject.Create(['name', Tool.Name]);
    JSetStr(Obj, 'description', Tool.Description);
    if Tool.Parameters <> '' then
      JSetRaw(Obj, 'parameters', Tool.Parameters);
    Decls.Add(Obj);
  end;
  Result := TJSONArray.Create;
  Result.Add(TJSONObject.Create(['functionDeclarations', Decls]));
end;

function TVertexClient.BuildBody(ARequest: TLLMRequest): TJSONObject;
var
  GenConfig, Thinking, Mode: TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('contents', BuildContents(ARequest));
    if ARequest.SystemPrompt <> '' then
      Result.Add('systemInstruction', TJSONObject.Create(['parts',
        TJSONArray.Create([TJSONObject.Create(['text',
          ARequest.SystemPrompt])])]));
    if ARequest.Tools.Count > 0 then
    begin
      Result.Add('tools', BuildTools(ARequest));
      if ARequest.ToolChoice <> '' then
      begin
        if ARequest.ToolChoice = 'auto' then
          Mode := TJSONObject.Create(['mode', 'AUTO'])
        else if ARequest.ToolChoice = 'none' then
          Mode := TJSONObject.Create(['mode', 'NONE'])
        else if ARequest.ToolChoice = 'required' then
          Mode := TJSONObject.Create(['mode', 'ANY'])
        else
          Mode := TJSONObject.Create(['mode', 'ANY',
            'allowedFunctionNames', TJSONArray.Create([ARequest.ToolChoice])]);
        Result.Add('toolConfig', TJSONObject.Create(['functionCallingConfig',
          Mode]));
      end;
    end;
    GenConfig := TJSONObject.Create;
    JSetOpt(GenConfig, 'temperature', ARequest.Temperature);
    JSetOpt(GenConfig, 'topP', ARequest.TopP);
    JSetOpt(GenConfig, 'seed', ARequest.Seed);
    if ARequest.MaxTokens.HasValue then
      GenConfig.Add('maxOutputTokens', ARequest.MaxTokens.Value);
    if Length(ARequest.Stop) > 0 then
      GenConfig.Add('stopSequences', JStrings(ARequest.Stop));
    if ARequest.ResponseFormat = 'json_object' then
      GenConfig.Add('responseMimeType', 'application/json')
    else if ARequest.ResponseFormat <> '' then
    begin
      GenConfig.Add('responseMimeType', 'application/json');
      JSetRaw(GenConfig, 'responseSchema', ARequest.ResponseFormat);
    end;
    if ARequest.Reasoning.Enabled then
    begin
      Thinking := TJSONObject.Create;
      if ARequest.Reasoning.BudgetTokens > 0 then
        Thinking.Add('thinkingBudget', ARequest.Reasoning.BudgetTokens)
      else if ARequest.Reasoning.Effort = 'low' then
        Thinking.Add('thinkingBudget', 2048)
      else if ARequest.Reasoning.Effort = 'high' then
        Thinking.Add('thinkingBudget', 24576);
      if (ARequest.Reasoning.Summary <> '') and
         (ARequest.Reasoning.Summary <> 'omitted') then
        Thinking.Add('includeThoughts', True);
      GenConfig.Add('thinkingConfig', Thinking);
    end;
    if GenConfig.Count > 0 then
      Result.Add('generationConfig', GenConfig)
    else
      GenConfig.Free;
    ApplyExtras(Result, ARequest, 'vertex');
  except
    Result.Free;
    raise;
  end;
end;

function TVertexClient.Chat(ARequest: TLLMRequest): TLLMResponse;
var
  Body: TJSONObject;
  Text: string;
  Data: TJSONData;
begin
  Need(capChat, 'chat');
  CheckParts(ARequest);
  CheckTools(ARequest);
  Body := BuildBody(ARequest);
  try
    Text := FTransport.PostJSONText(ModelPath('generateContent'), CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := ParseVertexResponse(Data, Text);
  finally
    Data.Free;
  end;
end;

function TVertexClient.HandleEvent(const AEvent: TSSEEvent): Boolean;
var
  Data: TJSONData;
  Chunk: TLLMChunk;
  Parts: TJSONArray;
  Item, Args: TJSONData;
  I: Integer;
  S: string;
  U: TUsage;
begin
  Result := True;
  if AEvent.Data = '' then
    Exit;
  Data := TryParseJSON(AEvent.Data);
  if Data = nil then
    Exit;
  try
    Parts := JArray(Data, 'candidates.0.content.parts');
    if Parts <> nil then
      for I := 0 to Parts.Count - 1 do
      begin
        Item := Parts.Items[I];
        Chunk := Default(TLLMChunk);
        Chunk.Raw := AEvent.Data;
        if JHas(Item, 'functionCall') then
        begin
          Args := JGet(Item, 'functionCall.args');
          Inc(FToolIndex);
          Chunk.Kind := ckToolCall;
          Chunk.Index := FToolIndex - 1;
          Chunk.ToolCallID := Format('call_%d', [FToolIndex]);
          Chunk.ToolName := JStr(Item, 'functionCall.name');
          if Args <> nil then
            Chunk.ArgumentsDelta := CompactJSON(Args);
          if not FOnChunk(Chunk) then
            Exit(False);
          Continue;
        end;
        S := JStr(Item, 'text');
        if S = '' then
          Continue;
        if JBool(Item, 'thought') then
          Chunk.Kind := ckReasoning
        else
          Chunk.Kind := ckText;
        Chunk.Text := S;
        Chunk.Signature := JStr(Item, 'thoughtSignature');
        if not FOnChunk(Chunk) then
          Exit(False);
      end;
    U := ParseVertexUsage(Data);
    S := JStr(Data, 'candidates.0.finishReason');
    if (S <> '') or (U.InputTokens + U.OutputTokens > 0) then
    begin
      Chunk := Default(TLLMChunk);
      Chunk.Raw := AEvent.Data;
      Chunk.Kind := ckFinish;
      Chunk.FinishReason := ParseFinishReason(S);
      Chunk.Usage := U;
      Result := FOnChunk(Chunk);
    end;
  finally
    Data.Free;
  end;
end;

function TVertexClient.Stream(ARequest: TLLMRequest;
  AOnChunk: TChunkEvent): Boolean;
var
  Body: TJSONObject;
begin
  Need(capStream, 'streaming');
  CheckParts(ARequest);
  CheckTools(ARequest);
  FOnChunk := AOnChunk;
  FToolIndex := 0;
  Body := BuildBody(ARequest);
  try
    Result := FTransport.PostSSE(ModelPath('streamGenerateContent') + '?alt=sse',
      Body, @HandleEvent);
  finally
    Body.Free;
  end;
end;

function TVertexClient.CountTokens(ARequest: TLLMRequest): Integer;
var
  Body, Payload: TJSONObject;
  Data: TJSONData;
begin
  Need(capCountTokens, 'token counting');
  Body := BuildBody(ARequest);
  try
    Payload := TJSONObject.Create;
    try
      Payload.Add('contents', Body.Extract('contents'));
      Data := FTransport.PostJSON(ModelPath('countTokens'), Payload);
    finally
      Payload.Free;
    end;
  finally
    Body.Free;
  end;
  try
    Result := JInt(Data, 'totalTokens');
  finally
    Data.Free;
  end;
end;

function TVertexClient.Embed(ARequest: TEmbedRequest): TEmbedResponse;
var
  Body: TJSONObject;
  Instances: TJSONArray;
  Instance, Params: TJSONObject;
  Text, TaskType: string;
  Data: TJSONData;
  Items: TJSONArray;
  I: Integer;
begin
  Need(capEmbed, 'embeddings');
  case ARequest.InputType of
    eiQuery: TaskType := 'RETRIEVAL_QUERY';
    eiDocument: TaskType := 'RETRIEVAL_DOCUMENT';
  else
    TaskType := '';
  end;
  Body := TJSONObject.Create;
  try
    Instances := TJSONArray.Create;
    for I := 0 to High(ARequest.Inputs) do
    begin
      Instance := TJSONObject.Create(['content', ARequest.Inputs[I]]);
      JSetStr(Instance, 'task_type', TaskType);
      Instances.Add(Instance);
    end;
    Body.Add('instances', Instances);
    if ARequest.Dimensions.HasValue then
    begin
      Params := TJSONObject.Create(['outputDimensionality',
        ARequest.Dimensions.Value]);
      Body.Add('parameters', Params);
    end;
    Text := FTransport.PostJSONText(ModelPath('predict'), CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TEmbedResponse.Create;
    Result.Provider := 'vertex';
    Result.Model := FModel;
    Result.Raw := Text;
    Items := JArray(Data, 'predictions');
    if Items <> nil then
    begin
      SetLength(Result.Embeddings, Items.Count);
      for I := 0 to Items.Count - 1 do
      begin
        Result.Embeddings[I] := FloatsFrom(
          JArray(Items.Items[I], 'embeddings.values'));
        Inc(Result.Usage.InputTokens,
          JInt(Items.Items[I], 'embeddings.statistics.token_count'));
      end;
    end;
  finally
    Data.Free;
  end;
end;

{ TVertexProvider }

function TVertexProvider.ID: string;
begin
  Result := 'vertex';
end;

function TVertexProvider.Aliases: TStringArray;
begin
  Result := StringArrayOf(['google', 'gemini']);
end;

function TVertexProvider.Matches(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'gemini-');
end;

function TVertexProvider.Capabilities(const AModel: string): TCapabilities;
begin
  if IsVertexEmbeddingModel(AModel) then
    Exit([capEmbed]);
  Result := [capChat, capStream, capTools, capImages, capAudio, capFiles,
             capReasoning, capCountTokens];
end;

function TVertexProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
var
  Cfg: TCompatConfig;
  Project, Location, Model: string;
begin
  Project := AOptions.Project;
  if Project = '' then
    Project := EnvOr('GOOGLE_CLOUD_PROJECT', '');
  if Project = '' then
    raise ELLMInvalidRequest.Create(
      'vertex needs a project: set GOOGLE_CLOUD_PROJECT or use WithProject');
  Location := AOptions.Location;
  if Location = '' then
    Location := EnvOr('GOOGLE_CLOUD_LOCATION', VertexDefaultLocation);

  Cfg := TCompatConfig.New('vertex',
    Format('https://%s-aiplatform.googleapis.com/v1', [Location]));
  Cfg.EnvKeys := StringArrayOf(['GOOGLE_ACCESS_TOKEN', 'GCLOUD_ACCESS_TOKEN']);
  { Vertex model ids may carry an @version suffix; keep it for the URL. }
  Model := AModel;
  Result := TVertexClient.Create(Model, Capabilities(AModel),
    CompatTransport(Cfg, AOptions), Project, Location);
end;

end.
