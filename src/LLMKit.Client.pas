{ LLMKit.Client - shared base for provider clients.

  Holds the transport, the resolved model name and the capability set, and
  rejects message parts the provider cannot send before anything goes out on
  the wire.
}
unit LLMKit.Client;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, LLMKit.Core, LLMKit.HTTP;

type
  TLLMClientBase = class(TInterfacedObject, ILLMClient)
  protected
    FProviderID: string;
    FModel: string;
    FCaps: TCapabilities;
    FTransport: TTransport;
    { Raises ELLMUnsupported for any part kind outside FCaps. }
    procedure CheckParts(ARequest: TLLMRequest);
    procedure CheckTools(ARequest: TLLMRequest);
    procedure Need(ACap: TCapability; const AWhat: string);
  public
    constructor Create(const AProviderID, AModel: string; ACaps: TCapabilities;
      ATransport: TTransport);
    destructor Destroy; override;
    function ProviderID: string;
    function ModelID: string;
    property Capabilities: TCapabilities read FCaps;
    property Transport: TTransport read FTransport;
  end;

implementation

constructor TLLMClientBase.Create(const AProviderID, AModel: string;
  ACaps: TCapabilities; ATransport: TTransport);
begin
  inherited Create;
  FProviderID := AProviderID;
  FModel := AModel;
  FCaps := ACaps;
  FTransport := ATransport;
end;

destructor TLLMClientBase.Destroy;
begin
  FTransport.Free;
  inherited Destroy;
end;

function TLLMClientBase.ProviderID: string;
begin
  Result := FProviderID;
end;

function TLLMClientBase.ModelID: string;
begin
  Result := FModel;
end;

procedure TLLMClientBase.Need(ACap: TCapability; const AWhat: string);
begin
  if not (ACap in FCaps) then
    raise ELLMUnsupported.CreateFmt('%s (model %s) does not support %s',
      [FProviderID, FModel, AWhat]);
end;

procedure TLLMClientBase.CheckParts(ARequest: TLLMRequest);
var
  I, J: Integer;
  Msg: TLLMMessage;
begin
  if ARequest = nil then
    raise ELLMInvalidRequest.Create('request is nil');
  for I := 0 to ARequest.Messages.Count - 1 do
  begin
    Msg := ARequest.Messages[I];
    for J := 0 to Msg.Parts.Count - 1 do
      case Msg.Parts[J].Kind of
        pkImage: Need(capImages, 'image parts');
        pkAudio: Need(capAudio, 'audio parts');
        pkFile: Need(capFiles, 'file parts');
      end;
  end;
end;

procedure TLLMClientBase.CheckTools(ARequest: TLLMRequest);
begin
  if (ARequest <> nil) and (ARequest.Tools.Count > 0) then
    Need(capTools, 'tools');
end;

end.
