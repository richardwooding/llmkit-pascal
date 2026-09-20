{ LLMKit.JSONUtil - small helpers over fpjson.

  Every lookup is nil-safe and type-safe: a missing or wrongly typed field
  yields the default instead of raising, which keeps provider decoders short.
}
unit LLMKit.JSONUtil;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, base64, fpjson, jsonparser, jsonscanner, LLMKit.Core;

{ --- reading --- }
function JGet(AObj: TJSONData; const APath: string): TJSONData;
function JStr(AObj: TJSONData; const APath: string; const ADefault: string = ''): string;
function JInt(AObj: TJSONData; const APath: string; ADefault: Integer = 0): Integer;
function JFloat(AObj: TJSONData; const APath: string; ADefault: Double = 0): Double;
function JBool(AObj: TJSONData; const APath: string; ADefault: Boolean = False): Boolean;
function JArray(AObj: TJSONData; const APath: string): TJSONArray;
function JObject(AObj: TJSONData; const APath: string): TJSONObject;
function JHas(AObj: TJSONData; const APath: string): Boolean;
{ Parses text into JSON; raises ELLMError with a readable message on failure. }
function ParseJSON(const AText: string): TJSONData;
function ParseJSONObject(const AText: string): TJSONObject;
{ Parses AText and returns nil instead of raising. Caller owns the result. }
function TryParseJSON(const AText: string): TJSONData;
{ Serialises without fpjson's default padding: wire bodies stay compact and
  byte-comparable. The global CompressedJSON flag is restored afterwards so
  the host application's formatting is untouched. }
function CompactJSON(AData: TJSONData): string;
function FloatsFrom(AArray: TJSONArray): TFloatArray;

{ --- writing --- }
procedure JSetOpt(AObj: TJSONObject; const AName: string; const AValue: TOptFloat);
procedure JSetOpt(AObj: TJSONObject; const AName: string; const AValue: TOptInt);
procedure JSetOpt(AObj: TJSONObject; const AName: string; const AValue: TOptBool);
procedure JSetStr(AObj: TJSONObject; const AName, AValue: string);
function JStrings(const AValues: TStringArray): TJSONArray;
{ Adds the raw JSON text AValue under AName; invalid text is stored as string. }
procedure JSetRaw(AObj: TJSONObject; const AName, AJSONText: string);
{ Copies every member of ASource into ATarget, replacing existing names. }
procedure JMerge(ATarget, ASource: TJSONObject);
{ Merges Request.Extra and Request.ProviderOptions[AProviderID] into ABody. }
procedure ApplyExtras(ABody: TJSONObject; ARequest: TLLMRequest;
  const AProviderID: string);

{ --- misc --- }
function Base64FromBytes(const AData: TBytes): string;
function BytesFromBase64(const AText: string): TBytes;
function DataURL(const AData: TBytes; const AMimeType: string): string;
function BytesToString(const AData: TBytes): string;
function StringToBytes(const AText: string): TBytes;

implementation

function SplitPath(const APath: string; out AHead, ATail: string): Boolean;
var
  P: Integer;
begin
  P := Pos('.', APath);
  if P = 0 then
  begin
    AHead := APath;
    ATail := '';
  end
  else
  begin
    AHead := Copy(APath, 1, P - 1);
    ATail := Copy(APath, P + 1, MaxInt);
  end;
  Result := AHead <> '';
end;

function JGet(AObj: TJSONData; const APath: string): TJSONData;
var
  Head, Tail: string;
  Idx: Integer;
  Cur: TJSONData;
begin
  Result := nil;
  if AObj = nil then
    Exit;
  if APath = '' then
    Exit(AObj);
  if not SplitPath(APath, Head, Tail) then
    Exit;
  Cur := nil;
  if (AObj.JSONType = jtObject) then
  begin
    Idx := TJSONObject(AObj).IndexOfName(Head);
    if Idx >= 0 then
      Cur := TJSONObject(AObj).Items[Idx];
  end
  else if AObj.JSONType = jtArray then
  begin
    if TryStrToInt(Head, Idx) and (Idx >= 0) and (Idx < TJSONArray(AObj).Count) then
      Cur := TJSONArray(AObj).Items[Idx];
  end;
  if Cur = nil then
    Exit;
  if Tail = '' then
    Result := Cur
  else
    Result := JGet(Cur, Tail);
end;

function JHas(AObj: TJSONData; const APath: string): Boolean;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  Result := (D <> nil) and (D.JSONType <> jtNull);
end;

function JStr(AObj: TJSONData; const APath: string; const ADefault: string): string;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  if (D = nil) or (D.JSONType in [jtNull, jtArray, jtObject]) then
    Result := ADefault
  else
    Result := D.AsString;
end;

function JInt(AObj: TJSONData; const APath: string; ADefault: Integer): Integer;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  if (D = nil) or not (D.JSONType in [jtNumber, jtBoolean]) then
    Result := ADefault
  else
    Result := D.AsInteger;
end;

function JFloat(AObj: TJSONData; const APath: string; ADefault: Double): Double;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  if (D = nil) or not (D.JSONType in [jtNumber, jtBoolean]) then
    Result := ADefault
  else
    Result := D.AsFloat;
end;

function JBool(AObj: TJSONData; const APath: string; ADefault: Boolean): Boolean;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  if (D = nil) or not (D.JSONType in [jtNumber, jtBoolean]) then
    Result := ADefault
  else
    Result := D.AsBoolean;
end;

function JArray(AObj: TJSONData; const APath: string): TJSONArray;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  if (D <> nil) and (D.JSONType = jtArray) then
    Result := TJSONArray(D)
  else
    Result := nil;
end;

function JObject(AObj: TJSONData; const APath: string): TJSONObject;
var
  D: TJSONData;
begin
  D := JGet(AObj, APath);
  if (D <> nil) and (D.JSONType = jtObject) then
    Result := TJSONObject(D)
  else
    Result := nil;
end;

function ParseJSON(const AText: string): TJSONData;
var
  P: TJSONParser;
begin
  P := TJSONParser.Create(AText, [joUTF8]);
  try
    try
      Result := P.Parse;
    except
      on E: Exception do
        raise ELLMError.CreateFmt('invalid JSON: %s', [E.Message]);
    end;
  finally
    P.Free;
  end;
end;

function ParseJSONObject(const AText: string): TJSONObject;
var
  D: TJSONData;
begin
  D := ParseJSON(AText);
  if D.JSONType <> jtObject then
  begin
    D.Free;
    raise ELLMError.Create('expected a JSON object');
  end;
  Result := TJSONObject(D);
end;

function TryParseJSON(const AText: string): TJSONData;
begin
  try
    Result := ParseJSON(AText);
  except
    on ELLMError do
      Result := nil;
  end;
end;

function CompactJSON(AData: TJSONData): string;
var
  Previous: Boolean;
begin
  if AData = nil then
    Exit('null');
  Previous := TJSONData.CompressedJSON;
  TJSONData.CompressedJSON := True;
  try
    Result := AData.AsJSON;
  finally
    TJSONData.CompressedJSON := Previous;
  end;
end;

function FloatsFrom(AArray: TJSONArray): TFloatArray;
var
  I: Integer;
begin
  if AArray = nil then
    Exit(nil);
  SetLength(Result, AArray.Count);
  for I := 0 to AArray.Count - 1 do
    if AArray.Items[I].JSONType = jtNumber then
      Result[I] := AArray.Items[I].AsFloat
    else
      Result[I] := 0;
end;

procedure JSetOpt(AObj: TJSONObject; const AName: string; const AValue: TOptFloat);
begin
  if AValue.HasValue then
    AObj.Add(AName, AValue.Value);
end;

procedure JSetOpt(AObj: TJSONObject; const AName: string; const AValue: TOptInt);
begin
  if AValue.HasValue then
    AObj.Add(AName, AValue.Value);
end;

procedure JSetOpt(AObj: TJSONObject; const AName: string; const AValue: TOptBool);
begin
  if AValue.HasValue then
    AObj.Add(AName, AValue.Value);
end;

procedure JSetStr(AObj: TJSONObject; const AName, AValue: string);
begin
  if AValue <> '' then
    AObj.Add(AName, AValue);
end;

function JStrings(const AValues: TStringArray): TJSONArray;
var
  I: Integer;
begin
  Result := TJSONArray.Create;
  for I := 0 to High(AValues) do
    Result.Add(AValues[I]);
end;

procedure JSetRaw(AObj: TJSONObject; const AName, AJSONText: string);
var
  D: TJSONData;
begin
  if AJSONText = '' then
    Exit;
  D := TryParseJSON(AJSONText);
  if D = nil then
    AObj.Add(AName, AJSONText)
  else
    AObj.Add(AName, D);
end;

procedure JMerge(ATarget, ASource: TJSONObject);
var
  I, Idx: Integer;
  Name: string;
begin
  if (ATarget = nil) or (ASource = nil) then
    Exit;
  for I := 0 to ASource.Count - 1 do
  begin
    Name := ASource.Names[I];
    Idx := ATarget.IndexOfName(Name);
    if Idx >= 0 then
      ATarget.Delete(Idx);
    ATarget.Add(Name, ASource.Items[I].Clone);
  end;
end;

procedure ApplyExtras(ABody: TJSONObject; ARequest: TLLMRequest;
  const AProviderID: string);
begin
  if ARequest = nil then
    Exit;
  JMerge(ABody, ARequest.ExtraOrNil);
  JMerge(ABody, ARequest.ProviderOptionsFor(AProviderID));
end;

function BytesToString(const AData: TBytes): string;
begin
  Result := '';
  SetLength(Result, Length(AData));
  if Length(AData) > 0 then
    Move(AData[0], Result[1], Length(AData));
end;

function StringToBytes(const AText: string): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(AText));
  if Length(AText) > 0 then
    Move(AText[1], Result[0], Length(AText));
end;

function Base64FromBytes(const AData: TBytes): string;
begin
  Result := EncodeStringBase64(BytesToString(AData));
end;

function BytesFromBase64(const AText: string): TBytes;
begin
  Result := StringToBytes(DecodeStringBase64(AText, False));
end;

function DataURL(const AData: TBytes; const AMimeType: string): string;
var
  Mime: string;
begin
  Mime := AMimeType;
  if Mime = '' then
    Mime := 'application/octet-stream';
  Result := 'data:' + Mime + ';base64,' + Base64FromBytes(AData);
end;

end.
