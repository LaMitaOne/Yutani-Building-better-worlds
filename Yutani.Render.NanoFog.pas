unit Yutani.Render.NanoFog;

{==============================================================================*
 *  Yutani NanoFog Engine v0.2 - Swarm Core
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    A persistent nanotech fog system with a strict limit of 10.000 particles.
 *    Particles are NEVER deleted. If a shape requires fewer particles, the
 *    excess particles stay alive and orbit the finished object as a fog cloud.
 *    No array shifting or SetLength happens during the Raylib render cycle!
 *==============================================================================}
{$POINTERMATH ON}
interface
uses
  System.SysUtils, System.Classes, System.Math, System.SyncObjs, Raylib, RayMath,
  rlgl;
type
  TNanoShapeType = (nstBox, nstSphere, nstCapsule, nstPyramid, nstPrism);
  // Added nsDead for the epic explosion & fade-out sequence
  TNanoState = (nsFog, nsOrbiting, nsForming, nsFormed, nsDead);
  TNanoParticle = record
    AvatarID: Integer;
    State: TNanoState;
    Position: TVector3;
    Velocity: TVector3;
    TargetPosition: TVector3;
    CenterPos: TVector3;
    WanderTarget: TVector3;
    WanderTimer: Single;
    PhaseTimer: Single;
    SpawnDelay: Single;
    Size: Single;
    Color: TColorB;
  end;
  TNanoFogEngine = class
  private
    FParticles: array of TNanoParticle;
    FLock: TCriticalSection;
    FMaxParticles: Integer;
    FElapsed: Single;
    FCurrentAvatarID: Integer;
    FMatTargetCount: Integer;
    FMatArrivedCount: Integer;
    function GeneratePrimitiveGrid(ShapeType: TNanoShapeType; const Scale: TVector3;
      out CenterPos: TVector3; out MinY: Single; out MaxY: Single): TArray<TVector3>;
    function GenerateMeshGrid(const Mesh: TMesh;
      out CenterPos: TVector3; out MinY: Single; out MaxY: Single): TArray<TVector3>;
    procedure SpawnAvatarParticles(const TargetPos: TVector3; const Points: TArray<TVector3>;
      const CenterPos: TVector3; MinY, MaxY: Single; AvatarID: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure Update(const dt: Single);
    procedure Render;
    procedure EmitMaterializeMesh(const TargetPos: TVector3; const Mesh: TMesh; AvatarID: Integer);
    procedure EmitMaterializePrimitive(const TargetPos: TVector3; ShapeType: TNanoShapeType;
      const Scale: TVector3; AvatarID: Integer);
    // Dissolves the avatar completely and immediately into chaotic fog
    procedure MorphToFog(AvatarID: Integer);
    // Epic explosion and death sequence
    procedure ExplodeAndKill;
    procedure Clear;
  end;
implementation
const
  MAX_PARTICLES = 10000;
{ TNanoFogEngine }
constructor TNanoFogEngine.Create;
begin
  inherited Create;
  SetLength(FParticles, 0);
  FLock := TCriticalSection.Create;
  FMaxParticles := MAX_PARTICLES;
  FElapsed := 0.0;
  FCurrentAvatarID := -1;
  FMatTargetCount := 0;
  FMatArrivedCount := 0;
end;
destructor TNanoFogEngine.Destroy;
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
procedure TNanoFogEngine.Clear;
begin
  FLock.Enter;
  try
    SetLength(FParticles, 0);
  finally
    FLock.Leave;
  end;
end;
procedure TNanoFogEngine.SpawnAvatarParticles(const TargetPos: TVector3; const Points: TArray<TVector3>;
  const CenterPos: TVector3; MinY, MaxY: Single; AvatarID: Integer);
var
  i, j: Integer;
  P: ^TNanoParticle;
  HeightRange, NormY: Single;
  NeededCount, AssignedCount, MissingCount, OldLength: Integer;
begin
  FLock.Enter;
  try
    NeededCount := Length(Points);
    AssignedCount := 0;
    // Initialize strict event-driven logic
    FCurrentAvatarID := AvatarID;
    FMatTargetCount := NeededCount;
    FMatArrivedCount := 0;
    // 1. MASS RESTORATION: If we have less than NeededCount particles in memory, spawn the missing ones.
    if Length(FParticles) < NeededCount then
    begin
      MissingCount := NeededCount - Length(FParticles);
      OldLength := Length(FParticles);
      // SAFELY extend the array and initialize the new particles
      SetLength(FParticles, NeededCount);
      for i := OldLength to High(FParticles) do
      begin
        P := @FParticles[i];
        P^.AvatarID := -1;
        P^.State := nsFog;
        P^.Position := Vector3Create(
          TargetPos.x + (Random * 30 - 15),
          TargetPos.y + (Random * 20 - 5),
          TargetPos.z + (Random * 30 - 15)
        );
        P^.Velocity := Vector3Create(0,0,0);
        P^.WanderTimer := 0;
        P^.Size := 0.04;
        P^.Color := ColorAlpha(SKYBLUE, 140);
      end;
    end;
    // Calculate target bounding box height for bottom-up assembly delay
    HeightRange := MaxY - MinY;
    if HeightRange <= 0.001 then HeightRange := 1.0;
    j := 0;
    // 2. Assign ALL existing particles to fly to the object and orbit it
    for i := 0 to High(FParticles) do
    begin
      P := @FParticles[i];
      // CRITICAL FIX: Grab all particles that are NOT currently forming for the NEW Avatar.
      // This forces particles still stuck on the OLD shape (nsFormed/nsForming/nsFog)
      // to immediately detach and fly to the new target, preventing render buffer aborts.
      if not ((P^.State = nsForming) and (P^.AvatarID = AvatarID) and (P^.PhaseTimer = P^.SpawnDelay)) then
      begin
        P^.AvatarID := AvatarID;
        P^.State := nsOrbiting; // Crucial: Set to Orbiting so they immediately fly to the new center
        P^.PhaseTimer := 0;
        P^.CenterPos := Vector3Add(TargetPos, CenterPos);
        // The first 'NeededCount' particles get a real target position to build the shape.
        if AssignedCount < NeededCount then
        begin
          P^.TargetPosition := Vector3Add(TargetPos, Points[j]);
          // Normalize Y for perfect bottom-up timing (0 = bottom, 1 = top)
          NormY := (Points[j].y - MinY) / HeightRange;
          P^.SpawnDelay := NormY * 1.0; // 1 second total build time
          Inc(j);
          Inc(AssignedCount);
        end
        else
        begin
          // EXCESS PARTICLES: They get no target, they just orbit and stay as fog.
          P^.TargetPosition := Vector3Create(99999, 99999, 99999);
          P^.SpawnDelay := 99999.0; // Never transition to nsForming
        end;
        // CRITICAL FIX: If they just morphed from a previous shape, they might be exactly
        // on a symmetry axis, resulting in a (0,0,0) cross product later. We add a tiny
        // random impulse to break them out of that dead axis.
        if Vector3Length(P^.Velocity) < 5.0 then
          P^.Velocity := Vector3Create(Random * 0.01, Random * 0.01, Random * 0.01);
        P^.WanderTimer := 0;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;
function TNanoFogEngine.GeneratePrimitiveGrid(ShapeType: TNanoShapeType; const Scale: TVector3;
  out CenterPos: TVector3; out MinY: Single; out MaxY: Single): TArray<TVector3>;
var
  GridSize, i, j, k: Integer;
  OffsetX, OffsetY, OffsetZ: Single;
  LenX, LenY, LenZ: Single;
  DistSq, RadSq: Single;
  CapY, t, Angle, MaxR: Single;
  Points: TArray<TVector3>;
  Count: Integer;
begin
  GridSize := 10;
  SetLength(Points, GridSize * GridSize * GridSize);
  Count := 0;
  LenX := Scale.x * 0.5;
  LenY := Scale.y * 0.5;
  LenZ := Scale.z * 0.5;
  MinY := 99999;
  MaxY := -99999;
  case ShapeType of
    nstSphere:
      begin
        RadSq := Sqr(Max(LenX, Max(LenY, LenZ)));
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Scale.z;
              DistSq := Sqr(OffsetX) + Sqr(OffsetY) + Sqr(OffsetZ);
              if DistSq <= RadSq then
              begin
                Points[Count] := Vector3Create(OffsetX, OffsetY, OffsetZ);
                if OffsetY < MinY then MinY := OffsetY;
                if OffsetY > MaxY then MaxY := OffsetY;
                Inc(Count);
              end;
            end;
      end;
    nstCapsule:
      begin
        RadSq := Sqr(Max(LenX, LenZ));
        CapY := LenY - Max(LenX, LenZ);
        if CapY < 0 then CapY := 0;
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Scale.z;
              DistSq := Sqr(OffsetX) + Sqr(OffsetZ);
              if DistSq <= RadSq then
              begin
                if (OffsetY >= -CapY) and (OffsetY <= CapY) then
                begin
                  Points[Count] := Vector3Create(OffsetX, OffsetY, OffsetZ);
                  if OffsetY < MinY then MinY := OffsetY;
                  if OffsetY > MaxY then MaxY := OffsetY;
                  Inc(Count);
                end
                else
                begin
                  if OffsetY > CapY then
                    DistSq := DistSq + Sqr(OffsetY - CapY)
                  else
                    DistSq := DistSq + Sqr(OffsetY + CapY);
                  if DistSq <= RadSq then
                  begin
                    Points[Count] := Vector3Create(OffsetX, OffsetY, OffsetZ);
                    if OffsetY < MinY then MinY := OffsetY;
                    if OffsetY > MaxY then MaxY := OffsetY;
                    Inc(Count);
                  end;
                end;
              end;
            end;
      end;
    nstPyramid:
      begin
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Scale.z;
              t := 1.0 - ((OffsetY + LenY) / Scale.y);
              if t < 0 then t := 0;
              if (Abs(OffsetX) <= LenX * t) and (Abs(OffsetZ) <= LenZ * t) then
              begin
                Points[Count] := Vector3Create(OffsetX, OffsetY, OffsetZ);
                if OffsetY < MinY then MinY := OffsetY;
                if OffsetY > MaxY then MaxY := OffsetY;
                Inc(Count);
              end;
            end;
      end;
    nstPrism:
      begin
        MaxR := Min(LenX, LenZ) * 0.866;
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Scale.z;
              if (Abs(OffsetX) <= MaxR) and (Abs(OffsetZ) <= MaxR) then
              begin
                Angle := ArcTan2(OffsetZ, OffsetX);
                while Angle < 0 do Angle := Angle + 2 * PI;
                while Angle >= 2 * PI do Angle := Angle - 2 * PI;
                if Angle > 2 * PI / 3 then Angle := Angle - 2 * PI / 3;
                if Angle > 2 * PI / 3 then Angle := Angle - 2 * PI / 3;
                if Sqr(OffsetX) + Sqr(OffsetZ) <= Sqr(MaxR / Cos(Angle - PI / 3)) then
                begin
                  Points[Count] := Vector3Create(OffsetX, OffsetY, OffsetZ);
                  if OffsetY < MinY then MinY := OffsetY;
                  if OffsetY > MaxY then MaxY := OffsetY;
                  Inc(Count);
                end;
              end;
            end;
      end;
    nstBox:
      begin
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Scale.z;
              Points[Count] := Vector3Create(OffsetX, OffsetY, OffsetZ);
              if OffsetY < MinY then MinY := OffsetY;
              if OffsetY > MaxY then MaxY := OffsetY;
              Inc(Count);
            end;
      end;
  end;
  CenterPos := Vector3Create(0, (MinY + MaxY) * 0.5, 0);
  SetLength(Points, Count);
  Result := Points;
end;
function TNanoFogEngine.GenerateMeshGrid(const Mesh: TMesh;
  out CenterPos: TVector3; out MinY: Single; out MaxY: Single): TArray<TVector3>;
var
  i: Integer;
  Points: TArray<TVector3>;
  vx, vy, vz: Single;
  BBox: TBoundingBox;
  MeshW, MeshH, MeshD, MaxDim, UniformScale: Single;
begin
  if (Mesh.vertexCount = 0) or (Mesh.vertices = nil) then
  begin
    SetLength(Result, 0);
    CenterPos := Vector3Create(0,0,0);
    MinY := 0; MaxY := 0;
    Exit;
  end;
  // Apply uniform scaling to prevent flat pancakes
  BBox := GetMeshBoundingBox(Mesh);
  MeshW := BBox.max.x - BBox.min.x;
  MeshH := BBox.max.y - BBox.min.y;
  MeshD := BBox.max.z - BBox.min.z;
  MaxDim := Max(MeshW, Max(MeshH, MeshD));
  if MaxDim <= 0 then MaxDim := 1.0;
  UniformScale := 1.0 / MaxDim;
  SetLength(Points, Mesh.vertexCount);
  MinY := 99999;
  MaxY := -99999;
  for i := 0 to Mesh.vertexCount - 1 do
  begin
    vx := Mesh.vertices[i * 3];
    vy := Mesh.vertices[i * 3 + 1];
    vz := Mesh.vertices[i * 3 + 2];
    vx := vx * UniformScale;
    vy := vy * UniformScale;
    vz := vz * UniformScale;
    Points[i] := Vector3Create(vx, vy, vz);
    if vy < MinY then MinY := vy;
    if vy > MaxY then MaxY := vy;
  end;
  CenterPos := Vector3Create(0, (MinY + MaxY) * 0.5, 0);
  Result := Points;
end;
procedure TNanoFogEngine.EmitMaterializeMesh(const TargetPos: TVector3; const Mesh: TMesh; AvatarID: Integer);
var
  Points: TArray<TVector3>;
  CenterPos: TVector3;
  MinY, MaxY: Single;
begin
  Points := GenerateMeshGrid(Mesh, CenterPos, MinY, MaxY);
  if Length(Points) > 0 then
    SpawnAvatarParticles(TargetPos, Points, CenterPos, MinY, MaxY, AvatarID);
end;
procedure TNanoFogEngine.EmitMaterializePrimitive(const TargetPos: TVector3; ShapeType: TNanoShapeType;
  const Scale: TVector3; AvatarID: Integer);
var
  Points: TArray<TVector3>;
  CenterPos: TVector3;
  MinY, MaxY: Single;
begin
  Points := GeneratePrimitiveGrid(ShapeType, Scale, CenterPos, MinY, MaxY);
  if Length(Points) > 0 then
    SpawnAvatarParticles(TargetPos, Points, CenterPos, MinY, MaxY, AvatarID);
end;
procedure TNanoFogEngine.MorphToFog(AvatarID: Integer);
var
  i: Integer;
  P: ^TNanoParticle;
  ExplodeDir: TVector3;
begin
  FLock.Enter;
  try
    for i := 0 to High(FParticles) do
    begin
      P := @FParticles[i];
      if P^.AvatarID = AvatarID then
      begin
        // IMMEDIATELY BREAK APART! Explode violently outwards.
        P^.State := nsFog;
        P^.AvatarID := -1; // Free up the ID immediately
        // Calculate a random direction from the center of the shape
        ExplodeDir := Vector3Subtract(P^.Position, P^.CenterPos);
        if Vector3Length(ExplodeDir) < 0.1 then
          ExplodeDir := Vector3Create(Random*2-1, Random*2-1, Random*2-1);
        // REDUCED SPEED: Give them a gentle push instead of bombing them to the moon
        P^.Velocity := Vector3Scale(Vector3Normalize(ExplodeDir), 5.0 + Random * 3.0);
        // REDUCED DISTANCE: Send them only a few meters away, not kilometers!
        P^.WanderTarget := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, 3.0));
        P^.WanderTimer := 1.5; // Shorter recovery time
      end;
    end;
    // Abort completion count immediately so Update doesn't freeze them
    if FCurrentAvatarID = AvatarID then
    begin
      FCurrentAvatarID := -1;
      FMatTargetCount := 0;
      FMatArrivedCount := 0;
    end;
  finally
    FLock.Leave;
  end;
end;
procedure TNanoFogEngine.ExplodeAndKill;
var
  i: Integer;
  P: ^TNanoParticle;
  ExplodeDir: TVector3;
begin
  FLock.Enter;
  try
    for i := 0 to High(FParticles) do
    begin
      P := @FParticles[i];
      // Only kill particles that are currently active
      if P^.State <> nsDead then
      begin
        // Calculate a fierce outward direction from the shape's center
        ExplodeDir := Vector3Subtract(P^.Position, P^.CenterPos);
        if Vector3Length(ExplodeDir) < 0.1 then
          ExplodeDir := Vector3Create(Random*2-1, Random*2-1, Random*2-1);
        // Give them a massive burst of speed
        P^.Velocity := Vector3Scale(Vector3Normalize(ExplodeDir), 50.0 + Random * 30.0);
        // Start the death timer
        P^.State := nsDead;
        P^.PhaseTimer := 0;
        P^.AvatarID := -1;
      end;
    end;
    // Abort current materialization logic
    FCurrentAvatarID := -1;
    FMatTargetCount := 0;
    FMatArrivedCount := 0;
  finally
    FLock.Leave;
  end;
end;
procedure TNanoFogEngine.Update(const dt: Single);
var
  i: Integer;
  P: ^TNanoParticle;
  Dir, Tangent: TVector3;
  Dist: Single;
begin
  FLock.Enter;
  try
    FElapsed := FElapsed + dt;
    FMatArrivedCount := 0;
    for i := 0 to High(FParticles) do
    begin
      P := @FParticles[i];
      case P^.State of
        nsFog:
          begin
            // Calm roaming
            if P^.WanderTimer <= 0 then
            begin
              // REDUCED WANDER RADIUS: Keep them in a tight 5x5x5 area
              P^.WanderTarget := Vector3Create(
                P^.Position.x + (Random * 5 - 2.5),
                P^.Position.y + (Random * 2 - 1.0),
                P^.Position.z + (Random * 5 - 2.5)
              );
              P^.WanderTimer := 2.0 + Random * 2.0;
            end;
            P^.WanderTimer := P^.WanderTimer - dt;
            Dir := Vector3Subtract(P^.WanderTarget, P^.Position);
            Dist := Vector3Length(Dir);
            if Dist > 0.1 then
              P^.Velocity := Vector3Add(P^.Velocity, Vector3Scale(Vector3Normalize(Dir), 0.5 * dt))
            else
              P^.Velocity := Vector3Scale(P^.Velocity, 0.9);
            // SUBTLE MAGNETISM: If no shape is currently building, pull them
            // gently back to the center so they don't drift away infinitely.
            if FCurrentAvatarID = -1 then
            begin
              Dir := Vector3Subtract(P^.CenterPos, P^.Position);
              Dist := Vector3Length(Dir);
              if Dist > 10.0 then // Only pull if they are too far away
              begin
                P^.Velocity := Vector3Add(P^.Velocity, Vector3Scale(Vector3Normalize(Dir), 1.0 * dt));
              end;
            end;
            P^.Velocity := Vector3Scale(P^.Velocity, 0.95);
            P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));
            P^.Color.r := 0;
            P^.Color.g := 170;
            P^.Color.b := 200;
            P^.Color.a := 140;
          end;
        nsOrbiting:
          begin
            P^.PhaseTimer := P^.PhaseTimer + dt;
            // Smooth orbit
            Dir := Vector3Subtract(P^.CenterPos, P^.Position);
            Dist := Vector3Length(Dir);
            if Dist > 0.1 then
            begin
              Tangent := Vector3CrossProduct(Vector3Create(0, 1, 0), Dir);
              // CRITICAL FIX: Prevent zero-vector lock when particles lie exactly on an axis
              if Vector3Length(Tangent) > 0.1 then
                P^.Velocity := Vector3Add(P^.Velocity, Vector3Scale(Vector3Normalize(Tangent), 12.0 * dt));
              P^.Velocity := Vector3Add(P^.Velocity, Vector3Scale(Vector3Normalize(Dir), (2.5 - Dist) * 1.5 * dt));
            end;
            P^.Velocity := Vector3Scale(P^.Velocity, 0.92);
            P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));
            P^.Color.r := 0;
            P^.Color.g := 190;
            P^.Color.b := 210;
            P^.Color.a := 180;
            // After 1.5 seconds of orbiting, start forming (ONLY for particles that have a real target)
            if (P^.PhaseTimer >= 1.5) and (P^.SpawnDelay < 100.0) then
            begin
              P^.State := nsForming;
              P^.PhaseTimer := P^.SpawnDelay;
              P^.Velocity := Vector3Create(0,0,0);
            end;
          end;
        nsForming:
          begin
            // Wait for the layer delay to finish
            if P^.PhaseTimer > 0 then
            begin
              P^.PhaseTimer := P^.PhaseTimer - dt;
              P^.Velocity := Vector3Create(0, 0, 0);
            end
            else
            begin
              // STRAIGHT TO TARGET: Direct, rigid movement, no physics wobble
              Dir := Vector3Subtract(P^.TargetPosition, P^.Position);
              Dist := Vector3Length(Dir);
              if Dist > 0.02 then
              begin
                P^.Velocity := Vector3Scale(Vector3Normalize(Dir), 12.0);
                P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));
              end
              else
              begin
                // Arrived exactly at target
                P^.Position := P^.TargetPosition;
                P^.Velocity := Vector3Create(0,0,0);
                P^.State := nsFormed;
                Inc(FMatArrivedCount); // Count arrivals for the strict logic
              end;
            end;
            P^.Color.r := 0;
            P^.Color.g := 210;
            P^.Color.b := 220;
            P^.Color.a := 200;
          end;
        nsFormed:
          begin
            // COMPLETELY RIGID. Just 0.001 independent micro-jitter
            P^.Position := Vector3Add(P^.TargetPosition, Vector3Create(
              Sin(FElapsed * 15.0 + P^.TargetPosition.x * 10.0) * 0.001,
              Sin(FElapsed * 15.0 + P^.TargetPosition.y * 10.0) * 0.001,
              Sin(FElapsed * 15.0 + P^.TargetPosition.z * 10.0) * 0.001
            ));
            P^.Color.r := 0;
            P^.Color.g := 230;
            P^.Color.b := 230;
            P^.Color.a := 220;
          end;
        // NEW STATE: EXPLODING AND DYING
        nsDead:
          begin
            P^.PhaseTimer := P^.PhaseTimer + dt;
            // Move with explosion velocity
            P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));
            P^.Velocity := Vector3Scale(P^.Velocity, 0.98); // Slight slow down
            // Flash bright white right before they disappear
            if P^.PhaseTimer < 0.2 then
            begin
              P^.Color.r := 255;
              P^.Color.g := 255;
              P^.Color.b := 255;
              P^.Color.a := 255;
            end
            else
            begin
              // Fade out rapidly
              P^.Color.a := P^.Color.a - Trunc(600 * dt);
              if P^.Color.a < 0 then P^.Color.a := 0;
            end;
          end;
      end;
    end;
    // STRICT EVENT-DRIVEN COMPLETION: The shape is ONLY finished when the
    // absolute last required particle (top layer) has arrived.
    if (FCurrentAvatarID <> -1) and (FMatTargetCount > 0) and (FMatArrivedCount >= FMatTargetCount) then
    begin
      FCurrentAvatarID := -1;
      FMatArrivedCount := 0;
      FMatTargetCount := 0;
    end;
  finally
    FLock.Leave;
  end;
end;
procedure TNanoFogEngine.Render;
var
  i: Integer;
  P: ^TNanoParticle;
  HalfSize: Single;
  Cx, Cy, Cz: Single;
  S: Single;
  HasAlive: Boolean;
begin
  FLock.Enter;
  try
    if Length(FParticles) = 0 then Exit;
    // Check if there are any particles left to render
    HasAlive := False;
    for i := 0 to High(FParticles) do
    begin
      if (FParticles[i].State <> nsDead) or (FParticles[i].Color.a > 0) then
      begin
        HasAlive := True;
        Break;
      end;
    end;
    if not HasAlive then
    begin
      // Safely clear memory if all particles have faded out
      SetLength(FParticles, 0);
      Exit;
    end;
    rlSetBlendMode(BLEND_ADDITIVE);
    rlBegin(RL_TRIANGLES);
    try
      for i := 0 to High(FParticles) do
      begin
        P := @FParticles[i];
        // SKIP DEAD AND FADED OUT PARTICLES
        if (P^.State = nsDead) and (P^.Color.a = 0) then
          Continue;
        HalfSize := P^.Size * 0.5;
        Cx := P^.Position.x;
        Cy := P^.Position.y;
        Cz := P^.Position.z;
        S := HalfSize;
        rlColor4ub(P^.Color.r, P^.Color.g, P^.Color.b, P^.Color.a);
        rlVertex3f(Cx, Cy + S, Cz); rlVertex3f(Cx, Cy, Cz + S); rlVertex3f(Cx + S, Cy, Cz);
        rlVertex3f(Cx, Cy + S, Cz); rlVertex3f(Cx - S, Cy, Cz); rlVertex3f(Cx, Cy, Cz + S);
        rlVertex3f(Cx, Cy + S, Cz); rlVertex3f(Cx + S, Cy, Cz); rlVertex3f(Cx, Cy, Cz - S);
        rlVertex3f(Cx, Cy + S, Cz); rlVertex3f(Cx, Cy, Cz - S); rlVertex3f(Cx - S, Cy, Cz);
        rlVertex3f(Cx, Cy - S, Cz); rlVertex3f(Cx + S, Cy, Cz); rlVertex3f(Cx, Cy, Cz + S);
        rlVertex3f(Cx, Cy - S, Cz); rlVertex3f(Cx, Cy, Cz + S); rlVertex3f(Cx - S, Cy, Cz);
        rlVertex3f(Cx, Cy - S, Cz); rlVertex3f(Cx - S, Cy, Cz); rlVertex3f(Cx, Cy, Cz - S);
        rlVertex3f(Cx, Cy - S, Cz); rlVertex3f(Cx, Cy, Cz - S); rlVertex3f(Cx + S, Cy, Cz);
      end;
    finally
      rlEnd();
    end;
    rlDrawRenderBatchActive();
    rlSetBlendMode(BLEND_ALPHA);
  finally
    FLock.Leave;
  end;
end;
end.
