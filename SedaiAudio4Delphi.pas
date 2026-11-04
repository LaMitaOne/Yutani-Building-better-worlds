{
  SedaiAudio4Delphi.pas - Delphi import unit for the Sedai Audio Foundation DLL.


 *  Author : Lara Miriam Tamy Reschke / LamitaOne


  Static import unit for sedaiaudio.dll (built from sedaiaudio.lpr with
  Free Pascal). All routines are cdecl and match the flat C-API exported
  by the DLL under their original names.

  Drop the compiled sedaiaudio.dll next to your .exe (or in a directory
  on the system PATH). Delphi loads it automatically when this unit is
  first referenced.

  ----------------------------------------------------------------------
  Calling convention
  ----------------------------------------------------------------------
  cdecl throughout - matches the DLL exports.

  ----------------------------------------------------------------------
  String parameters (PAnsiChar)
  ----------------------------------------------------------------------
  The DLL expects null-terminated ANSI strings. Delphi's default string
  type is UnicodeString, so convert explicitly:

      PlayClassic(440.0, PAnsiChar(AnsiString('sine')));

  For routines that had a default preset in the original API, pass nil to
  use the default - the DLL substitutes the original default value:

      PlayClassic(440.0);            // nil -> DLL uses 'sine'
      PlayFM(440.0);                 // nil -> DLL uses 'epiano'
      PlayWavetable(440.0);          // nil -> DLL uses 'basic'

  Note: PAnsiChar(AnsiString('')) in Delphi returns nil, so passing an
  empty Delphi string is the same as passing nil (i.e. uses the default).

  ----------------------------------------------------------------------
  String return values (PAnsiChar)
  ----------------------------------------------------------------------
  Routines returning PAnsiChar point to a thread-local static buffer inside
  the DLL. The buffer is overwritten by the next string-returning call on
  the same thread. Copy the result to a Delphi string IMMEDIATELY:

      var
        Name: string;
      Name := string(MIDINoteToName(60));   // copies the buffer

  ----------------------------------------------------------------------
  Array returns (GetLoadedWavetables, GetWavetableFormats)
  ----------------------------------------------------------------------
  The original routines returned a TStringArray, which cannot cross the
  ABI boundary. They are exported here as Integer (the element count).
  Use the indexed getters to retrieve individual items:

      Count := GetLoadedWavetables;
      for I := 0 to Count - 1 do
        Names.Add(string(GetLoadedWavetableName(I)));

      Count := GetWavetableFormats;
      for I := 0 to Count - 1 do
        Exts.Add(string(GetWavetableFormatByIndex(I)));

  ----------------------------------------------------------------------
  Enum parameters (Integer)
  ----------------------------------------------------------------------
  Enums are passed as Integer (32-bit) to keep the ABI independent of the
  FPC enum packing. Use the constants below (SAF_*, WT_*, FT_*, FS_*,
  MS_*, MDT_*, VOM_*).

  The TSAFSynthType values are reliable (the enum is declared in the
  public interface of SedaiAudioFoundation). All other enum values are
  INFERRED from usage in SedaiAudioFoundation - if you need the full set
  or the exact ordering, verify against the FPC source units:
    SedaiAudioTypes, SedaiOscillator, SedaiFilter, SedaiModulationMatrix,
    SedaiVoice.

  ----------------------------------------------------------------------
  Opaque pointer parameters
  ----------------------------------------------------------------------
  RegisterSample (ABuffer), PlayCustomWavetable and PlayCustomWavetableAdv
  (ACustomWavetable) take FPC-internal types that have no Delphi
  counterpart in this unit:
    - TSedaiAudioBuffer is a class  -> pass the object reference as Pointer.
    - TWavetable is a record        -> pass the address of the record as
                                       Pointer (the DLL dereferences it).
  The memory layout must match the FPC type. Most Delphi callers will not
  use these routines directly; LoadSampleFile + PlaySample / PlayLoaded*
  cover the typical sample/wavetable workflows.

  ----------------------------------------------------------------------
  Callbacks
  ----------------------------------------------------------------------
  RegisterMidiUpdateCallback expects a cdecl procedure of
  procedure(ADeltaTimeSeconds: Single); cdecl. The DLL stores it and
  invokes it from the audio thread. Keep the callback body short and
  non-blocking.
}

unit SedaiAudio4Delphi;

{$IFDEF FPC}
  {$MODE OBJFPC}{$H+}
{$ENDIF}

interface

type
  // MIDI update callback. Must be cdecl to match the DLL.
  TMidiUpdateProc = procedure(ADeltaTimeSeconds: Single); cdecl;

const
  // ==========================================================================
  // CONFIGURATION (mirrors SedaiAudioFoundation)
  // ==========================================================================
  SAF_MAX_VOICES           = 64;
  MIDI_MAX_VOICES          = 256;
  SAF_DEFAULT_SAMPLE_RATE  = 44100;
  SAF_DEFAULT_BUFFER_SIZE  = 1024;

  // ==========================================================================
  // ENUM CONSTANTS (passed as Integer)
  // ==========================================================================

  // TSAFSynthType - declared in SedaiAudioFoundation (reliable)
  SAF_CLASSIC   = 0;
  SAF_FM        = 1;
  SAF_WAVETABLE = 2;
  SAF_ADDITIVE  = 3;
  SAF_KARPLUS   = 4;

  // TWaveformType - INFERRED, verify against FPC source if you need all values.
  // The names below match the wt* identifiers referenced by the foundation.
  WT_SINE      = 0;
  WT_SQUARE    = 1;
  WT_SAW       = 2;
  WT_TRIANGLE  = 3;
  WT_PULSE     = 4;
  WT_NOISE     = 5;
  WT_SAWTOOTH  = 2;  // alias used by SetInstrumentRingMod / SetInstrumentSync

  // TFilterType - INFERRED, verify against FPC source.
  FT_LOWPASS   = 0;
  FT_HIGHPASS  = 1;
  FT_BANDPASS  = 2;
  FT_NOTCH     = 3;

  // TFilterSlope - fs12dB is confirmed; the rest are inferred.
  FS_12DB = 0;
  FS_24DB = 1;
  FS_36DB = 2;
  FS_48DB = 3;

  // TModSourceType - INFERRED from the modulation-matrix description in
  // SedaiAudioFoundation (envelope / velocity / keytrack / pitch-bend).
  MS_ENVELOPE  = 0;
  MS_VELOCITY  = 1;
  MS_KEYTRACK  = 2;
  MS_PITCHBEND = 3;

  // TModDestType - confirmed from the comments in SedaiAudioFoundation:
  //   mdtOscAllPitch = semitones, mdtFilterCutoff = octaves,
  //   mdtAmplitude = linear gain offset.
  MDT_OSC_ALL_PITCH = 0;
  MDT_FILTER_CUTOFF = 1;
  MDT_AMPLITUDE     = 2;

  // TVoiceOscMode - vomRingMod / vomSync confirmed; vomMix inferred.
  VOM_MIX      = 0;
  VOM_RING_MOD = 1;
  VOM_SYNC     = 2;

// ============================================================================
// INITIALIZATION
// ============================================================================

function InitAudio(AMaxVoices: Integer = SAF_MAX_VOICES): Boolean; cdecl; external 'sedaiaudio.dll' name 'InitAudio';
procedure ShutdownAudio; cdecl; external 'sedaiaudio.dll' name 'ShutdownAudio';

function GetSampleRate: Cardinal; cdecl; external 'sedaiaudio.dll' name 'GetSampleRate';
function GetActiveVoices: Integer; cdecl; external 'sedaiaudio.dll' name 'GetActiveVoices';
function GetMaxVoices: Integer; cdecl; external 'sedaiaudio.dll' name 'GetMaxVoices';

// ============================================================================
// MASTER VOLUME
// ============================================================================

procedure SetMasterVolume(AVolume: Single); cdecl; external 'sedaiaudio.dll' name 'SetMasterVolume';
function GetMasterVolume: Single; cdecl; external 'sedaiaudio.dll' name 'GetMasterVolume';

// ============================================================================
// CLASSIC SYNTHESIS (Subtractive)
// ============================================================================

procedure PlaySine(AFreq: Single; AAmplitude: Single = 0.5); cdecl; external 'sedaiaudio.dll' name 'PlaySine';
procedure PlaySquare(AFreq: Single; AAmplitude: Single = 0.5); cdecl; external 'sedaiaudio.dll' name 'PlaySquare';
procedure PlaySaw(AFreq: Single; AAmplitude: Single = 0.5); cdecl; external 'sedaiaudio.dll' name 'PlaySaw';
procedure PlayTriangle(AFreq: Single; AAmplitude: Single = 0.5); cdecl; external 'sedaiaudio.dll' name 'PlayTriangle';
procedure PlayPulse(AFreq: Single; APulseWidth: Single = 0.5; AAmplitude: Single = 0.5); cdecl; external 'sedaiaudio.dll' name 'PlayPulse';
procedure PlayNoise(AAmplitude: Single = 0.3); cdecl; external 'sedaiaudio.dll' name 'PlayNoise';

procedure PlayClassic(AFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayClassic';
procedure PlayLead(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayLead';
procedure PlayBass(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayBass';
procedure PlayPad(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayPad';

// ============================================================================
// FM SYNTHESIS
// ============================================================================

procedure PlayFM(AFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayFM';
procedure PlayEPiano(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayEPiano';
procedure PlayFMBrass(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayFMBrass';
procedure PlayFMBell(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayFMBell';
procedure PlayFMOrgan(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayFMOrgan';
procedure PlayFMLead(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayFMLead';
procedure PlayFMBass(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayFMBass';

// ============================================================================
// ADDITIVE SYNTHESIS (up to 64 harmonics)
// ============================================================================

procedure PlayAdditive(AFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayAdditive';
function PlayAdditiveAdv(AFreq: Single; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayAdditiveAdv';
procedure PlayAdditiveOrgan(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayAdditiveOrgan';
procedure PlayAdditiveBell(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayAdditiveBell';
procedure PlayAdditiveStrings(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayAdditiveStrings';

// ============================================================================
// KARPLUS-STRONG (plucked string)
// ============================================================================

procedure PlayKarplus(AFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayKarplus';
function PlayKarplusAdv(AFreq: Single; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayKarplusAdv';
procedure PlayPluck(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayPluck';
procedure PlayKarplusBass(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayKarplusBass';

// ============================================================================
// SAMPLE PLAYBACK
// ============================================================================

// ABuffer: Pointer to a TSedaiAudioBuffer object (FPC class). Advanced use.
function RegisterSample(AName: PAnsiChar; ABuffer: Pointer; ARootNote: Integer = 60; ALoop: Boolean = False): Boolean; cdecl; external 'sedaiaudio.dll' name 'RegisterSample';
function LoadSampleFile(AName: PAnsiChar; AFilename: PAnsiChar; ARootNote: Integer = 60; ALoop: Boolean = False): Boolean; cdecl; external 'sedaiaudio.dll' name 'LoadSampleFile';
function IsSampleRegistered(AName: PAnsiChar): Boolean; cdecl; external 'sedaiaudio.dll' name 'IsSampleRegistered';
function PlaySampleAdv(AFreq: Single; AName: PAnsiChar): Integer; cdecl; external 'sedaiaudio.dll' name 'PlaySampleAdv';
procedure PlaySample(AFreq: Single; AName: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'PlaySample';

// ============================================================================
// WAVETABLE SYNTHESIS
// ============================================================================

procedure PlayWavetable(AFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayWavetable';
procedure PlaySerum(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlaySerum';
procedure PlaySuperSaw(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlaySuperSaw';
procedure PlayPWM(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayPWM';
procedure PlayWasp(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayWasp';
procedure PlayPPG(AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'PlayPPG';
procedure PlayScaleWavetable(ABaseFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayScaleWavetable';

// ============================================================================
// WAVETABLE LOADING API
// ============================================================================

function LoadWavetableFile(AFilename: PAnsiChar): Boolean; cdecl; external 'sedaiaudio.dll' name 'LoadWavetableFile';
function LoadWavetableDirectory(APath: PAnsiChar): Integer; cdecl; external 'sedaiaudio.dll' name 'LoadWavetableDirectory';
procedure ScanWavetableDirectory(APath: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'ScanWavetableDirectory';
function GetLoadedWavetableCount: Integer; cdecl; external 'sedaiaudio.dll' name 'GetLoadedWavetableCount';
function GetLoadedWavetableName(AIndex: Integer): PAnsiChar; cdecl; external 'sedaiaudio.dll' name 'GetLoadedWavetableName';
// Returns the count of loaded wavetables. Use GetLoadedWavetableName(i) for 0..count-1.
function GetLoadedWavetables: Integer; cdecl; external 'sedaiaudio.dll' name 'GetLoadedWavetables';
function IsWavetableLoaded(AName: PAnsiChar): Boolean; cdecl; external 'sedaiaudio.dll' name 'IsWavetableLoaded';
function GetWavetableCacheInfo: PAnsiChar; cdecl; external 'sedaiaudio.dll' name 'GetWavetableCacheInfo';
// Returns the count of supported wavetable formats. Use GetWavetableFormatByIndex(i) for 0..count-1.
function GetWavetableFormats: Integer; cdecl; external 'sedaiaudio.dll' name 'GetWavetableFormats';
// Helper added for the flat C-API (no FPC counterpart). Returns one format extension by index.
function GetWavetableFormatByIndex(AIndex: Integer): PAnsiChar; cdecl; external 'sedaiaudio.dll' name 'GetWavetableFormatByIndex';
procedure ClearWavetableCache; cdecl; external 'sedaiaudio.dll' name 'ClearWavetableCache';
procedure PlayLoadedWavetable(AFreq: Single; AWavetableName: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'PlayLoadedWavetable';
function PlayLoadedWavetableAdv(AFreq: Single; AWavetableName: PAnsiChar): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayLoadedWavetableAdv';
// ACustomWavetable: Pointer to a TWavetable record (FPC). Advanced use.
procedure PlayCustomWavetable(AFreq: Single; ACustomWavetable: Pointer); cdecl; external 'sedaiaudio.dll' name 'PlayCustomWavetable';
function PlayCustomWavetableAdv(AFreq: Single; ACustomWavetable: Pointer): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayCustomWavetableAdv';
procedure ListLoadedWavetables; cdecl; external 'sedaiaudio.dll' name 'ListLoadedWavetables';
procedure PrintWavetableInfo(AFilename: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'PrintWavetableInfo';

// ============================================================================
// ADVANCED VOICE CONTROL (returns voice index)
// ============================================================================

function PlayClassicAdv(AFreq: Single; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayClassicAdv';
function PlayFMAdv(AFreq: Single; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayFMAdv';
function PlayWavetableAdv(AFreq: Single; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayWavetableAdv';

procedure NoteOff(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'NoteOff';
procedure NoteRelease(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'NoteRelease';
procedure SetVoicePan(AVoiceIndex: Integer; APan: Single); cdecl; external 'sedaiaudio.dll' name 'SetVoicePan';
procedure SetVoiceFrequency(AVoiceIndex: Integer; AFreq: Single); cdecl; external 'sedaiaudio.dll' name 'SetVoiceFrequency';
procedure SetVoiceAmplitude(AVoiceIndex: Integer; AAmplitude: Single); cdecl; external 'sedaiaudio.dll' name 'SetVoiceAmplitude';
procedure SetVoiceADSR(AVoiceIndex: Integer; AAttack, ADecay, ASustain, ARelease: Single); cdecl; external 'sedaiaudio.dll' name 'SetVoiceADSR';
procedure RetriggerVoice(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'RetriggerVoice';
procedure RetriggerVoiceHard(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'RetriggerVoiceHard';
procedure SetVoicePulseWidth(AVoiceIndex: Integer; APulseWidth: Single); cdecl; external 'sedaiaudio.dll' name 'SetVoicePulseWidth';
procedure SetVoiceFilter(AVoiceIndex: Integer; AEnabled: Boolean; AFilterType: Integer; AFreq: Single; AQ: Single; ASlope: Integer = FS_12DB); cdecl; external 'sedaiaudio.dll' name 'SetVoiceFilter';
procedure SetVoiceFilterEnabled(AVoiceIndex: Integer; AEnabled: Boolean); cdecl; external 'sedaiaudio.dll' name 'SetVoiceFilterEnabled';
procedure SetVoiceFilterParams(AVoiceIndex: Integer; AFreq: Single; AQ: Single); cdecl; external 'sedaiaudio.dll' name 'SetVoiceFilterParams';

// ============================================================================
// INSTRUMENT MODULATION (LFO / envelope / velocity -> pitch / cutoff / amp)
// ============================================================================

function SetInstrumentLFO(ASynth: Integer; APreset: PAnsiChar; ARateHz: Single; AWaveform: Integer = WT_SINE): Integer; cdecl; external 'sedaiaudio.dll' name 'SetInstrumentLFO';
procedure SetInstrumentModulation(ASynth: Integer; APreset: PAnsiChar; ASource: Integer; ADest: Integer; AAmount: Single; ABipolar: Boolean = True); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentModulation';
procedure SetInstrumentModulationLFO(ASynth: Integer; APreset: PAnsiChar; ALFOIndex: Integer; ADest: Integer; AAmount: Single; ABipolar: Boolean = True); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentModulationLFO';
procedure ClearInstrumentModulation(ASynth: Integer; APreset: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'ClearInstrumentModulation';

procedure SetInstrumentVibrato(ASynth: Integer; APreset: PAnsiChar; ADepthSemitones: Single; ARateHz: Single); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentVibrato';
procedure SetInstrumentTremolo(ASynth: Integer; APreset: PAnsiChar; ADepth: Single; ARateHz: Single); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentTremolo';
procedure SetInstrumentFilterLFO(ASynth: Integer; APreset: PAnsiChar; ADepthOctaves: Single; ARateHz: Single); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentFilterLFO';

// ============================================================================
// INSTRUMENT OSCILLATORS (classic source: mix / ring-mod / sync, sub-osc)
// ============================================================================

procedure SetInstrumentOscMode(ASynth: Integer; APreset: PAnsiChar; AMode: Integer); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentOscMode';
procedure SetInstrumentOscillator(ASynth: Integer; APreset: PAnsiChar; AIndex: Integer; AEnabled: Boolean; AWaveform: Integer; ALevel: Single; ADetuneCents: Single); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentOscillator';
procedure SetInstrumentSubOsc(ASynth: Integer; APreset: PAnsiChar; ALevel: Single = 0.5); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentSubOsc';
procedure SetInstrumentRingMod(ASynth: Integer; APreset: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentRingMod';
procedure SetInstrumentSync(ASynth: Integer; APreset: PAnsiChar; ADetuneSemitones: Single = 7.0); cdecl; external 'sedaiaudio.dll' name 'SetInstrumentSync';

// ============================================================================
// SYSTEM CONTROL
// ============================================================================

procedure StopAll; cdecl; external 'sedaiaudio.dll' name 'StopAll';
procedure SmoothStopAll(AFadeTimeMs: Integer = 300); cdecl; external 'sedaiaudio.dll' name 'SmoothStopAll';
procedure PrintStatus; cdecl; external 'sedaiaudio.dll' name 'PrintStatus';

procedure Beep(AFreq: Single; ADurationMs: Integer; AAmplitude: Single = 0.3); cdecl; external 'sedaiaudio.dll' name 'Beep';
procedure PlayNote(AChannel: Integer; AFreq: Single; ADurationMs: Integer; AAmplitude: Single = 0.5; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayNote';
procedure PlayOnVoice(AVoiceIndex: Integer; AFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayOnVoice';
procedure ReleaseVoice(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'ReleaseVoice';

// ============================================================================
// MIDI UTILITIES
// ============================================================================

function MIDINoteToFreq(ANote: Byte): Single; cdecl; external 'sedaiaudio.dll' name 'MIDINoteToFreq';
function FreqToMIDINote(AFreq: Single): Byte; cdecl; external 'sedaiaudio.dll' name 'FreqToMIDINote';
function MIDIVelocityToAmplitude(AVelocity: Byte): Single; cdecl; external 'sedaiaudio.dll' name 'MIDIVelocityToAmplitude';
function MIDIAmplitudeToVelocity(AAmplitude: Single): Byte; cdecl; external 'sedaiaudio.dll' name 'MIDIAmplitudeToVelocity';
function MIDIPanToSedai(APan: Byte): Single; cdecl; external 'sedaiaudio.dll' name 'MIDIPanToSedai';
function SedaiPanToMIDI(APan: Single): Byte; cdecl; external 'sedaiaudio.dll' name 'SedaiPanToMIDI';
function MIDINoteToName(ANote: Byte): PAnsiChar; cdecl; external 'sedaiaudio.dll' name 'MIDINoteToName';
function MIDINoteToOctave(ANote: Byte): Integer; cdecl; external 'sedaiaudio.dll' name 'MIDINoteToOctave';

// ============================================================================
// MIDI VOICE MANAGEMENT
// ============================================================================

function MIDIAllocateVoice: Integer; cdecl; external 'sedaiaudio.dll' name 'MIDIAllocateVoice';
function MIDIIsVoiceActive(AVoiceIndex: Integer): Boolean; cdecl; external 'sedaiaudio.dll' name 'MIDIIsVoiceActive';
function MIDIGetFreeVoiceCount: Integer; cdecl; external 'sedaiaudio.dll' name 'MIDIGetFreeVoiceCount';
procedure MIDIVoiceOn(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'MIDIVoiceOn';
procedure MIDIVoiceOff(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'MIDIVoiceOff';
procedure MIDIReleaseVoice(AVoiceIndex: Integer); cdecl; external 'sedaiaudio.dll' name 'MIDIReleaseVoice';
procedure MIDIReleaseAllVoices; cdecl; external 'sedaiaudio.dll' name 'MIDIReleaseAllVoices';
procedure MIDISetVoiceFrequency(AVoiceIndex: Integer; AFrequency: Single); cdecl; external 'sedaiaudio.dll' name 'MIDISetVoiceFrequency';
procedure MIDISetVoiceAmplitude(AVoiceIndex: Integer; AAmplitude: Single); cdecl; external 'sedaiaudio.dll' name 'MIDISetVoiceAmplitude';
procedure MIDISetVoiceWavetable(AVoiceIndex: Integer; AWavetableType: PAnsiChar); cdecl; external 'sedaiaudio.dll' name 'MIDISetVoiceWavetable';
procedure MIDISetVoicePan(AVoiceIndex: Integer; APan: Single); cdecl; external 'sedaiaudio.dll' name 'MIDISetVoicePan';
function MIDIGetVoiceFrequency(AVoiceIndex: Integer): Single; cdecl; external 'sedaiaudio.dll' name 'MIDIGetVoiceFrequency';
function MIDIGetVoiceAmplitude(AVoiceIndex: Integer): Single; cdecl; external 'sedaiaudio.dll' name 'MIDIGetVoiceAmplitude';
function MIDIGetVoiceWavetable(AVoiceIndex: Integer): PAnsiChar; cdecl; external 'sedaiaudio.dll' name 'MIDIGetVoiceWavetable';
function MIDIGetVoicePan(AVoiceIndex: Integer): Single; cdecl; external 'sedaiaudio.dll' name 'MIDIGetVoicePan';
function MIDIPlayNote(ANote: Byte; AVelocity: Byte; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'MIDIPlayNote';
function MIDIPlayNoteWithFreq(AFrequency: Single; AVelocity: Byte; APreset: PAnsiChar = nil): Integer; cdecl; external 'sedaiaudio.dll' name 'MIDIPlayNoteWithFreq';
function PlayWavetableMIDI(AFrequency: Single; AWavetableType: PAnsiChar; AVelocity: Byte; APan: Byte = 64): Integer; cdecl; external 'sedaiaudio.dll' name 'PlayWavetableMIDI';

// ============================================================================
// MIDI INTEGRATION (callback for external MIDI sequencer)
// ============================================================================

procedure RegisterMidiUpdateCallback(ACallback: TMidiUpdateProc); cdecl; external 'sedaiaudio.dll' name 'RegisterMidiUpdateCallback';
procedure UnregisterMidiUpdateCallback; cdecl; external 'sedaiaudio.dll' name 'UnregisterMidiUpdateCallback';

// ============================================================================
// CHORD AND SCALE HELPERS
// ============================================================================

procedure PlayChordWavetable(ANote1, ANote2, ANote3: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayChordWavetable';
procedure PlayChordClassic(ANote1, ANote2, ANote3: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayChordClassic';
procedure PlayChordFM(ANote1, ANote2, ANote3: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayChordFM';
procedure PlayScaleClassic(ABaseFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayScaleClassic';
procedure PlayScaleFM(ABaseFreq: Single; APreset: PAnsiChar = nil); cdecl; external 'sedaiaudio.dll' name 'PlayScaleFM';

implementation

// All routines are imported from sedaiaudio.dll - no Pascal implementation.

end.

