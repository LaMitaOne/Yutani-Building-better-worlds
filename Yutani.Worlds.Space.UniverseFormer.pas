unit Yutani.Worlds.Space.UniverseFormer;

{==============================================================================*
 *  Yutani Universe Former v0.1
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    A self-contained Raylib editor for designing an entire UNIVERSE of
 *    star systems. The player places COMPLETE star systems (not individual
 *    planets) by selecting a system template in the bottom toolbar, then
 *    clicking anywhere in the 3D viewport to drop the system at that
 *    location. Multiple systems can coexist in the same scene, each with
 *    their own sun + orbiting planets, all visible from a universe-scale
 *    camera.
 *
 *  System Templates:
 *    - Sol-Like: 7 planets (Mercury through Neptune), yellow sun
 *    - Random:   3-7 procedurally generated planets, random sun color
 *    - Binary:   2 suns orbiting each other + 3-5 planets
 *    - Dwarf:    Small red dwarf sun + 1-2 rocky planets
 *    - Empty:    Just a sun, no planets
 *    - Clear:    Wipes all systems
 *
 *  Scale:
 *    Camera operates at universe scale (default distance ~1800 units).
 *    Systems are placed on the Y=0 plane. LOD rendering: far systems
 *    (>1500 units) show only the sun glow, medium systems (600-1500)
 *    show sun + orbit rings, near systems (<600) show full detail.
 *
 *  Camera:
 *    Middle-mouse drag = orbit
 *    Mouse wheel       = zoom (30-6000)
 *    WASD / arrows     = pan target
 *
 *  Selection:
 *    Left-click a system → selects it (pulsing wireframe sphere)
 *    DEL → removes selected system
 *    ESC → deselects + disarms brush
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  Winapi.Windows, System.SysUtils, System.Math, System.Classes,
  Raylib, RayMath, rlgl, Yutani.Worlds.Space.Textures;

const
  UF_TOOLBAR_HEIGHT     = 130;    // Taller so the template label fits
  UF_TOOLBAR_PADDING    = 12;
  UF_TEMPLATE_SIZE      = 80;
  UF_TEMPLATE_GAP       = 10;
  UF_TEMPLATE_COUNT     = 12; // 5 planets + 5 systems + universe + clear

  UF_MAX_SYSTEMS        = 8000;   // Allows full galactic-scale universes
  UF_DEFAULT_CAM_DIST   = 600.0;  // Closer to the origin so the user can actually move the camera without flying off into the void
  UF_GROUND_Y           = 0.0;

  // Scaled-down sizes. The creator is a "model railroad" view of the
  // universe - everything is small enough to see at once from the
  // default camera distance. The real Space.World can scale these
  // values up by 10x or 100x at runtime; here we want overview.
  UF_SUN_RADIUS         = 12.0;   // Was 50 - now small enough to not dominate
  UF_ORBIT_MIN_RADIUS   = 25.0;   // Was 100
  UF_ORBIT_STEP         = 18.0;   // Was 70
  UF_ORBIT_SPEED_BASE   = 0.2;

  UF_MIN_SYSTEM_GAP     = 150.0;  // Just enough so they don't visually overlap. Was 350 which was too strict.
  UF_PLACE_ATTEMPTS     = 80;     // More attempts to find a free spot

  // LOD Thresholds - kept high so nothing disappears. At the new
  // smaller scale the whole universe fits in a 1500-unit radius, so
  // these values effectively mean "always render full detail".
  UF_LOD_FAR_DIST       = 50000.0;
  UF_LOD_MED_DIST       = 20000.0;

  UF_COL_TOOLBAR_BG     : TColorB = (r: 18;  g: 22;  b: 30;  a: 230);
  UF_COL_TOOLBAR_BORDER : TColorB = (r: 80;  g: 100; b: 140; a: 255);
  UF_COL_TEMPLATE_BG    : TColorB = (r: 40;  g: 48;  b: 60;  a: 255);
  UF_COL_TEMPLATE_HOVER : TColorB = (r: 70;  g: 90;  b: 120; a: 255);
  UF_COL_TEMPLATE_SEL   : TColorB = (r: 220; g: 180; b: 60;  a: 255);
  UF_COL_TEXT           : TColorB = (r: 230; g: 235; b: 245; a: 255);
  UF_COL_TEXT_DIM       : TColorB = (r: 140; g: 150; b: 165; a: 255);
  UF_COL_HIGHLIGHT      : TColorB = (r: 100; g: 220; b: 255; a: 255);

type
  TUFPlanetType = 0..4;
  TUFSystemKind = (skSol, skRandom, skBinary, skDwarf, skEmpty, skUniverse);
  TUFTemplateKind = (tkPlanet, tkSystem, tkClear, tkUniverse);

  TUFPlanet = record
    PlanetType: TUFPlanetType;
    Radius: Single;
    OrbitRadius: Single;
    OrbitAngle: Single;
    OrbitSpeed: Single;
    PlanetColor: TColorB;
    AtmosphereColor: TColorB;
    HasAtmosphere: Boolean;
    CurrentPos: TVector3;
  end;

  TUFSystem = record
    Kind: TUFSystemKind;
    Position: TVector3;       // Current animated position (lerps toward TargetPosition)
    TargetPosition: TVector3; // Goal position - set when pushing other systems away
    SunRadius: Single;
    SunColor: TColorB;
    IsBinary: Boolean;
    Sun2Radius: Single;
    Sun2Color: TColorB;
    Sun2Offset: Single;
    BinaryAngle: Single;
    BinarySpeed: Single;
    Planets: TArray<TUFPlanet>;
    FreePlanets: TArray<TUFPlanet>; // Planets without a sun (rogue planets)
    Name: AnsiString;
    IsDead: Boolean;
    BoundsRadius: Single;
  end;

  TUFTemplate = record
    Kind: TUFTemplateKind;
    Label_: AnsiString;
    SystemKind: TUFSystemKind;
    PlanetType: TUFPlanetType; // Only valid for tkPlanet
    Color: TColorB;
  end;

  TUniverseFormer = class
  private
    FSystems: TArray<TUFSystem>;
    FSystemCount: Integer;

    FPlanetTextures: array[0..4] of TTexture2D;
    FPlanetModels: array[0..4] of TModel;
    FSunModel: TModel;
    FDefaultWhiteTex: TTexture2D;
    FLightShader: TShader;
    FOwnsShader: Boolean;
    FOwnsTextures: Boolean;

    FCamera: TCamera3D;
    FCamYaw, FCamPitch, FCamDist: Single;
    FCameraMoved: Boolean;

    FTemplates: array[0..UF_TEMPLATE_COUNT - 1] of TUFTemplate;
    FSelectedTemplate: Integer;
    FSelectedSystem: Integer;
    FMousePos: TVector2;
    FScreenW, FScreenH: Integer;
    FLastMouse: TPoint;
    FDraggingRMB: Boolean;
    FTime: Single;
    FLMBWasDown: Boolean;
    FPaused: Boolean;

    procedure InitTemplates;
    procedure GenerateAssets;
    procedure DestroyAssets;
    procedure SetupPlanetLighting(const SystemPos: TVector3);
    function GetToolbarRect: TRectangle;
    procedure HandleCameraInput(const MousePos: TVector2; const dt: Single);
    function GetTemplateRect(Idx: Integer): TRectangle;
    function GetTemplateAt(const Pos: TVector2): Integer;
    function IsMouseOverToolbar(const Pos: TVector2): Boolean;
    function RaycastToGround(const Ray: TRay; out HitPos: TVector3): Boolean;
    function GetSystemUnderMouse(const Ray: TRay): Integer;
    function SpawnSystem(Kind: TUFSystemKind; const Pos: TVector3): Integer;
    function FindFreePositionNear(const RequestedPos: TVector3): TVector3;
    function SpawnSystemSmart(Kind: TUFSystemKind; const RequestedPos: TVector3): Integer;
    procedure SpawnFreePlanet(PlanetType: TUFPlanetType; const Pos: TVector3);
    procedure GenerateRandomUniverse(const CenterPos: TVector3; Count: Integer);
    procedure GenerateSolSystem(var S: TUFSystem);
    procedure GenerateRandomSystem(var S: TUFSystem);
    procedure GenerateBinarySystem(var S: TUFSystem);
    procedure GenerateDwarfSystem(var S: TUFSystem);
    procedure GenerateEmptySystem(var S: TUFSystem);
    procedure DeleteSelectedSystem;
    procedure UpdateOrbits(const dt: Single);
    procedure ComputePlanetPositions(var S: TUFSystem);
    function GetSystemBoundsRadius(const S: TUFSystem): Single;
    procedure HandlePlacementInput(const MousePos: TVector2);
    procedure DrawOrbitRingBatched(const Center: TVector3; Radius: Single; const Color: TColorB);
    procedure Render3DScene;
    procedure RenderToolbar;
    procedure RenderStatusBar;
    procedure RenderSelectionHighlight;
  public
    constructor Create(const ALightShader: TShader);
    destructor Destroy; override;
    procedure Update(dt: Single; const MousePos: TVector2; ScreenW, ScreenH: Integer);
    procedure Render;
    procedure ClearAll;
    function LiveSystemCount: Integer;
    function LiveObjectCount: Integer;
    property SelectedSystem: Integer read FSelectedSystem;
    property SelectedTemplate: Integer read FSelectedTemplate;
    property Paused: Boolean read FPaused write FPaused;
    procedure SpawnSolSystemAtCamera;
    procedure SpawnRandomSystemAtCamera;
    procedure SpawnRandomUniverseAtCamera;
  end;

implementation

function MakeCol(r, g, b: Byte): TColorB;
begin
  Result.r := r;
  Result.g := g;
  Result.b := b;
  Result.a := 255;
end;

procedure TUniverseFormer.DrawOrbitRingBatched(const Center: TVector3; Radius: Single; const Color: TColorB);
var
  I: Integer;
  A1, A2: Single;
  P1, P2: TVector3;
const
  SEGS = 32;
begin
  // Must be called from inside an rlBegin(RL_LINES) block.
  for I := 0 to SEGS - 1 do
  begin
    A1 := (I / SEGS) * 2.0 * PI;
    A2 := ((I + 1) / SEGS) * 2.0 * PI;
    P1 := Vector3Add(Center, Vector3Create(Cos(A1) * Radius, 0, Sin(A1) * Radius));
    P2 := Vector3Add(Center, Vector3Create(Cos(A2) * Radius, 0, Sin(A2) * Radius));
    rlColor4ub(Color.r, Color.g, Color.b, Color.a);
    rlVertex3f(P1.x, P1.y, P1.z);
    rlColor4ub(Color.r, Color.g, Color.b, Color.a);
    rlVertex3f(P2.x, P2.y, P2.z);
  end;
end;

procedure DrawOrbitRing(const Center: TVector3; Radius: Single; const Color: TColorB);
var
  I: Integer;
  A1, A2: Single;
  P1, P2: TVector3;
const
  SEGS = 48;
begin
  for I := 0 to SEGS - 1 do
  begin
    A1 := (I / SEGS) * 2.0 * PI;
    A2 := ((I + 1) / SEGS) * 2.0 * PI;
    P1 := Vector3Add(Center, Vector3Create(Cos(A1) * Radius, 0, Sin(A1) * Radius));
    P2 := Vector3Add(Center, Vector3Create(Cos(A2) * Radius, 0, Sin(A2) * Radius));
    DrawLine3D(P1, P2, Color);
  end;
end;

{ TUniverseFormer }

constructor TUniverseFormer.Create(const ALightShader: TShader);
begin
  inherited Create;
  FSystemCount := 0;
  SetLength(FSystems, UF_MAX_SYSTEMS);

  FLightShader := ALightShader;
  FOwnsShader := False;
  FOwnsTextures := False;

  if FLightShader.id = 0 then
  begin
    FLightShader := LoadShader(nil, nil);
    FOwnsShader := True;
  end;

  // Camera defaults - reverted to the values that worked before the
  // top-down experiment. Yaw -0.6 / Pitch 0.9 gives a nice 3/4 view
  // from above-front. DO NOT touch this unless the user explicitly
  // asks - we wasted hours cycling through "improved" camera angles
  // that all broke the initial view.
  FCamYaw := -0.6;
  FCamPitch := 0.9;
  FCamDist := UF_DEFAULT_CAM_DIST;
  FCamera.target := Vector3Create(0, 0, 0);
  FCamera.up := Vector3Create(0, 1, 0);
  FCamera.fovy := 45.0;
  FCamera.projection := CAMERA_PERSPECTIVE;
  // Compute the position from the spherical coordinates so the first
  // frame is rendered from the correct viewpoint.
  FCamera.position := Vector3Create(
    FCamera.target.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist,
    FCamera.target.y + Sin(FCamPitch) * FCamDist,
    FCamera.target.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
  FCameraMoved := False;

  FSelectedTemplate := -1;
  FSelectedSystem := -1;
  FDraggingRMB := False;
  FTime := 0;
  FLMBWasDown := False;
  FPaused := False;

  InitTemplates;
  GenerateAssets;
end;

destructor TUniverseFormer.Destroy;
begin
  DestroyAssets;
  if FOwnsShader and (FLightShader.id > 0) then
    UnloadShader(FLightShader);
  FSystems := nil;
  inherited;
end;

procedure TUniverseFormer.InitTemplates;
const
  PLANET_COLORS: array[0..4] of TColorB = (
    (r: 140; g: 120; b: 100; a: 255),  // rocky  - brown
    (r:  60; g: 120; b: 200; a: 255),  // earth  - blue
    (r: 200; g:  90; b:  50; a: 255),  // mars   - red
    (r: 220; g: 180; b: 110; a: 255),  // gasgiant - tan
    (r: 220; g: 230; b: 245; a: 255)   // ice    - pale blue
  );
begin
  // 0-4: Individual planet brushes (single planet)
  FTemplates[0].Kind := tkPlanet; FTemplates[0].Label_ := 'Rocky';
  FTemplates[0].PlanetType := 0; FTemplates[0].Color := PLANET_COLORS[0];

  FTemplates[1].Kind := tkPlanet; FTemplates[1].Label_ := 'Earth';
  FTemplates[1].PlanetType := 1; FTemplates[1].Color := PLANET_COLORS[1];

  FTemplates[2].Kind := tkPlanet; FTemplates[2].Label_ := 'Mars';
  FTemplates[2].PlanetType := 2; FTemplates[2].Color := PLANET_COLORS[2];

  FTemplates[3].Kind := tkPlanet; FTemplates[3].Label_ := 'Gas Giant';
  FTemplates[3].PlanetType := 3; FTemplates[3].Color := PLANET_COLORS[3];

  FTemplates[4].Kind := tkPlanet; FTemplates[4].Label_ := 'Ice';
  FTemplates[4].PlanetType := 4; FTemplates[4].Color := PLANET_COLORS[4];

  // 5-9: Complete star system brushes
  FTemplates[5].Kind := tkSystem;
  FTemplates[5].Label_ := 'Sol-Like';
  FTemplates[5].SystemKind := skSol;
  FTemplates[5].Color := MakeCol(255, 220, 100);

  FTemplates[6].Kind := tkSystem;
  FTemplates[6].Label_ := 'Random';
  FTemplates[6].SystemKind := skRandom;
  FTemplates[6].Color := MakeCol(180, 220, 255);

  FTemplates[7].Kind := tkSystem;
  FTemplates[7].Label_ := 'Binary';
  FTemplates[7].SystemKind := skBinary;
  FTemplates[7].Color := MakeCol(255, 180, 100);

  FTemplates[8].Kind := tkSystem;
  FTemplates[8].Label_ := 'Dwarf';
  FTemplates[8].SystemKind := skDwarf;
  FTemplates[8].Color := MakeCol(200, 100, 60);

  FTemplates[9].Kind := tkSystem;
  FTemplates[9].Label_ := 'Empty Sun';
  FTemplates[9].SystemKind := skEmpty;
  FTemplates[9].Color := MakeCol(255, 240, 200);

  // 10: Random Universe
  FTemplates[10].Kind := tkUniverse;
  FTemplates[10].Label_ := 'Random Universe';
  FTemplates[10].SystemKind := skUniverse;
  FTemplates[10].Color := MakeCol(180, 100, 255);

  // 11: Clear
  FTemplates[11].Kind := tkClear;
  FTemplates[11].Label_ := 'Clear';
  FTemplates[11].Color := MakeCol(220, 80, 80);
end;

procedure TUniverseFormer.GenerateAssets;
var
  I: Integer;
  Mesh: TMesh;
  WhiteImg: TImage;
begin
  WhiteImg := GenImageColor(1, 1, WHITE);
  FDefaultWhiteTex := LoadTextureFromImage(WhiteImg);
  UnloadImage(WhiteImg);
  SetTextureFilter(FDefaultWhiteTex, TEXTURE_FILTER_TRILINEAR);

  for I := 0 to 4 do
  begin
    // 256x128 is plenty for these tiny editor-scale planets.
    FPlanetTextures[I] := TPlanetTextureGen.Generate(I, Cardinal(Random(MaxInt)), 256);
    if FPlanetTextures[I].id > 0 then
    begin
      SetTextureFilter(FPlanetTextures[I], TEXTURE_FILTER_TRILINEAR);
      SetTextureWrap(FPlanetTextures[I], TEXTURE_WRAP_REPEAT);
      GenTextureMipmaps(@FPlanetTextures[I]);
    end;
    Mesh := GenMeshSphere(1.0, 32, 24);
    UploadMesh(@Mesh, False);
    FPlanetModels[I] := LoadModelFromMesh(Mesh);
    FPlanetModels[I].materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FPlanetTextures[I];
    if FLightShader.id > 0 then
      FPlanetModels[I].materials[0].shader := FLightShader;
  end;
  FOwnsTextures := True;

  // No sun texture - we render the sun as a plain bright yellow sphere.
  // CRITICAL: We MUST use a Mesh + DrawModel, NOT DrawSphere.
  // DrawSphere uses immediate-mode vertex pushing every frame which is
  // dramatically slower than a pre-uploaded VBO. With 200+ systems this
  // makes the difference between 60 FPS and 15 FPS.
  Mesh := GenMeshSphere(1.0, 16, 12);
  UploadMesh(@Mesh, False);
  FSunModel := LoadModelFromMesh(Mesh);
  // No texture, no shader - just the raw mesh. We tint it yellow at
  // draw time via DrawModel's color parameter.
end;

procedure TUniverseFormer.DestroyAssets;
var
  I: Integer;
begin
  if FOwnsTextures then
  begin
    for I := 0 to 4 do
    begin
      if FPlanetTextures[I].id > 0 then
        UnloadTexture(FPlanetTextures[I]);
      if FPlanetModels[I].meshes <> nil then
        UnloadModel(FPlanetModels[I]);
    end;
  end;
  if FDefaultWhiteTex.id > 0 then
    UnloadTexture(FDefaultWhiteTex);
  if FSunModel.meshes <> nil then
    UnloadModel(FSunModel);
end;

procedure TUniverseFormer.SetupPlanetLighting(const SystemPos: TVector3);
var
  LightPosArr: array[0..2] of Single;
  ViewPosArr: array[0..2] of Single;
  Ambient: array[0..3] of Single;
  Diffuse: array[0..3] of Single;
  RadiusArr: array[0..0] of Single;
  Shader: TShader;
  I: Integer;
begin
  if FLightShader.id = 0 then
    Exit;
  LightPosArr[0] := SystemPos.x;
  LightPosArr[1] := SystemPos.y;
  LightPosArr[2] := SystemPos.z;
  ViewPosArr[0] := FCamera.position.x;
  ViewPosArr[1] := FCamera.position.y;
  ViewPosArr[2] := FCamera.position.z;
  Ambient[0] := 0.25; Ambient[1] := 0.25; Ambient[2] := 0.30; Ambient[3] := 1.0;
  Diffuse[0] := 1.8;  Diffuse[1] := 1.8;  Diffuse[2] := 1.6;  Diffuse[3] := 1.0;
  RadiusArr[0] := 10000.0;
  for I := 0 to 4 do
  begin
    if FPlanetModels[I].meshes = nil then
      Continue;
    Shader := FPlanetModels[I].materials[0].Shader;
    if Shader.id = 0 then
      Continue;
    SetShaderValue(Shader, GetShaderLocation(Shader, 'lightPos'), @LightPosArr, SHADER_UNIFORM_VEC3);
    SetShaderValue(Shader, GetShaderLocation(Shader, 'viewPos'), @ViewPosArr, SHADER_UNIFORM_VEC3);
    SetShaderValue(Shader, GetShaderLocation(Shader, 'ambient'), @Ambient, SHADER_UNIFORM_VEC4);
    SetShaderValue(Shader, GetShaderLocation(Shader, 'diffuse'), @Diffuse, SHADER_UNIFORM_VEC4);
    SetShaderValue(Shader, GetShaderLocation(Shader, 'lightRadius'), @RadiusArr, SHADER_UNIFORM_FLOAT);
  end;
end;

// ============================================================================
// Layout helpers
// ============================================================================

function TUniverseFormer.GetToolbarRect: TRectangle;
begin
  Result.x := 0;
  Result.y := FScreenH - UF_TOOLBAR_HEIGHT;
  Result.width := FScreenW;
  Result.height := UF_TOOLBAR_HEIGHT;
end;

function TUniverseFormer.GetTemplateRect(Idx: Integer): TRectangle;
var
  TotalWidth, StartX: Single;
begin
  TotalWidth := UF_TEMPLATE_COUNT * UF_TEMPLATE_SIZE +
                (UF_TEMPLATE_COUNT - 1) * UF_TEMPLATE_GAP;
  StartX := (FScreenW - TotalWidth) * 0.5;
  // Anchor the template block at the TOP of the toolbar with a small
  // padding. The label is drawn BELOW the swatch inside the same
  // template rect, so we need enough vertical room: UF_TEMPLATE_SIZE
  // for the swatch + ~20 for the label + a few px margin.
  Result.x := StartX + Idx * (UF_TEMPLATE_SIZE + UF_TEMPLATE_GAP);
  Result.y := FScreenH - UF_TOOLBAR_HEIGHT + 10;
  Result.width := UF_TEMPLATE_SIZE;
  Result.height := UF_TEMPLATE_SIZE;
end;

function TUniverseFormer.GetTemplateAt(const Pos: TVector2): Integer;
var
  I: Integer;
  R: TRectangle;
begin
  Result := -1;
  for I := 0 to UF_TEMPLATE_COUNT - 1 do
  begin
    R := GetTemplateRect(I);
    if CheckCollisionPointRec(Pos, R) then
      Exit(I);
  end;
end;

function TUniverseFormer.IsMouseOverToolbar(const Pos: TVector2): Boolean;
var
  R: TRectangle;
begin
  R := GetToolbarRect;
  Result := CheckCollisionPointRec(Pos, R);
end;

// ============================================================================
// 3D picking
// ============================================================================

function TUniverseFormer.RaycastToGround(const Ray: TRay; out HitPos: TVector3): Boolean;
var
  T: Single;
begin
  Result := False;
  if Abs(Ray.direction.y) < 0.0001 then
    Exit;
  T := (UF_GROUND_Y - Ray.position.y) / Ray.direction.y;
  if T < 0 then
    Exit;
  HitPos.x := Ray.position.x + Ray.direction.x * T;
  HitPos.y := UF_GROUND_Y;
  HitPos.z := Ray.position.z + Ray.direction.z * T;
  Result := True;
end;

function TUniverseFormer.GetSystemUnderMouse(const Ray: TRay): Integer;
var
  I: Integer;
  BestT, T: Single;
  SysPos: TVector3;
  SysRad: Single;
  Closest, D: TVector3;
  Offset, TrueT: Single;
begin
  Result := -1;
  BestT := 1e9;
  for I := 0 to FSystemCount - 1 do
  begin
    if FSystems[I].IsDead then
      Continue;
    SysPos := FSystems[I].Position;
    SysRad := FSystems[I].BoundsRadius;
    T := Vector3DotProduct(Vector3Subtract(SysPos, Ray.position), Ray.direction);
    if T < 0 then
      Continue;
    Closest := Vector3Add(Ray.position, Vector3Scale(Ray.direction, T));
    D := Vector3Subtract(Closest, SysPos);
    Offset := Sqrt(Sqr(SysRad) - Sqr(D.x) - Sqr(D.y) - Sqr(D.z));
    TrueT := T - Offset;
    if TrueT < BestT then
    begin
      BestT := TrueT;
      Result := I;
    end;
  end;
end;

// ============================================================================
// System generation
// ============================================================================

function TUniverseFormer.GetSystemBoundsRadius(const S: TUFSystem): Single;
var
  I: Integer;
begin
  Result := S.SunRadius + 50;
  for I := 0 to High(S.Planets) do
  begin
    if S.Planets[I].OrbitRadius + S.Planets[I].Radius > Result then
      Result := S.Planets[I].OrbitRadius + S.Planets[I].Radius;
  end;
  Result := Result + 20;
end;

procedure TUniverseFormer.ComputePlanetPositions(var S: TUFSystem);
var
  I: Integer;
  Center: TVector3;
begin
  Center := S.Position;
  for I := 0 to High(S.Planets) do
  begin
    S.Planets[I].CurrentPos := Vector3Add(Center, Vector3Create(
      Cos(S.Planets[I].OrbitAngle) * S.Planets[I].OrbitRadius, 0,
      Sin(S.Planets[I].OrbitAngle) * S.Planets[I].OrbitRadius));
  end;
end;

procedure TUniverseFormer.GenerateSolSystem(var S: TUFSystem);
type
  TSolData = record
    Typ: Byte;
    OrbitR: Single;
    Radius: Single;
    HasAtmo: Boolean;
    ColR, ColG, ColB: Byte;
    AtmoR, AtmoG, AtmoB: Byte;
  end;
const
  // Scaled down by ~4x from the previous values. Orbit radii 25-120
  // instead of 100-480, planet radii 1.5-7 instead of 6-28.
  SOL_DATA: array[0..6] of TSolData = (
    (Typ: 0; OrbitR: 25;  Radius: 1.5; HasAtmo: False; ColR: 140; ColG: 120; ColB: 100; AtmoR: 0;   AtmoG: 0;   AtmoB: 0;),
    (Typ: 1; OrbitR: 35;  Radius: 3;   HasAtmo: True;  ColR: 200; ColG: 160; ColB: 100; AtmoR: 255; AtmoG: 200; AtmoB: 100;),
    (Typ: 1; OrbitR: 45;  Radius: 3.5; HasAtmo: True;  ColR: 60;  ColG: 120; ColB: 200; AtmoR: 100; AtmoG: 150; AtmoB: 255;),
    (Typ: 2; OrbitR: 55;  Radius: 2.5; HasAtmo: True;  ColR: 200; ColG: 90;  ColB: 50;  AtmoR: 200; AtmoG: 100; AtmoB: 50;),
    (Typ: 3; OrbitR: 80;  Radius: 7;   HasAtmo: True;  ColR: 220; ColG: 180; ColB: 110; AtmoR: 255; AtmoG: 200; AtmoB: 150;),
    (Typ: 3; OrbitR: 100; Radius: 6;   HasAtmo: True;  ColR: 200; ColG: 170; ColB: 100; AtmoR: 255; AtmoG: 210; AtmoB: 160;),
    (Typ: 4; OrbitR: 120; Radius: 4;   HasAtmo: True;  ColR: 150; ColG: 200; ColB: 230; AtmoR: 180; AtmoG: 210; AtmoB: 255;)
  );
var
  I: Integer;
begin
  S.Kind := skSol;
  S.SunRadius := UF_SUN_RADIUS;
  S.SunColor := MakeCol(255, 220, 100);
  S.IsBinary := False;
  SetLength(S.Planets, 7);
  for I := 0 to 6 do
  begin
    S.Planets[I].PlanetType := TUFPlanetType(SOL_DATA[I].Typ);
    S.Planets[I].Radius := SOL_DATA[I].Radius;
    S.Planets[I].OrbitRadius := SOL_DATA[I].OrbitR;
    S.Planets[I].OrbitAngle := (I / 7.0) * 2.0 * PI;
    S.Planets[I].OrbitSpeed := UF_ORBIT_SPEED_BASE / Sqrt(SOL_DATA[I].OrbitR / UF_ORBIT_MIN_RADIUS);
    S.Planets[I].PlanetColor := MakeCol(SOL_DATA[I].ColR, SOL_DATA[I].ColG, SOL_DATA[I].ColB);
    S.Planets[I].AtmosphereColor := MakeCol(SOL_DATA[I].AtmoR, SOL_DATA[I].AtmoG, SOL_DATA[I].AtmoB);
    S.Planets[I].HasAtmosphere := SOL_DATA[I].HasAtmo;
    S.Planets[I].CurrentPos := Vector3Create(0, 0, 0);
  end;
  S.BoundsRadius := GetSystemBoundsRadius(S);
  ComputePlanetPositions(S);
end;

procedure TUniverseFormer.GenerateRandomSystem(var S: TUFSystem);
var
  Rng: Cardinal;
  PlanetCount, I: Integer;
  OrbitR: Single;
  PType: TUFPlanetType;
  SunColorPick: Integer;

  function Rand: Single;
  begin
    Rng := Rng xor (Rng shl 13);
    Rng := Rng xor (Rng shr 17);
    Rng := Rng xor (Rng shl 5);
    Result := (Rng and $00FFFFFF) / $00FFFFFF;
  end;
begin
  Rng := Cardinal(Random(MaxInt));
  if Rng = 0 then
    Rng := 1;
  S.Kind := skRandom;
  S.SunRadius := UF_SUN_RADIUS * (0.7 + Rand * 0.6);
  S.IsBinary := False;
  SunColorPick := Trunc(Rand * 4);
  case SunColorPick of
    0: S.SunColor := MakeCol(255, 220, 100);
    1: S.SunColor := MakeCol(255, 150, 50);
    2: S.SunColor := MakeCol(255, 100, 50);
    3: S.SunColor := MakeCol(255, 240, 220);
  end;
  PlanetCount := 3 + Trunc(Rand * 5);
  OrbitR := UF_ORBIT_MIN_RADIUS;
  SetLength(S.Planets, PlanetCount);
  for I := 0 to PlanetCount - 1 do
  begin
    OrbitR := OrbitR + UF_ORBIT_STEP + Rand * 10;
    PType := TUFPlanetType(Trunc(Rand * 5));
    S.Planets[I].PlanetType := PType;
    S.Planets[I].Radius := 1.5 + Rand * 5;  // Was 6 + Rand * 20
    S.Planets[I].OrbitRadius := OrbitR;
    S.Planets[I].OrbitAngle := Rand * 2.0 * PI;
    S.Planets[I].OrbitSpeed := UF_ORBIT_SPEED_BASE / Sqrt(OrbitR / UF_ORBIT_MIN_RADIUS);
    case PType of
      0: begin S.Planets[I].PlanetColor := MakeCol(140, 120, 100); S.Planets[I].AtmosphereColor := MakeCol(100, 80, 60);  S.Planets[I].HasAtmosphere := False; end;
      1: begin S.Planets[I].PlanetColor := MakeCol(60, 120, 200);  S.Planets[I].AtmosphereColor := MakeCol(100, 150, 255); S.Planets[I].HasAtmosphere := True;  end;
      2: begin S.Planets[I].PlanetColor := MakeCol(200, 90, 50);   S.Planets[I].AtmosphereColor := MakeCol(200, 100, 50);  S.Planets[I].HasAtmosphere := True;  end;
      3: begin S.Planets[I].PlanetColor := MakeCol(220, 180, 110); S.Planets[I].AtmosphereColor := MakeCol(255, 200, 150); S.Planets[I].HasAtmosphere := True;  end;
      4: begin S.Planets[I].PlanetColor := MakeCol(220, 230, 245); S.Planets[I].AtmosphereColor := MakeCol(180, 210, 255); S.Planets[I].HasAtmosphere := True;  end;
    end;
    S.Planets[I].CurrentPos := Vector3Create(0, 0, 0);
  end;
  S.BoundsRadius := GetSystemBoundsRadius(S);
  ComputePlanetPositions(S);
end;

procedure TUniverseFormer.GenerateBinarySystem(var S: TUFSystem);
var
  Rng: Cardinal;
  PlanetCount, I: Integer;
  OrbitR: Single;
  PType: TUFPlanetType;

  function Rand: Single;
  begin
    Rng := Rng xor (Rng shl 13);
    Rng := Rng xor (Rng shr 17);
    Rng := Rng xor (Rng shl 5);
    Result := (Rng and $00FFFFFF) / $00FFFFFF;
  end;
begin
  Rng := Cardinal(Random(MaxInt));
  if Rng = 0 then
    Rng := 1;
  S.Kind := skBinary;
  S.SunRadius := UF_SUN_RADIUS * 0.8;
  S.Sun2Radius := UF_SUN_RADIUS * 0.6;
  S.IsBinary := True;
  S.Sun2Offset := 35.0 + Rand * 25;  // Was 150 + Rand * 100
  S.BinaryAngle := 0;
  S.BinarySpeed := 0.1;
  S.SunColor := MakeCol(255, 200, 100);
  S.Sun2Color := MakeCol(255, 160, 80);
  PlanetCount := 3 + Trunc(Rand * 3);
  OrbitR := S.Sun2Offset * 1.5;
  SetLength(S.Planets, PlanetCount);
  for I := 0 to PlanetCount - 1 do
  begin
    OrbitR := OrbitR + UF_ORBIT_STEP + Rand * 10;
    PType := TUFPlanetType(Trunc(Rand * 5));
    S.Planets[I].PlanetType := PType;
    S.Planets[I].Radius := 1.5 + Rand * 4.5;  // Was 6 + Rand * 18
    S.Planets[I].OrbitRadius := OrbitR;
    S.Planets[I].OrbitAngle := Rand * 2.0 * PI;
    S.Planets[I].OrbitSpeed := UF_ORBIT_SPEED_BASE / Sqrt(OrbitR / UF_ORBIT_MIN_RADIUS);
    case PType of
      0: begin S.Planets[I].PlanetColor := MakeCol(140, 120, 100); S.Planets[I].AtmosphereColor := MakeCol(100, 80, 60);  S.Planets[I].HasAtmosphere := False; end;
      1: begin S.Planets[I].PlanetColor := MakeCol(60, 120, 200);  S.Planets[I].AtmosphereColor := MakeCol(100, 150, 255); S.Planets[I].HasAtmosphere := True;  end;
      2: begin S.Planets[I].PlanetColor := MakeCol(200, 90, 50);   S.Planets[I].AtmosphereColor := MakeCol(200, 100, 50);  S.Planets[I].HasAtmosphere := True;  end;
      3: begin S.Planets[I].PlanetColor := MakeCol(220, 180, 110); S.Planets[I].AtmosphereColor := MakeCol(255, 200, 150); S.Planets[I].HasAtmosphere := True;  end;
      4: begin S.Planets[I].PlanetColor := MakeCol(220, 230, 245); S.Planets[I].AtmosphereColor := MakeCol(180, 210, 255); S.Planets[I].HasAtmosphere := True;  end;
    end;
    S.Planets[I].CurrentPos := Vector3Create(0, 0, 0);
  end;
  S.BoundsRadius := GetSystemBoundsRadius(S);
  ComputePlanetPositions(S);
end;

procedure TUniverseFormer.GenerateDwarfSystem(var S: TUFSystem);
var
  Rng: Cardinal;
  PlanetCount, I: Integer;
  OrbitR: Single;

  function Rand: Single;
  begin
    Rng := Rng xor (Rng shl 13);
    Rng := Rng xor (Rng shr 17);
    Rng := Rng xor (Rng shl 5);
    Result := (Rng and $00FFFFFF) / $00FFFFFF;
  end;
begin
  Rng := Cardinal(Random(MaxInt));
  if Rng = 0 then
    Rng := 1;
  S.Kind := skDwarf;
  S.SunRadius := UF_SUN_RADIUS * 0.4;
  S.SunColor := MakeCol(255, 100, 50);
  S.IsBinary := False;
  PlanetCount := 1 + Trunc(Rand * 2);
  OrbitR := UF_ORBIT_MIN_RADIUS * 0.6;
  SetLength(S.Planets, PlanetCount);
  for I := 0 to PlanetCount - 1 do
  begin
    OrbitR := OrbitR + 12 + Rand * 8;  // Was 50 + Rand * 30
    S.Planets[I].PlanetType := 0;
    S.Planets[I].Radius := 1 + Rand * 1.5;  // Was 4 + Rand * 6
    S.Planets[I].OrbitRadius := OrbitR;
    S.Planets[I].OrbitAngle := Rand * 2.0 * PI;
    S.Planets[I].OrbitSpeed := UF_ORBIT_SPEED_BASE / Sqrt(OrbitR / UF_ORBIT_MIN_RADIUS);
    S.Planets[I].PlanetColor := MakeCol(140, 120, 100);
    S.Planets[I].AtmosphereColor := MakeCol(100, 80, 60);
    S.Planets[I].HasAtmosphere := False;
    S.Planets[I].CurrentPos := Vector3Create(0, 0, 0);
  end;
  S.BoundsRadius := GetSystemBoundsRadius(S);
  ComputePlanetPositions(S);
end;

procedure TUniverseFormer.GenerateEmptySystem(var S: TUFSystem);
begin
  S.Kind := skEmpty;
  S.SunRadius := UF_SUN_RADIUS;
  S.SunColor := MakeCol(255, 240, 200);
  S.IsBinary := False;
  SetLength(S.Planets, 0);
  S.BoundsRadius := S.SunRadius + 20;
end;

function TUniverseFormer.SpawnSystem(Kind: TUFSystemKind; const Pos: TVector3): Integer;
var
  Idx: Integer;
begin
  Result := -1;
  if FSystemCount >= UF_MAX_SYSTEMS then
    Exit;
  Idx := FSystemCount;
  Inc(FSystemCount);
  FSystems[Idx] := Default(TUFSystem);
  FSystems[Idx].Position := Pos;
  FSystems[Idx].TargetPosition := Pos;  // Initially no movement
  FSystems[Idx].IsDead := False;
  case Kind of
    skSol:    GenerateSolSystem(FSystems[Idx]);
    skRandom: GenerateRandomSystem(FSystems[Idx]);
    skBinary: GenerateBinarySystem(FSystems[Idx]);
    skDwarf:  GenerateDwarfSystem(FSystems[Idx]);
    skEmpty:  GenerateEmptySystem(FSystems[Idx]);
  end;
  FSystems[Idx].Name := AnsiString('System_' + IntToStr(Idx));
  Result := Idx;
  FSelectedSystem := Idx;
end;

// ============================================================================
// Smart placement - finds a non-colliding position near the requested spot
// ============================================================================

function TUniverseFormer.FindFreePositionNear(const RequestedPos: TVector3): TVector3;
var
  I, Attempt: Integer;
  TestPos: TVector3;
  Angle, Radius: Single;
  FoundCollision: Boolean;
  Dist: Single;
begin
  // First try the requested position itself
  Result := RequestedPos;
  FoundCollision := False;
  for I := 0 to FSystemCount - 1 do
  begin
    if FSystems[I].IsDead then
      Continue;
    Dist := Vector3Distance(Result, FSystems[I].Position);
    if Dist < (FSystems[I].BoundsRadius + UF_MIN_SYSTEM_GAP) then
    begin
      FoundCollision := True;
      Break;
    end;
  end;
  if not FoundCollision then
    Exit;

  // Otherwise spiral outward looking for a free spot. We scale the
  // search radius with the attempt number so we eventually search
  // far enough to find a free spot even in a dense universe.
  for Attempt := 1 to UF_PLACE_ATTEMPTS do
  begin
    Angle := Random * 2.0 * PI;
    // Radius grows with each attempt: 50, 100, 150, 200, ...
    // This ensures we eventually find a free spot even in a dense universe.
    Radius := 50.0 * Attempt + Random * 50.0;
    TestPos.x := RequestedPos.x + Cos(Angle) * Radius;
    TestPos.y := 0;
    TestPos.z := RequestedPos.z + Sin(Angle) * Radius;

    FoundCollision := False;
    for I := 0 to FSystemCount - 1 do
    begin
      if FSystems[I].IsDead then
        Continue;
      Dist := Vector3Distance(TestPos, FSystems[I].Position);
      if Dist < (FSystems[I].BoundsRadius + UF_MIN_SYSTEM_GAP) then
      begin
        FoundCollision := True;
        Break;
      end;
    end;
    if not FoundCollision then
    begin
      Result := TestPos;
      Exit;
    end;
  end;
  // All attempts failed - just return the requested pos. The caller
  // (SpawnSystemSmart) will push the conflicting systems out of the
  // way so the new system can spawn exactly where the user clicked.
  Result := RequestedPos;
end;

function TUniverseFormer.SpawnSystemSmart(Kind: TUFSystemKind; const RequestedPos: TVector3): Integer;
var
  I: Integer;
  Dist, PushDist: Single;
  PushDir, NewTarget: TVector3;
  EstimatedNewBounds: Single;
begin
  // ALWAYS spawn exactly at RequestedPos. Before we do, push away any
  // existing systems that are too close by setting their TargetPosition
  // outward. The smooth lerp in UpdateOrbits handles the actual
  // movement animation.

  EstimatedNewBounds := 160.0;

  for I := 0 to FSystemCount - 1 do
  begin
    if FSystems[I].IsDead then
      Continue;

    Dist := Vector3Distance(FSystems[I].Position, RequestedPos);

    if Dist < (EstimatedNewBounds + FSystems[I].BoundsRadius + UF_MIN_SYSTEM_GAP) then
    begin
      if Dist > 0.01 then
      begin
        PushDir := Vector3Normalize(Vector3Subtract(FSystems[I].Position, RequestedPos));
      end
      else
      begin
        PushDir := Vector3Normalize(Vector3Create(Random - 0.5, 0, Random - 0.5));
      end;

      PushDist := (EstimatedNewBounds + FSystems[I].BoundsRadius + UF_MIN_SYSTEM_GAP) - Dist;
      if PushDist < 50.0 then
        PushDist := 50.0;

      // Set TARGET position (not current position) - the smooth
      // lerp in UpdateOrbits will animate the system sliding
      // outward over the next few frames.
      NewTarget.x := FSystems[I].Position.x + PushDir.x * PushDist;
      NewTarget.y := FSystems[I].Position.y;
      NewTarget.z := FSystems[I].Position.z + PushDir.z * PushDist;

      FSystems[I].TargetPosition := NewTarget;
    end;
  end;

  // Now spawn the new system exactly where the user clicked.
  Result := SpawnSystem(Kind, RequestedPos);
end;

procedure TUniverseFormer.SpawnFreePlanet(PlanetType: TUFPlanetType; const Pos: TVector3);
var
  I, BestSys: Integer;
  BestDist, Dist: Single;
  Sys: ^TUFSystem;
  P: ^TUFPlanet;
  Count: Integer;
  OrbitR, Angle: Single;
begin
  if FSystemCount >= UF_MAX_SYSTEMS then
    Exit;

  // Find the nearest system that has a sun (not a FreePlanet-only system)
  BestSys := -1;
  BestDist := 1e9;
  for I := 0 to FSystemCount - 1 do
  begin
    if FSystems[I].IsDead then
      Continue;
    if FSystems[I].SunRadius <= 0 then
      Continue; // Skip FreePlanet placeholder systems
    Dist := Vector3Distance(FSystems[I].Position, Pos);
    if Dist < BestDist then
    begin
      BestDist := Dist;
      BestSys := I;
    end;
  end;

  // If we found a sun within a reasonable distance (say 500 units),
  // add the planet to that system's orbit. This is the behaviour the
  // user wants: click near a sun → planet joins that system and
  // orbits like the others.
  if (BestSys >= 0) and (BestDist < 500.0) then
  begin
    Sys := @FSystems[BestSys];
    Count := Length(Sys^.Planets);
    SetLength(Sys^.Planets, Count + 1);
    P := @Sys^.Planets[Count];

    P^.PlanetType := PlanetType;
    P^.Radius := 1.5 + Random * 3.0;

    // Orbit radius = distance from sun to click point, clamped to
    // at least UF_ORBIT_MIN_RADIUS so the planet doesn't sit inside
    // the sun.
    OrbitR := Max(UF_ORBIT_MIN_RADIUS, BestDist);
    P^.OrbitRadius := OrbitR;

    // Orbit angle = direction from sun to click point
    Angle := ArcTan2(Pos.z - Sys^.Position.z, Pos.x - Sys^.Position.x);
    P^.OrbitAngle := Angle;

    // Orbit speed follows the same inverse-square-root law as the
    // generated planets so it visually matches.
    P^.OrbitSpeed := UF_ORBIT_SPEED_BASE / Sqrt(OrbitR / UF_ORBIT_MIN_RADIUS);

    // Initial position at the current orbit angle
    P^.CurrentPos := Vector3Add(Sys^.Position, Vector3Create(
      Cos(Angle) * OrbitR, 0, Sin(Angle) * OrbitR));

    case PlanetType of
      0: begin P^.PlanetColor := MakeCol(140, 120, 100); P^.AtmosphereColor := MakeCol(100, 80, 60);  P^.HasAtmosphere := False; end;
      1: begin P^.PlanetColor := MakeCol(60, 120, 200);  P^.AtmosphereColor := MakeCol(100, 150, 255); P^.HasAtmosphere := True;  end;
      2: begin P^.PlanetColor := MakeCol(200, 90, 50);   P^.AtmosphereColor := MakeCol(200, 100, 50);  P^.HasAtmosphere := True;  end;
      3: begin P^.PlanetColor := MakeCol(220, 180, 110); P^.AtmosphereColor := MakeCol(255, 200, 150); P^.HasAtmosphere := True;  end;
      4: begin P^.PlanetColor := MakeCol(220, 230, 245); P^.AtmosphereColor := MakeCol(180, 210, 255); P^.HasAtmosphere := True;  end;
    end;

    // Update bounds radius so selection + push logic accounts for
    // the new outermost planet.
    Sys^.BoundsRadius := GetSystemBoundsRadius(Sys^);

    FSelectedSystem := BestSys;
  end
  else
  begin
    // No sun nearby → spawn as a rogue free planet (no orbit).
    // This is the fallback for planets placed in empty space.
    BestSys := -1;
    for Count := 0 to FSystemCount - 1 do
    begin
      if FSystems[Count].IsDead and (Length(FSystems[Count].FreePlanets) > 0) then
      begin
        BestSys := Count;
        Break;
      end;
    end;

    if BestSys = -1 then
    begin
      BestSys := FSystemCount;
      Inc(FSystemCount);
      FSystems[BestSys] := Default(TUFSystem);
      FSystems[BestSys].Position := Pos;
      FSystems[BestSys].TargetPosition := Pos;
      FSystems[BestSys].IsDead := False;
      FSystems[BestSys].Kind := skEmpty;
      FSystems[BestSys].Name := AnsiString('FreePlanets');
      FSystems[BestSys].SunRadius := 0;
      FSystems[BestSys].BoundsRadius := 5;
    end;

    Sys := @FSystems[BestSys];
    Count := Length(Sys^.FreePlanets);
    SetLength(Sys^.FreePlanets, Count + 1);
    P := @Sys^.FreePlanets[Count];
    P^.PlanetType := PlanetType;
    P^.Radius := 2.0 + Random * 3.0;
    P^.CurrentPos := Pos;
    P^.OrbitRadius := 0;
    P^.OrbitAngle := 0;
    P^.OrbitSpeed := 0;
    case PlanetType of
      0: begin P^.PlanetColor := MakeCol(140, 120, 100); P^.AtmosphereColor := MakeCol(100, 80, 60);  P^.HasAtmosphere := False; end;
      1: begin P^.PlanetColor := MakeCol(60, 120, 200);  P^.AtmosphereColor := MakeCol(100, 150, 255); P^.HasAtmosphere := True;  end;
      2: begin P^.PlanetColor := MakeCol(200, 90, 50);   P^.AtmosphereColor := MakeCol(200, 100, 50);  P^.HasAtmosphere := True;  end;
      3: begin P^.PlanetColor := MakeCol(220, 180, 110); P^.AtmosphereColor := MakeCol(255, 200, 150); P^.HasAtmosphere := True;  end;
      4: begin P^.PlanetColor := MakeCol(220, 230, 245); P^.AtmosphereColor := MakeCol(180, 210, 255); P^.HasAtmosphere := True;  end;
    end;

    FSelectedSystem := BestSys;
  end;
end;

// ============================================================================
// Random Universe generator - spawns thousands of systems in a galactic
// disk pattern. Mimics the C++ galaxy sample's exponential disk + bulge.
// ============================================================================

procedure TUniverseFormer.GenerateRandomUniverse(const CenterPos: TVector3; Count: Integer);
var
  Rng: Cardinal;
  I: Integer;
  LocalR, Angle, Z, U: Single;
  Pos: TVector3;
  KindRoll: Single;
  SysKind: TUFSystemKind;
  DiskScaleLength: Single;
  BulgeRadius: Single;
  DiskThickness: Single;

  function Rand: Single;
  begin
    Rng := Rng xor (Rng shl 13);
    Rng := Rng xor (Rng shr 17);
    Rng := Rng xor (Rng shl 5);
    Result := (Rng and $00FFFFFF) / $00FFFFFF;
  end;
begin
  Rng := Cardinal(Random(MaxInt));
  if Rng = 0 then
    Rng := 1;

  // Galactic structure parameters - true 3D distribution, not a flat
  // 2D disk. We use a very large Y spread so systems are distributed
  // in a 3D volume. This GUARANTEES no overlaps because systems occupy
  // a volume rather than being crammed onto a plane.
  DiskScaleLength := 200.0;
  BulgeRadius := 50.0;
  DiskThickness := 400.0;  // Very large Y spread - guarantees 3D separation

  for I := 0 to Count - 1 do
  begin
    if FSystemCount >= UF_MAX_SYSTEMS then
      Break;

    // Exponential disk profile: r = -L * ln(1 - u)
    U := Rand;
    LocalR := -DiskScaleLength * Ln(1.0 - U * 0.99);

    Angle := Rand * 2.0 * PI;

    // Y (up/down) position - large spread to guarantee 3D separation.
    // The previous Exp() damping made most systems clump at Y=0.
    // We use a full Gaussian with a large sigma and minimal damping
    // so systems spread across the full Y range.
    U := Rand;
    if U < 1e-6 then
      U := 1e-6;
    Z := Sqrt(-2.0 * Ln(U)) * Cos(2.0 * PI * Rand)
       * DiskThickness
       * Exp(-LocalR / (BulgeRadius * 4.0));  // Reduced damping for more Y spread

    Pos.x := CenterPos.x + Cos(Angle) * LocalR;
    Pos.y := CenterPos.y + Z;
    Pos.z := CenterPos.z + Sin(Angle) * LocalR;

    // Pick a system kind. Weighted toward Random (most common), with
    // occasional Sol-like, Binary, Dwarf, and Empty systems for
    // variety.
    KindRoll := Rand;
    if KindRoll < 0.55 then
      SysKind := skRandom
    else if KindRoll < 0.70 then
      SysKind := skSol
    else if KindRoll < 0.85 then
      SysKind := skBinary
    else if KindRoll < 0.95 then
      SysKind := skDwarf
    else
      SysKind := skEmpty;

    // CRITICAL: Use SpawnSystemSmart, NOT SpawnSystem. Smart placement
    // checks every existing system and pushes the new one away if it's
    // too close. Without this, all 20 systems pile up at the same
    // spot (the disk pattern generates positions that are close together
    // in the bulge) and you get the "Big Bang collapse" the user
    // described - everything overlapping at 5 points.
    SpawnSystemSmart(SysKind, Pos);
  end;
end;

procedure TUniverseFormer.DeleteSelectedSystem;
begin
  if (FSelectedSystem < 0) or (FSelectedSystem >= FSystemCount) then
    Exit;
  FSystems[FSelectedSystem].IsDead := True;
  FSystems[FSelectedSystem].Planets := nil;
  FSelectedSystem := -1;
end;

procedure TUniverseFormer.ClearAll;
var
  I: Integer;
begin
  for I := 0 to FSystemCount - 1 do
  begin
    FSystems[I].IsDead := True;
    FSystems[I].Planets := nil;
  end;
  FSelectedSystem := -1;
  FSelectedTemplate := -1;
end;

function TUniverseFormer.LiveSystemCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FSystemCount - 1 do
    if not FSystems[I].IsDead then
      Inc(Result);
end;

function TUniverseFormer.LiveObjectCount: Integer;
begin
  Result := LiveSystemCount;
end;

// ============================================================================
// Orbit animation
// ============================================================================

procedure TUniverseFormer.UpdateOrbits(const dt: Single);
var
  I, J: Integer;
  S: ^TUFSystem;
  Center: TVector3;
  LerpSpeed: Single;
begin
  if FPaused then
    Exit;
  if (FSystems = nil) or (Length(FSystems) = 0) then
    Exit;

  // Lerp speed for smooth push-away animation. 3.0 = fast enough to
  // feel responsive but slow enough to see the motion.
  LerpSpeed := 3.0;

  for I := 0 to FSystemCount - 1 do
  begin
    if I >= Length(FSystems) then
      Break;
    S := @FSystems[I];
    if S^.IsDead then
      Continue;

    // Smooth lerp Position toward TargetPosition. This produces the
    // "slowly moving away" effect when SpawnSystemSmart pushes other
    // systems aside.
    S^.Position.x := S^.Position.x + (S^.TargetPosition.x - S^.Position.x) * LerpSpeed * dt;
    S^.Position.y := S^.Position.y + (S^.TargetPosition.y - S^.Position.y) * LerpSpeed * dt;
    S^.Position.z := S^.Position.z + (S^.TargetPosition.z - S^.Position.z) * LerpSpeed * dt;

    // Update planet positions based on the (possibly moving) system center
    Center := S^.Position;
    for J := 0 to High(S^.Planets) do
    begin
      S^.Planets[J].OrbitAngle := S^.Planets[J].OrbitAngle + S^.Planets[J].OrbitSpeed * dt;
      S^.Planets[J].CurrentPos := Vector3Add(Center, Vector3Create(
        Cos(S^.Planets[J].OrbitAngle) * S^.Planets[J].OrbitRadius, 0,
        Sin(S^.Planets[J].OrbitAngle) * S^.Planets[J].OrbitRadius));
    end;
    // Free planets don't orbit, but if the parent system was pushed,
    // their CurrentPos must follow the system's Position. We store
    // their relative offset at spawn time in OrbitRadius/OrbitAngle
    // is 0 for free planets, so we just use the system center.
    for J := 0 to High(S^.FreePlanets) do
    begin
      S^.FreePlanets[J].CurrentPos := Center;
    end;
    if S^.IsBinary then
      S^.BinaryAngle := S^.BinaryAngle + S^.BinarySpeed * dt;
  end;
end;

// ============================================================================
// Input handling
// ============================================================================

procedure TUniverseFormer.HandleCameraInput(const MousePos: TVector2; const dt: Single);
var
  P: TPoint;
  PanSpeed, FwdX, FwdZ, RightX, RightZ: Single;
begin
  if (GetAsyncKeyState(VK_MBUTTON) and $8000) <> 0 then
  begin
    GetCursorPos(P);
    if FDraggingRMB then
    begin
      FCamYaw := FCamYaw - (P.x - FLastMouse.x) * 0.006;
      FCamPitch := EnsureRange(FCamPitch + (P.y - FLastMouse.y) * 0.006, 0.05, 1.53);
      FCameraMoved := True;
    end
    else
      FDraggingRMB := True;
    FLastMouse := P;
  end
  else
    FDraggingRMB := False;

  PanSpeed := 120.0 * dt;
  FwdX := -Sin(FCamYaw);
  FwdZ := -Cos(FCamYaw);
  RightX := Cos(FCamYaw);
  RightZ := -Sin(FCamYaw);
  if (GetAsyncKeyState(Ord('W')) and $8000) <> 0 then
  begin
    FCamera.target.x := FCamera.target.x + FwdX * PanSpeed;
    FCamera.target.z := FCamera.target.z + FwdZ * PanSpeed;
    FCameraMoved := True;
  end;
  if (GetAsyncKeyState(Ord('S')) and $8000) <> 0 then
  begin
    FCamera.target.x := FCamera.target.x - FwdX * PanSpeed;
    FCamera.target.z := FCamera.target.z - FwdZ * PanSpeed;
    FCameraMoved := True;
  end;
  if (GetAsyncKeyState(Ord('A')) and $8000) <> 0 then
  begin
    FCamera.target.x := FCamera.target.x - RightX * PanSpeed;
    FCamera.target.z := FCamera.target.z - RightZ * PanSpeed;
    FCameraMoved := True;
  end;
  if (GetAsyncKeyState(Ord('D')) and $8000) <> 0 then
  begin
    FCamera.target.x := FCamera.target.x + RightX * PanSpeed;
    FCamera.target.z := FCamera.target.z + RightZ * PanSpeed;
    FCameraMoved := True;
  end;
  if GetMouseWheelMove() <> 0 then
  begin
    FCamDist := EnsureRange(FCamDist - GetMouseWheelMove() * 20.0, 30, 6000);
    FCameraMoved := True;
  end;
  if FCameraMoved then
  begin
    FCamera.position := Vector3Create(
      FCamera.target.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist,
      FCamera.target.y + Sin(FCamPitch) * FCamDist,
      FCamera.target.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
    FCameraMoved := False;
  end;
end;

procedure TUniverseFormer.HandlePlacementInput(const MousePos: TVector2);
var
  Ray: TRay;
  WorldPos: TVector3;
  SysIdx: Integer;
  LMBDown, LMBClicked: Boolean;
begin
  LMBDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;
  LMBClicked := LMBDown and (not FLMBWasDown);

  if (GetAsyncKeyState(VK_DELETE) and $1) <> 0 then
  begin
    DeleteSelectedSystem;
    Exit;
  end;

  if (GetAsyncKeyState(VK_ESCAPE) and $1) <> 0 then
  begin
    FSelectedSystem := -1;
    FSelectedTemplate := -1;
    Exit;
  end;

  if not LMBClicked then
    Exit;

  Ray := GetScreenToWorldRay(MousePos, FCamera);

  if FSelectedTemplate >= 0 then
  begin
    if FTemplates[FSelectedTemplate].Kind = tkUniverse then
    begin
      // "Random Universe" template: spawn a galaxy at the click
      // position. 20 systems - framerate-friendly and readable.
      if RaycastToGround(Ray, WorldPos) then
        GenerateRandomUniverse(WorldPos, 20);
      // Universe is a one-shot action - disarm the brush so the user
      // doesn't accidentally spawn another batch on the next click.
      FSelectedTemplate := -1;
    end
    else if FTemplates[FSelectedTemplate].Kind = tkSystem then
    begin
      if RaycastToGround(Ray, WorldPos) then
        SpawnSystemSmart(FTemplates[FSelectedTemplate].SystemKind, WorldPos);
    end
    else if FTemplates[FSelectedTemplate].Kind = tkPlanet then
    begin
      // Single planet placement. Free planets don't push other systems
      // away - they just appear where the user clicks. The user can use
      // this to add planets to an existing system (visually) or place
      // rogue planets in empty space.
      if RaycastToGround(Ray, WorldPos) then
        SpawnFreePlanet(FTemplates[FSelectedTemplate].PlanetType, WorldPos);
    end;
    Exit;
  end;

  SysIdx := GetSystemUnderMouse(Ray);
  FSelectedSystem := SysIdx;
end;

procedure TUniverseFormer.Update(dt: Single; const MousePos: TVector2;
  ScreenW, ScreenH: Integer);
var
  TplIdx: Integer;
begin
  FMousePos := MousePos;
  FScreenW := ScreenW;
  FScreenH := ScreenH;
  FTime := FTime + dt;

  if IsMouseOverToolbar(MousePos) then
  begin
    if IsMouseButtonPressed(MOUSE_LEFT_BUTTON) then
    begin
      TplIdx := GetTemplateAt(MousePos);
      if TplIdx >= 0 then
      begin
        if FTemplates[TplIdx].Kind = tkClear then
          ClearAll
        else if FTemplates[TplIdx].Kind = tkUniverse then
        begin
          GenerateRandomUniverse(FCamera.target, 20);
        end
        else
        begin
          // Both tkPlanet and tkSystem arm the brush
          if FSelectedTemplate = TplIdx then
            FSelectedTemplate := -1
          else
            FSelectedTemplate := TplIdx;
        end;
      end;
    end;
    FLMBWasDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;
    Exit;
  end;

  HandleCameraInput(MousePos, dt);
  HandlePlacementInput(MousePos);
  UpdateOrbits(dt);
  FLMBWasDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;
end;

// ============================================================================
// Rendering
// ============================================================================

procedure TUniverseFormer.Render3DScene;
var
  I, J: Integer;
  S: ^TUFSystem;
  Dist: Single;
  SunPos, Sun2Pos: TVector3;
  CustomProj: TMatrix;
  PCol: TColorB;
  V0, V1, V2, V3, V4, V5, V6, V7: TVector3;
  H, Cx, Cy, Cz: Single;
begin
  if (FSystems = nil) or (Length(FSystems) = 0) then
    Exit;

  BeginMode3D(FCamera);
  try
    // CRITICAL: Override Raylib's default far plane (1000) AFTER BeginMode3D.
    CustomProj := MatrixPerspective(FCamera.fovy * DEG2RAD,
      GetScreenWidth() / GetScreenHeight(), 0.01, 10000.0);
    rlSetMatrixProjection(CustomProj);

    // ---- 1. GRID (batched lines) ----
    rlSetBlendMode(BLEND_ALPHA);
    rlDisableDepthTest;
    rlBegin(RL_LINES);
    try
      rlColor4ub(80, 80, 80, 80);
      for I := -20 to 20 do
      begin
        rlVertex3f(I * 100, 0, -2000);
        rlVertex3f(I * 100, 0, 2000);
        rlVertex3f(-2000, 0, I * 100);
        rlVertex3f(2000, 0, I * 100);
      end;

      // ---- 2. ORBIT RINGS (batched lines, same block) ----
      for I := 0 to FSystemCount - 1 do
      begin
        if I >= Length(FSystems) then Break;
        S := @FSystems[I];
        if S^.IsDead then Continue;
        Dist := Vector3Distance(S^.Position, FCamera.position);

        // Only draw orbit rings for systems in Far or Near LOD
        if Dist <= UF_LOD_MED_DIST then
        begin
          if Dist > UF_LOD_FAR_DIST then
            // Far LOD - dimmer rings
            for J := 0 to High(S^.Planets) do
              DrawOrbitRingBatched(S^.Position, S^.Planets[J].OrbitRadius, Fade(GRAY, 0.2))
          else
            // Near LOD - brighter rings
            for J := 0 to High(S^.Planets) do
              DrawOrbitRingBatched(S^.Position, S^.Planets[J].OrbitRadius, Fade(GRAY, 0.35));
        end;
      end;
    finally
      rlEnd;
    end;
    rlEnableDepthTest;

    // ---- 3. SUNS & PLANETS (batched octahedrons, no textures) ----
    // We abandon DrawModel here entirely. Instead we push raw octahedron
    // geometry for every sun and planet in a single rlBegin block.
    // This reduces 1700+ DrawModel calls to 1 DrawCall.
    rlBegin(RL_TRIANGLES);
    try
      for I := 0 to FSystemCount - 1 do
      begin
        if I >= Length(FSystems) then Break;
        S := @FSystems[I];
        if S^.IsDead then Continue;

        Dist := Vector3Distance(S^.Position, FCamera.position);

        // SUN (always drawn, even in Far LOD)
        if S^.IsBinary then
        begin
          SunPos := Vector3Add(S^.Position, Vector3Create(
            Cos(S^.BinaryAngle) * S^.Sun2Offset * 0.5, 0,
            Sin(S^.BinaryAngle) * S^.Sun2Offset * 0.5));
          Sun2Pos := Vector3Add(S^.Position, Vector3Create(
            -Cos(S^.BinaryAngle) * S^.Sun2Offset * 0.5, 0,
            -Sin(S^.BinaryAngle) * S^.Sun2Offset * 0.5));

          // Sun 1
          H := S^.SunRadius * 0.5;
          Cx := SunPos.x; Cy := SunPos.y; Cz := SunPos.z;
          rlColor4ub(255, 220, 100, 255);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx + H, Cy, Cz);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx - H, Cy, Cz);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx - H, Cy, Cz);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx + H, Cy, Cz);

          // Sun 2
          H := S^.Sun2Radius * 0.5;
          Cx := Sun2Pos.x; Cy := Sun2Pos.y; Cz := Sun2Pos.z;
          rlColor4ub(255, 180, 80, 255);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx + H, Cy, Cz);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx - H, Cy, Cz);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx - H, Cy, Cz);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx + H, Cy, Cz);
        end
        else
        begin
          H := S^.SunRadius * 0.5;
          Cx := S^.Position.x; Cy := S^.Position.y; Cz := S^.Position.z;
          rlColor4ub(255, 220, 100, 255);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx + H, Cy, Cz);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
          rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx - H, Cy, Cz);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx - H, Cy, Cz);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
          rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx + H, Cy, Cz);
        end;

        // PLANETS (only draw in Near LOD)
        if Dist <= UF_LOD_MED_DIST then
        begin
          for J := 0 to High(S^.Planets) do
          begin
            PCol := S^.Planets[J].PlanetColor;
            H := S^.Planets[J].Radius * 0.5;
            Cx := S^.Planets[J].CurrentPos.x;
            Cy := S^.Planets[J].CurrentPos.y;
            Cz := S^.Planets[J].CurrentPos.z;
            rlColor4ub(PCol.r, PCol.g, PCol.b, 255);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx + H, Cy, Cz);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx - H, Cy, Cz);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx - H, Cy, Cz);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx + H, Cy, Cz);
          end;

          // Free planets
          for J := 0 to High(S^.FreePlanets) do
          begin
            PCol := S^.FreePlanets[J].PlanetColor;
            H := S^.FreePlanets[J].Radius * 0.5;
            Cx := S^.FreePlanets[J].CurrentPos.x;
            Cy := S^.FreePlanets[J].CurrentPos.y;
            Cz := S^.FreePlanets[J].CurrentPos.z;
            rlColor4ub(PCol.r, PCol.g, PCol.b, 255);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx + H, Cy, Cz);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
            rlVertex3f(Cx, Cy + H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx - H, Cy, Cz);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx + H, Cy, Cz); rlVertex3f(Cx, Cy, Cz + H);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz + H); rlVertex3f(Cx - H, Cy, Cz);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx - H, Cy, Cz); rlVertex3f(Cx, Cy, Cz - H);
            rlVertex3f(Cx, Cy - H, Cz); rlVertex3f(Cx, Cy, Cz - H); rlVertex3f(Cx + H, Cy, Cz);
          end;
        end;
      end;
    finally
      rlEnd;
    end;

  finally
    EndMode3D;
  end;
end;

procedure TUniverseFormer.RenderSelectionHighlight;
begin
  // Selection highlight removed per user request - the blue wireframe
  // sphere "looks terrible". Selection state is still tracked in
  // FSelectedSystem and shown in the status bar text, so the user
  // knows which system is selected. DEL still works to remove it.
  Exit;
end;

procedure TUniverseFormer.RenderToolbar;
var
  I: Integer;
  R: TRectangle;
  Tpl: TUFTemplate;
  BgColor: TColorB;
  LabelY: Single;
  LabelTxt: AnsiString;
  Cx, Cy, TxtW: Single;
  SunCol: TColorB;
begin
  var BarR: TRectangle := GetToolbarRect;
  DrawRectangleRec(BarR, UF_COL_TOOLBAR_BG);
  DrawLineEx(Vector2Create(0, BarR.y), Vector2Create(FScreenW, BarR.y), 2, UF_COL_TOOLBAR_BORDER);

  for I := 0 to UF_TEMPLATE_COUNT - 1 do
  begin
    R := GetTemplateRect(I);
    Tpl := FTemplates[I];

    if FSelectedTemplate = I then
      BgColor := UF_COL_TEMPLATE_SEL
    else if CheckCollisionPointRec(FMousePos, R) then
      BgColor := UF_COL_TEMPLATE_HOVER
    else
      BgColor := UF_COL_TEMPLATE_BG;

    DrawRectangleRec(R, BgColor);
    DrawRectangleLinesEx(R, 2, UF_COL_TOOLBAR_BORDER);

    Cx := R.x + R.width * 0.5;
    Cy := R.y + R.height * 0.4;

    // Draw icon based on template kind. The icon visually represents
    // what the button does: single planet, complete system (sun +
    // orbit ring + planets), or galaxy cluster.
    case Tpl.Kind of
      tkPlanet:
        begin
          // Single planet icon: just the planet color circle
          DrawCircle(Trunc(Cx), Trunc(Cy), 14, Tpl.Color);
          DrawCircleLines(Trunc(Cx), Trunc(Cy), 14, BLACK);
        end;
      tkSystem:
        begin
          // System icon: sun in center + orbit ring + 2 small planet dots
          SunCol := Tpl.Color;
          DrawCircle(Trunc(Cx), Trunc(Cy), 8, SunCol);         // Sun
          DrawCircleLines(Trunc(Cx), Trunc(Cy), 8, BLACK);
          DrawCircleLines(Trunc(Cx), Trunc(Cy), 18, Fade(GRAY, 0.8)); // Orbit ring
          DrawCircle(Trunc(Cx - 18), Trunc(Cy), 3, BLUE);      // Planet 1
          DrawCircle(Trunc(Cx + 12), Trunc(Cy + 12), 3, GREEN); // Planet 2
        end;
      tkUniverse:
        begin
          // Universe icon: cluster of small dots representing many systems
          DrawCircle(Trunc(Cx - 8), Trunc(Cy - 5), 4, YELLOW);
          DrawCircle(Trunc(Cx + 7), Trunc(Cy - 8), 3, ORANGE);
          DrawCircle(Trunc(Cx + 5), Trunc(Cy + 7), 4, MakeCol(255, 100, 100));
          DrawCircle(Trunc(Cx - 6), Trunc(Cy + 8), 3, BLUE);
          DrawCircle(Trunc(Cx), Trunc(Cy), 5, WHITE);
        end;
      tkClear:
        begin
          // Clear icon: red X
          DrawCircle(Trunc(Cx), Trunc(Cy), 14, Fade(Tpl.Color, 0.3));
          DrawLine(Trunc(Cx - 10), Trunc(Cy - 10), Trunc(Cx + 10), Trunc(Cy + 10), Tpl.Color);
          DrawLine(Trunc(Cx + 10), Trunc(Cy - 10), Trunc(Cx - 10), Trunc(Cy + 10), Tpl.Color);
        end;
    end;

    // Label sits BELOW the icon, fully inside the template rect
    LabelTxt := Tpl.Label_;
    TxtW := MeasureText(PAnsiChar(LabelTxt), 12);
    LabelY := R.y + R.height - 18;
    DrawText(PAnsiChar(LabelTxt),
      Trunc(R.x + (R.width - TxtW) * 0.5),
      Trunc(LabelY), 12, UF_COL_TEXT);
  end;
end;

procedure TUniverseFormer.RenderStatusBar;
var
  StatusLine: AnsiString;
  SelectedName: AnsiString;
  ObjType: AnsiString;
  BrushTxt, SelTxt, HelpTxt: AnsiString;
  HelpW: Single;
begin
  StatusLine := AnsiString(Format('Systems: %d   |   FPS: %d',
    [LiveSystemCount, GetFPS()]));
  DrawText(PAnsiChar(StatusLine), 12, 12, 18, UF_COL_TEXT);

  if FSelectedTemplate >= 0 then
  begin
    BrushTxt := 'Brush: ' + FTemplates[FSelectedTemplate].Label_ +
                '  (click in 3D to place, ESC to cancel)';
    DrawText(PAnsiChar(BrushTxt), 12, 36, 16, UF_COL_TEMPLATE_SEL);
  end;

  if (FSelectedSystem >= 0) and (FSelectedSystem < FSystemCount) and
     (not FSystems[FSelectedSystem].IsDead) then
  begin
    SelectedName := FSystems[FSelectedSystem].Name;
    case FSystems[FSelectedSystem].Kind of
      skSol:    ObjType := 'Sol-Like';
      skRandom: ObjType := 'Random';
      skBinary: ObjType := 'Binary';
      skDwarf:  ObjType := 'Dwarf';
      skEmpty:  ObjType := 'Empty Sun';
    else
      ObjType := '?';
    end;
    SelTxt := 'Selected: ' + SelectedName + ' (' + ObjType + ')  -  DEL to remove';
    DrawText(PAnsiChar(SelTxt), 12, 58, 16, UF_COL_HIGHLIGHT);
  end;

  HelpTxt := 'MMB=orbit   Wheel=zoom   WASD=pan   DEL=remove   ESC=cancel';
  HelpW := MeasureText(PAnsiChar(HelpTxt), 14);
  DrawText(PAnsiChar(HelpTxt),
    Trunc((FScreenW - HelpW) * 0.5),
    FScreenH - UF_TOOLBAR_HEIGHT - 22,
    14, UF_COL_TEXT_DIM);
end;

procedure TUniverseFormer.Render;
begin
  Render3DScene;

  if (FSelectedSystem >= 0) and (FSelectedSystem < FSystemCount) and
     (not FSystems[FSelectedSystem].IsDead) then
  begin
    BeginMode3D(FCamera);
    try
      RenderSelectionHighlight;
    finally
      EndMode3D;
    end;
  end;

  RenderStatusBar;
  RenderToolbar;
end;

// ============================================================================
// Public API - external triggers for VCL buttons
// ============================================================================

procedure TUniverseFormer.SpawnSolSystemAtCamera;
var
  Pos: TVector3;
begin
  Pos := FCamera.target;
  SpawnSystemSmart(skSol, Pos);
end;

procedure TUniverseFormer.SpawnRandomSystemAtCamera;
var
  Pos: TVector3;
begin
  Pos := FCamera.target;
  SpawnSystemSmart(skRandom, Pos);
end;

procedure TUniverseFormer.SpawnRandomUniverseAtCamera;
begin
  GenerateRandomUniverse(FCamera.target, 20);
end;

end.

