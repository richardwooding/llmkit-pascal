{ llmkit - command line front end.

    llmkit chat -m claude-sonnet-4-5 "Explain iterators in one paragraph"
    echo "Summarise this" | llmkit chat -m llama3.2:3b --stream
    llmkit embed -m voyage-3-large "first" "second"
    llmkit rerank -m rerank-v3.5 -q "go iterators" doc1 doc2
    llmkit count -m claude-opus-4-1 "how long is this?"
    llmkit resolve gpt-5 openrouter/openai/gpt-4o meta-llama/Llama-3.3-70B
    llmkit models claude
}
program llmkit;

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math,
  LLMKit.Core, LLMKit.Registry, LLMKit.Providers, LLMKit.Stream,
  LLMKit.Catalog;

type
  TOptions = record
    Model: string;
    System: string;
    Query: string;
    Stream: Boolean;
    JSONOut: Boolean;
    Reasoning: Boolean;
    Verbose: Boolean;
    Temperature: TOptFloat;
    MaxTokens: TOptInt;
    Args: TStringList;
  end;

  TPrinter = class
    function OnChunk(const AChunk: TLLMChunk): Boolean;
  end;

var
  Opts: TOptions;

function TPrinter.OnChunk(const AChunk: TLLMChunk): Boolean;
begin
  case AChunk.Kind of
    ckText:
      Write(AChunk.Text);
    ckReasoning:
      if Opts.Reasoning then
        Write(StdErr, AChunk.Text);
    ckFinish:
      if Opts.Verbose and (AChunk.Usage.TotalTokens > 0) then
        WriteLn(StdErr, Format(#10'[%d in, %d out]',
          [AChunk.Usage.InputTokens, AChunk.Usage.OutputTokens]));
  end;
  Flush(Output);
  Result := True;
end;

procedure Usage;
begin
  WriteLn('llmkit ', LLMKitVersion, ' - one client for many AI back-ends');
  WriteLn;
  WriteLn('usage: llmkit <command> [options] [arguments]');
  WriteLn;
  WriteLn('commands:');
  WriteLn('  chat     -m MODEL [prompt]     chat, or read the prompt from stdin');
  WriteLn('  embed    -m MODEL text...      embed one or more inputs');
  WriteLn('  rerank   -m MODEL -q QUERY doc...');
  WriteLn('  count    -m MODEL [prompt]     count prompt tokens (Anthropic)');
  WriteLn('  resolve  name...               show provider routing');
  WriteLn('  models   [filter]              show the model catalog');
  WriteLn('  version');
  WriteLn;
  WriteLn('options:');
  WriteLn('  -m, --model NAME    model name, with an optional provider prefix');
  WriteLn('  -s, --system TEXT   system prompt');
  WriteLn('  -q, --query TEXT    rerank query');
  WriteLn('      --stream        stream the reply as it arrives');
  WriteLn('      --think         ask for reasoning and show it on stderr');
  WriteLn('      --json          ask for a JSON object reply');
  WriteLn('  -t, --temperature F');
  WriteLn('  -n, --max-tokens N');
  WriteLn('  -v, --verbose       report token usage on stderr');
  WriteLn;
  WriteLn('keys come from the usual environment variables:');
  WriteLn('  OPENAI_API_KEY, ANTHROPIC_API_KEY, DEEPSEEK_API_KEY, GROQ_API_KEY,');
  WriteLn('  XAI_API_KEY, COHERE_API_KEY, VOYAGE_API_KEY, OPENROUTER_API_KEY,');
  WriteLn('  HF_TOKEN, OLLAMA_HOST, GOOGLE_ACCESS_TOKEN + GOOGLE_CLOUD_PROJECT');
end;

function ReadStdIn: string;
var
  Line: string;
begin
  Result := '';
  while not EOF(Input) do
  begin
    ReadLn(Input, Line);
    if Result <> '' then
      Result := Result + LineEnding;
    Result := Result + Line;
  end;
end;

function PromptFrom(AArgs: TStringList): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to AArgs.Count - 1 do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + AArgs[I];
  end;
  if Trim(Result) = '' then
    Result := ReadStdIn;
end;

function ParseArgs(out ACommand: string): Boolean;
var
  I: Integer;
  Arg: string;

  function Next(const AName: string): string;
  begin
    Inc(I);
    if I > ParamCount then
      raise ELLMInvalidRequest.CreateFmt('%s needs a value', [AName]);
    Result := ParamStr(I);
  end;

begin
  Opts := Default(TOptions);
  Opts.Args := TStringList.Create;
  ACommand := '';
  I := 1;
  while I <= ParamCount do
  begin
    Arg := ParamStr(I);
    if (Arg = '-m') or (Arg = '--model') then
      Opts.Model := Next(Arg)
    else if (Arg = '-s') or (Arg = '--system') then
      Opts.System := Next(Arg)
    else if (Arg = '-q') or (Arg = '--query') then
      Opts.Query := Next(Arg)
    else if (Arg = '-t') or (Arg = '--temperature') then
      Opts.Temperature := OptFloat(StrToFloat(Next(Arg)))
    else if (Arg = '-n') or (Arg = '--max-tokens') then
      Opts.MaxTokens := OptInt(StrToInt(Next(Arg)))
    else if Arg = '--stream' then
      Opts.Stream := True
    else if Arg = '--think' then
      Opts.Reasoning := True
    else if Arg = '--json' then
      Opts.JSONOut := True
    else if (Arg = '-v') or (Arg = '--verbose') then
      Opts.Verbose := True
    else if (Arg = '-h') or (Arg = '--help') then
    begin
      Usage;
      Exit(False);
    end
    else if ACommand = '' then
      ACommand := Arg
    else
      Opts.Args.Add(Arg);
    Inc(I);
  end;
  if ACommand = '' then
  begin
    Usage;
    Exit(False);
  end;
  Result := True;
end;

procedure RequireModel;
begin
  if Opts.Model = '' then
  begin
    Opts.Model := GetEnvironmentVariable('LLMKIT_MODEL');
    if Opts.Model = '' then
      raise ELLMInvalidRequest.Create('no model: pass -m or set LLMKIT_MODEL');
  end;
end;

function NewRequest: TLLMRequest;
begin
  Result := TLLMRequest.Create(Opts.Model);
  Result.SystemPrompt := Opts.System;
  Result.Temperature := Opts.Temperature;
  Result.MaxTokens := Opts.MaxTokens;
  if Opts.JSONOut then
    Result.ResponseFormat := 'json_object';
  if Opts.Reasoning then
  begin
    Result.Reasoning.Enabled := True;
    Result.Reasoning.Effort := 'medium';
    Result.Reasoning.Summary := 'auto';
  end;
end;

procedure ReportUsage(const AUsage: TUsage; const AModel: string);
var
  Info: TModelInfo;
begin
  if not Opts.Verbose then
    Exit;
  Info := Lookup(AModel);
  Write(StdErr, Format('[%d in (%d cached), %d out',
    [AUsage.InputTokens, AUsage.CachedInputTokens, AUsage.OutputTokens]));
  if Info.Known and (Info.Cost(AUsage) > 0) then
    Write(StdErr, ', ', Info.CostString(AUsage));
  WriteLn(StdErr, ']');
end;

procedure CmdChat;
var
  Req: TLLMRequest;
  Resp: TLLMResponse;
  Printer: TPrinter;
  Streamer: IStreamer;
  Chatter: IChatter;
begin
  RequireModel;
  Req := NewRequest;
  Printer := TPrinter.Create;
  try
    Req.Add(UserText(PromptFrom(Opts.Args)));
    if Opts.Stream then
    begin
      Streamer := OpenStreamer(Opts.Model);
      Resp := Collect(Streamer, Req, @Printer.OnChunk);
    end
    else
    begin
      Chatter := OpenChatter(Opts.Model);
      Resp := Chatter.Chat(Req);
      if Opts.Reasoning and (Resp.ReasoningText <> '') then
        WriteLn(StdErr, Resp.ReasoningText);
      Write(Resp.Text);
    end;
    try
      if (Resp.Text <> '') and (Resp.Text[Length(Resp.Text)] <> #10) then
        WriteLn;
      ReportUsage(Resp.Usage, Opts.Model);
    finally
      Resp.Free;
    end;
  finally
    Printer.Free;
    Req.Free;
  end;
end;

procedure CmdEmbed;
var
  Embedder: IEmbedder;
  Req: TEmbedRequest;
  Resp: TEmbedResponse;
  I, J, Shown: Integer;
  Line: string;
begin
  RequireModel;
  if Opts.Args.Count = 0 then
    Opts.Args.Add(ReadStdIn);
  Embedder := OpenEmbedder(Opts.Model);
  Req := TEmbedRequest.Create;
  try
    Req.Model := Opts.Model;
    SetLength(Req.Inputs, Opts.Args.Count);
    for I := 0 to Opts.Args.Count - 1 do
      Req.Inputs[I] := Opts.Args[I];
    Resp := Embedder.Embed(Req);
    try
      for I := 0 to Resp.Count - 1 do
      begin
        Line := '';
        Shown := Min(8, Length(Resp.Embeddings[I]));
        for J := 0 to Shown - 1 do
        begin
          if Line <> '' then
            Line := Line + ', ';
          Line := Line + FormatFloat('0.0000', Resp.Embeddings[I][J]);
        end;
        WriteLn(Format('[%d] dim=%d  [%s%s]',
          [I, Length(Resp.Embeddings[I]), Line,
           specialize IfThen<string>(Shown < Length(Resp.Embeddings[I]),
             ', ...', '')]));
      end;
      ReportUsage(Resp.Usage, Opts.Model);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure CmdRerank;
var
  Reranker: IReranker;
  Req: TRerankRequest;
  Resp: TRerankResponse;
  I: Integer;
begin
  RequireModel;
  if Opts.Query = '' then
    raise ELLMInvalidRequest.Create('rerank needs -q QUERY');
  if Opts.Args.Count = 0 then
    raise ELLMInvalidRequest.Create('rerank needs documents');
  Reranker := OpenReranker(Opts.Model);
  Req := TRerankRequest.Create;
  try
    Req.Model := Opts.Model;
    Req.Query := Opts.Query;
    SetLength(Req.Documents, Opts.Args.Count);
    for I := 0 to Opts.Args.Count - 1 do
      Req.Documents[I] := Opts.Args[I];
    Resp := Reranker.Rerank(Req);
    try
      for I := 0 to Resp.Count - 1 do
        WriteLn(Format('%.4f  [%d] %s', [Resp.Results[I].Score,
          Resp.Results[I].Index, Resp.Results[I].Document]));
      ReportUsage(Resp.Usage, Opts.Model);
    finally
      Resp.Free;
    end;
  finally
    Req.Free;
  end;
end;

procedure CmdCount;
var
  Counter: ITokenCounter;
  Req: TLLMRequest;
begin
  RequireModel;
  Counter := OpenTokenCounter(Opts.Model);
  Req := NewRequest;
  try
    Req.Add(UserText(PromptFrom(Opts.Args)));
    WriteLn(Counter.CountTokens(Req));
  finally
    Req.Free;
  end;
end;

procedure CmdResolve;
var
  I: Integer;
  R: TResolution;
  Info: TModelInfo;
begin
  if Opts.Args.Count = 0 then
    raise ELLMInvalidRequest.Create('resolve needs at least one name');
  for I := 0 to Opts.Args.Count - 1 do
  begin
    R := Resolve(Opts.Args[I]);
    Info := Lookup(Opts.Args[I]);
    Write(Format('%-40s -> %-12s %-30s %s',
      [Opts.Args[I], R.ProviderID, R.Model,
       CapabilitiesToString(R.Provider.Capabilities(R.Model))]));
    if Info.Known then
      Write(Format('  (ctx %d, $%.2f/$%.2f per Mtok)',
        [Info.ContextWindow, Info.InputCost, Info.OutputCost]));
    WriteLn;
  end;
end;

procedure CmdModels;
var
  I: Integer;
  Info: TModelInfo;
  Filter: string;
begin
  Filter := '';
  if Opts.Args.Count > 0 then
    Filter := LowerCase(Opts.Args[0]);
  WriteLn(Format('%-28s %-10s %10s %10s %8s %8s',
    ['MODEL', 'PROVIDER', 'CONTEXT', 'MAX OUT', 'IN/M$', 'OUT/M$']));
  for I := 0 to CatalogCount - 1 do
  begin
    Info := CatalogEntry(I);
    if (Filter <> '') and (Pos(Filter, Info.Name) = 0) and
       (Pos(Filter, Info.Provider) = 0) then
      Continue;
    WriteLn(Format('%-28s %-10s %10d %10d %8.4f %8.4f',
      [Info.Name, Info.Provider, Info.ContextWindow, Info.MaxOutput,
       Info.InputCost, Info.OutputCost]));
  end;
  WriteLn;
  WriteLn('list prices as of ', CatalogDataAsOf, '; verify before billing');
end;

var
  Command: string;
  ExitStatus: Integer;

begin
  ExitStatus := 0;
  try
    if not ParseArgs(Command) then
      Halt(0);
    try
      Command := LowerCase(Command);
      if Command = 'chat' then
        CmdChat
      else if Command = 'embed' then
        CmdEmbed
      else if Command = 'rerank' then
        CmdRerank
      else if Command = 'count' then
        CmdCount
      else if Command = 'resolve' then
        CmdResolve
      else if Command = 'models' then
        CmdModels
      else if (Command = 'version') or (Command = '--version') then
        WriteLn('llmkit-pascal ', LLMKitVersion)
      else
      begin
        WriteLn(StdErr, 'unknown command: ', Command);
        Usage;
        ExitStatus := 2;
      end;
    finally
      Opts.Args.Free;
    end;
  except
    on E: EAPIError do
    begin
      WriteLn(StdErr, Format('error: %s (%s)',
        [E.Message, ErrorKindToString(E.Kind)]));
      if E.RetryAfter > 0 then
        WriteLn(StdErr, Format('retry after %d seconds', [E.RetryAfter]));
      ExitStatus := 1;
    end;
    on E: ELLMError do
    begin
      WriteLn(StdErr, 'error: ', E.Message);
      ExitStatus := 1;
    end;
    on E: Exception do
    begin
      WriteLn(StdErr, E.ClassName, ': ', E.Message);
      ExitStatus := 1;
    end;
  end;
  Halt(ExitStatus);
end.
