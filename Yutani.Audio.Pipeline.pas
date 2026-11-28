unit Yutani.Audio.Pipeline;

{$POINTERMATH ON}

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
  System.SysUtils, System.Classes, System.Math,
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
    { VTuber/OBS creator mode: the microphone only drives the mouth
      animation (live RMS amplitude), recognized text is never forwarded
      to the AI - see MicLipSyncOnly. }
    FMicLipSyncOnly: Boolean;
    { Live mic RMS amplitude (0.0..1.0) while MicLipSyncOnly is active.
      Written from the capture thread, read from the render loop; a
      4-byte aligned Single stays atomic on x64. }
    FMicAmplitude: Single;

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
    { WASAPI rock-solid fallback (engine thread = Setup caller): writes a
      short beep WAV into %TEMP% and plays it through
      ma_engine_play_sound. Used when the permanent voice sound did not
      come up (is_playing = 0) - if even THIS stays silent, the engine /
      driver session itself is dead and OnFallback says so. }
    function RunWavProbe: Boolean;
    { Capture-thread helper: smoothed RMS envelope of the raw microphone
      samples - the mouth driver for MicLipSyncOnly mode. Declared after the
      class so YutaniCaptureCallback can reach it. }
    procedure UpdateMicAmplitude(const Data: Pointer; FrameCount: Cardinal);
    function GetAmplitude: Single;
    function GetIsSpeaking: Boolean;
    function GetMicLipSyncOnly: Boolean;
    procedure SetMicLipSyncOnly(const Value: Boolean);
    function GetMicMuted: Boolean;
    procedure SetMicMuted(const Value: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    { Initializes the SIDES the caller actually wants. ATtsEnabled = True
      builds ma_engine + TYutaniPiperTTS (no capture device, no libvosk.dll
      needed); ASttEnabled = True builds ma_device capture + TYutaniVoskSTT
      (AI answers stay text + gestures). An empty or missing Vosk model
      directory leaves STT inactive instead of raising, so text chat and TTS
      (Piper/SAPI) keep working; a broken microphone or MiniAudio failure
      still raises. TTS problems degrade to SAPI (OnFallback). Both False
      raises - use the pipeline only when at least one side is wanted. }
    procedure Setup(const AVoskModelDir, APiperModelPath, APiperTokensPath,
      AEspeakDataDir: string; ATtsEnabled: Boolean = True;
      ASttEnabled: Boolean = True);

    { Makes the avatar say something. Thread-safe. }
    procedure Say(const AText: string);

    { Stops playback and drops pending replies. Thread-safe. }
    procedure ShutUp;

    { Demo behavior: when True (default), every final recognition result is
      echoed by the TTS ("You said: ..."). Set False and connect OnHeard to
      your own dialog logic. }
    property AutoReply: Boolean read FAutoReply write FAutoReply;

    { 0.0..1.0 smoothed mouth amplitude - read every render frame.
      While MicLipSyncOnly is active this is the live microphone RMS so the
      mouth tracks the creator's own voice; otherwise it is the TTS
      playback envelope. }
    property CurrentAmplitude: Single read GetAmplitude;

    { True while TTS is generating/playing. }
    property IsSpeaking: Boolean read GetIsSpeaking;

    { VTuber / OBS creator mode: while True the microphone only drives
      CurrentAmplitude (lip-sync for video voiceovers); recognized text is
      never fired through OnHeard to the AI. Anti-echo muting of the STT is
      still applied while the avatar speaks. Default False. }
    property MicLipSyncOnly: Boolean read GetMicLipSyncOnly write SetMicLipSyncOnly;

    { Mute / pause the recognizer without tearing the pipeline: while
      muted the capture keeps running (amplitude / LipSyncOnly stay live)
      but FeedPCM16 discards all audio. Assigning False resumes live
      recognition on a clean recognizer. }
    property MicMuted: Boolean read GetMicMuted write SetMicMuted;

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
  begin
    { Mic-Lip-Sync mode tracks the live microphone RMS so the mouth follows
      the creator's own voice even while STT is muted (anti-echo) or absent. }
    Pipeline.UpdateMicAmplitude(pInput, frameCount);
    { Guard for the pure LipSyncOnly mode: the capture device runs without
      a Vosk model (FStt = nil), so feeding the recognizer would AV. }
    if Pipeline.FStt <> nil then
      Pipeline.FStt.FeedPCM16(pInput, frameCount * 2); // s16 mono: 2 bytes/frame
  end;
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
  FMicLipSyncOnly := False;
  FMicAmplitude := 0.0;
end;

destructor TYutaniVoicePipeline.Destroy;
begin
  { The capture callback could be mid-flight on the audio thread; clear
    the registration first so the window between ma_device_stop and the
    uninit never dereferences a half-destroyed pipeline. }
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
  APiperTokensPath, AEspeakDataDir: string; ATtsEnabled, ASttEnabled: Boolean);
var
  EngineSize: NativeUInt;
  DeviceSize: NativeUInt;
  HR: ma_result;
begin
  if FEngine <> nil then
    raise Exception.Create('TYutaniVoicePipeline.Setup called twice.');
  if (not ATtsEnabled) and (not ASttEnabled) then
    raise Exception.Create('TYutaniVoicePipeline.Setup: both TTS and STT disabled - nothing to build.');

  // ---- 1. speech recognition (STT side only; a missing model just disables it) ----
  if ASttEnabled then
  begin
    if (Trim(AVoskModelDir) <> '') and DirectoryExists(AVoskModelDir) then
    begin
      FStt := TYutaniVoskSTT.Create(AVoskModelDir);
      FStt.OnPartialResult := HandlePartial;
      FStt.OnFinalResult := HandleFinal;
      // Inactive (DLL/model problem) never raises here: text chat and TTS
      // keep working, the host reads the reason from OnFallback instead.
      if not FStt.Active then
      begin
        HandleFallback(Self, Format('Vosk model could not be loaded from "%s": %s',
          [AVoskModelDir, FStt.LastError]));
        FreeAndNil(FStt);
      end;
    end
    else
      HandleFallback(Self, Format('Vosk model directory not found: "%s" - running without speech recognition',
        [AVoskModelDir]));
  end
  else
    HandleFallback(Self, 'STT disabled by toggle - recognizer not loaded.');

  // ---- 2. microphone capture (s16 mono 16 kHz for Vosk) - STT side only ----
  { INITIALIZED BEFORE ma_engine_init: on Windows/WASAPI, opening the
    capture device while the playback engine already exists makes WASAPI
    re-negotiate the shared-mode mix format on the SAME audio session -
    which silently mutes the playback side (the "AI response -> speaking
    logged but nothing audible" symptom). Opening the microphone FIRST and
    then creating the engine keeps both sides of the session alive.
    A missing STT (no Vosk model) still opens the capture device when
    MicLipSyncOnly wants the live amplitude; with neither STT nor
    lip-sync-only the microphone is plain unnecessary, so skip the device
    and keep engine + TTS working for text chat. TTS-only setups (ASttEnabled
    = False) NEVER open a capture device - no microphone, no libvosk. }
  if ASttEnabled and ((FStt <> nil) or FMicLipSyncOnly) then
  begin
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

    { Fixed 16384-byte device buffer instead of ma_device_sizeof(): the
      helper is not exported by every miniaudio.dll build, while 16 KB
      safely covers sizeof(ma_device) on Win64 (capture ~1.4 KB, playback
      ~4 KB plus the full dupped internals). }
    DeviceSize := 16384;
    GetMem(FDevice, DeviceSize);
    FillChar(FDevice^, DeviceSize, 0);
    HR := ma_device_init(nil, @FDeviceBuffer[0], FDevice);
    if HR <> MA_SUCCESS then
    begin
      FreeMem(FDevice);
      FDevice := nil;
      HandleFallback(Self, Format('ma_device_init(capture) failed: %d - ' +
        'is a microphone connected? Running without STT.', [HR]));
    end
    else
    begin
      YutaniActivePipeline := Self;

      HR := ma_device_start(FDevice);
      if HR <> MA_SUCCESS then
        HandleFallback(Self, Format('ma_device_start(capture) failed: %d - ' +
          'running without STT.', [HR]));
    end;
  end
  else
    { No STT and no lip-sync-only: the microphone is plain unnecessary,
      engine + TTS keep working for text chat and the capture device is
      never opened. }
    YutaniActivePipeline := nil;

  // ---- 3. audio engine (MiniAudio) - TTS side only ----
  if not ATtsEnabled then
  begin
    { STT-only: no playback engine at all - AI answers stay text + head
      gestures, exactly what the STT-only toggle promises. The sections
      below (engine + TTS + playback probe) are all skipped. }
    HandleFallback(Self, 'TTS disabled by toggle - no audio engine created (answers as text + gestures only).');
    Exit;
  end;
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
  { NO ma_engine_start here: ma_engine_init already starts the engine (its
    docs: "starts as started"), and MiniAudio4Delphi does not even declare
    ma_engine_start as a function: ma_result - calling it through the
    record's function pointer would not compile. }

  // ---- 4. TTS (Piper via sherpa-onnx, SAPI fallback built in) ----
  { Only reached with ATtsEnabled = True (the STT-only branch above exited). }
  FTts := TYutaniPiperTTS.Create;
  FTts.OnSpeakStart := HandleTtsStart;
  FTts.OnSpeakEnd := HandleTtsEnd;
  FTts.OnError := HandleTtsError;
  FTts.OnFallback := HandleFallback;
  FTts.SetupPiperVoice(APiperModelPath, APiperTokensPath, AEspeakDataDir);
  { Engine status AFTER SetupPiperVoice: the SAPI fallback decisions inside
    (missing DLL / model files / espeak data) all funnel into EngineKind.
    Reporting tekSherpaPiper vs tekSapi through OnFallback makes the
    "logged 'speaking' but silent" case diagnosable - UsePiper = EngineKind
    = tekSherpaPiper means the piper voice is REALLY rendering. }
  if FTts.EngineKind = tekSherpaPiper then
    HandleFallback(Self, Format('Piper TTS active (sherpa-onnx v%s): %s',
      [SherpaTtsLibraryVersion, APiperModelPath]))
  else
    HandleFallback(Self, Format('TTS on SAPI fallback (EngineKind=%d): %s',
      [Ord(FTts.EngineKind), SherpaTtsLibraryStatus]));
  FTts.AttachEngine(FEngine);
  { WASAPI playback diagnosis (engine thread, right after the attach): engine
    volume and the permanent voice sound's is_playing state go to OnFallback
    (= the panel's debug log) so a silent driver session is visible in the
    log. ma_engine_play_sound itself runs a rock-solid %TEMP% WAV probe when
    the sound did NOT come up - if even the probe stays silent, the engine /
    driver session is dead and the log says so. SAPI mode has no sound. }
  if FTts.EngineKind = tekSherpaPiper then
  begin
    HandleFallback(Self, Format('Playback check: engine volume %.2f, voice sound playing=%d',
      [ma_engine_get_volume(FEngine), Integer(ma_sound_is_playing(FTts.Sound))]));
    if ma_sound_is_playing(FTts.Sound) = 0 then
    begin
      HandleFallback(Self, 'Voice sound not playing - running %TEMP% WAV probe through ma_engine_play_sound.');
      if not RunWavProbe then
        HandleFallback(Self, 'WAV probe stayed silent too - the engine session is dead; check WASAPI shared mode / default output device.')
      else
        HandleFallback(Self, 'WAV probe audible - playback path OK; the voice sound needs a driver-side start.');
    end;
  end;
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
  { Mic-Lip-Sync (VTuber/OBS) mode: the microphone is only the mouth
    animation source - recognized text never reaches the dialog logic, so
    the AI is not spammed with the creator's voice-over. }
  if FMicLipSyncOnly then
    Exit;

  if Assigned(FOnHeard) then
    FOnHeard(Self, AText, True);

  // demo behavior: echo everything back through the avatar voice
  if FAutoReply and (Trim(AText) <> '') then
    Say('Du hast gesagt: ' + AText);
end;

procedure TYutaniVoicePipeline.HandleTtsStart(Sender: TObject;
  const AText: string);
begin
  { Anti-echo: mute the recognizer while the avatar speaks so it does not
    transcribe its own voice through the microphone. }
  if FStt <> nil then
    FStt.Muted := True;
  if Assigned(FOnTtsStart) then
    FOnTtsStart(Self, AText);
end;

procedure TYutaniVoicePipeline.HandleTtsEnd(Sender: TObject;
  const AText: string);
begin
  { Anti-echo release: un-mute and let the recognizer pick up the user
    again; SetMuted already reset any half-utterance buffered on mute. }
  if FStt <> nil then
    FStt.Muted := False;
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

function TYutaniVoicePipeline.RunWavProbe: Boolean;
{ Rock-solid playback probe: writes a short 440 Hz beep WAV into %TEMP% and
  plays it through ma_engine_play_sound, bypassing the permanent voice sound
  and its data source completely. Returns True when the engine accepted the
  file - audibility is the user's ears, but a MA_SUCCESS here proves engine
  AND driver session actually render samples. }
const
  PROBE_RATE = 22050;   // piper-typical rate: no mix format renegotiation
  PROBE_LEN  = 440;     // ~20 ms of 440 Hz sine beep
var
  TempWav: string;
  WavPathA: AnsiString;
  FS: TFileStream;
  I: Integer;
  Sample: SmallInt;

  { little-endian 32-bit write helper: WriteBuffer(@value, 4) on a local }
  procedure W32(const V: Integer);
  begin
    FS.WriteBuffer(V, 4);
  end;

  { little-endian 16-bit write helper }
  procedure W16(const V: SmallInt);
  begin
    FS.WriteBuffer(V, 2);
  end;

  { 4-char file tag helper: takes an AnsiString - a plain 'RIFF' literal
    would arrive as UTF-16 and write NUL-padded garbage into the header. }
  procedure WTag(const S: AnsiString);
  var
    J: Integer;
    C: AnsiChar;
  begin
    for J := 1 to 4 do
    begin
      C := S[J];
      FS.WriteBuffer(C, 1);
    end;
  end;

begin
  Result := False;
  if FEngine = nil then
    Exit;
  TempWav := IncludeTrailingPathDelimiter(
    GetEnvironmentVariable('TEMP')) + 'yutani_probe.wav';
  try
    FS := TFileStream.Create(TempWav, fmCreate);
    try
      // canonical 44-byte PCM WAV header: mono, 16-bit, PROBE_RATE
      WTag('RIFF');
      W32(36 + PROBE_LEN * 2);      // RIFF chunk size (file - 8)
      WTag('WAVE');
      WTag('fmt ');
      W32(16);                       // fmt chunk size
      W16(1);                        // PCM
      W16(1);                        // channels
      W32(PROBE_RATE);               // sample rate
      W32(PROBE_RATE * 2);           // byte rate
      W16(2);                        // block align
      W16(16);                       // bits per sample
      WTag('data');
      W32(PROBE_LEN * 2);            // data size
      for I := 0 to PROBE_LEN - 1 do
      begin
        Sample := SmallInt(Trunc(12000 * Sin(2 * Pi * 440 * I / PROBE_RATE)));
        W16(Sample);
      end;
    finally
      FS.Free;
    end;
  except
    Exit; // %TEMP% not writable - no probe, stay silent-safe
  end;

  { PAnsiChar path (ANSI, no wide API): ma_engine_play_sound takes the file
    name as PAnsiChar; nil group = the engine's default sound group. }
  WavPathA := AnsiString(TempWav);
  Result := ma_engine_play_sound(FEngine, PAnsiChar(WavPathA), nil) = MA_SUCCESS;
end;

procedure TYutaniVoicePipeline.Say(const AText: string);
begin
  if FTts <> nil then
    FTts.Speak(AText);
end;

procedure TYutaniVoicePipeline.UpdateMicAmplitude(const Data: Pointer; FrameCount: Cardinal);
var
  I: Integer;
  Smp: PSmallInt;
  Sum: Double;
  Rms, Target: Single;
const
  { Same envelope shape as the TTS path: fast attack, slow release, so the
    mouth opens crisply and closes softly. Mic levels are far quieter than
    the synthesized playback, so the normalization is more generous. }
  ATTACK = 0.55;
  RELEASE = 0.12;
begin
  if (Data = nil) or (FrameCount = 0) then
  begin
    FMicAmplitude := FMicAmplitude * (1.0 - RELEASE);
    Exit;
  end;
  Smp := Data;
  Sum := 0.0;
  for I := 0 to Integer(FrameCount) - 1 do
    Sum := Sum + (Smp[I] / 32768.0) * (Smp[I] / 32768.0);
  Rms := Sqrt(Sum / FrameCount);
  Target := Min(1.0, Rms * 9.0);
  if Target > FMicAmplitude then
    FMicAmplitude := FMicAmplitude + (Target - FMicAmplitude) * ATTACK
  else
    FMicAmplitude := FMicAmplitude + (Target - FMicAmplitude) * RELEASE;
end;

function TYutaniVoicePipeline.GetMicLipSyncOnly: Boolean;
begin
  Result := FMicLipSyncOnly;
end;

procedure TYutaniVoicePipeline.SetMicLipSyncOnly(const Value: Boolean);
begin
  { Only meaningful before Setup opens the capture device: when no STT is
    available, LipSyncOnly is what keeps the microphone alive at all. Set
    afterwards it still gates OnHeard (see HandleFinal), but a device the
    setup skipped cannot be conjured up retroactively. }
  FMicLipSyncOnly := Value;
  if (not Value) and (FStt = nil) and (FDevice = nil) then
    FMicAmplitude := 0.0;
end;

function TYutaniVoicePipeline.GetMicMuted: Boolean;
begin
  Result := (FStt <> nil) and FStt.Muted;
end;

procedure TYutaniVoicePipeline.SetMicMuted(const Value: Boolean);
begin
  { Delegates to the recognizer's mute (thread-safe, resets any buffered
    half-utterance on mute); no-op when STT is not available. }
  if FStt <> nil then
    FStt.Muted := Value;
end;

procedure TYutaniVoicePipeline.ShutUp;
begin
  if FTts <> nil then
    FTts.StopSpeaking;
end;

function TYutaniVoicePipeline.GetAmplitude: Single;
begin
  { Mic-Lip-Sync mode reads the live microphone envelope; the TTS playback
    envelope is meaningless there (nothing is being synthesized). While the
    avatar itself speaks, the TTS amplitude wins so the mouth follows the
    voice the audience hears. }
  if FMicLipSyncOnly and (not GetIsSpeaking) then
    Result := FMicAmplitude
  else if FTts <> nil then
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
