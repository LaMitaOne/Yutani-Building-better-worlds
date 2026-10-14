unit Yutani.Avatar.Controls;

{==============================================================================*
 *  Yutani Avatar Controls & Input Manager v1.1
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
  Vcl.Forms, Raylib, RayMath, JoltPhysics, Yutani.Core.ModelEngine,
  Yutani.Avatar.Controls.GamepadCore, Yutani.Avatar.Controls.GamepadSettings;

type
  /// <summary>
  /// Manages Gamepad input and provides thread-safe access to current states.
  /// </summary>
  TYutaniInputManager = class
  private
    FGamepadCore: TMRXGamepadCore;
    FLock: TCriticalSection;
    FBufForward: Single;
    FBufRight: Single;
    FBufUp: Single;
    FBufLookX: Single;
    FBufLookY: Single;
    FBufAction1: Boolean;
    FBufAction2: Boolean;
    procedure HandleGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
  public
    constructor Create;
    destructor Destroy; override;

    procedure InitializeGamepad;
    procedure ShowGamepadSettings(ParentForm: TForm);
    procedure Rumble(PlayerID: Integer; LowFreq, HighFreq: Word; DurationMS: Cardinal);
    procedure GetInputs(out forward, Right, Up, LookX, LookY: Single; out Action1, Action2: Boolean);

    property Core: TMRXGamepadCore read FGamepadCore;
  end;
  /// <summary>
  /// Base abstract controller for all avatar modes.
  /// </summary>
  TYutaniAvatarController = class abstract
  private
    FAvatar: TA3DComponent;
    FCamera: PCamera3D;
    FCamYaw: Single;
    FCamPitch: Single;
    FCamDist: Single;
    FMoveSpeed: Single;
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
  public
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); virtual;
    destructor Destroy; override;

    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); virtual; abstract;

    property Avatar: TA3DComponent read FAvatar write SetAvatar;
    property Camera: PCamera3D read FCamera write FCamera;
    property CamYaw: Single read FCamYaw write FCamYaw;
    property CamPitch: Single read FCamPitch write FCamPitch;
    property CamDist: Single read FCamDist write FCamDist;
    property MoveSpeed: Single read FMoveSpeed write FMoveSpeed;
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
    constructor Create(AAvatar: TA3DComponent; ACamera: PCamera3D); override;
    procedure Update(DeltaTime: Single; InputManager: TYutaniInputManager); override;
    property MaxSpeed: Single read FMaxSpeed write FMaxSpeed;
    property TurnSpeed: Single read FTurnSpeed write FTurnSpeed;
  end;

implementation
{ TYutaniInputManager }

constructor TYutaniInputManager.Create;
begin
  inherited;
  FLock := TCriticalSection.Create;
  FGamepadCore := TMRXGamepadCore.Create;
  FGamepadCore.OnInputEvent := HandleGamepadInput;
end;

destructor TYutaniInputManager.Destroy;
begin
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
  // Log standard buttons to the debug console
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
    // Log analog axes only if value exceeds threshold to prevent spam
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

  // Thread-safe buffering
  FLock.Acquire;
  try
    case Element of
      geLeftStickY:
        FBufForward := Value;
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
end;

procedure TYutaniThirdPersonController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  fwd, right, vel: TVector3;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;

  FCamYaw := FCamYaw + (FInputLookX * 0.05);
  FCamPitch := EnsureRange(FCamPitch - (FInputLookY * 0.05), 0.1, 1.5);

  fwd := Vector3Create(-Sin(FCamYaw), 0, -Cos(FCamYaw));
  right := Vector3Create(Cos(FCamYaw), 0, -Sin(FCamYaw));

  vel.x := (fwd.x * FInputForward + right.x * FInputRight) * FMoveSpeed;
  vel.z := (fwd.z * FInputForward + right.z * FInputRight) * FMoveSpeed;
  vel.y := FAvatar.GetLinearVelocity.y;

  FAvatar.SetLinearVelocity(vel);

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
begin
  if not Assigned(FCamera) then
    Exit;
  FCamera^.target := FAvatar.Position;
  FCamera^.position := Vector3Create(FAvatar.Position.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FAvatar.Position.y + Sin(FCamPitch) * FCamDist, FAvatar.Position.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
  FCamera^.Up := Vector3Create(0, 1, 0);
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

  // Space/Ctrl for vertical flight
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
  back: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  back := Vector3Create(Cos(FCamPitch) * Sin(FCamYaw + PI), Sin(FCamPitch + PI), Cos(FCamPitch) * Cos(FCamYaw + PI));
  FCamera^.target := FAvatar.Position;
  FCamera^.position := Vector3Add(FAvatar.Position, Vector3Scale(back, FCamDist));
  FCamera^.Up := Vector3Create(0, 1, 0);
end;
{ TYutaniVehicleController }

constructor TYutaniVehicleController.Create(AAvatar: TA3DComponent; ACamera: PCamera3D);
begin
  inherited;
  FMaxSpeed := 50.0;
  FTurnSpeed := 2.0;
  FCurrentSpeed := 0;
  FCamDist := 12.0;
end;

procedure TYutaniVehicleController.Update(DeltaTime: Single; InputManager: TYutaniInputManager);
var
  vel, fwd: TVector3;
  RotQuat: TQuaternion;
begin
  InputManager.GetInputs(FInputForward, FInputRight, FInputUp, FInputLookX, FInputLookY, FInputAction1, FInputAction2);
  HandleKeyboardInput;

  // Q / E: Up / Down Thrust
  if (GetAsyncKeyState(Ord('Q')) and $8000) <> 0 then
    FInputUp := 1.0;
  if (GetAsyncKeyState(Ord('E')) and $8000) <> 0 then
    FInputUp := -1.0;

  // Acceleration / Braking
  if FInputForward > 0 then
    FCurrentSpeed := EnsureRange(FCurrentSpeed + (20 * DeltaTime), 0, FMaxSpeed)
  else if FInputForward < 0 then
    FCurrentSpeed := EnsureRange(FCurrentSpeed - (40 * DeltaTime), -FMaxSpeed * 0.5, FMaxSpeed)
  else
    FCurrentSpeed := FCurrentSpeed * (1.0 - (0.5 * DeltaTime)); // Friction

  // Steering: REVERSED direction! (Matches the previous F11 logic)
  if Abs(FCurrentSpeed) > 0.1 then
    FCamYaw := FCamYaw - (FInputRight * FTurnSpeed * DeltaTime * (FCurrentSpeed / FMaxSpeed));

  fwd := Vector3Create(-Sin(FCamYaw), 0, -Cos(FCamYaw));

  // Hover mode
  FAvatar.SetAngularVelocity(Vector3Create(0, 0, 0));
  FAvatar.SetGravityFactor(0.0);

  vel := Vector3Scale(fwd, FCurrentSpeed);
  vel.y := FInputUp * 10.0; // Apply Up/Down Thrust directly

  FAvatar.SetLinearVelocity(vel);

  // Match avatar rotation to flight direction
  RotQuat := QuaternionFromAxisAngle(Vector3Create(0, 1, 0), FCamYaw);
  FAvatar.SetRotation(RotQuat);

  UpdateCameraTransform(DeltaTime);
end;

procedure TYutaniVehicleController.UpdateCameraTransform(dt: Single);
var
  back: TVector3;
begin
  if not Assigned(FCamera) then
    Exit;
  back := Vector3Create(Sin(FCamYaw), 0, Cos(FCamYaw));
  FCamera^.target := FAvatar.Position;
  FCamera^.position := Vector3Create(FAvatar.Position.x + (back.x * FCamDist), FAvatar.Position.y + 5.0, FAvatar.Position.z + (back.z * FCamDist));
  FCamera^.Up := Vector3Create(0, 1, 0);
end;

end.

