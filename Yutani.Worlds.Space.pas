unit Yutani.Worlds.Space;

{==============================================================================*
 *  Yutani World: Space - Infinite Procedural Cosmos
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Galaxy Model:
 *    One active star system at a time. The player flies out of the
 *    current system (which fades out over a tunable distance), crosses
 *    an empty void for a few seconds, then a new system fades in in the
 *    direction of flight. Visited systems are persisted to a SQLite
 *    database (sqlite3.dll loaded inline) so the player can
 *    revisit them with the same layout they left behind.
 *
 *  Phases:
 *    gpAtSystem     - camera is near current.sun, system fully visible
 *    gpDeparting    - camera flew far enough that current fades out
 *    gpTraveling    - empty void, only fake distant stars visible
 *    gpApproaching  - target system faded in in flight direction
 *    (gpArrived is implicit - on arrival we swap and go back to gpAtSystem)
 *==============================================================================}
{$POINTERMATH ON}
{$Q-}
{$R-}
interface

uses
  Winapi.Windows, System.SysUtils, System.Math, Raylib, RayMath, rlgl,
  Yutani.Worlds.Space.Textures;
// ============================================================================
// Inlined SQLite bindings + thin wrapper
// ============================================================================
// We need just enough of sqlite3.dll to persist explored star systems
// (open, prepare, bind, step, column-read). Inlining the declarations
// here keeps the dependency surface to one unit + one dll, no extra
// .pas file floating around for ~50 lines of bindings.

type
  // Opaque SQLite handles. Declared as distinct types so the compiler
  // can catch accidental mixing with other Pointer vars.
  TSQLiteDB = type Pointer;

  TSQLiteStmt = type Pointer;
  // Destructor callback signature for blob/text bindings. Matches the
  // C signature `void (*)(void*)` with cdecl calling convention.

  TSQLiteDestructor = procedure(p: Pointer); cdecl;

const
  // Result codes we actually check.
  SQLITE_OK = 0;
  SQLITE_ROW = 100;
  SQLITE_DONE = 101;
  // Open flags. The wrapper defaults to READWRITE + CREATE so a fresh
  // DB file is created on first Open() if it does not exist yet.
  SQLITE_OPEN_READONLY = $00000001;
  SQLITE_OPEN_READWRITE = $00000002;
  SQLITE_OPEN_CREATE = $00000004;
  // Special destructor sentinels. SQLITE_STATIC means "do not free,
  // the pointer stays valid forever"; SQLITE_TRANSIENT means "make a
  // private copy now". We always use TRANSIENT for safety.
  SQLITE_STATIC = Pointer(0);
  SQLITE_TRANSIENT = Pointer(-1);
  // Pass -1 for the SQL length to have SQLite read until the null
  // terminator.
  SQLITE_SQL_LENGTH_NULLTERM = -1;
// Native sqlite3.dll imports (cdecl). The DLL must be on the
// executable search path - drop it next to your .exe.

function sqlite3_open_v2(filename: PAnsiChar; out db: TSQLiteDB; flags: Integer; vfs: PAnsiChar): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_close_v2(db: TSQLiteDB): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_prepare_v2(db: TSQLiteDB; sql: PAnsiChar; nByte: Integer; out stmt: TSQLiteStmt; tail: PPAnsiChar): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_step(stmt: TSQLiteStmt): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_finalize(stmt: TSQLiteStmt): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_reset(stmt: TSQLiteStmt): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_bind_int(stmt: TSQLiteStmt; idx: Integer; val: Integer): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_bind_int64(stmt: TSQLiteStmt; idx: Integer; val: Int64): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_bind_double(stmt: TSQLiteStmt; idx: Integer; val: Double): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_bind_text(stmt: TSQLiteStmt; idx: Integer; txt: PAnsiChar; nByte: Integer; destructor_: Pointer): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_bind_null(stmt: TSQLiteStmt; idx: Integer): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_column_int(stmt: TSQLiteStmt; idx: Integer): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_column_int64(stmt: TSQLiteStmt; idx: Integer): Int64; cdecl; external 'sqlite3.dll';

function sqlite3_column_double(stmt: TSQLiteStmt; idx: Integer): Double; cdecl; external 'sqlite3.dll';

function sqlite3_column_text(stmt: TSQLiteStmt; idx: Integer): PAnsiChar; cdecl; external 'sqlite3.dll';

function sqlite3_column_bytes(stmt: TSQLiteStmt; idx: Integer): Integer; cdecl; external 'sqlite3.dll';

function sqlite3_errmsg(db: TSQLiteDB): PAnsiChar; cdecl; external 'sqlite3.dll';

type
  /// <summary>
  /// Thin ergonomic wrapper around a sqlite3 connection. Owns the handle
  /// and closes it on Destroy. Use Open() to open a database file,
  /// Execute() for one-shot statements (DDL like CREATE TABLE), and
  /// Prepare() + Bind*() + Step() + Column*() for parameterized queries.
  /// </summary>
  TYutaniSQLiteDB = class
  private
    FDB: TSQLiteDB;
    FFileName: string;
    FLastError: string;
    FDllAvailable: Boolean;
    procedure CaptureLastError;
  public
    constructor Create;
    destructor Destroy; override;
    function Open(const AFileName: string; CreateIfMissing: Boolean = True): Boolean;
    procedure Close;
    function Execute(const SQL: AnsiString): Boolean;
    function Prepare(const SQL: AnsiString; out Stmt: TSQLiteStmt): Boolean;
    class procedure BindInt(Stmt: TSQLiteStmt; Idx: Integer; Val: Integer); static;
    class procedure BindInt64(Stmt: TSQLiteStmt; Idx: Integer; Val: Int64); static;
    class procedure BindDouble(Stmt: TSQLiteStmt; Idx: Integer; Val: Double); static;
    class procedure BindText(Stmt: TSQLiteStmt; Idx: Integer; const Val: AnsiString); static;
    class procedure BindTextW(Stmt: TSQLiteStmt; Idx: Integer; const Val: string); static;
    class procedure BindNull(Stmt: TSQLiteStmt; Idx: Integer); static;
    class function Step(Stmt: TSQLiteStmt): Integer; static;
    class procedure Finalize(Stmt: TSQLiteStmt); static;
    class procedure Reset(Stmt: TSQLiteStmt); static;
    class function ColumnInt(Stmt: TSQLiteStmt; Idx: Integer): Integer; static;
    class function ColumnInt64(Stmt: TSQLiteStmt; Idx: Integer): Int64; static;
    class function ColumnDouble(Stmt: TSQLiteStmt; Idx: Integer): Double; static;
    class function ColumnText(Stmt: TSQLiteStmt; Idx: Integer): AnsiString; static;
    class function ColumnTextW(Stmt: TSQLiteStmt; Idx: Integer): string; static;
    property DB: TSQLiteDB read FDB;
    property FileName: string read FFileName;
    property LastError: string read FLastError;
    property DllAvailable: Boolean read FDllAvailable;
  end;

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
  // Small drifting rock/dust particle for ambient space detail.
  // Distinct from the bright star sprites - these are dark gray /
  // brown specks that float around the camera at close range so the
  // player feels like they're flying through actual debris, not
  // pristine empty void.

  TSpaceDust = record
    Position: TVector3;
    Velocity: TVector3;
    Size: Single;
    ColorR, ColorG, ColorB: Byte;
  end;
  // Galaxy lifecycle phases. See the unit header for a description.

  TGalaxyPhase = (gpAtSystem, gpDeparting, gpTraveling, gpApproaching);

  TSpaceWorld = class
  private
    FDistantStars: array of TSpaceStar;
    FNearStars: array of TNearStar;
    FNebulae: array of TNebula;
    // FSuns / FPlanets hold the current star system. FNextSuns /
    // FNextPlanets hold the approaching target system during the
    // gpApproaching phase. Both must use TArray<T> rather than the
    // anonymous `array of T` so they match the var-parameter type
    // of GenerateSystemAt - otherwise SetLength calls inside that
    // procedure would fail with E2008 / E2033.
    FPlanets: TArray<TSpacePlanet>;
    FSuns: TArray<TSun>;
    FComets: array of TSpaceComet;
    FCometParticles: array of TCometParticle;
    // Ambient dust / small rocks floating around the camera. Gives
    // the void a sense of "stuff here" instead of pristine emptiness.
    FDust: TArray<TSpaceDust>;
    // Cached list of all discovered star systems (galaxy positions)
    // loaded from SQLite for the minimap. Refreshed on demand when
    // the cache age exceeds MINIMAP_CACHE_TTL so we don't query the
    // DB every frame.
    FDiscoveredSystemsCache: TArray<TVector3>;
    FDiscoveredCacheAge: Single;
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
    FSunTexture: TTexture2D;
    FSunModel: TModel;
    // --- Galaxy manager state ---
    // Replaces the old chunk-based distant-solar-system generation with
    // a strict one-system-at-a-time model. The current system lives
    // in FSuns/FPlanets (kept trimmed to exactly the current system's
    // contents); the approaching system lives in FNextSuns/FNextPlanets
    // and is rendered alongside the current one with a fade factor.
    FPhase: TGalaxyPhase;
    FNextSuns: TArray<TSun>;
    FNextPlanets: TArray<TSpacePlanet>;
    FCurrentVis: Single;          // 0..1 fade for FSuns/FPlanets
    FNextVis: Single;             // 0..1 fade for FNextSuns/FNextPlanets
    FTravelTimer: Single;          // Empty-void accumulator (gpTraveling)
    // Tracks the camera's actual flight direction (delta between this
    // frame and the previous frame, normalized). When the user hovers
    // in place we keep the last known direction so the phase machine
    // still has a sensible forward to place the next target in.
    FCamForward: TVector3;
    FCurrentSeed: Cardinal;        // Seed used to generate current system
    FNextSeed: Cardinal;           // Seed used to generate next system
    FCurrentGalaxyPos: TVector3;   // Rounded galaxy cell of current sun
    FNextGalaxyPos: TVector3;       // Rounded galaxy cell of next sun
    FGalaxyDB: TYutaniSQLiteDB;     // Persisted explored systems
    // Tunable distances for the phase machine. All exposed as properties
    // so a settings dialog can tweak them at runtime.
    FFadeStartDist: Single;
    FFadeEndDist: Single;
    FTargetPickDistance: Single;
    FTargetApproachFadeStart: Single;
    FArriveDistance: Single;
    FMinTravelTime: Single;
    procedure InitializeDistantStars;
    procedure SpawnStarterPlanets;
    // Regenerates only the background decoration (near stars + nebulae)
    // around the camera. Distant solar systems are NOT regenerated here
    // anymore - the galaxy phase machine manages exactly one (or two
    // during transition) systems at a time.
    procedure RegenerateNearContent(const CameraPos: TVector3);
    procedure UpdateOrbits(const dt: Single);
    // Drives the one-system-at-a-time phase machine. Called every frame
    // from Update with the current camera position + flight direction.
    procedure UpdateGalaxyPhase(dt: Single; const CameraPos, CameraForward: TVector3);
    // Picks a procedural system in the flight direction and loads it
    // into FNextSuns / FNextPlanets. Tries the SQLite DB first; falls
    // back to fresh procedural generation if the cell has never been
    // visited before.
    procedure PickNextSystem(const CameraPos, CameraForward: TVector3);
    // Promotes FNextSuns/FNextPlanets to FSuns/FPlanets, saves the new
    // current system to the DB, and clears the next buffers.
    procedure SwapToNextSystem;
    // Recomputes FCurrentVis and FNextVis based on camera distance to
    // each system's sun. Called every frame before rendering.
    procedure UpdateSystemVisibilities(const CameraPos: TVector3);
    // Generates one procedural solar system at SunPos with the given
    // seed. Appends to (or replaces) the supplied Suns / Planets arrays.
    // Uses TArray<T> rather than `array of T` so the procedure can call
    // SetLength on the arrays - open array parameters would not allow
    // that.
    procedure GenerateSystemAt(var Suns: TArray<TSun>; var Planets: TArray<TSpacePlanet>; const SunPos: TVector3; Seed: Cardinal; Append: Boolean);
    // SQLite schema setup - creates the star_systems table if missing.
    procedure EnsureGalaxySchema;
    // Upserts the current system (FCurrentGalaxyPos + FCurrentSeed +
    // sun color / radius) into the DB. Best-effort; failures are silent.
    procedure SaveCurrentSystemToDB;
    // Loads a system's seed from the DB by galaxy position. Returns True
    // if a row was found, False otherwise. OutSeed is only valid on True.
    function LoadSystemSeedFromDB(const GalaxyPos: TVector3; out OutSeed: Cardinal): Boolean;
    // 3D hash of a galaxy cell position - yields a deterministic seed
    // for any given galaxy coordinate. Same hash as the legacy chunk
    // generator so old saved galaxies stay compatible.
    function HashGalaxyPos(x, y, z: Double): Cardinal;
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
    // Ambient dust particle system. Spawns a shell of slow-drifting
    // dark specks around the camera and respawns each particle when
    // it drifts too far away so the dust layer is always present.
    procedure SpawnDustShell(const CameraPos: TVector3);
    procedure UpdateDust(const dt: Single; const CameraPos: TVector3);
    procedure RenderDust(const CamRight, CamUp: TVector3);
    // Minimap - draws a 2D overlay in the top-right corner showing
    // the player's position, the current system, the next (target)
    // system, and all previously discovered systems. Call this from
    // outside BeginMode3D so the 2D primitives land on top of the
    // 3D scene without perspective distortion.
    procedure RefreshDiscoveredSystemsCache;
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
    // 2D overlay - call after EndMode3D so it lands on top of the
    // 3D scene. Safe to call inside BeginMode3D too but the result
    // will look stretched because of the perspective projection.
    procedure RenderMinimap(const Camera: TCamera3D);
    procedure InitiateLanding(const TargetIndex: Integer; var CameraTarget: TVector3; var CameraPos: TVector3);
    procedure ReleaseLanding;
    function FindNearestPlanet(const CameraPos: TVector3; out OutIndex: Integer; out OutDistance: Single): Boolean;
    function IsLanded: Boolean;
    function GetLandedPlanetPos: TVector3;
    function GetLandedPlanetRadius: Single;
    procedure GetPlanetInfo(const Index: Integer; out OutPos: TVector3; out OutRadius: Single);
    // Galaxy lifecycle - exposed for HUD / settings dialogs.
    property Phase: TGalaxyPhase read FPhase;
    property CurrentVisibility: Single read FCurrentVis;
    property NextVisibility: Single read FNextVis;
    property CurrentSeed: Cardinal read FCurrentSeed;
    property NextSeed: Cardinal read FNextSeed;
    // Tunable distances. Safe to modify at runtime from a settings UI.
    property FadeStartDist: Single read FFadeStartDist write FFadeStartDist;
    property FadeEndDist: Single read FFadeEndDist write FFadeEndDist;
    property TargetPickDistance: Single read FTargetPickDistance write FTargetPickDistance;
    property TargetApproachFadeStart: Single read FTargetApproachFadeStart write FTargetApproachFadeStart;
    property ArriveDistance: Single read FArriveDistance write FArriveDistance;
    property MinTravelTime: Single read FMinTravelTime write FMinTravelTime;
  end;

implementation
{ TYutaniSQLiteDB }

constructor TYutaniSQLiteDB.Create;
begin
  inherited Create;
  FDB := nil;
  FFileName := '';
  FLastError := '';
  // The external 'sqlite3.dll' declarations above cause Delphi to load
  // the DLL at app startup. If the DLL is missing the app won't even
  // launch - Windows shows a "sqlite3.dll not found" dialog. So we
  // don't need to probe here; we just assume the DLL is present once
  // we got this far. Open() will surface any other failures from
  // sqlite3 itself.
  FDllAvailable := True;
end;

destructor TYutaniSQLiteDB.Destroy;
begin
  Close;
  inherited;
end;

procedure TYutaniSQLiteDB.CaptureLastError;
begin
  if FDB <> nil then
    FLastError := string(AnsiString(sqlite3_errmsg(FDB)))
  else
    FLastError := 'Database is not open';
end;

function TYutaniSQLiteDB.Open(const AFileName: string; CreateIfMissing: Boolean): Boolean;
var
  Flags: Integer;
  AnsiName: AnsiString;
begin
  Result := False;
  // Close any existing connection first so repeated Open() calls on the
  // same instance do not leak handles.
  Close;
  if not FDllAvailable then
  begin
    FLastError := 'sqlite3.dll not found. Place it next to the executable.';
    Exit;
  end;
  AnsiName := AnsiString(AFileName);
  Flags := SQLITE_OPEN_READWRITE;
  if CreateIfMissing then
    Flags := Flags or SQLITE_OPEN_CREATE;
  if sqlite3_open_v2(PAnsiChar(AnsiName), FDB, Flags, nil) = SQLITE_OK then
  begin
    FFileName := AFileName;
    Result := True;
  end
  else
  begin
    CaptureLastError;
    if FDB <> nil then
    begin
      sqlite3_close_v2(FDB);
      FDB := nil;
    end;
  end;
end;

procedure TYutaniSQLiteDB.Close;
begin
  if FDB <> nil then
  begin
    sqlite3_close_v2(FDB);
    FDB := nil;
  end;
  FFileName := '';
end;

function TYutaniSQLiteDB.Execute(const SQL: AnsiString): Boolean;
var
  Stmt: TSQLiteStmt;
  StepResult: Integer;
begin
  Result := False;
  if FDB = nil then
  begin
    FLastError := 'Database is not open';
    Exit;
  end;
  // Use Prepare + Step + Finalize so we get proper error reporting
  // and don't accidentally leave a stmt dangling. sqlite3_exec would
  // be simpler but hides the error message in a callback.
  if not Prepare(SQL, Stmt) then
    Exit;
  try
    StepResult := Step(Stmt);
    // For statements with no result rows (CREATE, INSERT, etc.) the
    // expected step result is SQLITE_DONE. We accept both DONE and
    // OK as success in case SQLite ever changes semantics.
    Result := (StepResult = SQLITE_DONE) or (StepResult = SQLITE_OK);
    if not Result then
      CaptureLastError;
  finally
    Finalize(Stmt);
  end;
end;

function TYutaniSQLiteDB.Prepare(const SQL: AnsiString; out Stmt: TSQLiteStmt): Boolean;
begin
  Stmt := nil;
  if FDB = nil then
  begin
    FLastError := 'Database is not open';
    Exit(False);
  end;
  if sqlite3_prepare_v2(FDB, PAnsiChar(SQL), SQLITE_SQL_LENGTH_NULLTERM, Stmt, nil) = SQLITE_OK then
    Result := True
  else
  begin
    Result := False;
    Stmt := nil;
    CaptureLastError;
  end;
end;

class procedure TYutaniSQLiteDB.BindInt(Stmt: TSQLiteStmt; Idx: Integer; Val: Integer);
begin
  sqlite3_bind_int(Stmt, Idx, Val);
end;

class procedure TYutaniSQLiteDB.BindInt64(Stmt: TSQLiteStmt; Idx: Integer; Val: Int64);
begin
  sqlite3_bind_int64(Stmt, Idx, Val);
end;

class procedure TYutaniSQLiteDB.BindDouble(Stmt: TSQLiteStmt; Idx: Integer; Val: Double);
begin
  sqlite3_bind_double(Stmt, Idx, Val);
end;

class procedure TYutaniSQLiteDB.BindText(Stmt: TSQLiteStmt; Idx: Integer; const Val: AnsiString);
begin
  // SQLITE_TRANSIENT tells SQLite to make a private copy of the text
  // so the caller's string can be freed / reused immediately. This is
  // the safe default for short-lived string buffers.
  sqlite3_bind_text(Stmt, Idx, PAnsiChar(Val), Length(Val), SQLITE_TRANSIENT);
end;

class procedure TYutaniSQLiteDB.BindTextW(Stmt: TSQLiteStmt; Idx: Integer; const Val: string);
var
  AnsiVal: AnsiString;
begin
  AnsiVal := AnsiString(Val);
  sqlite3_bind_text(Stmt, Idx, PAnsiChar(AnsiVal), Length(AnsiVal), SQLITE_TRANSIENT);
end;

class procedure TYutaniSQLiteDB.BindNull(Stmt: TSQLiteStmt; Idx: Integer);
begin
  sqlite3_bind_null(Stmt, Idx);
end;

class function TYutaniSQLiteDB.Step(Stmt: TSQLiteStmt): Integer;
begin
  Result := sqlite3_step(Stmt);
end;

class procedure TYutaniSQLiteDB.Finalize(Stmt: TSQLiteStmt);
begin
  if Stmt <> nil then
    sqlite3_finalize(Stmt);
end;

class procedure TYutaniSQLiteDB.Reset(Stmt: TSQLiteStmt);
begin
  if Stmt <> nil then
    sqlite3_reset(Stmt);
end;

class function TYutaniSQLiteDB.ColumnInt(Stmt: TSQLiteStmt; Idx: Integer): Integer;
begin
  Result := sqlite3_column_int(Stmt, Idx);
end;

class function TYutaniSQLiteDB.ColumnInt64(Stmt: TSQLiteStmt; Idx: Integer): Int64;
begin
  Result := sqlite3_column_int64(Stmt, Idx);
end;

class function TYutaniSQLiteDB.ColumnDouble(Stmt: TSQLiteStmt; Idx: Integer): Double;
begin
  Result := sqlite3_column_double(Stmt, Idx);
end;

class function TYutaniSQLiteDB.ColumnText(Stmt: TSQLiteStmt; Idx: Integer): AnsiString;
var
  P: PAnsiChar;
  N: Integer;
begin
  P := sqlite3_column_text(Stmt, Idx);
  N := sqlite3_column_bytes(Stmt, Idx);
  if (P <> nil) and (N > 0) then
  begin
    SetLength(Result, N);
    Move(P^, Result[1], N);
  end
  else
    Result := '';
end;

class function TYutaniSQLiteDB.ColumnTextW(Stmt: TSQLiteStmt; Idx: Integer): string;
begin
  Result := string(ColumnText(Stmt, Idx));
end;

const
  DISTANT_STAR_COUNT = 3000;
  CHUNK_SIZE = 2000.0;
  CHUNK_RADIUS = 1;
  STAR_CLUSTER_CHANCE = 0.6;
  NEBULA_CHANCE = 0.08;
  SUN_CHANCE = 0.04;
  COMET_SHELL_RADIUS = 500.0;
  MAX_COMETS = 8;
  NEBULA_BASE_SIZE = 150.0;
  DISTANT_SHELL_RADIUS = 950.0;
  FADE_START_DIST = 700.0;
  FADE_END_DIST = 940.0;
  MAX_COMET_PARTICLES = 10000;
  COMET_PARTICLE_RATE = 7;
  PLANET_MIN_RADIUS = 60.0;
  PLANET_MAX_RADIUS = 180.0;
  // Coarse galaxy grid for star system placement. Two systems can't
  // spawn closer than this; galaxy positions are rounded to this grid
  // before DB lookups and procedural seed hashing.
  GALAXY_GRID = 1000.0;
  // Default SQLite DB filename - placed next to the executable in a
  // "ressources" subfolder so it stays organized alongside other data.
  GALAXY_DB_FILENAME = 'ressources\galaxy.sqlite';
  // Ambient dust particle system tuning.
  // Tuned for visibility against black space + bright suns/planets.
  // The previous values (600 / 200-1000 / 0.5-3.0 / 0.5-4.0) produced
  // mostly sub-pixel specks even after the spawn-init bug was fixed -
  // at 1000u distance a 0.5u billboard is ~0.7px and a 3.0u billboard
  // is only ~4px. The new values pull the shell much closer, double
  // the particle count, scale up sizes and bump the drift speed so the
  // player actually sees rocks drifting past the cockpit instead of
  // static invisible pinpricks.
  DUST_PARTICLE_COUNT = 1000;
  DUST_SHELL_INNER = 30.0;
  DUST_SHELL_OUTER = 350.0;
  DUST_RESPAWN_DIST = 400.0;
  DUST_MIN_SIZE = 0.1;
  DUST_MAX_SIZE = 0.3;
  DUST_MIN_SPEED = 3.0;
  DUST_MAX_SPEED = 12.0;
  // Minimap tuning.
  MINIMAP_SIZE = 200;                 // pixel size of the square overlay
  MINIMAP_MARGIN = 20;                // pixel gap from screen edge
  MINIMAP_RANGE = 10000.0;            // world units shown across the minimap
  MINIMAP_CACHE_TTL = 10.0;           // seconds between DB refreshes

function MakeCol(r, g, b: Byte): TColorB;
begin
  Result.r := r;
  Result.g := g;
  Result.b := b;
  Result.a := 255;
end;
{ TSpaceWorld }

constructor TSpaceWorld.Create(const ALightShader: TShader);
var
  Mesh: TMesh;
  DefaultShader: TShader;
  DBPath: string;
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
  // Galaxy manager defaults. Tunables are exposed as properties so a
  // settings dialog can override them later. With the default flight
  // speed of ~100 u/s these give roughly 30-60 seconds per system hop,
  // not minutes - the user should never feel like they're stuck in
  // empty space with no destination in sight.
  FPhase := gpAtSystem;
  FCurrentVis := 1.0;
  FNextVis := 0.0;
  FTravelTimer := 0.0;
  FCamForward := Vector3Create(0, 0, 1);  // Initial fallback until real movement
  FCurrentSeed := 42;
  FNextSeed := 0;
  FCurrentGalaxyPos := Vector3Create(0, 0, 0);
  FNextGalaxyPos := Vector3Create(0, 0, 0);
  // Reduced departure distances for a snappy exit, but the approach
  // phase uses much longer fade distances so the new system appears
  // as a dim speck far away and slowly brightens as the player
  // approaches - no more "pops into view fully sized" snaps.
  //   Departure fade: 800 -> 1500 (7s of fade-out at 100 u/s)
  //   Empty void: 2 seconds (just enough to register "I left")
  //   Target placed 6000 units ahead when picked
  //   Approach fade-in: starts at 5000 distance (long dim speck),
  //                    reaches full brightness at 100 units
  //   Arrive swap at 100 distance
  // Total: ~7s depart + 2s void + ~59s approach = ~68 seconds per
  // hop, which gives the user a clear "destination growing ahead"
  // experience rather than a system materializing right in front of
  // them.
  FFadeStartDist := 800.0;
  FFadeEndDist := 1500.0;
  FTargetPickDistance := 6000.0;
  FTargetApproachFadeStart := 5000.0;
  FArriveDistance := 100.0;
  FMinTravelTime := 2.0;
  // SQLite persistence. Failure to open is non-fatal - the manager
  // still works in-memory, systems just won't be saved between runs.
  FGalaxyDB := TYutaniSQLiteDB.Create;
  DBPath := ExtractFilePath(ParamStr(0)) + GALAXY_DB_FILENAME;
  ForceDirectories(ExtractFilePath(DBPath));
  if FGalaxyDB.Open(DBPath, True) then
    EnsureGalaxySchema;
  SetLength(FDistantStars, DISTANT_STAR_COUNT);
  SetLength(FCometParticles, MAX_COMET_PARTICLES);
  SetLength(FDust, DUST_PARTICLE_COUNT);
  FDiscoveredSystemsCache := nil;
  FDiscoveredCacheAge := MINIMAP_CACHE_TTL + 1.0;  // force refresh on first call
  Randomize;
  InitializeDistantStars;
  // The heavy generation is now triggered externally via GenerateAssetsAsync,
  // but we keep a fallback in case it's called directly.
  GeneratePlanetAssets(ALightShader);
  // Generate Sun Texture
  FSunTexture := TSunTextureGen.Generate(Cardinal(Random(MaxInt)), 2048);
  Mesh := GenMeshSphere(1.0, 48, 32);
  UploadMesh(@Mesh, False);
  FSunModel := LoadModelFromMesh(Mesh);
  DefaultShader := LoadShader(nil, nil);
  if DefaultShader.id > 0 then
    FSunModel.materials[0].shader := DefaultShader;
  FSunModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FSunTexture;
  SpawnStarterPlanets;
  // After SpawnStarterPlanets the home sun lives at FSuns[0]. Capture
  // its position as the current galaxy cell so subsequent phase machine
  // logic (and DB upserts) reference the correct home coordinates.
  if Length(FSuns) > 0 then
  begin
    FCurrentGalaxyPos.x := Round(FSuns[0].Position.x / GALAXY_GRID) * GALAXY_GRID;
    FCurrentGalaxyPos.y := Round(FSuns[0].Position.y / GALAXY_GRID) * GALAXY_GRID;
    FCurrentGalaxyPos.z := Round(FSuns[0].Position.z / GALAXY_GRID) * GALAXY_GRID;
  end;
  // Save the home system to the DB so it always has a stable row even
  // on a fresh install. The seed (42) is preserved by SpawnStarterPlanets
  // so a re-load reproduces the exact same home layout.
  SaveCurrentSystemToDB;
end;

destructor TSpaceWorld.Destroy;
begin
  DestroyPlanetAssets;
  if FSunTexture.id > 0 then
    UnloadTexture(FSunTexture);
  if FSunModel.meshes <> nil then
    UnloadModel(FSunModel);
  SetLength(FDistantStars, 0);
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);
  SetLength(FPlanets, 0);
  SetLength(FSuns, 0);
  SetLength(FNextSuns, 0);
  SetLength(FNextPlanets, 0);
  SetLength(FComets, 0);
  SetLength(FCometParticles, 0);
  SetLength(FDust, 0);
  FDiscoveredSystemsCache := nil;
  // Close the SQLite connection - the wrapper frees itself.
  FreeAndNil(FGalaxyDB);
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
  // Expanded color palette: White, Blue, Red, Yellow, Orange, Purple, Cyan
  case Tint of
    0:
      Result := ColorAlpha(WHITE, Alpha);
    1:
      Result := ColorAlpha(Fade(BLUE, 0.8), Alpha);
    2:
      Result := ColorAlpha(Fade(RED, 0.8), Alpha);
    3:
      Result := ColorAlpha(Fade(YELLOW, 0.9), Alpha);
    4:
      Result := ColorAlpha(Fade(ORANGE, 0.9), Alpha);
    5:
      Result := ColorAlpha(Fade(PURPLE, 0.8), Alpha);
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
 *  PLANET ASSETS & LIGHTING
 *==============================================================================}

procedure TSpaceWorld.GeneratePlanetAssets(const ALightShader: TShader);
var
  i: Integer;
  Mesh: TMesh;
begin
  for i := 0 to 4 do
  begin
    FPlanetTextures[i] := TPlanetTextureGen.Generate(i, Cardinal(Random(MaxInt)), 3072);
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
    if FPlanetTextures[i].id > 0 then
      UnloadTexture(FPlanetTextures[i]);
    if FPlanetModels[i].meshes <> nil then
      UnloadModel(FPlanetModels[i]);
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
  if (Length(FSuns) = 0) or (Length(FPlanetModels) = 0) then
    Exit;
  if FPlanetModels[0].materials[0].Shader.id = 0 then
    Exit;
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
  if not HasSun then
    Exit;
  LightPosArr[0] := NearestSun.Position.x;
  LightPosArr[1] := NearestSun.Position.y;
  LightPosArr[2] := NearestSun.Position.z;
  ViewPosArr[0] := CameraPos.x;
  ViewPosArr[1] := CameraPos.y;
  ViewPosArr[2] := CameraPos.z;
  // Higher ambient so the darkside is not pitch black
  Ambient[0] := 0.25;
  Ambient[1] := 0.25;
  Ambient[2] := 0.3;
  Ambient[3] := 1.0;
  // Very bright sun diffuse
  Diffuse[0] := 2.0;
  Diffuse[1] := 2.0;
  Diffuse[2] := 1.8;
  Diffuse[3] := 1.0;
  // Set the light radius VERY high so the sun reaches far planets
  Radius := 10000.0;
  RadiusArr[0] := Radius;
  for i := 0 to 4 do
  begin
    if FPlanetModels[i].meshes <> nil then
    begin
      // Get the TShader object directly from the material
      Shader := FPlanetModels[i].materials[0].Shader;
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
  // Home System is 400 units away.
  SystemOffset := Vector3Create(400, 0, 400);
  // 1. Home Sun
  SunIdx := Length(FSuns);
  SetLength(FSuns, SunIdx + 1);
  FSuns[SunIdx].Position := SystemOffset;
  FSuns[SunIdx].Radius := 100.0;
  FSuns[SunIdx].Color := MakeCol(180, 100, 0);
  // 2. Home Planets
  // CRITICAL FIX: Distance from Sun(400,0,400) to Origin(0,0,0) is ~565 units.
  // To GUARANTEE that no planet ever crosses (0,0,0), the orbit radius
  // MUST be strictly greater than the distance from the Sun to the Origin.
  // We start the first planet at OrbitR = 650, which is safely outside 565.
  OrbitR := 600.0;
  for i := 0 to 4 do
  begin
    OrbitR := OrbitR + 150.0 + (i * 50.0); // Safe, non-intersecting orbits: 750, 950, 1150, 1350, 1550
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
    // CRITICAL: Position is relative to the sun!
    FPlanets[idx].Position := Vector3Add(SystemOffset, Vector3Create(Cos(FPlanets[idx].OrbitAngle) * FPlanets[idx].OrbitRadius, 0, Sin(FPlanets[idx].OrbitAngle) * FPlanets[idx].OrbitRadius));
  end;
end;

procedure TSpaceWorld.RegenerateNearContent(const CameraPos: TVector3);
var
  cx, cy, cz, dx, dy, dz: Integer;
  ChunkOrigin: TVector3;
  i, idx, StarCount, ClusterCount: Integer;
  ClusterCenter: TVector3;
begin
  // Background decoration only - we deliberately do NOT touch FSuns
  // or FPlanets here anymore. Those arrays are owned by the galaxy
  // phase machine (see UpdateGalaxyPhase) which manages exactly one
  // current system + an optional next system for transitions.
  cx := Round(CameraPos.x / CHUNK_SIZE);
  cy := Round(CameraPos.y / CHUNK_SIZE);
  cz := Round(CameraPos.z / CHUNK_SIZE);
  FLastChunkX := cx;
  FLastChunkY := cy;
  FLastChunkZ := cz;
  SetLength(FNearStars, 0);
  SetLength(FNebulae, 0);
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
          ClusterCenter := Vector3Add(ChunkOrigin, Vector3Create((NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE));
          ClusterCount := 15 + Trunc(NextRand * 30);
          for i := 0 to ClusterCount - 1 do
          begin
            idx := Length(FNearStars);
            SetLength(FNearStars, idx + 1);
            FNearStars[idx].Position := Vector3Add(ClusterCenter, Vector3Create((NextRand - 0.5) * 400, (NextRand - 0.5) * 400, (NextRand - 0.5) * 400));
            FNearStars[idx].Size := 4.0 + NextRand * 12.0;
            FNearStars[idx].Brightness := 0.6 + NextRand * 0.4;
            FNearStars[idx].TwinklePhase := NextRand * 2.0 * PI;
            FNearStars[idx].TwinkleSpeed := 0.5 + NextRand * 2.5;
            FNearStars[idx].ColorTint := Trunc(NextRand * 7); // 0-6 (7 colors)
          end;
        end
        else
        begin
          // FILL BACKGROUND: More scattered single stars to reduce empty space
          StarCount := 5 + Trunc(NextRand * 5); // 5-10 stars per chunk
          for i := 0 to StarCount - 1 do
          begin
            idx := Length(FNearStars);
            SetLength(FNearStars, idx + 1);
            FNearStars[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE));
            // Small and dim
            FNearStars[idx].Size := 2.0 + NextRand * 4.0;
            FNearStars[idx].Brightness := 0.3 + NextRand * 0.3;
            FNearStars[idx].TwinklePhase := NextRand * 2.0 * PI;
            FNearStars[idx].TwinkleSpeed := 0.3 + NextRand * 2.0;
            FNearStars[idx].ColorTint := Trunc(NextRand * 7); // 0-6 (7 colors)
          end;
        end;
        // Nebulae
        SeedRand(HashChunk(ccx, ccy, ccz) xor $FF00FF);
        if NextRand < NEBULA_CHANCE then
        begin
          idx := Length(FNebulae);
          SetLength(FNebulae, idx + 1);
          FNebulae[idx].Position := Vector3Add(ChunkOrigin, Vector3Create((NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE, (NextRand - 0.5) * CHUNK_SIZE));
          FNebulae[idx].Size := NEBULA_BASE_SIZE * (0.8 + NextRand * 2.5);
          case Trunc(NextRand * 4) of
            0:
              FNebulae[idx].Color := ColorAlpha(PURPLE, 35);
            1:
              FNebulae[idx].Color := ColorAlpha(Fade(BLUE, 0.8), 35);
            2:
              FNebulae[idx].Color := ColorAlpha(Fade(ORANGE, 0.6), 35);
            3:
              FNebulae[idx].Color := ColorAlpha(Fade(RED, 0.5), 25);
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
        if i < High(FComets) then
          FComets[i] := FComets[High(FComets)];
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
    if P^.IsLocked then
      Continue;
    if P^.IsMoon then
    begin
      P^.MoonAngle := P^.MoonAngle + P^.MoonSpeed * dt;
      if P^.ParentPlanetIndex >= 0 then
      begin
        ParentPos := FPlanets[P^.ParentPlanetIndex].Position;
        P^.Position := Vector3Add(ParentPos, Vector3Create(Cos(P^.MoonAngle) * P^.MoonRadius, 0, Sin(P^.MoonAngle) * P^.MoonRadius));
      end;
    end
    else if P^.OrbitSunIndex >= 0 then
    begin
      P^.OrbitAngle := P^.OrbitAngle + P^.OrbitSpeed * dt;
      SunPos := FSuns[P^.OrbitSunIndex].Position;
      P^.Position := Vector3Add(SunPos, Vector3Create(Cos(P^.OrbitAngle) * P^.OrbitRadius, 0, Sin(P^.OrbitAngle) * P^.OrbitRadius));
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
  i: Integer;
  Delta, CamForward: TVector3;
  DeltaLen: Single;
begin
  FTime := FTime + dt;
  FTimeScale := TimeScale;
  ScaledDt := dt * FTimeScale;
  // Compute the camera's actual flight direction from the delta between
  // this frame's position and the previous frame's. FCameraPos still
  // holds the previous value at this point (we update it below). When
  // the user is hovering in place (delta too small) we keep the last
  // known direction so the phase machine still has a sensible forward
  // to place the next target in. This fixes the bug where gpTraveling
  // fell back to a hardcoded (0,0,1) and placed targets 4000 units in
  // +Z regardless of where the user was actually flying.
  Delta := Vector3Subtract(CameraPos, FCameraPos);
  DeltaLen := Vector3Length(Delta);
  if DeltaLen > 0.01 then
  begin
    CamForward := Vector3Scale(Delta, 1.0 / DeltaLen);
    FCamForward := CamForward;
  end
  else
    CamForward := FCamForward;
  FCameraPos := CameraPos;
  // Background decoration (near stars + nebulae) still regenerates on
  // chunk boundaries - this is just visual fluff and does not affect
  // the active star system lifecycle.
  cx := Round(CameraPos.x / CHUNK_SIZE);
  cy := Round(CameraPos.y / CHUNK_SIZE);
  cz := Round(CameraPos.z / CHUNK_SIZE);
  if (cx <> FLastChunkX) or (cy <> FLastChunkY) or (cz <> FLastChunkZ) then
    RegenerateNearContent(CameraPos);
  // Drive the one-system-at-a-time phase machine with the real flight
  // direction so the next target is always placed ahead of the user.
  UpdateGalaxyPhase(ScaledDt, CameraPos, CamForward);
  FSpawnTimer := FSpawnTimer - ScaledDt;
  if FSpawnTimer <= 0 then
  begin
    SpawnComet(CameraPos);
    FSpawnTimer := 1.5 + Random * 3.5;
  end;
  UpdateOrbits(ScaledDt);
  UpdateComets(ScaledDt, CameraPos);
  UpdateCometParticles(ScaledDt);
  // Drift the ambient dust particles + wrap them when they wander too
  // far from the camera. Cheap O(N) loop, N=600 by default.
  UpdateDust(ScaledDt, CameraPos);
  CheckCometCollisions;
  // SUN CORONA PARTICLES (Spawned here, rendered later in RenderCometParticles)
  if Length(FSuns) > 0 then
  begin
    for i := 0 to High(FSuns) do
    begin
      if Random < 0.5 then
      begin
        var Theta := Random * 2.0 * PI;
        var Phi := ArcCos(Random * 2.0 - 1.0);
        var SurfDir := Vector3Create(Sin(Phi) * Cos(Theta), Sin(Phi) * Sin(Theta), Cos(Phi));
        var PPos := Vector3Add(FSuns[i].Position, Vector3Scale(SurfDir, FSuns[i].Radius));
        SpawnCometParticle(PPos, Vector3Scale(SurfDir, 15.0), 4.0);
      end;
    end;
  end;
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
{==============================================================================*
 *  GALAXY MANAGER - One-System-At-A-Time Lifecycle
 *==============================================================================}

function TSpaceWorld.HashGalaxyPos(x, y, z: Double): Cardinal;
var
  h: Cardinal;
  ix, iy, iz: Int64;
begin
  // Round to the coarse galaxy grid so floating-point jitter does not
  // cause two systems at "the same" position to hash differently.
  ix := Round(x / GALAXY_GRID);
  iy := Round(y / GALAXY_GRID);
  iz := Round(z / GALAXY_GRID);
  // Mix the three coordinates into a 32-bit hash using the same primes
  // as the legacy HashChunk so the existing galaxy stays consistent if
  // anyone ever cross-references the two systems.
  h := Cardinal(ix) * 73856093;
  h := h xor (Cardinal(iy) * 19349663);
  h := h xor (Cardinal(iz) * 83492767);
  h := h xor (h shr 13);
  h := h * 1274126177;
  h := h xor (h shr 16);
  Result := h;
end;

procedure TSpaceWorld.EnsureGalaxySchema;
const
  SQL_CREATE: AnsiString = 'CREATE TABLE IF NOT EXISTS star_systems (' + '  system_id INTEGER PRIMARY KEY AUTOINCREMENT,' + '  galaxy_x REAL NOT NULL,' + '  galaxy_y REAL NOT NULL,' + '  galaxy_z REAL NOT NULL,' + '  seed INTEGER NOT NULL,' + '  sun_radius REAL NOT NULL DEFAULT 100.0,' + '  sun_color_r INTEGER NOT NULL DEFAULT 255,' + '  sun_color_g INTEGER NOT NULL DEFAULT 200,' + '  sun_color_b INTEGER NOT NULL DEFAULT 80,' + '  visit_count INTEGER NOT NULL DEFAULT 1,' + '  discovered_at TEXT,' + '  name TEXT' + ');';
  SQL_INDEX: AnsiString = 'CREATE UNIQUE INDEX IF NOT EXISTS idx_galaxy_pos ' + 'ON star_systems(galaxy_x, galaxy_y, galaxy_z);';
begin
  if not Assigned(FGalaxyDB) then
    Exit;
  FGalaxyDB.Execute(SQL_CREATE);
  FGalaxyDB.Execute(SQL_INDEX);
end;

procedure TSpaceWorld.SaveCurrentSystemToDB;
const
  SQL_UPSERT: AnsiString = 'INSERT INTO star_systems ' + '(galaxy_x, galaxy_y, galaxy_z, seed, sun_radius, sun_color_r, ' + ' sun_color_g, sun_color_b, visit_count, discovered_at, name) ' + 'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ' + 'ON CONFLICT(galaxy_x, galaxy_y, galaxy_z) DO UPDATE SET ' + '  visit_count = visit_count + 1;';
var
  Stmt: TSQLiteStmt;
  StepResult: Integer;
  Sun: ^TSun;
begin
  // Best-effort persistence - if the DB is not open or any step fails
  // we silently skip. The simulation continues with the in-memory
  // copy regardless.
  if (not Assigned(FGalaxyDB)) or (not FGalaxyDB.DllAvailable) then
    Exit;
  if (FGalaxyDB.DB = nil) or (Length(FSuns) = 0) then
    Exit;
  Sun := @FSuns[0];
  if not FGalaxyDB.Prepare(SQL_UPSERT, Stmt) then
    Exit;
  try
    TYutaniSQLiteDB.BindDouble(Stmt, 1, FCurrentGalaxyPos.x);
    TYutaniSQLiteDB.BindDouble(Stmt, 2, FCurrentGalaxyPos.y);
    TYutaniSQLiteDB.BindDouble(Stmt, 3, FCurrentGalaxyPos.z);
    TYutaniSQLiteDB.BindInt64(Stmt, 4, Int64(FCurrentSeed));
    TYutaniSQLiteDB.BindDouble(Stmt, 5, Sun^.Radius);
    TYutaniSQLiteDB.BindInt(Stmt, 6, Sun^.Color.r);
    TYutaniSQLiteDB.BindInt(Stmt, 7, Sun^.Color.g);
    TYutaniSQLiteDB.BindInt(Stmt, 8, Sun^.Color.b);
    TYutaniSQLiteDB.BindInt(Stmt, 9, 1);
    TYutaniSQLiteDB.BindTextW(Stmt, 10, DateTimeToStr(Now));
    TYutaniSQLiteDB.BindTextW(Stmt, 11, 'System-' + IntToHex(FCurrentSeed, 8));
    StepResult := TYutaniSQLiteDB.Step(Stmt);
    // Result ignored - we only care that the call did not crash.
    if (StepResult <> SQLITE_DONE) and (StepResult <> SQLITE_OK) then
      OutputDebugString(PChar('Galaxy DB upsert failed: ' + FGalaxyDB.LastError));
  finally
    TYutaniSQLiteDB.Finalize(Stmt);
  end;
end;

function TSpaceWorld.LoadSystemSeedFromDB(const GalaxyPos: TVector3; out OutSeed: Cardinal): Boolean;
const
  SQL_LOAD: AnsiString = 'SELECT seed FROM star_systems WHERE galaxy_x = ? AND galaxy_y = ? AND galaxy_z = ?;';
var
  Stmt: TSQLiteStmt;
  StepResult: Integer;
  RoundedPos: TVector3;
begin
  Result := False;
  OutSeed := 0;
  if (not Assigned(FGalaxyDB)) or (FGalaxyDB.DB = nil) then
    Exit;
  // Snap to grid so DB lookups match exactly despite float jitter.
  RoundedPos.x := Round(GalaxyPos.x / GALAXY_GRID) * GALAXY_GRID;
  RoundedPos.y := Round(GalaxyPos.y / GALAXY_GRID) * GALAXY_GRID;
  RoundedPos.z := Round(GalaxyPos.z / GALAXY_GRID) * GALAXY_GRID;
  if not FGalaxyDB.Prepare(SQL_LOAD, Stmt) then
    Exit;
  try
    TYutaniSQLiteDB.BindDouble(Stmt, 1, RoundedPos.x);
    TYutaniSQLiteDB.BindDouble(Stmt, 2, RoundedPos.y);
    TYutaniSQLiteDB.BindDouble(Stmt, 3, RoundedPos.z);
    StepResult := TYutaniSQLiteDB.Step(Stmt);
    if StepResult = SQLITE_ROW then
    begin
      OutSeed := Cardinal(TYutaniSQLiteDB.ColumnInt64(Stmt, 0));
      Result := True;
    end;
  finally
    TYutaniSQLiteDB.Finalize(Stmt);
  end;
end;

procedure TSpaceWorld.GenerateSystemAt(var Suns: TArray<TSun>; var Planets: TArray<TSpacePlanet>; const SunPos: TVector3; Seed: Cardinal; Append: Boolean);
var
  i, j, idx, PlanetCount, PlanetType: Integer;
  OrbitR, SunRadius: Single;
  HasMoon: Boolean;
  SunIdx: Integer;
  LocalRng: Cardinal;

  function Rand: Single;
  begin
    LocalRng := LocalRng xor (LocalRng shl 13);
    LocalRng := LocalRng xor (LocalRng shr 17);
    LocalRng := LocalRng xor (LocalRng shl 5);
    Result := (LocalRng and $00FFFFFF) / $00FFFFFF;
  end;

begin
  // We use a private RNG seeded with the supplied value so the call
  // does not perturb the global FRngState used by the rest of the
  // simulation. Deterministic: same seed always yields the same system.
  LocalRng := Seed;
  if LocalRng = 0 then
    LocalRng := 1;
  // Clear the destination arrays unless the caller explicitly asked us
  // to append (used by the home bootstrap which has planets already).
  if not Append then
  begin
    SetLength(Suns, 0);
    SetLength(Planets, 0);
  end;
  // Sun
  SunIdx := Length(Suns);
  SetLength(Suns, SunIdx + 1);
  Suns[SunIdx].Position := SunPos;
  SunRadius := 80.0 + Rand * 100.0;
  Suns[SunIdx].Radius := SunRadius;
  if Rand > 0.5 then
    Suns[SunIdx].Color := MakeCol(255, 200, 80)
  else
    Suns[SunIdx].Color := MakeCol(255, 150, 50);
  // Planets + moons. Mirrors the old chunk-based layout so the visual
  // feel is identical to what the user is used to.
  PlanetCount := 1 + Trunc(Rand * 3);
  OrbitR := SunRadius * 3.0;
  for j := 0 to PlanetCount - 1 do
  begin
    OrbitR := OrbitR + 400.0 + Rand * 400.0;
    idx := Length(Planets);
    SetLength(Planets, idx + 1);
    Planets[idx].OrbitSunIndex := SunIdx;
    Planets[idx].OrbitRadius := OrbitR;
    Planets[idx].OrbitAngle := Rand * 2.0 * PI;
    Planets[idx].OrbitSpeed := 0.02 + Rand * 0.05;
    Planets[idx].Radius := PLANET_MIN_RADIUS + Rand * (PLANET_MAX_RADIUS - PLANET_MIN_RADIUS);
    PlanetType := Trunc(Rand * 5);
    Planets[idx].PlanetType := PlanetType;
    Planets[idx].IsMoon := False;
    Planets[idx].ParentPlanetIndex := -1;
    Planets[idx].IsLocked := False;
    case PlanetType of
      0:
        begin
          Planets[idx].PlanetColor := MakeCol(140, 120, 100);
          Planets[idx].AtmosphereColor := MakeCol(100, 80, 60);
          Planets[idx].HasAtmosphere := False;
        end;
      1:
        begin
          Planets[idx].PlanetColor := MakeCol(40, 100, 160);
          Planets[idx].AtmosphereColor := MakeCol(100, 150, 255);
          Planets[idx].HasAtmosphere := True;
        end;
      2:
        begin
          Planets[idx].PlanetColor := MakeCol(180, 80, 40);
          Planets[idx].AtmosphereColor := MakeCol(200, 100, 50);
          Planets[idx].HasAtmosphere := True;
        end;
      3:
        begin
          Planets[idx].PlanetColor := MakeCol(200, 160, 100);
          Planets[idx].AtmosphereColor := MakeCol(255, 200, 150);
          Planets[idx].HasAtmosphere := True;
        end;
      4:
        begin
          Planets[idx].PlanetColor := MakeCol(200, 220, 240);
          Planets[idx].AtmosphereColor := MakeCol(180, 210, 255);
          Planets[idx].HasAtmosphere := True;
        end;
    end;
    HasMoon := (Planets[idx].Radius > 100.0) and (Rand < 0.4);
    if HasMoon then
    begin
      idx := Length(Planets);
      SetLength(Planets, idx + 1);
      Planets[idx].IsMoon := True;
      Planets[idx].ParentPlanetIndex := idx - 1;
      Planets[idx].MoonAngle := Rand * 2.0 * PI;
      Planets[idx].MoonSpeed := 0.5 + Rand * 1.5;
      Planets[idx].MoonRadius := 30.0 + Rand * 50.0;
      Planets[idx].Radius := Planets[idx - 1].Radius * 0.25;
      Planets[idx].PlanetType := Trunc(Rand * 5);
      Planets[idx].OrbitSunIndex := -1;
      Planets[idx].HasAtmosphere := False;
      Planets[idx].PlanetColor := MakeCol(100, 100, 100);
      Planets[idx].IsLocked := False;
    end;
    // Position the planet at its current orbital angle so it starts in
    // a sensible spot. UpdateOrbits will keep it moving from there.
    Planets[idx].Position := Vector3Add(SunPos, Vector3Create(Cos(Planets[idx].OrbitAngle) * Planets[idx].OrbitRadius, 0, Sin(Planets[idx].OrbitAngle) * Planets[idx].OrbitRadius));
  end;
end;

procedure TSpaceWorld.PickNextSystem(const CameraPos, CameraForward: TVector3);
var
  TargetPos, RoundedPos: TVector3;
  LoadedSeed: Cardinal;
  FoundInDB: Boolean;
begin
  // Place the next system a fixed distance ahead in the flight
  // direction. We then round to the galaxy grid so the seed hash
  // and DB lookup are stable.
  TargetPos := Vector3Add(CameraPos, Vector3Scale(CameraForward, FTargetPickDistance));
  RoundedPos.x := Round(TargetPos.x / GALAXY_GRID) * GALAXY_GRID;
  RoundedPos.y := Round(TargetPos.y / GALAXY_GRID) * GALAXY_GRID;
  RoundedPos.z := Round(TargetPos.z / GALAXY_GRID) * GALAXY_GRID;
  // Try to load a previously-visited system first - that's how the
  // player can revisit a galaxy cell with the same layout.
  FoundInDB := LoadSystemSeedFromDB(RoundedPos, LoadedSeed);
  if FoundInDB then
    FNextSeed := LoadedSeed
  else
    FNextSeed := HashGalaxyPos(RoundedPos.x, RoundedPos.y, RoundedPos.z);
  FNextGalaxyPos := RoundedPos;
  // Generate the contents into FNextSuns / FNextPlanets. These stay
  // invisible until FNextVis rises above zero in the approaching phase.
  GenerateSystemAt(FNextSuns, FNextPlanets, RoundedPos, FNextSeed, False);
end;

procedure TSpaceWorld.SwapToNextSystem;
var
  i: Integer;
begin
  // Save the current system's metadata to the DB before promoting
  // next to current - this is the only write that happens during the
  // arrive transition so we don't burn DB I/O on every frame.
  SaveCurrentSystemToDB;
  // Promote next -> current. We assign the array references directly
  // because SetLength-copying would be wasteful and the existing
  // UpdateOrbits / RenderSuns etc. all read FSuns/FPlanets.
  FSuns := FNextSuns;
  FPlanets := FNextPlanets;
  FCurrentSeed := FNextSeed;
  FCurrentGalaxyPos := FNextGalaxyPos;
  // Clear next so it is obvious nothing is staged.
  FNextSuns := nil;
  FNextPlanets := nil;
  FNextSeed := 0;
  FNextGalaxyPos := Vector3Create(0, 0, 0);
  FNextVis := 0.0;
  FCurrentVis := 1.0;
  FPhase := gpAtSystem;
  FTravelTimer := 0.0;
end;

procedure TSpaceWorld.UpdateSystemVisibilities(const CameraPos: TVector3);
var
  CurDist, NextDist, FadeT: Single;
  CurSunPos, NextSunPos: TVector3;
begin
  // Current system visibility: 1.0 when near, fading to 0.0 as we leave.
  if Length(FSuns) > 0 then
  begin
    CurSunPos := FSuns[0].Position;
    CurDist := Vector3Distance(CameraPos, CurSunPos);
    if CurDist <= FFadeStartDist then
      FCurrentVis := 1.0
    else if CurDist >= FFadeEndDist then
      FCurrentVis := 0.0
    else
    begin
      FadeT := (CurDist - FFadeStartDist) / (FFadeEndDist - FFadeStartDist);
      FCurrentVis := 1.0 - FadeT;
    end;
  end
  else
    FCurrentVis := 0.0;
  // Next system visibility: 0.0 when far, fading to 1.0 as we approach.
  if Length(FNextSuns) > 0 then
  begin
    NextSunPos := FNextSuns[0].Position;
    NextDist := Vector3Distance(CameraPos, NextSunPos);
    if NextDist >= FTargetApproachFadeStart then
      FNextVis := 0.0
    else if NextDist <= FArriveDistance then
      FNextVis := 1.0
    else
    begin
      FadeT := (NextDist - FArriveDistance) / (FTargetApproachFadeStart - FArriveDistance);
      FNextVis := 1.0 - FadeT;
    end;
  end
  else
    FNextVis := 0.0;
end;

procedure TSpaceWorld.UpdateGalaxyPhase(dt: Single; const CameraPos, CameraForward: TVector3);
var
  CurDist, NextDist: Single;
begin
  // Always recompute visibility first - the render thread reads these
  // every frame regardless of phase, so they must be current even
  // during transitions where we are between two systems.
  UpdateSystemVisibilities(CameraPos);
  case FPhase of
    gpAtSystem:
      begin
      // If the camera has flown past FadeStartDist we begin the
      // departure sequence. This is also the trigger when the user
      // immediately beelines away from the home system at game start.
        if Length(FSuns) > 0 then
        begin
          CurDist := Vector3Distance(CameraPos, FSuns[0].Position);
          if CurDist > FFadeStartDist then
            FPhase := gpDeparting;
        end;
      end;
    gpDeparting:
      begin
      // Hold in departure until the current system is fully faded out,
      // then enter the empty-void traveling phase.
        if FCurrentVis <= 0.001 then
        begin
          FPhase := gpTraveling;
          FTravelTimer := 0.0;
        end;
      end;
    gpTraveling:
      begin
      // Accumulate the empty-void timer so the user gets a clear
      // "crossing empty space" moment before the next system appears.
        FTravelTimer := FTravelTimer + dt;
        if FTravelTimer >= FMinTravelTime then
        begin
          PickNextSystem(CameraPos, CameraForward);
          if Length(FNextSuns) > 0 then
            FPhase := gpApproaching;
        end;
      end;
    gpApproaching:
      begin
      // Wait until the camera is close enough to the next sun, then
      // promote it to current and reset to the AtSystem phase.
        if Length(FNextSuns) > 0 then
        begin
          NextDist := Vector3Distance(CameraPos, FNextSuns[0].Position);
          if NextDist <= FArriveDistance then
            SwapToNextSystem;
        end
        else
        begin
        // Lost the next system somehow - go back to traveling so we
        // can re-pick. This should not happen in normal operation.
          FPhase := gpTraveling;
          FTravelTimer := 0.0;
        end;
      end;
  end;
end;

procedure TSpaceWorld.RenderSuns;
var
  i, j: Integer;
  S: ^TSun;
  Pos: TVector3;
  GlowCol, TintCol: TColorB;
  DistArr: array of Single;
  TempDist: Single;
  TempSun: TSun;
  CurAlpha, NextAlpha: Byte;
begin
  if (Length(FSuns) = 0) and (Length(FNextSuns) = 0) then
    Exit;
  // Precompute alpha bytes from the visibility factors so we don't
  // multiply per-vertex in the inner loop. If the visibility is zero
  // for either system we still enter the loop body once - the alpha
  // is zero so the draw is a no-op visually but the cost is negligible
  // and it keeps the code path identical between phases.
  CurAlpha := Trunc(EnsureRange(FCurrentVis, 0, 1) * 255);
  NextAlpha := Trunc(EnsureRange(FNextVis, 0, 1) * 255);
  // 1. Sort current suns by distance (far to near) to prevent aura
  //    overlap bugs. We only sort FSuns here - FNextSuns has at most
  //    one sun so sorting is pointless.
  if Length(FSuns) > 0 then
  begin
    SetLength(DistArr, Length(FSuns));
    for i := 0 to High(FSuns) do
      DistArr[i] := Vector3Distance(FSuns[i].Position, FCameraPos);
    for i := 0 to High(FSuns) - 1 do
      for j := 0 to High(FSuns) - i - 1 do
        if DistArr[j] < DistArr[j + 1] then
        begin
          TempDist := DistArr[j];
          DistArr[j] := DistArr[j + 1];
          DistArr[j + 1] := TempDist;
          TempSun := FSuns[j];
          FSuns[j] := FSuns[j + 1];
          FSuns[j + 1] := TempSun;
        end;
  end;
  // PHASE 1: Render solid cores (Far to near).
  rlEnableDepthTest;
  rlEnableDepthMask;
  rlSetBlendMode(BLEND_ALPHA);
  // Current system suns - apply FCurrentVis as alpha multiplier so
  // they fade out smoothly when the player departs.
  if CurAlpha > 0 then
  begin
    TintCol := ColorAlpha(WHITE, CurAlpha);
    for i := 0 to High(FSuns) do
    begin
      S := @FSuns[i];
      Pos := S^.Position;
      if FSunModel.meshes <> nil then
        DrawModel(FSunModel, Pos, S^.Radius, TintCol)
      else
        DrawSphereEx(Pos, S^.Radius, 48, 32, TintCol);
    end;
  end;
  // Next system sun - apply FNextVis so it fades in as the player
  // approaches the target system.
  if (NextAlpha > 0) and (Length(FNextSuns) > 0) then
  begin
    TintCol := ColorAlpha(WHITE, NextAlpha);
    for i := 0 to High(FNextSuns) do
    begin
      S := @FNextSuns[i];
      Pos := S^.Position;
      if FSunModel.meshes <> nil then
        DrawModel(FSunModel, Pos, S^.Radius, TintCol)
      else
        DrawSphereEx(Pos, S^.Radius, 48, 32, TintCol);
    end;
  end;
  rlDrawRenderBatchActive;
  // PHASE 2: Render additive Glow.
  // CRITICAL FIX: Keep Depth TEST enabled so the aura checks if it's closer
  // than a background planet. We only disable Depth MASK so the aura doesn't
  // write to the depth buffer (preventing Z-fighting with the sun's core).
  rlEnableDepthTest;
  rlDisableDepthMask;
  rlSetBlendMode(BLEND_ADDITIVE);
  GlowCol := MakeCol(255, 200, 50);
  // Current system aura - scaled by visibility so departing suns
  // fade out their halo too, not just the solid core.
  if CurAlpha > 0 then
  begin
    for i := 0 to High(FSuns) do
    begin
      S := @FSuns[i];
      Pos := S^.Position;
      DrawSphere(Pos, S^.Radius * 1.2, ColorAlpha(GlowCol, Trunc(30 * FCurrentVis)));
      DrawSphere(Pos, S^.Radius * 1.4, ColorAlpha(GlowCol, Trunc(15 * FCurrentVis)));
    end;
  end;
  // Next system aura - scaled by FNextVis.
  if (NextAlpha > 0) and (Length(FNextSuns) > 0) then
  begin
    for i := 0 to High(FNextSuns) do
    begin
      S := @FNextSuns[i];
      Pos := S^.Position;
      DrawSphere(Pos, S^.Radius * 1.2, ColorAlpha(GlowCol, Trunc(30 * FNextVis)));
      DrawSphere(Pos, S^.Radius * 1.4, ColorAlpha(GlowCol, Trunc(15 * FNextVis)));
    end;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableDepthMask;
end;

procedure TSpaceWorld.RenderPlanets(const CameraPos, CamRight, CamUp: TVector3);
var
  i, j: Integer;
  P: ^TSpacePlanet;
  DistArr: array of Single;
  TempDist: Single;
  TempPlanet: TSpacePlanet;
  CurAlpha, NextAlpha: Byte;
  CurTint, NextTint: TColorB;
begin
  if (Length(FPlanets) = 0) and (Length(FNextPlanets) = 0) then
    Exit;
  CurAlpha := Trunc(EnsureRange(FCurrentVis, 0, 1) * 255);
  NextAlpha := Trunc(EnsureRange(FNextVis, 0, 1) * 255);
  // 1. Sort current planets by distance (far to near) so the depth
  //    buffer stays sane when planets overlap each other.
  if Length(FPlanets) > 0 then
  begin
    SetLength(DistArr, Length(FPlanets));
    for i := 0 to High(FPlanets) do
      DistArr[i] := Vector3Distance(FPlanets[i].Position, CameraPos);
    for i := 0 to High(FPlanets) - 1 do
      for j := 0 to High(FPlanets) - i - 1 do
        if DistArr[j] < DistArr[j + 1] then
        begin
          TempDist := DistArr[j];
          DistArr[j] := DistArr[j + 1];
          DistArr[j + 1] := TempDist;
          TempPlanet := FPlanets[j];
          FPlanets[j] := FPlanets[j + 1];
          FPlanets[j + 1] := TempPlanet;
        end;
  end;
  // PHASE 1: Atmosphere Glow (Far to near). We render current + next
  // systems in the same additive pass so atmospheres blend correctly
  // during the cross-fade transition.
  rlDisableDepthTest;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_TRIANGLES);
  try
    if CurAlpha > 0 then
    begin
      for i := 0 to High(FPlanets) do
      begin
        P := @FPlanets[i];
        if not P^.HasAtmosphere then
          Continue;
        DrawCircularBillboard(P^.Position, CamRight, CamUp, P^.Radius * 1.5, P^.AtmosphereColor, Trunc(55 * FCurrentVis));
        DrawCircularBillboard(P^.Position, CamRight, CamUp, P^.Radius * 2.5, P^.AtmosphereColor, Trunc(20 * FCurrentVis));
      end;
    end;
    if (NextAlpha > 0) and (Length(FNextPlanets) > 0) then
    begin
      for i := 0 to High(FNextPlanets) do
      begin
        P := @FNextPlanets[i];
        if not P^.HasAtmosphere then
          Continue;
        DrawCircularBillboard(P^.Position, CamRight, CamUp, P^.Radius * 1.5, P^.AtmosphereColor, Trunc(55 * FNextVis));
        DrawCircularBillboard(P^.Position, CamRight, CamUp, P^.Radius * 2.5, P^.AtmosphereColor, Trunc(20 * FNextVis));
      end;
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
  rlEnableBackfaceCulling;
  rlEnableDepthTest;
  // Update lighting uniforms - the closest sun of either system
  // wins. SetupPlanetLighting already iterates FSuns, and we keep
  // FNextSuns separate so the next system's sun does not steal
  // lighting until the swap actually happens. This is a minor
  // visual quirk during the brief cross-fade - acceptable trade-off.
  SetupPlanetLighting(CameraPos);
  // PHASE 2: Planet Bodies (Far to near). Same dual-loop pattern
  // as the atmosphere pass: current system first, then next system
  // (if visible), each scaled by its visibility factor.
  rlDrawRenderBatchActive;
  rlEnableDepthMask;
  rlEnableDepthTest;
  CurTint := ColorAlpha(WHITE, CurAlpha);
  NextTint := ColorAlpha(WHITE, NextAlpha);
  if CurAlpha > 0 then
  begin
    for i := 0 to High(FPlanets) do
    begin
      P := @FPlanets[i];
      if P^.PlanetType < 0 then
        P^.PlanetType := 0;
      if P^.PlanetType > 4 then
        P^.PlanetType := 4;
      if FPlanetModels[P^.PlanetType].meshes <> nil then
        DrawModel(FPlanetModels[P^.PlanetType], P^.Position, P^.Radius, CurTint)
      else
        DrawSphere(P^.Position, P^.Radius, ColorAlpha(P^.PlanetColor, CurAlpha));
    end;
  end;
  if (NextAlpha > 0) and (Length(FNextPlanets) > 0) then
  begin
    for i := 0 to High(FNextPlanets) do
    begin
      P := @FNextPlanets[i];
      if P^.PlanetType < 0 then
        P^.PlanetType := 0;
      if P^.PlanetType > 4 then
        P^.PlanetType := 4;
      if FPlanetModels[P^.PlanetType].meshes <> nil then
        DrawModel(FPlanetModels[P^.PlanetType], P^.Position, P^.Radius, NextTint)
      else
        DrawSphere(P^.Position, P^.Radius, ColorAlpha(P^.PlanetColor, NextAlpha));
    end;
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
    HeadSize := C^.Size * 0.5;
    DrawSphere(C^.Position, HeadSize, C^.Color);
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
end;
{==============================================================================*
 *  AMBIENT DUST SYSTEM
 *==============================================================================}

procedure TSpaceWorld.SpawnDustShell(const CameraPos: TVector3);
var
  i: Integer;
  D: ^TSpaceDust;
  theta, phi, Dist: Single;
  Dir: TVector3;
  Speed: Single;
  ColorPick: Integer;
begin
  // Seed all dust particles at once around the camera. Called once
  // during Create (well, lazily on first Update since we don't know
  // the camera position at construct time) - UpdateDust then keeps
  // them distributed as the camera moves.
  for i := 0 to High(FDust) do
  begin
    D := @FDust[i];
    // Random direction on a sphere
    theta := Random * 2.0 * PI;
    phi := ArcCos(Random * 2.0 - 1.0);
    Dir := Vector3Create(Sin(phi) * Cos(theta), Sin(phi) * Sin(theta), Cos(phi));
    // Random distance in the shell
    Dist := DUST_SHELL_INNER + Random * (DUST_SHELL_OUTER - DUST_SHELL_INNER);
    D^.Position := Vector3Add(CameraPos, Vector3Scale(Dir, Dist));
    // Slow random drift velocity
    Speed := DUST_MIN_SPEED + Random * (DUST_MAX_SPEED - DUST_MIN_SPEED);
    D^.Velocity := Vector3Scale(Dir, Speed);
    // Random size within the rock range
    D^.Size := DUST_MIN_SIZE + Random * (DUST_MAX_SIZE - DUST_MIN_SIZE);
    // Pick from a small palette of bright grays / browns so the dust
    // reads as actual rocks against black space. The previous palette
    // (50-130) was so dark that BLEND_ALPHA against black produced
    // (43, 43, 47) - basically indistinguishable from the background
    // unless silhouetted against a bright sun/planet. The new palette
    // keeps the earth-tone feel but is bright enough to read against
    // pure black so the player actually sees drifting rocks.
    ColorPick := Trunc(Random * 5);
    case ColorPick of
      0:
        begin
          D^.ColorR := 140;
          D^.ColorG := 140;
          D^.ColorB := 145;
        end;  // bright gray
      1:
        begin
          D^.ColorR := 175;
          D^.ColorG := 175;
          D^.ColorB := 180;
        end;  // light gray
      2:
        begin
          D^.ColorR := 200;
          D^.ColorG := 170;
          D^.ColorB := 120;
        end;  // light tan
      3:
        begin
          D^.ColorR := 165;
          D^.ColorG := 130;
          D^.ColorB := 90;
        end;  // medium brown
      4:
        begin
          D^.ColorR := 210;
          D^.ColorG := 190;
          D^.ColorB := 160;
        end;  // pale tan
    end;
  end;
end;

procedure TSpaceWorld.UpdateDust(const dt: Single; const CameraPos: TVector3);
var
  i: Integer;
  D: ^TSpaceDust;
  ToCam: TVector3;
  Dist: Single;
  NewDist, NewTheta, NewPhi: Single;
  NewDir: TVector3;
begin
  // Detect uninitialized dust: the constructor pre-allocates FDust with
  // SetLength (so Length is never 0), but the entries start zero-filled
  // with Size=0 / Position=(0,0,0). The original `Length(FDust) = 0`
// check therefore never triggered and SpawnDustShell was never
  // called, leaving 600 particles stuck at the origin with size 0 -
  // the billboard collapses to a degenerate point and renders nothing.
  // Checking the first entry's Size catches this case and spawns the
  // shell lazily on the first UpdateDust call, which also gives us
  // the real camera position instead of (0,0,0).
  if (Length(FDust) = 0) or ((Length(FDust) > 0) and (FDust[0].Size = 0)) then
  begin
    SpawnDustShell(CameraPos);
    Exit;
  end;
  for i := 0 to High(FDust) do
  begin
    D := @FDust[i];
    // Drift
    D^.Position := Vector3Add(D^.Position, Vector3Scale(D^.Velocity, dt));
    // If the speck has drifted too far from the camera, wrap it back
    // to a fresh random position in the shell. This keeps the dust
    // layer always surrounding the camera no matter where the player
    // flies.
    ToCam := Vector3Subtract(D^.Position, CameraPos);
    Dist := Vector3Length(ToCam);
    if Dist > DUST_RESPAWN_DIST then
    begin
      NewTheta := Random * 2.0 * PI;
      NewPhi := ArcCos(Random * 2.0 - 1.0);
      NewDir := Vector3Create(Sin(NewPhi) * Cos(NewTheta), Sin(NewPhi) * Sin(NewTheta), Cos(NewPhi));
      NewDist := DUST_SHELL_INNER + Random * (DUST_SHELL_OUTER - DUST_SHELL_INNER);
      D^.Position := Vector3Add(CameraPos, Vector3Scale(NewDir, NewDist));
      // Give it a fresh drift velocity too
      D^.Velocity := Vector3Scale(NewDir, DUST_MIN_SPEED + Random * (DUST_MAX_SPEED - DUST_MIN_SPEED));
    end;
  end;
end;

procedure TSpaceWorld.RenderDust(const CamRight, CamUp: TVector3);
var
  i: Integer;
  D: ^TSpaceDust;
  HalfSize, RX, RY, RZ, UX, UY, UZ: Single;
  Px, Py, Pz: Single;
  R, G, B: Byte;
begin
  if Length(FDust) = 0 then
    Exit;
  // Cache camera basis vectors to locals so the inner loop doesn't
  // do property lookups per vertex.
  RX := CamRight.x;
  RY := CamRight.y;
  RZ := CamRight.z;
  UX := CamUp.x;
  UY := CamUp.y;
  UZ := CamUp.z;
  rlDisableBackfaceCulling;
  rlSetBlendMode(BLEND_ALPHA);
  rlBegin(RL_TRIANGLES);
  try
    for i := 0 to High(FDust) do
    begin
      D := @FDust[i];
      HalfSize := D^.Size * 0.5;
      Px := D^.Position.x;
      Py := D^.Position.y;
      Pz := D^.Position.z;
      R := D^.ColorR;
      G := D^.ColorG;
      B := D^.ColorB;
      // Two-triangle quad facing the camera (billboard). Slightly
      // transparent so specks behind nearer ones don't completely
      // hide each other.
      rlColor4ub(R, G, B, 220);
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
  rlEnableBackfaceCulling;
end;
{==============================================================================*
 *  MINIMAP - 2D overlay showing discovered systems + current flight state
 *==============================================================================}

procedure TSpaceWorld.RefreshDiscoveredSystemsCache;
const
  SQL_ALL: AnsiString = 'SELECT galaxy_x, galaxy_y, galaxy_z FROM star_systems ORDER BY system_id;';
var
  Stmt: TSQLiteStmt;
  StepResult: Integer;
  Count: Integer;
  Pos: TVector3;
begin
  FDiscoveredSystemsCache := nil;
  FDiscoveredCacheAge := 0.0;
  if (not Assigned(FGalaxyDB)) or (FGalaxyDB.DB = nil) then
    Exit;
  if not FGalaxyDB.Prepare(SQL_ALL, Stmt) then
    Exit;
  try
    Count := 0;
    SetLength(FDiscoveredSystemsCache, 16);
    StepResult := TYutaniSQLiteDB.Step(Stmt);
    while StepResult = SQLITE_ROW do
    begin
      if Count >= Length(FDiscoveredSystemsCache) then
        SetLength(FDiscoveredSystemsCache, Count * 2);
      Pos.x := TYutaniSQLiteDB.ColumnDouble(Stmt, 0);
      Pos.y := TYutaniSQLiteDB.ColumnDouble(Stmt, 1);
      Pos.z := TYutaniSQLiteDB.ColumnDouble(Stmt, 2);
      FDiscoveredSystemsCache[Count] := Pos;
      Inc(Count);
      StepResult := TYutaniSQLiteDB.Step(Stmt);
    end;
    SetLength(FDiscoveredSystemsCache, Count);
  finally
    TYutaniSQLiteDB.Finalize(Stmt);
  end;
end;

procedure TSpaceWorld.RenderMinimap(const Camera: TCamera3D);
var
  ScreenW, ScreenH: Integer;
  MapX, MapY, HalfSize: Integer;
  i: Integer;
  Pos: TVector3;
  RelX, RelZ: Single;
  DotX, DotY: Integer;
  PlayerX, PlayerY: Integer;
  CurX, CurY: Integer;
  NextX, NextY: Integer;
  Bg: TColorB;
  TextBuf: AnsiString;
begin
  // Refresh the discovered-systems cache if it's stale. This avoids
  // querying the DB every frame - we only re-query at most once per
  // MINIMAP_CACHE_TTL seconds, which is more than enough for a
  // minimap that the user glances at occasionally.
  FDiscoveredCacheAge := FDiscoveredCacheAge + 0.016; // assume 60fps; close enough
  if FDiscoveredCacheAge >= MINIMAP_CACHE_TTL then
    RefreshDiscoveredSystemsCache;
  ScreenW := GetScreenWidth();
  ScreenH := GetScreenHeight();
  HalfSize := MINIMAP_SIZE div 2;
  MapX := ScreenW - MINIMAP_SIZE - MINIMAP_MARGIN;
  MapY := MINIMAP_MARGIN;
  // Background: dark semi-transparent square.
  Bg.r := 0;
  Bg.g := 0;
  Bg.b := 0;
  Bg.a := 200;
  DrawRectangle(MapX, MapY, MINIMAP_SIZE, MINIMAP_SIZE, Bg);
  // Border: bright frame so the minimap stands out against the scene.
  DrawRectangleLines(MapX, MapY, MINIMAP_SIZE, MINIMAP_SIZE, WHITE);
  // Center of the minimap = player position.
  PlayerX := MapX + HalfSize;
  PlayerY := MapY + HalfSize;
  // Scale: MINIMAP_RANGE world units span MINIMAP_SIZE pixels.
  // We display the XZ plane (top-down view); Y is ignored.
  // Discovered systems as small gray dots.
  for i := 0 to High(FDiscoveredSystemsCache) do
  begin
    Pos := FDiscoveredSystemsCache[i];
    RelX := (Pos.x - Camera.position.x) / MINIMAP_RANGE;
    RelZ := (Pos.z - Camera.position.z) / MINIMAP_RANGE;
    // Skip dots that fall outside the minimap square.
    if (Abs(RelX) > 0.5) or (Abs(RelZ) > 0.5) then
      Continue;
    DotX := PlayerX + Trunc(RelX * MINIMAP_SIZE);
    DotY := PlayerY + Trunc(RelZ * MINIMAP_SIZE);
    DrawCircle(DotX, DotY, 2, Fade(GRAY, 0.7));
  end;
  // Current system: green dot. Only drawn if within minimap range.
  if Length(FSuns) > 0 then
  begin
    Pos := FSuns[0].Position;
    RelX := (Pos.x - Camera.position.x) / MINIMAP_RANGE;
    RelZ := (Pos.z - Camera.position.z) / MINIMAP_RANGE;
    if (Abs(RelX) <= 0.5) and (Abs(RelZ) <= 0.5) then
    begin
      CurX := PlayerX + Trunc(RelX * MINIMAP_SIZE);
      CurY := PlayerY + Trunc(RelZ * MINIMAP_SIZE);
      DrawCircle(CurX, CurY, 4, GREEN);
      DrawLine(PlayerX, PlayerY, CurX, CurY, Fade(GREEN, 0.4));
    end;
  end;
  // Next (target) system: yellow dot + connecting line. Only drawn
  // when the phase machine actually has a target staged.
  if (Length(FNextSuns) > 0) and (FPhase = gpApproaching) then
  begin
    Pos := FNextSuns[0].Position;
    RelX := (Pos.x - Camera.position.x) / MINIMAP_RANGE;
    RelZ := (Pos.z - Camera.position.z) / MINIMAP_RANGE;
    if (Abs(RelX) <= 0.5) and (Abs(RelZ) <= 0.5) then
    begin
      NextX := PlayerX + Trunc(RelX * MINIMAP_SIZE);
      NextY := PlayerY + Trunc(RelZ * MINIMAP_SIZE);
      DrawCircle(NextX, NextY, 4, YELLOW);
      DrawLine(PlayerX, PlayerY, NextX, NextY, Fade(YELLOW, 0.6));
    end;
  end;
  // Player: white dot in the center with a small arrow pointing in
  // the flight direction so the user can see which way they're
  // heading at a glance.
  DrawCircle(PlayerX, PlayerY, 3, WHITE);
  // Arrow tip = player + forward * 12 pixels (clamped to minimap).
  DotX := PlayerX + Trunc(FCamForward.x * 12);
  DotY := PlayerY + Trunc(FCamForward.z * 12);
  DrawLine(PlayerX, PlayerY, DotX, DotY, WHITE);
  // Title + scale label.
  TextBuf := AnsiString('GALAXY MAP');
  DrawText(PAnsiChar(TextBuf), MapX + 4, MapY + 4, 12, RAYWHITE);
  TextBuf := AnsiString(Format('%.0f u range', [MINIMAP_RANGE]));
  DrawText(PAnsiChar(TextBuf), MapX + 4, MapY + MINIMAP_SIZE - 16, 10, GRAY);
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
    if P^.PlanetType < 0 then
      P^.PlanetType := 0;
    if P^.PlanetType > 4 then
      P^.PlanetType := 4;
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
  CamRight := Vector3Normalize(Vector3CrossProduct(CamForward, Camera.up));
  CamUp := Vector3Normalize(Vector3CrossProduct(CamRight, CamForward));
  SpaceProj := MatrixPerspective(Camera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 10000.0);
  rlSetMatrixProjection(SpaceProj);
  // 1. Background (Stars + Nebulae)
  RenderDistantStars(FCameraPos, CamRight, CamUp);
  RenderNebulae(FCameraPos, CamRight, CamUp);
  RenderNearStars(FCameraPos, CamRight, CamUp);
  // 1b. Ambient dust - drawn after the background stars so the dust
  //     specks (close range) layer in front of the distant star
  //     sprites. Uses standard alpha blend, not additive, so the
  //     specks occlude stars behind them like real rocks would.
  RenderDust(CamRight, CamUp);
  // 2. Planets! MUST be rendered first so they write to the depth buffer
  // without being blocked by the sun's additive aura.
  RenderPlanets(FCameraPos, CamRight, CamUp);
  // 3. Comets AND their Particles
  RenderCometParticles(CamRight, CamUp);
  RenderComets;
  // 4. Suns AND their Corona Particles!
  // MUST be rendered LAST so the sun and its aura correctly overlap
  // the planets that are behind them!
  RenderSuns;
  // Optional: Render sun particles again here if you want them on top
  // RenderCometParticles(CamRight, CamUp);
  // Restore normal far plane
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
  if FIsLanded or (TargetIndex < 0) or (TargetIndex > High(FPlanets)) then
    Exit;
  TargetPos := FPlanets[TargetIndex].Position;
  Shift := Vector3Subtract(Vector3Create(0, 0, 0), TargetPos);
  FOriginOffset := Vector3Add(FOriginOffset, Shift);
  for i := 0 to High(FPlanets) do
    FPlanets[i].Position := Vector3Add(FPlanets[i].Position, Shift);
  for i := 0 to High(FSuns) do
    FSuns[i].Position := Vector3Add(FSuns[i].Position, Shift);
  for i := 0 to High(FNebulae) do
    FNebulae[i].Position := Vector3Add(FNebulae[i].Position, Shift);
  for i := 0 to High(FNearStars) do
    FNearStars[i].Position := Vector3Add(FNearStars[i].Position, Shift);
  for i := 0 to High(FComets) do
    FComets[i].Position := Vector3Add(FComets[i].Position, Shift);
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
  if not FIsLanded then
    Exit;
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
      BaseDir := Vector3Create(Sin(phi) * Cos(theta), Sin(phi) * Sin(theta), Cos(phi));
      StarsInCluster := 10 + Trunc(NextRand * 30);
      for j := 0 to StarsInCluster - 1 do
      begin
        if i >= DISTANT_STAR_COUNT then
          Break;
        St := @FDistantStars[i];
        // Scatter around base direction
        var Scatter: Single := 0.05 + NextRand * 0.15; // Tight cluster
        var Offset: TVector3 := Vector3Create((NextRand - 0.5), (NextRand - 0.5), (NextRand - 0.5));
        St^.Dir := Vector3Normalize(Vector3Add(BaseDir, Vector3Scale(Offset, Scatter)));
        // Cluster stars: Randomly pick from all 6 colors (0-5)
        St^.ColorTint := Trunc(NextRand * 6);
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
      St^.Dir := Vector3Create(Sin(phi) * Cos(theta), Sin(phi) * Sin(theta), Cos(phi));
      // Halo stars: Also randomly pick from all 7 colors (0-6)
      St^.ColorTint := Trunc(NextRand * 7);
      St^.Size := 5.0 + NextRand * NextRand * 15.0;
      St^.Brightness := 0.3 + NextRand * 0.4;
      St^.TwinklePhase := NextRand * 2.0 * PI;
      St^.TwinkleSpeed := 0.5 + NextRand * 2.5;
      Inc(i);
    end;
  end;
end;

end.

