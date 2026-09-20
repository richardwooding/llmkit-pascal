{ A private OpenAI-compatible endpoint (vLLM, LM Studio, llama.cpp, ...)
  registered as a first-class provider, plus embeddings and reranking.

    ./custom_endpoint http://gpu-box:8000/v1
}
program custom_endpoint;

{$mode objfpc}{$H+}

uses
  SysUtils, LLMKit, LLMKit.Provider.OpenAICompat;

var
  Cfg: TCompatConfig;
  Chat: IChatter;
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Embedder: IEmbedder;
  EmbedReq: TEmbedRequest;
  EmbedResp: TEmbedResponse;
  BaseURL: string;

begin
  BaseURL := ParamStr(1);
  if BaseURL = '' then
    BaseURL := 'http://localhost:8000/v1';

  Cfg := TCompatConfig.New('vllm', BaseURL);
  Cfg.KeyOptional := True;          { no API key on a private box }
  Cfg.Quirks.Images := True;        { this deployment accepts images }
  Cfg.Quirks.Embeddings := True;
  RegisterProvider(TOpenAICompatProvider.Create(Cfg));

  Chat := OpenChatter('vllm/my-finetune');
  Req := TLLMRequest.Create;
  try
    Req.Add(UserText('Say hello.'));
    Resp := Chat.Chat(Req);
    try
      WriteLn(Resp.Text);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;

  { Anything the registry can route also works with the other capabilities. }
  Embedder := OpenEmbedder('vllm/my-embedder');
  EmbedReq := TEmbedRequest.Create('my-embedder', ['first', 'second']);
  try
    EmbedResp := Embedder.Embed(EmbedReq);
    try
      WriteLn(Format('%d vectors of %d dimensions',
        [EmbedResp.Count, EmbedResp.Dimensions]));
    finally
      EmbedResp.Free;
    end;
  finally
    EmbedReq.Free;
  end;
end.
