unit Yutani.Render.Particles;

{==============================================================================*
 *  Yutani Particle Engine v0.2 - Pre-Allocated System (2D/3D Hybrid)
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    High-performance particle system using Pre-Allocation for spawning and
 *    Raylib's standard matrix transformations for rendering.
 *    Supports 3D Cubes, 3D Spheres, and 2D Camera-Facing Billboards.
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
  TParticleRenderShape = (rsCube, rsSphere, rsBillboard2D);

  TYutaniParticleEngine = class
  private
    FParticles: array of TParticleInstance;
    FLock: TCriticalSection;
    FGravity: Single;
    FDrag: Single;
    FRenderShape: TParticleRenderShape;
    FCamera: TCamera3D; // Needed for 2D Billboarding
    FMaxParticles: Integer;
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

    procedure Emit(const Pos: TVector3; EmissionType: TParticleEmissionType;
      Count: Integer; const BaseColor: TColorB);
    procedure EmitExplosion(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSmoke(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitSparks(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);
    procedure EmitBeamSparkles(const Pos: TVector3; Count: Integer; const BaseColor: TColorB);

    property Gravity: Single read FGravity write FGravity;
    property Drag: Single read FDrag write FDrag;
    property RenderShape: TParticleRenderShape read FRenderShape write FRenderShape;
    property Camera: TCamera3D read FCamera write FCamera;
    procedure SetMaxParticles(const MaxCount: Integer);
  end;

implementation

const
  MAX_PARTICLES = 1000000; // 1 Million cap

{ TYutaniParticleEngine }

constructor TYutaniParticleEngine.Create;
begin
  inherited Create;
  SetLength(FParticles, 0);
  FLock := TCriticalSection.Create;
  FGravity := -9.81;
  FDrag := 0.5;
  FRenderShape := rsBillboard2D; // Default to 2D Billboards (fastest & best looking)
  FMaxParticles := MAX_PARTICLES;
  // Default Camera just in case
  FCamera.position := Vector3Create(10, 10, 10);
  FCamera.target := Vector3Create(0, 0, 0);
  FCamera.up := Vector3Create(0, 1, 0);
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
            P^.EndSize := 0.02;
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
  CamRight, CamUp: TVector3;
  Vertices: array[0..3] of TVector3;
  HalfSize: Single;
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
            DrawCube(P^.Position, P^.Size * 0.5, P^.Size * 0.5, P^.Size * 0.5, P^.Color);
          end;
        end;
      rsSphere:
        begin
          for i := 0 to High(FParticles) do
          begin
            P := @FParticles[i];
            DrawSphere(P^.Position, P^.Size * 0.5, P^.Color);
          end;
        end;
      rsBillboard2D:
        begin
          // Calculate Camera Basis Vectors once
          CamRight := GetCameraRight;
          CamUp := GetCameraUp;

          for i := 0 to High(FParticles) do
          begin
            P := @FParticles[i];
            HalfSize := P^.Size * 0.5;

            // Calculate the 4 corners of the 2D Quad facing the camera
            Vertices[0].x := P^.Position.x + (CamRight.x * -HalfSize) + (CamUp.x * HalfSize);
            Vertices[0].y := P^.Position.y + (CamRight.y * -HalfSize) + (CamUp.y * HalfSize);
            Vertices[0].z := P^.Position.z + (CamRight.z * -HalfSize) + (CamUp.z * HalfSize);

            Vertices[1].x := P^.Position.x + (CamRight.x * HalfSize) + (CamUp.x * HalfSize);
            Vertices[1].y := P^.Position.y + (CamRight.y * HalfSize) + (CamUp.y * HalfSize);
            Vertices[1].z := P^.Position.z + (CamRight.z * HalfSize) + (CamUp.z * HalfSize);

            Vertices[2].x := P^.Position.x + (CamRight.x * HalfSize) + (CamUp.x * -HalfSize);
            Vertices[2].y := P^.Position.y + (CamRight.y * HalfSize) + (CamUp.y * -HalfSize);
            Vertices[2].z := P^.Position.z + (CamRight.z * HalfSize) + (CamUp.z * -HalfSize);

            Vertices[3].x := P^.Position.x + (CamRight.x * -HalfSize) + (CamUp.x * -HalfSize);
            Vertices[3].y := P^.Position.y + (CamRight.y * -HalfSize) + (CamUp.y * -HalfSize);
            Vertices[3].z := P^.Position.z + (CamRight.z * -HalfSize) + (CamUp.z * -HalfSize);

            // Draw the Quad (Triangle 1 and Triangle 2)
            DrawTriangle3D(Vertices[0], Vertices[1], Vertices[2], P^.Color);
            DrawTriangle3D(Vertices[0], Vertices[2], Vertices[3], P^.Color);
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
