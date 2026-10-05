unit Yutani.AliveHighlighter3D;

{*******************************************************************************
  Yutani.AliveHighlighter3D
  part of Yutani RaylibSandbox
  written by: Lara Miriam Tamy Reschke / LamitaOne
  Description:
  A dynamic, organic 3D ghost entity for the Raylib Sandbox.
  Uses kinematic math for perfectly smooth, predictable orbits.
  Features a dark, semi-transparent base with glowing Sci-Fi Teal/Aqua energy
  lines trailing behind it.
*******************************************************************************}
interface

uses
  System.SysUtils, System.Math, Raylib, RayMath, rlgl;

type
  TSnakeState3D = (ssIdle, ssApproaching, ssOrbiting);

  TAliveHighlighter3D = class
  private
    FState: TSnakeState3D;
    FHeadPos: TVector3;
    FTargetPos: TVector3;   // The object it orbits
    FMousePos: TVector3;    // The cursor it follows
    FHasTarget: Boolean;    // Does it have a fixed object to orbit?
    { The Trail }
    FTrail: array of TVector3;
    FMaxHistory: Integer;
    { Kinematic Math Variables }
    FOrbitAngle: Single;
    FOrbitVerticalPhase: Single;
    FOrbitSpeed: Single;
    { Appearance & Animation }
    FPhase: Single;
    FThickness: Single;
    FBaseColor: TColorB;  // Dark ghostly body
    FEnergyColor: TColorB; // Bright Sci-Fi Teal/Aqua
    FActive: Boolean;
    procedure UpdatePhysics(DeltaTime: Single);
  public
    constructor Create;
    procedure Update(DeltaTime: Single; const MouseWorldPos: TVector3);
    procedure Draw;
    { Sends the entity to a specific 3D target position }
    procedure SendToTarget(const TargetPos: TVector3);
    { Sets the initial spawn position to prevent trail drawing from 0,0,0 }
    procedure SetStartPosition(const Pos: TVector3);
    property Active: Boolean read FActive write FActive;
  end;

implementation
{ TAliveHighlighter3D }

constructor TAliveHighlighter3D.Create;
var
  I: Integer;
begin
  inherited Create;
  // Initialize Default State
  FState := ssApproaching;
  FActive := True;
  FHasTarget := False;
  // Initialize position to a default safe location
  FHeadPos := Vector3Create(0, 10, 0);
  FTargetPos := FHeadPos;
  FMousePos := FHeadPos;
  // Kinematic Math Init
  FOrbitAngle := 0;
  FOrbitVerticalPhase := 0;
  FOrbitSpeed := 1.5; // Smooth, gentle speed
  // Initialize Trail to the head position
  FMaxHistory := 40; // Slightly longer trail for better lines
  SetLength(FTrail, FMaxHistory);
  for I := 0 to FMaxHistory - 1 do
    FTrail[I] := FHeadPos;
  // Default Visuals
  FPhase := 0;
  FThickness := 0.5;
  // Very dark, almost black, ghostly body
  FBaseColor.r := 10;
  FBaseColor.g := 35;
  FBaseColor.b := 45;
  FBaseColor.a := 180;
  // Bright Sci-Fi Teal/Aqua for the energy lines
  FEnergyColor.r := 0;
  FEnergyColor.g := 255;
  FEnergyColor.b := 220;
  FEnergyColor.a := 255;
end;

procedure TAliveHighlighter3D.SetStartPosition(const Pos: TVector3);
var
  I: Integer;
begin
  FHeadPos := Pos;
  FTargetPos := Pos;
  for I := 0 to FMaxHistory - 1 do
    FTrail[I] := Pos;
end;

procedure TAliveHighlighter3D.SendToTarget(const TargetPos: TVector3);
begin
  // Set the target object to orbit
  FTargetPos := TargetPos;
  FTargetPos.y := TargetPos.y + 2.0; // Lift slightly
  FHasTarget := True;
  FState := ssApproaching;
  FActive := True;
end;

procedure TAliveHighlighter3D.Update(DeltaTime: Single; const MouseWorldPos: TVector3);
begin
  if not FActive then
    Exit;
  FMousePos := MouseWorldPos;
  // If it has a fixed target, keep it. Otherwise follow the mouse.
  if not FHasTarget then
    FTargetPos := FMousePos;
  UpdatePhysics(DeltaTime);
end;

procedure TAliveHighlighter3D.UpdatePhysics(DeltaTime: Single);
var
  DirToTarget: TVector3;
  DistToTarget: Single;
  DesiredPos: TVector3;
  BobY: Single;
begin
  DirToTarget := Vector3Subtract(FTargetPos, FHeadPos);
  DistToTarget := Vector3Length(DirToTarget);
  if DistToTarget > 0.1 then
    DirToTarget := Vector3Scale(DirToTarget, 1.0 / DistToTarget)
  else
    DirToTarget := Vector3Zero;
  // ==========================================================
  // KINEMATIC MOVEMENT (Perfectly smooth, no physics forces)
  // ==========================================================
  case FState of
    ssApproaching:
      begin
        // Glide directly towards the target
        if DistToTarget > 3.0 then
          FHeadPos := Vector3Add(FHeadPos, Vector3Scale(DirToTarget, FOrbitSpeed * DeltaTime))
        else
          FState := ssOrbiting; // Reached destination, start orbiting
      end;
    ssOrbiting:
      begin
        // Calculate perfect circular orbit
        FOrbitAngle := FOrbitAngle + (FOrbitSpeed * DeltaTime);
        FOrbitVerticalPhase := FOrbitVerticalPhase + (DeltaTime * 2.0);
        // Add a slight up/down bobbing for organic feel
        BobY := Sin(FOrbitVerticalPhase) * 0.5;
        DesiredPos.x := FTargetPos.x + Cos(FOrbitAngle) * 3.0; // 3.0 = Orbit Radius
        DesiredPos.y := FTargetPos.y + BobY;
        DesiredPos.z := FTargetPos.z + Sin(FOrbitAngle) * 3.0;
        // Smoothly interpolate to the desired position (Lerp)
        FHeadPos := Vector3Lerp(FHeadPos, DesiredPos, 5.0 * DeltaTime);
      end;
  end;
  // ==========================================================
  // TRAIL MANAGEMENT
  // ==========================================================
  if FMaxHistory > 1 then
    Move(FTrail[0], FTrail[1], (FMaxHistory - 1) * SizeOf(TVector3));
  FTrail[0] := FHeadPos;
  // Animation ticker for organic sway
  FPhase := FPhase + (0.1 * DeltaTime * 60.0);
end;

procedure TAliveHighlighter3D.Draw;
var
  I: Integer;
  P1, P2: TVector3;
  DrawPos: TVector3;
  SwayX, SwayZ: Single;
  BodyColor: TColorB;
  LineColor: TColorB;
  AlphaRatio: Single;
begin
  if not FActive then
    Exit;
  // CRITICAL: Enable Alpha Blending so the ghost body is actually see-through!
  rlSetBlendMode(BLEND_ALPHA);
  // ==========================================================
  // DRAW ENTITY BODY (Dark, semi-transparent ghost shell)
  // ==========================================================
  for I := FMaxHistory - 1 downto 1 do
  begin
    P1 := FTrail[I];
    P2 := FTrail[I - 1];
    // Calculate organic Sway offset
    SwayX := Sin(FPhase + (I * 0.2)) * 0.2;
    SwayZ := Cos(FPhase + (I * 0.2)) * 0.2;
    P1.x := P1.x + SwayX;
    P1.z := P1.z + SwayZ;
    // Calculate transparency: fade out towards the tail
    AlphaRatio := I / FMaxHistory;
    BodyColor := FBaseColor;
    BodyColor.a := Round(FBaseColor.a * AlphaRatio);
    // Draw cylinder segment (dark shell) - made it slightly thinner (0.3)
    DrawCylinderEx(P1, P2, 0.3, 0.3, 6, BodyColor);
  end;
  // ==========================================================
  // DRAW SCI-FI ENERGY LINES (Glowing Teal/Aqua)
  // ==========================================================
  // We draw lines connecting every 3rd point to create a jagged energy trail
  for I := 1 to FMaxHistory - 3 do
  begin
    if (I mod 3 = 0) then
    begin
      P1 := FTrail[I];
      P2 := FTrail[I - 3];
      // Apply the same sway so the lines stick to the body
      SwayX := Sin(FPhase + (I * 0.2)) * 0.2;
      SwayZ := Cos(FPhase + (I * 0.2)) * 0.2;
      P1.x := P1.x + SwayX;
      P1.z := P1.z + SwayZ;
      SwayX := Sin(FPhase + ((I - 3) * 0.2)) * 0.2;
      SwayZ := Cos(FPhase + ((I - 3) * 0.2)) * 0.2;
      P2.x := P2.x + SwayX;
      P2.z := P2.z + SwayZ;
      // Fade the energy lines out as well
      AlphaRatio := I / FMaxHistory;
      LineColor := FEnergyColor;
      LineColor.a := Round(255 * AlphaRatio);
      // Draw thicker glowing line so it's visible through the dark shell
      DrawCylinderEx(P1, P2, 0.12, 0.12, 4, LineColor);
    end;
  end;
  // ==========================================================
  // DRAW ENTITY HEAD
  // ==========================================================
  DrawPos := FHeadPos;
  // Draw dark ghostly head (smaller)
  DrawSphere(DrawPos, 0.4, BodyColor);
  // Draw bright energy core inside the head
  DrawSphere(DrawPos, 0.2, FEnergyColor);
  // Restore default blend mode for the rest of the scene
  rlSetBlendMode(BLEND_ALPHA);
end;

end.

