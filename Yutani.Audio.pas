unit Yutani.Audio;

{==============================================================================*
 *  Yutani.Audio - TinySoundFont & MiniAudio Wrapper (Threaded Audio Engine)
 *------------------------------------------------------------------------------
 *  Description:
 *    Standalone audio engine. Handles dynamic DLL loading for TinySoundFont,
 *    and full MiniAudio integration (SFX Groups, 3D Audio, etc.).
 *    Low-latency TSF audio rendering via MMSystem (WaveOut).
 *    The audio thread spins up on demand when notes are played and pauses
 *    automatically (saving CPU) when idle for more than 2 seconds.
 *==============================================================================}
interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Diagnostics, Winapi.MMSystem, TinySoundFont, MiniAudio4Delphi;

type
  TYutaniAudioEngine = class
  private
    // TSF (TinySoundFont) Fields
    FTSFDLL: HMODULE;
    FTSF: Ptsf;
    FDLLLoaded: Boolean;
    FWaveOut: HWAVEOUT;
    FBuffer: PSingle;
    FWaveHdr: array[0..1] of TWaveHdr;
    FChunkBytes: Cardinal;
    FAudioThread: TThread;
    FLock: TCriticalSection;
    FIsRunning: Boolean;
    FNoteQueue: TArray<Integer>;
    FLastNoteTime: TStopwatch;
    FFramesToRender: Cardinal;
    // MiniAudio Fields
    FMAEngine: ma_engine;
    FSFXGroup: ma_sound_group;
    FMusicGroup: ma_sound_group;
    FMAInitialized: Boolean;
    procedure InitMiniAudio;
  public
    constructor Create;
    destructor Destroy; override;
    procedure InitAudio;
    procedure LoadSoundfont(const FilePath: string);
    procedure AddNote(MidiNote: Integer; Velocity: Single = 1.0);
    // Direct live play (bypasses queue, instant trigger)
    procedure PlayLiveNote(MidiNote: Integer; Velocity: Single = 1.0);
    // --- MiniAudio Convenience Methods ---
    procedure PlaySoundEffect(const FilePath: string; Volume: Single = 1.0);
    procedure SetSFXVolume(Volume: Single);
    procedure SetSFXPitch(Pitch: Single);
    procedure SetTSFPitch(Pitch: Single);
    procedure SetMusicVolume(Volume: Single);
    procedure SetMasterVolume(Volume: Single);
    function GetMAEngine: ma_engine;
  end;

implementation

const
  WAVE_FORMAT_IEEE_FLOAT = 3;
  IDLE_TIMEOUT_MS = 5000; // Pause thread after 5s of silence

{ TYutaniAudioEngine }

constructor TYutaniAudioEngine.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FTSF := nil;
  FDLLLoaded := False;
  FWaveOut := 0;
  FBuffer := nil;
  FIsRunning := False;
  FFramesToRender := 22050; // 0.5 seconds of audio at 44.1kHz
  FLastNoteTime := TStopwatch.Create;
  // MiniAudio states
  FMAInitialized := False;
  FMAEngine := nil;
  FSFXGroup := nil;
  FMusicGroup := nil;
end;

destructor TYutaniAudioEngine.Destroy;
begin
  FIsRunning := False;
  if Assigned(FAudioThread) then
  begin
    FAudioThread.WaitFor;
    FreeAndNil(FAudioThread);
  end;
  // 1. Cleanup TinySoundFont
  if Assigned(FTSF) then
    tsf_close(FTSF);
  if FWaveOut <> 0 then
  begin
    waveOutReset(FWaveOut);
    waveOutUnprepareHeader(FWaveOut, @FWaveHdr[0], SizeOf(TWaveHdr));
    waveOutUnprepareHeader(FWaveOut, @FWaveHdr[1], SizeOf(TWaveHdr));
    waveOutClose(FWaveOut);
  end;
  if Assigned(FBuffer) then
    FreeMem(FBuffer);
  if FTSFDLL <> 0 then
    FreeLibrary(FTSFDLL);
  // 2. Cleanup MiniAudio
  if FMAInitialized then
  begin
    if FSFXGroup <> nil then
    begin
      ma_sound_group_uninit(FSFXGroup);
      FreeMem(FSFXGroup);
    end;
    if FMusicGroup <> nil then
    begin
      ma_sound_group_uninit(FMusicGroup);
      FreeMem(FMusicGroup);
    end;
    if FMAEngine <> nil then
    begin
      ma_engine_uninit(FMAEngine);
      FreeMem(FMAEngine);
    end;
  end;
  FreeAndNil(FLock);
  inherited;
end;

procedure TYutaniAudioEngine.InitMiniAudio;
var
  Res: ma_result;
begin
  if FMAInitialized then
    Exit;
  // 1. Allocate and Init Main Engine
  // We allocate 8192 bytes. This is more than enough for the ma_engine struct.
  GetMem(FMAEngine, 8192);
  Res := ma_engine_init(nil, FMAEngine);
  if Res <> MA_SUCCESS then
  begin
    FreeMem(FMAEngine);
    FMAEngine := nil;
    raise Exception.Create('Failed to initialize MiniAudio engine!');
  end;
  // 2. Allocate and Init SFX Group
  GetMem(FSFXGroup, 2048); // 2KB is safe for groups
  Res := ma_sound_group_init(FMAEngine, 0, nil, FSFXGroup);
  if Res <> MA_SUCCESS then
  begin
    FreeMem(FSFXGroup);
    FSFXGroup := nil;
  end;
  // 3. Allocate and Init Music Group
  GetMem(FMusicGroup, 2048);
  Res := ma_sound_group_init(FMAEngine, 0, nil, FMusicGroup);
  if Res <> MA_SUCCESS then
  begin
    FreeMem(FMusicGroup);
    FMusicGroup := nil;
  end;
  FMAInitialized := True;
end;

procedure TYutaniAudioEngine.InitAudio;
var
  DllPath: string;
  Format: TWaveFormatEx;
begin
  // Initialize MiniAudio first! It doesn't depend on TSF
  InitMiniAudio;
  if FDLLLoaded then
    Exit;
  // 1. Load TinySoundFont DLL
  DllPath := ExtractFilePath(ParamStr(0)) + 'tinysoundfont.dll';
  FTSFDLL := SafeLoadLibrary(DllPath);
  if FTSFDLL = 0 then
    raise Exception.Create('tinysoundfont.dll not found!');
  @tsf_load_filename := GetProcAddress(FTSFDLL, 'dll_tsf_load_filename');
  @tsf_close := GetProcAddress(FTSFDLL, 'dll_tsf_close');
  @tsf_set_output := GetProcAddress(FTSFDLL, 'dll_tsf_set_output');
  @tsf_note_on := GetProcAddress(FTSFDLL, 'dll_tsf_note_on');
  @tsf_render_float := GetProcAddress(FTSFDLL, 'dll_tsf_render_float');
  @tsf_channel_set_presetnumber := GetProcAddress(FTSFDLL, 'dll_tsf_channel_set_presetnumber');
  @tsf_channel_note_on := GetProcAddress(FTSFDLL, 'dll_tsf_channel_note_on');
  if not (Assigned(tsf_load_filename) and Assigned(tsf_set_output) and Assigned(tsf_render_float)) then
    raise Exception.Create('TinySoundFont DLL functions not found!');
  FDLLLoaded := True;
  // 2. Init MMSystem WaveOut
  FillChar(Format, SizeOf(Format), 0);
  Format.wFormatTag := WAVE_FORMAT_IEEE_FLOAT;
  Format.nChannels := 2;
  Format.nSamplesPerSec := 44100;
  Format.wBitsPerSample := 32;
  Format.nBlockAlign := (Format.nChannels * Format.wBitsPerSample) div 8;
  Format.nAvgBytesPerSec := Format.nSamplesPerSec * Format.nBlockAlign;
  if waveOutOpen(@FWaveOut, WAVE_MAPPER, @Format, 0, 0, CALLBACK_NULL) <> MMSYSERR_NOERROR then
    raise Exception.Create('Failed to open WaveOut device!');
  FChunkBytes := 176400; // 0.5s buffer * 2 for double buffering
  GetMem(FBuffer, FChunkBytes * 2);
  FillChar(FBuffer^, FChunkBytes * 2, 0);
  FillChar(FWaveHdr[0], SizeOf(TWaveHdr), 0);
  FWaveHdr[0].lpData := PAnsiChar(FBuffer);
  FWaveHdr[0].dwBufferLength := FChunkBytes;
  waveOutPrepareHeader(FWaveOut, @FWaveHdr[0], SizeOf(TWaveHdr));
  FillChar(FWaveHdr[1], SizeOf(TWaveHdr), 0);
  FWaveHdr[1].lpData := PAnsiChar(FBuffer) + FChunkBytes;
  FWaveHdr[1].dwBufferLength := FChunkBytes;
  waveOutPrepareHeader(FWaveOut, @FWaveHdr[1], SizeOf(TWaveHdr));
end;

procedure TYutaniAudioEngine.LoadSoundfont(const FilePath: string);
begin
  if not FDLLLoaded then
    Exit;
  if Assigned(FTSF) then
  begin
    FLock.Enter;
    try
      tsf_close(FTSF);
      FTSF := nil;
    finally
      FLock.Leave;
    end;
  end;
  FTSF := tsf_load_filename(PAnsiChar(AnsiString(FilePath)));
  if Assigned(FTSF) then
  begin
    tsf_set_output(FTSF, TSF_STEREO_INTERLEAVED, 44100, 0.0);
    tsf_channel_set_presetnumber(FTSF, 0, 0, 0);
    // Start Thread if it isn't running yet
    if not FIsRunning then
    begin
      FIsRunning := True;
      FLastNoteTime.Reset;
      FLastNoteTime.Start;
      FAudioThread := TThread.CreateAnonymousThread(
        procedure
        var
          Timer: TStopwatch;
          Freq: Int64;
          TargetTicks, NowTicks, SpinTicks: Int64;
          BufIndex: Integer;
          LocalQueue: TArray<Integer>;
          i: Integer;
        begin
          Timer := TStopwatch.Create;
          Timer.Reset;
          Timer.Start;
          Freq := Timer.Frequency;
          SpinTicks := (2000000 * Freq) div 1000000000; // 2ms
          BufIndex := 0;
          TargetTicks := Timer.GetTimestamp;
          while FIsRunning do
          begin
            // --- 1. PROCESS NOTE QUEUE ---
            if Length(FNoteQueue) > 0 then
            begin
              FLock.Enter;
              try
                LocalQueue := Copy(FNoteQueue);
                SetLength(FNoteQueue, 0);
              finally
                FLock.Leave;
              end;
              if Assigned(FTSF) then
              begin
                for i := 0 to High(LocalQueue) do
                  tsf_channel_note_on(FTSF, 0, LocalQueue[i], 1.0);
              end;
            end;
            // --- 2. IDLE TIMEOUT LOGIC ---
            if FLastNoteTime.ElapsedMilliseconds > IDLE_TIMEOUT_MS then
            begin
              Sleep(50);
              TargetTicks := Timer.GetTimestamp;
              Continue;
            end;
            // --- 3. RENDER AUDIO CHUNK ---
            if Assigned(FTSF) then
              tsf_render_float(FTSF, System.PSingle(FWaveHdr[BufIndex].lpData), FFramesToRender, 0)
            else
              FillChar(FWaveHdr[BufIndex].lpData^, FChunkBytes, 0);
            // --- 4. QUEUE BUFFER TO SOUNDCARD ---
            waveOutWrite(FWaveOut, @FWaveHdr[BufIndex], SizeOf(TWaveHdr));
            BufIndex := BufIndex xor 1; // Ping-Pong
            // --- 5. PRECISE PACING ---
            TargetTicks := TargetTicks + (Freq div 2);
            NowTicks := Timer.GetTimestamp;
            if TargetTicks <= NowTicks then
              TargetTicks := NowTicks + (Freq div 2);
            while (TargetTicks - Timer.GetTimestamp) > SpinTicks do
              Sleep(1);
            while Timer.GetTimestamp < TargetTicks do
              ;
          end;
          waveOutReset(FWaveOut);
        end);
      FAudioThread.FreeOnTerminate := False;
      FAudioThread.Start;
    end;
  end
  else
    raise Exception.Create('Failed to load Soundfont!');
end;

procedure TYutaniAudioEngine.AddNote(MidiNote: Integer; Velocity: Single = 1.0);
begin
  FLock.Enter;
  try
    SetLength(FNoteQueue, Length(FNoteQueue) + 1);
    FNoteQueue[High(FNoteQueue)] := MidiNote;
  finally
    FLock.Leave;
  end;
  FLastNoteTime.Reset;
  FLastNoteTime.Start;
end;

procedure TYutaniAudioEngine.PlayLiveNote(MidiNote: Integer; Velocity: Single = 1.0);
begin
  if Assigned(FTSF) then
  begin
    tsf_channel_note_on(FTSF, 0, MidiNote, Velocity);
    FLastNoteTime.Reset;
    FLastNoteTime.Start;
  end;
end;
// =============================================================================
// MINIAUDIO CONVENIENCE METHODS
// =============================================================================

procedure TYutaniAudioEngine.PlaySoundEffect(const FilePath: string; Volume: Single = 1.0);
begin
  if not FMAInitialized then
    Exit;
  // Set volume for the SFX bus right before playing
  if FSFXGroup <> nil then
    ma_sound_group_set_volume(FSFXGroup, Volume);
  // Play sound routed into the SFX group
  ma_engine_play_sound(FMAEngine, PAnsiChar(AnsiString(FilePath)), FSFXGroup);
end;

procedure TYutaniAudioEngine.SetSFXVolume(Volume: Single);
begin
  if FMAInitialized and (FSFXGroup <> nil) then
    ma_sound_group_set_volume(FSFXGroup, Volume);
end;

procedure TYutaniAudioEngine.SetSFXPitch(Pitch: Single);
begin
  // Pitch 1.0 = Normal speed, 0.5 = Slow/Low, 2.0 = Fast/High
  if FMAInitialized and (FSFXGroup <> nil) then
    ma_sound_group_set_pitch(FSFXGroup, Pitch);
end;

procedure TYutaniAudioEngine.SetTSFPitch(Pitch: Single);
var
  TargetSampleRate: Integer;
begin
  if not Assigned(FTSF) then
    Exit;

  // Calculate the new sample rate based on the pitch (1.0 = normal)
  // Pitch 0.5 means we halve the sample rate, resulting in slow & low audio
  TargetSampleRate := Round(44100 * Pitch);

  // Prevent invalid sample rates
  if TargetSampleRate < 4000 then
    TargetSampleRate := 4000;
  if TargetSampleRate > 96000 then
    TargetSampleRate := 96000;

  // Re-configure the TSF output format
  tsf_set_output(FTSF, TSF_STEREO_INTERLEAVED, TargetSampleRate, 0.0);
end;

procedure TYutaniAudioEngine.SetMusicVolume(Volume: Single);
begin
  if FMAInitialized and (FMusicGroup <> nil) then
    ma_sound_group_set_volume(FMusicGroup, Volume);
end;

procedure TYutaniAudioEngine.SetMasterVolume(Volume: Single);
begin
  if FMAInitialized and (FMusicGroup <> nil) then
    ma_engine_set_volume(FMAEngine, Volume);
end;


function TYutaniAudioEngine.GetMAEngine: ma_engine;
begin
  Result := FMAEngine;
end;

end.

