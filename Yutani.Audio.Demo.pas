unit Yutani.Audio.Demo;

{==============================================================================*
 *  Yutani.Audio.Demo - complete wiring example for the Yutani audio units
 *------------------------------------------------------------------------------
 *  Version: 1.0
 *
 *  This unit demonstrates how to wire the full voice pipeline of the Yutani
 *  avatar in a console or GUI application:
 *
 *      microphone (MiniAudio capture device)
 *          -> TYutaniVoskSTT.FeedPCM16()          [speech recognition]
 *          -> OnFinalResult / OnPartialResult     [your dialog logic]
 *          -> TYutaniPiperTTS.Speak(reply)        [local TTS + fallback]
 *          -> CurrentAmplitude                    [mouth animation]
 *
 *  Everything runs without a GUI - read the amplitude from your render loop.
 *
 *  Usage (console demo):
 *      uses Yutani.Audio.Demo;
 *      var Pipeline: TYutaniVoicePipeline;
 *      Pipeline := TYutaniVoicePipeline.Create;
 *      try
 *        Pipeline.Setup(
 *          'C:\models\vosk-model-small-en-us-0.15',
 *          'C:\models\de_DE-thorsten-vits\de_DE-thorsten-medium.onnx',
 *          'C:\models\de_DE-thorsten-vits\tokens.txt',
 *          'C:\models\de_DE-thorsten-vits\espeak-ng-data');
 *        Writeln('Speak into the microphone. Empty line quits.');
 *        while Readln(Line) and (Line = '') do ; // run until user quits
 *      finally
 *        Pipeline.Free;
 *      end;
 *
 *  IMPORTANT: create and destroy TYutaniVoicePipeline from the same thread
 *  that owns the MiniAudio engine (usually the main thread). The event
 *  handlers run on worker / audio threads - marshal to your UI thread.
 *
 *  Requirements (Win64): miniaudio.dll, libvosk.dll, optionally
 *  sherpa-onnx-c-api.dll + onnxruntime.dll + a piper voice model. When the
 *  sherpa files are missing, the pipeline automatically speaks through the
 *  Windows SAPI voice instead (OnFallback tells you why).
 *==============================================================================}

interface

uses
  System.SysUtils, System.Classes,
  Winapi.Windows,
  MiniAudio4Delphi,
  Yutani.Audio.Vosk,
  Yutani.Audio.PiperTTS;

const
  // ma_device_config field offsets on Win64 (see miniaudio.h, struct
  // ma_device_config). The demo fills a 288 byte buffer manually because
  // MiniAudio4Delphi declares ma_device_config as an opaque Pointer.
  MADC_SIZE                    = 288;
  MADC_OFF_DEVICE_TYPE         = 0;    // ma_device_type (capture = 2)
  MADC_OFF_SAMPLE_RATE         = 4;    // ma_uint32
  MADC_OFF_PERIOD_MS           = 12;   // ma_uint32
  MADC_OFF_PERIODS             = 16;   // ma_uint32
  MADC_OFF_DATA_CALLBACK       = 32;   // ma_device_data_proc
  MADC_OFF_PUSER_DATA          = 56;   // void*
  MADC_OFF_CAPTURE_FORMAT      = 160;  // ma_format (s16 = 2)
  MADC_OFF_CAPTURE_CHANNELS    = 164;  // ma_uint32

type
  // matches: void (* ma_device_data_proc)(ma_device*, void*, const void*, ma_uint32)
  TMaDeviceDataProc = procedure(pDevice: Pointer; pOutput: Pointer;
    pInput: Pointer; frameCount: Cardinal); cdecl;

  { Event signatures re-exported for convenience (same as in the units). }
  TVoicePipelineHeard = procedure(Sender: TObject;
    const AText: string; AIsFinal: Boolean) of object;
  TVoicePipelineMessage = procedure(Sender: TObject;
    const AMsg: string) of object;

  { TYutaniVoicePipeline - microphone -> Vosk STT -> (your logic) ->
    Piper TTS -> MiniAudio playback + mouth amplitude. }
  TYutaniVoicePipeline = class(TObject)
  private
    FEngine: Pointer;              // ma_engine (allocated, owned)
    FDevice: Pointer;              // ma_device (allocated, owned)
    FStt: TYutaniVoskSTT;
    FTts: TYutaniPiperTTS;
    FDeviceBuffer: TArray<Byte>;   // ma_device_config storage
    FAutoReply: Boolean;           // demo behavior: echo recognized text

    FOnHeard: TVoicePipelineHeard;
    FOnTtsStart: TVoicePipelineMessage;
    FOnTtsEnd: TVoicePipelineMessage;
    FOnError: TVoicePipelineMessage;
    FOnFallback: TVoicePipelineMessage;

    procedure HandlePartial(Sender: TObject; const AText: string);
    procedure HandleFinal(Sender: TObject; const AText: string);
    procedure HandleTtsStart(Sender: TObject; const AText: string);
    procedure HandleTtsEnd(Sender: TObject; const AText: string);
    procedure HandleTtsError(Sender: TObject; const AMsg: string);
    procedure HandleFallback(Sender: TObject; const AMsg: string);
    function GetAmplitude: Single;
    function GetIsSpeaking: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Initializes STT (Vosk) and TTS (Piper/SAPI) and starts the microphone.
      Raises Exception when the microphone cannot be opened or the Vosk
      model is invalid. TTS problems degrade to SAPI (OnFallback). }
    procedure Setup(const AVoskModelDir, APiperModelPath, APiperTokensPath,
      AEspeakDataDir: string);

    { Makes the avatar say something. Thread-safe. }
    procedure Say(const AText: string);

    { Stops playback and drops pending replies. Thread-safe. }
    procedure ShutUp;

    { Demo behavior: when True (default), every final recognition result is
      echoed by the TTS ("You said: ..."). Set False and connect OnHeard to
      your own dialog logic. }
    property AutoReply: Boolean read FAutoReply write FAutoReply;

    { 0.0..1.0 smoothed mouth amplitude - read every render frame. }
    property CurrentAmplitude: Single read GetAmplitude;

    { True while TTS is generating/playing. }
    property IsSpeaking: Boolean read GetIsSpeaking;

    { Recognition results (worker thread of the capture callback!). }
    property OnHeard: TVoicePipelineHeard read FOnHeard write FOnHeard;

    { TTS bracket events (worker thread). }
    property OnTtsStart: TVoicePipelineMessage read FOnTtsStart write FOnTtsStart;
    property OnTtsEnd: TVoicePipelineMessage read FOnTtsEnd write FOnTtsEnd;

    { Error / fallback notifications (worker thread). }
    property OnError: TVoicePipelineMessage read FOnError write FOnError;
    property OnFallback: TVoicePipelineMessage read FOnFallback write FOnFallback;
  end;

  { The capture callback handed to miniaudio. pUserData is the pipeline. }
procedure YutaniCaptureCallback(pDevice: Pointer; pOutput: Pointer;
  pInput: Pointer; frameCount: Cardinal); cdecl;

implementation

var
  // The capture callback cannot recover pUserData from the opaque ma_device
  // pointer, so the (single) active pipeline registers itself here.
  // (Initialized in the initialization section below.)
  YutaniActivePipeline: TYutaniVoicePipeline;

{------------------------------------------------------------------------------}
{ Helpers to fill the ma_device_config byte buffer                             }
{------------------------------------------------------------------------------}

procedure PutUInt32(var Buf: TArray<Byte>; Offset: Integer; Value: Cardinal);
begin
  Move(Value, Buf[Offset], 4);
end;

procedure PutPointer(var Buf: TArray<Byte>; Offset: Integer; Value: Pointer);
begin
  Move(Value, Buf[Offset], 8);
end;

{------------------------------------------------------------------------------}
{ Capture callback (runs on the miniaudio device thread!)                      }
{------------------------------------------------------------------------------}

procedure YutaniCaptureCallback(pDevice: Pointer; pOutput: Pointer;
  pInput: Pointer; frameCount: Cardinal); cdecl;
var
  Pipeline: TYutaniVoicePipeline;
begin
  Pipeline := YutaniActivePipeline;
  if (Pipeline <> nil) and (pInput <> nil) and (frameCount > 0) then
    Pipeline.FStt.FeedPCM16(pInput, frameCount * 2); // s16 mono: 2 bytes/frame
end;

{------------------------------------------------------------------------------}
{ TYutaniVoicePipeline                                                         }
{------------------------------------------------------------------------------}

constructor TYutaniVoicePipeline.Create;
begin
  inherited Create;
  FEngine := nil;
  FDevice := nil;
  FStt := nil;
  FTts := nil;
  FAutoReply := True;
end;

destructor TYutaniVoicePipeline.Destroy;
begin
  if YutaniActivePipeline = Self then
    YutaniActivePipeline := nil;

  // stop the microphone first (the callback references FStt)
  if FDevice <> nil then
  begin
    ma_device_stop(FDevice);
    ma_device_uninit(FDevice);
    FreeMem(FDevice);
    FDevice := nil;
  end;

  FreeAndNil(FTts);   // uninit the TTS voice sound before the engine dies
  if FEngine <> nil then
  begin
    ma_engine_uninit(FEngine);
    FreeMem(FEngine);
    FEngine := nil;
  end;

  FreeAndNil(FStt);
  inherited;
end;

procedure TYutaniVoicePipeline.Setup(const AVoskModelDir, APiperModelPath,
  APiperTokensPath, AEspeakDataDir: string);
var
  EngineSize, DeviceSize: NativeUInt;
  HR: ma_result;
begin
  if FEngine <> nil then
    raise Exception.Create('TYutaniVoicePipeline.Setup called twice.');

  // ---- 1. speech recognition (never raises; check Available) ----
  FStt := TYutaniVoskSTT.Create(AVoskModelDir);
  FStt.OnPartialResult := HandlePartial;
  FStt.OnFinalResult := HandleFinal;
  if not FStt.Available then
    raise Exception.CreateFmt('Vosk speech recognition is not available: %s',
      [FStt.LastError]);
  if not FStt.Active then
    raise Exception.CreateFmt('Vosk model could not be loaded from "%s": %s',
      [AVoskModelDir, FStt.LastError]);

  // ---- 2. audio engine (MiniAudio) ----
  EngineSize := ma_engine_sizeof();
  GetMem(FEngine, EngineSize);
  FillChar(FEngine^, EngineSize, 0);
  HR := ma_engine_init(nil, FEngine); // NULL config = sensible defaults
  if HR <> MA_SUCCESS then
  begin
    FreeMem(FEngine);
    FEngine := nil;
    raise Exception.CreateFmt('ma_engine_init failed: %d', [HR]);
  end;

  // ---- 3. TTS (Piper via sherpa-onnx, SAPI fallback built in) ----
  FTts := TYutaniPiperTTS.Create;
  FTts.OnSpeakStart := HandleTtsStart;
  FTts.OnSpeakEnd := HandleTtsEnd;
  FTts.OnError := HandleTtsError;
  FTts.OnFallback := HandleFallback;
  FTts.SetupPiperVoice(APiperModelPath, APiperTokensPath, AEspeakDataDir);
  FTts.AttachEngine(FEngine);

  // ---- 4. microphone capture (s16 mono 16 kHz for Vosk) ----
  SetLength(FDeviceBuffer, MADC_SIZE);
  FillChar(FDeviceBuffer[0], MADC_SIZE, 0);
  PutUInt32(FDeviceBuffer, MADC_OFF_DEVICE_TYPE, MA_DEVICE_TYPE_CAPTURE);
  PutUInt32(FDeviceBuffer, MADC_OFF_SAMPLE_RATE, 16000);
  PutUInt32(FDeviceBuffer, MADC_OFF_PERIOD_MS, 20);   // 20 ms chunks
  PutUInt32(FDeviceBuffer, MADC_OFF_PERIODS, 8);
  PutPointer(FDeviceBuffer, MADC_OFF_DATA_CALLBACK, @YutaniCaptureCallback);
  PutPointer(FDeviceBuffer, MADC_OFF_PUSER_DATA, Self);
  PutUInt32(FDeviceBuffer, MADC_OFF_CAPTURE_FORMAT, MA_FORMAT_S16);
  PutUInt32(FDeviceBuffer, MADC_OFF_CAPTURE_CHANNELS, 1);

  DeviceSize := ma_device_sizeof();
  GetMem(FDevice, DeviceSize);
  FillChar(FDevice^, DeviceSize, 0);
  HR := ma_device_init(nil, @FDeviceBuffer[0], FDevice);
  if HR <> MA_SUCCESS then
  begin
    FreeMem(FDevice);
    FDevice := nil;
    raise Exception.CreateFmt('ma_device_init(capture) failed: %d - ' +
      'is a microphone connected?', [HR]);
  end;

  YutaniActivePipeline := Self;

  HR := ma_device_start(FDevice);
  if HR <> MA_SUCCESS then
    raise Exception.CreateFmt('ma_device_start failed: %d', [HR]);
end;

procedure TYutaniVoicePipeline.HandlePartial(Sender: TObject;
  const AText: string);
begin
  if Assigned(FOnHeard) then
    FOnHeard(Self, AText, False);
end;

procedure TYutaniVoicePipeline.HandleFinal(Sender: TObject;
  const AText: string);
begin
  if Assigned(FOnHeard) then
    FOnHeard(Self, AText, True);

  // demo behavior: echo everything back through the avatar voice
  if FAutoReply and (Trim(AText) <> '') then
    Say('Du hast gesagt: ' + AText);
end;

procedure TYutaniVoicePipeline.HandleTtsStart(Sender: TObject;
  const AText: string);
begin
  if Assigned(FOnTtsStart) then
    FOnTtsStart(Self, AText);
end;

procedure TYutaniVoicePipeline.HandleTtsEnd(Sender: TObject;
  const AText: string);
begin
  if Assigned(FOnTtsEnd) then
    FOnTtsEnd(Self, AText);
end;

procedure TYutaniVoicePipeline.HandleTtsError(Sender: TObject;
  const AMsg: string);
begin
  if Assigned(FOnError) then
    FOnError(Self, AMsg);
end;

procedure TYutaniVoicePipeline.HandleFallback(Sender: TObject;
  const AMsg: string);
begin
  if Assigned(FOnFallback) then
    FOnFallback(Self, AMsg);
end;

procedure TYutaniVoicePipeline.Say(const AText: string);
begin
  if FTts <> nil then
    FTts.Speak(AText);
end;

procedure TYutaniVoicePipeline.ShutUp;
begin
  if FTts <> nil then
    FTts.StopSpeaking;
end;

function TYutaniVoicePipeline.GetAmplitude: Single;
begin
  if FTts <> nil then
    Result := FTts.CurrentAmplitude
  else
    Result := 0.0;
end;

function TYutaniVoicePipeline.GetIsSpeaking: Boolean;
begin
  Result := (FTts <> nil) and FTts.IsSpeaking;
end;

initialization
  YutaniActivePipeline := nil;

end.
