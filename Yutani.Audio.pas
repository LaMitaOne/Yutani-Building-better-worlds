unit Yutani.Audio;

{==============================================================================*
 *  Yutani.Audio - TinySoundFont Wrapper & Threaded Audio Engine 0.642
 *------------------------------------------------------------------------------
 *  Description:
 *    Standalone audio engine for TinySoundFont. Handles dynamic DLL loading,
 *    soundfont loading, and low-latency audio rendering via MMSystem (WaveOut).
 *    The audio thread spins up on demand when notes are played and pauses
 *    automatically (saving CPU) when idle for more than 2 seconds.
 *==============================================================================}
interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs,
  System.Diagnostics, Winapi.MMSystem, TinySoundFont;

type
  TYutaniAudioEngine = class
  private
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
  public
    constructor Create;
    destructor Destroy; override;
    procedure InitAudio;
    procedure LoadSoundfont(const FilePath: string);
    procedure AddNote(MidiNote: Integer; Velocity: Single = 1.0);
    // Direct live play (bypasses queue, instant trigger)
    procedure PlayLiveNote(MidiNote: Integer; Velocity: Single = 1.0);
  end;

implementation

const
  WAVE_FORMAT_IEEE_FLOAT = 3;
  IDLE_TIMEOUT_MS = 5000; // Pause thread after 5s of silence (gives notes enough time to ring out / decay)

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
end;

destructor TYutaniAudioEngine.Destroy;
begin
  FIsRunning := False;
  if Assigned(FAudioThread) then
  begin
    FAudioThread.WaitFor;
    FreeAndNil(FAudioThread);
  end;
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
  FreeAndNil(FLock);
  inherited;
end;

procedure TYutaniAudioEngine.InitAudio;
var
  DllPath: string;
  Format: TWaveFormatEx;
begin
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
          CurrentTime: Double;
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
            // If nothing was played for 2 seconds, sleep and skip rendering to save CPU
            if FLastNoteTime.ElapsedMilliseconds > IDLE_TIMEOUT_MS then
            begin
              Sleep(50);
              TargetTicks := Timer.GetTimestamp; // Reset timer so we don't fast-forward
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
            // Hybrid Sleep/Spin
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
  FLastNoteTime.Reset; // Reset idle timer
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

end.

