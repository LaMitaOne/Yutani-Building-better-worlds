unit Yutani.Worlds.Space;

{==============================================================================*
 *  Yutani World: Space - Infinite Procedural Cosmos
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    A real, infinite, procedural cosmos that replaces the static space skybox.
 *    Features glowing 4-pointed star sprites, circular nebula billboards,
 *    Skia-generated procedural planet textures on 3D spheres, comets with
 *    massive flame particle trails, and chunk-based procedural generation
 *    for endless exploration with no visible boundary.
 *
 *  Architecture:
 *    1. Distant Star Shell: Background stars on a sphere around the camera.
 *    2. Near Star Chunks: World-space stars with parallax (chunk-grid system).
 *    3. Nebula Clouds: Circular gradient billboards (no hard rectangle edges).
 *    4. Planets: 3D textured spheres (Skia-generated textures, 60-200 radius).
 *    5. Comet System: Flame particle trails (white-hot to dark red gradient).
 *
 *  License: Apache-2.0
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Classes, System.Math, Raylib, RayMath, rlgl,
  Yutani.Worlds.Space.Textures;

type
  TSpaceStar = record
    Dir: TVector3;
    Size: Single;
    Brightness: Single;
    TwinklePhase: Single;
    TwinkleSpeed: Single;
    ColorTint: Byte;
  end;

  TNearStar = record
    Position: TVector3;
    Size: Single;
    Brightness: Single;
    TwinklePhase: Single;
    TwinkleSpeed: Single;
    ColorTint: Byte;
  end;

  TNebula = record
    Position: TVector3;
    Size: Single;
    Color: TColorB;
  end;

  TSpacePlanet = record
    Position: TVector3;
    Radius: Single;
    PlanetType: Integer;
    PlanetColor: TColorB;
    AtmosphereColor: TColorB;
    HasAtmosphere: Boolean;
  end;

  TSpaceComet = record
    Position: TVector3;
    Velocity: TVector3;
    Life: Single;
    MaxLife: Single;
    Size: Single;
    Color: TColorB;
    ParticleTimer: Single;
  end;

  TCometParticle = record
    Position: TVector3;
    Velocity: TVector3;
    Life: Single;
    MaxLife: Single;
    Size: Single;
    Active: Boolean;
  end;

  TSpaceWorld = class
  private
    FDistantStars: array of TSpaceStar;
    FNearStars: array of TNearStar;
    FNebulae: array of TNebula;
    FPlanets: array of TSpacePlanet;
    FComets: array of TSpaceComet;
    FCometParticles: array of TCometParticle;
    FPlanetTextures: array[0..4] of TTexture2D;
    FPlanetModels: array[0..4] of TModel;
    FCameraPos: TVector3;
    FLastChunkX: Integer;
    FLastChunkY: Integer;
    FLastChunkZ: Integer;
    FSpawnTimer: Single;
    FTime: Single;
    FRngState: Cardinal;

    procedure InitializeDistantStars;
    procedure SpawnStarterPlanets;
    procedure RegenerateNearContent(const CameraPos: TVector3);
    procedure UpdateComets(const dt: Single; const CameraPos: TVector3);
    procedure SpawnComet(const CameraPos: TVector3);
    procedure SpawnCometParticle(const Pos, Vel: TVector3; Size: Single);
    procedure UpdateCometParticles(const dt: Single);
    procedure RenderDistantStars(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderNearStars(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderNebulae(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderPlanets(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderCometParticles(const CamRight, CamUp: TVector3);
    procedure RenderComets;
    procedure DrawStarSprite(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
    procedure DrawCircularBillboard(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
    procedure GeneratePlanetAssets;
    procedure DestroyPlanetAssets;
    function GetStarColor(Tint: Byte; Alpha: Byte): TColorB;
    function HashChunk(cx, cy, cz: Integer): Cardinal;
    procedure SeedRand(Seed: Cardinal);
    function NextRand: Single;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Update(const dt: Single; const CameraPos: TVector3);
    procedure Render(const Camera: TCamera3D);
  end;

implementation

const
  DISTANT_STAR_COUNT = 2500;
  CHUNK_SIZE = 400.0;
  CHUNK_RADIUS = 2;
  NEAR_STARS_PER_CHUNK = 8;
  NEBULA_CHANCE = 0.20;
  PLANET_CHANCE = 0.03;
  COMET_SHELL_RADIUS = 500.0;
  MAX_COMETS = 8;
  NEBULA_BASE_SIZE = 80.0;
  DISTANT_SHELL_RADIUS = 950.0;
  FADE_START_DIST = 700.0;
  FADE_END_DIST = 940.0;
  MAX_COMET_PARTICLES = 10000;
  COMET_PARTICLE_RATE = 7;
  PLANET_MIN_RADIUS = 60.0;
  PLANET_MAX_RADIUS = 200.0;

function MakeCol(r, g, b: Byte): TColorB;
begin
  Result.r := r;
  Result.g := g;
  Result.b := b;
  Result.a := 255;
end;

{ TSpaceWorld }

constructor TSpaceWorld.Create;
begin
  inherited Create;
  FCameraPos := Vector3Create(0, 0, 0);
  FLastChunkX := 999999;
  FLastChunkY := 999999;
  FLastChunkZ := 999999;
  FSpawnTimer := 2.0;
  FTime := 0;
  FRngState := 42;
  SetLength(FDistantStars, DISTANT_STAR_COUNT);
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);
  SetLength(FPlanets, 0);
  SetLength(FComets, 0);
  SetLength(FCometParticles, MAX_COMET_PARTICLES);
  Randomize;
  InitializeDistantStars;
  GeneratePlanetAssets;
  SpawnStarterPlanets;
end;

destructor TSpaceWorld.Destroy;
begin
  DestroyPlanetAssets;
  SetLength(FDistantStars, 0);
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);
  SetLength(FPlanets, 0);
  SetLength(FComets, 0);
  SetLength(FCometParticles, 0);
  inherited;
end;

procedure TSpaceWorld.SeedRand(Seed: Cardinal);
begin
  if Seed = 0 then
    Seed := 1;
  FRngState := Seed;
end;

function TSpaceWorld.NextRand: Single;
begin
  FRngState := FRngState xor (FRngState shl 13);
  FRngState := FRngState xor (FRngState shr 17);
  FRngState := FRngState xor (FRngState shl 5);
  Result := (FRngState and $00FFFFFF) / $00FFFFFF;
end;

function TSpaceWorld.HashChunk(cx, cy, cz: Integer): Cardinal;
var
  h: Cardinal;
begin
  h := Cardinal(cx) * 73856093;
  h := h xor (Cardinal(cy) * 19349663);
  h := h xor (Cardinal(cz) * 83492767);
  h := h xor (h shr 13);
  h := h * 1274126177;
  h := h xor (h shr 16);
  Result := h;
end;

function TSpaceWorld.GetStarColor(Tint: Byte; Alpha: Byte): TColorB;
begin
  case Tint of
    0:
      Result := ColorAlpha(WHITE, Alpha);
    1:
      Result := ColorAlpha(SKYBLUE, Alpha);
    2:
      Result := ColorAlpha(Fade(RED, 0.8), Alpha);
    3:
      Result := ColorAlpha(Fade(YELLOW, 0.9), Alpha);
  else
    Result := ColorAlpha(WHITE, Alpha);
  end;
end;

{==============================================================================*
 *  STAR SPRITE: 4-pointed gradient billboard (bright center -> transparent edges)
 *==============================================================================}
procedure TSpaceWorld.DrawStarSprite(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
var
  H: Single;
  TopV, RightV, BottomV, LeftV: TVector3;
begin
  H := Size * 0.5;
  TopV := Vector3Add(Pos, Vector3Scale(CamUp, H));
  RightV := Vector3Add(Pos, Vector3Scale(CamRight, H));
  BottomV := Vector3Subtract(Pos, Vector3Scale(CamUp, H));
  LeftV := Vector3Subtract(Pos, Vector3Scale(CamRight, H));

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(TopV.x, TopV.y, TopV.z);
  rlVertex3f(RightV.x, RightV.y, RightV.z);

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(RightV.x, RightV.y, RightV.z);
  rlVertex3f(BottomV.x, BottomV.y, BottomV.z);

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(BottomV.x, BottomV.y, BottomV.z);
  rlVertex3f(LeftV.x, LeftV.y, LeftV.z);

  rlColor4ub(Col.r, Col.g, Col.b, Alpha);
  rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);
  rlVertex3f(LeftV.x, LeftV.y, LeftV.z);
  rlVertex3f(TopV.x, TopV.y, TopV.z);
end;

{==============================================================================*
 *  CIRCULAR BILLBOARD: 8-triangle circle with gradient (for nebulae + atmospheres)
 *  Eliminates hard rectangle edges by fading from center to transparent rim.
 *==============================================================================}
procedure TSpaceWorld.DrawCircularBillboard(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
var
  i: Integer;
  H, Angle, NextAngle: Single;
  Ex, Ey, Ez, Nx, Ny, Nz: Single;
  EdgeX, EdgeY, NextEdgeX, NextEdgeY: Single;
begin
  H := Size * 0.5;
  for i := 0 to 7 do
  begin
    Angle := (i / 8.0) * 2.0 * PI;
    NextAngle := ((i + 1) / 8.0) * 2.0 * PI;
    EdgeX := Cos(Angle) * H;
    EdgeY := Sin(Angle) * H;
    NextEdgeX := Cos(NextAngle) * H;
    NextEdgeY := Sin(NextAngle) * H;
    Ex := Pos.x + CamRight.x * EdgeX + CamUp.x * EdgeY;
    Ey := Pos.y + CamRight.y * EdgeX + CamUp.y * EdgeY;
    Ez := Pos.z + CamRight.z * EdgeX + CamUp.z * EdgeY;
    Nx := Pos.x + CamRight.x * NextEdgeX + CamUp.x * NextEdgeY;
    Ny := Pos.y + CamRight.y * NextEdgeX + CamUp.y * NextEdgeY;
    Nz := Pos.z + CamRight.z * NextEdgeX + CamUp.z * NextEdgeY;

    rlColor4ub(Col.r, Col.g, Col.b, Alpha);
    rlVertex3f(Pos.x, Pos.y, Pos.z);
    rlColor4ub(Col.r, Col.g, Col.b, 0);
    rlVertex3f(Ex, Ey, Ez);
    rlVertex3f(Nx, Ny, Nz);
  end;
end;

{==============================================================================*
 *  PLANET ASSET GENERATION (Skia textures + sphere models)
 *==============================================================================}
procedure TSpaceWorld.GeneratePlanetAssets;
var
  i: Integer;
  Mesh: TMesh;
begin
  for i := 0 to 4 do
  begin
    FPlanetTextures[i] := TPlanetTextureGen.Generate(i, Cardinal(Random(MaxInt)));
    if FPlanetTextures[i].id > 0 then
    begin
      SetTextureFilter(FPlanetTextures[i], TEXTURE_FILTER_TRILINEAR);
      GenTextureMipmaps(@FPlanetTextures[i]);
    end;
    Mesh := GenMeshSphere(1.0, 48, 32);
    UploadMesh(@Mesh, False);
    FPlanetModels[i] := LoadModelFromMesh(Mesh);
    FPlanetModels[i].materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FPlanetTextures[i];
  end;
end;

procedure TSpaceWorld.DestroyPlanetAssets;
var
  i: Integer;
begin
  for i := 0 to 4 do
  begin
    if FPlanetTextures[i].id > 0 then
      UnloadTexture(FPlanetTextures[i]);
    if FPlanetModels[i].meshes <> nil then
      UnloadModel(FPlanetModels[i]);
  end;
end;

{==============================================================================*
 *  STARTER PLANETS — One of each type spread out in a comfortable home system.
 *  Far enough that you need to fly a bit, close enough to find them easily.
 *==============================================================================}
procedure TSpaceWorld.SpawnStarterPlanets;
var
  i, idx: Integer;
  Angle, Dist: Single;
  Pos: TVector3;
begin
  // 5 planets in a wide ring around origin — spaced out like a real system
  Dist := 1200.0; // Comfortable cruise distance between planets
  for i := 0 to 4 do
  begin
    Angle := (i / 5.0) * 2.0 * PI;
    // Spread them in a ring at different heights for visual variety
    Pos := Vector3Create(Cos(Angle) * Dist, Sin(Angle * 1.7) * 150.0,  // Slight vertical variation
      Sin(Angle) * Dist);

    idx := Length(FPlanets);
    SetLength(FPlanets, idx + 1);
    FPlanets[idx].Position := Pos;
    FPlanets[idx].Radius := 90.0 + i * 30.0; // 90, 120, 150, 180, 210
    FPlanets[idx].PlanetType := i;

    case i of
      0:
        begin
          FPlanets[idx].PlanetColor := MakeCol(140, 120, 100);
          FPlanets[idx].AtmosphereColor := MakeCol(100, 80, 60);
          FPlanets[idx].HasAtmosphere := False;
        end;
      1:
        begin
          FPlanets[idx].PlanetColor := MakeCol(40, 100, 160);
          FPlanets[idx].AtmosphereColor := MakeCol(100, 150, 255);
          FPlanets[idx].HasAtmosphere := True;
        end;
      2:
        begin
          FPlanets[idx].PlanetColor := MakeCol(180, 80, 40);
          FPlanets[idx].AtmosphereColor := MakeCol(200, 100, 50);
          FPlanets[idx].HasAtmosphere := True;
        end;
      3:
        begin
          FPlanets[idx].PlanetColor := MakeCol(200, 160, 100);
          FPlanets[idx].AtmosphereColor := MakeCol(255, 200, 150);
          FPlanets[idx].HasAtmosphere := True;
        end;
      4:
        begin
          FPlanets[idx].PlanetColor := MakeCol(200, 220, 240);
          FPlanets[idx].AtmosphereColor := MakeCol(180, 210, 255);
          FPlanets[idx].HasAtmosphere := True;
        end;
    end;
  end;
end;

{==============================================================================*
 *  CHUNK GENERATION
 *==============================================================================}
procedure TSpaceWorld.InitializeDistantStars;
var
  i: Integer;
  theta, phi: Single;
  St: ^TSpaceStar;
begin
  SeedRand(98765);
  for i := 0 to High(FDistantStars) do
  begin
    St := @FDistantStars[i];
    theta := NextRand * 2.0 * PI;
    phi := ArcCos(NextRand * 2.0 - 1.0);
    St^.Dir := Vector3Create(Sin(phi) * Cos(theta), Sin(phi) * Sin(theta), Cos(phi));
    St^.Size := 10.0 + NextRand * NextRand * 30.0;
    St^.Brightness := 0.4 + NextRand * 0.6;
    St^.TwinklePhase := NextRand * 2.0 * PI;
    St^.TwinkleSpeed := 0.5 + NextRand * 2.5;
    St^.ColorTint := Trunc(NextRand * 4);
  end;
end;

procedure TSpaceWorld.RegenerateNearContent(const CameraPos: TVector3);
var
  cx, cy, cz, dx, dy, dz: Integer;
  ChunkOrigin: TVector3;
  i, StarCount, idx, PlanetType: Integer;
begin
  cx := Round(CameraPos.x / CHUNK_SIZE);
  cy := Round(CameraPos.y / CHUNK_SIZE);
  cz := Round(CameraPos.z / CHUNK_SIZE);
  FLastChunkX := cx;
  FLastChunkY := cy;
  FLastChunkZ := cz;
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);
  // NOTE: We do NOT clear FPlanets here — starter planets stay forever.
  // Chunk-generated planets are appended after starter planets.
  // To keep it simple: chunk planets replace themselves each regeneration.

  // Save starter planet count so we don't delete them
  var StarterCount: Integer;
  StarterCount := 0;
  // Starter planets are always the first 5 (index 0-4)
  // Only clear planets beyond the starter set
  while Length(FPlanets) > 5 do
  begin
    // Remove last element (chunk-generated planet)
    SetLength(FPlanets, Length(FPlanets) - 1);
  end;

  for dx := -CHUNK_RADIUS to CHUNK_RADIUS do
    for dy := -CHUNK_RADIUS to CHUNK_RADIUS do
      for dz := -CHUNK_RADIUS to CHUNK_RADIUS do
      begin
        var ccx := cx + dx;
        var ccy := cy + dy;
        var ccz := cz + dz;
        ChunkOrigin := Vector3Create(ccx * CHUNK_SIZE, ccy * CHUNK_SIZE, ccz * CHUNK_SIZE);

        // Near stars
        SeedRand(HashChunk(ccx, ccy, ccz));
        StarCount := Trunc(NextRand * NEAR_STARS_PER_CHUNK);
        for i := 0 to StarCount - 1 do
        begin
          idx := Length(FNearStars);
          SetLength(FNearStars, idx + 1);
          FNearStars[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE));
          FNearStars[idx].Size := 5.0 + NextRand * NextRand * 18.0;
          FNearStars[idx].Brightness := 0.5 + NextRand * 0.5;
          FNearStars[idx].TwinklePhase := NextRand * 2.0 * PI;
          FNearStars[idx].TwinkleSpeed := 0.3 + NextRand * 2.0;
          FNearStars[idx].ColorTint := Trunc(NextRand * 4);
        end;

        // Nebulae
        SeedRand(HashChunk(ccx, ccy, ccz) xor $FF00FF);
        if NextRand < NEBULA_CHANCE then
        begin
          idx := Length(FNebulae);
          SetLength(FNebulae, idx + 1);
          FNebulae[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE));
          FNebulae[idx].Size := NEBULA_BASE_SIZE * (0.3 + NextRand * 1.2);
          case Trunc(NextRand * 4) of
            0:
              FNebulae[idx].Color := ColorAlpha(PURPLE, 22);
            1:
              FNebulae[idx].Color := ColorAlpha(SKYBLUE, 22);
            2:
              FNebulae[idx].Color := ColorAlpha(Fade(ORANGE, 0.6), 22);
            3:
              FNebulae[idx].Color := ColorAlpha(Fade(GREEN, 0.5), 18);
          end;
        end;

        // Planets (procedural, chunk-based)
        SeedRand(HashChunk(ccx, ccy, ccz) xor $00FF00);
        if NextRand < PLANET_CHANCE then
        begin
          idx := Length(FPlanets);
          SetLength(FPlanets, idx + 1);
          FPlanets[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand - 0.5) * CHUNK_SIZE * 0.6, (NextRand - 0.5) * CHUNK_SIZE * 0.3, (NextRand - 0.5) * CHUNK_SIZE * 0.6));
          FPlanets[idx].Radius := PLANET_MIN_RADIUS + NextRand * (PLANET_MAX_RADIUS - PLANET_MIN_RADIUS);
          PlanetType := Trunc(NextRand * 5);
          FPlanets[idx].PlanetType := PlanetType;
          case PlanetType of
            0:
              begin
                FPlanets[idx].PlanetColor := MakeCol(140, 120, 100);
                FPlanets[idx].AtmosphereColor := MakeCol(100, 80, 60);
                FPlanets[idx].HasAtmosphere := False;
              end;
            1:
              begin
                FPlanets[idx].PlanetColor := MakeCol(40, 100, 160);
                FPlanets[idx].AtmosphereColor := MakeCol(100, 150, 255);
                FPlanets[idx].HasAtmosphere := True;
              end;
            2:
              begin
                FPlanets[idx].PlanetColor := MakeCol(180, 80, 40);
                FPlanets[idx].AtmosphereColor := MakeCol(200, 100, 50);
                FPlanets[idx].HasAtmosphere := True;
              end;
            3:
              begin
                FPlanets[idx].PlanetColor := MakeCol(200, 160, 100);
                FPlanets[idx].AtmosphereColor := MakeCol(255, 200, 150);
                FPlanets[idx].HasAtmosphere := True;
              end;
            4:
              begin
                FPlanets[idx].PlanetColor := MakeCol(200, 220, 240);
                FPlanets[idx].AtmosphereColor := MakeCol(180, 210, 255);
                FPlanets[idx].HasAtmosphere := True;
              end;
          end;
        end;
      end;
end;

{==============================================================================*
 *  COMET SYSTEM
 *==============================================================================}
procedure TSpaceWorld.SpawnComet(const CameraPos: TVector3);
var
  idx: Integer;
  theta, phi: Single;
  SpawnDir, TargetOffset: TVector3;
  C: ^TSpaceComet;
  Speed: Single;
begin
  if Length(FComets) >= MAX_COMETS then
    Exit;
  idx := Length(FComets);
  SetLength(FComets, idx + 1);
  C := @FComets[idx];
  theta := Random * 2.0 * PI;
  phi := ArcCos(Random * 2.0 - 1.0);
  SpawnDir := Vector3Create(Sin(phi) * Cos(theta), Sin(phi) * Sin(theta), Cos(phi));
  C^.Position := Vector3Add(CameraPos, Vector3Scale(SpawnDir, COMET_SHELL_RADIUS));
  TargetOffset := Vector3Create((Random - 0.5) * 200, (Random - 0.5) * 200, (Random - 0.5) * 200);
  C^.Velocity := Vector3Subtract(Vector3Add(CameraPos, TargetOffset), C^.Position);
  Speed := 40.0 + Random * 60.0;
  C^.Velocity := Vector3Scale(Vector3Normalize(C^.Velocity), Speed);
  C^.MaxLife := 15.0 + Random * 10.0;
  C^.Life := C^.MaxLife;
  C^.Size := 3.0 + Random * 4.0;
  C^.ParticleTimer := 0;
  if Random > 0.5 then
    C^.Color := ColorAlpha(SKYBLUE, 230)
  else
    C^.Color := ColorAlpha(Fade(ORANGE, 0.9), 230);
end;

procedure TSpaceWorld.SpawnCometParticle(const Pos, Vel: TVector3; Size: Single);
var
  i: Integer;
  Spread: TVector3;
begin
  for i := 0 to High(FCometParticles) do
  begin
    if not FCometParticles[i].Active then
    begin
      FCometParticles[i].Active := True;
      FCometParticles[i].Position := Vector3Add(Pos, Vector3Create((Random - 0.5) * 6, (Random - 0.5) * 6, (Random - 0.5) * 6));
      Spread := Vector3Create((Random - 0.5) * 15, (Random - 0.5) * 15, (Random - 0.5) * 15);
      FCometParticles[i].Velocity := Vector3Add(Vector3Scale(Vel, 0.1), Spread);
      FCometParticles[i].MaxLife := 0.6 + Random * 1.4;
      FCometParticles[i].Life := FCometParticles[i].MaxLife;
      FCometParticles[i].Size := Size * (0.5 + Random * 0.8);
      Exit;
    end;
  end;
end;

procedure TSpaceWorld.UpdateComets(const dt: Single; const CameraPos: TVector3);
var
  i, j: Integer;
  C: ^TSpaceComet;
  Dist: Single;
begin
  for i := High(FComets) downto 0 do
  begin
    C := @FComets[i];
    C^.Life := C^.Life - dt;
    C^.Position := Vector3Add(C^.Position, Vector3Scale(C^.Velocity, dt));
    C^.ParticleTimer := C^.ParticleTimer + dt;
    if C^.ParticleTimer >= 0.016 then
    begin
      C^.ParticleTimer := 0;
      for j := 0 to COMET_PARTICLE_RATE - 1 do
        SpawnCometParticle(C^.Position, C^.Velocity, C^.Size);
    end;
    Dist := Vector3Distance(C^.Position, CameraPos);
    if (C^.Life <= 0) or (Dist > COMET_SHELL_RADIUS * 1.8) then
    begin
      if i < High(FComets) then
        FComets[i] := FComets[High(FComets)];
      SetLength(FComets, Length(FComets) - 1);
    end;
  end;
end;

procedure TSpaceWorld.UpdateCometParticles(const dt: Single);
var
  i: Integer;
  P: ^TCometParticle;
begin
  for i := 0 to High(FCometParticles) do
  begin
    if not FCometParticles[i].Active then
      Continue;
    P := @FCometParticles[i];
    P^.Life := P^.Life - dt;
    if P^.Life <= 0 then
    begin
      P^.Active := False;
      Continue;
    end;
    P^.Velocity := Vector3Scale(P^.Velocity, 1.0 - 0.5 * dt);
    P^.Position := Vector3Add(P^.Position, Vector3Scale(P^.Velocity, dt));
  end;
end;

procedure TSpaceWorld.Update(const dt: Single; const CameraPos: TVector3);
var
  cx, cy, cz: Integer;
begin
  FTime := FTime + dt;
  FCameraPos := CameraPos;
  cx := Round(CameraPos.x / CHUNK_SIZE);
  cy := Round(CameraPos.y / CHUNK_SIZE);
  cz := Round(CameraPos.z / CHUNK_SIZE);
  if (cx <> FLastChunkX) or (cy <> FLastChunkY) or (cz <> FLastChunkZ) then
    RegenerateNearContent(CameraPos);
  FSpawnTimer := FSpawnTimer - dt;
  if FSpawnTimer <= 0 then
  begin
    SpawnComet(CameraPos);
    FSpawnTimer := 1.5 + Random * 3.5;
  end;
  UpdateComets(dt, CameraPos);
  UpdateCometParticles(dt);
end;

{==============================================================================*
 *  RENDERERS
 *==============================================================================}
procedure TSpaceWorld.RenderDistantStars(const CameraPos, CamRight, CamUp: TVector3);
var
  i: Integer;
  St: ^TSpaceStar;
  Pos: TVector3;
  Twinkle, AlphaF: Single;
  AlphaB: Byte;
  Col: TColorB;
begin
  rlDisableDepthTest;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FDistantStars) do
    begin
      St := @FDistantStars[i];
      Pos := Vector3Add(CameraPos, Vector3Scale(St^.Dir, DISTANT_SHELL_RADIUS));
      Twinkle := 0.6 + 0.4 * Sin(FTime * St^.TwinkleSpeed + St^.TwinklePhase);
      AlphaF := St^.Brightness * Twinkle;
      AlphaB := Trunc(EnsureRange(AlphaF * 255, 0, 255));
      Col := GetStarColor(St^.ColorTint, 255);
      DrawStarSprite(Pos, CamRight, CamUp, St^.Size * 2.5, Col, Trunc(AlphaB * 0.15));
      DrawStarSprite(Pos, CamRight, CamUp, St^.Size, Col, AlphaB);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
  rlEnableDepthTest;
end;

procedure TSpaceWorld.RenderNearStars(const CameraPos, CamRight, CamUp: TVector3);
var
  i: Integer;
  St: ^TNearStar;
  Pos: TVector3;
  Twinkle, AlphaF, Dist, FadeF: Single;
  AlphaB: Byte;
  Col: TColorB;
begin
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FNearStars) do
    begin
      St := @FNearStars[i];
      Pos := St^.Position;
      Dist := Vector3Distance(Pos, CameraPos);
      if Dist > FADE_END_DIST then
        Continue;
      if Dist > FADE_START_DIST then
        FadeF := 1.0 - ((Dist - FADE_START_DIST) / (FADE_END_DIST - FADE_START_DIST))
      else
        FadeF := 1.0;
      Twinkle := 0.6 + 0.4 * Sin(FTime * St^.TwinkleSpeed + St^.TwinklePhase);
      AlphaF := St^.Brightness * Twinkle * FadeF;
      AlphaB := Trunc(EnsureRange(AlphaF * 255, 0, 255));
      Col := GetStarColor(St^.ColorTint, 255);
      DrawStarSprite(Pos, CamRight, CamUp, St^.Size * 2.5, Col, Trunc(AlphaB * 0.15));
      DrawStarSprite(Pos, CamRight, CamUp, St^.Size, Col, AlphaB);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
end;

procedure TSpaceWorld.RenderNebulae(const CameraPos, CamRight, CamUp: TVector3);
var
  i: Integer;
  Nb: ^TNebula;
  Pos: TVector3;
  Dist, FadeF: Single;
  AlphaB: Byte;
begin
  rlDisableDepthTest;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FNebulae) do
    begin
      Nb := @FNebulae[i];
      Pos := Nb^.Position;
      Dist := Vector3Distance(Pos, CameraPos);
      if (Dist > FADE_END_DIST) or (Dist < 50.0) then
        Continue;
      if Dist > FADE_START_DIST then
        FadeF := 1.0 - ((Dist - FADE_START_DIST) / (FADE_END_DIST - FADE_START_DIST))
      else
        FadeF := 1.0;
      if Dist < 150.0 then
        FadeF := FadeF * (Dist - 50.0) / 100.0;
      AlphaB := Trunc(EnsureRange(Nb^.Color.a * FadeF, 0, 255));
      DrawCircularBillboard(Pos, CamRight, CamUp, Nb^.Size, Nb^.Color, AlphaB);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
  rlEnableDepthTest;
end;

procedure TSpaceWorld.RenderPlanets(const CameraPos, CamRight, CamUp: TVector3);
var
  i: Integer;
  P: ^TSpacePlanet;
begin
  // Phase 1: Atmosphere glow (circular billboards with gradient — no hard rectangles)
  rlDisableDepthTest;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FPlanets) do
    begin
      P := @FPlanets[i];
      if not P^.HasAtmosphere then
        Continue;
      // NO distance culling — planets always visible
      // Two-layer atmosphere: tight inner glow + wide outer glow
      DrawCircularBillboard(P^.Position, CamRight, CamUp, P^.Radius * 1.5, P^.AtmosphereColor, 55);
      DrawCircularBillboard(P^.Position, CamRight, CamUp, P^.Radius * 2.5, P^.AtmosphereColor, 20);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
  rlEnableDepthTest;

  // Phase 2: Planet bodies (textured 3D spheres, depth write ON)
  rlDrawRenderBatchActive;
  rlEnableDepthMask;
  rlEnableDepthTest;
  for i := 0 to High(FPlanets) do
  begin
    P := @FPlanets[i];
    // NO distance culling — planets always visible
    if P^.PlanetType < 0 then
      P^.PlanetType := 0;
    if P^.PlanetType > 4 then
      P^.PlanetType := 4;
    if FPlanetModels[P^.PlanetType].meshes <> nil then
      DrawModel(FPlanetModels[P^.PlanetType], P^.Position, P^.Radius, WHITE)
    else
      DrawSphere(P^.Position, P^.Radius, P^.PlanetColor);
  end;
  rlDrawRenderBatchActive;
  rlDisableDepthMask;
end;

procedure TSpaceWorld.RenderCometParticles(const CamRight, CamUp: TVector3);
var
  i: Integer;
  P: ^TCometParticle;
  Progress, AlphaF: Single;
  AlphaB: Byte;
  R, G, B: Byte;
  HalfSize: Single;
  RX, RY, RZ, UX, UY, UZ: Single;
  Px, Py, Pz: Single;
begin
  RX := CamRight.x;
  RY := CamRight.y;
  RZ := CamRight.z;
  UX := CamUp.x;
  UY := CamUp.y;
  UZ := CamUp.z;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FCometParticles) do
    begin
      if not FCometParticles[i].Active then
        Continue;
      P := @FCometParticles[i];
      Progress := 1.0 - (P^.Life / P^.MaxLife);
      if Progress < 0.2 then
      begin
        R := 255;
        G := 255;
        B := Round(Lerp(255, 180, Progress / 0.2));
      end
      else if Progress < 0.5 then
      begin
        var t := (Progress - 0.2) / 0.3;
        R := 255;
        G := Round(Lerp(255, 120, t));
        B := Round(Lerp(180, 40, t));
      end
      else
      begin
        var t := (Progress - 0.5) / 0.5;
        R := Round(Lerp(255, 60, t));
        G := Round(Lerp(120, 10, t));
        B := Round(Lerp(40, 5, t));
      end;
      AlphaF := (1.0 - Progress) * 0.8;
      AlphaB := Trunc(EnsureRange(AlphaF * 255, 0, 255));
      HalfSize := (P^.Size * (1.0 - Progress * 0.6)) * 0.5;
      Px := P^.Position.x;
      Py := P^.Position.y;
      Pz := P^.Position.z;
      rlColor4ub(R, G, B, AlphaB);
      rlVertex3f(Px - RX * HalfSize + UX * HalfSize, Py - RY * HalfSize + UY * HalfSize, Pz - RZ * HalfSize + UZ * HalfSize);
      rlVertex3f(Px + RX * HalfSize + UX * HalfSize, Py + RY * HalfSize + UY * HalfSize, Pz + RZ * HalfSize + UZ * HalfSize);
      rlVertex3f(Px + RX * HalfSize - UX * HalfSize, Py + RY * HalfSize - UY * HalfSize, Pz + RZ * HalfSize - UZ * HalfSize);
      rlVertex3f(Px - RX * HalfSize + UX * HalfSize, Py - RY * HalfSize + UY * HalfSize, Pz - RZ * HalfSize + UZ * HalfSize);
      rlVertex3f(Px + RX * HalfSize - UX * HalfSize, Py + RY * HalfSize - UY * HalfSize, Pz + RZ * HalfSize - UZ * HalfSize);
      rlVertex3f(Px - RX * HalfSize - UX * HalfSize, Py - RY * HalfSize - UY * HalfSize, Pz - RZ * HalfSize - UZ * HalfSize);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
end;

procedure TSpaceWorld.RenderComets;
var
  i: Integer;
  C: ^TSpaceComet;
  HeadSize: Single;
begin
  rlSetBlendMode(BLEND_ADDITIVE);
  for i := 0 to High(FComets) do
  begin
    C := @FComets[i];
    // Only the core sphere — flame particles do the rest
    HeadSize := C^.Size * 0.5;
    DrawSphere(C^.Position, HeadSize, C^.Color);
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
end;

procedure TSpaceWorld.Render(const Camera: TCamera3D);
var
  CamForward, CamRight, CamUp: TVector3;
  SpaceProj, NormalProj: TMatrix;
begin
  CamForward := Vector3Normalize(Vector3Subtract(Camera.target, Camera.position));
  CamRight := Vector3Normalize(Vector3CrossProduct(CamForward, Camera.up));
  CamUp := Vector3Normalize(Vector3CrossProduct(CamRight, CamForward));

  // Extend far plane to 10000 so distant planets don't vanish when zooming out
  SpaceProj := MatrixPerspective(Camera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 10000.0);
  rlSetMatrixProjection(SpaceProj);

  // Layer 1: Distant stars + Nebulae (background, depth OFF)
  RenderDistantStars(FCameraPos, CamRight, CamUp);
  RenderNebulae(FCameraPos, CamRight, CamUp);

  // Layer 2: Near stars (depth ON for proper occlusion)
  RenderNearStars(FCameraPos, CamRight, CamUp);

  // Layer 3: Planets (solid 3D textured spheres, depth ON)
  RenderPlanets(FCameraPos, CamRight, CamUp);

  // Layer 4: Comet flame particles (additive)
  RenderCometParticles(CamRight, CamUp);

  // Layer 5: Comet heads (additive glow spheres)
  RenderComets;

  // Restore normal far plane (1000) for subsequent scene rendering (actors etc.)
  NormalProj := MatrixPerspective(Camera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
  rlSetMatrixProjection(NormalProj);

  rlEnableDepthMask;
end;

end.

