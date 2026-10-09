unit Yutani.Worlds.Space;

{==============================================================================*
 *  Yutani World: Space - Infinite Procedural Cosmos
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
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
    OrbitSunIndex: Integer;
    OrbitRadius: Single;
    OrbitAngle: Single;
    OrbitSpeed: Single;
    IsMoon: Boolean;
    MoonAngle: Single;
    MoonSpeed: Single;
    MoonRadius: Single;
    ParentPlanetIndex: Integer;
    IsLocked: Boolean;
  end;

  TSun = record
    Position: TVector3;
    Radius: Single;
    Color: TColorB;
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
    FSuns: array of TSun;
    FComets: array of TSpaceComet;
    FCometParticles: array of TCometParticle;
    FPlanetTextures: array[0..4] of TTexture2D;
    FPlanetModels: array[0..4] of TModel;
    FCameraPos: TVector3;
    FLastChunkX, FLastChunkY, FLastChunkZ: Integer;
    FSpawnTimer: Single;
    FTime: Single;
    FRngState: Cardinal;
    FTimeScale: Single;
    FIsLanded: Boolean;
    FOriginOffset: TVector3;

    procedure InitializeDistantStars;
    procedure SpawnStarterPlanets;
    procedure RegenerateNearContent(const CameraPos: TVector3);
    procedure UpdateOrbits(const dt: Single);
    procedure UpdateComets(const dt: Single; const CameraPos: TVector3);
    procedure SpawnComet(const CameraPos: TVector3);
    procedure SpawnCometParticle(const Pos, Vel: TVector3; Size: Single);
    procedure UpdateCometParticles(const dt: Single);
    procedure CheckCometCollisions;
    procedure RenderDistantStars(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderNearStars(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderNebulae(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderSuns;
    procedure RenderPlanets(const CameraPos, CamRight, CamUp: TVector3);
    procedure RenderCometParticles(const CamRight, CamUp: TVector3);
    procedure RenderComets;
    procedure DrawStarSprite(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
    procedure DrawCircularBillboard(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
    procedure GeneratePlanetAssets(const ALightShader: TShader);
    procedure DestroyPlanetAssets;
    procedure SetupPlanetLighting(const CameraPos: TVector3);
    function GetStarColor(Tint: Byte; Alpha: Byte): TColorB;
    function HashChunk(cx, cy, cz: Integer): Cardinal;
    procedure SeedRand(Seed: Cardinal);
    function NextRand: Single;
  public
    FLandingTargetIndex: Integer;
    constructor Create(const ALightShader: TShader);
    destructor Destroy; override;
    procedure Update(const dt: Single; const CameraPos: TVector3; const TimeScale: Single = 1.0);
    procedure Render(const Camera: TCamera3D);
    procedure RenderShadows;

    procedure InitiateLanding(const TargetIndex: Integer; var CameraTarget: TVector3; var CameraPos: TVector3);
    procedure ReleaseLanding;
    function FindNearestPlanet(const CameraPos: TVector3; out OutIndex: Integer; out OutDistance: Single): Boolean;
    function IsLanded: Boolean;
    function GetLandedPlanetPos: TVector3;
    function GetLandedPlanetRadius: Single;
    procedure GetPlanetInfo(const Index: Integer; out OutPos: TVector3; out OutRadius: Single);
  end;

implementation

const
  DISTANT_STAR_COUNT   = 3000;
  CHUNK_SIZE           = 2000.0;
  CHUNK_RADIUS         = 1;
  STAR_CLUSTER_CHANCE  = 0.6;
  NEBULA_CHANCE        = 0.08;
  SUN_CHANCE           = 0.04;
  COMET_SHELL_RADIUS   = 500.0;
  MAX_COMETS           = 8;
  NEBULA_BASE_SIZE     = 150.0;
  DISTANT_SHELL_RADIUS = 950.0;
  FADE_START_DIST      = 700.0;
  FADE_END_DIST        = 940.0;
  MAX_COMET_PARTICLES  = 10000;
  COMET_PARTICLE_RATE  = 7;
  PLANET_MIN_RADIUS    = 60.0;
  PLANET_MAX_RADIUS    = 180.0;

function MakeCol(r, g, b: Byte): TColorB;
begin
  Result.r := r; Result.g := g; Result.b := b; Result.a := 255;
end;

{ TSpaceWorld }

constructor TSpaceWorld.Create(const ALightShader: TShader);
begin
  inherited Create;
  FCameraPos := Vector3Create(0, 0, 0);
  FLastChunkX := 999999;
  FSpawnTimer := 2.0;
  FTime := 0;
  FRngState := 42;
  FTimeScale := 1.0;
  FIsLanded := False;
  FLandingTargetIndex := -1;
  FOriginOffset := Vector3Create(0, 0, 0);
  SetLength(FDistantStars, DISTANT_STAR_COUNT);
  SetLength(FCometParticles, MAX_COMET_PARTICLES);
  Randomize;
  InitializeDistantStars;
  GeneratePlanetAssets(ALightShader);
  SpawnStarterPlanets;
end;

destructor TSpaceWorld.Destroy;
begin
  DestroyPlanetAssets;
  SetLength(FDistantStars, 0);
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);
  SetLength(FPlanets, 0);
  SetLength(FSuns, 0);
  SetLength(FComets, 0);
  SetLength(FCometParticles, 0);
  inherited;
end;

procedure TSpaceWorld.SeedRand(Seed: Cardinal);
begin
  if Seed = 0 then Seed := 1;
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
var h: Cardinal;
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
    0: Result := ColorAlpha(WHITE, Alpha);
    1: Result := ColorAlpha(Fade(BLUE, 0.8), Alpha);
    2: Result := ColorAlpha(Fade(ORANGE, 0.9), Alpha);
    3: Result := ColorAlpha(Fade(RED, 0.8), Alpha);
  else
    Result := ColorAlpha(WHITE, Alpha);
  end;
end;

{==============================================================================*
 *  STAR SPRITE & CIRCULAR BILLBOARD
 *==============================================================================}
procedure TSpaceWorld.DrawStarSprite(const Pos, CamRight, CamUp: TVector3; Size: Single; Col: TColorB; Alpha: Byte);
var
  H: Single;
  TopV, RightV, BottomV, LeftV: TVector3;
begin
  H := Size * 0.5;
  TopV    := Vector3Add(Pos, Vector3Scale(CamUp, H));
  RightV  := Vector3Add(Pos, Vector3Scale(CamRight, H));
  BottomV := Vector3Subtract(Pos, Vector3Scale(CamUp, H));
  LeftV   := Vector3Subtract(Pos, Vector3Scale(CamRight, H));

  rlColor4ub(Col.r, Col.g, Col.b, Alpha); rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);     rlVertex3f(TopV.x, TopV.y, TopV.z); rlVertex3f(RightV.x, RightV.y, RightV.z);
  rlColor4ub(Col.r, Col.g, Col.b, Alpha); rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);     rlVertex3f(RightV.x, RightV.y, RightV.z); rlVertex3f(BottomV.x, BottomV.y, BottomV.z);
  rlColor4ub(Col.r, Col.g, Col.b, Alpha); rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);     rlVertex3f(BottomV.x, BottomV.y, BottomV.z); rlVertex3f(LeftV.x, LeftV.y, LeftV.z);
  rlColor4ub(Col.r, Col.g, Col.b, Alpha); rlVertex3f(Pos.x, Pos.y, Pos.z);
  rlColor4ub(Col.r, Col.g, Col.b, 0);     rlVertex3f(LeftV.x, LeftV.y, LeftV.z); rlVertex3f(TopV.x, TopV.y, TopV.z);
end;

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
    EdgeX := Cos(Angle) * H; EdgeY := Sin(Angle) * H;
    NextEdgeX := Cos(NextAngle) * H; NextEdgeY := Sin(NextAngle) * H;
    Ex := Pos.x + CamRight.x * EdgeX + CamUp.x * EdgeY;
    Ey := Pos.y + CamRight.y * EdgeX + CamUp.y * EdgeY;
    Ez := Pos.z + CamRight.z * EdgeX + CamUp.z * EdgeY;
    Nx := Pos.x + CamRight.x * NextEdgeX + CamUp.x * NextEdgeY;
    Ny := Pos.y + CamRight.y * NextEdgeX + CamUp.y * NextEdgeY;
    Nz := Pos.z + CamRight.z * NextEdgeX + CamUp.z * NextEdgeY;

    rlColor4ub(Col.r, Col.g, Col.b, Alpha); rlVertex3f(Pos.x, Pos.y, Pos.z);
    rlColor4ub(Col.r, Col.g, Col.b, 0);     rlVertex3f(Ex, Ey, Ez); rlVertex3f(Nx, Ny, Nz);
  end;
end;

{==============================================================================*
 *  PLANET ASSETS & LIGHTING
 *==============================================================================}
procedure TSpaceWorld.GeneratePlanetAssets(const ALightShader: TShader);
var
  i: Integer;
  Mesh: TMesh;
begin
  for i := 0 to 4 do
  begin
    FPlanetTextures[i] := TPlanetTextureGen.Generate(i, Cardinal(Random(MaxInt)), 2048);
    if FPlanetTextures[i].id > 0 then
    begin
      SetTextureFilter(FPlanetTextures[i], TEXTURE_FILTER_TRILINEAR);
      SetTextureWrap(FPlanetTextures[i], TEXTURE_WRAP_REPEAT);
      GenTextureMipmaps(@FPlanetTextures[i]);
    end;
    Mesh := GenMeshSphere(1.0, 48, 32);
    UploadMesh(@Mesh, False);
    FPlanetModels[i] := LoadModelFromMesh(Mesh);
    FPlanetModels[i].materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FPlanetTextures[i];
    if ALightShader.id > 0 then
      FPlanetModels[i].materials[0].shader := ALightShader;
  end;
end;

procedure TSpaceWorld.DestroyPlanetAssets;
var
  i: Integer;
begin
  for i := 0 to 4 do
  begin
    if FPlanetTextures[i].id > 0 then UnloadTexture(FPlanetTextures[i]);
    if FPlanetModels[i].meshes <> nil then UnloadModel(FPlanetModels[i]);
  end;
end;

procedure TSpaceWorld.SetupPlanetLighting(const CameraPos: TVector3);
var
  NearestSun: TSun;
  NearestDist, Dist: Single;
  i: Integer;
  LightPosArr: array[0..2] of Single;
  ViewPosArr: array[0..2] of Single;
  Ambient: array[0..3] of Single;
  Diffuse: array[0..3] of Single;
  HasSun: Boolean;
  Radius: Single;
  RadiusArr: array[0..0] of Single;
  Shader: TShader;
begin
  if (Length(FSuns) = 0) or (Length(FPlanetModels) = 0) then Exit;
  if FPlanetModels[0].materials[0].shader.id = 0 then Exit;

  HasSun := False;
  NearestDist := 1e9;
  for i := 0 to High(FSuns) do
  begin
    Dist := Vector3Distance(FSuns[i].Position, CameraPos);
    if Dist < NearestDist then
    begin
      NearestDist := Dist;
      NearestSun := FSuns[i];
      HasSun := True;
    end;
  end;

  if not HasSun then Exit;

  LightPosArr[0] := NearestSun.Position.x;
  LightPosArr[1] := NearestSun.Position.y;
  LightPosArr[2] := NearestSun.Position.z;

  ViewPosArr[0] := CameraPos.x;
  ViewPosArr[1] := CameraPos.y;
  ViewPosArr[2] := CameraPos.z;

  // Higher ambient so the darkside is not pitch black
  Ambient[0] := 0.25; Ambient[1] := 0.25; Ambient[2] := 0.3; Ambient[3] := 1.0;

  // Very bright sun diffuse
  Diffuse[0] := 2.0; Diffuse[1] := 2.0; Diffuse[2] := 1.8; Diffuse[3] := 1.0;

  // Set the light radius VERY high so the sun reaches far planets
  Radius := 10000.0;
  RadiusArr[0] := Radius;

  for i := 0 to 4 do
  begin
    if FPlanetModels[i].meshes <> nil then
    begin
      // Get the TShader object directly from the material
      Shader := FPlanetModels[i].materials[0].shader;

      // Pass it to GetShaderLocation and SetShaderValue
      SetShaderValue(Shader, GetShaderLocation(Shader, 'lightPos'), @LightPosArr, SHADER_UNIFORM_VEC3);
      SetShaderValue(Shader, GetShaderLocation(Shader, 'viewPos'), @ViewPosArr, SHADER_UNIFORM_VEC3);
      SetShaderValue(Shader, GetShaderLocation(Shader, 'ambient'), @Ambient, SHADER_UNIFORM_VEC4);
      SetShaderValue(Shader, GetShaderLocation(Shader, 'diffuse'), @Diffuse, SHADER_UNIFORM_VEC4);
      SetShaderValue(Shader, GetShaderLocation(Shader, 'lightRadius'), @RadiusArr, SHADER_UNIFORM_FLOAT);
    end;
  end;
end;

{==============================================================================*
 *  STARTER PLANETS (Home Solar System) & CHUNK GEN
 *==============================================================================}
procedure TSpaceWorld.SpawnStarterPlanets;
var
  i, SunIdx, idx: Integer;
  OrbitR: Single;
  SystemOffset: TVector3;
begin
  // Home System is 600 units away so we don't spawn inside the sun, but it's still close
  SystemOffset := Vector3Create(600, 0, 600);

  // 1. Home Sun
  SunIdx := Length(FSuns);
  SetLength(FSuns, SunIdx + 1);
  FSuns[SunIdx].Position := SystemOffset;
  FSuns[SunIdx].Radius := 100.0;
  FSuns[SunIdx].Color := MakeCol(255, 220, 100);

  // 2. Home Planets
  OrbitR := 400.0; // Start closer to the sun
  for i := 0 to 4 do
  begin
    OrbitR := OrbitR + 200.0 + (i * 50.0); // Closer orbits
    idx := Length(FPlanets);
    SetLength(FPlanets, idx + 1);

    FPlanets[idx].OrbitSunIndex := SunIdx;
    FPlanets[idx].OrbitRadius := OrbitR;
    FPlanets[idx].OrbitAngle := (i / 5.0) * 2.0 * PI;
    FPlanets[idx].OrbitSpeed := (0.01 + (i * 0.003));
    FPlanets[idx].Radius := 80.0 + i * 25.0;
    FPlanets[idx].PlanetType := i;
    FPlanets[idx].IsMoon := False;
    FPlanets[idx].ParentPlanetIndex := -1;
    FPlanets[idx].IsLocked := False;

    case i of
      0: begin FPlanets[idx].PlanetColor := MakeCol(140,120,100); FPlanets[idx].AtmosphereColor := MakeCol(100,80,60); FPlanets[idx].HasAtmosphere := False; end;
      1: begin FPlanets[idx].PlanetColor := MakeCol(40,100,160); FPlanets[idx].AtmosphereColor := MakeCol(100,150,255); FPlanets[idx].HasAtmosphere := True; end;
      2: begin FPlanets[idx].PlanetColor := MakeCol(180,80,40); FPlanets[idx].AtmosphereColor := MakeCol(200,100,50); FPlanets[idx].HasAtmosphere := True; end;
      3: begin FPlanets[idx].PlanetColor := MakeCol(200,160,100); FPlanets[idx].AtmosphereColor := MakeCol(255,200,150); FPlanets[idx].HasAtmosphere := True; end;
      4: begin FPlanets[idx].PlanetColor := MakeCol(200,220,240); FPlanets[idx].AtmosphereColor := MakeCol(180,210,255); FPlanets[idx].HasAtmosphere := True; end;
    end;

    FPlanets[idx].Position := Vector3Add(FSuns[SunIdx].Position, Vector3Create(
      Cos(FPlanets[idx].OrbitAngle) * FPlanets[idx].OrbitRadius, 0,
      Sin(FPlanets[idx].OrbitAngle) * FPlanets[idx].OrbitRadius));
  end;
end;

procedure TSpaceWorld.RegenerateNearContent(const CameraPos: TVector3);
var
  cx, cy, cz, dx, dy, dz: Integer;
  ChunkOrigin: TVector3;
  i, j, idx, StarCount, SunIdx, PlanetCount, PlanetType, ClusterCount: Integer;
  OrbitR, SunRadius: Single;
  HasMoon: Boolean;
  ClusterCenter: TVector3;
begin
  cx := Round(CameraPos.x / CHUNK_SIZE);
  cy := Round(CameraPos.y / CHUNK_SIZE);
  cz := Round(CameraPos.z / CHUNK_SIZE);
  FLastChunkX := cx; FLastChunkY := cy; FLastChunkZ := cz;
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);

  // CRITICAL FIX: Properly clear all procedural stars and planets, keeping ONLY Home System (Index 0)
  SetLength(FSuns, 1);           // Keep only Home Sun at index 0
  SetLength(FPlanets, 5);        // Keep only 5 Home Planets at index 0..4

  for dx := -CHUNK_RADIUS to CHUNK_RADIUS do
    for dy := -CHUNK_RADIUS to CHUNK_RADIUS do
      for dz := -CHUNK_RADIUS to CHUNK_RADIUS do
      begin
        var ccx := cx + dx;
        var ccy := cy + dy;
        var ccz := cz + dz;
        ChunkOrigin := Vector3Create(ccx * CHUNK_SIZE, ccy * CHUNK_SIZE, ccz * CHUNK_SIZE);

        // DENSE STAR CLUSTERS
        SeedRand(HashChunk(ccx, ccy, ccz));
        if NextRand < STAR_CLUSTER_CHANCE then
        begin
          ClusterCenter := Vector3Add(ChunkOrigin, Vector3Create((NextRand-0.5)*CHUNK_SIZE, (NextRand-0.5)*CHUNK_SIZE, (NextRand-0.5)*CHUNK_SIZE));
          ClusterCount := 15 + Trunc(NextRand * 30);
          for i := 0 to ClusterCount - 1 do
          begin
            idx := Length(FNearStars);
            SetLength(FNearStars, idx + 1);
            FNearStars[idx].Position := Vector3Add(ClusterCenter, Vector3Create((NextRand-0.5)*400, (NextRand-0.5)*400, (NextRand-0.5)*400));
            FNearStars[idx].Size := 4.0 + NextRand * 12.0;
            FNearStars[idx].Brightness := 0.6 + NextRand * 0.4;
            FNearStars[idx].TwinklePhase := NextRand * 2.0 * PI;
            FNearStars[idx].TwinkleSpeed := 0.5 + NextRand * 2.5;
            FNearStars[idx].ColorTint := Trunc(NextRand * 4);
          end;
        end
        else
        begin
          StarCount := Trunc(NextRand * 3);
          for i := 0 to StarCount - 1 do
          begin
            idx := Length(FNearStars);
            SetLength(FNearStars, idx + 1);
            FNearStars[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand-0.5)*CHUNK_SIZE, (NextRand-0.5)*CHUNK_SIZE, (NextRand-0.5)*CHUNK_SIZE));
            FNearStars[idx].Size := 5.0 + NextRand * NextRand * 18.0;
            FNearStars[idx].Brightness := 0.5 + NextRand * 0.5;
            FNearStars[idx].TwinklePhase := NextRand * 2.0 * PI;
            FNearStars[idx].TwinkleSpeed := 0.3 + NextRand * 2.0;
            FNearStars[idx].ColorTint := Trunc(NextRand * 4);
          end;
        end;

        // Nebulae
        SeedRand(HashChunk(ccx, ccy, ccz) xor $FF00FF);
        if NextRand < NEBULA_CHANCE then
        begin
          idx := Length(FNebulae);
          SetLength(FNebulae, idx + 1);
          FNebulae[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand-0.5)*CHUNK_SIZE, (NextRand-0.5)*CHUNK_SIZE, (NextRand-0.5)*CHUNK_SIZE));
          FNebulae[idx].Size := NEBULA_BASE_SIZE * (0.8 + NextRand * 2.5);
          case Trunc(NextRand * 4) of
            0: FNebulae[idx].Color := ColorAlpha(PURPLE, 35);
            1: FNebulae[idx].Color := ColorAlpha(Fade(BLUE, 0.8), 35);
            2: FNebulae[idx].Color := ColorAlpha(Fade(ORANGE, 0.6), 35);
            3: FNebulae[idx].Color := ColorAlpha(Fade(RED, 0.5), 25);
          end;
        end;

        // Distant Solar Systems
        SeedRand(HashChunk(ccx, ccy, ccz) xor $00FF00);
        if (ccx = 0) and (ccy = 0) and (ccz = 0) then Continue; // Never spawn on Home System

        if NextRand < SUN_CHANCE then
        begin
          SunIdx := Length(FSuns);
          SetLength(FSuns, SunIdx + 1);
          FSuns[SunIdx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand-0.5)*CHUNK_SIZE*0.3, 0, (NextRand-0.5)*CHUNK_SIZE*0.3));
          SunRadius := 80.0 + NextRand * 100.0;
          FSuns[SunIdx].Radius := SunRadius;
          if NextRand > 0.5 then FSuns[SunIdx].Color := MakeCol(255, 200, 80) else FSuns[SunIdx].Color := MakeCol(255, 150, 50);

          PlanetCount := 1 + Trunc(NextRand * 3);
          OrbitR := SunRadius * 3.0;
          for j := 0 to PlanetCount - 1 do
          begin
            idx := Length(FPlanets);
            SetLength(FPlanets, idx + 1);
            OrbitR := OrbitR + 400.0 + NextRand * 400.0;

            FPlanets[idx].OrbitSunIndex := SunIdx;
            FPlanets[idx].OrbitRadius := OrbitR;
            FPlanets[idx].OrbitAngle := NextRand * 2.0 * PI;
            FPlanets[idx].OrbitSpeed := (0.02 + NextRand * 0.05);
            FPlanets[idx].Radius := PLANET_MIN_RADIUS + NextRand * (PLANET_MAX_RADIUS - PLANET_MIN_RADIUS);
            PlanetType := Trunc(NextRand * 5);
            FPlanets[idx].PlanetType := PlanetType;
            FPlanets[idx].IsMoon := False;
            FPlanets[idx].ParentPlanetIndex := -1;
            FPlanets[idx].IsLocked := False;

            case PlanetType of
              0: begin FPlanets[idx].PlanetColor := MakeCol(140,120,100); FPlanets[idx].AtmosphereColor := MakeCol(100,80,60); FPlanets[idx].HasAtmosphere := False; end;
              1: begin FPlanets[idx].PlanetColor := MakeCol(40,100,160); FPlanets[idx].AtmosphereColor := MakeCol(100,150,255); FPlanets[idx].HasAtmosphere := True; end;
              2: begin FPlanets[idx].PlanetColor := MakeCol(180,80,40); FPlanets[idx].AtmosphereColor := MakeCol(200,100,50); FPlanets[idx].HasAtmosphere := True; end;
              3: begin FPlanets[idx].PlanetColor := MakeCol(200,160,100); FPlanets[idx].AtmosphereColor := MakeCol(255,200,150); FPlanets[idx].HasAtmosphere := True; end;
              4: begin FPlanets[idx].PlanetColor := MakeCol(200,220,240); FPlanets[idx].AtmosphereColor := MakeCol(180,210,255); FPlanets[idx].HasAtmosphere := True; end;
            end;

            HasMoon := (FPlanets[idx].Radius > 100.0) and (NextRand < 0.4);
            if HasMoon then
            begin
              idx := Length(FPlanets);
              SetLength(FPlanets, idx + 1);
              FPlanets[idx].IsMoon := True;
              FPlanets[idx].ParentPlanetIndex := idx - 1;
              FPlanets[idx].MoonAngle := NextRand * 2.0 * PI;
              FPlanets[idx].MoonSpeed := 0.5 + NextRand * 1.5;
              FPlanets[idx].MoonRadius := 30.0 + NextRand * 50.0;
              FPlanets[idx].Radius := FPlanets[idx-1].Radius * 0.25;
              FPlanets[idx].PlanetType := Trunc(NextRand * 5);
              FPlanets[idx].OrbitSunIndex := -1;
              FPlanets[idx].HasAtmosphere := False;
              FPlanets[idx].PlanetColor := MakeCol(100,100,100);
              FPlanets[idx].IsLocked := False;
            end;
          end;
        end;
      end;
end;

{==============================================================================*
 *  COMET SYSTEM & COLLISIONS
 *==============================================================================}
procedure TSpaceWorld.SpawnComet(const CameraPos: TVector3);
var
  idx: Integer;
  theta, phi: Single;
  SpawnDir, TargetOffset: TVector3;
  C: ^TSpaceComet;
  Speed: Single;
begin
  if Length(FComets) >= MAX_COMETS then Exit;
  idx := Length(FComets);
  SetLength(FComets, idx + 1);
  C := @FComets[idx];
  theta := Random * 2.0 * PI;
  phi := ArcCos(Random * 2.0 - 1.0);
  SpawnDir := Vector3Create(Sin(phi)*Cos(theta), Sin(phi)*Sin(theta), Cos(phi));
  C^.Position := Vector3Add(CameraPos, Vector3Scale(SpawnDir, COMET_SHELL_RADIUS));
  TargetOffset := Vector3Create((Random-0.5)*200, (Random-0.5)*200, (Random-0.5)*200);
  C^.Velocity := Vector3Subtract(Vector3Add(CameraPos, TargetOffset), C^.Position);
  Speed := 40.0 + Random * 60.0;
  C^.Velocity := Vector3Scale(Vector3Normalize(C^.Velocity), Speed);
  C^.MaxLife := 15.0 + Random * 10.0;
  C^.Life := C^.MaxLife;
  C^.Size := 3.0 + Random * 4.0;
  C^.ParticleTimer := 0;
  if Random > 0.5 then C^.Color := ColorAlpha(SKYBLUE, 230) else C^.Color := ColorAlpha(Fade(ORANGE, 0.9), 230);
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
      FCometParticles[i].Position := Vector3Add(Pos, Vector3Create((Random-0.5)*6, (Random-0.5)*6, (Random-0.5)*6));
      Spread := Vector3Create((Random-0.5)*15, (Random-0.5)*15, (Random-0.5)*15);
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
      if i < High(FComets) then FComets[i] := FComets[High(FComets)];
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
    if not FCometParticles[i].Active then Continue;
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

procedure TSpaceWorld.CheckCometCollisions;
var
  i, j: Integer;
  C: ^TSpaceComet;
  P: ^TSpacePlanet;
  Dist, CombinedR: Single;
begin
  for i := High(FComets) downto 0 do
  begin
    C := @FComets[i];
    for j := 0 to High(FPlanets) do
    begin
      P := @FPlanets[j];
      Dist := Vector3Distance(C^.Position, P^.Position);
      CombinedR := C^.Size + P^.Radius;
      if Dist < CombinedR then
      begin
        var SurfDir := Vector3Normalize(Vector3Subtract(C^.Position, P^.Position));
        var ImpactPos := Vector3Add(P^.Position, Vector3Scale(SurfDir, P^.Radius));

        for var k := 0 to 30 do
          SpawnCometParticle(ImpactPos, Vector3Scale(SurfDir, 50.0), C^.Size * 2.0);

        if i < High(FComets) then FComets[i] := FComets[High(FComets)];
        SetLength(FComets, Length(FComets) - 1);
        Break;
      end;
    end;
  end;
end;

{==============================================================================*
 *  ORBIT UPDATE
 *==============================================================================}
procedure TSpaceWorld.UpdateOrbits(const dt: Single);
var
  i: Integer;
  P: ^TSpacePlanet;
  SunPos, ParentPos: TVector3;
begin
  for i := 0 to High(FPlanets) do
  begin
    P := @FPlanets[i];
    if P^.IsLocked then Continue;

    if P^.IsMoon then
    begin
      P^.MoonAngle := P^.MoonAngle + P^.MoonSpeed * dt;
      if P^.ParentPlanetIndex >= 0 then
      begin
        ParentPos := FPlanets[P^.ParentPlanetIndex].Position;
        P^.Position := Vector3Add(ParentPos, Vector3Create(
          Cos(P^.MoonAngle) * P^.MoonRadius, 0, Sin(P^.MoonAngle) * P^.MoonRadius));
      end;
    end
    else if P^.OrbitSunIndex >= 0 then
    begin
      P^.OrbitAngle := P^.OrbitAngle + P^.OrbitSpeed * dt;
      SunPos := FSuns[P^.OrbitSunIndex].Position;
      P^.Position := Vector3Add(SunPos, Vector3Create(
        Cos(P^.OrbitAngle) * P^.OrbitRadius, 0, Sin(P^.OrbitAngle) * P^.OrbitRadius));
    end;
  end;
end;

{==============================================================================*
 *  MAIN UPDATE
 *==============================================================================}
procedure TSpaceWorld.Update(const dt: Single; const CameraPos: TVector3; const TimeScale: Single);
var
  cx, cy, cz: Integer;
  ScaledDt: Single;
begin
  FTime := FTime + dt;
  FCameraPos := CameraPos;
  FTimeScale := TimeScale;
  ScaledDt := dt * FTimeScale;

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

  UpdateOrbits(ScaledDt);
  UpdateComets(ScaledDt, CameraPos);
  UpdateCometParticles(ScaledDt);
  CheckCometCollisions;
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
      if Dist > FADE_END_DIST then Continue;
      if Dist > FADE_START_DIST then FadeF := 1.0 - ((Dist - FADE_START_DIST) / (FADE_END_DIST - FADE_START_DIST)) else FadeF := 1.0;
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
      if (Dist > FADE_END_DIST) or (Dist < 50.0) then Continue;
      if Dist > FADE_START_DIST then FadeF := 1.0 - ((Dist - FADE_START_DIST) / (FADE_END_DIST - FADE_START_DIST)) else FadeF := 1.0;
      if Dist < 150.0 then FadeF := FadeF * (Dist - 50.0) / 100.0;
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

procedure TSpaceWorld.RenderSuns;
var
  i: Integer;
  S: ^TSun;
  Pos: TVector3;
  Col: TColorB;
begin
  rlSetBlendMode(BLEND_ADDITIVE);
  for i := 0 to High(FSuns) do
  begin
    S := @FSuns[i];
    Pos := S^.Position;
    Col := S^.Color;

    // Core sun sphere (solid)
    DrawSphere(Pos, S^.Radius, Col);

    // Weak outer aura (glow)
    DrawSphere(Pos, S^.Radius * 1.05, ColorAlpha(Col, 80));
    DrawSphere(Pos, S^.Radius * 1.15, ColorAlpha(Col, 40));
    DrawSphere(Pos, S^.Radius * 1.30, ColorAlpha(Col, 20)); // Very faint outer glow

    // Emit Corona Particles directly using the comet particle pool
    if Random < 0.5 then
    begin
      var Theta := Random * 2.0 * PI;
      var Phi := ArcCos(Random * 2.0 - 1.0);
      var SurfDir := Vector3Create(Sin(Phi)*Cos(Theta), Sin(Phi)*Sin(Theta), Cos(Phi));
      var PPos := Vector3Add(Pos, Vector3Scale(SurfDir, S^.Radius));
      SpawnCometParticle(PPos, Vector3Scale(SurfDir, 15.0), 4.0);
    end;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
end;

procedure TSpaceWorld.RenderPlanets(const CameraPos, CamRight, CamUp: TVector3);
var
  i: Integer;
  P: ^TSpacePlanet;
begin
  rlDisableDepthTest;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FPlanets) do
    begin
      P := @FPlanets[i];
      if not P^.HasAtmosphere then Continue;
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

  // CRITICAL: Setup lighting right before drawing the planets
  SetupPlanetLighting(CameraPos);

  rlDrawRenderBatchActive;
  rlEnableDepthMask;
  rlEnableDepthTest;
  for i := 0 to High(FPlanets) do
  begin
    P := @FPlanets[i];
    if P^.PlanetType < 0 then P^.PlanetType := 0;
    if P^.PlanetType > 4 then P^.PlanetType := 4;
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
  RX := CamRight.x; RY := CamRight.y; RZ := CamRight.z;
  UX := CamUp.x;   UY := CamUp.y;   UZ := CamUp.z;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FCometParticles) do
    begin
      if not FCometParticles[i].Active then Continue;
      P := @FCometParticles[i];
      Progress := 1.0 - (P^.Life / P^.MaxLife);
      if Progress < 0.2 then begin R := 255; G := 255; B := Round(Lerp(255, 180, Progress / 0.2)); end
      else if Progress < 0.5 then begin var t := (Progress - 0.2) / 0.3; R := 255; G := Round(Lerp(255, 120, t)); B := Round(Lerp(180, 40, t)); end
      else begin var t := (Progress - 0.5) / 0.5; R := Round(Lerp(255, 60, t)); G := Round(Lerp(120, 10, t)); B := Round(Lerp(40, 5, t)); end;
      AlphaF := (1.0 - Progress) * 0.8;
      AlphaB := Trunc(EnsureRange(AlphaF * 255, 0, 255));
      HalfSize := (P^.Size * (1.0 - Progress * 0.6)) * 0.5;
      Px := P^.Position.x; Py := P^.Position.y; Pz := P^.Position.z;
      rlColor4ub(R, G, B, AlphaB);
      rlVertex3f(Px - RX*HalfSize + UX*HalfSize, Py - RY*HalfSize + UY*HalfSize, Pz - RZ*HalfSize + UZ*HalfSize);
      rlVertex3f(Px + RX*HalfSize + UX*HalfSize, Py + RY*HalfSize + UY*HalfSize, Pz + RZ*HalfSize + UZ*HalfSize);
      rlVertex3f(Px + RX*HalfSize - UX*HalfSize, Py + RY*HalfSize - UY*HalfSize, Pz + RZ*HalfSize - UZ*HalfSize);
      rlVertex3f(Px - RX*HalfSize + UX*HalfSize, Py - RY*HalfSize + UY*HalfSize, Pz - RZ*HalfSize + UZ*HalfSize);
      rlVertex3f(Px + RX*HalfSize - UX*HalfSize, Py + RY*HalfSize - UY*HalfSize, Pz + RZ*HalfSize - UZ*HalfSize);
      rlVertex3f(Px - RX*HalfSize - UX*HalfSize, Py - RY*HalfSize - UY*HalfSize, Pz - RZ*HalfSize - UZ*HalfSize);
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
    HeadSize := C^.Size * 0.5;
    DrawSphere(C^.Position, HeadSize, C^.Color);
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
end;

{==============================================================================*
 *  SHADOW MAP RENDERING
 *==============================================================================}
procedure TSpaceWorld.RenderShadows;
var
  i: Integer;
  P: ^TSpacePlanet;
  C: ^TSpaceComet;
begin
  for i := 0 to High(FPlanets) do
  begin
    P := @FPlanets[i];
    if P^.PlanetType < 0 then P^.PlanetType := 0;
    if P^.PlanetType > 4 then P^.PlanetType := 4;
    if FPlanetModels[P^.PlanetType].meshes <> nil then
      DrawModel(FPlanetModels[P^.PlanetType], P^.Position, P^.Radius, BLACK)
    else
      DrawSphere(P^.Position, P^.Radius, BLACK);
  end;

  for i := 0 to High(FComets) do
  begin
    C := @FComets[i];
    DrawSphere(C^.Position, C^.Size * 0.5, BLACK);
  end;
end;

procedure TSpaceWorld.Render(const Camera: TCamera3D);
var
  CamForward, CamRight, CamUp: TVector3;
  SpaceProj, NormalProj: TMatrix;
begin
  CamForward := Vector3Normalize(Vector3Subtract(Camera.target, Camera.position));
  CamRight   := Vector3Normalize(Vector3CrossProduct(CamForward, Camera.up));
  CamUp      := Vector3Normalize(Vector3CrossProduct(CamRight, CamForward));

  SpaceProj := MatrixPerspective(Camera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 10000.0);
  rlSetMatrixProjection(SpaceProj);

  RenderDistantStars(FCameraPos, CamRight, CamUp);
  RenderNebulae(FCameraPos, CamRight, CamUp);
  RenderNearStars(FCameraPos, CamRight, CamUp);
  RenderSuns;
  RenderPlanets(FCameraPos, CamRight, CamUp);
  RenderCometParticles(CamRight, CamUp);
  RenderComets;

  NormalProj := MatrixPerspective(Camera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
  rlSetMatrixProjection(NormalProj);

  rlEnableDepthMask;
end;

{==============================================================================*
 *  LANDING & FLOATING ORIGIN SYSTEM
 *==============================================================================}
function TSpaceWorld.FindNearestPlanet(const CameraPos: TVector3; out OutIndex: Integer; out OutDistance: Single): Boolean;
var
  i: Integer;
  Dist, Nearest: Single;
  P: ^TSpacePlanet;
begin
  Result := False;
  OutIndex := -1;
  Nearest := 1e9;

  for i := 0 to High(FPlanets) do
  begin
    P := @FPlanets[i];
    Dist := Vector3Distance(P^.Position, CameraPos) - P^.Radius;
    if (Dist < Nearest) and (Dist > 0) then
    begin
      Nearest := Dist;
      OutIndex := i;
    end;
  end;

  OutDistance := Nearest;
  Result := (OutIndex >= 0);
end;

procedure TSpaceWorld.InitiateLanding(const TargetIndex: Integer; var CameraTarget: TVector3; var CameraPos: TVector3);
var
  TargetPos, Shift: TVector3;
  i: Integer;
begin
  if FIsLanded or (TargetIndex < 0) or (TargetIndex > High(FPlanets)) then Exit;

  TargetPos := FPlanets[TargetIndex].Position;
  Shift := Vector3Subtract(Vector3Create(0, 0, 0), TargetPos);
  FOriginOffset := Vector3Add(FOriginOffset, Shift);

  for i := 0 to High(FPlanets) do FPlanets[i].Position := Vector3Add(FPlanets[i].Position, Shift);
  for i := 0 to High(FSuns) do FSuns[i].Position := Vector3Add(FSuns[i].Position, Shift);
  for i := 0 to High(FNebulae) do FNebulae[i].Position := Vector3Add(FNebulae[i].Position, Shift);
  for i := 0 to High(FNearStars) do FNearStars[i].Position := Vector3Add(FNearStars[i].Position, Shift);
  for i := 0 to High(FComets) do FComets[i].Position := Vector3Add(FComets[i].Position, Shift);
  for i := 0 to High(FCometParticles) do
    if FCometParticles[i].Active then
      FCometParticles[i].Position := Vector3Add(FCometParticles[i].Position, Shift);

  CameraPos := Vector3Add(CameraPos, Shift);
  CameraTarget := Vector3Add(CameraTarget, Shift);

  FPlanets[TargetIndex].IsLocked := True;
  FLandingTargetIndex := TargetIndex;
  FIsLanded := True;

  var SurfDir := Vector3Normalize(Vector3Subtract(CameraPos, FPlanets[TargetIndex].Position));
  CameraPos := Vector3Add(FPlanets[TargetIndex].Position, Vector3Scale(SurfDir, FPlanets[TargetIndex].Radius + 5.0));
  CameraTarget := FPlanets[TargetIndex].Position;
end;

procedure TSpaceWorld.ReleaseLanding;
begin
  if not FIsLanded then Exit;
  if FLandingTargetIndex >= 0 then
    FPlanets[FLandingTargetIndex].IsLocked := False;
  FIsLanded := False;
  FLandingTargetIndex := -1;
end;

function TSpaceWorld.IsLanded: Boolean;
begin
  Result := FIsLanded;
end;

function TSpaceWorld.GetLandedPlanetPos: TVector3;
begin
  if FIsLanded and (FLandingTargetIndex >= 0) then
    Result := FPlanets[FLandingTargetIndex].Position
  else
    Result := Vector3Create(0, 0, 0);
end;

function TSpaceWorld.GetLandedPlanetRadius: Single;
begin
  if FIsLanded and (FLandingTargetIndex >= 0) then
    Result := FPlanets[FLandingTargetIndex].Radius
  else
    Result := 0;
end;

procedure TSpaceWorld.GetPlanetInfo(const Index: Integer; out OutPos: TVector3; out OutRadius: Single);
begin
  if (Index >= 0) and (Index <= High(FPlanets)) then
  begin
    OutPos := FPlanets[Index].Position;
    OutRadius := FPlanets[Index].Radius;
  end
  else
  begin
    OutPos := Vector3Create(0, 0, 0);
    OutRadius := 0;
  end;
end;

{==============================================================================*
 *  Initialize distant stars with true cluster distribution (no rings)
 *==============================================================================}
procedure TSpaceWorld.InitializeDistantStars;
var
  i, c, j: Integer;
  St: ^TSpaceStar;
  ClusterCount, StarsInCluster: Integer;
  BaseDir: TVector3;
  theta, phi: Single;
begin
  SeedRand(98765);

  // Determine number of clusters
  ClusterCount := 60 + Trunc(NextRand * 40); // 60-100 clusters

  i := 0;
  while i < DISTANT_STAR_COUNT do
  begin
    if (NextRand < 0.4) and (i < DISTANT_STAR_COUNT - 20) then
    begin
      // Create a cluster
      theta := NextRand * 2.0 * PI;
      phi := ArcCos(NextRand * 2.0 - 1.0);
      BaseDir := Vector3Create(Sin(phi)*Cos(theta), Sin(phi)*Sin(theta), Cos(phi));

      StarsInCluster := 10 + Trunc(NextRand * 30);
      for j := 0 to StarsInCluster - 1 do
      begin
        if i >= DISTANT_STAR_COUNT then Break;
        St := @FDistantStars[i];

        // Scatter around base direction
        var Scatter: Single := 0.05 + NextRand * 0.15; // Tight cluster
        var Offset: TVector3 := Vector3Create((NextRand-0.5), (NextRand-0.5), (NextRand-0.5));
        St^.Dir := Vector3Normalize(Vector3Add(BaseDir, Vector3Scale(Offset, Scatter)));

        // Cluster stars are hot and bright (blue/white)
        St^.ColorTint := Trunc(NextRand * 2);
        St^.Size := 8.0 + NextRand * NextRand * 25.0;
        St^.Brightness := 0.5 + NextRand * 0.5;
        St^.TwinklePhase := NextRand * 2.0 * PI;
        St^.TwinkleSpeed := 0.5 + NextRand * 2.5;

        Inc(i);
      end;
    end
    else
    begin
      // Single scattered halo star
      St := @FDistantStars[i];
      theta := NextRand * 2.0 * PI;
      phi := ArcCos(NextRand * 2.0 - 1.0);
      St^.Dir := Vector3Create(Sin(phi)*Cos(theta), Sin(phi)*Sin(theta), Cos(phi));

      // Halo stars are dimmer and older (red/orange)
      St^.ColorTint := 2 + Trunc(NextRand * 2);
      St^.Size := 5.0 + NextRand * NextRand * 15.0;
      St^.Brightness := 0.3 + NextRand * 0.4;
      St^.TwinklePhase := NextRand * 2.0 * PI;
      St^.TwinkleSpeed := 0.5 + NextRand * 2.5;

      Inc(i);
    end;
  end;
end;

end.
