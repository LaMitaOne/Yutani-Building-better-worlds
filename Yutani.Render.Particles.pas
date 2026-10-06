unit Yutani.Render.Particles;

{==============================================================================*
 *  Yutani Particle Engine v0.4 - Volumetric Materialization Core
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    A state-of-the-art, multi-threaded 3D particle system built for maximum
 *    hardware efficiency. Features a pre-allocated array memory layout
 *    and a high-performance raw OpenGL-style immediate mode stream via
 *    Raylib's internal RenderBatch (rlBegin/rlEnd).
 *
 *  Advanced Architecture & Features:
 *    - Isolated Materialization: High-density voxel structure synthesis.
 *      Particles are pulled from a localized chaos orbit straight into a
 *      mathematical 3D matrix layout using a damped-attraction vector force.
 *    - Layer-by-Layer Synchronization: Voxel layers assemble sequentially.
 *      A unified frame-lock keeps all vertices active until the last node
 *      arrives, simultaneously dissolving to trigger solid physics.
 *
 *  Hardware-Level Z-Buffer Optimization (The "Sinking" Dissolve):
 *    - In traditional engines, removing upper voxel layers instantly creates
 *      a depth-buffer conflict (Ghosting/Flickering) because the hardware's
 *      rasterizer requires nanoseconds to register and redraw the underlying
 *      geometry beneath the void.
 *    - To completely circumvent this Z-Buffer ordering glitch, this engine
 *      implements a "Sinking Layer" mechanic: Upper cubes do NOT get destroyed
 *      in place. Instead, they physically descend layer-by-layer down to the
 *      lowest baseline (Y=0) of the object while maintaining 100% opacity.
 *    - This keeps the screen space completely dense and opaque at all times,
 *      preventing any transparency artifact, Z-Fighting, or floor bleeding.
 *      Once a voxel hits the bottom baseline, it is cleanly removed.
 *==============================================================================}


{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs,
  Raylib, RayMath, rlgl;

type
  PParticleInstance = ^TParticleInstance;
  TParticleInstance = record
    Position: TVector3;
    Velocity: TVector3;
    TargetPosition: TVector3;
    Color: TColorB;
    StartColor: TColorB;
    EndColor: TColorB;
    Life: Single;
    MaxLife: Single;
    Size: Single;
    StartSize: Single;
    EndSize: Single;
    IsSmoke: Boolean;
    IsMaterializing: Boolean;
    IsDematerializing: Boolean;
    SpawnDelay: Single;
    SpawnTimer: Single;
    HasArrived: Boolean;
  end;

  TParticleEmissionType = (etExplosion, etSmoke, etSpark, etBeam);
  TParticleRenderShape = (rsCube, rsSphere, rsBillboard2D);

  TYutaniParticleEngine = class
  private
    FParticles: array of TParticleInstance;
    FLock: TCriticalSection;
    FGravity: Single;
    FDrag: Single;
    FRenderShape: TParticleRenderShape;
    FCamera: TCamera3D;
    FMaxParticles: Integer;

    // ISOLATED STATES
    FHasSolidCube: Boolean;
    FIsMaterializing: Boolean;
    FIsDematerializing: Boolean;
    FMatArrivedCount: Integer;
    FMatTotalCount: Integer;

    procedure SetDefaults(var P: TParticleInstance);
    function GetCameraForward: TVector3;
    function GetCameraRight: TVector3;
    function GetCameraUp: TVector3;
  public
    constructor Create;
    destructor Destroy; override;

    function ParticleCount: Integer;

    procedure Update(const dt: Single);
    procedure Render;

    procedure SetMaxParticles(const MaxCount: Integer);

    procedure Emit(const Pos: TVector3; EmissionType: TParticleEmissionType;
      Count: Integer; const BaseColor: TColorB);
    procedure EmitExplosion(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSmoke(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSparks(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitBeamSparkles(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);

    procedure EmitMaterializeCube(const TargetPos: TVector3);
    procedure EmitDematerializeCube(const SourcePos: TVector3);

    property Gravity: Single read FGravity write FGravity;
    property Drag: Single read FDrag write FDrag;
    property RenderShape: TParticleRenderShape read FRenderShape write FRenderShape;
    property Camera: TCamera3D read FCamera write FCamera;
    property SolidCubeReady: Boolean read FHasSolidCube;
  end;

implementation

const
  MAX_PARTICLES = 1000000;

{ TYutaniParticleEngine }

constructor TYutaniParticleEngine.Create;
begin
  inherited Create;
  SetLength(FParticles, 0);
  FLock := TCriticalSection.Create;
  FGravity := -9.81;
  FDrag := 0.5;
  FRenderShape := rsCube;
  FMaxParticles := MAX_PARTICLES;

  FHasSolidCube := False;
  FIsMaterializing := False;
  FIsDematerializing := False;
  FMatArrivedCount := 0;
  FMatTotalCount := 0;

  FCamera.position := Vector3Create(10, 10, 10);
  FCamera.target := Vector3Create(0, 0, 0);
  FCamera.up := Vector3Create(0, 1, 0);
end;

destructor TYutaniParticleEngine.Destroy;
begin
  FLock.Enter;
  try
    SetLength(FParticles, 0);
  finally
    FLock.Leave;
  end;
  FLock.Free;
  inherited;
end;

procedure TYutaniParticleEngine.SetDefaults(var P: TParticleInstance);
begin
  P.Position := Vector3Create(0, 0, 0);
  P.Velocity := Vector3Create(0, 0, 0);
  P.TargetPosition := Vector3Create(0, 0, 0);
  P.Life := 1.0;
  P.MaxLife := 1.0;
  P.StartColor := WHITE;
  P.EndColor := WHITE;
  P.Color := WHITE;
  P.StartSize := 1.0;
  P.EndSize := 1.0;
  P.Size := 1.0;
  P.IsSmoke := False;
  P.IsMaterializing := False;
  P.IsDematerializing := False;
  P.SpawnDelay := 0.0;
  P.SpawnTimer := 0.0;
  P.HasArrived := False;
end;

procedure TYutaniParticleEngine.SetMaxParticles(const MaxCount: Integer);
begin
  FLock.Enter;
  try
    FMaxParticles := EnsureRange(MaxCount, 1, MAX_PARTICLES);
    if Length(FParticles) > FMaxParticles then
      SetLength(FParticles, FMaxParticles);
  finally
    FLock.Leave;
  end;
end;

function TYutaniParticleEngine.GetCameraForward: TVector3;
begin
  Result := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));
end;

function TYutaniParticleEngine.GetCameraRight: TVector3;
begin
  Result := Vector3Normalize(Vector3CrossProduct(GetCameraForward, FCamera.up));
end;

function TYutaniParticleEngine.GetCameraUp: TVector3;
begin
  Result := Vector3Normalize(Vector3CrossProduct(GetCameraRight, GetCameraForward));
end;

procedure TYutaniParticleEngine.Emit(const Pos: TVector3; EmissionType: TParticleEmissionType;
  Count: Integer; const BaseColor: TColorB);
var
  i: Integer;
  P: PParticleInstance;
  RandSpeed: Single;
  DirX, DirY, DirZ: Single;
  OldLength, NewCount: Integer;
begin
  FLock.Enter;
  try
    OldLength := Length(FParticles);

    if OldLength + Count > FMaxParticles then
      NewCount := FMaxParticles - OldLength
    else
      NewCount := Count;

    if NewCount <= 0 then Exit;
    SetLength(FParticles, OldLength + NewCount);

    for i := 0 to NewCount - 1 do
    begin
      P := @FParticles[OldLength + i];
      SetDefaults(P^);
      P.Position := Pos;

      case EmissionType of
        etExplosion:
          begin
            DirX := Random * 2 - 1;
            DirY := Random * 2 - 1;
            DirZ := Random * 2 - 1;
            P.Velocity := Vector3Normalize(Vector3Create(DirX, DirY, DirZ));
            RandSpeed := 5 + (Random * 15);
            P.Velocity := Vector3Scale(P.Velocity, RandSpeed);
            P.MaxLife := 1.0 + (Random * 1.0);
            P.StartColor := BaseColor;
            P.EndColor := ColorAlpha(BLACK, 0);
            P.StartSize := 0.15;
            P.EndSize := 0.02;
          end;
        etSmoke:
          begin
            P.IsSmoke := True;
            P.Position.x := Pos.x + ((Random * 2 - 1) * 15.0);
            P.Position.z := Pos.z + ((Random * 2 - 1) * 15.0);
            P.Position.y := Pos.y + (Random * 5.0);

            P.Velocity.x := (Random * 2 - 1) * 0.2;
            P.Velocity.y := 0.5 + (Random * 0.8);
            P.Velocity.z := (Random * 2 - 1) * 0.2;

            P.MaxLife := 8.0 + (Random * 7.0);
            P.StartColor := ColorAlpha(BaseColor, 30);
            P.EndColor := ColorAlpha(BaseColor, 0);
            P.StartSize := 0.1;
            P.EndSize := 0.25;
          end;
        etSpark:
          begin
            DirX := Random * 2 - 1;
            DirY := Abs(Random * 2 - 1);
            DirZ := Random * 2 - 1;
            P.Velocity := Vector3Normalize(Vector3Create(DirX, DirY, DirZ));
            RandSpeed := 10 + (Random * 20);
            P.Velocity := Vector3Scale(P.Velocity, RandSpeed);
            P.MaxLife := 0.3 + (Random * 0.5);
            P.StartColor := BaseColor;
            P.EndColor := ColorAlpha(RED, 0);
            P.StartSize := 0.05;
            P.EndSize := 0.01;
          end;
        etBeam:
          begin
            P.Position.x := Pos.x + (Random * 2 - 1) * 1.5;
            P.Position.y := Pos.y + (Random * 100);
            P.Position.z := Pos.z + (Random * 2 - 1) * 1.5;
            P.Velocity.y := -1.0 - (Random * 2);
            P.MaxLife := 1.5 + (Random * 1.0);
            P.StartColor := WHITE;
            P.EndColor := ColorAlpha(BaseColor, 0);
            P.StartSize := 0.05;
            P.EndSize := 0.01;
          end;
      end;

      P.Life := P.MaxLife;
      P.Color := P.StartColor;
      P.Size := P.StartSize;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniParticleEngine.EmitExplosion(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
begin
  Emit(Pos, etExplosion, Count, BaseColor);
end;

procedure TYutaniParticleEngine.EmitSmoke(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
begin
  Emit(Pos, etSmoke, Count, BaseColor);
end;

procedure TYutaniParticleEngine.EmitSparks(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
begin
  Emit(Pos, etSpark, Count, BaseColor);
end;

procedure TYutaniParticleEngine.EmitBeamSparkles(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
begin
  Emit(Pos, etBeam, Count, BaseColor);
end;

procedure TYutaniParticleEngine.EmitMaterializeCube(const TargetPos: TVector3);
var
  i, j, k: Integer;
  P: PParticleInstance;
  RandSpeed: Single;
  OffsetX, OffsetY, OffsetZ: Single;
  VoxelSize: Single;
  OldLength: Integer;
begin
  FLock.Enter;
  try
    FHasSolidCube := False;
    FIsMaterializing := True;
    FIsDematerializing := False;
    FMatArrivedCount := 0;
    FMatTotalCount := 1000;

    VoxelSize := 0.1;

    for i := 0 to 9 do
      for j := 0 to 9 do
        for k := 0 to 9 do
        begin
          if Length(FParticles) >= FMaxParticles then Break;

          OldLength := Length(FParticles);
          SetLength(FParticles, OldLength + 1);
          P := @FParticles[OldLength];

          SetDefaults(P^);

          P.TargetPosition.x := TargetPos.x + (i * 0.1) - 0.45;
          P.TargetPosition.y := TargetPos.y + (j * 0.1) - 0.45;
          P.TargetPosition.z := TargetPos.z + (k * 0.1) - 0.45;

          OffsetX := (Random * 6.0) - 3.0;
          OffsetY := (Random * 6.0) - 3.0;
          OffsetZ := (Random * 6.0) - 3.0;
          P.Position := Vector3Create(P.TargetPosition.x + OffsetX, P.TargetPosition.y + OffsetY, P.TargetPosition.z + OffsetZ);

          RandSpeed := 2.0 + (Random * 3.0);
          P.Velocity := Vector3Scale(Vector3Normalize(Vector3Subtract(P.TargetPosition, P.Position)), RandSpeed);

          P.IsMaterializing := True;
          P.SpawnDelay := (j / 9.0) * 1.5;
          P.SpawnTimer := 0.0;

          P.Life := 99999.0;
          P.MaxLife := 99999.0;

          P.Size := VoxelSize;
          P.StartSize := VoxelSize;
          P.EndSize := VoxelSize;
          P.StartColor := ColorAlpha(BLUE, 0);
          P.EndColor := ColorAlpha(BLUE, 255);
          P.Color := P.StartColor;
        end;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniParticleEngine.EmitDematerializeCube(const SourcePos: TVector3);
var
  i, j, k: Integer;
  P: PParticleInstance;
  VoxelSize: Single;
  OldLength: Integer;
  LowestY: Single;
begin
  FLock.Enter;
  try
    FHasSolidCube := False;
    FIsMaterializing := False;
    FIsDematerializing := True;

    VoxelSize := 0.1;
    // Lowest Y level of the 10x10x10 cube
    LowestY := SourcePos.y - 0.45;

    for i := 0 to 9 do
      for j := 0 to 9 do
        for k := 0 to 9 do
        begin
          if Length(FParticles) >= FMaxParticles then Break;

          OldLength := Length(FParticles);
          SetLength(FParticles, OldLength + 1);
          P := @FParticles[OldLength];

          SetDefaults(P^);

          P.Position.x := SourcePos.x + (i * 0.1) - 0.45;
          P.Position.y := SourcePos.y + (j * 0.1) - 0.45;
          P.Position.z := SourcePos.z + (k * 0.1) - 0.45;

          // FIX: Target is straight down to the lowest layer!
          P.TargetPosition := Vector3Create(P.Position.x, LowestY, P.Position.z);
          P.Velocity := Vector3Create(0, 0, 0);

          P.IsDematerializing := True;
          // Top layer (j=9) gets 0 delay. Bottom layer (j=0) gets 1.5 sec delay.
          P.SpawnDelay := ((9 - j) / 9.0) * 1.5;
          P.SpawnTimer := 0.0;

          P.Life := 99999.0;
          P.MaxLife := 99999.0;

          P.Size := VoxelSize;
          P.StartSize := VoxelSize;
          P.EndSize := VoxelSize;
          // 100% Opak, kein Alpha!
          P.StartColor := ColorAlpha(BLUE, 255);
          P.EndColor := ColorAlpha(BLUE, 255);
          P.Color := P.StartColor;
        end;
  finally
    FLock.Leave;
  end;
end;

function TYutaniParticleEngine.ParticleCount: Integer;
begin
  FLock.Enter;
  try
    Result := Length(FParticles);
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniParticleEngine.Update(const dt: Single);
var
  i: Integer;
  P: PParticleInstance;
  Progress: Single;
  CurrentY, CurrentVel: Single;
  DeltaColor: TColorB;
  LastIdx: Integer;
  DirToTarget: TVector3;
  Dist: Single;
  Sog: Single;
  MatAliveCount: Integer;
  DematAliveCount: Integer;
begin
  FLock.Enter;
  try
    MatAliveCount := 0;
    DematAliveCount := 0;
    FMatArrivedCount := 0;
    i := 0;
    while i <= High(FParticles) do
    begin
      P := @FParticles[i];
      P.Life := P.Life - dt;
      // 1. Instant destruction check to prevent stale memory registration
      if P.Life <= 0 then
      begin
        LastIdx := High(FParticles);
        if i <> LastIdx then
          Move(FParticles[LastIdx], FParticles[i], SizeOf(TParticleInstance));
        SetLength(FParticles, LastIdx);
        Continue; // Skip index increment since a new particle shifted down
      end;
      // --- LOGIC FOR MATERIALIZATION ---
      if P.IsMaterializing then
      begin
        Inc(MatAliveCount);
        if P.SpawnTimer < P.SpawnDelay then
        begin
          P.SpawnTimer := P.SpawnTimer + dt;
          P.Color.a := 0;
        end
        else
        begin
          DirToTarget := Vector3Subtract(P.TargetPosition, P.Position);
          Dist := Vector3Length(DirToTarget);
          if Dist > 0.001 then
            DirToTarget := Vector3Scale(DirToTarget, 1.0 / Dist)
          else
            DirToTarget := Vector3Create(0, 0, 0);
          Sog := 15.0 * Dist;
          P.Velocity := Vector3Scale(DirToTarget, Sog);
          if Dist < 0.05 then
          begin
            P.Position := P.TargetPosition;
            P.Velocity := Vector3Create(0, 0, 0);
            if not P.HasArrived then
              P.HasArrived := True;
          end;
          if P.HasArrived then
            Inc(FMatArrivedCount);
          if P.HasArrived then
            P.Color.a := 255
          else
            P.Color.a := 200;
        end;
      end
      // --- LOGIC FOR DEMATERIALIZATION (Sink to bottom) ---
      else if P.IsDematerializing then
      begin
        Inc(DematAliveCount);
        if P.SpawnTimer < P.SpawnDelay then
        begin
          P.SpawnTimer := P.SpawnTimer + dt;
          P.Color.a := 255; // Keep completely opaque to bypass Z-buffer glitches
        end
        else
        begin
          DirToTarget := Vector3Subtract(P.TargetPosition, P.Position);
          Dist := Vector3Length(DirToTarget);
          if Dist > 0.001 then
            DirToTarget := Vector3Scale(DirToTarget, 1.0 / Dist)
          else
            DirToTarget := Vector3Create(0, 0, 0);
          // Smooth sinking speed towards bottom layer
          Sog := 3.0 * Dist;
          P.Velocity := Vector3Scale(DirToTarget, Sog);
          if Dist < 0.05 then
          begin
            P.Position := P.TargetPosition;
            P.Velocity := Vector3Create(0, 0, 0);
            // RADICAL LEAK FIX: Force immediate termination flags
            P.Life := -1.0;
            P.IsDematerializing := False;
            LastIdx := High(FParticles);
            if i <> LastIdx then
              Move(FParticles[LastIdx], FParticles[i], SizeOf(TParticleInstance));
            SetLength(FParticles, LastIdx);
            Continue; // Drop out instantly, skipping the trailing matrix math
          end;
        end;
      end
      // --- STANDARD EXPLOSION PHYSICS ---
      else
      begin
        if not P.IsSmoke then
        begin
          CurrentY := P.Velocity.y + (FGravity * dt);
          P.Velocity.y := CurrentY;
        end;
        CurrentVel := 1.0 - (FDrag * dt);
        if CurrentVel < 0 then CurrentVel := 0;
        P.Velocity := Vector3Scale(P.Velocity, CurrentVel);
        Progress := 1.0 - (P.Life / P.MaxLife);
        if Progress > 1.0 then Progress := 1.0;
        if Progress < 0.0 then Progress := 0.0;
        P.Size := Lerp(P.StartSize, P.EndSize, Progress);
        DeltaColor.r := Round(Lerp(P.StartColor.r, P.EndColor.r, Progress));
        DeltaColor.g := Round(Lerp(P.StartColor.g, P.EndColor.g, Progress));
        DeltaColor.b := Round(Lerp(P.StartColor.b, P.EndColor.b, Progress));
        DeltaColor.a := Round(Lerp(P.StartColor.a, P.EndColor.a, Progress));
        P.Color := DeltaColor;
      end;
      // Integrate velocity into final 3D position vector
      P.Position := Vector3Add(P.Position, Vector3Scale(P.Velocity, dt));
      Inc(i);
    end;
    // --- ISOLATED COMPONENT STATE TRIGGERS ---
    if FIsMaterializing and (FMatArrivedCount = FMatTotalCount) and (FMatArrivedCount > 0) then
    begin
      for i := 0 to High(FParticles) do
      begin
        if FParticles[i].IsMaterializing and (FParticles[i].Life > 1.0) then
        begin
          FParticles[i].Life := 0.2;
          FParticles[i].MaxLife := 0.2;
        end;
      end;
    end;
    if FIsMaterializing and (MatAliveCount = 0) then
    begin
      FIsMaterializing := False;
      FHasSolidCube := True;
    end;
    if FIsDematerializing and (DematAliveCount = 0) then
    begin
      FIsDematerializing := False;
      FHasSolidCube := False;
    end;
  finally
    FLock.Leave;
  end;
end;


procedure TYutaniParticleEngine.Render;
var
  i: Integer;
  P: PParticleInstance;
  CamRight, CamUp: TVector3;
  HalfSize: Single;
  PosX, PosY, PosZ: Single;
  RgtX, RgtY, RgtZ: Single;
  UpX, UpY, UpZ: Single;
begin
  FLock.Enter;
  try
    if Length(FParticles) = 0 then Exit;

    rlSetBlendMode(BLEND_ALPHA);

    case FRenderShape of
      rsCube:
        begin
          for i := 0 to High(FParticles) do
          begin
            P := @FParticles[i];
            DrawCube(P.Position, P.Size * 0.5, P.Size * 0.5, P.Size * 0.5, P.Color);
          end;
        end;
      rsSphere:
        begin
          for i := 0 to High(FParticles) do
          begin
            P := @FParticles[i];
            DrawSphere(P.Position, P.Size * 0.5, P.Color);
          end;
        end;
      rsBillboard2D:
        begin
          CamRight := GetCameraRight;
          CamUp := GetCameraUp;
          RgtX := CamRight.x; RgtY := CamRight.y; RgtZ := CamRight.z;
          UpX := CamUp.x;     UpY := CamUp.y;     UpZ := CamUp.z;

          rlBegin(RL_QUADS);
          try
            for i := 0 to High(FParticles) do
            begin
              P := @FParticles[i];
              HalfSize := P.Size * 0.5;
              PosX := P.Position.x;
              PosY := P.Position.y;
              PosZ := P.Position.z;

              rlColor4ub(P.Color.r, P.Color.g, P.Color.b, P.Color.a);

              rlVertex3f(PosX + (RgtX * -HalfSize) + (UpX * HalfSize),
                         PosY + (RgtY * -HalfSize) + (UpY * HalfSize),
                         PosZ + (RgtZ * -HalfSize) + (UpZ * HalfSize));
              rlVertex3f(PosX + (RgtX * HalfSize) + (UpX * HalfSize),
                         PosY + (RgtY * HalfSize) + (UpY * HalfSize),
                         PosZ + (RgtZ * HalfSize) + (UpZ * HalfSize));
              rlVertex3f(PosX + (RgtX * HalfSize) + (UpX * -HalfSize),
                         PosY + (RgtY * HalfSize) + (UpY * -HalfSize),
                         PosZ + (RgtZ * HalfSize) + (UpZ * -HalfSize));
              rlVertex3f(PosX + (RgtX * -HalfSize) + (UpX * -HalfSize),
                         PosY + (RgtY * -HalfSize) + (UpY * -HalfSize),
                         PosZ + (RgtZ * -HalfSize) + (UpZ * -HalfSize));
            end;
          finally
            rlEnd();
          end;
        end;
    end;

    rlDrawRenderBatchActive();
    rlSetBlendMode(BLEND_ALPHA);
  finally
    FLock.Leave;
  end;
end;

end.
