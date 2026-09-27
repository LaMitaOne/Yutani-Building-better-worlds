{*******************************************************************************
  MRX Gamepad Core
********************************************************************************
  A modern, lightweight, and cross-platform gamepad input handler for Delphi
  using FireMonkey (FMX) and dynamically loaded SDL3.
  Designed for smooth, non-blocking input polling and thread-safe event delivery.
  Author:  Lara Miriam Tamy Reschke
  License: MIT
  Key Features:
  - SDL3 Dynamic Binding: No static .lib files needed. Just drop SDL3.dll
    next to your executable.
  - Threaded Polling: Runs input detection in a background thread (100Hz)
    to keep the FMX UI perfectly smooth.
  - Thread-Safe Events: Gamepad states are safely marshaled to the main UI
    thread using TThread.Queue.
  - Multi-Gamepad Support: Connect and track up to 4 gamepads simultaneously.
  - Rumble Support: Trigger haptic feedback (low/high frequency motors) for
    any connected pad.
  - Event Throttling: Smart filtering prevents event flooding from analog
    stick micro-movements and trigger pre-travel.
*******************************************************************************}
{ MRX-Gamepad-Core v0.1                                                        }
{ by Lara Miriam Tamy Reschke                                                  }
{                                                                              }
{------------------------------------------------------------------------------}
{
 ----Latest Changes
   v 0.1 (Alpha):
     - Initial Release.
     - Implemented SDL3 dynamic loading (Init, Joysticks, Gamepads, Rumble).
     - Fixed memory leak in SDL_GetJoysticks by binding and calling SDL_free.
     - Fixed SDL_bool return types to LongBool to prevent registry corruption.
     - Added thread-safe Rumble execution via TCriticalSection.
     - Implemented event throttling for axes to prevent UI message flooding.
     - Basic hot-discovery: Finds and opens up to 4 gamepads on launch.
}

unit uMRX_GamepadCore;

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Math, Winapi.Windows;

type
  /// <summary>
  /// Enum representing all possible gamepad inputs.
  /// </summary>
  TGamepadElement = (geNone, gePadUp, gePadDown, gePadLeft, gePadRight, geLeftStickUp, geLeftStickDown, geLeftStickLeft, geLeftStickRight, geRightStickUp, geRightStickDown, geRightStickLeft, geRightStickRight, geBtnA, geBtnB, geBtnX, geBtnY, geLB, geRB, geLT, geRT, geLeftStickX, geLeftStickY, geRightStickX, geRightStickY, geLeftStickClick, geRightStickClick, geStart, geBack, geGuide, geExtra1, geExtra2, geExtra3, geExtra4);
  /// <summary>
  /// Event fired when a gamepad state changes.
  /// </summary>

  TGamepadInputEvent = procedure(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single) of object;
  // SDL3 Forward Types

  TSDL_Gamepad = Pointer;

  PSDL_JoystickID = ^TSDL_JoystickID;

  TSDL_JoystickID = Int32;
  /// <summary>
  /// Core class handling SDL3 gamepad input, polling, and rumble.
  /// </summary>

  TMRXGamepadCore = class
  private
    FThread: TThread;
    FActive: Boolean;
    FLock: TCriticalSection;
    FOnInputEvent: TGamepadInputEvent;
    FGamepads: array[0..3] of TSDL_Gamepad;
    FDeadzone: Single;
    FPrevButtons: array[0..3, 0..19] of Boolean;
    FPrevAxes: array[0..3, 0..5] of Single; // Used to prevent event flooding

    // SDL3 DLL Bindings
    FSDLLib: THandle;
    SDL_Init: function(Flags: Cardinal): LongBool; cdecl;
    SDL_Quit: procedure; cdecl;
    SDL_UpdateGamepads: procedure; cdecl;
    SDL_GetJoysticks: function(out Count: Int32): PSDL_JoystickID; cdecl;
    SDL_IsGamepad: function(InstanceID: Int32): LongBool; cdecl;
    SDL_OpenGamepad: function(InstanceID: Int32): TSDL_Gamepad; cdecl;
    SDL_CloseGamepad: procedure(Gamepad: TSDL_Gamepad); cdecl;
    SDL_GamepadConnected: function(Gamepad: TSDL_Gamepad): LongBool; cdecl;
    SDL_GetGamepadAxis: function(Gamepad: TSDL_Gamepad; Axis: Int32): Int16; cdecl;
    SDL_GetGamepadButton: function(Gamepad: TSDL_Gamepad; Button: Int32): LongBool; cdecl;
    SDL_RumbleGamepad: function(Gamepad: TSDL_Gamepad; LowFreq: Word; HighFreq: Word; DurationMS: Cardinal): LongBool; cdecl;
    SDL_free: procedure(ptr: Pointer); cdecl;

    procedure LoadSDL;
    procedure FreeSDL;
    procedure StartThread;
    procedure StopThread;
    procedure ProcessGamepadStates;
    procedure DoInputEvent(PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Initialize;
    procedure Rumble(PlayerID: Integer; LowFreq, HighFreq: Word; DurationMS: Cardinal);

    property Active: Boolean read FActive;
    property Deadzone: Single read FDeadzone write FDeadzone;
    property OnInputEvent: TGamepadInputEvent read FOnInputEvent write FOnInputEvent;
  end;

const
  SDL_INIT_GAMEPAD = $00000010;
  SDL_INIT_JOYSTICK = $00000200;
  SDL_AXIS_LEFTX = 0;
  SDL_AXIS_LEFTY = 1;
  SDL_AXIS_RIGHTX = 2;
  SDL_AXIS_RIGHTY = 3;
  SDL_AXIS_TRIGGER_LEFT = 4;
  SDL_AXIS_TRIGGER_RIGHT = 5;
  SDL_BUTTON_A = 0;
  SDL_BUTTON_B = 1;
  SDL_BUTTON_X = 2;
  SDL_BUTTON_Y = 3;
  SDL_BUTTON_BACK = 4;
  SDL_BUTTON_GUIDE = 5;
  SDL_BUTTON_START = 6;
  SDL_BUTTON_LEFT_STICK = 7;
  SDL_BUTTON_RIGHT_STICK = 8;
  SDL_BUTTON_LEFT_SHOULDER = 9;
  SDL_BUTTON_RIGHT_SHOULDER = 10;
  SDL_BUTTON_DPAD_UP = 11;
  SDL_BUTTON_DPAD_DOWN = 12;
  SDL_BUTTON_DPAD_LEFT = 13;
  SDL_BUTTON_DPAD_RIGHT = 14;
  SDL_BUTTON_MISC1 = 15;

implementation
{ TMRXGamepadCore }

constructor TMRXGamepadCore.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FDeadzone := 0.15;
  FActive := False;
  FillChar(FPrevButtons, SizeOf(FPrevButtons), 0);
  FillChar(FPrevAxes, SizeOf(FPrevAxes), 0);
  LoadSDL;
end;

destructor TMRXGamepadCore.Destroy;
begin
  StopThread;
  FreeSDL;
  FreeAndNil(FLock);
  inherited;
end;

procedure TMRXGamepadCore.LoadSDL;
begin
  FSDLLib := LoadLibrary('SDL3.dll');
  if FSDLLib = 0 then
    Exit;

  @SDL_Init := GetProcAddress(FSDLLib, 'SDL_Init');
  @SDL_Quit := GetProcAddress(FSDLLib, 'SDL_Quit');
  @SDL_UpdateGamepads := GetProcAddress(FSDLLib, 'SDL_UpdateGamepads');
  @SDL_GetJoysticks := GetProcAddress(FSDLLib, 'SDL_GetJoysticks');
  @SDL_IsGamepad := GetProcAddress(FSDLLib, 'SDL_IsGamepad');
  @SDL_OpenGamepad := GetProcAddress(FSDLLib, 'SDL_OpenGamepad');
  @SDL_CloseGamepad := GetProcAddress(FSDLLib, 'SDL_CloseGamepad');
  @SDL_GamepadConnected := GetProcAddress(FSDLLib, 'SDL_GamepadConnected');
  @SDL_GetGamepadAxis := GetProcAddress(FSDLLib, 'SDL_GetGamepadAxis');
  @SDL_GetGamepadButton := GetProcAddress(FSDLLib, 'SDL_GetGamepadButton');
  @SDL_RumbleGamepad := GetProcAddress(FSDLLib, 'SDL_RumbleGamepad');
  @SDL_free := GetProcAddress(FSDLLib, 'SDL_free');
end;

procedure TMRXGamepadCore.FreeSDL;
var
  I: Integer;
begin
  if FSDLLib = 0 then
    Exit;

  for I := 0 to 3 do
  begin
    if Assigned(FGamepads[I]) and Assigned(SDL_CloseGamepad) then
      SDL_CloseGamepad(FGamepads[I]);
  end;

  if Assigned(SDL_Quit) then
    SDL_Quit;
  FreeLibrary(FSDLLib);
  FSDLLib := 0;
end;

procedure TMRXGamepadCore.Initialize;
begin
  if FSDLLib = 0 then
    raise Exception.Create('SDL3.dll not found. Please ensure the DLL is in the project directory.');

  if Assigned(SDL_Init) then
  begin
    SDL_Init(SDL_INIT_GAMEPAD or SDL_INIT_JOYSTICK);
    FActive := True;
    StartThread;
  end;
end;

procedure TMRXGamepadCore.StartThread;
begin
  FThread := TThread.CreateAnonymousThread(
    procedure
    begin
      while FActive do
      begin
        if Assigned(SDL_UpdateGamepads) then
          SDL_UpdateGamepads;

        FLock.Acquire;
        try
          ProcessGamepadStates;
        finally
          FLock.Release;
        end;

        Sleep(10); // Polling rate: ~100Hz
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TMRXGamepadCore.StopThread;
begin
  FActive := False;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50); // Allow thread to finish gracefully
  end;
end;

procedure TMRXGamepadCore.ProcessGamepadStates;
var
  I, Count: Int32;
  IDs, IDPtr: PSDL_JoystickID;
  AxisVal: Int16;
  BtnVal: LongBool;
  DZ, ValNorm: Single;
  IsPressed: Boolean;
  EventVal: Single;
  BtnIdx: Integer;
begin
  // 1. Discover and open connected gamepads
  if Assigned(SDL_GetJoysticks) and Assigned(SDL_OpenGamepad) then
  begin
    IDs := SDL_GetJoysticks(Count);
    try
      IDPtr := IDs;
      if Count > 0 then
      begin
        for I := 0 to Count - 1 do
        begin
          if (I <= 3) and not Assigned(FGamepads[I]) then
            FGamepads[I] := SDL_OpenGamepad(IDPtr^);
          Inc(IDPtr);
        end;
      end;
    finally
      // SDL3 allocates memory for the ID array, we must free it
      if Assigned(SDL_free) then
        SDL_free(IDs);
    end;
  end;

  // 2. Poll states for opened gamepads
  for I := 0 to 3 do
  begin
    if Assigned(FGamepads[I]) then
    begin
      DZ := FDeadzone;

      // --- Buttons ---
      if Assigned(SDL_GetGamepadButton) then
      begin
        for BtnIdx := 0 to 19 do
        begin
          BtnVal := SDL_GetGamepadButton(FGamepads[I], BtnIdx);
          IsPressed := BtnVal;

          if IsPressed <> FPrevButtons[I, BtnIdx] then
          begin
            FPrevButtons[I, BtnIdx] := IsPressed;
            if IsPressed then
              EventVal := 1.0
            else
              EventVal := 0.0;

            case BtnIdx of
              0:
                DoInputEvent(I, geBtnA, IsPressed, EventVal);
              1:
                DoInputEvent(I, geBtnB, IsPressed, EventVal);
              2:
                DoInputEvent(I, geBtnX, IsPressed, EventVal);
              3:
                DoInputEvent(I, geBtnY, IsPressed, EventVal);
              4:
                DoInputEvent(I, geBack, IsPressed, EventVal);
              5:
                DoInputEvent(I, geGuide, IsPressed, EventVal);
              6:
                DoInputEvent(I, geStart, IsPressed, EventVal);
              7:
                DoInputEvent(I, geLeftStickClick, IsPressed, EventVal);
              8:
                DoInputEvent(I, geRightStickClick, IsPressed, EventVal);
              9:
                DoInputEvent(I, geLB, IsPressed, EventVal);
              10:
                DoInputEvent(I, geRB, IsPressed, EventVal);
              11:
                DoInputEvent(I, gePadUp, IsPressed, EventVal);
              12:
                DoInputEvent(I, gePadDown, IsPressed, EventVal);
              13:
                DoInputEvent(I, gePadLeft, IsPressed, EventVal);
              14:
                DoInputEvent(I, gePadRight, IsPressed, EventVal);
              15:
                DoInputEvent(I, geExtra1, IsPressed, EventVal);
              16:
                DoInputEvent(I, geExtra2, IsPressed, EventVal);
              17:
                DoInputEvent(I, geExtra3, IsPressed, EventVal);
              18:
                DoInputEvent(I, geExtra4, IsPressed, EventVal);
              19:
                DoInputEvent(I, geExtra1, IsPressed, EventVal); // Fallback
            end;
          end;
        end;
      end;

      // --- Axes (Sticks & Triggers) ---
      if Assigned(SDL_GetGamepadAxis) then
      begin
        // Left Stick X
        AxisVal := SDL_GetGamepadAxis(FGamepads[I], SDL_AXIS_LEFTX);
        ValNorm := AxisVal / 32767.0;
        if Abs(ValNorm) < DZ then
          ValNorm := 0;
        if Abs(ValNorm - FPrevAxes[I, SDL_AXIS_LEFTX]) > 0.05 then
        begin
          FPrevAxes[I, SDL_AXIS_LEFTX] := ValNorm;
          DoInputEvent(I, geLeftStickX, Abs(ValNorm) > 0, ValNorm);
        end;

        // Left Stick Y
        AxisVal := SDL_GetGamepadAxis(FGamepads[I], SDL_AXIS_LEFTY);
        ValNorm := AxisVal / 32767.0;
        if Abs(ValNorm) < DZ then
          ValNorm := 0;
        if Abs(ValNorm - FPrevAxes[I, SDL_AXIS_LEFTY]) > 0.05 then
        begin
          FPrevAxes[I, SDL_AXIS_LEFTY] := ValNorm;
          DoInputEvent(I, geLeftStickY, Abs(ValNorm) > 0, ValNorm);
        end;

        // Right Stick X
        AxisVal := SDL_GetGamepadAxis(FGamepads[I], SDL_AXIS_RIGHTX);
        ValNorm := AxisVal / 32767.0;
        if Abs(ValNorm) < DZ then
          ValNorm := 0;
        if Abs(ValNorm - FPrevAxes[I, SDL_AXIS_RIGHTX]) > 0.05 then
        begin
          FPrevAxes[I, SDL_AXIS_RIGHTX] := ValNorm;
          DoInputEvent(I, geRightStickX, Abs(ValNorm) > 0, ValNorm);
        end;

        // Right Stick Y
        AxisVal := SDL_GetGamepadAxis(FGamepads[I], SDL_AXIS_RIGHTY);
        ValNorm := AxisVal / 32767.0;
        if Abs(ValNorm) < DZ then
          ValNorm := 0;
        if Abs(ValNorm - FPrevAxes[I, SDL_AXIS_RIGHTY]) > 0.05 then
        begin
          FPrevAxes[I, SDL_AXIS_RIGHTY] := ValNorm;
          DoInputEvent(I, geRightStickY, Abs(ValNorm) > 0, ValNorm);
        end;

        // Left Trigger (LT)
        AxisVal := SDL_GetGamepadAxis(FGamepads[I], SDL_AXIS_TRIGGER_LEFT);
        ValNorm := AxisVal / 32767.0;
        if ValNorm < 0 then
          ValNorm := 0;
        if Abs(ValNorm - FPrevAxes[I, SDL_AXIS_TRIGGER_LEFT]) > 0.05 then
        begin
          FPrevAxes[I, SDL_AXIS_TRIGGER_LEFT] := ValNorm;
          DoInputEvent(I, geLT, ValNorm > 0.5, ValNorm);
        end;

        // Right Trigger (RT)
        AxisVal := SDL_GetGamepadAxis(FGamepads[I], SDL_AXIS_TRIGGER_RIGHT);
        ValNorm := AxisVal / 32767.0;
        if ValNorm < 0 then
          ValNorm := 0;
        if Abs(ValNorm - FPrevAxes[I, SDL_AXIS_TRIGGER_RIGHT]) > 0.05 then
        begin
          FPrevAxes[I, SDL_AXIS_TRIGGER_RIGHT] := ValNorm;
          DoInputEvent(I, geRT, ValNorm > 0.5, ValNorm);
        end;
      end;
    end;
  end;
end;

procedure TMRXGamepadCore.DoInputEvent(PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
begin
  if Assigned(FOnInputEvent) then
  begin
    // Marshal event to the main UI thread
    TThread.Queue(nil,
      procedure
      begin
        if Assigned(FOnInputEvent) then
          FOnInputEvent(Self, PadID, Element, Pressed, Value);
      end);
  end;
end;

procedure TMRXGamepadCore.Rumble(PlayerID: Integer; LowFreq, HighFreq: Word; DurationMS: Cardinal);
var
  TargetPad: TSDL_Gamepad;
begin
  TargetPad := nil;

  // Thread-safe access to the gamepad array
  FLock.Acquire;
  try
    if (PlayerID >= 0) and (PlayerID <= 3) then
      TargetPad := FGamepads[PlayerID];
  finally
    FLock.Release;
  end;

  if Assigned(TargetPad) and Assigned(SDL_RumbleGamepad) then
  begin
    SDL_RumbleGamepad(TargetPad, LowFreq, HighFreq, DurationMS);
  end;
end;

end.

