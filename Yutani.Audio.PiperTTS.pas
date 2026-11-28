unit Yutani.Audio.PiperTTS;

{==============================================================================*
 *  Yutani.Audio.PiperTTS - Offline TTS (Piper/VITS via sherpa-onnx)
 *                           with automatic Windows SAPI fallback
 *------------------------------------------------------------------------------
 *  Version: 1.0
 *
 *  Self-contained text-to-speech component for the Yutani avatar project.
 *
 *  Primary engine: local Piper VITS ONNX voices rendered through sherpa-onnx
 *  ('sherpa-onnx-c-api.dll'), loaded dynamically (LoadLibrary/GetProcAddress).
 *  If the DLL or the .onnx model files are missing, the unit automatically
 *  falls back to the Windows SAPI voice (ISpVoice via raw COM calls against
 *  ole32.dll - no ComObj/VCL needed), so the avatar always makes sound.
 *
 *  Playback path (sherpa/Piper mode):
 *    - Speak() enqueues text; a worker thread calls
 *      SherpaOnnxOfflineTtsGenerate() and appends the float32 samples to a
 *      locked playback buffer.
 *    - A custom ma_data_source (see TYutaniTtsDataSource) feeds one permanent
 *      ma_sound created through MiniAudio4Delphi. The MiniAudio mixing thread
 *      pulls samples from the queue, which never blocks the UI/render loop.
 *    - The playback callback (VtRead) continuously computes a smoothed RMS
 *      amplitude (CurrentAmplitude, 0.0..1.0, attack/release envelope) which
 *      can be read from the 3D render loop every frame to drive the avatar's
 *      mouth animation.
 *
 *  Playback path (SAPI fallback):
 *    - The worker thread speaks through ISpVoice::Speak(SPF_ASYNC) and polls
 *      WaitUntilDone; the OS renders the audio. Since SAPI does not expose
 *      the samples to us, the mouth envelope is approximated from the
 *      speaking state (documented approximation, still good enough for lip
 *      sync).
 *
 *  Style / conventions follow MiniAudio4Delphi.pas:
 *  - opaque Pointer handles for C objects, cdecl function pointer types
 *  - dynamic loading, no static external dependencies
 *  - runtime units used: System.SysUtils, System.Classes, System.JSON,
 *    Winapi.Windows (ole32 functions are declared as external WinAPI imports,
 *    just like Winapi.Windows does for kernel32 - no COM framework units).
 *
 *  Target: Win64, Delphi 12 / 13.
 *  IMPORTANT threading rules:
 *  - Create / SetupPiperVoice / AttachEngine / Destroy must be called from
 *    the thread that owns the ma_engine (usually the main thread), in this
 *    order: Create -> SetupPiperVoice -> AttachEngine.
 *  - Speak / StopSpeaking / IsSpeaking / CurrentAmplitude may be called from
 *    any thread.
 *  - OnSpeakStart / OnSpeakEnd / OnError / OnFallback are fired from the
 *    worker thread; marshal to the UI thread yourself (see demo).
 *==============================================================================}

{$POINTERMATH ON}   // enables Dst + Done / ABuffer[I] style pointer arithmetic

interface

uses
  System.SysUtils, System.Classes, Winapi.Windows,
  MiniAudio4Delphi;

const
  SHERPA_LIB = 'sherpa-onnx-c-api.dll';

  // ---- miniaudio constants (see miniaudio.h) ----
  MA_FORMAT_F32             = 5;    // ma_format_f32
  MA_FORMAT_S16             = 2;    // ma_format_s16
  MA_SUCCESS                = 0;
  MA_INVALID_OPERATION      = -3;
  MA_AT_END                 = -17;
  MA_BUSY                   = -19;
  MA_NOT_IMPLEMENTED        = -29;
  MA_DEVICE_TYPE_CAPTURE    = 2;    // ma_device_type_capture

  // ---- SAPI constants (see sapi.idl) ----
  SPF_ASYNC                 = $0001;
  SPF_PURGEBEFORESPEAK      = $0002;
  SPRS_IS_SPEAKING          = $0002;  // SPVOICESTATUS.dwRunningState bit

  // ---- sherpa-onnx struct sizes on Win64 (see sherpa-onnx c-api.h).
  // Compile-time checks below verify our Delphi records match; older DLLs
  // simply read less than we pass (caller struct may be larger than callee's).
  SHERPA_VITS_CONFIG_SIZE        = 56;
  SHERPA_MATCHA_CONFIG_SIZE      = 56;
  SHERPA_KOKORO_CONFIG_SIZE      = 64;
  SHERPA_KITTEN_CONFIG_SIZE      = 48;
  SHERPA_ZIPVOICE_CONFIG_SIZE    = 64;
  SHERPA_POCKET_CONFIG_SIZE      = 64;
  SHERPA_SUPERTONIC_CONFIG_SIZE  = 56;
  SHERPA_MODEL_CONFIG_SIZE       = 424;
  SHERPA_OFFLINE_TTS_CONFIG_SIZE = 456;
  SHERPA_GENERATED_AUDIO_SIZE    = 16;

  // Win64 size of ma_data_source_vtable / ma_data_source_base (miniaudio.h)
  MA_DATA_SOURCE_VTABLE_SIZE     = 56;
  MA_DATA_SOURCE_BASE_SIZE       = 72;

  // Default Piper voice parameters (sherpa-onnx piper examples)
  PIPER_DEFAULT_NOISE_SCALE      = 0.667;
  PIPER_DEFAULT_NOISE_SCALE_W    = 0.8;
  PIPER_DEFAULT_LENGTH_SCALE     = 1.0;
  PIPER_DEFAULT_NUM_THREADS      = 2;
  PIPER_DEFAULT_MAX_SENTENCES    = 1;
  PIPER_DEFAULT_SILENCE_SCALE    = 0.2;

type
  // ============================================================================
  // Sherpa-ONNX Offline TTS C API bindings (Win64 layout, cdecl)
  // Field order and types follow sherpa-onnx/c-api/c-api.h exactly.
  // NOTE: records use DEFAULT (natural) alignment - do NOT pack them.
  // ============================================================================

  SherpaOnnxOfflineTtsVitsModelConfig = record
    model: PAnsiChar;         // path to the VITS .onnx file
    lexicon: PAnsiChar;       // path to lexicon.txt (optional with espeak data)
    tokens: PAnsiChar;        // path to tokens.txt
    data_dir: PAnsiChar;      // path to espeak-ng-data directory
    noise_scale: Single;      // VITS noise scale (Piper default 0.667)
    noise_scale_w: Single;    // VITS duration noise scale (Piper default 0.8)
    length_scale: Single;     // speech rate: < 1 slower, > 1 faster
    dict_dir: PAnsiChar;      // legacy field, kept for ABI compatibility
  end;

  SherpaOnnxOfflineTtsMatchaModelConfig = record
    acoustic_model: PAnsiChar;
    vocoder: PAnsiChar;
    lexicon: PAnsiChar;
    tokens: PAnsiChar;
    data_dir: PAnsiChar;
    noise_scale: Single;
    length_scale: Single;
    dict_dir: PAnsiChar;
  end;

  SherpaOnnxOfflineTtsKokoroModelConfig = record
    model: PAnsiChar;
    voices: PAnsiChar;
    tokens: PAnsiChar;
    data_dir: PAnsiChar;
    length_scale: Single;
    dict_dir: PAnsiChar;
    lexicon: PAnsiChar;
    lang: PAnsiChar;
  end;

  SherpaOnnxOfflineTtsKittenModelConfig = record
    model: PAnsiChar;
    voices: PAnsiChar;
    tokens: PAnsiChar;
    data_dir: PAnsiChar;
    length_scale: Single;
    lexicon: PAnsiChar;
  end;

  SherpaOnnxOfflineTtsZipvoiceModelConfig = record
    tokens: PAnsiChar;
    encoder: PAnsiChar;
    decoder: PAnsiChar;
    vocoder: PAnsiChar;
    data_dir: PAnsiChar;
    lexicon: PAnsiChar;
    feat_scale: Single;
    t_shift: Single;
    target_rms: Single;
    guidance_scale: Single;
  end;

  SherpaOnnxOfflineTtsPocketModelConfig = record
    lm_flow: PAnsiChar;
    lm_main: PAnsiChar;
    encoder: PAnsiChar;
    decoder: PAnsiChar;
    text_conditioner: PAnsiChar;
    vocab_json: PAnsiChar;
    token_scores_json: PAnsiChar;
    voice_embedding_cache_capacity: Integer;
  end;

  SherpaOnnxOfflineTtsSupertonicModelConfig = record
    duration_predictor: PAnsiChar;
    text_encoder: PAnsiChar;
    vector_estimator: PAnsiChar;
    vocoder: PAnsiChar;
    tts_json: PAnsiChar;
    unicode_indexer: PAnsiChar;
    voice_style: PAnsiChar;
  end;

  SherpaOnnxOfflineTtsModelConfig = record
    vits: SherpaOnnxOfflineTtsVitsModelConfig;
    num_threads: Integer;     // backend threads
    debug: Integer;           // 1 = print debug output
    provider: PAnsiChar;      // 'cpu' or 'cuda'
    matcha: SherpaOnnxOfflineTtsMatchaModelConfig;
    kokoro: SherpaOnnxOfflineTtsKokoroModelConfig;
    kitten: SherpaOnnxOfflineTtsKittenModelConfig;
    zipvoice: SherpaOnnxOfflineTtsZipvoiceModelConfig;
    pocket: SherpaOnnxOfflineTtsPocketModelConfig;
    supertonic: SherpaOnnxOfflineTtsSupertonicModelConfig;
  end;

  PSherpaOnnxOfflineTtsConfig = ^SherpaOnnxOfflineTtsConfig;
  SherpaOnnxOfflineTtsConfig = record
    model: SherpaOnnxOfflineTtsModelConfig;
    rule_fsts: PAnsiChar;       // optional comma-separated rule FST list
    max_num_sentences: Integer; // sentences per chunk (Piper: 1)
    rule_fars: PAnsiChar;       // optional FAR archives for text normalization
    silence_scale: Single;      // silence between sentences
  end;

  PSherpaOnnxGeneratedAudio = ^SherpaOnnxGeneratedAudio;
  SherpaOnnxGeneratedAudio = record
    samples: PSingle;         // mono float32 samples in [-1, 1]
    n: Integer;               // number of samples
    sample_rate: Integer;     // output sample rate (e.g. 22050 for Piper)
  end;

  // ---- sherpa-onnx entry point types (cdecl) ----
  TSherpaCreateOfflineTtsProc = function(
    const config: PSherpaOnnxOfflineTtsConfig): Pointer; cdecl;
  TSherpaDestroyOfflineTtsProc = procedure(tts: Pointer); cdecl;
  TSherpaOfflineTtsSampleRateProc = function(tts: Pointer): Integer; cdecl;
  TSherpaOfflineTtsGenerateProc = function(tts: Pointer; text: PAnsiChar;
    sid: Integer; speed: Single): PSherpaOnnxGeneratedAudio; cdecl;
  PSherpaOnnxGenerationConfig = ^SherpaOnnxGenerationConfig;
  SherpaOnnxGenerationConfig = record
    silence_scale: Single;
    speed: Single;
    sid: Integer;
    reference_audio: PSingle;
    reference_audio_len: Integer;
    reference_sample_rate: Integer;
    reference_text: PAnsiChar;
    num_steps: Integer;
    extra: PAnsiChar;
    phoneme_codepoints: PInteger;
    phoneme_codepoints_lens: PInteger;
    phoneme_codepoints_num_sentences: Integer;
    tokens: PPAnsiChar;
    tokens_lens: PInteger;
    tokens_num_sentences: Integer;
  end;


  TSherpaOfflineTtsGenerateWithConfigProc = function(tts: Pointer; text: PAnsiChar;
    const config: PSherpaOnnxGenerationConfig; callback: Pointer;
    arg: Pointer): PSherpaOnnxGeneratedAudio; cdecl;


  TSherpaDestroyOfflineTtsAudioProc = procedure(
    audio: PSherpaOnnxGeneratedAudio); cdecl;
  { Optional export since sherpa-onnx v1.9.x: returns the library's own
    version string (PAnsiChar, owned by the DLL - never freed by us). Used
    purely for diagnostics, so a missing export is not an error. }
  TSherpaGetVersionStrProc = function: PAnsiChar; cdecl;

  // ============================================================================
  // miniaudio custom data source bindings (Win64 layout of
  // ma_data_source_vtable / ma_data_source_base, see miniaudio.h)
  // ============================================================================

  TMaDataSourceReadProc = function(pDataSource: Pointer; pFramesOut: Pointer;
    frameCount: UInt64; pFramesRead: PUInt64): Integer; cdecl;
  TMaDataSourceSeekProc = function(pDataSource: Pointer;
    frameIndex: UInt64): Integer; cdecl;
  TMaDataSourceGetDataFormatProc = function(pDataSource: Pointer;
    pFormat: PCardinal; pChannels: PCardinal; pSampleRate: PCardinal;
    pChannelMap: Pointer; channelMapCap: NativeUInt): Integer; cdecl;
  TMaDataSourceGetCursorProc = function(pDataSource: Pointer;
    pCursor: PUInt64): Integer; cdecl;
  TMaDataSourceGetLengthProc = function(pDataSource: Pointer;
    pLength: PUInt64): Integer; cdecl;
  TMaDataSourceSetLoopingProc = function(pDataSource: Pointer;
    isLooping: Integer): Integer; cdecl;

  TMaDataSourceVtable = record
    onRead: TMaDataSourceReadProc;
    onSeek: TMaDataSourceSeekProc;
    onGetDataFormat: TMaDataSourceGetDataFormatProc;
    onGetCursor: TMaDataSourceGetCursorProc;
    onGetLength: TMaDataSourceGetLengthProc;
    onSetLooping: TMaDataSourceSetLoopingProc;
    flags: Cardinal;
  end;

  TMaDataSourceBase = record
    vtable: Pointer;
    rangeBegInFrames: UInt64;
    rangeEndInFrames: UInt64;      // $FFFFFFFFFFFFFFFF = unranged (default)
    loopBegInFrames: UInt64;
    loopEndInFrames: UInt64;
    pCurrent: Pointer;
    pNext: Pointer;
    onGetNext: Pointer;
    isLooping: Integer;            // MA_ATOMIC(4, ma_bool32)
    Reserved: Integer;             // tail padding so the record is 72 bytes
  end;

  // The data source object we hand to ma_sound_init_from_data_source.
  // Base MUST be the first field; Owner is our private app data.
  PYutaniTtsDataSource = ^TYutaniTtsDataSource;
  TYutaniTtsDataSource = record
    Base: TMaDataSourceBase;
    Owner: Pointer;                // TYutaniPiperTTS instance
  end;

  // ============================================================================
  // Events / class
  // ============================================================================

  TPiperNotifyEvent = procedure(Sender: TObject) of object;
  TPiperTextEvent = procedure(Sender: TObject; const AText: string) of object;
  TPiperMessageEvent = procedure(Sender: TObject;
    const AMsg: string) of object;

  TTtsEngineKind = (tekUninitialized, tekSherpaPiper, tekSapi);

  { TYutaniPiperTTS - text-to-speech with MiniAudio playback and SAPI fallback.
    Usage: Create -> SetupPiperVoice (falls back to SAPI automatically) ->
    AttachEngine (from the engine-owning thread) -> Speak(...) from anywhere. }
  TYutaniPiperTTS = class(TObject)
  private
    // ---- class-level sherpa DLL management (shared by all instances) ----
    class var FModule: THandle;
    class var FModuleLoaded: Boolean;
    class var FModuleStatus: string;
    { Version reported by the loaded DLL (SherpaOnnxGetVersionStr) or
      'unknown (GetVersionStr not exported)' - diagnostics only. }
    class var FLibraryVersion: string;
    class var FModuleLock: TRTLCriticalSection;

    // resolved sherpa entry points - protected so the worker thread class
    // (same unit) can call them directly
    class var _SherpaCreateOfflineTts: TSherpaCreateOfflineTtsProc;
    class var _SherpaDestroyOfflineTts: TSherpaDestroyOfflineTtsProc;
    class var _SherpaOfflineTtsSampleRate: TSherpaOfflineTtsSampleRateProc; // optional export
    class var _SherpaOfflineTtsGenerate: TSherpaOfflineTtsGenerateProc;
    class var _SherpaOfflineTtsGenerateWithConfig: TSherpaOfflineTtsGenerateWithConfigProc;
    class var _SherpaDestroyOfflineTtsAudio: TSherpaDestroyOfflineTtsAudioProc;
    class var _SherpaGetVersionStr: TSherpaGetVersionStrProc; // optional export

    class constructor ClassCreate;
    class destructor ClassDestroy;
    class procedure EnsureModuleLoaded; static;
  private
    FTts: Pointer;                    // sherpa-onnx offline tts handle
    FEngineKind: TTtsEngineKind;
    FEngine: ma_engine;               // MiniAudio engine (not owned)
    FSound: ma_sound;                 // permanent voice sound (allocated)
    FDataSource: TYutaniTtsDataSource;
    FDataSourceSampleRate: Integer;   // rate reported to miniaudio

    // ---- worker thread state ----
    FWorker: TThread;                 // TYutaniTtsWorkerThread (impl section)
    FWakeup: THandle;                 // manual-reset event
    FShutdown: Boolean;               // set in Destroy (main thread)
    FCancelSpeak: Boolean;            // set by StopSpeaking
    FCancelEpoch: Integer;            // incremented by StopSpeaking (atomic-ish)
    FQueueLock: TRTLCriticalSection;
    FQueue: TStringList;              // pending utterances

    // ---- playback buffer (worker writes, mixer reads) ----
    FPlayLock: TRTLCriticalSection;
    FSamples: TArray<Single>;         // float32 mono sample ring storage
    FTotalAppended: UInt64;           // frames appended by the worker
    FTotalRead: UInt64;               // frames delivered to miniaudio so far
    // ring positions are derived: pos = counter mod Length(FSamples)

    // ---- mouth amplitude (mixer/worker write, render loop reads) ----
    FAmplitude: Single;               // 4-byte aligned; atomic on x64
    FSpeaking: Boolean;               // worker: between Start/End events

    // ---- piper voice configuration ----
    FModelPath: string;
    FLexiconPath: string;
    FTokensPath: string;
    FEspeakDataDir: string;
    FDictDir: string;
    FRuleFsts: string;
    FNoiseScale: Single;
    FNoiseScaleW: Single;
    FLengthScale: Single;
    FNumThreads: Integer;
    FDebug: Integer;
    FProvider: string;
    FMaxNumSentences: Integer;
    FSilenceScale: Single;
    FSpeakerId: Integer;
    FSpeed: Single;
    FSapiRate: Integer;               // SAPI rate adjustment (-10..10)
    FSapiVolume: Word;                // SAPI volume (0..100)

    FOnSpeakStart: TPiperTextEvent;
    FOnSpeakEnd: TPiperTextEvent;
    FOnFallback: TPiperMessageEvent;
    FOnError: TPiperMessageEvent;

    function GetIsSpeaking: Boolean;
    function GetSampleRate: Integer;
    procedure SetModelPath(const Value: string);
  protected
    // called by the worker thread (implementation section)
    procedure WorkerFireStart(const AText: string);
    procedure WorkerFireEnd(const AText: string);
    procedure WorkerAppendSamples(const ASamples: PSingle; ACount: Integer;
      ASampleRate: Integer);
    procedure WorkerClearBuffer;
    function WorkerDrained: Boolean;
    procedure WorkerSetSpeaking(AValue: Boolean);
    procedure UpdateAmplitude(const ABuffer: PSingle; AFrames: Integer);
    procedure DoError(const AMsg: string);
    procedure DoFallback(const AReason: string);
    property Shutdown: Boolean read FShutdown;
    property Wakeup: THandle read FWakeup;
    property QueueLock: TRTLCriticalSection read FQueueLock;
    property Queue: TStringList read FQueue;
    property TtsHandle: Pointer read FTts;
    property Speaking: Boolean read FSpeaking write FSpeaking;
    property Amplitude: Single read FAmplitude write FAmplitude;
  public
    constructor Create;
    destructor Destroy; override;

    { PUBLIC so the pipeline (Yutani.Audio.Pipeline.pas) can report the
      real engine state right after SetupPiperVoice: tekSherpaPiper means the
      local piper voice is REALLY rendering, tekSapi means the Windows
      fallback took over. }
    property EngineKind: TTtsEngineKind read FEngineKind;

    { PUBLIC read access for the pipeline's WASAPI playback diagnosis: the
      pipeline logs ma_sound_is_playing(Sound) right after AttachEngine and
      probes a %TEMP% WAV through the engine when the sound did not come up
      (nil after a failed ma_sound_init_from_data_source). nil in SAPI mode. }
    property Sound: ma_sound read FSound;

    { Tries to set up the local Piper/VITS voice through sherpa-onnx.
      AModelPath:  the .onnx file (required)
      ATokensPath: tokens.txt (required)
      AEspeakDataDir: espeak-ng-data directory (required unless ALexiconPath set)
      ALexiconPath / ADictDir: optional.
      Returns True when the sherpa engine is active. If the DLL or the model
      files are missing (or creation fails), the instance switches to the
      SAPI fallback, fires OnFallback and returns False - Speak() works
      immediately either way. }
    function SetupPiperVoice(const AModelPath, ATokensPath, AEspeakDataDir: string;
      const ALexiconPath: string = ''; const ADictDir: string = ''): Boolean;

    { Connects the MiniAudio engine and starts the permanent voice sound.
      Call from the thread that owns the engine, AFTER SetupPiperVoice.
      If no piper voice is available the call is still safe (SAPI mode does
      not need the engine). }
    procedure AttachEngine(AEngine: ma_engine);

    { Asynchronous TTS: returns immediately; the worker thread generates and
      plays the utterance. Thread-safe. }
    procedure Speak(const AText: string);

    { Drops everything queued and currently playing. Thread-safe. }
    procedure StopSpeaking;

    { True while text is queued/generating/playing. Thread-safe. }
    property IsSpeaking: Boolean read GetIsSpeaking;

    { Smoothed RMS mouth amplitude 0.0..1.0 - read this every render frame
      to drive the 3D avatar's jaw/morph targets. Thread-safe (aligned
      Single read). }
    property CurrentAmplitude: Single read FAmplitude;

    { Sample rate of the active voice (piper output rate, or 22050 default
      in SAPI mode). Set before AttachEngine - it configures the data source. }
    property SampleRate: Integer read GetSampleRate;

    // ---- piper/sherpa voice parameters (set BEFORE SetupPiperVoice) ----
    property ModelPath: string read FModelPath write SetModelPath;
    property LexiconPath: string read FLexiconPath write FLexiconPath;
    property TokensPath: string read FTokensPath write FTokensPath;
    property EspeakDataDir: string read FEspeakDataDir write FEspeakDataDir;
    property DictDir: string read FDictDir write FDictDir;
    property RuleFsts: string read FRuleFsts write FRuleFsts;
    property NoiseScale: Single read FNoiseScale write FNoiseScale;
    property NoiseScaleW: Single read FNoiseScaleW write FNoiseScaleW;
    property LengthScale: Single read FLengthScale write FLengthScale;
    property NumThreads: Integer read FNumThreads write FNumThreads;
    property Debug: Integer read FDebug write FDebug;
    property Provider: string read FProvider write FProvider;
    property MaxNumSentences: Integer read FMaxNumSentences write FMaxNumSentences;
    property SilenceScale: Single read FSilenceScale write FSilenceScale;
    property SpeakerId: Integer read FSpeakerId write FSpeakerId;
    property Speed: Single read FSpeed write FSpeed;
    property SapiRate: Integer read FSapiRate write FSapiRate;
    property SapiVolume: Word read FSapiVolume write FSapiVolume;

    { Events - fired from the WORKER thread (marshal to UI yourself).
      OnSpeakStart/OnSpeakEnd bracket one utteration INCLUDING playback. }
    property OnSpeakStart: TPiperTextEvent read FOnSpeakStart write FOnSpeakStart;
    property OnSpeakEnd: TPiperTextEvent read FOnSpeakEnd write FOnSpeakEnd;
    property OnFallback: TPiperMessageEvent read FOnFallback write FOnFallback;
    property OnError: TPiperMessageEvent read FOnError write FOnError;
  end;

{ True if 'sherpa-onnx-c-api.dll' is loadable with the required TTS exports. }
function SherpaTtsLibraryAvailable: Boolean;

{ Human readable reason when SherpaTtsLibraryAvailable is False ('' if fine). }
function SherpaTtsLibraryStatus: string;

{ Version string the loaded DLL reports via SherpaOnnxGetVersionStr (or
  'unknown (GetVersionStr not exported)' for older DLLs / when no DLL
  loaded). Diagnostics: the C-API struct layout the DLL expects is tied
  to this version. }
function SherpaTtsLibraryVersion: string;

implementation

uses
  System.Math;

{##############################################################################}
{# SAPI raw COM bindings (no ComObj / SpeechLib dependency)                    #}
{##############################################################################}

const
  COINIT_APARTMENTTHREADED = $2;
  CLSCTX_INPROC_SERVER     = $1;
  // IID / CLSID from sapi.idl
  IID_ISpVoice: TGUID     = '{6C44DF74-72B9-4992-A1EC-EF996E0422D4}';
  CLSID_SpVoice: TGUID    = '{96749377-3391-11D2-9EE3-00C04F797396}';

type
  // ---- SAPI procedure types (COM / stdcall). First parameter is the
  // interface pointer (thiscall-like 'this'), named pThis because 'Self'
  // is reserved in Delphi method scope.
  TSapiSpeakProc = function(pThis: Pointer; pwcs: PWideChar;
    flags: Cardinal; number: PCardinal): HResult; stdcall;
  TSapiGetStatusProc = function(pThis: Pointer; status: Pointer;
    bookmark: PPWideChar): HResult; stdcall;
  TSapiSetRateProc = function(pThis: Pointer;
    adjust: Integer): HResult; stdcall;
  TSapiSetVolumeProc = function(pThis: Pointer;
    volume: Word): HResult; stdcall;
  TSapiWaitProc = function(pThis: Pointer;
    msTimeout: Cardinal): HResult; stdcall;
  TSapiReleaseProc = function(pThis: Pointer): Integer; stdcall;

  // SPVOICESTATUS (sapi.idl, natural alignment on Win64 -> 64 bytes)
  TSpVoiceStatus = record
    ulCurrentStream: Cardinal;
    ulLastStreamQueued: Cardinal;
    hrLastResult: HResult;
    dwRunningState: Cardinal;   // 0=busy, SPRS_DONE=1, SPRS_IS_SPEAKING=2
    ulInputWordPos: Cardinal;
    ulInputWordLen: Cardinal;
    ulInputSentPos: Cardinal;
    ulInputSentLen: Cardinal;
    lBookmarkId: Integer;
    PhonemeId: Pointer;         // SPPHONEID (WCHAR*), aligned to 8
    VisemeId: Integer;
    dwReserved1: Cardinal;
    dwReserved2: Cardinal;
  end;

  // vtable slots up to WaitUntilDone (index 32) - layout verified against
  // sapi.idl: IUnknown(0-2), ISpNotifySource(3-9), ISpEventSource(10-12),
  // ISpVoice: SetOutput(13) .. WaitUntilDone(32).
  TSapiVoiceVtable = record
    QueryInterface: Pointer;
    AddRef: Pointer;
    Release: TSapiReleaseProc;
    SetNotifySink: Pointer;
    SetNotifyWindowMessage: Pointer;
    SetNotifyCallbackFunction: Pointer;
    SetNotifyCallbackInterface: Pointer;
    SetNotifyWin32Event: Pointer;
    WaitForNotifyEvent: Pointer;
    GetNotifyEventHandle: Pointer;
    SetInterest: Pointer;
    GetEvents: Pointer;
    GetInfo: Pointer;
    SetOutput: Pointer;
    GetOutputObjectToken: Pointer;
    GetOutputStream: Pointer;
    Pause: Pointer;
    Resume: Pointer;
    SetVoice: Pointer;
    GetVoice: Pointer;
    Speak: TSapiSpeakProc;
    SpeakStream: Pointer;
    GetStatus: TSapiGetStatusProc;
    Skip: Pointer;
    SetPriority: Pointer;
    GetPriority: Pointer;
    SetAlertBoundary: Pointer;
    GetAlertBoundary: Pointer;
    SetRate: TSapiSetRateProc;
    GetRate: Pointer;
    SetVolume: TSapiSetVolumeProc;
    GetVolume: Pointer;
    WaitUntilDone: TSapiWaitProc;
  end;
  PSapiVoiceVtable = ^TSapiVoiceVtable;

  PSapiVoice = ^TSapiVoice;
  TSapiVoice = record
    lpVtbl: PSapiVoiceVtable;
  end;

{ ole32 / kernel32 imports for raw COM. Declared here (not via Winapi.Windows)
  so the unit also compiles with older Delphi versions that lack them. }
function CoInitializeEx(pvReserved: Pointer; coInit: Cardinal): HResult; stdcall;
  external 'ole32.dll' name 'CoInitializeEx';
procedure CoUninitialize; stdcall; external 'ole32.dll' name 'CoUninitialize';
function CoCreateInstance(clsid: PGUID; unkOuter: Pointer;
  dwClsContext: Cardinal; iid: PGUID; out pv): HResult; stdcall;
  external 'ole32.dll' name 'CoCreateInstance';

{##############################################################################}
{# Worker thread                                                              #}
{##############################################################################}

type
  TYutaniTtsWorkerThread = class(TThread)
  private
    FOwner: TYutaniPiperTTS;
    FSapiVoice: PSapiVoice;             // COM voice (created lazily, worker STA)
    FSapiComReady: Boolean;
    function EnsureSapiVoice: PSapiVoice;
    procedure SpeakViaSapi(const AText: string);
    procedure SpeakViaSherpa(const AText: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TYutaniPiperTTS);
    destructor Destroy; override;
  end;

constructor TYutaniTtsWorkerThread.Create(AOwner: TYutaniPiperTTS);
begin
  FOwner := AOwner;
  FSapiComReady := False;
  FSapiVoice := nil;
  inherited Create(False); // start immediately
end;

destructor TYutaniTtsWorkerThread.Destroy;
begin
  if FSapiVoice <> nil then
  begin
    FSapiVoice^.lpVtbl^.Release(FSapiVoice);
    FSapiVoice := nil;
  end;
  if FSapiComReady then
  begin
    CoUninitialize;
    FSapiComReady := False;
  end;
  inherited;
end;

function TYutaniTtsWorkerThread.EnsureSapiVoice: PSapiVoice;
var
  HR: HResult;
  Unk: PSapiVoice;
begin
  Result := FSapiVoice;
  if Result <> nil then
    Exit;

  if not FSapiComReady then
  begin
    // SAPI objects are apartment aware; a worker thread needs its own init.
    HR := CoInitializeEx(nil, COINIT_APARTMENTTHREADED);
    if Failed(HR) and (HR <> HResult($80010106)) then // RPC_E_CHANGED_MODE: use the existing init
      raise Exception.CreateFmt('CoInitializeEx failed: 0x%.8x', [Cardinal(HR)]);
    FSapiComReady := True;
  end;

  Unk := nil;
  HR := CoCreateInstance(@CLSID_SpVoice, nil, CLSCTX_INPROC_SERVER,
    @IID_ISpVoice, Unk);
  if Failed(HR) or (Unk = nil) then
    raise Exception.CreateFmt('CoCreateInstance(SpVoice) failed: 0x%.8x', [Cardinal(HR)]);

  Unk^.lpVtbl^.SetRate(Unk, FOwner.FSapiRate);
  Unk^.lpVtbl^.SetVolume(Unk, FOwner.FSapiVolume);

  FSapiVoice := Unk;
  Result := Unk;
end;

procedure TYutaniTtsWorkerThread.SpeakViaSapi(const AText: string);
{ SAPI renders the audio itself; we do not see the samples, so the mouth
  amplitude is approximated by modulating a smoothed envelope while
  dwRunningState reports SPRS_IS_SPEAKING (documented approximation). }
var
  Voice: PSapiVoice;
  HR: HResult;
  Status: TSpVoiceStatus;
  T0, T1: Cardinal;
  Phase: Single;
  StartEpoch, CurEpoch: Integer;
begin
  Voice := EnsureSapiVoice;

  HR := Voice^.lpVtbl^.Speak(Voice, PWideChar(AText),
    SPF_ASYNC or SPF_PURGEBEFORESPEAK, nil);
  if Failed(HR) then
    raise Exception.CreateFmt('ISpVoice::Speak failed: 0x%.8x', [Cardinal(HR)]);

  StartEpoch := FOwner.FCancelEpoch;

  // Poll until SAPI reports done / the utterance is cancelled / shutdown.
  T0 := GetTickCount;
  repeat
    HR := Voice^.lpVtbl^.WaitUntilDone(Voice, 30);
    FillChar(Status, SizeOf(Status), 0);
    Voice^.lpVtbl^.GetStatus(Voice, @Status, nil);

    CurEpoch := FOwner.FCancelEpoch;
    if (CurEpoch <> StartEpoch) or FOwner.FShutdown then
    begin
      Voice^.lpVtbl^.Speak(Voice, nil, SPF_PURGEBEFORESPEAK, nil);
      Break;
    end;

    if (Status.dwRunningState and SPRS_IS_SPEAKING) <> 0 then
    begin
      // ~3.3 Hz jaw movement, smoothed
      T1 := GetTickCount - T0;
      Phase := Sin(T1 * 0.0207);
      FOwner.Amplitude := 0.45 + 0.35 * Phase;
    end
    else
      FOwner.Amplitude := 0.0;
  until (HR = S_OK) or ((Status.dwRunningState and SPRS_IS_SPEAKING) = 0);

  FOwner.Amplitude := 0.0;
end;

procedure TYutaniTtsWorkerThread.SpeakViaSherpa(const AText: string);
var
  Utf8: RawByteString;
  Audio: PSherpaOnnxGeneratedAudio;
  Cleaned: string;
  StartEpoch, CurEpoch: Integer;
  OldDir, VoiceDir: string;
  GenCfg: SherpaOnnxGenerationConfig;
begin
  { Typographic characters are poison for espeak-ng inside sherpa-onnx:
    en dash, em dash, German low/high quotes, curly apostrophe and ellipsis
    frequently make the tokenizer bail out and the generate call return
    nil. Normalize to plain ASCII BEFORE the text reaches the C API. }
  Cleaned := AText;
  Cleaned := StringReplace(Cleaned, #$2013, '-', [rfReplaceAll]);  // EN DASH
  Cleaned := StringReplace(Cleaned, #$2014, '-', [rfReplaceAll]);  // EM DASH
  Cleaned := StringReplace(Cleaned, #$201E, '"', [rfReplaceAll]); // DOUBLE LOW-9 QUOTE
  Cleaned := StringReplace(Cleaned, #$201C, '"', [rfReplaceAll]); // LEFT DOUBLE QUOTE
  Cleaned := StringReplace(Cleaned, #$201D, '"', [rfReplaceAll]); // RIGHT DOUBLE QUOTE
  Cleaned := StringReplace(Cleaned, #$2019, #$27, [rfReplaceAll]); // RIGHT SINGLE QUOTE
  Cleaned := StringReplace(Cleaned, #$2026, '...', [rfReplaceAll]); // HORIZONTAL ELLIPSIS

  Utf8 := UTF8Encode(Cleaned);
  OldDir := GetCurrentDir;
  VoiceDir := ExtractFileDir(FOwner.FModelPath);
  if DirectoryExists(VoiceDir) then
    SetCurrentDir(VoiceDir);
  try
    if Assigned(TYutaniPiperTTS._SherpaOfflineTtsGenerateWithConfig) then
    begin
      FillChar(GenCfg, SizeOf(GenCfg), 0);
      GenCfg.silence_scale := 0.2;
      GenCfg.speed := FOwner.FSpeed;
      GenCfg.sid := FOwner.FSpeakerId;
      GenCfg.reference_text := PAnsiChar('');
      GenCfg.num_steps := 5;
      GenCfg.extra := PAnsiChar('');
      Audio := TYutaniPiperTTS._SherpaOfflineTtsGenerateWithConfig(FOwner.FTts,
        PAnsiChar(Utf8), @GenCfg, nil, nil);
    end
    else
      Audio := TYutaniPiperTTS._SherpaOfflineTtsGenerate(FOwner.FTts,
        PAnsiChar(Utf8), FOwner.FSpeakerId, FOwner.FSpeed);
  finally
    SetCurrentDir(OldDir);
  end;

  if Audio = nil then
  begin
    { NOT a silent abort: a nil-generate (ORT loader hiccup, thread
      trouble, model quirk) must still make the avatar AUDIBLE - log the
      reason and hand the utterance to Windows SAPI right away. The
      generated-sample path below is skipped entirely (SAPI renders its
      own audio), the wait loop keeps the anti-echo / drain semantics. }
    FOwner.DoFallback('SherpaOnnxOfflineTtsGenerate returned nil - falling back to Windows SAPI');
    SpeakViaSapi(Cleaned);
    Exit;
  end;

  StartEpoch := FOwner.FCancelEpoch;
  try
    if (Audio^.samples <> nil) and (Audio^.n > 0) then
      FOwner.WorkerAppendSamples(Audio^.samples, Audio^.n, Audio^.sample_rate);
  finally
    TYutaniPiperTTS._SherpaDestroyOfflineTtsAudio(Audio);
  end;

  // Wait until the mixer has drained the playback buffer.
  while (not FOwner.FShutdown) do
  begin
    CurEpoch := FOwner.FCancelEpoch;
    if CurEpoch <> StartEpoch then
    begin
      FOwner.WorkerClearBuffer;
      Break;
    end;
    if FOwner.WorkerDrained then
      Break;
    Sleep(15);
  end;
end;


procedure TYutaniTtsWorkerThread.Execute;
var
  Text: string;
begin
  while not FOwner.FShutdown do
  begin
    WaitForSingleObject(FOwner.FWakeup, 100);

    while (not FOwner.FShutdown) do
    begin
      // dequeue one utterance
      EnterCriticalSection(FOwner.FQueueLock);
      try
        if FOwner.FQueue.Count = 0 then
          Text := ''
        else
        begin
          Text := FOwner.FQueue[0];
          FOwner.FQueue.Delete(0);
        end;
      finally
        LeaveCriticalSection(FOwner.FQueueLock);
      end;

      if Text = '' then
        Break;

      FOwner.Speaking := True;
      FOwner.WorkerFireStart(Text);
      try
        if FOwner.EngineKind = tekSherpaPiper then
          SpeakViaSherpa(Text)
        else
          SpeakViaSapi(Text);
      except
        on E: Exception do
          FOwner.DoError(E.Message);
      end;
      FOwner.Amplitude := 0.0;
      FOwner.Speaking := False;
      FOwner.WorkerFireEnd(Text);
    end;
  end;
end;

{##############################################################################}
{# Class-level sherpa DLL management                                          #}
{##############################################################################}

class constructor TYutaniPiperTTS.ClassCreate;
begin
  FModule := 0;
  FModuleLoaded := False;
  FModuleStatus := '';
  InitializeCriticalSection(FModuleLock);
end;

class destructor TYutaniPiperTTS.ClassDestroy;
begin
  if FModule <> 0 then
  begin
    FreeLibrary(FModule);
    FModule := 0;
  end;
  FModuleLoaded := False;
  DeleteCriticalSection(FModuleLock);
end;

class procedure TYutaniPiperTTS.EnsureModuleLoaded;
var
  OldMode: Cardinal;
  HasGeneratedAudioExport: Boolean;
  SherpaInExe, SherpaInSub, OnnxRtInExe, OnnxRtInSub: Boolean;

  { "EXE folder", "sherpa\ subfolder", "both" or "missing" for the
    diagnosis text above. }
  function DllLocationText(AInExe, AInSub: Boolean): string;
  begin
    if AInExe and AInSub then
      Result := 'in both the EXE folder and sherpa\'
    else if AInExe then
      Result := 'in the EXE folder'
    else if AInSub then
      Result := 'in sherpa\'
    else
      Result := 'MISSING';
  end;

begin
  if FModuleLoaded then
    Exit;
  EnterCriticalSection(FModuleLock);
  try
    if FModuleLoaded then
      Exit;

    // Search order: application directory, then the 'sherpa\' subfolder.
    // SetDllDirectoryW also lets Windows resolve the runtime DLLs that
    // sherpa-onnx-c-api.dll depends on (onnxruntime.dll etc.).
    // Pre-flight diagnosis: report WHERE the sherpa DLL and onnxruntime.dll
    // actually sit (EXE folder / sherpa subfolder / nowhere), because
    // "DLL not found" alone hides the common case of onnxruntime.dll sitting
    // in sherpa\ while sherpa-onnx-c-api.dll sits in the EXE folder (or vice
    // versa) - Windows only resolves dependencies through ONE of those
    // search paths per LoadLibrary call.
    SherpaInExe := FileExists(IncludeTrailingPathDelimiter(
      ExtractFilePath(ParamStr(0))) + SHERPA_LIB);
    SherpaInSub := FileExists(IncludeTrailingPathDelimiter(
      ExtractFilePath(ParamStr(0))) + 'sherpa\' + SHERPA_LIB);
    OnnxRtInExe := FileExists(IncludeTrailingPathDelimiter(
      ExtractFilePath(ParamStr(0))) + 'onnxruntime.dll');
    OnnxRtInSub := FileExists(IncludeTrailingPathDelimiter(
      ExtractFilePath(ParamStr(0))) + 'sherpa\onnxruntime.dll');
    OldMode := SetErrorMode(SEM_FAILCRITICALERRORS);
    try
      SetDllDirectoryW(PChar(IncludeTrailingPathDelimiter(
        ExtractFilePath(ParamStr(0)) + 'sherpa')));
      try
        FModule := LoadLibraryA(SHERPA_LIB);
      finally
        SetDllDirectoryW(nil);
      end;
    finally
      SetErrorMode(OldMode);
    end;

    if FModule = 0 then
    begin
      FModuleStatus := Format('"%s" not found (Win32 error %d). ' +
        'Searched the EXE folder and the sherpa\ subfolder - place the ' +
        'sherpa-onnx runtime DLL (and onnxruntime.dll) there. ' +
        'Diagnosis: sherpa-onnx-c-api.dll %s, onnxruntime.dll %s.',
        [SHERPA_LIB, GetLastError,
         DllLocationText(SherpaInExe, SherpaInSub),
         DllLocationText(OnnxRtInExe, OnnxRtInSub)]);
      FModuleLoaded := True;
      Exit;
    end;

    @_SherpaCreateOfflineTts := GetProcAddress(FModule, 'SherpaOnnxCreateOfflineTts');
    @_SherpaDestroyOfflineTts := GetProcAddress(FModule, 'SherpaOnnxDestroyOfflineTts');
    @_SherpaOfflineTtsSampleRate := GetProcAddress(FModule, 'SherpaOnnxOfflineTtsSampleRate');
    @_SherpaOfflineTtsGenerate := GetProcAddress(FModule, 'SherpaOnnxOfflineTtsGenerate');
    @_SherpaOfflineTtsGenerateWithConfig := GetProcAddress(FModule, 'SherpaOnnxOfflineTtsGenerateWithConfig');


    // Export was renamed at some point - accept both names.
    @_SherpaDestroyOfflineTtsAudio := GetProcAddress(FModule, 'SherpaOnnxDestroyOfflineTtsGeneratedAudio');
    if @_SherpaDestroyOfflineTtsAudio = nil then
    begin
      @_SherpaDestroyOfflineTtsAudio := GetProcAddress(FModule, 'SherpaOnnxDestroyOfflineTtsAudio');
      HasGeneratedAudioExport := @_SherpaDestroyOfflineTtsAudio <> nil;
    end
    else
      HasGeneratedAudioExport := True;

    if (@_SherpaCreateOfflineTts = nil) or (@_SherpaDestroyOfflineTts = nil) or
       (@_SherpaOfflineTtsGenerate = nil) or (not HasGeneratedAudioExport) then
    begin
      FModuleStatus := Format('"%s" does not export the required offline ' +
        'TTS functions - wrong or too old DLL.', [SHERPA_LIB]);
      FreeLibrary(FModule);
      FModule := 0;
      FModuleLoaded := True;
      Exit;
    end;

    FModuleStatus := '';
    { Optional version probe: SherpaOnnxGetVersionStr is exported since
      sherpa-onnx ~v1.9.x. Older DLLs simply do not have it - the version
      is then reported as "unknown" instead of failing the load. The
      C-API struct layout the DLL expects is tied to its version, so
      seeing "v1.10.x" vs "v1.9.y" in the log immediately explains
      CreateOfflineTts struct-size mismatches. String stays DLL-owned. }
    @_SherpaGetVersionStr := GetProcAddress(FModule, 'SherpaOnnxGetVersionStr');
    if @_SherpaGetVersionStr <> nil then
      FLibraryVersion := string(AnsiString(_SherpaGetVersionStr()))
    else
      FLibraryVersion := 'unknown (GetVersionStr not exported)';
    FModuleLoaded := True;
  finally
    LeaveCriticalSection(FModuleLock);
  end;
end;

function SherpaTtsLibraryAvailable: Boolean;
begin
  TYutaniPiperTTS.EnsureModuleLoaded;
  Result := TYutaniPiperTTS.FModule <> 0;
end;

function SherpaTtsLibraryStatus: string;
begin
  TYutaniPiperTTS.EnsureModuleLoaded;
  Result := TYutaniPiperTTS.FModuleStatus;
end;

function SherpaTtsLibraryVersion: string;
begin
  TYutaniPiperTTS.EnsureModuleLoaded;
  Result := TYutaniPiperTTS.FLibraryVersion;
end;

{##############################################################################}
{# Custom ma_data_source callbacks (called from the MiniAudio mixer thread)    #}
{##############################################################################}

function TtsDsRead(pDS: Pointer; pFramesOut: Pointer; frameCount: UInt64;
  pFramesRead: PUInt64): Integer; cdecl;
{ Feeds samples from the ring buffer. IMPORTANT: never reports the end of the
  stream - missing frames are delivered as silence so the permanent voice
  sound keeps playing (miniaudio treats "0 frames read" as end-of-stream and
  would stop the sound otherwise). }
var
  DS: PYutaniTtsDataSource;
  TTS: TYutaniPiperTTS;
  Frames, Avail, Chunk, Src, Done, Cap: Integer;
  Dst: PSingle;
begin
  DS := PYutaniTtsDataSource(pDS);
  TTS := TYutaniPiperTTS(DS^.Owner);
  Frames := Integer(frameCount);
  Dst := PSingle(pFramesOut);

  if Frames > 0 then
    FillChar(Dst^, Frames * SizeOf(Single), 0); // default: silence

  EnterCriticalSection(TTS.FPlayLock);
  try
    Avail := Integer(TTS.FTotalAppended - TTS.FTotalRead); // frames (mono)
    if Avail > Frames then
      Avail := Frames;
    if (Avail > 0) and (Length(TTS.FSamples) > 0) then
    begin
      // copy out (ring); may wrap at the end of the storage array
      Cap := Length(TTS.FSamples);
      Src := Integer(TTS.FTotalRead mod UInt64(Cap));
      Done := 0;
      while Done < Avail do
      begin
        Chunk := Cap - Src;
        if Chunk > Avail - Done then
          Chunk := Avail - Done;
        Move(TTS.FSamples[Src], (Dst + Done)^, Chunk * SizeOf(Single));
        TTS.FTotalRead := TTS.FTotalRead + UInt64(Chunk);
        Done := Done + Chunk;
        Src := 0;
      end;
    end;
    // smoothed RMS envelope for the mouth (attack fast, release slow)
    TTS.UpdateAmplitude(Dst, Frames);
  finally
    LeaveCriticalSection(TTS.FPlayLock);
  end;

  { pFramesRead may be nil (miniaudio calls the reader with a NULL out
    counter in some paths) - writing through it would AV instantly. }
  if pFramesRead <> nil then
    pFramesRead^ := frameCount; // ALWAYS the requested count
  Result := MA_SUCCESS;         // never MA_AT_END
end;

function TtsDsSeek(pDS: Pointer; frameIndex: UInt64): Integer; cdecl;
begin
  Result := MA_NOT_IMPLEMENTED;
end;

function TtsDsGetDataFormat(pDS: Pointer; pFormat: PCardinal;
  pChannels: PCardinal; pSampleRate: PCardinal; pChannelMap: Pointer;
  channelMapCap: NativeUInt): Integer; cdecl;
var
  DS: PYutaniTtsDataSource;
  TTS: TYutaniPiperTTS;
begin
  DS := PYutaniTtsDataSource(pDS);
  TTS := TYutaniPiperTTS(DS^.Owner);
  if pFormat <> nil then
    pFormat^ := MA_FORMAT_F32;
  if pChannels <> nil then
    pChannels^ := 1; // mono
  if pSampleRate <> nil
    then pSampleRate^ := Cardinal(TTS.FDataSourceSampleRate);
  if (pChannelMap <> nil) and (channelMapCap > 0) then
    PCardinal(pChannelMap)^ := 1; // MA_CHANNEL_MONO
  Result := MA_SUCCESS;
end;

function TtsDsGetCursor(pDS: Pointer; pCursor: PUInt64): Integer; cdecl;
var
  DS: PYutaniTtsDataSource;
  TTS: TYutaniPiperTTS;
begin
  DS := PYutaniTtsDataSource(pDS);
  TTS := TYutaniPiperTTS(DS^.Owner);
  if pCursor <> nil then
    pCursor^ := TTS.FTotalRead;
  Result := MA_SUCCESS;
end;

function TtsDsGetLength(pDS: Pointer; pLength: PUInt64): Integer; cdecl;
begin
  if pLength <> nil then
    pLength^ := 0; // unknown / endless
  Result := MA_NOT_IMPLEMENTED;
end;

function TtsDsSetLooping(pDS: Pointer; isLooping: Integer): Integer; cdecl;
begin
  Result := MA_SUCCESS; // accepted, ignored
end;

var
  // Single shared vtable - state lives in the data source object.
  GTtsDataSourceVtable: TMaDataSourceVtable;

{##############################################################################}
{# TYutaniPiperTTS                                                            #}
{##############################################################################}

constructor TYutaniPiperTTS.Create;
begin
  inherited Create;

  FTts := nil;
  FEngineKind := tekUninitialized;
  FEngine := nil;
  FSound := nil;
  FDataSourceSampleRate := 22050; // piper default, corrected in SetupPiperVoice

  FShutdown := False;
  FCancelSpeak := False;
  FCancelEpoch := 0;
  FSpeaking := False;
  FAmplitude := 0.0;

  InitializeCriticalSection(FQueueLock);
  FQueue := TStringList.Create;

  InitializeCriticalSection(FPlayLock);
  SetLength(FSamples, 0);
  FTotalAppended := 0;
  FTotalRead := 0;

  // Piper defaults (see sherpa-onnx piper examples)
  FModelPath := '';
  FLexiconPath := '';
  FTokensPath := '';
  FEspeakDataDir := '';
  FDictDir := '';
  FRuleFsts := '';
  FNoiseScale := PIPER_DEFAULT_NOISE_SCALE;
  FNoiseScaleW := PIPER_DEFAULT_NOISE_SCALE_W;
  FLengthScale := PIPER_DEFAULT_LENGTH_SCALE;
  FNumThreads := PIPER_DEFAULT_NUM_THREADS;
  FDebug := 1;
  FProvider := 'cpu';
  FMaxNumSentences := PIPER_DEFAULT_MAX_SENTENCES;
  FSilenceScale := PIPER_DEFAULT_SILENCE_SCALE;
  FSpeakerId := 0;
  FSpeed := 1.0;
  FSapiRate := 0;
  FSapiVolume := 100;

  FWakeup := CreateEvent(nil, False, False, nil);

  // data source: static vtable + base defaults
  FillChar(GTtsDataSourceVtable, SizeOf(GTtsDataSourceVtable), 0);
  GTtsDataSourceVtable.onRead := TtsDsRead;
  GTtsDataSourceVtable.onSeek := TtsDsSeek;
  GTtsDataSourceVtable.onGetDataFormat := TtsDsGetDataFormat;
  GTtsDataSourceVtable.onGetCursor := TtsDsGetCursor;
  GTtsDataSourceVtable.onGetLength := TtsDsGetLength;
  GTtsDataSourceVtable.onSetLooping := TtsDsSetLooping;
  GTtsDataSourceVtable.flags := 0; // range/loop handled by miniaudio defaults

  FillChar(FDataSource, SizeOf(FDataSource), 0);
  FDataSource.Base.vtable := @GTtsDataSourceVtable;
  FDataSource.Base.rangeBegInFrames := 0;
  FDataSource.Base.rangeEndInFrames := UInt64(-1); // unranged
  FDataSource.Base.loopBegInFrames := 0;
  FDataSource.Base.loopEndInFrames := UInt64(-1);
  FDataSource.Base.isLooping := 0;
  FDataSource.Owner := Self;

  FWorker := TYutaniTtsWorkerThread.Create(Self);
end;

destructor TYutaniPiperTTS.Destroy;
begin
  // stop the worker first (it references us)
  FShutdown := True;
  SetEvent(FWakeup);
  if FWorker <> nil then
  begin
    FWorker.Terminate;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;

  // free the MiniAudio voice sound (must happen on the engine thread; the
  // class contract says the owner destroys the engine AFTER the TTS object)
  if FSound <> nil then
  begin
    ma_sound_uninit(FSound);
    FreeMem(FSound);
    FSound := nil;
  end;

  if FTts <> nil then
  begin
    _SherpaDestroyOfflineTts(FTts);
    FTts := nil;
  end;

  if FWakeup <> 0 then
  begin
    CloseHandle(FWakeup);
    FWakeup := 0;
  end;

  FreeAndNil(FQueue);
  DeleteCriticalSection(FQueueLock);
  DeleteCriticalSection(FPlayLock);

  inherited;
end;

function TYutaniPiperTTS.GetSampleRate: Integer;
begin
  Result := FDataSourceSampleRate;
end;

procedure TYutaniPiperTTS.SetModelPath(const Value: string);
begin
  FModelPath := Value;
end;

procedure TYutaniPiperTTS.UpdateAmplitude(const ABuffer: PSingle; AFrames: Integer);
{ Called from the data source read (mixer thread), inside FPlayLock.
  Computes a smoothed RMS envelope over the mixed output frames. }
const
  ATTACK = 0.55;  // fast open
  RELEASE = 0.12; // slow close
var
  I: Integer;
  Sum: Double;
  Rms, Target: Single;
begin
  if (ABuffer = nil) or (AFrames <= 0) then
  begin
    FAmplitude := FAmplitude * (1.0 - RELEASE);
    Exit;
  end;

  Sum := 0.0;
  for I := 0 to AFrames - 1 do
    Sum := Sum + ABuffer[I] * ABuffer[I];
  Rms := Sqrt(Sum / AFrames);

  // normalize: piper voices rarely exceed ~0.35 RMS on speech
  Target := Min(1.0, Rms * 3.0);

  if Target > FAmplitude then
    FAmplitude := FAmplitude + (Target - FAmplitude) * ATTACK
  else
    FAmplitude := FAmplitude + (Target - FAmplitude) * RELEASE;
end;

procedure TYutaniPiperTTS.WorkerAppendSamples(const ASamples: PSingle;
  ACount: Integer; ASampleRate: Integer);
{ Worker thread: appends generated samples to the ring buffer, growing it as
  needed. Ring positions are derived from the absolute counters
  (FTotalAppended / FTotalRead), so reader and writer stay consistent without
  separate index bookkeeping. Samples at a different rate than the data
  source rate are rejected with an OnError note (piper always generates the
  model's fixed rate, so in practice this never triggers). }
var
  Used, Needed, Chunk, Offs, Dst: Integer;
begin
  if (ASamples = nil) or (ACount <= 0) then
    Exit;

  if ASampleRate <> FDataSourceSampleRate then
  begin
    DoError(Format('TTS sample rate %d does not match data source rate %d - ' +
      'call SetupPiperVoice before AttachEngine.', [ASampleRate, FDataSourceSampleRate]));
    Exit;
  end;

  EnterCriticalSection(FPlayLock);
  try
    Used := Integer(FTotalAppended - FTotalRead);

    // capacity: used data + the new utterance + 50% headroom, 4096-aligned
    Needed := (((Used + ACount) * 3) div 2 + 4095) and not 4095;
    if Needed < 8192 then
      Needed := 8192;
    if Needed > Length(FSamples) then
      SetLength(FSamples, Needed);
    if Length(FSamples) = 0 then
      Exit; // out of memory guard (SetLength failed silently)

    // copy in (ring); the buffer always has room because it was sized above
    Offs := 0;
    while Offs < ACount do
    begin
      Dst := Integer(FTotalAppended mod UInt64(Length(FSamples)));
      Chunk := Length(FSamples) - Dst;
      if Chunk > ACount - Offs then
        Chunk := ACount - Offs;
      Move((ASamples + Offs)^, FSamples[Dst], Chunk * SizeOf(Single));
      FTotalAppended := FTotalAppended + UInt64(Chunk);
      Offs := Offs + Chunk;
    end;
  finally
    LeaveCriticalSection(FPlayLock);
  end;
end;

procedure TYutaniPiperTTS.WorkerClearBuffer;
begin
  EnterCriticalSection(FPlayLock);
  try
    FTotalAppended := 0;
    FTotalRead := 0;
    SetLength(FSamples, 0);
    FAmplitude := 0.0;
  finally
    LeaveCriticalSection(FPlayLock);
  end;
end;

function TYutaniPiperTTS.WorkerDrained: Boolean;
begin
  EnterCriticalSection(FPlayLock);
  try
    Result := FTotalAppended = FTotalRead;
  finally
    LeaveCriticalSection(FPlayLock);
  end;
end;

procedure TYutaniPiperTTS.WorkerSetSpeaking(AValue: Boolean);
begin
  FSpeaking := AValue;
end;

procedure TYutaniPiperTTS.WorkerFireStart(const AText: string);
begin
  if Assigned(FOnSpeakStart) then
    FOnSpeakStart(Self, AText);
end;

procedure TYutaniPiperTTS.WorkerFireEnd(const AText: string);
begin
  if Assigned(FOnSpeakEnd) then
    FOnSpeakEnd(Self, AText);
end;

procedure TYutaniPiperTTS.DoError(const AMsg: string);
begin
  if Assigned(FOnError) then
    FOnError(Self, AMsg);
end;

procedure TYutaniPiperTTS.DoFallback(const AReason: string);
begin
  if Assigned(FOnFallback) then
    FOnFallback(Self, AReason);
end;

{##############################################################################}
{# Setup / engine attach / public speak API                                   #}
{##############################################################################}

function ToAnsiBuffer(const S: string; out Buffer: AnsiString): PAnsiChar;
{ Converts a Delphi string to a UTF-8 AnsiString; returns nil for '' so we
  can pass clean NULL pointers to the C API. }
begin
  if S = '' then
  begin
    Buffer := '';
    Result := nil;
  end
  else
  begin
    Buffer := AnsiString(UTF8Encode(S));
    Result := PAnsiChar(Buffer);
  end;
end;

function TYutaniPiperTTS.SetupPiperVoice(const AModelPath, ATokensPath,
  AEspeakDataDir: string; const ALexiconPath, ADictDir: string): Boolean;
var
  Config: SherpaOnnxOfflineTtsConfig;
  ModelBuf, LexiconBuf, TokensBuf, DataDirBuf, DictDirBuf,
    RuleFstsBuf, ProviderBuf: AnsiString;
  SampleRate: Integer;
  Reason: string;
  FwdModelPath, FwdTokensPath, FwdEspeakDataDir, FwdLexiconPath,
    FwdDictDir: string;

  { sherpa-onnx (onnxruntime file IO) prefers forward slashes: a plain
    'C:\models\voice.onnx' can fail deep inside the ORT loader and the
    generate call then returns nil. One shared normalization; the
    FileExists / DirectoryExists checks above keep the ORIGINAL Delphi
    backslash paths. }
  function Fwd(const S: string): string;
  begin
    Result := StringReplace(S, '\', '/', [rfReplaceAll]);
  end;

begin
  Result := False;

  if FEngineKind <> tekUninitialized then
  begin
    DoError('SetupPiperVoice called twice - create a new TYutaniPiperTTS ' +
      'instance to change the voice.');
    Exit;
  end;

  // remember the paths (also used by the properties)
  FModelPath := AModelPath;
  FTokensPath := ATokensPath;
  FEspeakDataDir := AEspeakDataDir;
  FLexiconPath := ALexiconPath;
  FDictDir := ADictDir;

  // --- can we use sherpa-onnx at all? ---
  EnsureModuleLoaded;
  if FModule = 0 then
  begin
    FEngineKind := tekSapi;
    Reason := SherpaTtsLibraryStatus;
    DoFallback(Reason);
    Exit; // False -> caller knows SAPI is active
  end;

  // --- model files present? ---
  if (not FileExists(AModelPath)) or (not FileExists(ATokensPath)) then
  begin
    FEngineKind := tekSapi;
    Reason := Format('Piper model file not found: %s / %s',
      [AModelPath, ATokensPath]);
    DoFallback(Reason);
    Exit;
  end;
  if (AEspeakDataDir = '') and (ALexiconPath = '') then
  begin
    FEngineKind := tekSapi;
    Reason := 'Either the espeak-ng-data directory or a lexicon file is required.';
    DoFallback(Reason);
    Exit;
  end;
  if (AEspeakDataDir <> '') and (not DirectoryExists(AEspeakDataDir)) then
  begin
    FEngineKind := tekSapi;
    Reason := Format('espeak-ng-data directory not found: %s', [AEspeakDataDir]);
    DoFallback(Reason);
    Exit;
  end;

  // --- build the config (zero everything first!) ---
  // Path conversion happens HERE, right before the C API sees the strings.
  FwdModelPath := Fwd(AModelPath);
  FwdTokensPath := Fwd(ATokensPath);
  FwdEspeakDataDir := Fwd(AEspeakDataDir);
  FwdLexiconPath := Fwd(ALexiconPath);
  FwdDictDir := Fwd(ADictDir);
  FillChar(Config, SizeOf(Config), 0);
  Config.model.vits.model := ToAnsiBuffer(FwdModelPath, ModelBuf);
  if FwdLexiconPath <> '' then
    Config.model.vits.lexicon := ToAnsiBuffer(FwdLexiconPath, LexiconBuf)
  else
    Config.model.vits.lexicon := PAnsiChar('');
  Config.model.vits.tokens := ToAnsiBuffer(FwdTokensPath, TokensBuf);
  if FwdEspeakDataDir <> '' then
    Config.model.vits.data_dir := ToAnsiBuffer(FwdEspeakDataDir, DataDirBuf)
  else
    Config.model.vits.data_dir := PAnsiChar('');
  if FwdDictDir <> '' then
    Config.model.vits.dict_dir := ToAnsiBuffer(FwdDictDir, DictDirBuf)
  else
    Config.model.vits.dict_dir := PAnsiChar('');
  Config.model.vits.noise_scale := FNoiseScale;
  Config.model.vits.noise_scale_w := FNoiseScaleW;
  Config.model.vits.length_scale := FLengthScale;
  Config.model.num_threads := 1;
  Config.model.debug := FDebug;
  ProviderBuf := 'cpu';
  Config.model.provider := PAnsiChar(ProviderBuf);
  if FRuleFsts <> '' then
    Config.rule_fsts := ToAnsiBuffer(FRuleFsts, RuleFstsBuf)
  else
    Config.rule_fsts := PAnsiChar('');
  Config.rule_fars := PAnsiChar('');
  Config.max_num_sentences := FMaxNumSentences;
  Config.silence_scale := FSilenceScale;

  var OldDir := GetCurrentDir;
  SetCurrentDir(ExtractFileDir(AModelPath));
  try
    FTts := _SherpaCreateOfflineTts(@Config);
  finally
    SetCurrentDir(OldDir);
  end;


  if FTts = nil then
  begin
    FEngineKind := tekSapi;
    Reason := 'SherpaOnnxCreateOfflineTts failed (check the model files / ' +
      'onnxruntime DLL versions).';
    DoFallback(Reason);
    Exit;
  end;

  // output rate of the loaded model
  SampleRate := 22050;
  if @_SherpaOfflineTtsSampleRate <> nil then
    SampleRate := _SherpaOfflineTtsSampleRate(FTts);
  if SampleRate <= 0 then
    SampleRate := 22050;
  FDataSourceSampleRate := SampleRate;

  FEngineKind := tekSherpaPiper;
  Result := True;
end;

procedure TYutaniPiperTTS.AttachEngine(AEngine: ma_engine);
const
  MA_SOUND_FLAG_NONE = 0;
var
  SoundSize: NativeUInt;
  HR: ma_result;
begin
  if AEngine = nil then
  begin
    DoError('AttachEngine: engine pointer is nil');
    Exit;
  end;
  FEngine := AEngine;
  if FEngineKind <> tekSherpaPiper then
    Exit; // SAPI mode does not need the MiniAudio engine

  // The permanent voice sound; MiniAudio4Delphi uses opaque pointers, so we
  // allocate the exact size ourselves. ma_sound_sizeof() can return 0 (or a
  // suspiciously small value) on DLL/build mismatches - GetMem(0) would hand
  // ma_sound_init_from_data_source a zero-byte buffer it happily writes
  // through. Floor at 16 KB, the same safe envelope the capture device uses
  // (sizeof(ma_sound) on Win64 is far below that).
  SoundSize := ma_sound_sizeof();
  if SoundSize < 16384 then
    SoundSize := 16384;
  GetMem(FSound, SoundSize);
  FillChar(FSound^, SoundSize, 0);

  HR := ma_sound_init_from_data_source(FEngine, @FDataSource,
    MA_SOUND_FLAG_NONE, nil { default group }, FSound);
  if HR <> MA_SUCCESS then
  begin
    DoError(Format('ma_sound_init_from_data_source failed: %d', [HR]));
    FreeMem(FSound);
    FSound := nil;
    Exit;
  end;

  // Permanent sound; never stopped. ma_sound_start is declared as a plain
  // PROCEDURE in MiniAudio4Delphi (no ma_result return available), so the
  // call cannot be checked here - the playback diagnosis in the pipeline
  // (ma_sound_is_playing + WAV probe right after AttachEngine) covers a
  // driver-side failed start instead.
  ma_sound_start(FSound);
end;

procedure TYutaniPiperTTS.Speak(const AText: string);
begin
  if FEngineKind = tekUninitialized then
  begin
    DoError('Speak called before SetupPiperVoice - ignoring.');
    Exit;
  end;
  if AText = '' then
    Exit;

  EnterCriticalSection(FQueueLock);
  try
    FQueue.Add(AText);
  finally
    LeaveCriticalSection(FQueueLock);
  end;
  SetEvent(FWakeup);
end;

procedure TYutaniPiperTTS.StopSpeaking;
begin
  // drop everything queued
  EnterCriticalSection(FQueueLock);
  try
    FQueue.Clear;
  finally
    LeaveCriticalSection(FQueueLock);
  end;

  // signal the running generation to abort + clear the playback buffer
  FCancelSpeak := True;
  Inc(FCancelEpoch);
  WorkerClearBuffer;
end;

function TYutaniPiperTTS.GetIsSpeaking: Boolean;
begin
  EnterCriticalSection(FQueueLock);
  try
    if FQueue.Count > 0 then
      Exit(True);
  finally
    LeaveCriticalSection(FQueueLock);
  end;
  Result := FSpeaking;
end;

end.
