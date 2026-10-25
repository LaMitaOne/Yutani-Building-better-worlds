unit Yutani.Worlds.Space.UniverseFormer;

{==============================================================================*
 *  Yutani Universe Former v0.2
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    A standalone Raylib editor for designing an entire UNIVERSE of
 *    star systems. The player places COMPLETE star systems (or
 *    individual planets) by selecting a template in the bottom toolbar
 *    and clicking in the 3D viewport.
 *
 *  Features:
 *    - 12 Templates: 5 Planet types, 5 System types (Sol/Random/Binary/
 *      Dwarf/Empty), Random Universe generator, Clear.
 *    - Smart Placement: Always spawns at click position, pushing other
 *      systems out of the way (smooth animation).
 *    - 3D Distribution: Random Universe spreads systems in X/Y/Z.
 *    - Individual Planets: Clicking near a sun adds a planet to that
 *      system's orbit.
 *    - Selection: LMB click selects (orbit rings turn aqua) and drags.
 *    - Y-Axis Editing: +/- keys move selected system up/down.
 *
 *  Rendering (v0.4 - Performance Pass):
 *    No textures are used. All planets and suns are rendered using a
 *    single pre-uploaded sphere mesh (VBO) via DrawModel.
 *
 *    Three layers of distance culling keep draw calls minimal:
 *      * Orbit rings culled at UF_ORBIT_CULL_DIST (1800)
 *      * Planets    culled at UF_PLANET_CULL_DIST (3000)
 *      * Suns       culled at UF_SUN_CULL_DIST (8000) - kept far for
 *        orientation when zoomed out
 *
 *    Planet rendering is done in 5 type-sorted passes (TUFPlanetType
 *    0..4) so the GPU driver doesn't have to flip the color uniform
 *    thousands of times per frame.
 *
 *    Orbit math (Cos/Sin per planet) is skipped entirely for systems
 *    beyond UF_UPDATE_CULL_DIST (5000), since their CurrentPos is
 *    never rendered anyway.
 *
 *    Net effect: at 500+ systems, per-frame draw calls drop from
 *    ~3000 to ~250 (zoomed in) or ~50 (zoomed out), restoring 60+ FPS
 *    on both integrated and discrete GPUs.
 *
 *  Scale:
 *    All sizes are halved compared to v0.1 for more relative space.
 *    The real Space.World can scale these values up at runtime.
 *
 *  Camera:
 *    Middle-mouse drag = orbit
 *    Mouse wheel       = zoom
 *    WASD / arrows     = pan target
 *
 *  Selection & Editing:
 *    Left-click a system → selects it + drag to move
 *    +/- keys            → move selected system up/down (Y)
 *    DEL                 → removes selected system
 *    ESC                 → deselects + disarms brush
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  Winapi.Windows, System.SysUtils, System.Math, System.Classes,
  Raylib, RayMath, rlgl;

const
  UF_TOOLBAR_HEIGHT     = 130;    // Taller so the template label fits
  UF_TOOLBAR_PADDING    = 12;
  UF_TEMPLATE_SIZE      = 80;
  UF_TEMPLATE_GAP       = 10;
  UF_TEMPLATE_COUNT     = 14; // 5 planets + 5 systems + universe + clear + save + load

  UF_MAX_SYSTEMS        = 8000;   // Allows full galactic-scale universes
  UF_DEFAULT_CAM_DIST   = 600.0;  // Closer to the origin so the user can actually move the camera without flying off into the void
  UF_GROUND_Y           = 0.0;

  // Halved sizes - gives much more room between systems. The real
  // Space.World can scale these up by 2x or 10x at runtime.
  UF_SUN_RADIUS         = 6.0;    // Was 12
  UF_ORBIT_MIN_RADIUS   = 12.0;   // Was 25
  UF_ORBIT_STEP         = 9.0;    // Was 18
  UF_ORBIT_SPEED_BASE   = 0.2;

  UF_MIN_SYSTEM_GAP     = 80.0;   // Was 150 - halved with everything else
  UF_PLACE_ATTEMPTS     = 80;

  // Distance culling thresholds (v0.4 - performance pass).
  // The old values (50000/20000) meant "render everything always",
  // which produced 3000+ draw calls per frame at 500+ systems and
  // tanked FPS to ~50 even on an RTX 2060S. The new values hard-cull
  // objects by distance, so only what's actually near the camera
  // costs a draw call. Suns are kept visible from far away because
  // they double as orientation markers when zoomed out.
  UF_LOD_FAR_DIST       = 50000.0; // legacy - kept for any external refs
  UF_LOD_MED_DIST       = 20000.0; // legacy - kept for any external refs
  UF_ORBIT_CULL_DIST    = 1800.0;  // Orbit rings only for nearby systems
  UF_ORBIT_FADE_DIST    = 1200.0;  // Beyond this, orbit rings fade to 0.2 alpha
  UF_PLANET_CULL_DIST   = 3000.0;  // Planets only within this radius of camera
  UF_SUN_CULL_DIST      = 8000.0;  // Suns visible from far away (orientation)
  UF_UPDATE_CULL_DIST   = 5000.0;  // Skip orbit math (Cos/Sin) beyond this

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
  TUFTemplateKind = (tkPlanet, tkSystem, tkClear, tkUniverse, tkSave, tkLoad);

  // HUD action callback. Fired when the user clicks one of the
  // in-Raylib Save/Load buttons. The host (typically the VCL form)
  // subscribes to these to open its TSaveDialog / TOpenDialog and
  // then call back into the engine to actually read/write the file.
  TUFNotifyEvent = procedure of object;

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

    // No textures (solid colored spheres), but we keep a single
    // pre-uploaded sphere mesh (VBO) for maximum rendering speed.
    // Drawing 1000+ spheres via rlVertex3f (immediate mode) kills the
    // CPU. Drawing them via DrawModel(Mesh) uses GPU memory directly.
    FLightShader: TShader;
    FOwnsShader: Boolean;
    FSphereModel: TModel; // Single shared sphere mesh for all objects

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
    FDraggingSystem: Boolean;        // True while dragging a selected system with LMB
    FDragStartMouse: TVector2;       // Mouse position when drag started
    FDragStartSystemPos: TVector3;   // System position when drag started

    // HUD button callbacks. nil = no handler; clicks are ignored.
    FOnSaveRequested: TUFNotifyEvent;
    FOnLoadRequested: TUFNotifyEvent;

    procedure InitTemplates;
    procedure GenerateAssets;
    procedure DestroyAssets;
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

    // --- Save/Load Support ---
    // Exposes the internal system array for external serialization
    // (e.g. SQLite in the sample wrapper). The former itself stays
    // DB-agnostic so it can be reused without dragging in sqlite3.dll.
    function GetSystemData(Index: Integer): TUFSystem;
    procedure SetSystemData(Index: Integer; const S: TUFSystem);
    procedure SetSystemTargetPosition(Index: Integer; const P: TVector3);
    procedure ClearAllSystems;
    function GetSystemCount: Integer;
    procedure SetSystemCount(Count: Integer);
    function GetMaxSystems: Integer;

    // --- HUD Action Callbacks ---
    // Subscribe from the host (e.g. the VCL form) to open file
    // dialogs when the user clicks Save/Load in the in-Raylib HUD.
    property OnSaveRequested: TUFNotifyEvent read FOnSaveRequested write FOnSaveRequested;
    property OnLoadRequested: TUFNotifyEvent read FOnLoadRequested write FOnLoadRequested;
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
  if FLightShader.id = 0 then
  begin
    FLightShader := LoadShader(nil, nil);
    FOwnsShader := True;
  end;

  // Camera defaults
  FCamYaw := -0.6;
  FCamPitch := 0.9;
  FCamDist := UF_DEFAULT_CAM_DIST;
  FCamera.target := Vector3Create(0, 0, 0);
  FCamera.up := Vector3Create(0, 1, 0);
  FCamera.fovy := 45.0;
  FCamera.projection := CAMERA_PERSPECTIVE;
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
  FDraggingSystem := False;

  InitTemplates;
  GenerateAssets;
  // No GenerateUnitSphere call needed anymore.
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

  // 10: Random Universe generator button
  // Label is "+20 systems" because that's exactly what one click does:
  // GenerateRandomUniverse(WorldPos, 20). The original "Random Universe"
  // label was misleading - it sounded like a one-shot reset that
  // populates the whole map, but actually each click adds 20 systems
  // at the clicked position.
  FTemplates[10].Kind := tkUniverse;
  FTemplates[10].Label_ := '+20 systems';
  FTemplates[10].SystemKind := skUniverse;
  FTemplates[10].Color := MakeCol(180, 100, 255);

  // 11: Clear
  FTemplates[11].Kind := tkClear;
  FTemplates[11].Label_ := 'Clear';
  FTemplates[11].Color := MakeCol(220, 80, 80);

  // 12: Save - fires OnSaveRequested so the host opens its TSaveDialog.
  //     These two are part of the regular template grid (not floating
  //     HUD buttons) so they line up with the other 12 templates.
  FTemplates[12].Kind := tkSave;
  FTemplates[12].Label_ := 'Save';
  FTemplates[12].Color := MakeCol(60, 180, 110);

  // 13: Load - fires OnLoadRequested so the host opens its TOpenDialog.
  FTemplates[13].Kind := tkLoad;
  FTemplates[13].Label_ := 'Load';
  FTemplates[13].Color := MakeCol(80, 130, 220);
end;

procedure TUniverseFormer.GenerateAssets;
var
  Mesh: TMesh;
begin
  // Generate a single plain sphere mesh and upload it to GPU (VBO).
  // We will use DrawModel with this single mesh for all suns and
  // planets, tinting them with the color parameter. This is almost
  // as fast as instanced rendering.
  Mesh := GenMeshSphere(1.0, 12, 10); // Low poly, but smooth enough
  UploadMesh(@Mesh, False);
  FSphereModel := LoadModelFromMesh(Mesh);
  // No texture, no shader assigned. DrawModel will use the default
  // material, which is very fast.
end;

procedure TUniverseFormer.DestroyAssets;
begin
  if FSphereModel.meshes <> nil then
    UnloadModel(FSphereModel);
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
  // Halved sizes - orbits 12-60, planet radii 0.75-3.5
  SOL_DATA: array[0..6] of TSolData = (
    (Typ: 0; OrbitR: 12;  Radius: 0.75; HasAtmo: False; ColR: 140; ColG: 120; ColB: 100; AtmoR: 0;   AtmoG: 0;   AtmoB: 0;),
    (Typ: 1; OrbitR: 17;  Radius: 1.5;  HasAtmo: True;  ColR: 200; ColG: 160; ColB: 100; AtmoR: 255; AtmoG: 200; AtmoB: 100;),
    (Typ: 1; OrbitR: 22;  Radius: 1.75; HasAtmo: True;  ColR: 60;  ColG: 120; ColB: 200; AtmoR: 100; AtmoG: 150; AtmoB: 255;),
    (Typ: 2; OrbitR: 27;  Radius: 1.25; HasAtmo: True;  ColR: 200; ColG: 90;  ColB: 50;  AtmoR: 200; AtmoG: 100; AtmoB: 50;),
    (Typ: 3; OrbitR: 40;  Radius: 3.5;  HasAtmo: True;  ColR: 220; ColG: 180; ColB: 110; AtmoR: 255; AtmoG: 200; AtmoB: 150;),
    (Typ: 3; OrbitR: 50;  Radius: 3;    HasAtmo: True;  ColR: 200; ColG: 170; ColB: 100; AtmoR: 255; AtmoG: 210; AtmoB: 160;),
    (Typ: 4; OrbitR: 60;  Radius: 2;    HasAtmo: True;  ColR: 150; ColG: 200; ColB: 230; AtmoR: 180; AtmoG: 210; AtmoB: 255;)
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
    S.Planets[I].Radius := 0.75 + Rand * 2.5;  // Halved from 1.5 + Rand * 5
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
  S.Sun2Offset := 17.0 + Rand * 12.0;  // Halved from 35 + Rand * 25
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
    S.Planets[I].Radius := 0.75 + Rand * 2.25;  // Halved from 1.5 + Rand * 4.5
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
    OrbitR := OrbitR + 6 + Rand * 4;  // Halved from 12 + Rand * 8
    S.Planets[I].PlanetType := 0;
    S.Planets[I].Radius := 0.5 + Rand * 0.75;  // Halved from 1 + Rand * 1.5
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
  RequiredXZGap, RequiredYGap: Single;
  XZDist, YDist: Single;
begin
  // First try the requested position itself
  Result := RequestedPos;
  FoundCollision := False;
  for I := 0 to FSystemCount - 1 do
  begin
    if FSystems[I].IsDead then
      Continue;
    RequiredXZGap := FSystems[I].BoundsRadius * 1.1;
    RequiredYGap  := FSystems[I].SunRadius * 4.0;
    XZDist := Sqrt(Sqr(Result.x - FSystems[I].Position.x) + Sqr(Result.z - FSystems[I].Position.z));
    YDist  := Abs(Result.y - FSystems[I].Position.y);
    if (XZDist < RequiredXZGap) or (YDist < RequiredYGap) then
    begin
      FoundCollision := True;
      Break;
    end;
  end;
  if not FoundCollision then
    Exit;

  // Otherwise spiral outward looking for a free spot
  for Attempt := 1 to UF_PLACE_ATTEMPTS do
  begin
    Angle := Random * 2.0 * PI;
    Radius := 50.0 * Attempt + Random * 50.0;
    TestPos.x := RequestedPos.x + Cos(Angle) * Radius;
    TestPos.y := RequestedPos.y + (Random - 0.5) * 100.0; // Add Y jitter
    TestPos.z := RequestedPos.z + Sin(Angle) * Radius;

    FoundCollision := False;
    for I := 0 to FSystemCount - 1 do
    begin
      if FSystems[I].IsDead then
        Continue;
      RequiredXZGap := FSystems[I].BoundsRadius * 1.1;
      RequiredYGap  := FSystems[I].SunRadius * 4.0;
      XZDist := Sqrt(Sqr(TestPos.x - FSystems[I].Position.x) + Sqr(TestPos.z - FSystems[I].Position.z));
      YDist  := Abs(TestPos.y - FSystems[I].Position.y);
      if (XZDist < RequiredXZGap) or (YDist < RequiredYGap) then
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
  Result := RequestedPos;
end;

function TUniverseFormer.SpawnSystemSmart(Kind: TUFSystemKind; const RequestedPos: TVector3): Integer;
var
  I: Integer;
  Dist, PushDist: Single;
  PushDir, NewTarget: TVector3;
  EstimatedNewBounds: Single;
  RequiredXZGap, RequiredYGap: Single;
  XZDist, YDist: Single;
  XZPush, YPush: Single;
begin
  // ALWAYS spawn exactly at RequestedPos. Before we do, push away any
  // existing systems that are too close based on STRICT separation rules:
  //   - XZ Plane: Required gap = (existing system's BoundsRadius) + 10%
  //   - Y Axis:   Required gap = (existing system's SunRadius) * 4
  // This guarantees systems never visually overlap or crash into each other.

  EstimatedNewBounds := 160.0;

  for I := 0 to FSystemCount - 1 do
  begin
    if FSystems[I].IsDead then
      Continue;

    // Calculate separation per-axis
    RequiredXZGap := FSystems[I].BoundsRadius * 1.1;
    RequiredYGap  := FSystems[I].SunRadius * 4.0;

    // Project the vector onto XZ plane and Y axis
    XZDist := Sqrt(Sqr(FSystems[I].Position.x - RequestedPos.x) + Sqr(FSystems[I].Position.z - RequestedPos.z));
    YDist  := Abs(FSystems[I].Position.y - RequestedPos.y);

    // Only push if we are too close on EITHER axis
    if (XZDist < RequiredXZGap) or (YDist < RequiredYGap) then
    begin
      if XZDist > 0.01 then
      begin
        PushDir.x := (FSystems[I].Position.x - RequestedPos.x) / XZDist;
        PushDir.z := (FSystems[I].Position.z - RequestedPos.z) / XZDist;
      end
      else
      begin
        PushDir.x := Random - 0.5;
        PushDir.z := Random - 0.5;
        PushDir.x := PushDir.x / Sqrt(PushDir.x*PushDir.x + PushDir.z*PushDir.z);
        PushDir.z := PushDir.z / Sqrt(PushDir.x*PushDir.x + PushDir.z*PushDir.z);
      end;

      // Calculate push distances per axis
      if XZDist < RequiredXZGap then
        XZPush := RequiredXZGap - XZDist + 10.0
      else
        XZPush := 0.0;

      if YDist < RequiredYGap then
      begin
        if (FSystems[I].Position.y - RequestedPos.y) > 0 then
          YPush := RequiredYGap - YDist + 10.0
        else
          YPush := -(RequiredYGap - YDist + 10.0);
      end
      else
        YPush := 0.0;

      // Set TARGET position (not current position) - the smooth
      // lerp in UpdateOrbits will animate the system sliding
      // outward over the next few frames.
      NewTarget.x := FSystems[I].Position.x + PushDir.x * XZPush;
      NewTarget.y := FSystems[I].Position.y + YPush;
      NewTarget.z := FSystems[I].Position.z + PushDir.z * XZPush;

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
    P^.Radius := 0.75 + Random * 1.5;  // Halved from 1.5 + Random * 3.0

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
    P^.Radius := 1.0 + Random * 1.5;  // Halved from 2.0 + Random * 3.0
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

  // Spread out even more with the halved sizes. The systems are now
  // much smaller so we have even more relative space between them.
  DiskScaleLength := 700.0;
  BulgeRadius := 20.0;
  DiskThickness := 700.0;

  for I := 0 to Count - 1 do
  begin
    if FSystemCount >= UF_MAX_SYSTEMS then
      Break;

    // Exponential disk profile with a minimum radius to avoid
    // clumping at the exact center
    U := Rand;
    LocalR := -DiskScaleLength * Ln(1.0 - U * 0.99);
    LocalR := LocalR + 200.0 + Rand * 400.0;  // Large min radius + jitter

    Angle := Rand * 2.0 * PI;

    // Y (up/down) - full 3D spread with minimal damping
    U := Rand;
    if U < 1e-6 then
      U := 1e-6;
    Z := Sqrt(-2.0 * Ln(U)) * Cos(2.0 * PI * Rand)
       * DiskThickness
       * Exp(-LocalR / (BulgeRadius * 12.0));  // Very weak damping = spread everywhere

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
  Dist: Single;
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
    // systems aside. Always runs (cheap) so animated motion finishes
    // even when the system is off-screen.
    S^.Position.x := S^.Position.x + (S^.TargetPosition.x - S^.Position.x) * LerpSpeed * dt;
    S^.Position.y := S^.Position.y + (S^.TargetPosition.y - S^.Position.y) * LerpSpeed * dt;
    S^.Position.z := S^.Position.z + (S^.TargetPosition.z - S^.Position.z) * LerpSpeed * dt;

    // CPU LOD: skip the expensive Cos/Sin orbit math for systems that
    // are far from the camera. Their CurrentPos is stale but they're
    // not being rendered anyway (UF_PLANET_CULL_DIST < UF_UPDATE_CULL_DIST),
    // so the user never sees the stale position. When the user zooms
    // back to them, the math resumes and the position snaps back to
    // correct within one frame.
    Dist := Vector3Distance(S^.Position, FCamera.position);
    if Dist > UF_UPDATE_CULL_DIST then
    begin
      if S^.IsBinary then
        S^.BinaryAngle := S^.BinaryAngle + S^.BinarySpeed * dt;
      Continue;
    end;

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
  MouseDeltaX, MouseDeltaY: Single;
  PanSpeed: Single;
begin
  LMBDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;
  LMBClicked := LMBDown and (not FLMBWasDown);

  // +/- keys (regular keyboard, NOT numpad) to move selected system up/down
  if (FSelectedSystem >= 0) and (FSelectedSystem < FSystemCount) and
     (not FSystems[FSelectedSystem].IsDead) then
  begin
    // VK_OEM_PLUS and VK_OEM_MINUS are the +/- keys next to Backspace
    if (GetAsyncKeyState(VK_OEM_PLUS) and $8000) <> 0 then
    begin
      FSystems[FSelectedSystem].TargetPosition.y := FSystems[FSelectedSystem].TargetPosition.y + 30.0 * GetFrameTime();
    end;
    if (GetAsyncKeyState(VK_OEM_MINUS) and $8000) <> 0 then
    begin
      FSystems[FSelectedSystem].TargetPosition.y := FSystems[FSelectedSystem].TargetPosition.y - 30.0 * GetFrameTime();
    end;
  end;

  if (GetAsyncKeyState(VK_DELETE) and $1) <> 0 then
  begin
    DeleteSelectedSystem;
    Exit;
  end;

  if (GetAsyncKeyState(VK_ESCAPE) and $1) <> 0 then
  begin
    FSelectedSystem := -1;
    FSelectedTemplate := -1;
    FDraggingSystem := False;
    Exit;
  end;

  // ---- DRAGGING a selected system ----
  if FDraggingSystem then
  begin
    if LMBDown then
    begin
      // While dragging, move the system with WASD (reuse the camera
      // pan vectors) and mouse movement. The system follows the
      // camera target on the XZ plane.
      PanSpeed := 120.0 * GetFrameTime();
      MouseDeltaX := MousePos.x - FDragStartMouse.x;
      MouseDeltaY := MousePos.y - FDragStartMouse.y;

      // Move system based on mouse delta projected onto ground plane
      Ray := GetScreenToWorldRay(MousePos, FCamera);
      if RaycastToGround(Ray, WorldPos) then
      begin
        FSystems[FSelectedSystem].TargetPosition.x := WorldPos.x;
        FSystems[FSelectedSystem].TargetPosition.z := WorldPos.z;
        // Keep current Y
      end;
      Exit;
    end
    else
    begin
      FDraggingSystem := False;
      Exit;
    end;
  end;

  if not LMBClicked then
    Exit;

  Ray := GetScreenToWorldRay(MousePos, FCamera);

  if FSelectedTemplate >= 0 then
  begin
    if FTemplates[FSelectedTemplate].Kind = tkUniverse then
    begin
      if RaycastToGround(Ray, WorldPos) then
        GenerateRandomUniverse(WorldPos, 20);
      FSelectedTemplate := -1;
    end
    else if FTemplates[FSelectedTemplate].Kind = tkSystem then
    begin
      if RaycastToGround(Ray, WorldPos) then
        SpawnSystemSmart(FTemplates[FSelectedTemplate].SystemKind, WorldPos);
    end
    else if FTemplates[FSelectedTemplate].Kind = tkPlanet then
    begin
      if RaycastToGround(Ray, WorldPos) then
        SpawnFreePlanet(FTemplates[FSelectedTemplate].PlanetType, WorldPos);
    end;
    Exit;
  end;

  // No brush armed - try to select or start dragging
  SysIdx := GetSystemUnderMouse(Ray);
  FSelectedSystem := SysIdx;

  // If we clicked on a system, start dragging it
  if (SysIdx >= 0) and (not FSystems[SysIdx].IsDead) then
  begin
    FDraggingSystem := True;
    FDragStartMouse := MousePos;
    FDragStartSystemPos := FSystems[SysIdx].Position;
  end;
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

  // ESC = deselect current system + disarm current brush. The
  // engine handles ESC here so the host can call SetExitKey(0) to
  // disable Raylib's default ESC→close-window behavior (which
  // would otherwise destroy the GL context and turn the embedded
  // window white).
  if IsKeyPressed(KEY_ESCAPE) then
  begin
    FSelectedSystem := -1;
    FSelectedTemplate := -1;
  end;

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
        else if FTemplates[TplIdx].Kind = tkSave then
        begin
          // Fire-and-forget - the host opens its TSaveDialog and
          // calls back into SaveToFile. We don't arm a brush.
          if Assigned(FOnSaveRequested) then FOnSaveRequested;
        end
        else if FTemplates[TplIdx].Kind = tkLoad then
        begin
          if Assigned(FOnLoadRequested) then FOnLoadRequested;
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
  I, J, TypeIdx: Integer;
  S: ^TUFSystem;
  Dist: Single;
  SunPos, Sun2Pos: TVector3;
  CustomProj: TMatrix;
begin
  if (FSystems = nil) or (Length(FSystems) = 0) then
    Exit;

  BeginMode3D(FCamera);
  try
    CustomProj := MatrixPerspective(FCamera.fovy * DEG2RAD,
      GetScreenWidth() / GetScreenHeight(), 0.01, 10000.0);
    rlSetMatrixProjection(CustomProj);

    // ---- 1. GRID + ORBIT RINGS (batched lines, hard distance-culled) ----
    // Orbit rings beyond UF_ORBIT_CULL_DIST are skipped entirely - we
    // don't even compute their line vertices. This was the #1 cause of
    // CPU overhead at 500+ systems: every system was generating 32
    // line segments per planet per frame, even when off-screen.
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

      for I := 0 to FSystemCount - 1 do
      begin
        if I >= Length(FSystems) then Break;
        S := @FSystems[I];
        if S^.IsDead then Continue;
        Dist := Vector3Distance(S^.Position, FCamera.position);
        if Dist > UF_ORBIT_CULL_DIST then Continue; // Hard cull

        // Selected system gets aqua-colored orbit rings, all others gray
        if I = FSelectedSystem then
        begin
          for J := 0 to High(S^.Planets) do
            DrawOrbitRingBatched(S^.Position, S^.Planets[J].OrbitRadius, UF_COL_HIGHLIGHT);
        end
        else
        begin
          if Dist > UF_ORBIT_FADE_DIST then
            for J := 0 to High(S^.Planets) do
              DrawOrbitRingBatched(S^.Position, S^.Planets[J].OrbitRadius, Fade(GRAY, 0.2))
          else
            for J := 0 to High(S^.Planets) do
              DrawOrbitRingBatched(S^.Position, S^.Planets[J].OrbitRadius, Fade(GRAY, 0.35));
        end;
      end;
    finally
      rlEnd;
    end;
    rlEnableDepthTest;

    // ---- 2. SUNS (single pass, hard distance-culled) ----
    // Suns stay visible from far away (UF_SUN_CULL_DIST is large) so
    // the user can still see the overall universe layout when zoomed
    // out, but anything beyond that distance is skipped.
    rlSetBlendMode(BLEND_ALPHA);
    for I := 0 to FSystemCount - 1 do
    begin
      if I >= Length(FSystems) then Break;
      S := @FSystems[I];
      if S^.IsDead then Continue;

      Dist := Vector3Distance(S^.Position, FCamera.position);
      if Dist > UF_SUN_CULL_DIST then Continue;

      if S^.IsBinary then
      begin
        SunPos := Vector3Add(S^.Position, Vector3Create(
          Cos(S^.BinaryAngle) * S^.Sun2Offset * 0.5, 0,
          Sin(S^.BinaryAngle) * S^.Sun2Offset * 0.5));
        Sun2Pos := Vector3Add(S^.Position, Vector3Create(
          -Cos(S^.BinaryAngle) * S^.Sun2Offset * 0.5, 0,
          -Sin(S^.BinaryAngle) * S^.Sun2Offset * 0.5));
        DrawModel(FSphereModel, SunPos, S^.SunRadius, MakeCol(255, 220, 100));
        DrawModel(FSphereModel, Sun2Pos, S^.Sun2Radius, MakeCol(255, 180, 80));
      end
      else
      begin
        DrawModel(FSphereModel, S^.Position, S^.SunRadius, MakeCol(255, 220, 100));
      end;
    end;

    // ---- 3. PLANETS (5 passes, sorted by TUFPlanetType) ----
    // Planets are rendered in 5 type-grouped passes (type 0..4) so the
    // GPU driver doesn't have to flip the color uniform 3000 times per
    // frame. Combined with hard distance culling at UF_PLANET_CULL_DIST,
    // this typically reduces per-frame draw calls from ~3000 to ~250
    // when zoomed in close, or near zero when zoomed out.
    for TypeIdx := 0 to 4 do
    begin
      for I := 0 to FSystemCount - 1 do
      begin
        if I >= Length(FSystems) then Break;
        S := @FSystems[I];
        if S^.IsDead then Continue;

        Dist := Vector3Distance(S^.Position, FCamera.position);
        if Dist > UF_PLANET_CULL_DIST then Continue;

        for J := 0 to High(S^.Planets) do
          if S^.Planets[J].PlanetType = TUFPlanetType(TypeIdx) then
            DrawModel(FSphereModel, S^.Planets[J].CurrentPos,
                      S^.Planets[J].Radius, S^.Planets[J].PlanetColor);

        for J := 0 to High(S^.FreePlanets) do
          if S^.FreePlanets[J].PlanetType = TUFPlanetType(TypeIdx) then
            DrawModel(FSphereModel, S^.FreePlanets[J].CurrentPos,
                      S^.FreePlanets[J].Radius, S^.FreePlanets[J].PlanetColor);
      end;
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
      tkSave:
        begin
          // Save icon: floppy-disk (filled body + black outline +
          // metal slider on top + label slot at bottom). DrawRectangle
          // is filled; DrawRectangleLines is the outline.
          DrawRectangle(Trunc(Cx - 14), Trunc(Cy - 14), 28, 28, Tpl.Color);
          DrawRectangleLines(Trunc(Cx - 14), Trunc(Cy - 14), 28, 28, BLACK);
          // Metal slider at top (the part that slides on a real floppy)
          DrawRectangle(Trunc(Cx - 10), Trunc(Cy - 11), 20, 6, BLACK);
          // Label sticker slot at the bottom
          DrawRectangle(Trunc(Cx - 8), Trunc(Cy + 2), 16, 8, BLACK);
        end;
      tkLoad:
        begin
          // Load icon: open folder (filled body + tab on top-left +
          // black outline + a small down-arrow inside to signal
          // "import from disk").
          DrawRectangle(Trunc(Cx - 14), Trunc(Cy - 6), 28, 18, Tpl.Color);
          DrawRectangleLines(Trunc(Cx - 14), Trunc(Cy - 6), 28, 18, BLACK);
          // Folder tab (trapezoid approximated by a triangle)
          DrawTriangle(
            Vector2Create(Trunc(Cx - 14), Trunc(Cy - 6)),
            Vector2Create(Trunc(Cx - 14), Trunc(Cy - 14)),
            Vector2Create(Trunc(Cx - 2),  Trunc(Cy - 14)),
            Tpl.Color);
          DrawTriangleLines(
            Vector2Create(Trunc(Cx - 14), Trunc(Cy - 6)),
            Vector2Create(Trunc(Cx - 14), Trunc(Cy - 14)),
            Vector2Create(Trunc(Cx - 2),  Trunc(Cy - 14)),
            BLACK);
          // Down-arrow inside the folder body (white so it shows on blue)
          DrawLine(Trunc(Cx + 4), Trunc(Cy - 3), Trunc(Cx + 4), Trunc(Cy + 8), WHITE);
          DrawLine(Trunc(Cx + 4), Trunc(Cy + 8), Trunc(Cx + 0), Trunc(Cy + 4), WHITE);
          DrawLine(Trunc(Cx + 4), Trunc(Cy + 8), Trunc(Cx + 8), Trunc(Cy + 4), WHITE);
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

  HelpTxt := 'MMB=orbit  Wheel=zoom  WASD=pan  LMB=select/drag  +/-=Y  DEL=remove  ESC=cancel';
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

// ============================================================================
// Save/Load Support
// ============================================================================

function TUniverseFormer.GetSystemData(Index: Integer): TUFSystem;
begin
  if (Index >= 0) and (Index < Length(FSystems)) then
    Result := FSystems[Index]
  else
    Result := Default(TUFSystem);
end;

procedure TUniverseFormer.SetSystemData(Index: Integer; const S: TUFSystem);
begin
  if (Index >= 0) and (Index < Length(FSystems)) then
  begin
    // Direct copy of the entire record. We do NOT auto-sync
    // TargetPosition to Position here - that used to clobber the
    // loaded target, breaking reload of mid-animation states. The
    // caller (e.g. LoadFromFile) supplies whatever target they want.
    FSystems[Index] := S;
  end;
end;

procedure TUniverseFormer.SetSystemTargetPosition(Index: Integer; const P: TVector3);
begin
  if (Index >= 0) and (Index < Length(FSystems)) then
  begin
    FSystems[Index].TargetPosition := P;
  end;
end;

procedure TUniverseFormer.ClearAllSystems;
begin
  ClearAll;
end;

function TUniverseFormer.GetSystemCount: Integer;
begin
  Result := FSystemCount;
end;

procedure TUniverseFormer.SetSystemCount(Count: Integer);
begin
  FSystemCount := Count;
end;

function TUniverseFormer.GetMaxSystems: Integer;
begin
  Result := UF_MAX_SYSTEMS;
end;

end.

