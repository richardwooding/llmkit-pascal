{ LLMKit.Provider.Voyage - VoyageAI embeddings and reranking.

  No chat: Open[Chatter] on a voyage-* model fails with ELLMUnsupported.
  Key: VOYAGE_API_KEY.
}
unit LLMKit.Provider.Voyage;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson, LLMKit.Core, LLMKit.JSONUtil, LLMKit.HTTP,
  LLMKit.Registry, LLMKit.Client, LLMKit.Provider.OpenAICompat;

const
  VoyageDefaultBaseURL = 'https://api.voyageai.com/v1';

type
  TVoyageClient = class(TLLMClientBase, IEmbedder, IReranker)
  public
    function Embed(ARequest: TEmbedRequest): TEmbedResponse;
    function Rerank(ARequest: TRerankRequest): TRerankResponse;
  end;

  TVoyageProvider = class(TLLMProvider)
  public
    function ID: string; override;
    function Matches(const AModel: string): Boolean; override;
    function Capabilities(const AModel: string): TCapabilities; override;
    function NewClient(const AModel: string;
      const AOptions: TClientOptions): ILLMClient; override;
  end;

function IsVoyageRerankModel(const AModel: string): Boolean;

implementation

function IsVoyageRerankModel(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'rerank-');
end;

{ TVoyageClient }

function TVoyageClient.Embed(ARequest: TEmbedRequest): TEmbedResponse;
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
    case ARequest.InputType of
      eiQuery: Body.Add('input_type', 'query');
      eiDocument: Body.Add('input_type', 'document');
    end;
    if ARequest.Dimensions.HasValue then
      Body.Add('output_dimension', ARequest.Dimensions.Value);
    if ARequest.Truncate.HasValue then
      Body.Add('truncation', ARequest.Truncate.Value);
    Text := FTransport.PostJSONText('/embeddings', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TEmbedResponse.Create;
    Result.Provider := 'voyage';
    Result.Model := JStr(Data, 'model', FModel);
    Result.Raw := Text;
    Result.Usage.InputTokens := JInt(Data, 'usage.total_tokens');
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

function TVoyageClient.Rerank(ARequest: TRerankRequest): TRerankResponse;
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
    if ARequest.TopN.HasValue then
      Body.Add('top_k', ARequest.TopN.Value);
    Text := FTransport.PostJSONText('/rerank', CompactJSON(Body));
  finally
    Body.Free;
  end;
  Data := ParseJSON(Text);
  try
    Result := TRerankResponse.Create;
    Result.Provider := 'voyage';
    Result.Model := JStr(Data, 'model', FModel);
    Result.Raw := Text;
    Result.Usage.InputTokens := JInt(Data, 'usage.total_tokens');
    Items := JArray(Data, 'data');
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

{ TVoyageProvider }

function TVoyageProvider.ID: string;
begin
  Result := 'voyage';
end;

function TVoyageProvider.Matches(const AModel: string): Boolean;
begin
  Result := HasPrefix(AModel, 'voyage-');
end;

function TVoyageProvider.Capabilities(const AModel: string): TCapabilities;
begin
  if IsVoyageRerankModel(AModel) then
    Exit([capRerank]);
  Result := [capEmbed];
end;

function TVoyageProvider.NewClient(const AModel: string;
  const AOptions: TClientOptions): ILLMClient;
var
  Cfg: TCompatConfig;
begin
  Cfg := TCompatConfig.New('voyage', VoyageDefaultBaseURL);
  Cfg.EnvKeys := StringArrayOf(['VOYAGE_API_KEY']);
  Result := TVoyageClient.Create('voyage', AModel, Capabilities(AModel),
    CompatTransport(Cfg, AOptions));
end;

end.
