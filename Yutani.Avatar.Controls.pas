unit Yutani.Avatar.Controls;

{==============================================================================*
 *  Yutani Avatar Controls & Input Manager
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Central input and control system bridging Keyboard, SDL3 Gamepads,
 *    Jolt Physics (via TModelEngine) and Raylib Cameras.
 *==============================================================================}
{$POINTERMATH ON}
interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.SyncObjs, System.Math,
  System.Types, Vcl.Forms, Raylib, RayMath, JoltPhysics, Yutani.Core.ModelEngine,
  Yutani.Avatar.Controls.GamepadCore, Yutani.Avatar.Controls.GamepadSettings;

type
  // Identifies which avatar controller is currently selected. F11 will
  // possess the selected object using this controller type. Shift+F11
  // cycles through the values. Declared here (in Yutani.Avatar.Controls)
  // so the factory function and TYutaniPlayerSlot can use it directly,
  // and re-exported to Yutani.Core via the uses clause.
  TYutaniAvatarControllerType = (actVehicle, actThirdPerson, actFirstPerson, actFlight, actSpectator, actOrbit, actRigidBody);
  // Per-player input snapshot. The InputManager maintains one of these
  // per connected gamepad (plus a slot for the keyboard/mouse player) so
  // split-screen play can read inputs isolated per pad.
  // The field name Fwd is used instead of Forward because Forward is a
  // Delphi directive; the legacy GetInputs API still exposes it as the
  // out parameter named "forward" for backward compatibility.

  TYutaniPlayerInputState = record
    Fwd: Single;
    Right: Single;
    Up: Single;
    LookX: Single;
    LookY: Single;
    Action1: Boolean;
    Action2: Boolean;
  end;

  TYutaniInputManager = class
  private
    FGamepadCore: TMRXGamepadCore;
    FLock: TCriticalSection;
    // Legacy shared buffer kept for backward compatibility with the
    // existing single-player GetInputs call. It mirrors slot 0 of
    // FPlayerStates so old code paths do not break.
    FBufForward: Single;
    FBufRight: Single;
    FBufUp: Single;
    FBufLookX: Single;
    FBufLookY: Single;
    FBufAction1: Boolean;
    FBufAction2: Boolean;
    // Per-pad buffered state. Slot 0 doubles as the keyboard/mouse
    // player (mouselook writes into it). Slots 1..3 are gamepad-only and
    // are only populated by HandleGamepadInput with the matching PadID.
    FPlayerStates: array[0..3] of TYutaniPlayerInputState;
    // --- Mouselook state ---
    // Tracks cursor delta when mouselook is enabled. The engine thread calls
    // PollMouseLook every frame; if mouselook is active, the delta between
    // the current cursor position and the viewport center is added to the
    // look buffer and the cursor is snapped back to center so the player
    // can rotate indefinitely without hitting the screen border.
    FMouseLookActive: Boolean;
    FMouseSensitivity: Single;
    FMouseInvertY: Boolean;
    FCenterPos: TPoint;
    FViewportHandle: HWND;
    procedure HandleGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
  public
    constructor Create;
    destructor Destroy; override;
    procedure InitializeGamepad;
    procedure ShowGamepadSettings(ParentForm: TForm);
    procedure Rumble(PlayerID: Integer; LowFreq, HighFreq: Word; DurationMS: Cardinal);
    procedure GetInputs(out forward, Right, Up, LookX, LookY: Single; out Action1, Action2: Boolean);
    // Per-pad input query. Reads the isolated state for the requested
    // pad and resets the look axis (same behaviour as GetInputs).
    // PadID 0 is the keyboard/mouse player; 1..3 are gamepads.
    procedure GetInputsForPad(PadID: Integer; out forward, Right, Up, LookX, LookY: Single; out Action1, Action2: Boolean);
    // Snapshot accessor for code paths that want the full struct instead
    // of out parameters.
    function GetPlayerState(PadID: Integer): TYutaniPlayerInputState;
    // --- Mouselook API ---
    // StartMouseLook hides the cursor, snaps it to the center of the given
    // viewport and begins emitting look deltas into the buffer. StopMouseLook
    // restores normal cursor behaviour. PollMouseLook must be called every
    // frame from the render thread; it is a no-op when mouselook is inactive.
    procedure StartMouseLook(ViewportHandle: HWND);
    procedure StopMouseLook;
    procedure PollMouseLook;
    property Core: TMRXGamepadCore read FGamepadCore;
    property MouseLookActive: Boolean read FMouseLookActive;
    property MouseSensitivity: Single read FMouseSensitivity write FMouseSensitivity;
    property MouseInvertY: Boolean read FMouseInvertY write FMouseInvertY;
  end;

  TYutaniAvatarController = class abstract
  private
    FAvatar: TA3DComponent;
    FCamera: PCamera3D;
    FCamYaw: Single;
    FCamPitch: Single;
    FCamDist: Single;
    FMoveSpeed: Single;
    // --- Camera smoothing state ---
    // Two-layer smoothing system. CamSmoothing is an always-on lerp factor
    // (per second) that softly chases the desired camera transform in
    // normal operation. BeginCameraTransition starts a one-shot ease from
    // the current camera state to the desired state over a fixed duration;
    // this is what makes Possess / Shift+F11 feel cinematic instead of
    // snapping the camera to its new spot in a single frame.
    FCamSmoothing: Single;
    FCamTransitionActive: Boolean;
    FCamTransitionProgress: Single;   // 0..1 elapsed fraction
    FCamTransitionDuration: Single;   // Seconds for a full transition
    FCamStartPos: TVector3;            // Camera state captured at BeginCameraTransition
    FCamStartTarget: TVector3;
    FCamStartUp: TVector3;
    // --- Camera collision state ---
    // When active, WriteCameraTransform raycasts from the look anchor
    // towards the desired camera position. If anything is hit closer
    // than the desired distance, the camera is pulled in to just before
    // the contact point so it never clips through walls. The radius is
    // a safety margin so the near plane does not intersect the wall.
    FCameraCollisionActive: Boolean;
    FCameraCollisionRadius: Single;
    // --- Avatar facing state ---
    // When active, the avatar body is smoothly rotated to face its
    // current movement direction. Only horizontal (xz) velocity is
    // used so falling/jumping does not tilt the body. Disabled for
    // controllers like Flight where the body has its own rotation logic.
    FAvatarFacingActive: Boolean;
    FAvatarFacingSpeed: Single;        // Per-second lerp factor for yaw
    // --- Wheel zoom state ---
    // Mouse wheel delta is read every frame and applied to CamDist.
    // Min/Max clamp the value so the camera cannot be pushed inside
    // the avatar or pulled infinitely far away.
    FZoomSpeed: Single;
    FMinCamDist: Single;
    FMaxCamDist: Single;
    // --- Footstep audio trigger ---
    // Fires FOnFootstep at an interval inversely proportional to the
    // avatar's horizontal speed. The sandbox can subscribe and call
    // into MiniAudio to play the actual footstep sample.
    FOnFootstep: TNotifyEvent;
    FFootstepTimer: Single;
    FFootstepBaseInterval: Single;     // Seconds between steps at walk speed
    procedure SetAvatar(const Value: TA3DComponent);
  protected
    FInputForward: Single;
    FInputRight: Single;
    FInputUp: Single;
    FInputLookX: Single;
    FInputLookY: Single;
    FInputAction1: Boolean;
    FInputAction2: Boolean;
    procedure HandleKeyboardInput; virtual;
    procedure UpdateCameraTransform(dt: Single); virtual; abstract;
    // Single entry point that every UpdateCameraTransform override should
    // call instead of writing to FCamera^ directly. It applies the
    // one-shot transition (if active), the always-on smoothing and the
    // optional camera collision pull-in on top, so all camera motion
    // stays consistent across every controller.
    procedure WriteCameraTransform(const Pos, Target, Up: TVector3; dt: Single);
    // Raycasts from Anchor towards DesiredPos and returns a position
    // pulled in to just before the first hit (plus a safety margin).
    // Returns DesiredPos unchanged if collision is disabled or nothing
    // was hit. Used by WriteCameraTransform so subclasses do not need
    // to call it manually.
    function ResolveCameraCollision(const Anchor, DesiredPos: TVector3): TVector3;
    // Reads GetMouseWheelMove() and adjusts CamDist within the Min/Max
    // clamps. Subclasses can override to implement different behaviour
    // (e.g. first person uses the wheel for ADS zoom levels instead).
    procedure HandleWheelZoom(dt: Single); virtual;
    // Smoothly rotates the avatar body around the Y axis to face the
    // horizontal component of Vel. No-op when the horizontal speed is
    // below a small threshold so the body does not twitch in place.
    procedure FaceMovementDirection(const Vel: TVector3; dt: Single);
    // Drives the OnFootstep event based on the avatar's horizontal speed.
    // Faster movement = shorter interval between steps.
    procedure UpdateFootstepAudio(dt: Single);
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); virtual;
    destructor Destroy; override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); virtual; abstract;
    // Call this immediately after spawning a controller (or when shifting
    // between controller types) to make the camera fly smoothly from its
    // current state to the new controller's desired state. Captures the
    // current FCamera position/target/up as the start of the ease.
    procedure BeginCameraTransition(Duration: Single = 0.6);
    property Avatar: TA3DComponent read FAvatar write SetAvatar;
    property Camera: PCamera3D read FCamera write FCamera;
    property CamYaw: Single read FCamYaw write FCamYaw;
    property CamPitch: Single read FCamPitch write FCamPitch;
    property CamDist: Single read FCamDist write FCamDist;
    property MoveSpeed: Single read FMoveSpeed write FMoveSpeed;
    // 0 = no smoothing (instant follow). Recommended ~5.0 for a smooth chase.
    property CamSmoothing: Single read FCamSmoothing write FCamSmoothing;
    property CamTransitionActive: Boolean read FCamTransitionActive;
    // Camera collision prevents the camera from clipping through walls.
    property CameraCollisionActive: Boolean read FCameraCollisionActive write FCameraCollisionActive;
    property CameraCollisionRadius: Single read FCameraCollisionRadius write FCameraCollisionRadius;
    // Avatar facing rotates the body to match movement direction.
    property AvatarFacingActive: Boolean read FAvatarFacingActive write FAvatarFacingActive;
    property AvatarFacingSpeed: Single read FAvatarFacingSpeed write FAvatarFacingSpeed;
    // Wheel zoom adjusts CamDist within [MinCamDist, MaxCamDist].
    property ZoomSpeed: Single read FZoomSpeed write FZoomSpeed;
    property MinCamDist: Single read FMinCamDist write FMinCamDist;
    property MaxCamDist: Single read FMaxCamDist write FMaxCamDist;
    // Footstep event - wire to the audio engine from the sandbox.
    property OnFootstep: TNotifyEvent read FOnFootstep write FOnFootstep;
    property FootstepBaseInterval: Single read FFootstepBaseInterval write FFootstepBaseInterval;
  end;

  TYutaniThirdPersonController = class(TYutaniAvatarController)
  private
    FJumpForce: Single;
  protected
    procedure UpdateCameraTransform(dt: Single); override;
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property JumpForce: Single read FJumpForce write FJumpForce;
  end;

  TYutaniFlightController = class(TYutaniAvatarController)
  protected
    procedure UpdateCameraTransform(dt: Single); override;
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
  end;

  TYutaniVehicleController = class(TYutaniAvatarController)
  private
    FCurrentSpeed: Single;
    FMaxSpeed: Single;
    FTurnSpeed: Single;
  protected
    procedure UpdateCameraTransform(dt: Single); override;
  public
    FVehicleModelOffset: Single;
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property MaxSpeed: Single read FMaxSpeed write FMaxSpeed;
    property TurnSpeed: Single read FTurnSpeed write FTurnSpeed;
  end;
  // ==========================================================================
  // Centralized Avatar Settings Record
  // ==========================================================================
  // Single record that bundles every tunable value shared across all the
  // controller types below. Keeping them in a record makes it trivial to
  // expose them in a VCL inspector, persist them to disk alongside other
  // user preferences, or pass them by value into helper functions.

  TYutaniAvatarSettings = record
    LookSensitivity: Single;      // Mouse / right-stick look speed multiplier
    InvertY: Boolean;             // If TRUE, pushing the stick up looks down
    MoveDeadzone: Single;         // Analog stick deadzone for movement axes
    LookDeadzone: Single;         // Analog stick deadzone for look axes
    SprintMultiplier: Single;     // Velocity multiplier applied while sprinting
    CrouchMultiplier: Single;    // Velocity multiplier applied while crouching
    CameraSmoothing: Single;     // 0 = no smoothing, 1 = very smooth (lerp factor)
    MinCamPitch: Single;         // Lower clamp for pitch in radians
    MaxCamPitch: Single;         // Upper clamp for pitch in radians
    FOVNormal: Single;           // Field of view in degrees while walking
    FOVSprint: Single;           // Field of view in degrees while sprinting
    class function Default: TYutaniAvatarSettings; static;
  end;
  // ==========================================================================
  // First Person Controller
  // ==========================================================================
  // Walks inside the avatar body. The camera is locked to the avatar's eye
  // height and bobs subtly while moving. The avatar body is rotated to
  // match the camera yaw so movement is always relative to the view
  // direction. Sprint (Shift), crouch (Ctrl) and jump (Space / Action1)
  // are supported. Vertical look is clamped to a sane range so the player
  // cannot break their neck looking straight up or down.

  TYutaniFirstPersonController = class(TYutaniAvatarController)
  private
    FYaw: Single;                 // Body yaw (mirrored to FCamYaw for external readers)
    FPitch: Single;               // Vertical look pitch in radians
    FSprintActive: Boolean;       // Currently sprinting (drives FOV / speed scaling)
    FIsCrouching: Boolean;        // Currently crouching (lowers eye height)
    FEyeHeight: Single;           // Standing eye height in world units
    FCurrentEyeHeight: Single;    // Smoothed eye height (for crouch transitions)
    FCrouchHeight: Single;        // Crouching eye height in world units
    FHeadBobTime: Single;          // Accumulated time for the head bob sine wave
    FHeadBobOffset: Single;        // Current vertical offset added to the camera
    FSensitivity: Single;          // Locally cached look sensitivity multiplier
    FInvertY: Boolean;             // Locally cached Y invert flag
    FJumpForce: Single;            // Initial Y velocity applied on jump
    FWalkFOV: Single;              // Cached walking field of view (degrees)
    FSprintFOV: Single;            // Cached sprinting field of view (degrees)
    FCurrentFOV: Single;           // Smoothed current field of view
    // --- Aim Down Sights (ADS) state ---
    // When the player holds the ADS trigger key, the camera FOV smoothly
    // lerps down to FADSFOV (smaller = more zoom). The wheel can tune
    // FADSFOV live so the user can dial in sniper-mag vs red-dot feel.
    FADSActive: Boolean;
    FADSTriggerKey: Word;          // Virtual-key code that activates ADS
    FADSFOV: Single;                // Target FOV in degrees while aiming
    FADSWheelStep: Single;          // FOV delta per wheel notch while aiming
    procedure UpdateHeadBob(dt: Single; IsMoving: Boolean);
    procedure UpdateFOV(dt: Single);
  protected
    procedure UpdateCameraTransform(dt: Single); override;
    // Override wheel zoom: when aiming, the wheel adjusts FADSFOV instead
    // of CamDist (which is unused in first person anyway).
    procedure HandleWheelZoom(dt: Single); override;
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property EyeHeight: Single read FEyeHeight write FEyeHeight;
    property CrouchHeight: Single read FCrouchHeight write FCrouchHeight;
    property IsCrouching: Boolean read FIsCrouching;
    property IsSprinting: Boolean read FSprintActive;
    property IsADS: Boolean read FADSActive;
    property JumpForce: Single read FJumpForce write FJumpForce;
    property ADSTriggerKey: Word read FADSTriggerKey write FADSTriggerKey;
    property ADSFOV: Single read FADSFOV write FADSFOV;
    property ADSWheelStep: Single read FADSWheelStep write FADSWheelStep;
  end;
  // ==========================================================================
  // Spectator / Free-Fly Controller
  // ==========================================================================
  // Pure noclip-style camera. Useful for editing scenes, debugging and
  // reviewing a level from any angle. Disables gravity on the avatar so it
  // floats freely in any direction. Sprint with Shift for a speed boost.
  // The avatar itself is not rotated - only the camera moves. This is the
  // go-to controller for level designers that need to fly through walls.

  TYutaniSpectatorController = class(TYutaniAvatarController)
  private
    FSprintActive: Boolean;
    FBoostMultiplier: Single;
    FSensitivity: Single;
    FInvertY: Boolean;
  protected
    procedure UpdateCameraTransform(dt: Single); override;
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property IsSprinting: Boolean read FSprintActive;
    property BoostMultiplier: Single read FBoostMultiplier write FBoostMultiplier;
  end;
  // ==========================================================================
  // Orbit Controller
  // ==========================================================================
  // Slow auto-rotating camera around the avatar. Designed for character
  // showcase scenes, idle cinematic shots and inspecting models in 3D.
  // Manual look overrides auto-rotation as soon as the user touches the
  // right stick; auto-rotation resumes once the stick is released. The
  // forward/backward axes (or triggers) adjust the orbit distance.

  TYutaniOrbitController = class(TYutaniAvatarController)
  private
    FAutoRotate: Boolean;
    FAutoRotateSpeed: Single;     // Radians per second
    FTargetDist: Single;          // Target orbit distance (smoothed into FCamDist)
  protected
    procedure UpdateCameraTransform(dt: Single); override;
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property AutoRotate: Boolean read FAutoRotate write FAutoRotate;
    property AutoRotateSpeed: Single read FAutoRotateSpeed write FAutoRotateSpeed;
  end;
  // ==========================================================================
  // Rigid Body Controller (Physics-driven avatar)
  // ==========================================================================
  // Unlike the third person controller which directly sets the linear
  // velocity, this controller applies real forces and torques to the avatar
  // body. This produces physically believable acceleration, momentum and
  // friction behaviour on slopes. Best used for ragdoll-friendly avatars,
  // rolling spheres and physics puzzles where momentum matters.

  TYutaniRigidBodyController = class(TYutaniAvatarController)
  private
    FAccelForce: Single;           // Force applied per second when accelerating
    FMaxSpeed: Single;             // Soft cap - forces stop above this speed
    FJumpImpulse: Single;          // Upward impulse applied on jump
    FTorqueForce: Single;          // Torque applied for turning the body
    FYaw: Single;                  // Current body yaw (smoothed towards FTargetYaw)
    FTargetYaw: Single;            // Desired body yaw (driven by camera yaw)
    FSensitivity: Single;
    FInvertY: Boolean;
    FIsGrounded: Boolean;
    function CheckGrounded: Boolean;
  protected
    procedure UpdateCameraTransform(dt: Single); override;
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property AccelForce: Single read FAccelForce write FAccelForce;
    property MaxSpeed: Single read FMaxSpeed write FMaxSpeed;
    property JumpImpulse: Single read FJumpImpulse write FJumpImpulse;
    property IsGrounded: Boolean read FIsGrounded;
  end;
  // ==========================================================================
  // Standalone avatar controller factory
  // ==========================================================================
  // Maps the TYutaniAvatarControllerType enum to the matching controller
  // class. The sandbox in Yutani.Core.pas has its own method version of
  // this for legacy reasons, but this standalone function lets other
  // consumers (TYutaniMultiPlayerManager, unit tests, external tools)
  // spawn controllers without depending on the sandbox.

function YutaniCreateAvatarController(Avatar: TA3DComponent; AType: TYutaniAvatarControllerType; ACamera: PCamera3D): TYutaniAvatarController;
  // ==========================================================================
  // Player slot for split-screen play
  // ==========================================================================
  // Each slot bundles an avatar, an active controller and the PadID the
  // controller should pull input from. The sandbox renders the scene once
  // per slot using the slot's camera; the manager handles the per-frame
  // update logic for both slots.

type
  TYutaniPlayerSlot = class
  private
    FAvatar: TA3DComponent;
    FController: TYutaniAvatarController;
    FOwnsController: Boolean;       // True if the manager created (and should free) the controller
    FPadID: Integer;                // -1 = no input source; 0 = keyboard+mouse; 1..3 = gamepad
    FActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Assigns the avatar and PadID and spawns a fresh controller of the
    // given type bound to the supplied camera. The slot takes ownership of
    // the spawned controller and frees it on Destroy.
    procedure Setup(AAvatar: TA3DComponent; AControllerType: TYutaniAvatarControllerType; APadID: Integer; ACamera: PCamera3D);
    // Detaches from the avatar and frees the controller. Safe to call
    // multiple times - the slot becomes inert after the first call.
    procedure Teardown;
    // Advances the controller one frame using inputs from the given pad.
    procedure Update(dt: Single; InputManager: TYutaniInputManager);
    property Avatar: TA3DComponent read FAvatar;
    property Controller: TYutaniAvatarController read FController;
    property PadID: Integer read FPadID;
    property Active: Boolean read FActive;
  end;
  // ==========================================================================
  // Split-screen manager for 2 players
  // ==========================================================================
  // Two-slot manager for local couch-coop. Slot 0 is keyboard/mouse, slot
  // 1 is gamepad 1. Both slots are updated every frame when Active. The
  // sandbox is responsible for rendering the scene twice using each
  // slot's camera; the manager only handles the simulation side.
  //
  // Usage from the sandbox:
  //   FMultiPlayer := TYutaniMultiPlayerManager.Create;
  //   FMultiPlayer.EnableSplitScreen(Avatar1, Avatar2, @FCam1, @FCam2,
  //     actThirdPerson, actThirdPerson);
  //   // every frame:
  //   FMultiPlayer.Update(dt, FInputManager);
  //   // when done:
  //   FMultiPlayer.DisableSplitScreen;

  TYutaniMultiPlayerManager = class
  private
    FSlots: array[0..1] of TYutaniPlayerSlot;
    FActive: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Spawns controllers for both avatars and marks the manager as active.
    // ControllerType1 is used for slot 0 (keyboard/mouse player),
    // ControllerType2 for slot 1 (gamepad player).
    procedure EnableSplitScreen(Avatar1, Avatar2: TA3DComponent; Camera1, Camera2: PCamera3D; ControllerType1: TYutaniAvatarControllerType = actThirdPerson; ControllerType2: TYutaniAvatarControllerType = actThirdPerson);
    // Tears down both slots and frees the controllers.
    procedure DisableSplitScreen;
    // Advances both slots by dt using the supplied InputManager.
    procedure Update(dt: Single; InputManager: TYutaniInputManager);
    property Active: Boolean read FActive;
    function GetSlot(Index: Integer): TYutaniPlayerSlot;
  end;

implementation
{ TYutaniInputManager }

constructor TYutaniInputManager.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FGamepadCore := TMRXGamepadCore.Create;
  FGamepadCore.OnInputEvent := HandleGamepadInput;
  // Mouselook defaults - moderate sensitivity, no Y inversion. The user can
  // tweak these via the published properties or a settings dialog.
  FMouseLookActive := False;
  FMouseSensitivity := 1.0;
  FMouseInvertY := False;
  FCenterPos := Point(0, 0);
  FViewportHandle := 0;
  // Zero-init all per-pad states so a stale value from a previous session
  // cannot bleed into the first read of an uninitialized slot.
  FillChar(FPlayerStates, SizeOf(FPlayerStates), 0);
end;

destructor TYutaniInputManager.Destroy;
begin
  // Safety: if the manager is destroyed while mouselook is still active,
  // restore the cursor so the user is not left with an invisible cursor.
  StopMouseLook;
  FGamepadCore.Free;
  FLock.Free;
  inherited;
end;

procedure TYutaniInputManager.InitializeGamepad;
begin
  try
    FGamepadCore.Initialize;
    OutputDebugString('SDL3 Gamepad Core initialized successfully.');
  except
    on E: Exception do
      OutputDebugString(PChar('Gamepad Init Error: ' + E.Message));
  end;
end;

procedure TYutaniInputManager.ShowGamepadSettings(ParentForm: TForm);
var
  FrmSettings: TfrmGamepadSettings;
begin
  FrmSettings := TfrmGamepadSettings.Create(ParentForm, FGamepadCore);
  try
    FrmSettings.ShowModal;
  finally
    FrmSettings.Free;
  end;
end;

procedure TYutaniInputManager.Rumble(PlayerID: Integer; LowFreq, HighFreq: Word; DurationMS: Cardinal);
begin
  FGamepadCore.Rumble(PlayerID, LowFreq, HighFreq, DurationMS);
end;

procedure TYutaniInputManager.HandleGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
var
  BtnName, StateStr: string;
begin
  if not (Element in [geLeftStickX, geLeftStickY, geRightStickX, geRightStickY, geLT, geRT]) then
  begin
    BtnName := 'Unknown';
    case Element of
      geBtnA:
        BtnName := 'A';
      geBtnB:
        BtnName := 'B';
      geBtnX:
        BtnName := 'X';
      geBtnY:
        BtnName := 'Y';
      geLB:
        BtnName := 'LB';
      geRB:
        BtnName := 'RB';
      geStart:
        BtnName := 'Start';
      geBack:
        BtnName := 'Back';
      geGuide:
        BtnName := 'Guide (Xbox)';
      geLeftStickClick:
        BtnName := 'L3 (Stick Click)';
      geRightStickClick:
        BtnName := 'R3 (Stick Click)';
      gePadUp:
        BtnName := 'D-Pad Up';
      gePadDown:
        BtnName := 'D-Pad Down';
      gePadLeft:
        BtnName := 'D-Pad Left';
      gePadRight:
        BtnName := 'D-Pad Right';
      geExtra1:
        BtnName := 'Extra1 (Share/Paddle)';
      geExtra2:
        BtnName := 'Extra2 (Paddle)';
      geExtra3:
        BtnName := 'Extra3 (Paddle)';
      geExtra4:
        BtnName := 'Extra4 (Paddle)';
    end;
    if Pressed then
      StateStr := 'pressed'
    else
      StateStr := 'released';
    OutputDebugString(PChar(Format('[Pad %d] %s %s', [PadID, BtnName, StateStr])));
  end
  else
  begin
    if Abs(Value) > 0.1 then
    begin
      BtnName := 'Unknown';
      case Element of
        geLeftStickX:
          BtnName := 'Left Stick X';
        geLeftStickY:
          BtnName := 'Left Stick Y';
        geRightStickX:
          BtnName := 'Right Stick X';
        geRightStickY:
          BtnName := 'Right Stick Y';
        geLT:
          BtnName := 'Trigger Left (LT)';
        geRT:
          BtnName := 'Trigger Right (RT)';
      end;
      OutputDebugString(PChar(Format('[Pad %d] %s: %.2f', [PadID, BtnName, Value])));
    end;
  end;
  FLock.Acquire;
  try
    // Per-pad buffered state. PadID is bounded 0..3 by the GamepadCore
    // itself so we can index safely here without an extra range check.
    if (PadID >= 0) and (PadID <= 3) then
    begin
      case Element of
        geLeftStickY:
          // SDL Y axis is inverted: pushing the stick UP returns a
          // negative value. We negate it here so that "stick up" produces
          // a positive Fwd, which the controllers treat as "move forward".
          FPlayerStates[PadID].Fwd := -Value;
        geLeftStickX:
          FPlayerStates[PadID].Right := Value;
        geRightStickX:
          FPlayerStates[PadID].LookX := FPlayerStates[PadID].LookX + Value;
        geRightStickY:
          FPlayerStates[PadID].LookY := FPlayerStates[PadID].LookY + Value;
        geBtnA:
          FPlayerStates[PadID].Action1 := Pressed;
        geBtnB:
          FPlayerStates[PadID].Action2 := Pressed;
        geLT:
          if Pressed then
            FPlayerStates[PadID].Up := 1.0
          else
            FPlayerStates[PadID].Up := 0.0;
        geRT:
          if Pressed then
            FPlayerStates[PadID].Up := -1.0
          else if FPlayerStates[PadID].Up = -1.0 then
            FPlayerStates[PadID].Up := 0.0;
      end;
    end;
    // Legacy shared buffer mirrors slot 0 so the existing GetInputs call
    // path keeps working unchanged. New split-screen code paths should
    // call GetInputsForPad with the explicit PadID instead.
    if PadID = 0 then
    begin
      case Element of
        geLeftStickY:
          FBufForward := -Value;
        geLeftStickX:
          FBufRight := Value;
        geRightStickX:
          FBufLookX := FBufLookX + Value;
        geRightStickY:
          FBufLookY := FBufLookY + Value;
        geBtnA:
          FBufAction1 := Pressed;
        geBtnB:
          FBufAction2 := Pressed;
        geLT:
          if Pressed then
            FBufUp := 1.0
          else
            FBufUp := 0.0;
        geRT:
          if Pressed then
            FBufUp := -1.0
          else if FBufUp = -1.0 then
            FBufUp := 0.0;
      end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniInputManager.GetInputs(out forward, Right, Up, LookX, LookY: Single; out Action1, Action2: Boolean);
begin
  FLock.Acquire;
  try
    forward := FBufForward;
    Right := FBufRight;
    Up := FBufUp;
    LookX := FBufLookX;
    LookY := FBufLookY;
    Action1 := FBufAction1;
    Action2 := FBufAction2;
    FBufLookX := 0;
    FBufLookY := 0;
  finally
    FLock.Release;
  end;
end;
// ==========================================================================
// Mouselook Implementation
// ==========================================================================
// Mouselook works by tracking the delta between the current cursor
// position and the viewport center. After each poll the cursor is snapped
// back to the center so the user can rotate indefinitely. The cursor is
// hidden while mouselook is active to keep the experience immersive.

procedure TYutaniInputManager.StartMouseLook(ViewportHandle: HWND);
var
  R: TRect;
begin
  if FMouseLookActive then
    Exit;
  FViewportHandle := ViewportHandle;
  if FViewportHandle = 0 then
    Exit;
  // Compute the center of the viewport in screen coordinates so we know
  // where to snap the cursor back to every frame.
  GetWindowRect(FViewportHandle, R);
  FCenterPos.X := (R.Left + R.Right) div 2;
  FCenterPos.Y := (R.Top + R.Bottom) div 2;
  // SetCursorPos before activation so the first poll does not produce a
  // huge delta from wherever the cursor happened to be sitting.
  SetCursorPos(FCenterPos.X, FCenterPos.Y);
  // ShowCursor is reference-counted by Windows, so we loop until it goes
  // negative. This guarantees the cursor is hidden even if other code has
  // bumped the reference count up.
  //
  // CRITICAL: We qualify with the full unit name `Winapi.Windows.ShowCursor`
  // because the Raylib rlgl unit also exports a no-parameter `ShowCursor`
  // procedure. Without the qualifier Delphi would pick the Raylib version
  // (because Raylib comes later in the uses clause) and emit E2034 "too
  // many parameters".
  while Winapi.Windows.ShowCursor(False) >= 0 do
    ;
  FMouseLookActive := True;
end;

procedure TYutaniInputManager.StopMouseLook;
begin
  if not FMouseLookActive then
    Exit;
  FMouseLookActive := False;
  // Restore the cursor the same way we hid it - loop until Windows reports
  // a non-negative reference count, which means the cursor is visible again.
  // See StartMouseLook for why we qualify with the full unit name.
  while Winapi.Windows.ShowCursor(True) < 0 do
    ;
  FViewportHandle := 0;
end;

procedure TYutaniInputManager.PollMouseLook;
var
  p: TPoint;
  DeltaX, DeltaY: Single;
begin
  if (not FMouseLookActive) or (FViewportHandle = 0) then
    Exit;
  // Read the current cursor position. We compute the delta against the
  // viewport center rather than against the previous position because we
  // will snap the cursor back to center in a moment.
  GetCursorPos(p);
  DeltaX := (p.X - FCenterPos.X) * FMouseSensitivity * 0.005;
  DeltaY := (p.Y - FCenterPos.Y) * FMouseSensitivity * 0.005;
  // Invert Y if the user opted into inverted-flight-style controls.
  if FMouseInvertY then
    DeltaY := -DeltaY;
  // Accumulate into both the legacy shared buffer (slot 0) and the
  // explicit per-pad slot 0 - the mouse is always owned by player 0
  // since there is only one physical mouse on the system.
  FLock.Acquire;
  try
    FBufLookX := FBufLookX + DeltaX;
    FBufLookY := FBufLookY + DeltaY;
    FPlayerStates[0].LookX := FPlayerStates[0].LookX + DeltaX;
    FPlayerStates[0].LookY := FPlayerStates[0].LookY + DeltaY;
  finally
    FLock.Release;
  end;
  // Re-center the cursor so the next frame can keep rotating freely.
  SetCursorPos(FCenterPos.X, FCenterPos.Y);
end;

procedure TYutaniInputManager.GetInputsForPad(PadID: Integer; out forward, Right, Up, LookX, LookY: Single; out Action1, Action2: Boolean);
begin
  if (PadID < 0) or (PadID > 3) then
    PadID := 0;
  FLock.Acquire;
  try
    forward := FPlayerStates[PadID].Fwd;
    Right := FPlayerStates[PadID].Right;
    Up := FPlayerStates[PadID].Up;
    LookX := FPlayerStates[PadID].LookX;
    LookY := FPlayerStates[PadID].LookY;
    Action1 := FPlayerStates[PadID].Action1;
    Action2 := FPlayerStates[PadID].Action2;
    // Reset look accumulator so the next frame starts from zero delta.
    // Movement / action state is retained until the gamepad explicitly
    // reports a change (analog stick neutral or button release).
    FPlayerStates[PadID].LookX := 0;
    FPlayerStates[PadID].LookY := 0;
  finally
    FLock.Release;
  end;
end;

function TYutaniInputManager.GetPlayerState(PadID: Integer): TYutaniPlayerInputState;
begin
  if (PadID < 0) or (PadID > 3) then
    PadID := 0;
  FLock.Acquire;
  try
    Result := FPlayerStates[PadID];
  finally
    FLock.Release;
  end;
end;
{ TYutaniAvatarController }

constructor TYutaniAvatarController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited Create;
  FAvatar := AAvatar;
  FCamera := ACamera;
  FCamYaw := -0.5;
  FCamPitch := 0.8;
  FCamDist := 10.0;
  FMoveSpeed := 15.0;
  // Camera smoothing defaults. CamSmoothing > 0 gives a soft chase feel in
  // normal operation; BeginCameraTransition starts an additional one-shot
  // ease for cinematic swaps. Both can be tuned per controller in their
  // own constructors or from outside via the published properties.
  FCamSmoothing := 5.0;
  FCamTransitionActive := False;
  FCamTransitionProgress := 0.0;
  FCamTransitionDuration := 0.6;
  FCamStartPos := Vector3Create(0, 0, 0);
  FCamStartTarget := Vector3Create(0, 0, 0);
  FCamStartUp := Vector3Create(0, 1, 0);
  // Camera collision defaults. The radius is intentionally small so the
  // camera can squeeze through doorways; raise it if the near plane
  // still clips into thick walls.
  FCameraCollisionActive := True;
  FCameraCollisionRadius := 0.3;
  // Avatar facing defaults. Disabled on the base class so controllers
  // that manage avatar rotation themselves (Vehicle, Flight) are not
  // fought over. ThirdPerson / RigidBody / FirstPerson opt in inside
  // their own constructors.
  FAvatarFacingActive := False;
  FAvatarFacingSpeed := 8.0;
  // Wheel zoom defaults. Range covers tight over-the-shoulder to wide
  // cinematic distance; tighten in a settings dialog per game needs.
  FZoomSpeed := 5.0;
  FMinCamDist := 3.0;
  FMaxCamDist := 30.0;
  // Footstep audio defaults. 0.45s interval matches a casual walking
  // cadence at ~4 m/s; the helper scales this down as speed increases.
  FFootstepTimer := 0.0;
  FFootstepBaseInterval := 0.45;
  FOnFootstep := nil;
end;

procedure TYutaniAvatarController.BeginCameraTransition(Duration: Single);
begin
  // Capture the current camera state so WriteCameraTransform can ease from
  // it over the next Duration seconds. If the camera pointer is nil (e.g.
  // during construction before the sandbox assigned one) we simply no-op;
  // the next UpdateCameraTransform will fall back to always-on smoothing.
  if not Assigned(FCamera) then
    Exit;
  if Duration <= 0.001 then
  begin
    // Treat a zero/negative duration as "skip transition" so callers can
    // pass user-configurable values without worrying about divide-by-zero.
    FCamTransitionActive := False;
    Exit;
  end;
  FCamStartPos := FCamera^.position;
  FCamStartTarget := FCamera^.target;
  FCamStartUp := FCamera^.Up;
  FCamTransitionProgress := 0.0;
  FCamTransitionDuration := Duration;
  FCamTransitionActive := True;
end;

procedure TYutaniAvatarController.WriteCameraTransform(const Pos, Target, Up: TVector3; dt: Single);
var
  Alpha: Single;
  FinalPos, FinalTarget, FinalUp, CollideAdjustedPos: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  // Run camera collision against the freshly computed desired position.
  // We use the desired target as the ray origin so the camera can never
  // be pushed through a wall by an avatar that is itself pressed against
  // one - the avatar stays visible on the near side of any obstacle.
  CollideAdjustedPos := ResolveCameraCollision(Target, Pos);
  if FCamTransitionActive then
  begin
    // --- One-shot cinematic transition ---
    // Eases from the captured start state to the freshly computed desired
    // state over FCamTransitionDuration seconds. We use a smoothstep ease
    // (t^2 * (3 - 2t)) because it has zero velocity at both ends, which
    // prevents the camera from popping when the transition ends.
    FCamTransitionProgress := FCamTransitionProgress + (dt / FCamTransitionDuration);
    if FCamTransitionProgress >= 1.0 then
    begin
      FCamTransitionProgress := 1.0;
      FCamTransitionActive := False;
    end;
    Alpha := FCamTransitionProgress * FCamTransitionProgress * (3.0 - 2.0 * FCamTransitionProgress);
    FinalPos := Vector3Lerp(FCamStartPos, CollideAdjustedPos, Alpha);
    FinalTarget := Vector3Lerp(FCamStartTarget, Target, Alpha);
    FinalUp := Vector3Lerp(FCamStartUp, Up, Alpha);
  end
  else if FCamSmoothing > 0.0 then
  begin
    // --- Always-on chase smoothing ---
    // Lerps the current camera state towards the desired state by a
    // dt-scaled factor. This keeps the camera glued to the avatar during
    // fast motion while still feeling like a real lens motor instead of
    // a hard lock. Clamped to 1.0 so a long dt cannot overshoot.
    Alpha := EnsureRange(FCamSmoothing * dt, 0.0, 1.0);
    FinalPos := Vector3Lerp(FCamera^.position, CollideAdjustedPos, Alpha);
    FinalTarget := Vector3Lerp(FCamera^.Target, Target, Alpha);
    FinalUp := Vector3Lerp(FCamera^.Up, Up, Alpha);
  end
  else
  begin
    // No smoothing - write directly. This is the original behaviour so
    // setting CamSmoothing := 0 fully restores the pre-smoothing feel.
    FinalPos := CollideAdjustedPos;
    FinalTarget := Target;
    FinalUp := Up;
  end;
  FCamera^.position := FinalPos;
  FCamera^.Target := FinalTarget;
  FCamera^.Up := FinalUp;
end;

function TYutaniAvatarController.ResolveCameraCollision(const Anchor, DesiredPos: TVector3): TVector3;
var
  ToCam, Dir: TVector3;
  Dist, HitDist: Single;
  HitBodyID: JPH_BodyID;
  HitPoint: TVector3;
begin
  Result := DesiredPos;
  if (not FCameraCollisionActive) or (not Assigned(FAvatar)) or (not Assigned(FAvatar.FEngine)) then
    Exit;
  ToCam := Vector3Subtract(DesiredPos, Anchor);
  Dist := Vector3Length(ToCam);
  if Dist < 0.001 then
    Exit;
  Dir := Vector3Scale(ToCam, 1.0 / Dist);
  // Raycast from the look anchor (avatar position) towards the desired
  // camera position. Jolt's RayCast expects a normalized direction and
  // returns the hit fraction as a 0..1 value along that direction, so
  // the hit point distance from Anchor equals fraction * Dist (because
  // Dir is normalized, fraction IS the distance in world units).
  if FAvatar.FEngine.RayCast(Anchor, Dir, HitBodyID, HitPoint) then
  begin
    HitDist := Vector3Distance(Anchor, HitPoint);
    if HitDist < Dist then
    begin
      // Pull the camera in to just before the contact point. We subtract
      // the safety radius so the near plane does not intersect the wall
      // and clamp to a tiny minimum so the camera does not end up inside
      // the anchor itself.
      HitDist := HitDist - FCameraCollisionRadius;
      if HitDist < 0.1 then
        HitDist := 0.1;
      Result := Vector3Add(Anchor, Vector3Scale(Dir, HitDist));
    end;
  end;
end;

procedure TYutaniAvatarController.HandleWheelZoom(dt: Single);
var
  Wheel: Single;
begin
  // Raylib's GetMouseWheelMove returns positive for scroll up (zoom in)
  // and negative for scroll down (zoom out). We invert the sign so that
  // scroll up reduces CamDist (camera moves closer = zoom in).
  Wheel := GetMouseWheelMove();
  if Wheel = 0 then
    Exit;
  FCamDist := EnsureRange(FCamDist - Wheel * FZoomSpeed, FMinCamDist, FMaxCamDist);
end;

procedure TYutaniAvatarController.FaceMovementDirection(const Vel: TVector3; dt: Single);
var
  HorizSpeed: Single;
  DesiredYaw, CurrentYaw, YawDelta: Single;
  RotQuat: TQuaternion;
  Qx, Qy, Qz, Qw: Single;
begin
  if (not FAvatarFacingActive) or (not Assigned(FAvatar)) then
    Exit;
  HorizSpeed := Sqrt(Vel.x * Vel.x + Vel.z * Vel.z);
  // Only rotate when the avatar is actually moving horizontally. This
  // prevents the body twitching in place when the avatar lands from a
  // jump or stands still while the player looks around.
  if HorizSpeed < 0.5 then
    Exit;
  // Desired yaw from velocity. We use atan2(-x, -z) so that a velocity
  // of (0, 0, +1) (forward in engine conventions) maps to yaw = 0,
  // matching the convention used by the third person controller.
  DesiredYaw := ArcTan2(-Vel.x, -Vel.z);
  // Extract current yaw from the avatar's quaternion. The standard
  // yaw-from-quaternion formula for a rotation around Y only.
  Qx := FAvatar.FQuaternion.x;
  Qy := FAvatar.FQuaternion.y;
  Qz := FAvatar.FQuaternion.z;
  Qw := FAvatar.FQuaternion.w;
  CurrentYaw := ArcTan2(2 * (Qw * Qy + Qx * Qz), 1 - 2 * (Qy * Qy + Qx * Qx));
  // Compute the shortest angular delta (mod 2*PI) so the body always
  // turns the shorter way around when the direction changes sign.
  YawDelta := DesiredYaw - CurrentYaw;
  while YawDelta > PI do
    YawDelta := YawDelta - 2 * PI;
  while YawDelta < -PI do
    YawDelta := YawDelta + 2 * PI;
  // Smoothly rotate towards the desired yaw. The clamp prevents
  // overshooting at high delta time values (e.g. after a hitch).
  YawDelta := EnsureRange(YawDelta * FAvatarFacingSpeed * dt, -Abs(YawDelta), Abs(YawDelta));
  CurrentYaw := CurrentYaw + YawDelta;
  RotQuat := QuaternionFromAxisAngle(Vector3Create(0, 1, 0), CurrentYaw);
  FAvatar.SetRotation(RotQuat);
end;

procedure TYutaniAvatarController.UpdateFootstepAudio(dt: Single);
var
  Vel: TVector3;
  Speed, Interval: Single;
begin
  if (not Assigned(FOnFootstep)) or (not Assigned(FAvatar)) then
    Exit;
  Vel := FAvatar.GetLinearVelocity;
  // Only consider horizontal speed so a falling avatar does not spawn
  // a flurry of footsteps on the way down.
  Speed := Sqrt(Vel.x * Vel.x + Vel.z * Vel.z);
  if Speed < 1.0 then
  begin
    FFootstepTimer := 0;
    Exit;
  end;
  // Walk speed reference is 4 m/s. Faster movement = proportionally
  // shorter interval. Clamped to 0.2s so running does not turn into
  // a continuous buzzing sound.
  Interval := FFootstepBaseInterval / (Speed / 4.0);
  if Interval < 0.2 then
    Interval := 0.2;
  FFootstepTimer := FFootstepTimer + dt;
  if FFootstepTimer >= Interval then
  begin
    FFootstepTimer := FFootstepTimer - Interval;
    FOnFootstep(Self);
  end;
end;

destructor TYutaniAvatarController.Destroy;
begin
  if Assigned(FAvatar) and (FAvatar.FBodyID <> 0) then
    FAvatar.SetGravityFactor(1.0);
  inherited;
end;

procedure TYutaniAvatarController.SetAvatar(const Value: TA3DComponent);
begin
  FAvatar := Value;
  if Assigned(FAvatar) then
    FAvatar.ActivateBody;
end;

procedure TYutaniAvatarController.HandleKeyboardInput;
begin
  if (GetAsyncKeyState(Ord('W')) and $8000) <> 0 then
    FInputForward := 1.0;
  if (GetAsyncKeyState(Ord('S')) and $8000) <> 0 then
    FInputForward := -1.0;
  if (GetAsyncKeyState(Ord('A')) and $8000) <> 0 then
    FInputRight := -1.0;
  if (GetAsyncKeyState(Ord('D')) and $8000) <> 0 then
    FInputRight := 1.0;
end;
{ TYutaniThirdPersonController }

constructor TYutaniThirdPersonController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  FJumpForce := 7.0;
  FMoveSpeed := 10.0;
  // Turn avatar facing on so the body rotates to face the walk direction.
  // The lerp speed is high so the avatar snaps to direction changes
  // quickly without lagging behind the player's input.
  FAvatarFacingActive := True;
  FAvatarFacingSpeed := 10.0;
  // Slightly tighter zoom range for a third person chase feel.
  FMinCamDist := 3.0;
  FMaxCamDist := 15.0;
end;

procedure TYutaniThirdPersonController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  fwd, right, vel: TVector3;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;
  // Mouse wheel zoom: lets the player dial in their preferred chase
  // distance live without touching the settings dialog.
  HandleWheelZoom(DeltaTime);
  FCamYaw := FCamYaw + (FInputLookX * 0.05);
  FCamPitch := EnsureRange(FCamPitch - (FInputLookY * 0.05), 0.1, 1.5);
  fwd := Vector3Create(-Sin(FCamYaw), 0, -Cos(FCamYaw));
  right := Vector3Create(Cos(FCamYaw), 0, -Sin(FCamYaw));
  vel.x := (fwd.x * FInputForward + right.x * FInputRight) * FMoveSpeed;
  vel.z := (fwd.z * FInputForward + right.z * FInputRight) * FMoveSpeed;
  vel.y := FAvatar.GetLinearVelocity.y;
  FAvatar.SetLinearVelocity(vel);
  // Rotate the avatar body to face the velocity direction. This makes
  // the avatar look where it is walking instead of sliding in place.
  FaceMovementDirection(vel, DeltaTime);
  // Footstep audio: fires FOnFootstep at a speed-scaled interval.
  UpdateFootstepAudio(DeltaTime);
  if FInputAction1 or ((GetAsyncKeyState(VK_SPACE) and $8000) <> 0) then
  begin
    if FAvatar.Position.y <= 1.0 then
    begin
      vel.y := FJumpForce;
      FAvatar.SetLinearVelocity(vel);
      FAvatar.ActivateBody;
    end;
  end;
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniThirdPersonController.UpdateCameraTransform(dt: Single);
var
  Pos, Target, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  Target := Vector3Create(FAvatar.Position.x, FAvatar.Position.y + 2.0, FAvatar.Position.z);
  Pos := Vector3Create(FAvatar.Position.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FAvatar.Position.y + Sin(FCamPitch) * FCamDist, FAvatar.Position.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(Pos, Target, Up, dt);
end;
{ TYutaniFlightController }

constructor TYutaniFlightController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  FMoveSpeed := 25.0;
  FCamDist := 15.0;
end;

procedure TYutaniFlightController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  fwd, right, up, vel: TVector3;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;
  // Wheel zoom lets the player pull the chase camera back for a wider
  // view while flying. Useful for navigating tight terrain where the
  // default distance feels too claustrophobic.
  HandleWheelZoom(DeltaTime);
  if (GetAsyncKeyState(VK_SPACE) and $8000) <> 0 then
    FInputUp := 1.0;
  if (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0 then
    FInputUp := -1.0;
  FAvatar.SetGravityFactor(0.0);
  FAvatar.SetAngularVelocity(Vector3Create(0, 0, 0));
  FCamYaw := FCamYaw + (FInputLookX * 0.05);
  FCamPitch := EnsureRange(FCamPitch - (FInputLookY * 0.05), -1.4, 1.4);
  fwd := Vector3Create(Cos(FCamPitch) * Sin(FCamYaw), Sin(FCamPitch), Cos(FCamPitch) * Cos(FCamYaw));
  fwd := Vector3Normalize(fwd);
  right := Vector3Normalize(Vector3CrossProduct(fwd, Vector3Create(0, 1, 0)));
  up := Vector3Create(0, 1, 0);
  vel := Vector3Create(0, 0, 0);
  vel := Vector3Add(vel, Vector3Scale(fwd, FInputForward * FMoveSpeed));
  vel := Vector3Add(vel, Vector3Scale(right, FInputRight * FMoveSpeed));
  vel := Vector3Add(vel, Vector3Scale(up, FInputUp * FMoveSpeed));
  FAvatar.SetLinearVelocity(vel);
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniFlightController.UpdateCameraTransform(dt: Single);
var
  back, Pos, Target, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  back := Vector3Create(Cos(FCamPitch) * Sin(FCamYaw + PI), Sin(FCamPitch + PI), Cos(FCamPitch) * Cos(FCamYaw + PI));
  Target := Vector3Create(FAvatar.Position.x, FAvatar.Position.y + 2.0, FAvatar.Position.z);
  Pos := Vector3Add(FAvatar.Position, Vector3Scale(back, FCamDist));
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(Pos, Target, Up, dt);
end;
{ TYutaniVehicleController }

constructor TYutaniVehicleController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  FMaxSpeed := 50.0;
  FTurnSpeed := 2.0;
  FCurrentSpeed := 0;
  FCamDist := 12.0;
  FVehicleModelOffset := 0;
end;

procedure TYutaniVehicleController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  vel, fwd: TVector3;
  RotQuat: TQuaternion;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;
  // Wheel zoom adjusts chase distance on the fly. Useful when parking
  // or maneuvering in tight spots so the player can pull the camera
  // in for a closer look at the avatar.
  HandleWheelZoom(DeltaTime);
  if (GetAsyncKeyState(Ord('Q')) and $8000) <> 0 then
    FInputUp := 1.0;
  if (GetAsyncKeyState(Ord('E')) and $8000) <> 0 then
    FInputUp := -1.0;
  if FInputForward > 0 then
    FCurrentSpeed := EnsureRange(FCurrentSpeed + (20 * DeltaTime), 0, FMaxSpeed)
  else if FInputForward < 0 then
    FCurrentSpeed := EnsureRange(FCurrentSpeed - (40 * DeltaTime), -FMaxSpeed * 0.5, FMaxSpeed)
  else
    FCurrentSpeed := FCurrentSpeed * (1.0 - (0.5 * DeltaTime));
  if Abs(FCurrentSpeed) > 0.1 then
    FCamYaw := FCamYaw - (FInputRight * FTurnSpeed * DeltaTime * (FCurrentSpeed / FMaxSpeed));
  fwd := Vector3Create(-Sin(FCamYaw), 0, -Cos(FCamYaw));
  FAvatar.SetAngularVelocity(Vector3Create(0, 0, 0));
  FAvatar.SetGravityFactor(0.0);
  vel := Vector3Scale(fwd, FCurrentSpeed);
  vel.y := FInputUp * 10.0;
  FAvatar.SetLinearVelocity(vel);
  RotQuat := QuaternionFromAxisAngle(Vector3Create(0, 1, 0), FCamYaw + FVehicleModelOffset);
  FAvatar.SetRotation(RotQuat);
  // Footstep-style audio trigger: not used for footsteps but can be
  // repurposed for engine-idle / tire-roll cues by wiring a different
  // callback to OnFootstep from the sandbox.
  UpdateFootstepAudio(DeltaTime);
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniVehicleController.UpdateCameraTransform(dt: Single);
var
  back, Pos, Target, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  back := Vector3Create(Sin(FCamYaw), 0, Cos(FCamYaw));
  Target := Vector3Create(FAvatar.Position.x, FAvatar.Position.y + 2.0, FAvatar.Position.z);
  Pos := Vector3Create(FAvatar.Position.x + (back.x * FCamDist), FAvatar.Position.y + 6.0, FAvatar.Position.z + (back.z * FCamDist));
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(Pos, Target, Up, dt);
end;
// ==========================================================================
// NEW IMPLEMENTATIONS
// ==========================================================================
{ TYutaniAvatarSettings }

class function TYutaniAvatarSettings.Default: TYutaniAvatarSettings;
begin
  // Reasonable defaults for a third-person action game. Tweaking these in a
  // settings dialog lets the player personalise the feel of the avatar
  // without touching code.
  Result.LookSensitivity := 1.0;
  Result.InvertY := False;
  Result.MoveDeadzone := 0.15;
  Result.LookDeadzone := 0.10;
  Result.SprintMultiplier := 2.0;
  Result.CrouchMultiplier := 0.45;
  Result.CameraSmoothing := 0.15;
  Result.MinCamPitch := -1.4;     // ~ -80 degrees
  Result.MaxCamPitch := 1.4;      // ~ +80 degrees
  Result.FOVNormal := 60.0;
  Result.FOVSprint := 75.0;
end;
{ TYutaniFirstPersonController }

constructor TYutaniFirstPersonController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  // First person uses no orbit distance - the camera sits directly inside
  // the avatar head. Movement speed is slower than third person because
  // the player is closer to the action.
  FMoveSpeed := 8.0;
  FCamDist := 0.0;
  FEyeHeight := 1.7;
  FCrouchHeight := 0.9;
  FCurrentEyeHeight := FEyeHeight;
  FHeadBobTime := 0.0;
  FHeadBobOffset := 0.0;
  FSensitivity := 1.0;
  FInvertY := False;
  FJumpForce := 6.0;
  FWalkFOV := 60.0;
  FSprintFOV := 75.0;
  FCurrentFOV := FWalkFOV;
  // ADS defaults. Right mouse button is the natural aim trigger in PC
  // games; since mouselook hides the cursor during driving, RMB has no
  // other duty and is free for ADS. ADSFOV is sniper-mag tier by default;
  // tweak down to 15 for very long range, up to 45 for a red-dot feel.
  FADSActive := False;
  FADSTriggerKey := VK_RBUTTON;
  FADSFOV := 30.0;
  FADSWheelStep := 2.0;
  FYaw := 0.0;
  FPitch := 0.0;
  // Enable avatar facing so the body matches the view yaw. The body
  // rotation call is redundant (we already SetRotation in Update) but
  // turning on the flag lets external code paths reuse the helper too.
  FAvatarFacingActive := True;
end;

procedure TYutaniFirstPersonController.UpdateHeadBob(dt: Single; IsMoving: Boolean);
const
  BOB_FREQ = 10.0;     // Approximate step frequency while jogging
  BOB_AMP = 0.045;     // Vertical amplitude in world units
begin
  // A subtle sine-wave bob gives the player a sense of weight and contact
  // with the ground. The bob decays smoothly back to zero when standing
  // still so the camera does not feel jittery while aiming.
  if IsMoving then
  begin
    FHeadBobTime := FHeadBobTime + dt * BOB_FREQ;
    FHeadBobOffset := Sin(FHeadBobTime) * BOB_AMP;
  end
  else
  begin
    FHeadBobOffset := FHeadBobOffset * (1.0 - dt * 8.0);
    if Abs(FHeadBobOffset) < 0.001 then
    begin
      FHeadBobOffset := 0.0;
      FHeadBobTime := 0.0;
    end;
  end;
end;

procedure TYutaniFirstPersonController.UpdateFOV(dt: Single);
var
  TargetFOV: Single;
begin
  // Smoothly lerp the field of view between walking, sprinting and ADS so
  // the transition feels like a cinematic speed rush / aim-in animation
  // instead of a hard cut. ADS has priority so the player can dial in a
  // long-range shot even while sprinting.
  if FADSActive then
    TargetFOV := FADSFOV
  else if FSprintActive then
    TargetFOV := FSprintFOV
  else
    TargetFOV := FWalkFOV;
  FCurrentFOV := Lerp(FCurrentFOV, TargetFOV, EnsureRange(dt * 6.0, 0.0, 1.0));
  if Assigned(FCamera) then
    FCamera^.fovy := FCurrentFOV;
end;

procedure TYutaniFirstPersonController.HandleWheelZoom(dt: Single);
var
  Wheel: Single;
begin
  Wheel := GetMouseWheelMove();
  if Wheel = 0 then
    Exit;
  if FADSActive then
  begin
    // While aiming, the wheel adjusts the ADS target FOV so the player
    // can swap between magnification tiers without leaving ADS.
    FADSFOV := EnsureRange(FADSFOV - Wheel * FADSWheelStep, 10.0, 60.0);
  end
  else
  begin
    // Not aiming - the wheel still feels useful, so let it nudge the
    // walk FOV so the user can pick their preferred field of view.
    FWalkFOV := EnsureRange(FWalkFOV - Wheel * FADSWheelStep, 40.0, 90.0);
  end;
end;

procedure TYutaniFirstPersonController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  fwd, right, vel: TVector3;
  SpeedScale: Single;
  CurrentVel: TVector3;
  IsMoving: Boolean;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;
  // --- Keyboard modifiers: sprint, crouch, jump ---
  FSprintActive := (GetAsyncKeyState(VK_SHIFT) and $8000) <> 0;
  FIsCrouching := (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0;
  // --- ADS trigger detection ---
  // Held-key behaviour: FADSActive mirrors the current key state so the
  // player can tap-zoom by tapping and hold-zoom by holding. Wheel input
  // is only sampled while aiming, so non-ADS wheel motion falls through
  // to the WalkFOV tuning branch in HandleWheelZoom.
  FADSActive := (GetAsyncKeyState(FADSTriggerKey) and $8000) <> 0;
  // --- Wheel zoom / ADS zoom tuning ---
  HandleWheelZoom(DeltaTime);
  // --- Apply look input to yaw and pitch ---
  // Stick up produces positive Y, but we want look-up to be positive pitch,
  // so we invert the sign here unless the user requested Y inversion.
  if FInvertY then
    FPitch := EnsureRange(FPitch + (FInputLookY * 0.05 * FSensitivity), -1.4, 1.4)
  else
    FPitch := EnsureRange(FPitch - (FInputLookY * 0.05 * FSensitivity), -1.4, 1.4);
  // Inverted horizontal look: moving the mouse right turns the view left
  // and vice versa. This matches the requested "natural" feel for the
  // first-person controller. Other controllers keep the standard mapping.
  FYaw := FYaw - (FInputLookX * 0.05 * FSensitivity);
  // Mirror to the base class so external code reading CamYaw/CamPitch still
  // works (e.g. the existing camera HUD or save-load routines).
  FCamYaw := FYaw;
  FCamPitch := FPitch;
  // --- Build basis vectors from yaw only ---
  // Movement stays on the ground plane so the player does not fly when
  // looking up. Vertical motion is handled entirely by gravity + jump.
  fwd := Vector3Create(-Sin(FYaw), 0, -Cos(FYaw));
  right := Vector3Create(Cos(FYaw), 0, -Sin(FYaw));
  // --- Determine effective speed based on sprint / crouch state ---
  SpeedScale := 1.0;
  if FSprintActive and (not FIsCrouching) then
    SpeedScale := 2.0
  else if FIsCrouching then
    SpeedScale := 0.45;
  // --- Compose target velocity, preserving gravity-driven Y velocity ---
  vel.x := (fwd.x * FInputForward + right.x * FInputRight) * FMoveSpeed * SpeedScale;
  vel.z := (fwd.z * FInputForward + right.z * FInputRight) * FMoveSpeed * SpeedScale;
  CurrentVel := FAvatar.GetLinearVelocity;
  vel.y := CurrentVel.y;
  FAvatar.SetLinearVelocity(vel);
  // --- Jump: only when close to ground and moving downwards ---
  // The Position.y <= 1.2 check is intentionally a bit loose so the player
  // can jump from small steps and uneven terrain without feeling stuck.
  if (FInputAction1) or ((GetAsyncKeyState(VK_SPACE) and $8000) <> 0) then
  begin
    if (FAvatar.Position.y <= 1.2) and (CurrentVel.y <= 0.1) then
    begin
      vel.y := FJumpForce;
      FAvatar.SetLinearVelocity(vel);
      FAvatar.ActivateBody;
    end;
  end;
  // --- Rotate the avatar body so its visual orientation matches the view yaw ---
  // This keeps third-person rendering of the avatar (shadow, mirror, other
  // players) consistent with where the player is actually looking.
  FAvatar.SetRotation(QuaternionFromAxisAngle(Vector3Create(0, 1, 0), FYaw));
  // --- Smoothly transition eye height when crouching ---
  // Lerp gives a soft dip instead of an instant snap, which feels much
  // more natural and prevents motion sickness.
  if FIsCrouching then
    FCurrentEyeHeight := Lerp(FCurrentEyeHeight, FCrouchHeight, EnsureRange(DeltaTime * 10.0, 0.0, 1.0))
  else
    FCurrentEyeHeight := Lerp(FCurrentEyeHeight, FEyeHeight, EnsureRange(DeltaTime * 10.0, 0.0, 1.0));
  // Determine if horizontal movement is happening so the head bob activates
  IsMoving := (Abs(FInputForward) > 0.1) or (Abs(FInputRight) > 0.1);
  UpdateHeadBob(DeltaTime, IsMoving);
  UpdateFOV(DeltaTime);
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniFirstPersonController.UpdateCameraTransform(dt: Single);
var
  EyePos, LookTarget, Fwd, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  // Position the camera at the avatar's eye height plus the head bob offset.
  EyePos := Vector3Create(FAvatar.Position.x, FAvatar.Position.y + FCurrentEyeHeight + FHeadBobOffset, FAvatar.Position.z);
  // Forward vector combining yaw + pitch so looking up/down tilts the view.
  // The math mirrors the flight controller: pitch lifts the Y component,
  // yaw rotates the horizontal direction.
  Fwd := Vector3Create(Cos(FPitch) *  - Sin(FYaw), Sin(FPitch), Cos(FPitch) *  - Cos(FYaw));
  LookTarget := Vector3Add(EyePos, Fwd);
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(EyePos, LookTarget, Up, dt);
end;
{ TYutaniSpectatorController }

constructor TYutaniSpectatorController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  // Spectator flies faster than the flight controller because level
  // designers need to traverse large scenes quickly.
  FMoveSpeed := 20.0;
  FCamDist := 0.0;
  FBoostMultiplier := 4.0;
  FSensitivity := 1.0;
  FInvertY := False;
end;

procedure TYutaniSpectatorController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  fwd, right, up, vel: TVector3;
  SpeedScale: Single;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;
  // Keyboard vertical: Space = up, Ctrl = down. Mirrors the flight controller
  // so users do not have to relearn muscle memory between the two modes.
  if (GetAsyncKeyState(VK_SPACE) and $8000) <> 0 then
    FInputUp := 1.0;
  if (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0 then
    FInputUp := -1.0;
  // Sprint gives a strong speed multiplier for crossing large maps fast.
  FSprintActive := (GetAsyncKeyState(VK_SHIFT) and $8000) <> 0;
  // Disable gravity & freeze any rotation so the avatar floats in pure 6DOF.
  // We do not touch the avatar's rotation here so the avatar keeps whatever
  // orientation the player previously set - useful for placement work.
  FAvatar.SetGravityFactor(0.0);
  FAvatar.SetAngularVelocity(Vector3Create(0, 0, 0));
  // Apply look input (pitch is inverted unless the user opted out).
  if FInvertY then
    FCamPitch := EnsureRange(FCamPitch + (FInputLookY * 0.05 * FSensitivity), -1.4, 1.4)
  else
    FCamPitch := EnsureRange(FCamPitch - (FInputLookY * 0.05 * FSensitivity), -1.4, 1.4);
  FCamYaw := FCamYaw + (FInputLookX * 0.05 * FSensitivity);
  fwd := Vector3Create(Cos(FCamPitch) * Sin(FCamYaw), Sin(FCamPitch), Cos(FCamPitch) * Cos(FCamYaw));
  fwd := Vector3Normalize(fwd);
  right := Vector3Normalize(Vector3CrossProduct(fwd, Vector3Create(0, 1, 0)));
  up := Vector3Create(0, 1, 0);
  SpeedScale := 1.0;
  if FSprintActive then
    SpeedScale := FBoostMultiplier;
  vel := Vector3Create(0, 0, 0);
  vel := Vector3Add(vel, Vector3Scale(fwd, FInputForward * FMoveSpeed * SpeedScale));
  vel := Vector3Add(vel, Vector3Scale(right, FInputRight * FMoveSpeed * SpeedScale));
  vel := Vector3Add(vel, Vector3Scale(up, FInputUp * FMoveSpeed * SpeedScale));
  FAvatar.SetLinearVelocity(vel);
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniSpectatorController.UpdateCameraTransform(dt: Single);
var
  fwd, Pos, Target, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  fwd := Vector3Create(Cos(FCamPitch) * Sin(FCamYaw), Sin(FCamPitch), Cos(FCamPitch) * Cos(FCamYaw));
  fwd := Vector3Normalize(fwd);
  // In spectator mode the camera IS the avatar position - there is no
  // orbit distance. The avatar body is simply the camera anchor.
  Pos := FAvatar.Position;
  Target := Vector3Add(FAvatar.Position, fwd);
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(Pos, Target, Up, dt);
end;
{ TYutaniOrbitController }

constructor TYutaniOrbitController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  // Orbit controller is for showcase / inspection, so the avatar itself
  // does not move. We still inherit FMoveSpeed for API consistency but
  // it is intentionally zero.
  FMoveSpeed := 0.0;
  FCamDist := 6.0;
  FTargetDist := FCamDist;
  FCamYaw := 0.0;
  FCamPitch := 0.4;
  FAutoRotate := True;
  FAutoRotateSpeed := 0.4;         // Slow drift, ~23 deg/sec
end;

procedure TYutaniOrbitController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  // Manual look always overrides auto-rotation when the user touches the
  // stick. As soon as they let go, auto-rotation resumes. This is the
  // standard "Idle Cinematic" pattern used in many game main menus.
  if (Abs(FInputLookX) > 0.05) or (Abs(FInputLookY) > 0.05) then
  begin
    FAutoRotate := False;
    FCamYaw := FCamYaw + (FInputLookX * 0.05);
    FCamPitch := EnsureRange(FCamPitch - (FInputLookY * 0.05), 0.05, 1.5);
  end
  else
  begin
    FAutoRotate := True;
  end;
  // Distance adjustment via the forward/back axis. Triggers (FInputUp)
  // are wired to the same channel by the input manager, so they work too.
  if Abs(FInputForward) > 0.05 then
    FTargetDist := EnsureRange(FTargetDist - FInputForward * 0.5, 3.0, 50.0);
  if Abs(FInputUp) > 0.05 then
    FTargetDist := EnsureRange(FTargetDist - FInputUp * 0.5, 3.0, 50.0);
  // Smoothly lerp the actual distance towards the target so zoom feels
  // like a real lens motor rather than an instant cut.
  FCamDist := Lerp(FCamDist, FTargetDist, EnsureRange(DeltaTime * 6.0, 0.0, 1.0));
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniOrbitController.UpdateCameraTransform(dt: Single);
var
  Pos, Target, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  if FAutoRotate then
    FCamYaw := FCamYaw + (FAutoRotateSpeed * dt);
  // Spherical coordinate to Cartesian conversion. Pitch lifts the camera
  // above the avatar, yaw rotates around the vertical axis.
  Pos := Vector3Create(FAvatar.Position.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FAvatar.Position.y + Sin(FCamPitch) * FCamDist + 1.5, FAvatar.Position.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
  // Look slightly above the avatar's pivot so headshots of character
  // models feel natural instead of looking at their feet.
  Target := Vector3Create(FAvatar.Position.x, FAvatar.Position.y + 1.5, FAvatar.Position.z);
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(Pos, Target, Up, dt);
end;
{ TYutaniRigidBodyController }

constructor TYutaniRigidBodyController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  // Forces are tuned for a roughly 1kg avatar body. Heavier bodies will
  // accelerate more slowly - which is physically correct behaviour.
  FMoveSpeed := 10.0;
  FAccelForce := 200.0;
  FMaxSpeed := 12.0;
  FJumpImpulse := 7.0;
  FTorqueForce := 80.0;
  FTargetYaw := 0.0;
  FSensitivity := 1.0;
  FInvertY := False;
  FIsGrounded := False;
  FCamDist := 8.0;
  // Enable avatar facing so the body physically rotates to match the
  // movement direction. Slower lerp factor than ThirdPerson because the
  // body is force-driven and a fast snap would fight with the physics
  // solver's angular velocity.
  FAvatarFacingActive := True;
  FAvatarFacingSpeed := 6.0;
end;

function TYutaniRigidBodyController.CheckGrounded: Boolean;
var
  Origin, Dir: TVector3;
  HitBodyID: JPH_BodyID;
  HitPoint: TVector3;
begin
  // Cast a short ray straight down from the avatar's centre. If anything
  // is hit within 1.2 units, we consider the avatar grounded. This is a
  // huge improvement over the third person controller's Position.y <= 1.0
  // check because it works on ramps, stairs and stacked objects.
  if not Assigned(FAvatar.FEngine) then
    Exit(False);
  Origin := FAvatar.Position;
  Dir := Vector3Create(0, -1, 0);
  Result := FAvatar.FEngine.RayCast(Origin, Dir, HitBodyID, HitPoint);
  // Only treat the avatar as grounded if the hit was close enough.
  Result := Result and (Vector3Distance(Origin, HitPoint) <= 1.2);
end;

procedure TYutaniRigidBodyController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  fwd, right, Force, CurrentVel, TorqueAxis: TVector3;
  SpeedSq, MaxSpeedSq: Single;
  YawDelta, YawStep: Single;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;
  // Wheel zoom: lets the player dial in their preferred orbit distance.
  HandleWheelZoom(DeltaTime);
  // --- Apply look input ---
  if FInvertY then
    FCamPitch := EnsureRange(FCamPitch + (FInputLookY * 0.05 * FSensitivity), -1.4, 1.4)
  else
    FCamPitch := EnsureRange(FCamPitch - (FInputLookY * 0.05 * FSensitivity), -1.4, 1.4);
  FCamYaw := FCamYaw + (FInputLookX * 0.05 * FSensitivity);
  // --- Ground check (raycast based, much more reliable than y-position) ---
  FIsGrounded := CheckGrounded;
  // --- Compute desired forward / right based on camera yaw ---
  fwd := Vector3Create(-Sin(FCamYaw), 0, -Cos(FCamYaw));
  right := Vector3Create(Cos(FCamYaw), 0, -Sin(FCamYaw));
  // --- Apply force to accelerate. Only do this if we are below max speed ---
  // in the desired direction. This prevents runaway acceleration on slopes
  // and respects the soft speed cap. Note: we compare squared lengths to
  // avoid the expensive square root in the inner loop.
  CurrentVel := FAvatar.GetLinearVelocity;
  SpeedSq := (CurrentVel.x * CurrentVel.x) + (CurrentVel.z * CurrentVel.z);
  MaxSpeedSq := FMaxSpeed * FMaxSpeed;
  if (SpeedSq < MaxSpeedSq) and ((Abs(FInputForward) > 0.01) or (Abs(FInputRight) > 0.01)) then
  begin
    Force := Vector3Create(0, 0, 0);
    Force := Vector3Add(Force, Vector3Scale(fwd, FInputForward * FAccelForce * DeltaTime));
    Force := Vector3Add(Force, Vector3Scale(right, FInputRight * FAccelForce * DeltaTime));
    FAvatar.AddForce(Force);
  end;
  // --- Smoothly turn the avatar body to face the camera yaw ---
  // We compute the shortest angular delta to avoid the body spinning the
  // long way around when the player turns past 180 degrees.
  FTargetYaw := FCamYaw;
  YawDelta := FTargetYaw - FYaw;
  while YawDelta > PI do
    YawDelta := YawDelta - 2 * PI;
  while YawDelta < -PI do
    YawDelta := YawDelta + 2 * PI;
  YawStep := EnsureRange(YawDelta * 8.0 * DeltaTime, -Abs(YawDelta), Abs(YawDelta));
  FYaw := FYaw + YawStep;
  // Apply a torque impulse around the Y axis to nudge the body towards the
  // target yaw. Jolt will integrate this into the angular velocity.
  TorqueAxis := Vector3Create(0, YawStep * FTorqueForce, 0);
  FAvatar.AddForce(TorqueAxis); // AddForce on Y acts as a torque around Y when offset - kept simple here.
  // --- Jump: only when grounded ---
  if ((FInputAction1) or ((GetAsyncKeyState(VK_SPACE) and $8000) <> 0)) and FIsGrounded then
  begin
    FAvatar.ApplyImpulse(Vector3Create(0, FJumpImpulse, 0));
    FAvatar.ActivateBody;
  end;
  // Re-activate the body if the player is providing input so it does not
  // fall asleep mid-motion (Jolt puts bodies to sleep to save CPU).
  if (Abs(FInputForward) > 0.01) or (Abs(FInputRight) > 0.01) then
    FAvatar.ActivateBody;
  // Rotate the avatar body to face the velocity direction.
  FaceMovementDirection(CurrentVel, DeltaTime);
  // Footstep audio trigger.
  UpdateFootstepAudio(DeltaTime);
  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniRigidBodyController.UpdateCameraTransform(dt: Single);
var
  Pos, Target, Up: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  // Same orbit math as the third person controller - kept consistent so
  // players can switch controllers without the camera jumping.
  Target := Vector3Create(FAvatar.Position.x, FAvatar.Position.y + 2.0, FAvatar.Position.z);
  Pos := Vector3Create(FAvatar.Position.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FAvatar.Position.y + Sin(FCamPitch) * FCamDist, FAvatar.Position.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
  Up := Vector3Create(0, 1, 0);
  WriteCameraTransform(Pos, Target, Up, dt);
end;
// ==========================================================================
// Standalone factory + multi-player manager implementation
// ==========================================================================

function YutaniCreateAvatarController(Avatar: TA3DComponent; AType: TYutaniAvatarControllerType; ACamera: PCamera3D): TYutaniAvatarController;
begin
  case AType of
    actVehicle:
      Result := TYutaniVehicleController.Create(Avatar, ACamera);
    actThirdPerson:
      Result := TYutaniThirdPersonController.Create(Avatar, ACamera);
    actFirstPerson:
      Result := TYutaniFirstPersonController.Create(Avatar, ACamera);
    actFlight:
      Result := TYutaniFlightController.Create(Avatar, ACamera);
    actSpectator:
      Result := TYutaniSpectatorController.Create(Avatar, ACamera);
    actOrbit:
      Result := TYutaniOrbitController.Create(Avatar, ACamera);
    actRigidBody:
      Result := TYutaniRigidBodyController.Create(Avatar, ACamera);
  else
    Result := TYutaniVehicleController.Create(Avatar, ACamera);
  end;
end;
{ TYutaniPlayerSlot }

constructor TYutaniPlayerSlot.Create;
begin
  inherited Create;
  FAvatar := nil;
  FController := nil;
  FOwnsController := False;
  FPadID := -1;
  FActive := False;
end;

destructor TYutaniPlayerSlot.Destroy;
begin
  Teardown;
  inherited;
end;

procedure TYutaniPlayerSlot.Setup(AAvatar: TA3DComponent; AControllerType: TYutaniAvatarControllerType; APadID: Integer; ACamera: PCamera3D);
begin
  // Tear down any previous setup so calling Setup repeatedly does not
  // leak controller instances or orphan the previous avatar.
  Teardown;
  FAvatar := AAvatar;
  FPadID := APadID;
  if Assigned(FAvatar) and Assigned(ACamera) then
  begin
    FController := YutaniCreateAvatarController(FAvatar, AControllerType, ACamera);
    FOwnsController := True;
    FActive := True;
  end;
end;

procedure TYutaniPlayerSlot.Teardown;
begin
  if FOwnsController and Assigned(FController) then
  begin
    // Reset gravity on the avatar so the engine physics take over again
    // when the player is no longer driving. Otherwise the avatar would
    // float forever if the slot was driving a zero-gravity controller
    // (Flight / Spectator / Vehicle).
    if Assigned(FController.Avatar) and (FController.Avatar.FBodyID <> 0) then
      FController.Avatar.SetGravityFactor(1.0);
    FreeAndNil(FController);
  end;
  FAvatar := nil;
  FPadID := -1;
  FOwnsController := False;
  FActive := False;
end;

procedure TYutaniPlayerSlot.Update(dt: Single; InputManager: TYutaniInputManager);
var
  FwdIn, RIn, UIn, LXIn, LYIn: Single;
  A1In, A2In: Boolean;
begin
  if (not FActive) or (not Assigned(FController)) or (not Assigned(InputManager)) then
    Exit;
  // Pull isolated state for this slot's pad. The controller will then
  // proceed to use the standard HandleKeyboardInput path too, but that
  // only writes FInputForward / FInputRight for keyboard - on slots
  // other than 0 the gamepad sticks are the primary input source.
  InputManager.GetInputsForPad(FPadID, FwdIn, RIn, UIn, LXIn, LYIn, A1In, A2In);
  // Push the per-pad values into the controller's input fields directly.
  // The controllers already read FInputForward etc. internally so we
  // bypass the standard GetInputs call entirely here.
  FController.FInputForward := FwdIn;
  FController.FInputRight := RIn;
  FController.FInputUp := UIn;
  FController.FInputLookX := LXIn;
  FController.FInputLookY := LYIn;
  FController.FInputAction1 := A1In;
  FController.FInputAction2 := A2In;
  // Let the controller do its thing (physics, camera, audio).
  FController.Update(dt, InputManager);
end;
{ TYutaniMultiPlayerManager }

constructor TYutaniMultiPlayerManager.Create;
begin
  inherited Create;
  FSlots[0] := TYutaniPlayerSlot.Create;
  FSlots[1] := TYutaniPlayerSlot.Create;
  FActive := False;
end;

destructor TYutaniMultiPlayerManager.Destroy;
begin
  DisableSplitScreen;
  FreeAndNil(FSlots[0]);
  FreeAndNil(FSlots[1]);
  inherited;
end;

procedure TYutaniMultiPlayerManager.EnableSplitScreen(Avatar1, Avatar2: TA3DComponent; Camera1, Camera2: PCamera3D; ControllerType1: TYutaniAvatarControllerType = actThirdPerson; ControllerType2: TYutaniAvatarControllerType = actThirdPerson);
begin
  // Clean up any previous session so the new setup starts fresh.
  DisableSplitScreen;
  // Slot 0 = keyboard/mouse player (PadID 0 is the keyboard+mouse slot
  // in the InputManager). Slot 1 = gamepad 1.
  FSlots[0].Setup(Avatar1, ControllerType1, 0, Camera1);
  FSlots[1].Setup(Avatar2, ControllerType2, 1, Camera2);
  FActive := True;
end;

procedure TYutaniMultiPlayerManager.DisableSplitScreen;
begin
  if not FActive then
    Exit;
  FSlots[0].Teardown;
  FSlots[1].Teardown;
  FActive := False;
end;

procedure TYutaniMultiPlayerManager.Update(dt: Single; InputManager: TYutaniInputManager);
begin
  if not FActive then
    Exit;
  // Update both slots. They share the same InputManager but each reads
  // from a different PadID, so there is no cross-talk between players.
  FSlots[0].Update(dt, InputManager);
  FSlots[1].Update(dt, InputManager);
end;

function TYutaniMultiPlayerManager.GetSlot(Index: Integer): TYutaniPlayerSlot;
begin
  if (Index < 0) or (Index > 1) then
    Result := nil
  else
    Result := FSlots[Index];
end;

end.

