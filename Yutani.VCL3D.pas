unit Yutani.VCL3D;

{==============================================================================*
 *  VCL3D - High-Level Spawning Utilities for Yutani
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Provides high-level, ready-to-use spawning routines for the 3D Engine.
 *    This unit acts as a bridge between the VCL UI controls and the thread-safe
 *    spawn queue inside TRaylibSandbox, preventing race conditions with Jolt.
 *
 *  Contents:
 *    - TPiano   : Standalone interactive 3D piano component. Moved out of
 *                 Yutani.Core to keep the engine core clean. Spawns a solid
 *                 wooden base plus a perfectly aligned 2-octave key set.
 *                 Keys are static bodies flagged with IsPianoKey=True so the
 *                 sandbox core can render / click / link them via gizmos
 *                 without needing a TPiano reference.
 *
 *    - TVCL3D   : Static helper class with ready-to-use spawn routines:
 *                    * SpawnSandbox       (4 static walls)
 *                    * SpawnDynamicWall   (brick wall, optional bomb)
 *                    * SpawnButton        (3D UI button with OnClick)
 *                    * SpawnMonitorWall   (2x5 floating TV screens)
 *                    * SpawnPiano         (full 2-octave piano)
 *                    * SpawnTrackbar      (slider with track + knob)
 *                    * SpawnProgressBar   (fill bar)
 *
 *  Thread Safety:
 *    All Spawn* methods push TSpawnRequest records into the sandbox's
 *    thread-safe QueueCustomSpawn. The actual TA3DComponent instances are
 *    created later inside the render thread by ProcessCustomSpawnQueue.
 *    The only exception is TPiano.Create, which spawns the wooden base
 *    synchronously so the caller gets an immediate FBase reference; this
 *    mirrors the original behaviour from Yutani.Core.
 *==============================================================================}

interface

uses
  System.SysUtils, System.Classes, Raylib, JoltPhysics, Yutani.Core,
  Yutani.Core.ModelEngine;

type
  // ==========================================================================
  // Standalone 3D Piano Component
  // --------------------------------------------------------------------------
  // Encapsulates a solid wooden base and a set of perfectly aligned white
  // and black keys. Keys are spawned via the thread-safe queue and flagged
  // with IsPianoKey=True on TA3DComponent; the sandbox core detects them
  // through that flag for rendering, mouse-click handling and gizmo linking.
  //
  // Ownership:
  //    The TPiano instance is owned by the CALLER, not by the sandbox.
  //    Create it via TVCL3D.SpawnPiano(Sandbox) and free it yourself when
  //    the scene is cleared or the form is closed. The underlying actors
  //    (base + keys) live in Sandbox.FItems and are freed by the sandbox
  //    during scene cleanup.
  //
  // Key lookup:
  //    Because the keys are spawned asynchronously through the queue, this
  //    class does NOT keep a cached FKeys array. PressKey / ReleaseKey /
  //    GetKey / KeyCount scan Sandbox.FItems on demand for actors with
  //    IsPianoKey=True. The iteration order matches the spawn order, which
  //    is white0, black0, white1, black1, white2, white3, black3, ...
  // ==========================================================================
  TPiano = class
  private
    FSandbox: TYutaniRaylibSandbox;
    FBase: TA3DComponent;
  public
    constructor Create(ASandbox: TYutaniRaylibSandbox);
    destructor Destroy; override;

    { Manually press / release a key by its spawn index. Used for scripted
      playback. The call is a no-op if the index is out of range or the
      underlying actor has been freed. }
    procedure PressKey(Index: Integer);
    procedure ReleaseKey(Index: Integer);

    { Returns the TA3DComponent for the key at the given spawn index, or
      nil if the index is out of range. The returned actor is owned by the
      sandbox; do not free it. }
    function GetKey(Index: Integer): TA3DComponent;

    { Number of keys currently registered on this piano. Counts all actors
      in Sandbox.FItems with IsPianoKey=True. }
    function KeyCount: Integer;

    { The wooden base actor. Use this to attach gizmos etc. Never nil after
      Create returns. }
    property Base: TA3DComponent read FBase;
  end;

  // ==========================================================================
  // High-level spawning utilities
  // --------------------------------------------------------------------------
  // All methods are class procedures on TVCL3D so callers can use them without
  // instantiating anything:
  //
  //    TVCL3D.SpawnSandbox(Sandbox);
  //    TVCL3D.SpawnPiano(Sandbox);
  //
  // Every method is safe to call from the VCL UI thread; they push
  // TSpawnRequest records into the sandbox's thread-safe queue.
  // ==========================================================================
  TVCL3D = class
  public
    { Spawns 4 solid, static walls to create a closed sandbox environment. }
    class procedure SpawnSandbox(Sandbox: TYutaniRaylibSandbox);

    { Spawns a grid of blocks sequentially to build a realistic wall.
      Width and Height are in brick units (one brick = 2x2x2). When
      SpawnFalling is True the bricks drop from height 15. When SpawnBomb
      is True the very last brick is replaced by a bomb trigger that spawns
      a separate THE_BOMB actor. Destructable controls the IsDestructable
      flag so bricks can be fractured on hard impact. }
    class procedure SpawnDynamicWall(Sandbox: TYutaniRaylibSandbox; Width, Height: Integer; SpawnFalling: Boolean = True; SpawnBomb: Boolean = False; Destructable: Boolean = False);

    { Spawns a 3D UI Button with OnClick event. The button is a static body
      that does not fall via gravity. ACaption is baked into a texture so
      it shows up on the button face. }
    class procedure SpawnButton(Sandbox: TYutaniRaylibSandbox; const ACaption: string; APos, ASize: TVector3; AOnClick: TNotifyEvent);

    { Spawns a 2x5 grid of floating TV screens for a future multiview
      system. Each screen gets a procedurally generated test texture in a
      different color. }
    class procedure SpawnMonitorWall(Sandbox: TYutaniRaylibSandbox);

    { Spawns a complete 2-octave 3D piano (wooden base + 14 white keys +
      10 black keys). Keys start at MIDI note 60 (Middle C). All keys are
      static bodies flagged with IsPianoKey=True so the sandbox handles
      rendering, clicking and gizmo linking automatically. }
    class procedure SpawnPiano(Sandbox: TYutaniRaylibSandbox);

    { Spawns a 3D Trackbar styled like the existing 3D Button: a single
      composite actor with a dark base block and a smaller knob that
      sticks out the front (Z+ face). The knob is interactive: click+
      drag with the left mouse button to change the value live.

      The current value is stored on the actor's ItemPosition field as
      a 0..1000 promille (caller maps to [AMin..AMax]). Use
      GetTrackbarValue / SetTrackbarValue to read / write the value
      with automatic Min..Max mapping.

      AOnChange is an optional callback that fires (in the VCL thread,
      marshalled via TThread.Queue) every time ItemPosition changes
      during a drag. Sender is the TA3DComponent actor - the callback
      can read ItemPosition and convert to its own [AMin..AMax] range
      via GetTrackbarValue. Pass nil if you don't need change events.

      Single actor spawned: 'Trackbar_<AName>' }
    class procedure SpawnTrackbar(Sandbox: TYutaniRaylibSandbox; const AName: string; APos, ASize: TVector3; AMin, AMax, AValue: Single; AOnChange: TNotifyEvent = nil);

    { Spawns a 3D Progress Bar styled like the existing 3D Button: a
      single composite actor with a dark base block and a green fill
      that sticks out the front (Z+ face). The fill width grows from
      the left edge based on the value.

      Progress bars are NOT interactive - their value is driven
      externally. Use GetProgressBarValue / SetProgressBarValue to
      read / write the value with automatic 0..AMax mapping.

      Single actor spawned: 'ProgressBar_<AName>' }
    class procedure SpawnProgressBar(Sandbox: TYutaniRaylibSandbox; const AName: string; APos, ASize: TVector3; AValue: Single; AMax: Single = 100.0);

    { Helper: writes Value (in caller's [AMin..AMax] range) onto the
      ItemPosition of the named trackbar actor. The value is clamped
      and mapped to 0..1000 promille internally. No-op if the actor
      is not found or not a stTrackbar. }
    class procedure SetTrackbarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AValue, AMin, AMax: Single);

    { Helper: reads the current value (in caller's [AMin..AMax] range)
      from the ItemPosition of the named trackbar actor. Returns AMin
      if the actor is not found or not a stTrackbar. }
    class function GetTrackbarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AMin, AMax: Single): Single;

    { Helper: writes Value (in caller's [0..AMax] range) onto the
      ItemPosition of the named progress bar actor. The value is
      clamped and mapped to 0..1000 promille internally. No-op if
      the actor is not found or not a stProgressBar. }
    class procedure SetProgressBarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AValue, AMax: Single);

    { Helper: reads the current value (in caller's [0..AMax] range)
      from the ItemPosition of the named progress bar actor. Returns
      0 if the actor is not found or not a stProgressBar. }
    class function GetProgressBarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AMax: Single): Single;
  end;

implementation

// ============================================================================
// Custom UI colors used by SpawnTrackbar / SpawnProgressBar. Raylib's
// standard palette doesn't include TEAL, so we define our own here. The
// values match the COL_TEAL constant used by Yutani.Core for the active
// body highlight so the look stays consistent across the engine.
// LIME is also redefined here so the unit is self-contained even when the
// Raylib binding in use does not export LIME.
// ============================================================================

const
  COL_UI_TEAL: TColorB = (
    r: 64;
    g: 224;
    b: 208;
    a: 255
  );
  COL_UI_LIME: TColorB = (
    r: 0;
    g: 255;
    b: 0;
    a: 255
  );

{ TPiano }

constructor TPiano.Create(ASandbox: TYutaniRaylibSandbox);
var
  i: Integer;
  Pos: TVector3;
  Request: TSpawnRequest;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  WhiteKeyCount, Note: Integer;
  WhiteKeyW, WhiteKeyH, WhiteKeyD: Single;
  BlackKeyW, BlackKeyH, BlackKeyD: Single;
  HasBlack: Boolean;
  BlackOffset: Single;
  WoodColor: TColorB;
  WhiteBaseColor, WhiteHoverColor, BlackBaseColor, BlackHoverColor: TColorB;
  BaseCube: TA3DComponent;
begin
  if not Assigned(ASandbox) then
    raise Exception.Create('TPiano.Create: Sandbox reference is nil');

  FSandbox := ASandbox;
  FBase := nil;

  // Key dimensions in world units
  WhiteKeyW := 1.0;
  WhiteKeyH := 0.2;
  WhiteKeyD := 3.0;
  BlackKeyW := 0.6;
  BlackKeyH := 0.3;
  BlackKeyD := 1.5;

  // -----------------------------------------------------------------------
  // 1. Spawn the Piano Base synchronously so we get an immediate reference.
  //    Base height is 0.6, center at Y=0.3 so the bottom sits at Y=0.0
  //    and the top is exactly at Y=0.6 where the keys will rest.
  // -----------------------------------------------------------------------
  JPos.x := 0;
  JPos.y := 0.3;
  JPos.z := 0;
  JRot.x := 0;
  JRot.y := 0;
  JRot.z := 0;
  JRot.w := 1;

  // Width is 15.0 to perfectly match 14 white keys + spacing
  BaseCube := TA3DComponent.Create('', FSandbox.Engine, stBox, Vector3Create(15.0, 0.6, WhiteKeyD + 1.0), True, False, @JPos, @JRot);
  BaseCube.Name := 'PianoBody';

  // Warm wood color for the body
  WoodColor.r := 101;
  WoodColor.g := 67;
  WoodColor.b := 33;
  WoodColor.a := 255;
  BaseCube.ActColor := WoodColor;
  BaseCube.TargetColor := WoodColor;
  BaseCube.Visible := True;
  FBase := BaseCube;

  // Register the base directly in the sandbox's item list
  SetLength(FSandbox.FItems, Length(FSandbox.FItems) + 1);
  FSandbox.FItems[High(FSandbox.FItems)] := BaseCube;

  // Setup key colors
  WhiteBaseColor.r := 255;
  WhiteBaseColor.g := 255;
  WhiteBaseColor.b := 255;
  WhiteBaseColor.a := 255;
  WhiteHoverColor.r := 255;
  WhiteHoverColor.g := 255;
  WhiteHoverColor.b := 0;
  WhiteHoverColor.a := 255;
  BlackBaseColor.r := 0;
  BlackBaseColor.g := 0;
  BlackBaseColor.b := 0;
  BlackBaseColor.a := 255;
  BlackHoverColor.r := 255;
  BlackHoverColor.g := 165;
  BlackHoverColor.b := 0;
  BlackHoverColor.a := 255;

  // -----------------------------------------------------------------------
  // 2. Spawn the white and black keys via the thread-safe queue.
  //    The keys are processed asynchronously by ProcessCustomSpawnQueue
  //    in the render thread. The sandbox flags them with IsPianoKey=True
  //    based on the name prefix ('Key_White_' / 'Key_Black_').
  // -----------------------------------------------------------------------
  WhiteKeyCount := 14; // 2 octaves
  Note := 60;          // Start at Middle C (MIDI note 60)

  for i := 0 to WhiteKeyCount - 1 do
  begin
    // No black key after E (index 2 mod 7) or B (index 6 mod 7)
    HasBlack := not ((i mod 7 = 2) or (i mod 7 = 6));

    // --- White key ---
    // Base top is Y=0.6. Key height is 0.2, so center at Y=0.7 means
    // the key occupies Y=0.6..0.8 exactly.
    // A 0.02 spacing between keys prevents Wireframe Z-Fighting.
    Pos := Vector3Create((i * (WhiteKeyW + 0.02)) - (WhiteKeyCount * (WhiteKeyW + 0.02) * 0.5) + (WhiteKeyW * 0.5), 0.7, 0);

    Request.Shape := stBox;
    Request.Pos := Pos;
    Request.Size := Vector3Create(WhiteKeyW, WhiteKeyH, WhiteKeyD);
    Request.IsStatic := True;
    Request.IsDestructable := False;
    Request.Name := 'Key_White_' + IntToStr(Note);
    Request.Color := WhiteBaseColor;
    Request.BaseColor := WhiteBaseColor;
    Request.HoverColor := WhiteHoverColor;
    Request.Caption := '';
    Request.GenerateTestTexture := False;
    Request.OnClick := nil;
    FSandbox.QueueCustomSpawn(Request);

    // --- Black key (if applicable) ---
    if HasBlack then
    begin
      BlackOffset := Pos.x + (WhiteKeyW * 0.5);
      // Black key center at Y=0.75 so it occupies Y=0.6..0.9 exactly
      // (sits 0.1 above the white keys).
      Request.Pos := Vector3Create(BlackOffset, 0.75, -0.76);
      Request.Size := Vector3Create(BlackKeyW, BlackKeyH, BlackKeyD);
      Request.Name := 'Key_Black_' + IntToStr(Note + 1);
      Request.Color := BlackBaseColor;
      Request.BaseColor := BlackBaseColor;
      Request.HoverColor := BlackHoverColor;
      FSandbox.QueueCustomSpawn(Request);
      Inc(Note, 2);
    end
    else
      Inc(Note);
  end;
end;

destructor TPiano.Destroy;
begin
  // The sandbox owns the actual TA3DComponent instances (base + keys
  // live in Sandbox.FItems and are freed by the sandbox's scene cleanup).
  // We only hold a reference to the base, so just clear our pointer.
  FBase := nil;
  FSandbox := nil;
  inherited;
end;

procedure TPiano.PressKey(Index: Integer);
var
  Key: TA3DComponent;
begin
  Key := GetKey(Index);
  if Assigned(Key) then
    Key.IsPressed := True;
end;

procedure TPiano.ReleaseKey(Index: Integer);
var
  Key: TA3DComponent;
begin
  Key := GetKey(Index);
  if Assigned(Key) then
    Key.IsPressed := False;
end;

function TPiano.GetKey(Index: Integer): TA3DComponent;
var
  i: Integer;
  Count: Integer;
begin
  Result := nil;
  if (Index < 0) or (not Assigned(FSandbox)) then
    Exit;

  // Keys are spawned asynchronously, so we scan FItems on demand for
  // IsPianoKey=True actors. The iteration order matches the spawn order
  // (white0, black0, white1, black1, ...) because QueueCustomSpawn is
  // a FIFO queue.
  Count := 0;
  for i := 0 to High(FSandbox.FItems) do
  begin
    if Assigned(FSandbox.FItems[i]) and FSandbox.FItems[i].IsPianoKey then
    begin
      if Count = Index then
      begin
        Result := FSandbox.FItems[i];
        Exit;
      end;
      Inc(Count);
    end;
  end;
end;

function TPiano.KeyCount: Integer;
var
  i: Integer;
begin
  Result := 0;
  if not Assigned(FSandbox) then
    Exit;

  for i := 0 to High(FSandbox.FItems) do
    if Assigned(FSandbox.FItems[i]) and FSandbox.FItems[i].IsPianoKey then
      Inc(Result);
end;

{ TVCL3D }

class procedure TVCL3D.SpawnSandbox(Sandbox: TYutaniRaylibSandbox);
var
  Req: TSpawnRequest;
begin
  if not Assigned(Sandbox) then
    Exit;

  // Prevent spawning the sandbox multiple times
  if Sandbox.FSandboxSpawned then
    Exit;

  Sandbox.FSandboxSpawned := True;

  // Configure the request for solid, static walls
  Req.Shape := stBox;
  Req.IsStatic := True; // Static bodies won't fall over or be affected by physics
  Req.Color := ColorCreate(20, 20, 20, 255);

  // Back Wall
  Req.Size := Vector3Create(100, 20, 1);
  Req.Pos := Vector3Create(0, 10, -50);
  Req.Name := 'Sandbox_Wall_Back';
  Sandbox.QueueCustomSpawn(Req);

  // Front Wall
  Req.Pos := Vector3Create(0, 10, 50);
  Req.Name := 'Sandbox_Wall_Front';
  Sandbox.QueueCustomSpawn(Req);

  // Left Wall
  Req.Size := Vector3Create(1, 20, 100);
  Req.Pos := Vector3Create(-50, 10, 0);
  Req.Name := 'Sandbox_Wall_Left';
  Sandbox.QueueCustomSpawn(Req);

  // Right Wall
  Req.Pos := Vector3Create(50, 10, 0);
  Req.Name := 'Sandbox_Wall_Right';
  Sandbox.QueueCustomSpawn(Req);
end;

class procedure TVCL3D.SpawnDynamicWall(Sandbox: TYutaniRaylibSandbox; Width, Height: Integer; SpawnFalling: Boolean = True; SpawnBomb: Boolean = False; Destructable: Boolean = False);
var
  Req: TSpawnRequest;
  x, y: Integer;
  BrickSize, HalfWidth, SpawnHeight: Single;
  RandX, RandZ, RandY: Single;
begin
  if not Assigned(Sandbox) then
    Exit;
  if Width < 1 then
    Width := 1;
  if Height < 1 then
    Height := 1;

  BrickSize := 2.0; // 2x2x2 blocks
  HalfWidth := (Width - 1) * BrickSize * 0.5;

  // If static, we don't need a spawn height, they can just be placed directly
  if not SpawnFalling then
    SpawnHeight := 0.0
  else
    SpawnHeight := 15.0; // Height from which they fall

  Req.Shape := stBox;
  Req.Size := Vector3Create(BrickSize, BrickSize, BrickSize);
  Req.IsStatic := False; // Always dynamic so the bomb can destroy them!
  Req.IsDestructable := Destructable;
  Req.Color := MAROON;
  Req.GenerateTestTexture := False;

  // Strict sequential order: Left to Right, Bottom to Top (like a real bricklayer)
  for y := 0 to Height - 1 do
  begin
    for x := 0 to Width - 1 do
    begin
      if SpawnFalling then
      begin
        RandX := (System.Random - 0.5) * 0.4;
        RandZ := (System.Random - 0.5) * 0.4;
        RandY := System.Random * 2.0;
      end
      else
      begin
        // Perfect placement: RandY=1.0 so the bottom row sits exactly on the ground (Y=0)
        RandX := 0.0;
        RandY := 1.0;
        RandZ := 0.0;
      end;

      Req.Pos := Vector3Create(-HalfWidth + (x * BrickSize) + RandX, (y * BrickSize) + SpawnHeight + RandY, 0 + RandZ);

      // Set timer: The last block gets the bomb!
      if SpawnBomb and (y = Height - 1) and (x = Width - 1) then
        Req.Name := 'BOMB_TRIGGER'
      else
        Req.Name := 'WallBlock_' + IntToStr(x) + '_' + IntToStr(y);

      Sandbox.QueueCustomSpawn(Req);
    end;
  end;
end;

class procedure TVCL3D.SpawnButton(Sandbox: TYutaniRaylibSandbox; const ACaption: string; APos, ASize: TVector3; AOnClick: TNotifyEvent);
var
  Req: TSpawnRequest;
begin
  if not Assigned(Sandbox) then
    Exit;

  // Configure the spawn request for a static UI button
  Req.Shape := stButton;
  Req.Pos := APos;
  Req.Size := ASize;
  Req.IsStatic := True; // Buttons shouldn't fall via gravity
  Req.IsDestructable := False;
  Req.Name := 'UI_Button_' + ACaption;
  Req.GenerateTestTexture := False;

  // Default Colors (Standard VCL Blue-ish)
  Req.Color := BLUE;
  Req.BaseColor := GRAY;
  Req.HoverColor := SKYBLUE;

  Req.Caption := ACaption;
  Req.OnClick := AOnClick;

  Sandbox.QueueCustomSpawn(Req);
end;

class procedure TVCL3D.SpawnMonitorWall(Sandbox: TYutaniRaylibSandbox);
var
  Req: TSpawnRequest;
  Row, Col, i: Integer;
  ScreenWidth, ScreenHeight, ScreenDepth: Single;
  SpacingX, SpacingY: Single;
  StartX, StartY, StartZ: Single;
  PosX, PosY, PosZ: Single;
  Colors: array[0..9] of TColorB;
begin
  if not Assigned(Sandbox) then
    Exit;

  // Define 10 different colors for testing
  Colors[0] := RED;
  Colors[1] := GREEN;
  Colors[2] := BLUE;
  Colors[3] := YELLOW;
  Colors[4] := MAGENTA;
  Colors[5] := ORANGE;
  Colors[6] := PURPLE;
  Colors[7] := PINK;
  Colors[8] := LIME;
  Colors[9] := SKYBLUE;

  ScreenWidth := 8.0;
  ScreenHeight := 4.5;
  ScreenDepth := 0.5;
  SpacingX := ScreenWidth + 2.0;
  SpacingY := ScreenHeight + 2.0;
  StartX := -((5 - 1) * SpacingX) / 2.0;
  StartY := 10.0 + ((2 - 1) * SpacingY) / 2.0;
  StartZ := -20.0;

  Req.Shape := stBox;
  Req.IsStatic := True;
  Req.IsDestructable := False;
  Req.GenerateTestTexture := True; // Tell Raylib thread to make a texture

  i := 0;
  for Row := 0 to 1 do
  begin
    for Col := 0 to 4 do
    begin
      PosX := StartX + (Col * SpacingX);
      PosY := StartY - (Row * SpacingY);
      PosZ := StartZ;
      Req.Pos := Vector3Create(PosX, PosY, PosZ);
      Req.Size := Vector3Create(ScreenWidth, ScreenHeight, ScreenDepth);
      Req.Color := Colors[i]; // Use this color for the generated texture
      Req.Name := 'Screen_' + IntToStr(i + 1);
      Sandbox.QueueCustomSpawn(Req);
      Inc(i);
    end;
  end;
end;

class procedure TVCL3D.SpawnPiano(Sandbox: TYutaniRaylibSandbox);
begin
  if not Assigned(Sandbox) then
    Exit;

  // -----------------------------------------------------------------------
  // Create the standalone Piano component. The instance is owned by the
  // caller, so the VCL form should hold the returned reference (e.g. in a
  // FPiano field) and FreeAndNil it when the scene is cleared or the form
  // is closed. The underlying actors (base + keys) live in Sandbox.FItems
  // and are freed by the sandbox during scene cleanup, so even if you
  // forget to capture the TPiano instance the only thing that leaks is
  // the lightweight wrapper object itself (a couple of pointers).
  //
  // If you need to drive the piano from code (PressKey etc.), call
  // TPiano.Create(Sandbox) directly and keep the returned reference.
  // TVCL3D.SpawnPiano is the convenience entry point for "fire and
  // forget" use from a button click.
  // -----------------------------------------------------------------------
  TPiano.Create(Sandbox);
end;

class procedure TVCL3D.SpawnTrackbar(Sandbox: TYutaniRaylibSandbox; const AName: string; APos, ASize: TVector3; AMin, AMax, AValue: Single; AOnChange: TNotifyEvent = nil);
var
  Req: TSpawnRequest;
  T: Single;
  Promille: Integer;
begin
  if not Assigned(Sandbox) then
    Exit;

  // Sanity-clamp the value range
  if AMax <= AMin then
    AMax := AMin + 1.0;
  if AValue < AMin then
    AValue := AMin;
  if AValue > AMax then
    AValue := AMax;

  // Normalize the value to [0..1] and convert to 0..1000 promille
  T := (AValue - AMin) / (AMax - AMin);
  Promille := Round(T * 1000.0);

  // -----------------------------------------------------------------------
  // Single composite actor. The render thread in Yutani.Core draws the
  // dark base block (Actor.BaseColor, default DARKGRAY) plus a smaller
  // TEAL knob that sticks out the front (Z+ face) and whose X position
  // is driven by ItemPosition.
  // -----------------------------------------------------------------------
  Req.Shape := stTrackbar;
  Req.Pos := APos;
  Req.Size := ASize;
  Req.IsStatic := True;          // UI control, no gravity
  Req.IsDestructable := False;
  Req.Name := 'Trackbar_' + AName;
  // Color semantics for stTrackbar / stProgressBar:
  //   Color      = initial ActColor (so frame 0 looks right before the
  //                first Update() tick runs the color lerp)
  //   BaseColor  = the dark BASE BLOCK color (frame, default DARKGRAY)
  //   FillColor  = the knob / fill REST color (lerp target in normal state)
  //   HoverColor = the knob / fill HOVER highlight color (lerp target on hover)
  // All four colors are independently editable in the Object Inspector.
  Req.Color := COL_UI_TEAL;       // ActColor init (knob, frame 0)
  Req.BaseColor := DARKGRAY;      // Base block color (frame)
  Req.FillColor := COL_UI_TEAL;   // Knob rest color
  Req.HoverColor := YELLOW;       // Knob hover highlight (bright yellow)
  Req.Caption := '';
  Req.OnClick := nil;
  Req.GenerateTestTexture := False;
  // Seed the initial value as 0..1000 promille - the render block
  // reads this every frame to position the knob.
  Req.ItemPosition := Promille;
  // Forward the caller's value-changed callback. The render thread
  // fires this (via TThread.Queue, safe to call from VCL) every time
  // ItemPosition changes during a drag.
  Req.OnChange := AOnChange;
  Sandbox.QueueCustomSpawn(Req);
end;

class procedure TVCL3D.SpawnProgressBar(Sandbox: TYutaniRaylibSandbox; const AName: string; APos, ASize: TVector3; AValue: Single; AMax: Single = 100.0);
var
  Req: TSpawnRequest;
  T: Single;
  Promille: Integer;
begin
  if not Assigned(Sandbox) then
    Exit;

  // Sanity-clamp the value range
  if AMax <= 0 then
    AMax := 100.0;
  if AValue < 0 then
    AValue := 0;
  if AValue > AMax then
    AValue := AMax;
  T := AValue / AMax;
  Promille := Round(T * 1000.0);

  // -----------------------------------------------------------------------
  // Single composite actor. The render thread in Yutani.Core draws the
  // dark base block (Actor.BaseColor, default DARKGRAY) plus a green fill
  // that sticks out the front (Z+ face), anchored to the left edge, width
  // driven by ItemPosition.
  // -----------------------------------------------------------------------
  Req.Shape := stProgressBar;
  Req.Pos := APos;
  Req.Size := ASize;
  Req.IsStatic := True;          // UI control, no gravity
  Req.IsDestructable := False;
  Req.Name := 'ProgressBar_' + AName;
  // Color semantics for stTrackbar / stProgressBar:
  //   Color      = initial ActColor (so frame 0 looks right before the
  //                first Update() tick runs the color lerp)
  //   BaseColor  = the dark BASE BLOCK color (frame, default DARKGRAY)
  //   FillColor  = the knob / fill REST color (lerp target in normal state)
  //   HoverColor = the knob / fill HOVER highlight color (lerp target on hover)
  // All four colors are independently editable in the Object Inspector.
  Req.Color := GREEN;         // ActColor init (fill, frame 0)
  Req.BaseColor := DARKGRAY;  // Base block color (frame)
  Req.FillColor := GREEN;     // Fill rest color
  Req.HoverColor := COL_UI_LIME; // Fill hover highlight (brighter green)
  Req.Caption := '';
  Req.OnClick := nil;
  Req.GenerateTestTexture := False;
  // Seed the initial fill level as 0..1000 promille - the render
  // block reads this every frame to size the fill.
  Req.ItemPosition := Promille;
  Sandbox.QueueCustomSpawn(Req);
end;

// ============================================================================
// Helper: Find a UI actor by name (single-actor design, so the caller
// does not need to know about Track / Knob / BG / Fill suffixes anymore).
// Returns nil if no actor with the given name is currently in the scene.
// Note: actors are spawned asynchronously, so the actor may not exist
// immediately after SpawnTrackbar / SpawnProgressBar returns. Poll from
// a timer or the next user action.
// ============================================================================
function FindUIActorByName(Sandbox: TYutaniRaylibSandbox; const AName: string): TA3DComponent;
var
  i: Integer;
begin
  Result := nil;
  if not Assigned(Sandbox) then
    Exit;
  for i := 0 to High(Sandbox.FItems) do
  begin
    if Assigned(Sandbox.FItems[i]) and (Sandbox.FItems[i].Name = AName) then
    begin
      Result := Sandbox.FItems[i];
      Exit;
    end;
  end;
end;

class procedure TVCL3D.SetTrackbarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AValue, AMin, AMax: Single);
var
  Actor: TA3DComponent;
  T: Single;
begin
  if not Assigned(Sandbox) then
    Exit;
  if AMax <= AMin then
    AMax := AMin + 1.0;
  if AValue < AMin then
    AValue := AMin;
  if AValue > AMax then
    AValue := AMax;

  Actor := FindUIActorByName(Sandbox, 'Trackbar_' + AName);
  if not Assigned(Actor) then
    Exit;
  if Actor.ShapeType <> stTrackbar then
    Exit;

  T := (AValue - AMin) / (AMax - AMin);
  // SetItemPosition clamps to 0..1000 internally for stTrackbar.
  Actor.ItemPosition := Round(T * 1000.0);
end;

class function TVCL3D.GetTrackbarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AMin, AMax: Single): Single;
var
  Actor: TA3DComponent;
begin
  Result := AMin;
  if not Assigned(Sandbox) then
    Exit;
  if AMax <= AMin then
    AMax := AMin + 1.0;

  Actor := FindUIActorByName(Sandbox, 'Trackbar_' + AName);
  if not Assigned(Actor) then
    Exit;
  if Actor.ShapeType <> stTrackbar then
    Exit;

  Result := AMin + (Actor.ItemPosition / 1000.0) * (AMax - AMin);
end;

class procedure TVCL3D.SetProgressBarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AValue, AMax: Single);
var
  Actor: TA3DComponent;
  T: Single;
begin
  if not Assigned(Sandbox) then
    Exit;
  if AMax <= 0 then
    AMax := 100.0;
  if AValue < 0 then
    AValue := 0;
  if AValue > AMax then
    AValue := AMax;

  Actor := FindUIActorByName(Sandbox, 'ProgressBar_' + AName);
  if not Assigned(Actor) then
    Exit;
  if Actor.ShapeType <> stProgressBar then
    Exit;

  T := AValue / AMax;
  // SetItemPosition clamps to 0..1000 internally for stProgressBar.
  Actor.ItemPosition := Round(T * 1000.0);
end;

class function TVCL3D.GetProgressBarValue(Sandbox: TYutaniRaylibSandbox; const AName: string; AMax: Single): Single;
var
  Actor: TA3DComponent;
begin
  Result := 0;
  if not Assigned(Sandbox) then
    Exit;
  if AMax <= 0 then
    AMax := 100.0;

  Actor := FindUIActorByName(Sandbox, 'ProgressBar_' + AName);
  if not Assigned(Actor) then
    Exit;
  if Actor.ShapeType <> stProgressBar then
    Exit;

  Result := (Actor.ItemPosition / 1000.0) * AMax;
end;

end.

