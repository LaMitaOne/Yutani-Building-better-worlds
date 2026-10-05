unit Yutani.Render.Particles;

{==============================================================================*
 *  Yutani Particle Engine v0.2 - Pre-Allocated Matrix Batched System
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    High-performance particle system using Pre-Allocation for spawning and
 *    Raylib's standard matrix transformations (DrawCube) for rendering.
 *    Raylib's internal RenderBatch groups these calls efficiently into a
 *    single draw call, bypassing broken Delphi DrawMeshInstanced bindings.
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
    Color: TColorB;
    StartColor: TColorB;
    EndColor: TColorB;
    Life: Single;
    MaxLife: Single;
    Size: Single;
    StartSize: Single;
    EndSize: Single;
    IsSmoke: Boolean;
  end;
  TParticleEmissionType = (etExplosion, etSmoke, etSpark, etBeam);
  TYutaniParticleEngine = class
  private
    FParticles: array of TParticleInstance;
    FMatrices: array of TMatrix;
    FLock: TCriticalSection;
    FBaseMesh: TMesh;
    FMaterial: TMaterial;
    FGravity: Single;
    FDrag: Single;
    procedure InitializeBaseMesh;
    procedure SetDefaults(var P: TParticleInstance);
  public
    constructor Create;
    destructor Destroy; override;
    function ParticleCount: Integer;
    procedure Update(const dt: Single);
    procedure Render;
    procedure Emit(const Pos: TVector3; EmissionType: TParticleEmissionType;
      Count: Integer; const BaseColor: TColorB);
    procedure EmitExplosion(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSmoke(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSparks(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitBeamSparkles(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    property Gravity: Single read FGravity write FGravity;
    property Drag: Single read FDrag write FDrag;
  end;
implementation
const
  MAX_PARTICLES = 1000000; // 1 Million cap
{ TYutaniParticleEngine }
constructor TYutaniParticleEngine.Create;
begin
  inherited Create;
  SetLength(FParticles, 0);
  // Pre-allocate the matrices array to maximum capacity once
  SetLength(FMatrices, MAX_PARTICLES);
  FLock := TCriticalSection.Create;
  FGravity := -9.81;
  FDrag := 0.5;
  InitializeBaseMesh;
end;
destructor TYutaniParticleEngine.Destroy;
begin
  FLock.Enter;
  try
    SetLength(FParticles, 0);
    SetLength(FMatrices, 0);
  finally
    FLock.Leave;
  end;
  FLock.Free;
  if FBaseMesh.vertices <> nil then
    UnloadMesh(FBaseMesh);
  inherited;
end;
procedure TYutaniParticleEngine.InitializeBaseMesh;
begin
  // Very low poly unit sphere (radius 0.5) for particles
  FBaseMesh := GenMeshSphere(0.5, 6, 4);
  UploadMesh(@FBaseMesh, False);
  // Create a safe default material
  FMaterial := LoadMaterialDefault();
end;
procedure TYutaniParticleEngine.SetDefaults(var P: TParticleInstance);
begin
  P.Position := Vector3Create(0, 0, 0);
  P.Velocity := Vector3Create(0, 0, 0);
  P.Life := 1.0;
  P.MaxLife := 1.0;
  P.StartColor := WHITE;
  P.EndColor := WHITE;
  P.Color := WHITE;
  P.StartSize := 1.0;
  P.EndSize := 1.0;
  P.Size := 1.0;
  P.IsSmoke := False;
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
    // --- Step A: Pre-allocation ---
    // Prevent array from being too large
    if OldLength + Count > MAX_PARTICLES then
      NewCount := MAX_PARTICLES - OldLength
    else
      NewCount := Count;
    if NewCount <= 0 then Exit;
    // Resize the array ONCE for the whole batch
    SetLength(FParticles, OldLength + NewCount);
    for i := 0 to NewCount - 1 do
    begin
      // Directly access the pre-allocated memory via pointer
      P := @FParticles[OldLength + i];
      SetDefaults(P^);
      P^.Position := Pos;
      case EmissionType of
        etExplosion:
          begin
            DirX := Random * 2 - 1;
            DirY := Random * 2 - 1;
            DirZ := Random * 2 - 1;
            P^.Velocity := Vector3Normalize(Vector3Create(DirX, DirY, DirZ));
            RandSpeed := 5 + (Random * 15);
            P^.Velocity := Vector3Scale(P^.Velocity, RandSpeed);
            P^.MaxLife := 1.0 + (Random * 1.0);
            P^.StartColor := BaseColor;
            P^.EndColor := ColorAlpha(BLACK, 0);
            P^.StartSize := 0.15;
            P^.EndSize := 0.05;
          end;
        etSmoke:
          begin
            P^.IsSmoke := True;
            P^.Position.x := Pos.x + ((Random * 2 - 1) * 15.0);
            P^.Position.z := Pos.z + ((Random * 2 - 1) * 15.0);
            P^.Position.y := Pos.y + (Random * 5.0);
            P^.Velocity.x := (Random * 2 - 1) * 0.2;
            P^.Velocity.y := 0.5 + (Random * 0.8);
            P^.Velocity.z := (Random * 2 - 1) * 0.2;
            P^.MaxLife := 8.0 + (Random * 7.0);
            P^.StartColor := ColorAlpha(BaseColor, 30);
            P^.EndColor := ColorAlpha(BaseColor, 0);
            P^.StartSize := 0.1;
            P^.EndSize := 0.25;
          end;
        etSpark:
          begin
            DirX := Random * 2 - 1;
            DirY := Abs(Random * 2 - 1);
            DirZ := Random * 2 - 1;
            P^.Velocity := Vector3Normalize(Vector3Create(DirX, DirY, DirZ));
            RandSpeed := 10 + (Random * 20);
            P^.Velocity := Vector3Scale(P^.Velocity, RandSpeed);
            P^.MaxLife := 0.3 + (Random * 0.5);
            P^.StartColor := BaseColor;
            P^.EndColor := ColorAlpha(RED, 0);
            P^.StartSize := 0.05;
            P^.EndSize := 0.01;
          end;
        etBeam:
          begin
            P^.Position.x := Pos.x + (Random * 2 - 1) * 1.5;
            P^.Position.y := Pos.y + (Random * 100);
            P^.Position.z := Pos.z + (Random * 2 - 1) * 1.5;
            P^.Velocity.y := -1.0 - (Random * 2);
            P^.MaxLife := 1.5 + (Random * 1.0);
            P^.StartColor := WHITE;
            P^.EndColor := ColorAlpha(BaseColor, 0);
            P^.StartSize := 0.05;
            P^.EndSize := 0.01;
          end;
      end;
      P^.Life := P^.MaxLife;
      P^.Color := P^.StartColor;
      P^.Size := P^.StartSize;
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
begin
  FLock.Enter;
  try
    i := 0;
    while i <= High(FParticles) do
    begin
      P := @FParticles[i];
      P^.Life := P^.Life - dt;
      if P^.Life <= 0 then
      begin
        LastIdx := High(FParticles);
        if i <> LastIdx then
          Move(FParticles[LastIdx], FParticles[i], SizeOf(TParticleInstance));
        SetLength(FParticles, LastIdx);
        Continue;
      end;
      if not P^.IsSmoke then
      begin
        CurrentY := P^.Velocity.y + (FGravity * dt);
        P^.Velocity.y := CurrentY;
      end;
      CurrentVel := 1.0 - (FDrag * dt);
      if CurrentVel < 0 then CurrentVel := 0;
      P^.Velocity := Vector3Scale(P^.Velocity, CurrentVel);
      P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));
      Progress := 1.0 - (P^.Life / P^.MaxLife);
      if Progress > 1.0 then Progress := 1.0;
      if Progress < 0.0 then Progress := 0.0;
      P^.Size := Lerp(P^.StartSize, P^.EndSize, Progress);
      DeltaColor.r := Round(Lerp(P^.StartColor.r, P^.EndColor.r, Progress));
      DeltaColor.g := Round(Lerp(P^.StartColor.g, P^.EndColor.g, Progress));
      DeltaColor.b := Round(Lerp(P^.StartColor.b, P^.EndColor.b, Progress));
      DeltaColor.a := Round(Lerp(P^.StartColor.a, P^.EndColor.a, Progress));
      P^.Color := DeltaColor;
      Inc(i);
    end;
  finally
    FLock.Leave;
  end;
end;
procedure TYutaniParticleEngine.Render;
var
  i: Integer;
  P: PParticleInstance;
  ZeroPos: TVector3;
begin
  FLock.Enter;
  try
    if Length(FParticles) = 0 then Exit;
    rlSetBlendMode(BLEND_ALPHA);
    // Prepare a zero vector, as we handle the position via rlTranslatef
    ZeroPos := Vector3Create(0, 0, 0);
    for i := 0 to High(FParticles) do
    begin
      P := @FParticles[i];
      rlPushMatrix();
      // 1. Translate matrix to the particle's world position
      rlTranslatef(P^.Position.x, P^.Position.y, P^.Position.z);
      // 2. Scale matrix based on particle size
      rlScalef(P^.Size, P^.Size, P^.Size);
      // 3. Draw exactly at the local origin (0,0,0) of the matrix.
      // The base size of the cube is 0.5, as the scaling is fully handled by rlScalef!
      DrawCube(ZeroPos, 0.5, 0.5, 0.5, P^.Color);
      rlPopMatrix();
    end;
    rlDrawRenderBatchActive();
    rlSetBlendMode(BLEND_ALPHA);
  finally
    FLock.Leave;
  end;
end;
end.
