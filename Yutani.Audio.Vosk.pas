unit Yutani.Audio.Vosk;

{==============================================================================*
 *  Yutani.Audio.Vosk - Offline Speech-to-Text via libvosk.dll
 *------------------------------------------------------------------------------
 *  Version: 1.0
 *
 *  Self-contained Vosk wrapper for the Yutani avatar project. Loads
 *  'libvosk.dll' dynamically (LoadLibrary / GetProcAddress) with a clean
 *  fallback if the DLL or the model is missing, so the host application
 *  never crashes on machines without a speech model installed.
 *
 *  Style / conventions follow MiniAudio4Delphi.pas:
 *  - opaque Pointer handles for the C objects
 *  - cdecl function pointer types, resolved at runtime
 *  - no external framework dependencies
 *
 *  Threading model:
 *  - FeedPCM16() is designed to be called directly from the MiniAudio capture
 *    callback thread. Recognition itself is synchronous and runs on the
 *    caller's thread (Vosk is fast enough for 16 kHz mono chunks).
 *  - OnPartialResult / OnFinalResult / OnError are fired from the thread that
 *    called FeedPCM16 (i.e. typically the audio capture thread). UI code must
 *    marshal into the main thread (see the demo at the bottom of the example
 *    wiring file).
 *  - The instance is protected by a critical section, so FeedPCM16 / Reset /
 *    Flush / SetMuted may be called from any thread.
 *
 *  Audio format required by FeedPCM16: 16-bit signed little-endian PCM,
 *  MONO, at the sample rate the recognizer was created with (16000 Hz by
 *  default - configure the MiniAudio capture device accordingly).
 *
 *  Uses only: System.SysUtils, System.Classes, System.JSON, Winapi.Windows.
 *  Target: Win64, Delphi 12 / 13.
 *==============================================================================}

interface

uses
  System.SysUtils, System.Classes, System.JSON, Winapi.Windows;

const
  VOSK_LIB = 'libvosk.dll';

  // Values for vosk_set_log_level (see vosk_api.h):
  //  -1 disables logging, 0 = errors (+words timing), 1 = debug info,
  //  -1000 = everything (very verbose).
  VOSK_LOG_OFF   = -1;
  VOSK_LOG_ERROR = 0;
  VOSK_LOG_INFO  = 1;

  // Default model format used by the Yutani avatar pipeline.
  VOSK_DEFAULT_SAMPLE_RATE = 16000;

type
  // Opaque handles (we use Pointer exactly like MiniAudio4Delphi does)
  vosk_model = Pointer;
  vosk_recognizer = Pointer;

  // Event signatures. NOTE: fired from the audio/capture thread!
  TVoskTextEvent = procedure(Sender: TObject; const AText: string) of object;
  TVoskErrorEvent = procedure(Sender: TObject; const AMsg: string) of object;

  { Exception raised only for programming errors (wrong constructor usage).
      Missing DLL / missing model are NOT raised - see TYutaniVoskSTT.Available. }
  EVoskError = class(Exception);

  { TYutaniVoskSTT - offline speech recognizer built on libvosk.dll.
      If the DLL or the model directory is missing, the object is created
      inactive (Available = False) instead of raising, so the avatar can run
      without speech input. }
  TYutaniVoskSTT = class(TObject)
  private type
    TVoskSetLogLevelProc = procedure(log_level: Integer); cdecl;
    TVoskModelNewProc = function(model_path: PAnsiChar): vosk_model; cdecl;
    TVoskModelFreeProc = procedure(model: vosk_model); cdecl;
    TVoskRecognizerNewProc = function(model: vosk_model;
      sample_rate: Single): vosk_recognizer; cdecl;
    TVoskRecognizerFreeProc = procedure(recognizer: vosk_recognizer); cdecl;
    TVoskRecognizerAcceptWaveformProc = function(recognizer: vosk_recognizer;
      data: PAnsiChar; length: Integer): Integer; cdecl;
    TVoskRecognizerPartialResultProc = function(
      recognizer: vosk_recognizer): PAnsiChar; cdecl;
    TVoskRecognizerResultProc = function(
      recognizer: vosk_recognizer): PAnsiChar; cdecl;
    TVoskRecognizerFinalResultProc = function(
      recognizer: vosk_recognizer): PAnsiChar; cdecl;
    TVoskRecognizerResetProc = procedure(recognizer: vosk_recognizer); cdecl;
  private
    // ---- class-level DLL management (shared by all instances) ----
    class var FModule: THandle;
    class var FModuleLoaded: Boolean;   // load attempted (success or not)
    class var FModuleStatus: string;    // '' = ok, otherwise reason
    class var FModuleLock: TRTLCriticalSection;

    class var _vosk_set_log_level: TVoskSetLogLevelProc;
    class var _vosk_model_new: TVoskModelNewProc;
    class var _vosk_model_free: TVoskModelFreeProc;
    class var _vosk_recognizer_new: TVoskRecognizerNewProc;
    class var _vosk_recognizer_free: TVoskRecognizerFreeProc;
    class var _vosk_recognizer_accept_waveform: TVoskRecognizerAcceptWaveformProc;
    class var _vosk_recognizer_partial_result: TVoskRecognizerPartialResultProc;
    class var _vosk_recognizer_result: TVoskRecognizerResultProc;
    class var _vosk_recognizer_final_result: TVoskRecognizerFinalResultProc;
    class var _vosk_recognizer_reset: TVoskRecognizerResetProc;

    class constructor Create;
    class destructor Destroy;

    class procedure EnsureModuleLoaded; static;
  private
    // ---- instance state ----
    FModel: vosk_model;
    FRecognizer: vosk_recognizer;
    FSampleRate: Integer;
    FLock: TRTLCriticalSection;
    FActive: Boolean;
    FMuted: Boolean;
    FModelPath: string;
    FLastError: string;
    FOnPartialResult: TVoskTextEvent;
    FOnFinalResult: TVoskTextEvent;
    FOnError: TVoskErrorEvent;

    function GetAvailable: Boolean;
    function GetMuted: Boolean;
    procedure SetMuted(const Value: Boolean);
    procedure SetInactive(const AReason: string);

    // Parse a Vosk JSON answer ('{"partial": "..."}' or '{"text": "..."}')
    // and fire the matching event. AJsonPtr points to a UTF-8 null-terminated
    // string owned by libvosk - only valid until the next recognizer call.
    procedure ParseAndFire(const AJsonPtr: PAnsiChar; IsFinal: Boolean);

    procedure DoPartial(const AText: string); virtual;
    procedure DoFinal(const AText: string); virtual;
    procedure DoError(const AMsg: string); virtual;
  public
    // AModelPath: directory with the unpacked Vosk model (conf, am, graph...).
    // ASampleRate: sample rate of the PCM data you will feed (default 16 kHz).
    // ALogLevel: VOSK_LOG_* constant, applied once while loading.
    // Does NOT raise when DLL/model are missing -> check Available.
    constructor Create(const AModelPath: string;
      ASampleRate: Integer = VOSK_DEFAULT_SAMPLE_RATE;
      ALogLevel: Integer = VOSK_LOG_ERROR); reintroduce;
    destructor Destroy; override;

    { Main feed - call directly from the MiniAudio capture callback.
      Data: 16-bit mono PCM at FSampleRate. ByteCount is in BYTES
      (= SampleCount * 2), exactly like vosk_recognizer_accept_waveform.
      Fires OnPartialResult / OnFinalResult. Does nothing when muted,
      inactive or on error. }
    procedure FeedPCM16(const Data: Pointer; ByteCount: Integer);

    { Clears the recognizer's internal audio buffer and decoding state. }
    procedure Reset;

    { Flushes the pipeline and fires OnFinalResult for any pending speech.
      Call once before you stop the capture device. }
    procedure Flush;

    { Mute / pause: while muted, FeedPCM16 discards all audio and the
      recognizer is reset (so the avatar does not transcribe its own voice
      and no stale half-utterance fires after unmuting). }
    property Muted: Boolean read GetMuted write SetMuted;

    { True when model + recognizer were created successfully. }
    property Active: Boolean read FActive;
    { True when Active and the libvosk.dll is usable. }
    property Available: Boolean read GetAvailable;
    property ModelPath: string read FModelPath;
    property SampleRate: Integer read FSampleRate;
    { Last fatal setup reason ('' when fine), e.g. 'libvosk.dll not found'. }
    property LastError: string read FLastError;

    property OnPartialResult: TVoskTextEvent read FOnPartialResult write FOnPartialResult;
    property OnFinalResult: TVoskTextEvent read FOnFinalResult write FOnFinalResult;
    property OnError: TVoskErrorEvent read FOnError write FOnError;
  end;

{ True if 'libvosk.dll' was found and every required entry point could be
  resolved. Safe to call before creating any TYutaniVoskSTT instance. }
function VoskLibraryAvailable: Boolean;

{ Human readable reason when VoskLibraryAvailable is False ('' when fine). }
function VoskLibraryStatus: string;

{ Converts a UTF-8 null-terminated C string (PAnsiChar) to a Delphi string.
  Vosk returns UTF-8 encoded JSON, so plain string(PAnsiChar) would corrupt
  non-ASCII characters (e.g. umlauts). }
function VoskUtf8ToStr(const P: PAnsiChar): string;

implementation

// =============================================================================
// Library management
// =============================================================================

class constructor TYutaniVoskSTT.Create;
begin
  InitializeCriticalSection(FModuleLock);
end;

class destructor TYutaniVoskSTT.Destroy;
begin
  EnterCriticalSection(FModuleLock);
  try
    if FModule <> 0 then
    begin
      FreeLibrary(FModule);
      FModule := 0;
    end;
    FModuleLoaded := False;
    _vosk_set_log_level := nil;
    _vosk_model_new := nil;
    _vosk_model_free := nil;
    _vosk_recognizer_new := nil;
    _vosk_recognizer_free := nil;
    _vosk_recognizer_accept_waveform := nil;
    _vosk_recognizer_partial_result := nil;
    _vosk_recognizer_result := nil;
    _vosk_recognizer_final_result := nil;
    _vosk_recognizer_reset := nil;
  finally
    LeaveCriticalSection(FModuleLock);
  end;
  DeleteCriticalSection(FModuleLock);
end;

class procedure TYutaniVoskSTT.EnsureModuleLoaded;
var
  Missing: string;

  procedure Need(const AName: AnsiString; var AProc: Pointer);
  var
    Addr: FARPROC;
  begin
    if AProc <> nil then
      Exit;
    Addr := GetProcAddress(FModule, PAnsiChar(AName));
    if Addr = nil then
    begin
      if Missing <> '' then
        Missing := Missing + ', ';
      Missing := Missing + string(AName);
    end
    else
      AProc := Addr;
  end;

begin
  if FModuleLoaded then
    Exit;
  EnterCriticalSection(FModuleLock);
  try
    if FModuleLoaded then   // re-check inside the lock
      Exit;

    FModuleStatus := '';

    // Search order: application directory, then the 'vosk\' subfolder.
    // SetDllDirectoryW also lets Windows resolve the MinGW runtime DLLs
    // (libwinpthread-1.dll etc.) that libvosk.dll depends on.
    SetDllDirectoryW(PChar(IncludeTrailingPathDelimiter(
      ExtractFilePath(ParamStr(0)) + 'vosk')));
    try
      FModule := LoadLibrary(VOSK_LIB);
    finally
      SetDllDirectoryW(nil);
    end;
    if FModule = 0 then
    begin
      FModuleStatus := Format('%s not found (Win32 error %d) - searched ' +
        'the EXE folder and the vosk\ subfolder', [VOSK_LIB, GetLastError]);
      FModuleLoaded := True;
      Exit;
    end;

    Missing := '';
    Need('vosk_set_log_level', @_vosk_set_log_level);
    Need('vosk_model_new', @_vosk_model_new);
    Need('vosk_model_free', @_vosk_model_free);
    Need('vosk_recognizer_new', @_vosk_recognizer_new);
    Need('vosk_recognizer_free', @_vosk_recognizer_free);
    Need('vosk_recognizer_accept_waveform', @_vosk_recognizer_accept_waveform);
    Need('vosk_recognizer_partial_result', @_vosk_recognizer_partial_result);
    Need('vosk_recognizer_result', @_vosk_recognizer_result);
    Need('vosk_recognizer_final_result', @_vosk_recognizer_final_result);
    Need('vosk_recognizer_reset', @_vosk_recognizer_reset);

    if Missing <> '' then
    begin
      FreeLibrary(FModule);
      FModule := 0;
      FModuleStatus := Format('%s is missing exports: %s', [VOSK_LIB, Missing]);
    end;
    FModuleLoaded := True;
  finally
    LeaveCriticalSection(FModuleLock);
  end;
end;

function VoskLibraryAvailable: Boolean;
begin
  Result := TYutaniVoskSTT.FModule <> 0;
  if not Result then
  begin
    // cheap enough: only attempts once, afterwards cached in FModuleLoaded
    TYutaniVoskSTT.EnsureModuleLoaded;
    Result := TYutaniVoskSTT.FModule <> 0;
  end;
end;

function VoskLibraryStatus: string;
begin
  if not VoskLibraryAvailable then
    Result := TYutaniVoskSTT.FModuleStatus
  else
    Result := '';
end;

function VoskUtf8ToStr(const P: PAnsiChar): string;
var
  Len: Integer;
  Bytes: TBytes;
begin
  Result := '';
  if P = nil then
    Exit;
  Len := 0;
  while P[Len] <> #0 do    // strlen for PAnsiChar without extra units
    Inc(Len);
  if Len = 0 then
    Exit;
  SetLength(Bytes, Len);
  Move(P^, Bytes[0], Len);
  Result := TEncoding.UTF8.GetString(Bytes);
end;

// =============================================================================
// TYutaniVoskSTT
// =============================================================================

constructor TYutaniVoskSTT.Create(const AModelPath: string;
  ASampleRate: Integer; ALogLevel: Integer);
begin
  inherited Create;
  InitializeCriticalSection(FLock);
  FModelPath := AModelPath;
  FSampleRate := ASampleRate;

  if not VoskLibraryAvailable then
  begin
    SetInactive(VoskLibraryStatus);
    Exit;
  end;

  if not DirectoryExists(AModelPath) then
  begin
    SetInactive(Format('Vosk model directory not found: %s', [AModelPath]));
    Exit;
  end;

  if Assigned(_vosk_set_log_level) then
    _vosk_set_log_level(ALogLevel);

  FModel := _vosk_model_new(PAnsiChar(AnsiString(AModelPath)));
  if FModel = nil then
  begin
    SetInactive(Format('vosk_model_new failed for "%s" (incompatible or ' +
      'corrupt model?)', [AModelPath]));
    Exit;
  end;

  FRecognizer := _vosk_recognizer_new(FModel, Single(FSampleRate));
  if FRecognizer = nil then
  begin
    _vosk_model_free(FModel);
    FModel := nil;
    SetInactive(Format('vosk_recognizer_new failed (%d Hz)', [FSampleRate]));
    Exit;
  end;

  FActive := True;
end;

destructor TYutaniVoskSTT.Destroy;
begin
  EnterCriticalSection(FLock);
  try
    if (FRecognizer <> nil) and Assigned(_vosk_recognizer_free) then
      _vosk_recognizer_free(FRecognizer);
    FRecognizer := nil;
    if (FModel <> nil) and Assigned(_vosk_model_free) then
      _vosk_model_free(FModel);
    FModel := nil;
    FActive := False;
  finally
    LeaveCriticalSection(FLock);
    DeleteCriticalSection(FLock);
  end;
  inherited Destroy;
end;

procedure TYutaniVoskSTT.SetInactive(const AReason: string);
begin
  FActive := False;
  FLastError := AReason;
end;

function TYutaniVoskSTT.GetAvailable: Boolean;
begin
  Result := FActive and (FModule <> 0);
end;

function TYutaniVoskSTT.GetMuted: Boolean;
begin
  Result := FMuted;
end;

procedure TYutaniVoskSTT.SetMuted(const Value: Boolean);
begin
  if FMuted = Value then
    Exit;
  FMuted := Value;
  if Value and FActive then
    Reset;   // drop the half-utterance buffered while we were listening
end;

procedure TYutaniVoskSTT.FeedPCM16(const Data: Pointer; ByteCount: Integer);
var
  Res: Integer;
  JsonPtr: PAnsiChar;
  IsFinal: Boolean;
begin
  if (Data = nil) or (ByteCount <= 0) then
    Exit;
  if FMuted or (not GetAvailable) then
    Exit;

  // Never hand an odd number of bytes to Vosk (incomplete sample frame).
  ByteCount := ByteCount and not 1;

  EnterCriticalSection(FLock);
  try
    if (FRecognizer = nil) or (not Assigned(_vosk_recognizer_accept_waveform)) then
      Exit;

    Res := _vosk_recognizer_accept_waveform(FRecognizer, PAnsiChar(Data),
      ByteCount);
    if Res < 0 then
    begin
      // Exception inside Vosk: recover by resetting the recognizer.
      if Assigned(_vosk_recognizer_reset) then
        _vosk_recognizer_reset(FRecognizer);
      LeaveCriticalSection(FLock);
      try
        DoError('vosk_recognizer_accept_waveform failed (' +
          IntToStr(Res) + ') - recognizer reset');
      finally
        EnterCriticalSection(FLock);
      end;
      Exit;
    end;

    // Res = 1: end of utterance detected (silence) -> full result,
    // Res = 0: decoding continues -> partial result.
    IsFinal := Res = 1;
    if IsFinal then
      JsonPtr := _vosk_recognizer_result(FRecognizer)
    else
      JsonPtr := _vosk_recognizer_partial_result(FRecognizer);

    ParseAndFire(JsonPtr, IsFinal);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TYutaniVoskSTT.Reset;
begin
  if not GetAvailable then
    Exit;
  EnterCriticalSection(FLock);
  try
    if (FRecognizer <> nil) and Assigned(_vosk_recognizer_reset) then
      _vosk_recognizer_reset(FRecognizer);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TYutaniVoskSTT.Flush;
var
  JsonPtr: PAnsiChar;
begin
  if not GetAvailable then
    Exit;
  EnterCriticalSection(FLock);
  try
    if (FRecognizer = nil) or (not Assigned(_vosk_recognizer_final_result)) then
      Exit;
    JsonPtr := _vosk_recognizer_final_result(FRecognizer);
    ParseAndFire(JsonPtr, True);
    // final_result flushes the pipeline; reset so the next utterance
    // starts from a clean state.
    if Assigned(_vosk_recognizer_reset) then
      _vosk_recognizer_reset(FRecognizer);
  finally
    LeaveCriticalSection(FLock);
  end;
end;

procedure TYutaniVoskSTT.ParseAndFire(const AJsonPtr: PAnsiChar;
  IsFinal: Boolean);
var
  Json: TJSONValue;
  Txt: string;
  FirePartial: Boolean;
  FireFinal: Boolean;
begin
  FirePartial := False;
  FireFinal := False;
  Txt := '';

  if (AJsonPtr <> nil) and (AJsonPtr^ <> #0) then
  begin
    Json := TJSONObject.ParseJSONValue(VoskUtf8ToStr(AJsonPtr));
    if Json <> nil then
    begin
      try
        if IsFinal then
        begin
          // final answer: {"text": "..."}
          if Json.TryGetValue<string>('text', Txt) then
            FireFinal := Txt <> '';
        end
        else
        begin
          // partial answer: {"partial": "..."}  (may be empty: UI can clear)
          if Json.TryGetValue<string>('partial', Txt) then
            FirePartial := True;
        end;
      finally
        Json.Free;
      end;
    end
    else
    begin
      LeaveCriticalSection(FLock);
      try
        DoError('Vosk returned invalid JSON');
      finally
        EnterCriticalSection(FLock);
      end;
      Exit;
    end;
  end;

  // Fire events OUTSIDE the critical section so handlers may safely call
  // back into this instance (Windows CS is re-entrant per thread anyway,
  // but this also keeps handler latency out of the lock).
  LeaveCriticalSection(FLock);
  try
    if FirePartial then
      DoPartial(Txt);
    if FireFinal then
      DoFinal(Txt);
  finally
    EnterCriticalSection(FLock);
  end;
end;

procedure TYutaniVoskSTT.DoPartial(const AText: string);
begin
  if Assigned(FOnPartialResult) then
    FOnPartialResult(Self, AText);
end;

procedure TYutaniVoskSTT.DoFinal(const AText: string);
begin
  if Assigned(FOnFinalResult) then
    FOnFinalResult(Self, AText);
end;

procedure TYutaniVoskSTT.DoError(const AMsg: string);
begin
  FLastError := AMsg;
  if Assigned(FOnError) then
    FOnError(Self, AMsg);
end;

end.
