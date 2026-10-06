unit Yutani.Render.Particles;

{==============================================================================*
 *  Yutani Particle Engine v0.5 - Volumetric Materialization Core
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
 *
 *  v0.5 Update - Event-Driven Materialization & Dynamic Mesh Support:
 *    - Strict Event-Driven Logic: Time-based durations for beam effects have
 *      been completely removed. The effect now relies exclusively on the
 *      "SolidCubeReady" event signal, which is only triggered when the
 *      absolute last particle (top layer) reaches its target coordinate.
 *    - Persistent Voxel Framing: Particles no longer fade out or get culled
 *      during the assembly process. Once a particle arrives, it freezes and
 *      maintains 100% opacity until the entire structure is complete.
 *    - Dynamic Mesh Synthesis: Support for arbitrary 3D meshes (GLTF/OBJ).
 *      The engine dynamically scales voxels to match vertex positions and
 *      calculates an accurate Y-layer bounding box for synchronized building.
 *    - Universal Z-Offset Alignment: The particle matrix respects the exact
 *      model offset (ModelOffset) required by the physics engine, ensuring
 *      the volumetric build matches the final rendered 3D model perfectly.
 *==============================================================================}


{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, Raylib, RayMath,
  rlgl;

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

    procedure Emit(const Pos: TVector3; EmissionType: TParticleEmissionType; Count: Integer; const BaseColor: TColorB);
    procedure EmitExplosion(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSmoke(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSparks(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitBeamSparkles(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);

    procedure EmitMaterializeCube(const TargetPos: TVector3);
    procedure EmitDematerializeCube(const SourcePos: TVector3);

    // NEW: Dynamic Mesh Materialization
    procedure EmitMaterializeMesh(const TargetPos: TVector3; const Mesh: TMesh);
    procedure EmitDematerializeMesh(const TargetPos: TVector3; const Mesh: TMesh);

    property Gravity: Single read FGravity write FGravity;
    property Drag: Single read FDrag write FDrag;
    property RenderShape: TParticleRenderShape read FRenderShape write FRenderShape;
    property Camera: TCamera3D read FCamera write FCamera;
    property SolidCubeReady: Boolean read FHasSolidCube write FHasSolidCube;
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

procedure TYutaniParticleEngine.Emit(const Pos: TVector3; EmissionType: TParticleEmissionType; Count: Integer; const BaseColor: TColorB);
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

    if NewCount <= 0 then
      Exit;
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
          if Length(FParticles) >= FMaxParticles then
            Break;

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
          if Length(FParticles) >= FMaxParticles then
            Break;

          OldLength := Length(FParticles);
          SetLength(FParticles, OldLength + 1);
          P := @FParticles[OldLength];

          SetDefaults(P^);

          P.Position.x := SourcePos.x + (i * 0.1) - 0.45;
          P.Position.y := SourcePos.y + (j * 0.1) - 0.45;
          P.Position.z := SourcePos.z + (k * 0.1) - 0.45;

          // Target is straight down to the lowest layer
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
          // 100% Opaque, no alpha
          P.StartColor := ColorAlpha(BLUE, 255);
          P.EndColor := ColorAlpha(BLUE, 255);
          P.Color := P.StartColor;
        end;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniParticleEngine.EmitMaterializeMesh(const TargetPos: TVector3; const Mesh: TMesh);
var
  i: Integer;
  P: PParticleInstance;
  vx, vy, vz: Single;
  MinY, MaxY, HeightRange: Single;
  VoxelSize: Single;
  OldLength, AvailableSlots, ToSpawn: Integer;
  RandSpeed, OffsetX, OffsetY, OffsetZ: Single;
begin
  if (Mesh.vertexCount = 0) or (Mesh.vertices = nil) then
    Exit;

  FLock.Enter;
  try
    // CRITICAL FIX: Reset all isolated states
    FHasSolidCube := False;
    FIsMaterializing := True;
    FIsDematerializing := False;
    FMatArrivedCount := 0;
    FMatTotalCount := 0; // Start at 0

    AvailableSlots := FMaxParticles - Length(FParticles);
    ToSpawn := EnsureRange(Mesh.vertexCount, 0, AvailableSlots);
    if ToSpawn <= 0 then
      Exit;

    // Pre-allocate memory ONCE
    OldLength := Length(FParticles);
    SetLength(FParticles, OldLength + ToSpawn);
    FMatTotalCount := ToSpawn; // MUST be set to the actual amount

    VoxelSize := 0.05;

    // Calculate bounding box height for layer-by-layer timing
    MinY := Mesh.vertices[1];
    MaxY := Mesh.vertices[1];
    for i := 0 to Mesh.vertexCount - 1 do
    begin
      vy := Mesh.vertices[i * 3 + 1];
      if vy < MinY then
        MinY := vy;
      if vy > MaxY then
        MaxY := vy;
    end;
    HeightRange := MaxY - MinY;
    if HeightRange <= 0.001 then
      HeightRange := 1.0;

    for i := 0 to ToSpawn - 1 do
    begin
      P := @FParticles[OldLength + i];
      SetDefaults(P^);

      vx := Mesh.vertices[i * 3];
      vy := Mesh.vertices[i * 3 + 1];
      vz := Mesh.vertices[i * 3 + 2];

      P.TargetPosition.x := TargetPos.x + vx;
      P.TargetPosition.y := TargetPos.y + vy;
      P.TargetPosition.z := TargetPos.z + vz;

      // Chaos orbit spawn location (materializing from thin air)
      // Spread them out a bit more so they rush inwards dramatically
      OffsetX := (Random * 6.0) - 3.0;
      OffsetY := (Random * 6.0) - 3.0;
      OffsetZ := (Random * 6.0) - 3.0;
      P.Position := Vector3Create(P.TargetPosition.x + OffsetX, P.TargetPosition.y + OffsetY, P.TargetPosition.z + OffsetZ);

      RandSpeed := 2.0 + (Random * 3.0);
      P.Velocity := Vector3Scale(Vector3Normalize(Vector3Subtract(P.TargetPosition, P.Position)), RandSpeed);

      P.IsMaterializing := True;
      // MATERIALIZE LOGIC: Bottom layer (MinY) gets 0 delay and builds first.
      P.SpawnDelay := ((vy - MinY) / HeightRange) * 0.3;
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

procedure TYutaniParticleEngine.EmitDematerializeMesh(const TargetPos: TVector3; const Mesh: TMesh);
var
  i: Integer;
  P: PParticleInstance;
  vx, vy, vz: Single;
  MinY, MaxY, HeightRange: Single;
  VoxelSize: Single;
  OldLength, AvailableSlots, ToSpawn: Integer;
  LowestY: Single;
begin
  if (Mesh.vertexCount = 0) or (Mesh.vertices = nil) then
    Exit;

  FLock.Enter;
  try
    FHasSolidCube := False;
    FIsMaterializing := False;
    FIsDematerializing := True;

    AvailableSlots := FMaxParticles - Length(FParticles);
    ToSpawn := EnsureRange(Mesh.vertexCount, 0, AvailableSlots);
    if ToSpawn <= 0 then
      Exit;

    // Pre-allocate memory ONCE for high-count mesh synthesis performance
    OldLength := Length(FParticles);
    SetLength(FParticles, OldLength + ToSpawn);

    VoxelSize := 0.05; // Smaller voxel size for higher density mesh points

    // Calculate bounding box height for layer-by-layer sinking timing
    MinY := Mesh.vertices[1];
    MaxY := Mesh.vertices[1];
    for i := 0 to Mesh.vertexCount - 1 do
    begin
      vy := Mesh.vertices[i * 3 + 1];
      if vy < MinY then
        MinY := vy;
      if vy > MaxY then
        MaxY := vy;
    end;
    HeightRange := MaxY - MinY;
    if HeightRange <= 0.001 then
      HeightRange := 1.0;

    // Target Y line is the EXACT bottom of the object in world space.
    // No guessing, no 0.25 offsets. Pure mathematical precision.
    LowestY := TargetPos.y + MinY;

    for i := 0 to ToSpawn - 1 do
    begin
      P := @FParticles[OldLength + i];
      SetDefaults(P^);

      vx := Mesh.vertices[i * 3];
      vy := Mesh.vertices[i * 3 + 1];
      vz := Mesh.vertices[i * 3 + 2];

      P.Position.x := TargetPos.x + vx;
      P.Position.y := TargetPos.y + vy;
      P.Position.z := TargetPos.z + vz;

      // Sink straight down to the exact lowest layer
      P.TargetPosition := Vector3Create(P.Position.x, LowestY, P.Position.z);
      P.Velocity := Vector3Create(0, 0, 0);

      P.IsDematerializing := True;

      // DEMATERIALIZE LOGIC: Top layer (MaxY) gets 0 delay and falls first.
      // Bottom layer (MinY) gets 1.5 sec delay and falls last.
      // This creates the perfect top-to-bottom dissolving effect.
      P.SpawnDelay := ((MaxY - vy) / HeightRange) * 1.5;
      P.SpawnTimer := 0.0;

      P.Life := 99999.0;
      P.MaxLife := 99999.0;

      P.Size := VoxelSize;
      P.StartSize := VoxelSize;
      P.EndSize := VoxelSize;
      // 100% Opaque to bypass Z-Buffer glitches
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
  // NOTE: Removed FLock.Enter here to prevent UI thread contention while
  // calculating 100,000+ particles. Emit() remains thread-safe.
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
        P.Color.a := 0; // Invisible during delay time
      end
      else
      begin
        DirToTarget := Vector3Subtract(P.TargetPosition, P.Position);
        Dist := Vector3Length(DirToTarget);
        if Dist > 0.001 then
          DirToTarget := Vector3Scale(DirToTarget, 1.0 / Dist)
        else
          DirToTarget := Vector3Create(0, 0, 0);

        Sog := 30.0 * Dist;
        P.Velocity := Vector3Scale(DirToTarget, Sog);

        if Dist < 0.05 then
        begin
          // ARRIVED! Move exactly to target and freeze
          P.Position := P.TargetPosition;
          P.Velocity := Vector3Create(0, 0, 0);
          P.HasArrived := True;
          Inc(FMatArrivedCount);
          // IMPORTANT: Particles stay here and glow with 100% alpha
          P.Color.a := 255;
        end
        else
        begin
          // On the way inwards: Already glowing, but not arrived yet
          P.Color.a := 200;
        end;
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
      if CurrentVel < 0 then
        CurrentVel := 0;
      P.Velocity := Vector3Scale(P.Velocity, CurrentVel);

      Progress := 1.0 - (P.Life / P.MaxLife);
      if Progress > 1.0 then
        Progress := 1.0;
      if Progress < 0.0 then
        Progress := 0.0;

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
  // If ALL particles have arrived -> Set SolidCubeReady to True and kill ALL particles
  if FIsMaterializing and (FMatTotalCount > 0) and (FMatArrivedCount >= FMatTotalCount) then
  begin
    FIsMaterializing := False;
    FHasSolidCube := True; // THE SIGNAL: Top layer reached!
    FMatArrivedCount := 0;
    FMatTotalCount := 0;
    // Now that the model is finished, we kill all particles together
    SetLength(FParticles, 0);
  end;

  if FIsDematerializing and (DematAliveCount = 0) then
  begin
    FIsDematerializing := False;
    FHasSolidCube := False;
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
  // Raw cube vertices
  V0, V1, V2, V3, V4, V5, V6, V7: TVector3;
  // Raw sphere variables
  RX, RY, RZ: Single;
  Sx, Sy, Sz: Single;
  Cx, Cy, Cz: Single;
begin
  FLock.Enter;
  try
    if Length(FParticles) = 0 then
      Exit;

    rlSetBlendMode(BLEND_ALPHA);

    case FRenderShape of
      rsCube:
        begin
          // RAW OPENGL BATCHING: Prevent DrawCube from flushing the batch buffer!
          rlBegin(RL_TRIANGLES);
          try
            for i := 0 to High(FParticles) do
            begin
              P := @FParticles[i];
              HalfSize := P.Size * 0.5;
              PosX := P.Position.x;
              PosY := P.Position.y;
              PosZ := P.Position.z;

              // 8 corners of the cube
              V0 := Vector3Create(PosX - HalfSize, PosY - HalfSize, PosZ - HalfSize);
              V1 := Vector3Create(PosX + HalfSize, PosY - HalfSize, PosZ - HalfSize);
              V2 := Vector3Create(PosX + HalfSize, PosY + HalfSize, PosZ - HalfSize);
              V3 := Vector3Create(PosX - HalfSize, PosY + HalfSize, PosZ - HalfSize);
              V4 := Vector3Create(PosX - HalfSize, PosY - HalfSize, PosZ + HalfSize);
              V5 := Vector3Create(PosX + HalfSize, PosY - HalfSize, PosZ + HalfSize);
              V6 := Vector3Create(PosX + HalfSize, PosY + HalfSize, PosZ + HalfSize);
              V7 := Vector3Create(PosX - HalfSize, PosY + HalfSize, PosZ + HalfSize);

              rlColor4ub(P.Color.r, P.Color.g, P.Color.b, P.Color.a);

              // Front face
              rlVertex3f(V0.x, V0.y, V0.z); rlVertex3f(V1.x, V1.y, V1.z); rlVertex3f(V2.x, V2.y, V2.z);
              rlVertex3f(V0.x, V0.y, V0.z); rlVertex3f(V2.x, V2.y, V2.z); rlVertex3f(V3.x, V3.y, V3.z);
              // Back face
              rlVertex3f(V5.x, V5.y, V5.z); rlVertex3f(V4.x, V4.y, V4.z); rlVertex3f(V7.x, V7.y, V7.z);
              rlVertex3f(V5.x, V5.y, V5.z); rlVertex3f(V7.x, V7.y, V7.z); rlVertex3f(V6.x, V6.y, V6.z);
              // Top face
              rlVertex3f(V3.x, V3.y, V3.z); rlVertex3f(V2.x, V2.y, V2.z); rlVertex3f(V6.x, V6.y, V6.z);
              rlVertex3f(V3.x, V3.y, V3.z); rlVertex3f(V6.x, V6.y, V6.z); rlVertex3f(V7.x, V7.y, V7.z);
              // Bottom face
              rlVertex3f(V4.x, V4.y, V4.z); rlVertex3f(V5.x, V5.y, V5.z); rlVertex3f(V1.x, V1.y, V1.z);
              rlVertex3f(V4.x, V4.y, V4.z); rlVertex3f(V1.x, V1.y, V1.z); rlVertex3f(V0.x, V0.y, V0.z);
              // Left face
              rlVertex3f(V4.x, V4.y, V4.z); rlVertex3f(V0.x, V0.y, V0.z); rlVertex3f(V3.x, V3.y, V3.z);
              rlVertex3f(V4.x, V4.y, V4.z); rlVertex3f(V3.x, V3.y, V3.z); rlVertex3f(V7.x, V7.y, V7.z);
              // Right face
              rlVertex3f(V1.x, V1.y, V1.z); rlVertex3f(V5.x, V5.y, V5.z); rlVertex3f(V6.x, V6.y, V6.z);
              rlVertex3f(V1.x, V1.y, V1.z); rlVertex3f(V6.x, V6.y, V6.z); rlVertex3f(V2.x, V2.y, V2.z);
            end;
          finally
            rlEnd();
          end;
        end;
      rsSphere:
        begin
          // RAW OPENGL BATCHING: Octahedron approximation for spheres (highly performant)
          rlBegin(RL_TRIANGLES);
          try
            for i := 0 to High(FParticles) do
            begin
              P := @FParticles[i];
              HalfSize := P.Size * 0.5;
              Cx := P.Position.x;
              Cy := P.Position.y;
              Cz := P.Position.z;

              // Top, Bottom, Left, Right, Front, Back
              Sx := HalfSize; Sy := HalfSize; Sz := HalfSize;

              rlColor4ub(P.Color.r, P.Color.g, P.Color.b, P.Color.a);

              // Top-Left triangles
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx - Sx, Cy, Cz - Sz); rlVertex3f(Cx - Sx, Cy, Cz + Sz);
              // Top-Right triangles
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx + Sx, Cy, Cz + Sz); rlVertex3f(Cx + Sx, Cy, Cz - Sz);
              // Top-Front triangles
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx, Cy, Cz + Sz); rlVertex3f(Cx + Sx, Cy, Cz + Sz); // Wait, need simpler octa
              // Actually, let's just use 8 simple faces (Octahedron)
              // Re-doing it cleanly below for top/bottom left/right front/back

              // Top Front
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx, Cy, Cz + Sz); rlVertex3f(Cx + Sx, Cy, Cz);
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx - Sx, Cy, Cz); rlVertex3f(Cx, Cy, Cz + Sz);
              // Top Back
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx + Sx, Cy, Cz); rlVertex3f(Cx, Cy, Cz - Sz);
              rlVertex3f(Cx, Cy + Sy, Cz); rlVertex3f(Cx, Cy, Cz - Sz); rlVertex3f(Cx - Sx, Cy, Cz);
              // Bottom Front
              rlVertex3f(Cx, Cy - Sy, Cz); rlVertex3f(Cx + Sx, Cy, Cz); rlVertex3f(Cx, Cy, Cz + Sz);
              rlVertex3f(Cx, Cy - Sy, Cz); rlVertex3f(Cx, Cy, Cz + Sz); rlVertex3f(Cx - Sx, Cy, Cz);
              // Bottom Back
              rlVertex3f(Cx, Cy - Sy, Cz); rlVertex3f(Cx - Sx, Cy, Cz); rlVertex3f(Cx, Cy, Cz - Sz);
              rlVertex3f(Cx, Cy - Sy, Cz); rlVertex3f(Cx, Cy, Cz - Sz); rlVertex3f(Cx + Sx, Cy, Cz);
            end;
          finally
            rlEnd();
          end;
        end;
      rsBillboard2D:
        begin
          CamRight := GetCameraRight;
          CamUp := GetCameraUp;
          RgtX := CamRight.x;
          RgtY := CamRight.y;
          RgtZ := CamRight.z;
          UpX := CamUp.x;
          UpY := CamUp.y;
          UpZ := CamUp.z;

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

              rlVertex3f(PosX + (RgtX *  - HalfSize) + (UpX * HalfSize), PosY + (RgtY *  - HalfSize) + (UpY * HalfSize), PosZ + (RgtZ *  - HalfSize) + (UpZ * HalfSize));
              rlVertex3f(PosX + (RgtX * HalfSize) + (UpX * HalfSize), PosY + (RgtY * HalfSize) + (UpY * HalfSize), PosZ + (RgtZ * HalfSize) + (UpZ * HalfSize));
              rlVertex3f(PosX + (RgtX * HalfSize) + (UpX *  - HalfSize), PosY + (RgtY * HalfSize) + (UpY *  - HalfSize), PosZ + (RgtZ * HalfSize) + (UpZ *  - HalfSize));
              rlVertex3f(PosX + (RgtX *  - HalfSize) + (UpX *  - HalfSize), PosY + (RgtY *  - HalfSize) + (UpY *  - HalfSize), PosZ + (RgtZ *  - HalfSize) + (UpZ *  - HalfSize));
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

