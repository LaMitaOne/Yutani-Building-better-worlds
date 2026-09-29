unit TinySoundFont;

{==============================================================================*
 *  TinySoundFont - Delphi Wrapper
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *  License MIT
 *  A complete Delphi wrapper for Bernhard Schelling's TinySoundFont (v0.9).
 *  A software synthesizer for playing SoundFont2 (.sf2) files.
 *
 *  Requires the compiled tinysoundfont.dll in the application directory.
 *  The DLL must export functions using the `dll_tsf_` prefix.
 *==============================================================================}

interface

type
  // Opaque pointer to the TinySoundFont instance
  Ptsf = Pointer;

  // TSF output modes
  TTSFOutputMode = (TSF_STEREO_INTERLEAVED = 0, // Two channels with single left/right samples one after another
    TSF_STEREO_UNWEAVED = 1, // Two channels with all samples for the left channel first then right
    TSF_MONO = 2  // A single channel (stereo instruments are mixed into center)
  );

var
  // --- Load / Save ---
  tsf_load_filename: function(const filename: PAnsiChar): Ptsf; cdecl;
  tsf_load_memory: function(const buffer: Pointer; size: Integer): Ptsf; cdecl;
  tsf_copy: function(f: Ptsf): Ptsf; cdecl;
  tsf_close: procedure(f: Ptsf); cdecl;
  tsf_reset: procedure(f: Ptsf); cdecl;

  // --- Preset Management ---
  tsf_get_presetindex: function(const f: Ptsf; bank, preset_number: Integer): Integer; cdecl;
  tsf_get_presetcount: function(const f: Ptsf): Integer; cdecl;
  tsf_get_presetname: function(const f: Ptsf; preset_index: Integer): PAnsiChar; cdecl;
  tsf_bank_get_presetname: function(const f: Ptsf; bank, preset_number: Integer): PAnsiChar; cdecl;

  // --- Output Setup ---
  tsf_set_output: procedure(f: Ptsf; outputmode: TTSFOutputMode; samplerate: Integer; global_gain_db: Single); cdecl;
  tsf_set_volume: procedure(f: Ptsf; global_gain: Single); cdecl;
  tsf_set_max_voices: function(f: Ptsf; max_voices: Integer): Integer; cdecl;

  // --- Note Functions ---
  tsf_note_on: function(f: Ptsf; preset_index, key: Integer; vel: Single): Integer; cdecl;
  tsf_bank_note_on: function(f: Ptsf; bank, preset_number, key: Integer; vel: Single): Integer; cdecl;
  tsf_note_off: procedure(f: Ptsf; preset_index, key: Integer); cdecl;
  tsf_bank_note_off: function(f: Ptsf; bank, preset_number, key: Integer): Integer; cdecl;
  tsf_note_off_all: procedure(f: Ptsf); cdecl;
  tsf_active_voice_count: function(f: Ptsf): Integer; cdecl;

  // --- Rendering ---
  tsf_render_short: procedure(f: Ptsf; buffer: PSmallInt; samples: Integer; flag_mixing: Integer); cdecl;
  tsf_render_float: procedure(f: Ptsf; buffer: PSingle; samples: Integer; flag_mixing: Integer); cdecl;

  // --- Channel Functions ---
  tsf_channel_set_presetindex: function(f: Ptsf; channel, preset_index: Integer): Integer; cdecl;
  tsf_channel_set_presetnumber: function(f: Ptsf; channel, preset_number: Integer; flag_mididrums: Integer): Integer; cdecl;
  tsf_channel_set_bank: function(f: Ptsf; channel, bank: Integer): Integer; cdecl;
  tsf_channel_set_bank_preset: function(f: Ptsf; channel, bank, preset_number: Integer): Integer; cdecl;
  tsf_channel_set_pan: function(f: Ptsf; channel: Integer; pan: Single): Integer; cdecl;
  tsf_channel_set_volume: function(f: Ptsf; channel: Integer; volume: Single): Integer; cdecl;
  tsf_channel_set_pitchwheel: function(f: Ptsf; channel, pitch_wheel: Integer): Integer; cdecl;
  tsf_channel_set_pitchrange: function(f: Ptsf; channel: Integer; pitch_range: Single): Integer; cdecl;
  tsf_channel_set_tuning: function(f: Ptsf; channel: Integer; tuning: Single): Integer; cdecl;
  tsf_channel_set_sustain: function(f: Ptsf; channel, flag_sustain: Integer): Integer; cdecl;
  tsf_channel_note_on: function(f: Ptsf; channel, key: Integer; vel: Single): Integer; cdecl;
  tsf_channel_note_off: procedure(f: Ptsf; channel, key: Integer); cdecl;
  tsf_channel_note_off_all: procedure(f: Ptsf; channel: Integer); cdecl;
  tsf_channel_sounds_off_all: procedure(f: Ptsf; channel: Integer); cdecl;
  tsf_channel_midi_control: function(f: Ptsf; channel, controller, control_value: Integer): Integer; cdecl;

  // --- Channel Getters ---
  tsf_channel_get_preset_index: function(f: Ptsf; channel: Integer): Integer; cdecl;
  tsf_channel_get_preset_bank: function(f: Ptsf; channel: Integer): Integer; cdecl;
  tsf_channel_get_preset_number: function(f: Ptsf; channel: Integer): Integer; cdecl;
  tsf_channel_get_pan: function(f: Ptsf; channel: Integer): Single; cdecl;
  tsf_channel_get_volume: function(f: Ptsf; channel: Integer): Single; cdecl;
  tsf_channel_get_pitchwheel: function(f: Ptsf; channel: Integer): Integer; cdecl;
  tsf_channel_get_pitchrange: function(f: Ptsf; channel: Integer): Single; cdecl;
  tsf_channel_get_tuning: function(f: Ptsf; channel: Integer): Single; cdecl;

implementation

end.

