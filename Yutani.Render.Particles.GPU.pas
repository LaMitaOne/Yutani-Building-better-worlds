{*******************************************************************************
  Yutani.Render.Particles.GPU v0.3
********************************************************************************
  Slim, modular GPU compute-shader particle engine.

  ARCHITECTURE
  ============
  - 5 per-particle SSBOs (positions, velocities, colors, meta, targets)
  - 1 emitter SSBO (binding 6) with modular TEmitterData records (11 vec4 each)
  - Optional impacts ring buffer (binding 7) for rain/puddle system
  - Optional collider SSBO (binding 8) for physics bridge
  - Compute shader applies modular forces (gravity, drag, curl noise, vortex,
    radial, floor) and over-lifetime curves (color, size, alpha). NO more
    hardcoded etype if/else chains.
  - Vertex shader renders camera-facing quads (6 verts, UVs 0..1) with
    optional motion-trail stretch.
  - Fragment shader supports optional 4x4 sprite atlas or procedural radial
    gradient fallback.

  SSBO LAYOUT (16-byte aligned vec4)
  =================================
  binding 0  positions    vec4(pos.xyz, alive)        alive: 1.0 = alive, 0.0 = dead
  binding 1  velocities   vec4(vel.xyz, age)          age in seconds
  binding 2  colors       vec4(r, g, b, a)
  binding 3  meta         vec4(size, emitterID, maxLife, spawnDelay)
  binding 4  targets      vec4(targetPos.xyz, stateFlag)  materialize/demat
  binding 5  (reserved, was startPositions in v2.0 - removed)
  binding 6  emitterData  vec4[] (11 vec4 per emitter, max 64 emitters)
  binding 7  impacts      vec4 ring buffer (x, y, z, timeOfImpact)
  binding 8  colliders    vec4 AABB pairs (min+restitution, max+reserved)

  EMITTER DATA LAYOUT (11 vec4 = 176 bytes per emitter)
  ====================================================
  [0]  origin.xyz,            modeFlags (int packed: lifeMode, spawnShape,
                                              blendMode, useColorOverride,
                                              isMaterialize, isDematerialize,
                                              textureIndex)
  [1]  spawnDir.xyz,          spawnRadius (sphere) or coneAngle (cone)
  [2]  regionMin.xyz,         minSpeed
  [3]  regionMax.xyz,         maxSpeed
  [4]  minLife, maxLife,      startSize, endSize
  [5]  startColor (vec4 rgba)
  [6]  endColor   (vec4 rgba)
  [7]  gravity.xyz,           drag
  [8]  curlStrength, curlFreq, vortexStrength, radialForce
  [9]  glow, trailStrength,   spread, floorY
  [10] bounce, textureIndex,   reserved, reserved

  Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}

unit Yutani.Render.Particles.GPU;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  Winapi.Windows,
  Raylib, RayMath, rlgl,
  Yutani.Render.ParticlePhysics;

type
  { Spawn shape determines where new particles appear and how their initial
    velocity is computed. }
  TYutaniSpawnShape = (ssBox = 0, ssSphere = 1, ssCone = 2);

  { Emitter lifecycle modes.
    lmContinuous       - respawn particles forever (fire, smoke, rain)
    lmBurst            - emit all particles once and let them play out
    lmOneShotAutoRemove - emit once; when all particles have died the
                          emitter is removed and OnEmitterExpired fires. }
  TYutaniLifeMode = (lmContinuous = 0, lmBurst = 1, lmOneShotAutoRemove = 2);

  { Blend mode for this emitter's particles. The engine uses one global
    blend mode at a time; the host switches it via SetBlendMode before
    rendering groups of emitters that share a blend mode. }
  TYutaniBlendMode = (bmAlpha = 0, bmAdditive = 1);

  { Modular emitter data. This is the host-side mirror of the 11 vec4
    records uploaded to the emitter SSBO (binding 6). }
  TYutaniEmitterData = record
    SpawnShape:        TYutaniSpawnShape;
    Origin:            TVector3;    // Emitter origin (sphere/cone center)
    SpawnDir:          TVector3;    // Cone direction or vortex axis
    SpawnRadius:       Single;     // Sphere radius or cone half-angle (rad)
    RegionMin:         TVector3;   // Box spawn region min
    RegionMax:         TVector3;   // Box spawn region max
    MinSpeed:          Single;
    MaxSpeed:          Single;
    Spread:            Single;     // Cone lateral spread multiplier
    MinLife:           Single;     // Seconds
    MaxLife:           Single;
    StartSize:         Single;
    EndSize:           Single;
    StartColor:        TColorB;
    EndColor:          TColorB;
    UseColorOverride:  Boolean;    // Lerp start -> end over lifetime
    Glow:              Single;     // Emissive multiplier (0 = off, 1 = +100%)
    TrailStrength:     Single;     // Motion-trail stretch in vertex shader
    Gravity:           TVector3;   // Per-emitter gravity (added to global)
    Drag:              Single;     // vel *= max(0, 1 - drag*dt)
    CurlNoiseStrength: Single;     // Turbulence amplitude
    CurlNoiseFreq:     Single;     // Turbulence frequency
    VortexStrength:    Single;     // Rotation around SpawnDir axis
    RadialForce:       Single;     // +pull / -push toward Origin
    FloorY:            Single;     // Floor height (-1000 = no floor)
    Bounce:            Single;     // 0 = kill on floor, 0..1 = bounce
    LifeMode:          TYutaniLifeMode;
    BlendMode:         TYutaniBlendMode;
    TextureIndex:      Integer;    // 0..15 sprite atlas cell, -1 = procedural
    IsMaterialize:     Boolean;    // Special: lerp to target then freeze
    IsDematerialize:   Boolean;    // Special: sink to floorY then die
    ParticleCount:     Integer;    // Slots reserved for this emitter
    Active:            Boolean;    // Soft-toggle without releasing slots
    Name:              string[48];
  end;
  PYutaniEmitterData = ^TYutaniEmitterData;

  { Solid cube rendered in place of (or before) the particle swarm.
    Materialize: created once all Mat-particles have arrived at their target.
    Dematerialize: created at the moment the Demat emitter is started, so the
    cube is visible while the swarm fills its voxel grid; the cube is removed
    once the last Demat-particle has sunk below the floor. }
  TSolidCube = record
    Active:    Boolean;
    Position:  TVector3;   // center of the cube
    Size:      Single;     // edge length (0.9 for the default 10x10x10 voxel grid)
    Color:     TColorB;
    FromMat:   Boolean;    // True = created by Materialize (keep until Demat); False = created by Demat (remove when its swarm is gone)
  end;

  { Event fired when a lmOneShotAutoRemove emitter has all particles dead.
    The host can use this to spawn follow-up emitters (sub-emitters). }
  TEmitterExpiredEvent = procedure(Sender: TObject; EmitterID: Integer;
    const Emitter: TYutaniEmitterData) of object;

  TYutaniParticleEngine = class
  private
    FLock: TCriticalSection;
    FComputeProgram:      Cardinal;
    FRenderProgram:       Cardinal;
    FSSBO_Positions:      Cardinal;
    FSSBO_Velocities:     Cardinal;
    FSSBO_Colors:         Cardinal;
    FSSBO_Meta:           Cardinal;
    FSSBO_Targets:        Cardinal;
    FSSBO_EmitterData:    Cardinal;
    FSSBO_Impacts:        Cardinal;
    FSSBO_Colliders:      Cardinal;
    FBillboardVAO:        Cardinal;
    FBillboardVBO:        Cardinal;
    FAtlasTexID:          Cardinal;   // 0 = procedural fallback
    FAtlasEnabled:        Integer;    // 0 = procedural, 1 = atlas
    FNumParticles:        Integer;
    FParticleScale:       Single;
    FTimeScale:           Single;
    FTime:                Single;
    FInstancesX1000:      Single;
    FBlendMode:           TYutaniBlendMode;
    FPushPos:             TVector3;
    FPushRadius:          Single;
    FPushStrength:        Single;
    FPushActive:          Boolean;
    FGPUInitialized:      Boolean;
    FGlobalWind:          TVector3;
    FGlobalGravity:       TVector3;
    FHDRMultiplier:       Single;

    { Emitter registry }
    FEmitters:            array of TYutaniEmitterData;
    FSpawnTimes:          array of Single;  // CPU-only: when each emitter was created
    FNumEmitters:         Integer;
    FEmittersDirty:       Boolean;

    { CPU-side particle mirror used for initial spawn on AddEmitter }
    FCPU_Positions:       array of TVector4;
    FCPU_Velocities:      array of TVector4;
    FCPU_Colors:          array of TVector4;
    FCPU_Meta:            array of TVector4;
    FCPU_Targets:         array of TVector4;
    FCPU_Dirty:           Boolean;          // legacy flag, kept for compatibility
    { Pending spawn slots: list of particle indices that were spawned or
      modified by AddEmitter/RemoveEmitter since the last Update. The engine
      thread (which owns the GL context) syncs ONLY these slots to the GPU
      in the next Update, instead of the entire particle array. This avoids
      overwriting compute-shader results for already-running particles AND
      avoids making OpenGL calls from the VCL thread (which doesn't own
      the GL context on Windows - silent failure). }
    FPendingSpawnSlots:   array of Integer;
    FPendingSpawnCount:   Integer;
    { Pending META-only slots: indices whose ONLY changed attribute is the
      meta vec4 (e.g. emitterID renumber after CompactEmitters / RemoveEmitter).
      We sync ONLY the Meta SSBO for these, NOT positions/velocities/colors,
      because the CPU mirror has STALE positions for running particles (the
      compute shader updates only the GPU, never the CPU). A full sync would
      push the CPU's old spawn-position back to the GPU and the particle would
      visibly jump back to its birthplace and "start over". By syncing only the
      Meta SSBO, the renumbered emitterID reaches the GPU without touching the
      live position/velocity that the compute shader has been advancing. }
    FPendingMetaSlots:    array of Integer;
    FPendingMetaCount:    Integer;
    FFullResyncNeeded:    Boolean;          // set by ClearEmitters (kills all -> safe to full-sync)

    { Compute shader uniform locations }
    FCompLoc_Time, FCompLoc_TimeScale, FCompLoc_DeltaTime,
    FCompLoc_ParticleCount, FCompLoc_PushPos, FCompLoc_PushRadius,
    FCompLoc_PushStrength, FCompLoc_PushActive, FCompLoc_NumEmitters,
    FCompLoc_GlobalWind, FCompLoc_GlobalGravity, FCompLoc_HDRMultiplier,
    FCompLoc_ImpactWriteIdx, FCompLoc_ImpactMax,
    FCompLoc_PhysicsSampleRate, FCompLoc_PhysicsColliderCount: Integer;
    FImpactWriteIdx:      Integer;
    FImpactMax:           Integer;
    FLastImpactBuffer:    array of TVector4;
    FPhysicsBridge:       IParticlePhysicsBridge;
    FPhysicsSampleRate:   Integer;
    FPhysicsMaxColliders:  Integer;
    FCurrentColliderCount: Integer;
    FOnEmitterExpired:    TEmitterExpiredEvent;

    { Solid-cube overlay (replaces the frozen Mat swarm / precedes the Demat
      sink). Up to a few active cubes can coexist; the array grows as needed. }
    FSolidCubes:           array of TSolidCube;
    FReadbackTargets:     array of TVector4;  // scratch buffer for glGetBufferSubData
    FReadbackAccum:       Single;  // accumulates dt until next Mat-readback (every 50 ms)
    FMatArrivedCheck:     Boolean;  // true when at least one Mat emitter is alive and we must readback targets this frame

    { Render shader uniform locations }
    FRendLoc_ProjMatrix, FRendLoc_ViewMatrix, FRendLoc_ParticleScale,
    FRendLoc_AtlasEnabled: Integer;
    FRendLoc_AtlasSampler: Integer;

    procedure InitGPUResources;
    procedure FreeGPUResources;
    procedure BuildBillboardVAO;
    procedure SyncEmittersToGPU;
    procedure SyncCPUParticlesToGPU;
    procedure SyncPendingSlots;   // partial sync - only FPendingSpawnSlots
    procedure SyncPendingMetaSlots;  // Meta-SSBO-only sync for renumbered slots
    procedure SyncCollidersToGPU;
    procedure DispatchCompute(const dt: Single);
    procedure DrawInstances(const NumInstances: Integer; const ACamera: TCamera3D);
    procedure CompactEmitters;
    function  GetActiveInstanceCount: Integer;
    function  GetEmitterProp(Idx: Integer): TYutaniEmitterData;
    function  FindFreeParticleSlots(Count: Integer; Slots: PIntegerArray): Integer;
    procedure AssignParticlesToEmitter(EmitterID: Integer; const AData: TYutaniEmitterData);
    procedure SpawnParticleCPU(Idx: Integer; EmitterID: Integer; const AData: TYutaniEmitterData);
    function  PackModeFlags(const AData: TYutaniEmitterData): Integer;
    { Solid-cube helpers. PushSolidCube adds a new active cube (no-op if one
      already exists at the same position+size). FindSolidCubeFor returns
      True when a cube with the given center+size already exists. }
    procedure PushSolidCube(const APos: TVector3; ASize: Single; AColor: TColorB;
                            AFromMat: Boolean);
    function  FindSolidCubeFor(const APos: TVector3; ASize: Single): Boolean;
    { RemoveSolidCube drops the first cube at APos/ASize whose FromMat matches
      AFromMatFlag. Pass False to drop Demat-owned cubes (the cube that the
      sink just finished dismantling), True to drop Mat-owned cubes. }
    procedure RemoveSolidCube(const APos: TVector3; ASize: Single;
                              AFromMatFlag: Boolean);
    { MarkSolidCubeForDemat finds any cube at APos/ASize and flips its
      FromMat flag to False so the Demat Auto-Expire will remove it. This is
      used when a Demat emitter starts dismantling a cube that Materialize
      previously built (FromMat was True). }
    procedure MarkSolidCubeForDemat(const APos: TVector3; ASize: Single);
    procedure RenderSolidCubes;
  public
    constructor Create(ANumParticles: Integer = 102400);
    destructor  Destroy; override;
    procedure Initialise;
    procedure Update(const ADeltaTime: Single);
    procedure Render(const ACamera: TCamera3D);
    procedure Restart;
    procedure Reset;
    procedure SetPush(const APos: TVector3; ARadius, AStrength: Single);
    procedure ClearPush;
    { Global forces }
    procedure SetGlobalWind(const AWind: TVector3);
    procedure SetGlobalGravity(const AGravity: TVector3);
    procedure SetHDRMultiplier(AMultiplier: Single);
    { Blend mode for the next Render call }
    procedure SetBlendMode(AMode: TYutaniBlendMode);
    { Optional sprite atlas (4x4 grid). Pass a Texture2D whose .id is the
      OpenGL texture name. Pass 0/nil to disable and use procedural radial
      gradient. }
    procedure SetSpriteAtlas(const ATexture: TTexture2D); overload;
    procedure SetSpriteAtlas(ATextureID: Cardinal); overload;
    procedure ClearSpriteAtlas;
    { Physics bridge }
    procedure SetPhysicsBridge(const ABridge: IParticlePhysicsBridge);
    procedure SetPhysicsSampleRate(ARate: Integer);
    { Impact ring buffer (CPU readback for puddle system) }
    function  GetImpactCount: Integer;
    function  GetImpactBuffer: Pointer;
    procedure AdvanceImpactWriteIdx;

    { === Emitter API === }
    function  AddEmitter(const AData: TYutaniEmitterData): Integer;
    function  RemoveEmitter(EmitterID: Integer): Boolean;
    procedure ClearEmitters;
    function  GetEmitterCount: Integer;
    function  GetEmitter(EmitterID: Integer; out AEmitter: TYutaniEmitterData): Boolean;
    function  SetEmitterActive(EmitterID: Integer; AActive: Boolean): Boolean;
    function  SetEmitterOrigin(EmitterID: Integer; const AOrigin: TVector3): Boolean;
    function  SetEmitterRegion(EmitterID: Integer;
      const ARegionMin, ARegionMax: TVector3): Boolean;
    function  SetEmitterStartColor(EmitterID: Integer; const AColor: TColorB): Boolean;
    function  SetEmitterEndColor(EmitterID: Integer; const AColor: TColorB): Boolean;
    function  SetEmitterGlow(EmitterID: Integer; AGlow: Single): Boolean;
    function  SetEmitterTrailStrength(EmitterID: Integer; AStrength: Single): Boolean;
    function  SetEmitterUseColorOverride(EmitterID: Integer; AUse: Boolean): Boolean;
    function  SetEmitterLifeMode(EmitterID: Integer; AMode: TYutaniLifeMode): Boolean;
    function  SetEmitterFromTo(EmitterID: Integer;
      const AFromPos, AToPos: TVector3): Boolean;

    { === Materialize / Dematerialize presets ===
      These create emitters with the IsMaterialize / IsDematerialize flags
      set, spawning a voxel cube that flies to a target position (or sinks
      to the floor). They use the same modular emitter struct - no special
      etype branch is needed in the compute shader. }
    procedure EmitMaterializeCube(const TargetPos: TVector3;
      const Color: TColorB; VoxelSize: Single = 0.1); overload;
    procedure EmitMaterializeCube(const TargetPos: TVector3;
      VoxelSize: Single = 0.1); overload;
    procedure EmitDematerializeCube(const SourcePos: TVector3;
      const Color: TColorB; VoxelSize: Single = 0.1); overload;
    procedure EmitDematerializeCube(const SourcePos: TVector3;
      VoxelSize: Single = 0.1); overload;
    procedure EmitMaterializeMesh(const TargetPos: TVector3; const Mesh: TMesh;
      const Color: TColorB); overload;
    procedure EmitMaterializeMesh(const TargetPos: TVector3;
      const Mesh: TMesh); overload;
    procedure EmitDematerializeMesh(const SourcePos: TVector3; const Mesh: TMesh;
      const Color: TColorB); overload;
    procedure EmitDematerializeMesh(const SourcePos: TVector3;
      const Mesh: TMesh); overload;

    property NumParticles:        Integer read FNumParticles;
    property ParticleScale:       Single  read FParticleScale  write FParticleScale;
    property TimeScale:           Single  read FTimeScale      write FTimeScale;
    property Time:                Single  read FTime           write FTime;
    property InstancesX1000:      Single  read FInstancesX1000 write FInstancesX1000;
    property BlendMode:           TYutaniBlendMode read FBlendMode write SetBlendMode;
    property PushActive:          Boolean read FPushActive;
    property Initialised:         Boolean read FGPUInitialized;
    property GlobalWind:          TVector3 read FGlobalWind write SetGlobalWind;
    property GlobalGravity:       TVector3 read FGlobalGravity write SetGlobalGravity;
    property HDRMultiplier:       Single read FHDRMultiplier write SetHDRMultiplier;
    property PhysicsSampleRate:   Integer read FPhysicsSampleRate write SetPhysicsSampleRate;
    property PhysicsBridge:       IParticlePhysicsBridge read FPhysicsBridge write SetPhysicsBridge;
    property ActiveInstanceCount: Integer read GetActiveInstanceCount;
    property ParticleCount:       Integer read GetActiveInstanceCount;
    property NumEmitters:         Integer read FNumEmitters;
    property EmitterByID[Idx: Integer]: TYutaniEmitterData read GetEmitterProp;
    property OnEmitterExpired:    TEmitterExpiredEvent read FOnEmitterExpired write FOnEmitterExpired;
  end;

const
  { Maximum emitters supported by the engine. Each emitter uses 11 vec4
    records (176 bytes) in the emitter SSBO; 64 emitters = 11.2 KB upload
    per frame, negligible cost. }
  YUTANI_MAX_EMITTERS = 64;
  YUTANI_EMITTER_VEC4_COUNT = 11;
  YUTANI_PARTICLE_LOCAL_SIZE = 1024;
  YUTANI_NO_FLOOR = -1000.0;

{ Helper to build a TYutaniEmitterData with neutral defaults so callers
  can override only the fields they care about. }
function MakeEmitterData: TYutaniEmitterData;

implementation

{ ========================================================================== }
{ OpenGL 4.3+ dynamic function loading                                       }
{ ========================================================================== }

const
  GL_COMPUTE_SHADER              = $91B9;
  GL_VERTEX_SHADER               = $8B31;
  GL_FRAGMENT_SHADER             = $8B30;
  GL_COMPILE_STATUS              = $8B81;
  GL_LINK_STATUS                 = $8B82;
  GL_INFO_LOG_LENGTH             = $8B84;
  GL_SHADER_STORAGE_BARRIER_BIT  = $2000;
  GL_FALSE                       = 0;
  GL_TRUE                        = 1;
  GL_CULL_FACE                   = $0B44;
  GL_DEPTH_TEST                  = $0B71;
  GL_BLEND                       = $0BE2;
  GL_SRC_ALPHA                   = $0302;
  GL_ONE_MINUS_SRC_ALPHA         = $0303;
  GL_ONE                         = $0001;
  GL_ARRAY_BUFFER                = $8892;
  GL_ELEMENT_ARRAY_BUFFER        = $8893;
  GL_SHADER_STORAGE_BUFFER       = $90D2;
  GL_STATIC_DRAW                 = $88E4;
  GL_DYNAMIC_COPY                = $88EA;
  GL_DYNAMIC_READ                = $88E9;
  GL_DYNAMIC_DRAW                = $88E8;
  GL_TRIANGLES                   = $0004;
  GL_NO_ERROR                    = 0;
  GL_FLOAT                       = $1406;
  GL_TEXTURE0                    = $84C0;
  GL_TEXTURE_2D                  = $0DE1;

type
  PFNGLCREATESHADERPROC        = function(shaderType: Cardinal): Cardinal; stdcall;
  PFNGLSHADERSOURCEPROC        = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;
  PFNGLCOMPILESHADERPROC       = procedure(shader: Cardinal); stdcall;
  PFNGLDELETESHADERPROC        = procedure(shader: Cardinal); stdcall;
  PFNGLGETSHADERIVPROC         = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETSHADERINFOLOGPROC    = procedure(shader: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLCREATEPROGRAMPROC       = function: Cardinal; stdcall;
  PFNGLATTACHSHADERPROC        = procedure(programObj: Cardinal; shader: Cardinal); stdcall;
  PFNGLLINKPROGRAMPROC         = procedure(programObj: Cardinal); stdcall;
  PFNGLDELETEPROGRAMPROC       = procedure(programObj: Cardinal); stdcall;
  PFNGLGETPROGRAMIVPROC        = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETPROGRAMINFOLOGPROC   = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLUSEPROGRAMPROC          = procedure(programObj: Cardinal); stdcall;
  PFNGLGETUNIFORMLOCATIONPROC  = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;
  PFNGLUNIFORM1FPROC           = procedure(location: Integer; v: Single); stdcall;
  PFNGLUNIFORM1IPROC           = procedure(location: Integer; v: Integer); stdcall;
  PFNGLUNIFORM3FPROC           = procedure(location: Integer; x: Single; y: Single; z: Single); stdcall;
  PFNGLUNIFORM4FVPROC          = procedure(location: Integer; count: Integer; v: PSingle); stdcall;
  PFNGLUNIFORMMATRIX4FVPROC    = procedure(location: Integer; count: Integer; transpose: Byte; value: PSingle); stdcall;
  PFNGLDISPATCHCOMPUTEPROC     = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;
  PFNGLMEMORYBARRIERPROC       = procedure(barriers: Cardinal); stdcall;
  PFNGLGENVERTEXARRAYSPROC    = procedure(n: Integer; arrays: PCardinal); stdcall;
  PFNGLBINDVERTEXARRAYPROC    = procedure(array_: Cardinal); stdcall;
  PFNGLDELETEVERTEXARRAYSPROC = procedure(n: Integer; arrays: PCardinal); stdcall;
  PFNGLGENBUFFERSPROC         = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLDELETEBUFFERSPROC      = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLBINDBUFFERPROC         = procedure(target: Cardinal; buffer: Cardinal); stdcall;
  PFNGLBUFFERDATAPROC         = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;
  PFNGLBUFFERSUBDATAPROC      = procedure(target: Cardinal; offset: NativeInt; size: NativeInt; data: Pointer); stdcall;
  PFNGLGETBUFFERSUBDATAPROC   = procedure(target: Cardinal; offset: NativeInt; size: NativeInt; data: Pointer); stdcall;
  PFNGLBINDBUFFERBASEPROC     = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;
  PFNGLVERTEXATTRIBPOINTERPROC = procedure(index: Cardinal; size: Integer; type_: Cardinal; normalized: Byte; stride: Integer; pointer: Pointer); stdcall;
  PFNGLENABLEVERTEXATTRIBARRAYPROC = procedure(index: Cardinal); stdcall;
  PFNGLDRAWARRAYSINSTANCEDPROC = procedure(mode: Cardinal; first: Integer; count: Integer; instancecount: Integer); stdcall;
  PFNGLGETERRORPROC           = function: Cardinal; stdcall;
  PFNGLACTIVETEXTUREPROC      = procedure(texture: Cardinal); stdcall;

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';
procedure OutputDebugStringA(lpOutputString: PAnsiChar); stdcall; external 'kernel32.dll';
{ rlgl functions used to keep Raylib's internal state cache in sync with
  the raw OpenGL calls we make for the particle pass. }
function  rlGetShaderIdDefault: Cardinal; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlGetShaderIdDefault';
function  rlGetTextureIdDefault: Cardinal; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlGetTextureIdDefault';
procedure rlEnableShader(id: Cardinal); cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlEnableShader';
procedure rlActiveTextureSlot(slot: Integer); cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlActiveTextureSlot';
procedure rlSetTexture(id: Cardinal); cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlSetTexture';
procedure rlDrawRenderBatchActive; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlDrawRenderBatchActive';
function  rlGetMatrixModelview: TMatrix; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlGetMatrixModelview';
function  rlGetMatrixProjection: TMatrix; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlGetMatrixProjection';
procedure glDisable(cap: Cardinal); stdcall; external 'opengl32.dll';
procedure glEnable(cap: Cardinal); stdcall; external 'opengl32.dll';
procedure glDepthMask(flag: Byte); stdcall; external 'opengl32.dll';
procedure glBlendFunc(sfactor, dfactor: Cardinal); stdcall; external 'opengl32.dll';
procedure glBindTexture(target: Cardinal; texture: Cardinal); stdcall; external 'opengl32.dll';

var
  glGenVertexArrays: PFNGLGENVERTEXARRAYSPROC;
  glBindVertexArray: PFNGLBINDVERTEXARRAYPROC;
  glDeleteVertexArrays: PFNGLDELETEVERTEXARRAYSPROC;
  glGenBuffers: PFNGLGENBUFFERSPROC;
  glDeleteBuffers: PFNGLDELETEBUFFERSPROC;
  glBindBuffer: PFNGLBINDBUFFERPROC;
  glBufferData: PFNGLBUFFERDATAPROC;
  glBufferSubData: PFNGLBUFFERSUBDATAPROC;
  glGetBufferSubData: PFNGLGETBUFFERSUBDATAPROC;
  glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
  glVertexAttribPointer: PFNGLVERTEXATTRIBPOINTERPROC;
  glEnableVertexAttribArray: PFNGLENABLEVERTEXATTRIBARRAYPROC;
  glDrawArraysInstanced: PFNGLDRAWARRAYSINSTANCEDPROC;
  glGetError: PFNGLGETERRORPROC;
  glActiveTexture: PFNGLACTIVETEXTUREPROC;
  glCreateShader: PFNGLCREATESHADERPROC;
  glShaderSource: PFNGLSHADERSOURCEPROC;
  glCompileShader: PFNGLCOMPILESHADERPROC;
  glDeleteShader: PFNGLDELETESHADERPROC;
  glGetShaderiv: PFNGLGETSHADERIVPROC;
  glGetShaderInfoLog: PFNGLGETSHADERINFOLOGPROC;
  glCreateProgram: PFNGLCREATEPROGRAMPROC;
  glAttachShader: PFNGLATTACHSHADERPROC;
  glLinkProgram: PFNGLLINKPROGRAMPROC;
  glDeleteProgram: PFNGLDELETEPROGRAMPROC;
  glGetProgramiv: PFNGLGETPROGRAMIVPROC;
  glGetProgramInfoLog: PFNGLGETPROGRAMINFOLOGPROC;
  glUseProgram: PFNGLUSEPROGRAMPROC;
  glGetUniformLocation: PFNGLGETUNIFORMLOCATIONPROC;
  glUniform1f: PFNGLUNIFORM1FPROC;
  glUniform1i: PFNGLUNIFORM1IPROC;
  glUniform3f: PFNGLUNIFORM3FPROC;
  glUniform4fv: PFNGLUNIFORM4FVPROC;
  glUniformMatrix4fv: PFNGLUNIFORMMATRIX4FVPROC;
  glDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
  glMemoryBarrier: PFNGLMEMORYBARRIERPROC;
  GLReady: Boolean = False;

function LoadOpenGL43: Boolean;
  function GetProc(const name: AnsiString): Pointer;
  begin
    Result := wglGetProcAddress(PAnsiChar(name));
    if Result = nil then
      Result := GetProcAddress(GetModuleHandle('opengl32.dll'), PAnsiChar(name));
  end;
begin
  if GLReady then Exit(True);
  glCreateShader := GetProc('glCreateShader');
  glShaderSource := GetProc('glShaderSource');
  glCompileShader := GetProc('glCompileShader');
  glDeleteShader := GetProc('glDeleteShader');
  glGetShaderiv := GetProc('glGetShaderiv');
  glGetShaderInfoLog := GetProc('glGetShaderInfoLog');
  glCreateProgram := GetProc('glCreateProgram');
  glAttachShader := GetProc('glAttachShader');
  glLinkProgram := GetProc('glLinkProgram');
  glDeleteProgram := GetProc('glDeleteProgram');
  glGetProgramiv := GetProc('glGetProgramiv');
  glGetProgramInfoLog := GetProc('glGetProgramInfoLog');
  glUseProgram := GetProc('glUseProgram');
  glGetUniformLocation := GetProc('glGetUniformLocation');
  glUniform1f := GetProc('glUniform1f');
  glUniform1i := GetProc('glUniform1i');
  glUniform3f := GetProc('glUniform3f');
  glUniform4fv := GetProc('glUniform4fv');
  glUniformMatrix4fv := GetProc('glUniformMatrix4fv');
  glDispatchCompute := GetProc('glDispatchCompute');
  glMemoryBarrier := GetProc('glMemoryBarrier');
  glGenVertexArrays := GetProc('glGenVertexArrays');
  glBindVertexArray := GetProc('glBindVertexArray');
  glDeleteVertexArrays := GetProc('glDeleteVertexArrays');
  glGenBuffers := GetProc('glGenBuffers');
  glDeleteBuffers := GetProc('glDeleteBuffers');
  glBindBuffer := GetProc('glBindBuffer');
  glBufferData := GetProc('glBufferData');
  glBufferSubData := GetProc('glBufferSubData');
  glGetBufferSubData := GetProc('glGetBufferSubData');
  glBindBufferBase := GetProc('glBindBufferBase');
  glVertexAttribPointer := GetProc('glVertexAttribPointer');
  glEnableVertexAttribArray := GetProc('glEnableVertexAttribArray');
  glDrawArraysInstanced := GetProc('glDrawArraysInstanced');
  glGetError := GetProc('glGetError');
  glActiveTexture := GetProc('glActiveTexture');
  GLReady := Assigned(glCreateShader) and Assigned(glShaderSource) and
    Assigned(glCompileShader) and Assigned(glDeleteShader) and
    Assigned(glGetShaderiv) and Assigned(glGetShaderInfoLog) and
    Assigned(glCreateProgram) and Assigned(glAttachShader) and
    Assigned(glLinkProgram) and Assigned(glDeleteProgram) and
    Assigned(glGetProgramiv) and Assigned(glGetProgramInfoLog) and
    Assigned(glUseProgram) and Assigned(glGetUniformLocation) and
    Assigned(glUniform1f) and Assigned(glUniform1i) and
    Assigned(glUniform3f) and Assigned(glUniform4fv) and
    Assigned(glUniformMatrix4fv) and Assigned(glDispatchCompute) and
    Assigned(glMemoryBarrier) and Assigned(glGenVertexArrays) and
    Assigned(glBindVertexArray) and Assigned(glDeleteVertexArrays) and
    Assigned(glGenBuffers) and Assigned(glDeleteBuffers) and
    Assigned(glBindBuffer) and Assigned(glBufferData) and
    Assigned(glBufferSubData) and Assigned(glGetBufferSubData) and
    Assigned(glBindBufferBase) and Assigned(glVertexAttribPointer) and
    Assigned(glEnableVertexAttribArray) and Assigned(glDrawArraysInstanced) and
    Assigned(glGetError) and Assigned(glActiveTexture);
  Result := GLReady;
end;

function CompileShaderRaw(const src: AnsiString; shaderType: Cardinal): Cardinal;
var srcPtr: PAnsiChar; srcLen: Integer; success: Integer;
    infoLog: array[0..4095] of AnsiChar; typeName: string;
begin
  Result := 0;
  case shaderType of
    GL_COMPUTE_SHADER: typeName := 'COMPUTE';
    GL_VERTEX_SHADER: typeName := 'VERTEX';
    GL_FRAGMENT_SHADER: typeName := 'FRAGMENT';
    else typeName := 'UNKNOWN';
  end;
  Result := glCreateShader(shaderType);
  if Result = 0 then raise Exception.CreateFmt('glCreateShader(%s) returned 0', [typeName]);
  srcPtr := PAnsiChar(src); srcLen := Length(src);
  glShaderSource(Result, 1, @srcPtr, @srcLen);
  glCompileShader(Result);
  glGetShaderiv(Result, GL_COMPILE_STATUS, @success);
  if success = GL_FALSE then begin
    FillChar(infoLog, SizeOf(infoLog), 0);
    glGetShaderInfoLog(Result, SizeOf(infoLog), nil, infoLog);
    glDeleteShader(Result); Result := 0;
    raise Exception.CreateFmt('Yutani.Render.Particles.GPU: %s shader compile FAILED:'#10#10'%s', [typeName, string(infoLog)]);
  end;
end;

function LinkProgramRaw(const shaderIds: array of Cardinal): Cardinal;
var i: Integer; success: Integer; infoLog: array[0..4095] of AnsiChar;
begin
  Result := glCreateProgram();
  if Result = 0 then raise Exception.Create('glCreateProgram() returned 0');
  for i := Low(shaderIds) to High(shaderIds) do glAttachShader(Result, shaderIds[i]);
  glLinkProgram(Result);
  glGetProgramiv(Result, GL_LINK_STATUS, @success);
  if success = GL_FALSE then begin
    FillChar(infoLog, SizeOf(infoLog), 0);
    glGetProgramInfoLog(Result, SizeOf(infoLog), nil, infoLog);
    glDeleteProgram(Result); Result := 0;
    raise Exception.CreateFmt('Yutani.Render.Particles.GPU: shader program link FAILED:'#10#10'%s', [string(infoLog)]);
  end;
  for i := Low(shaderIds) to High(shaderIds) do glDeleteShader(shaderIds[i]);
end;

{ ========================================================================== }
{ Embedded shader sources                                                   }
{ ========================================================================== }

const
  { Compute shader: modular Niagara-Light particle simulation.
    SSBO layout (see unit header for details).
    Uniforms: see location assignments below. }
  COMPUTE_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 1024) in;'#10 +
    'layout(std430, binding=0) buffer ssbo0 { vec4 positions[]; };'#10 +
    'layout(std430, binding=1) buffer ssbo1 { vec4 velocities[]; };'#10 +
    'layout(std430, binding=2) buffer ssbo2 { vec4 colors[]; };'#10 +
    'layout(std430, binding=3) buffer ssbo3 { vec4 meta[]; };'#10 +
    'layout(std430, binding=4) buffer ssbo4 { vec4 targets[]; };'#10 +
    'layout(std430, binding=6) buffer ssbo6 { vec4 emitterData[]; };'#10 +
    'layout(std430, binding=7) buffer ssbo7 { vec4 impacts[]; };'#10 +
    'layout(std430, binding=8) buffer ssbo8 { vec4 colliders[]; };'#10 +
    'layout(location=0) uniform float time;'#10 +
    'layout(location=1) uniform float timeScale;'#10 +
    'layout(location=2) uniform float deltaTime;'#10 +
    'layout(location=3) uniform int particleCount;'#10 +
    'layout(location=4) uniform vec3 pushPos;'#10 +
    'layout(location=5) uniform float pushRadius;'#10 +
    'layout(location=6) uniform float pushStrength;'#10 +
    'layout(location=7) uniform int pushActive;'#10 +
    'layout(location=8) uniform int numEmitters;'#10 +
    'layout(location=9) uniform vec3 globalWind;'#10 +
    'layout(location=10) uniform vec3 globalGravity;'#10 +
    'layout(location=11) uniform float hdrMultiplier;'#10 +
    'layout(location=12) uniform int impactWriteIdx;'#10 +
    'layout(location=13) uniform int impactMax;'#10 +
    'layout(location=14) uniform int physicsSampleRate;'#10 +
    'layout(location=15) uniform int physicsColliderCount;'#10 +
    'const float PI = 3.14159265359;'#10 +
    'float rand(float n) { return fract(sin(n*12.9898)*43758.5453); }'#10 +
    'vec3 rand3(float n) { return vec3(rand(n), rand(n+1.7), rand(n+3.3)); }'#10 +
    // Curl-noise approximation using sin/cos - cheap and good enough for
    // fire, smoke and magic turbulence. Real curl noise would require a
    // proper gradient of a 3D noise function; this is a Niagara-light
    // approximation that has the same visual character.
    'vec3 curlNoise(vec3 p, float freq, float t) {'#10 +
    '  p *= freq;'#10 +
    '  return vec3('#10 +
    '    sin(p.y + t) * cos(p.z + t*0.7),'#10 +
    '    sin(p.z + t*1.3) * cos(p.x + t*0.9),'#10 +
    '    sin(p.x + t*0.7) * cos(p.y + t*1.1)'#10 +
    '  );'#10 +
    '}'#10 +
    // Emitter struct: 11 vec4 = 176 bytes per emitter. See unit header.
    'struct Emitter {'#10 +
    '  vec4 originMode; vec4 spawnDirRadius; vec4 regionMinMinSpd;'#10 +
    '  vec4 regionMaxMaxSpd; vec4 lifeSize; vec4 colorStart;'#10 +
    '  vec4 colorEnd; vec4 gravityDrag; vec4 forces; vec4 optParams;'#10 +
    '  vec4 bounceTex; };'#10 +
    'Emitter loadEmitter(int id) {'#10 +
    '  Emitter em; int b = id*11;'#10 +
    '  em.originMode       = emitterData[b+0];'#10 +
    '  em.spawnDirRadius   = emitterData[b+1];'#10 +
    '  em.regionMinMinSpd  = emitterData[b+2];'#10 +
    '  em.regionMaxMaxSpd  = emitterData[b+3];'#10 +
    '  em.lifeSize         = emitterData[b+4];'#10 +
    '  em.colorStart       = emitterData[b+5];'#10 +
    '  em.colorEnd         = emitterData[b+6];'#10 +
    '  em.gravityDrag      = emitterData[b+7];'#10 +
    '  em.forces           = emitterData[b+8];'#10 +
    '  em.optParams        = emitterData[b+9];'#10 +
    '  em.bounceTex        = emitterData[b+10];'#10 +
    '  return em; }'#10 +
    // modeFlags bit decoding
    'int getLifeMode(int f)         { return f & 0x3; }'#10 +
    'int getSpawnShape(int f)       { return (f >> 2) & 0x3; }'#10 +
    'int getBlendMode(int f)        { return (f >> 4) & 0x1; }'#10 +
    'bool getUseColorOverride(int f){ return (f & 0x20) != 0; }'#10 +
    'bool getIsMaterialize(int f)   { return (f & 0x40) != 0; }'#10 +
    'bool getIsDematerialize(int f) { return (f & 0x80) != 0; }'#10 +
    // Respawn a particle at the emitter based on its spawn shape.
    'void respawnParticle(int idx, Emitter em, int flags,'#10 +
    '    inout vec3 pos, inout vec3 vel, inout float age,'#10 +
    '    inout vec4 color, inout float psize, inout vec4 posData) {'#10 +
    '  vec3 r = rand3(float(idx) + time*0.13);'#10 +
    '  int shape = getSpawnShape(flags);'#10 +
    '  if (shape == 0) {'#10 +
    '    pos = mix(em.regionMinMinSpd.xyz, em.regionMaxMaxSpd.xyz, r);'#10 +
    '    vel = vec3(0.0);'#10 +
    '  } else if (shape == 1) {'#10 +
    '    vec3 dir = normalize(r - 0.5 + vec3(0.001));'#10 +
    '    pos = em.originMode.xyz + dir * em.spawnDirRadius.w * length(r - 0.5);'#10 +
    '    float speed = em.regionMinMinSpd.w + r.x * (em.regionMaxMaxSpd.w - em.regionMinMinSpd.w);'#10 +
    '    vel = dir * speed;'#10 +
    '  } else {'#10 +
    '    vec3 axis = normalize(em.spawnDirRadius.xyz + vec3(0.001));'#10 +
    '    vec3 right = abs(axis.y) > 0.9 ? vec3(1,0,0) : vec3(0,1,0);'#10 +
    '    right = normalize(cross(axis, right));'#10 +
    '    vec3 up = cross(right, axis);'#10 +
    '    float ang = (r.x - 0.5) * 2.0 * em.spawnDirRadius.w;'#10 +
    '    float spin = r.y * 6.2831;'#10 +
    '    vec3 offset = (right * cos(spin) + up * sin(spin)) * sin(ang) * em.optParams.z;'#10 +
    '    pos = em.originMode.xyz + axis * 0.05 + offset;'#10 +
    '    float speed = em.regionMinMinSpd.w + r.z * (em.regionMaxMaxSpd.w - em.regionMinMinSpd.w);'#10 +
    '    vel = (axis + offset) * speed;'#10 +
    '  }'#10 +
    '  age = 0.0;'#10 +
    '  color = em.colorStart;'#10 +
    '  psize = em.lifeSize.z;'#10 +
    '  posData.w = 1.0;'#10 +
    '}'#10 +
    'void main() {'#10 +
    '  uint index = gl_GlobalInvocationID.x;'#10 +
    '  if (index >= uint(particleCount)) return;'#10 +
    '  int idx = int(index);'#10 +
    '  vec4 posData   = positions[index];'#10 +
    '  vec4 velData   = velocities[index];'#10 +
    '  vec4 colorData = colors[index];'#10 +
    '  vec4 metaData  = meta[index];'#10 +
    '  vec4 targetData= targets[index];'#10 +
    '  if (posData.w < 0.5) return; // dead/unassigned slot'#10 +
    '  vec3 pos    = posData.xyz;'#10 +
    '  vec3 vel    = velData.xyz;'#10 +
    '  float age   = velData.w;'#10 +
    '  vec4 color  = colorData;'#10 +
    '  float psize = metaData.x;'#10 +
    '  int emitterID = int(metaData.y);'#10 +
    '  float maxLife = metaData.z;'#10 +
    '  float spawnDelay = metaData.w;'#10 +
    '  vec3 target = targetData.xyz;'#10 +
    '  float stateFlag = targetData.w;'#10 +
    // CRITICAL: if emitterID is out of range, this particle has been orphaned
    // (its emitter was removed/expired but the GPU slot was not yet synced
    // to "dead"). Just returning leaves the particle frozen in place and
    // visible forever. Instead we explicitly kill it by writing posData.w=0
    // to the SSBO so subsequent frames skip it AND so the next sync sees
    // the dead state. This is the safety net behind RemoveEmitter/Auto-Expire:
    // even if a sync is delayed by a frame, the compute shader self-heals.
    '  if (emitterID < 0 || emitterID >= numEmitters) {'#10 +
    '    posData.w = 0.0;'#10 +
    '    positions[index] = posData;'#10 +
    '    color.a = 0.0;'#10 +
    '    colors[index] = color;'#10 +
    '    return;'#10 +
    '  }'#10 +
    '  Emitter em = loadEmitter(emitterID);'#10 +
    '  int flags = int(em.originMode.w);'#10 +
    '  int lifeMode = getLifeMode(flags);'#10 +
    '  bool isMaterialize = getIsMaterialize(flags);'#10 +
    '  bool isDematerialize = getIsDematerialize(flags);'#10 +
    '  bool useColorOverride = getUseColorOverride(flags);'#10 +
    // Spawn delay (used by materialize/demat layer timing).
    // For Mat: particle is at its target voxel but INVISIBLE while its layer's
    // spawnDelay counts down - this is the "schicht fuer schicht aufbauen"
    // 3D-printer effect. Each layer snaps into existence (alpha=1) the moment
    // its delay expires. For Demat: particle is at its target voxel and fully
    // visible while spawnDelay counts down - this is the "fill the cube" phase
    // before the sink begins.
    '  if (spawnDelay > 0.0) {'#10 +
    '    spawnDelay -= deltaTime;'#10 +
    '    metaData.w = spawnDelay;'#10 +
    '    pos = target; vel = vec3(0.0);'#10 +
    '    color = em.colorStart;'#10 +
    '    if (isMaterialize) color.a = 0.0; else color.a = 1.0;'#10 +
    '    if (spawnDelay > 0.0) {'#10 +
    '      colors[index] = color;'#10 +
    '      positions[index] = vec4(pos, posData.w);'#10 +
    '      meta[index] = metaData;'#10 +
    '      return;'#10 +
    '    }'#10 +
    // first frame after delay expiry: snap Mat to arrived + visible so the
    // readback sees target.w = 1.0 AND the layer becomes visible at once.
    '    if (isMaterialize) { stateFlag = 1.0; targetData.w = 1.0; color.a = 1.0; }'#10 +
    '  }'#10 +
    '  age += deltaTime;'#10 +
    // === MATERIALIZE / DEMATERIALIZE special modes (override modular forces) ===
    // Materialize: particle is now visible at its voxel after its layer's
    // spawnDelay expired. Stay frozen, fully opaque. No flying.
    '  if (isMaterialize) {'#10 +
    '    pos = target; vel = vec3(0.0);'#10 +
    '    stateFlag = 1.0; targetData.w = 1.0;'#10 +
    '    color = em.colorStart; color.a = 1.0;'#10 +
    '  } else if (isDematerialize) {'#10 +
    '    // SINK phase: descend to floor. Top layer sinks first (its hold'#10 +
    '    // timer in metaData.w was set to 0, lower layers got progressively'#10 +
    '    // larger hold timers so they sink later - exactly the reverse of'#10 +
    '    // Materialize. The hold timer is consumed by the spawnDelay block'#10 +
    // above, so when we reach here the particle's hold is over.
    '    if (pos.y > em.optParams.w + 0.01) {'#10 +
    '      vel.y = -4.0; pos += vel * deltaTime * timeScale;'#10 +
    '      if (pos.y < em.optParams.w) { pos.y = em.optParams.w; age = maxLife + 1.0; posData.w = 0.0; }'#10 +
    '    } else { age = maxLife + 1.0; posData.w = 0.0; }'#10 +
    '    color = em.colorStart; color.a = 1.0;'#10 +
    '  } else {'#10 +
    // === MODULAR FORCE SYSTEM (Niagara-Light) ===
    '    vec3 force = vec3(0.0);'#10 +
    // 1. Per-emitter gravity (added to global gravity later)
    '    force += em.gravityDrag.xyz;'#10 +
    // 2. Curl noise turbulence
    '    if (em.forces.x > 0.001) {'#10 +
    '      force += curlNoise(pos, em.forces.y, time) * em.forces.x;'#10 +
    '    }'#10 +
    // 3. Vortex + radial force
    '    if (abs(em.forces.z) > 0.001 || abs(em.forces.w) > 0.001) {'#10 +
    '      vec3 toOrigin = em.originMode.xyz - pos;'#10 +
    '      vec3 axis = em.spawnDirRadius.xyz;'#10 +
    '      if (length(axis) < 0.001) axis = vec3(0.0, 1.0, 0.0);'#10 +
    '      axis = normalize(axis);'#10 +
    '      vec3 tangent = cross(axis, toOrigin);'#10 +
    '      if (length(tangent) > 0.001) tangent = normalize(tangent);'#10 +
    '      force += tangent * em.forces.z;'#10 +
    '      force += normalize(toOrigin + vec3(0.001)) * em.forces.w;'#10 +
    '    }'#10 +
    // 4. Apply forces
    '    vel += force * deltaTime * timeScale;'#10 +
    // 5. Drag (air resistance / damping)
    '    if (em.gravityDrag.w > 0.001) {'#10 +
    '      vel *= max(0.0, 1.0 - em.gravityDrag.w * deltaTime);'#10 +
    '    }'#10 +
    // 6. Integrate position
    '    pos += vel * deltaTime * timeScale;'#10 +
    // 7. Floor bounce / kill at floorY
    '    if (em.optParams.w > -1000.0 && pos.y < em.optParams.w) {'#10 +
    '      if (em.bounceTex.x > 0.001) {'#10 +
    '        pos.y = em.optParams.w;'#10 +
    '        vel.y = abs(vel.y) * em.bounceTex.x;'#10 +
    '        vel.x *= 0.9; vel.z *= 0.9;'#10 +
    '      } else {'#10 +
    '        age = maxLife + 1.0; // kill, will be respawned or removed'#10 +
    '      }'#10 +
    '    }'#10 +
    '  }'#10 +
    // === Push interaction (mouse) ===
    '  if (pushActive != 0) {'#10 +
    '    vec3 toP = pos - pushPos; float d = length(toP);'#10 +
    '    if (d < pushRadius && d > 0.001) vel += normalize(toP) * pushStrength * (1.0 - d/pushRadius);'#10 +
    '  }'#10 +
    // === Global forces (wind + gravity) applied to ALL particles ===
    '  vel += globalWind * deltaTime;'#10 +
    '  vel -= globalGravity * deltaTime;'#10 +
    // === Physics bridge collision ===
    '  if (physicsSampleRate > 0 && physicsColliderCount > 0 && (int(index) % physicsSampleRate) == 0) {'#10 +
    '    for (int c = 0; c < physicsColliderCount; c++) {'#10 +
    '      int b = c*2;'#10 +
    '      vec3 cmin = colliders[b].xyz;'#10 +
    '      float restitution = colliders[b].w;'#10 +
    '      vec3 cmax = colliders[b+1].xyz;'#10 +
    '      if (pos.x >= cmin.x && pos.x <= cmax.x &&'#10 +
    '          pos.y >= cmin.y && pos.y <= cmax.y &&'#10 +
    '          pos.z >= cmin.z && pos.z <= cmax.z) {'#10 +
    '        vec3 center = (cmin + cmax) * 0.5;'#10 +
    '        vec3 half_extent = (cmax - cmin) * 0.5;'#10 +
    '        vec3 d = pos - center;'#10 +
    '        vec3 face_dist = half_extent - abs(d);'#10 +
    '        if (face_dist.x < face_dist.y && face_dist.x < face_dist.z) {'#10 +
    '          pos.x = d.x > 0.0 ? cmax.x + 0.001 : cmin.x - 0.001;'#10 +
    '          vel.x = -vel.x * restitution;'#10 +
    '        } else if (face_dist.y < face_dist.z) {'#10 +
    '          pos.y = d.y > 0.0 ? cmax.y + 0.001 : cmin.y - 0.001;'#10 +
    '          vel.y = -vel.y * restitution;'#10 +
    '        } else {'#10 +
    '          pos.z = d.z > 0.0 ? cmax.z + 0.001 : cmin.z - 0.001;'#10 +
    '          vel.z = -vel.z * restitution;'#10 +
    '        }'#10 +
    '      }'#10 +
    '    }'#10 +
    '  }'#10 +
    // === Over-lifetime curves ===
    '  float t = clamp(age / max(maxLife, 0.001), 0.0, 1.0);'#10 +
    '  if (useColorOverride) {'#10 +
    '    color = mix(em.colorStart, em.colorEnd, t);'#10 +
    '  } else {'#10 +
    '    color.rgb = em.colorStart.rgb;'#10 +
    '    color.a = em.colorStart.a * (1.0 - t);'#10 +
    '  }'#10 +
    '  psize = mix(em.lifeSize.z, em.lifeSize.w, t);'#10 +
    // Glow (emissive boost) + HDR multiplier
    '  color.rgb *= (1.0 + em.optParams.x);'#10 +
    '  color.rgb *= hdrMultiplier;'#10 +
    // === Respawn / death based on lifeMode ===
    // Materialize particles are NOT killed by MaxLife - they freeze at their
    // target and stay there as the visible "almost-complete" swarm. The CPU
    // host (Update loop) reads back target.w, sees all particles arrived, and
    // replaces the whole swarm with a single SolidCube, killing the particles
    // itself. This mirrors the original CPU engine's "SolidCubeReady" event
    // which fires only when the LAST particle reaches its target.
    '  if (age >= maxLife && !isMaterialize) {'#10 +
    '    if (lifeMode == 0) { // lmContinuous'#10 +
    '      respawnParticle(idx, em, flags, pos, vel, age, color, psize, posData);'#10 +
    '    } else { // lmBurst or lmOneShotAutoRemove - mark dead'#10 +
    '      posData.w = 0.0; color.a = 0.0;'#10 +
    '    }'#10 +
    '  }'#10 +
    // Write back
    '  positions[index]    = vec4(pos, posData.w);'#10 +
    '  velocities[index]   = vec4(vel, age);'#10 +
    '  colors[index]       = color;'#10 +
    '  metaData.x = psize;'#10 +
    '  meta[index]         = metaData;'#10 +
    '  targets[index]      = targetData;'#10 +
    '}';

  { Vertex shader: camera-facing quad (2 triangles = 6 verts, UV 0..1)
    with optional motion-trail stretch along view-space velocity. }
  VERTEX_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout (location=0) in vec3 vertexPosition;'#10 +
    'layout (location=1) in vec2 vertexTexCoord;'#10 +
    'layout (location=0) uniform mat4 projectionMatrix;'#10 +
    'layout (location=1) uniform mat4 viewMatrix;'#10 +
    'layout (location=2) uniform float particleScale;'#10 +
    'layout(std430, binding=0) buffer ssbo0 { vec4 positions[]; };'#10 +
    'layout(std430, binding=1) buffer ssbo1 { vec4 velocities[]; };'#10 +
    'layout(std430, binding=2) buffer ssbo2 { vec4 colors[]; };'#10 +
    'layout(std430, binding=3) buffer ssbo3 { vec4 meta[]; };'#10 +
    'layout(std430, binding=6) buffer ssbo6 { vec4 emitterData[]; };'#10 +
    'out vec4 fragColor;'#10 +
    'out vec2 fragTexCoord;'#10 +
    'flat out int fragTextureIndex;'#10 +
    'void main() {'#10 +
    '  uint inst = uint(gl_InstanceID);'#10 +
    '  vec4 posData = positions[inst];'#10 +
    '  vec4 velData = velocities[inst];'#10 +
    '  vec3 position = posData.xyz;'#10 +
    '  vec3 velocity = velData.xyz;'#10 +
    '  fragColor = colors[inst];'#10 +
    '  fragTexCoord = vertexTexCoord;'#10 +
    '  if (posData.w < 0.5) { gl_Position = vec4(0,0,0,-1); return; } // dead slot offscreen'#10 +
    '  float psize = meta[inst].x;'#10 +
    '  int emitterID = int(meta[inst].y);'#10 +
    '  float trailStrength = 0.0;'#10 +
    '  int textureIndex = 0;'#10 +
    '  if (emitterID >= 0) {'#10 +
    '    int ebase = emitterID * 11;'#10 +
    '    trailStrength = emitterData[ebase + 9].y;'#10 +
    '    textureIndex = int(emitterData[ebase + 10].y);'#10 +
    '  }'#10 +
    '  fragTextureIndex = textureIndex;'#10 +
    '  float scale = 0.5 * particleScale * psize;'#10 +
    // Camera right and up vectors extracted from view matrix rows.
    '  vec3 camRight = vec3(viewMatrix[0][0], viewMatrix[1][0], viewMatrix[2][0]);'#10 +
    '  vec3 camUp    = vec3(viewMatrix[0][1], viewMatrix[1][1], viewMatrix[2][1]);'#10 +
    // View-space velocity direction for motion-trail stretch.
    '  vec3 viewVel = (viewMatrix * vec4(velocity, 0.0)).xyz;'#10 +
    '  float viewSpeed = length(viewVel);'#10 +
    '  vec3 viewDir = vec3(0.0);'#10 +
    '  if (viewSpeed > 0.001) viewDir = viewVel / viewSpeed;'#10 +
    '  vec3 worldMotionDir = camRight*viewDir.x + camUp*viewDir.y;'#10 +
    '  if (length(worldMotionDir) > 0.001) worldMotionDir = normalize(worldMotionDir);'#10 +
    '  float stretch = 1.0 + trailStrength * clamp(viewSpeed, 0.0, 5.0);'#10 +
    '  vec2 localPos = vertexPosition.xy;'#10 +
    '  vec3 worldPos;'#10 +
    '  if (trailStrength > 0.001) {'#10 +
    '    float along = dot(localPos, worldMotionDir.xy);'#10 +
    '    float perp = dot(localPos, vec2(-worldMotionDir.y, worldMotionDir.x));'#10 +
    '    along = along * stretch;'#10 +
    '    perp = perp / sqrt(stretch);'#10 +
    '    vec2 stretchedLocal = vec2('#10 +
    '      along * worldMotionDir.x - perp * worldMotionDir.y,'#10 +
    '      along * worldMotionDir.y + perp * worldMotionDir.x);'#10 +
    '    worldPos = position + camRight * stretchedLocal.x * scale + camUp * stretchedLocal.y * scale;'#10 +
    '  } else {'#10 +
    '    worldPos = position + camRight * vertexPosition.x * scale + camUp * vertexPosition.y * scale;'#10 +
    '  }'#10 +
    // IMPORTANT: worldPos is in WORLD space. We must transform with viewMatrix
    // first to get into camera/view space, then projectionMatrix to clip space.
    // Skipping viewMatrix makes particles appear stuck to the camera because
    // their world position would be interpreted as camera-relative.
    '  vec4 viewPos = viewMatrix * vec4(worldPos, 1.0);'#10 +
    '  gl_Position = projectionMatrix * viewPos;'#10 +
    '}';

  { Fragment shader: optional 4x4 sprite atlas OR procedural radial gradient
    fallback. The host sets atlasEnabled=1 and binds an atlas texture for
    textured particles; otherwise the fragment shader draws a clean round
    radial gradient so particles look soft out of the box. }
  FRAGMENT_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'in vec4 fragColor;'#10 +
    'in vec2 fragTexCoord;'#10 +
    'flat in int fragTextureIndex;'#10 +
    'out vec4 finalColor;'#10 +
    'uniform sampler2D particleAtlas;'#10 +
    'uniform int atlasEnabled;'#10 +
    'void main() {'#10 +
    '  if (atlasEnabled != 0) {'#10 +
    // 4x4 atlas grid: pick cell by textureIndex 0..15
    '    float cellU = 1.0 / 4.0;'#10 +
    '    float cellV = 1.0 / 4.0;'#10 +
    '    int cellX = fragTextureIndex % 4;'#10 +
    '    int cellY = fragTextureIndex / 4;'#10 +
    '    vec2 atlasUV = vec2('#10 +
    '      (float(cellX) + fragTexCoord.x) * cellU,'#10 +
    '      (float(cellY) + fragTexCoord.y) * cellV);'#10 +
    '    vec4 texColor = texture(particleAtlas, atlasUV);'#10 +
    '    finalColor = fragColor * texColor;'#10 +
    '  } else {'#10 +
    // Procedural radial gradient - smoothstep from center to edge
    '    vec2 centered = fragTexCoord - 0.5;'#10 +
    '    float dist = length(centered) * 2.0;'#10 +
    '    float alpha = 1.0 - smoothstep(0.5, 1.0, dist);'#10 +
    '    finalColor = vec4(fragColor.rgb, fragColor.a * alpha);'#10 +
    '  }'#10 +
    '}';

  { Camera-facing quad (2 triangles = 6 vertices). UVs span 0..1 so the
    fragment shader can sample a sprite atlas or draw a radial gradient
    that maps cleanly to a circle. }
  QUAD_VERTS: array[0..5] of TVector3 = (
    (x: -0.5; y: -0.5; z: 0.0),
    (x:  0.5; y: -0.5; z: 0.0),
    (x:  0.5; y:  0.5; z: 0.0),
    (x: -0.5; y: -0.5; z: 0.0),
    (x:  0.5; y:  0.5; z: 0.0),
    (x: -0.5; y:  0.5; z: 0.0));
  QUAD_UVS: array[0..5] of TVector2 = (
    (x: 0.0; y: 0.0),
    (x: 1.0; y: 0.0),
    (x: 1.0; y: 1.0),
    (x: 0.0; y: 0.0),
    (x: 1.0; y: 1.0),
    (x: 0.0; y: 1.0));

{ ========================================================================== }
{ Helper: build a neutral TYutaniEmitterData so callers only set the fields
  they care about. }
{ ========================================================================== }

function MakeEmitterData: TYutaniEmitterData;
begin
  FillChar(Result, SizeOf(TYutaniEmitterData), 0);
  Result.SpawnShape := ssBox;
  Result.Origin := Vector3Create(0, 0, 0);
  Result.SpawnDir := Vector3Create(0, 1, 0);
  Result.SpawnRadius := 0.5;
  Result.RegionMin := Vector3Create(-1, -1, -1);
  Result.RegionMax := Vector3Create(1, 1, 1);
  Result.MinSpeed := 0;
  Result.MaxSpeed := 1.0;
  Result.Spread := 0.3;
  Result.MinLife := 2.0;
  Result.MaxLife := 4.0;
  Result.StartSize := 0.1;
  Result.EndSize := 0.1;
  Result.StartColor.r := 255; Result.StartColor.g := 255;
  Result.StartColor.b := 255; Result.StartColor.a := 255;
  Result.EndColor   := Result.StartColor;
  Result.UseColorOverride := False;
  Result.Glow := 0;
  Result.TrailStrength := 0;
  Result.Gravity := Vector3Create(0, 0, 0);
  Result.Drag := 0;
  Result.CurlNoiseStrength := 0;
  Result.CurlNoiseFreq := 1.0;
  Result.VortexStrength := 0;
  Result.RadialForce := 0;
  Result.FloorY := YUTANI_NO_FLOOR;
  Result.Bounce := 0;
  Result.LifeMode := lmContinuous;
  Result.BlendMode := bmAlpha;
  Result.TextureIndex := -1;  // -1 = procedural radial gradient
  Result.IsMaterialize := False;
  Result.IsDematerialize := False;
  Result.ParticleCount := 1024;
  Result.Active := True;
  Result.Name := '';
end;

{ ========================================================================== }
{ TYutaniParticleEngine                                                      }
{ ========================================================================== }

constructor TYutaniParticleEngine.Create(ANumParticles: Integer);
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  if ANumParticles < 1024 then ANumParticles := 1024;
  FNumParticles := ((ANumParticles + YUTANI_PARTICLE_LOCAL_SIZE - 1)
                    div YUTANI_PARTICLE_LOCAL_SIZE) * YUTANI_PARTICLE_LOCAL_SIZE;
  FComputeProgram := 0; FRenderProgram := 0;
  FSSBO_Positions := 0; FSSBO_Velocities := 0; FSSBO_Colors := 0;
  FSSBO_Meta := 0; FSSBO_Targets := 0; FSSBO_EmitterData := 0;
  FSSBO_Impacts := 0; FSSBO_Colliders := 0;
  FBillboardVAO := 0; FBillboardVBO := 0;
  FAtlasTexID := 0; FAtlasEnabled := 0;
  FParticleScale := 1.0; FTimeScale := 1.0; FTime := 0.0;
  FInstancesX1000 := 100.0;  // Render only 10% of pool by default
  FBlendMode := bmAlpha;
  FPushPos := Vector3Create(0, 0, 0); FPushRadius := 0.3; FPushStrength := 8.0;
  FPushActive := False;
  FGPUInitialized := False;
  FGlobalWind := Vector3Create(0, 0, 0);
  FGlobalGravity := Vector3Create(0, 0, 0);  // No global gravity - presets have their own
  FHDRMultiplier := 1.0;
  FImpactMax := 1024;
  FImpactWriteIdx := 0;
  SetLength(FLastImpactBuffer, 1024);
  FPhysicsBridge := nil;
  FPhysicsSampleRate := 0;
  FPhysicsMaxColliders := 32;
  FNumEmitters := 0;
  FEmittersDirty := False;
  FCPU_Dirty := False;
  FPendingSpawnCount := 0;
  FPendingMetaCount := 0;
  FFullResyncNeeded := False;
  SetLength(FEmitters, YUTANI_MAX_EMITTERS);
  SetLength(FSpawnTimes, YUTANI_MAX_EMITTERS);
  SetLength(FCPU_Positions, FNumParticles);
  SetLength(FCPU_Velocities, FNumParticles);
  SetLength(FCPU_Colors, FNumParticles);
  SetLength(FCPU_Meta, FNumParticles);
  SetLength(FCPU_Targets, FNumParticles);
  SetLength(FPendingSpawnSlots, FNumParticles);  // worst case: all slots spawn at once
  SetLength(FPendingMetaSlots, FNumParticles);   // worst case: all slots renumbered at once

  { Initialize CPU-side particle mirror here in the Constructor (NOT in
    InitGPUResources). All slots start dead so FindFreeParticleSlots finds
    them on the first AddEmitter call. This also ensures that if AddEmitter
    is called BEFORE the GPU is initialized (which is common when the
    engine thread hasn't entered its loop yet), the CPU data is preserved
    and InitGPUResources won't overwrite it. }
  for I := 0 to FNumParticles - 1 do
  begin
    FCPU_Positions[I].x := 0;  FCPU_Positions[I].y := 0;
    FCPU_Positions[I].z := 0;  FCPU_Positions[I].w := 0.0;  // DEAD / FREE
    FCPU_Velocities[I].x := 0; FCPU_Velocities[I].y := 0;
    FCPU_Velocities[I].z := 0; FCPU_Velocities[I].w := 0;  // age = 0
    FCPU_Colors[I].x := 1.0; FCPU_Colors[I].y := 1.0;
    FCPU_Colors[I].z := 1.0; FCPU_Colors[I].w := 1.0;
    FCPU_Meta[I].x := 1.0;    // size
    FCPU_Meta[I].y := -1.0;   // emitterID = -1 (UNASSIGNED)
    FCPU_Meta[I].z := 0.0;   // maxLife
    FCPU_Meta[I].w := 0.0;   // spawnDelay
    FCPU_Targets[I].x := 0;  FCPU_Targets[I].y := 0;
    FCPU_Targets[I].z := 0;  FCPU_Targets[I].w := 0;  // stateFlag = 0
  end;
end;

destructor TYutaniParticleEngine.Destroy;
begin
  FreeGPUResources;
  FLock.Free;
  SetLength(FEmitters, 0);
  SetLength(FSpawnTimes, 0);
  SetLength(FCPU_Positions, 0);
  SetLength(FCPU_Velocities, 0);
  SetLength(FCPU_Colors, 0);
  SetLength(FCPU_Meta, 0);
  SetLength(FCPU_Targets, 0);
  SetLength(FPendingSpawnSlots, 0);
  SetLength(FPendingMetaSlots, 0);
  inherited;
end;

{ === GPU resource setup / teardown === }

procedure TYutaniParticleEngine.InitGPUResources;
var csId, vsId, fsId: Cardinal;
begin
  if FGPUInitialized then Exit;
  if not LoadOpenGL43 then
    raise Exception.Create('Yutani.Render.Particles.GPU: OpenGL 4.3+ function pointers not available.');

  csId := CompileShaderRaw(COMPUTE_SHADER_SRC, GL_COMPUTE_SHADER);
  FComputeProgram := LinkProgramRaw([csId]);
  vsId := CompileShaderRaw(VERTEX_SHADER_SRC, GL_VERTEX_SHADER);
  fsId := CompileShaderRaw(FRAGMENT_SHADER_SRC, GL_FRAGMENT_SHADER);
  FRenderProgram := LinkProgramRaw([vsId, fsId]);

  FCompLoc_Time          := glGetUniformLocation(FComputeProgram, 'time');
  FCompLoc_TimeScale     := glGetUniformLocation(FComputeProgram, 'timeScale');
  FCompLoc_DeltaTime     := glGetUniformLocation(FComputeProgram, 'deltaTime');
  FCompLoc_ParticleCount := glGetUniformLocation(FComputeProgram, 'particleCount');
  FCompLoc_PushPos       := glGetUniformLocation(FComputeProgram, 'pushPos');
  FCompLoc_PushRadius    := glGetUniformLocation(FComputeProgram, 'pushRadius');
  FCompLoc_PushStrength  := glGetUniformLocation(FComputeProgram, 'pushStrength');
  FCompLoc_PushActive    := glGetUniformLocation(FComputeProgram, 'pushActive');
  FCompLoc_NumEmitters   := glGetUniformLocation(FComputeProgram, 'numEmitters');
  FCompLoc_GlobalWind    := glGetUniformLocation(FComputeProgram, 'globalWind');
  FCompLoc_GlobalGravity := glGetUniformLocation(FComputeProgram, 'globalGravity');
  FCompLoc_HDRMultiplier := glGetUniformLocation(FComputeProgram, 'hdrMultiplier');
  FCompLoc_ImpactWriteIdx := glGetUniformLocation(FComputeProgram, 'impactWriteIdx');
  FCompLoc_ImpactMax     := glGetUniformLocation(FComputeProgram, 'impactMax');
  FCompLoc_PhysicsSampleRate := glGetUniformLocation(FComputeProgram, 'physicsSampleRate');
  FCompLoc_PhysicsColliderCount := glGetUniformLocation(FComputeProgram, 'physicsColliderCount');

  FRendLoc_ProjMatrix    := glGetUniformLocation(FRenderProgram, 'projectionMatrix');
  FRendLoc_ViewMatrix    := glGetUniformLocation(FRenderProgram, 'viewMatrix');
  FRendLoc_ParticleScale := glGetUniformLocation(FRenderProgram, 'particleScale');
  FRendLoc_AtlasEnabled  := glGetUniformLocation(FRenderProgram, 'atlasEnabled');
  FRendLoc_AtlasSampler   := glGetUniformLocation(FRenderProgram, 'particleAtlas');

  { NOTE: CPU-side particle data is initialized in the Constructor, NOT here.
    This is critical: if AddEmitter is called BEFORE the GPU is initialized
    (common because the engine thread hasn't entered its Execute loop yet),
    the CPU mirror already has the alive particles from AddEmitter. If we
    re-initialized them here, we'd overwrite the user's emitter spawns and
    they'd never appear. The Constructor sets all slots to dead, AddEmitter
    marks some alive, and here we just upload whatever is currently in the
    CPU mirror to the GPU. }

  // Per-particle SSBOs
  glGenBuffers(1, @FSSBO_Positions);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Positions);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FNumParticles*SizeOf(TVector4),
    @FCPU_Positions[0], GL_DYNAMIC_COPY);
  glGenBuffers(1, @FSSBO_Velocities);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Velocities);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FNumParticles*SizeOf(TVector4),
    @FCPU_Velocities[0], GL_DYNAMIC_COPY);
  glGenBuffers(1, @FSSBO_Colors);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Colors);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FNumParticles*SizeOf(TVector4),
    @FCPU_Colors[0], GL_DYNAMIC_COPY);
  glGenBuffers(1, @FSSBO_Meta);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Meta);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FNumParticles*SizeOf(TVector4),
    @FCPU_Meta[0], GL_DYNAMIC_COPY);
  glGenBuffers(1, @FSSBO_Targets);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Targets);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FNumParticles*SizeOf(TVector4),
    @FCPU_Targets[0], GL_DYNAMIC_COPY);
  // Emitter data SSBO (binding 6): 11 vec4 per emitter, max 64 emitters
  glGenBuffers(1, @FSSBO_EmitterData);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_EmitterData);
  glBufferData(GL_SHADER_STORAGE_BUFFER,
    YUTANI_MAX_EMITTERS * YUTANI_EMITTER_VEC4_COUNT * SizeOf(TVector4), nil, GL_DYNAMIC_DRAW);
  // Impacts ring buffer SSBO (binding 7)
  glGenBuffers(1, @FSSBO_Impacts);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Impacts);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FImpactMax * SizeOf(TVector4), nil, GL_DYNAMIC_READ);
  // Collider SSBO (binding 8): 32 AABB pairs = 64 vec4
  glGenBuffers(1, @FSSBO_Colliders);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Colliders);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FPhysicsMaxColliders * 2 * SizeOf(TVector4), nil, GL_DYNAMIC_DRAW);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);

  BuildBillboardVAO;
  FEmittersDirty := True;
  FCPU_Dirty := True;  // Force sync of CPU mirror (may contain alive particles
                       // from AddEmitter calls that happened before InitGPUResources)
  FGPUInitialized := True;
end;

procedure TYutaniParticleEngine.FreeGPUResources;
begin
  if not FGPUInitialized then Exit;
  if (FComputeProgram <> 0) and Assigned(glDeleteProgram) then glDeleteProgram(FComputeProgram);
  if (FRenderProgram <> 0) and Assigned(glDeleteProgram) then glDeleteProgram(FRenderProgram);
  if FSSBO_Positions <> 0 then glDeleteBuffers(1, @FSSBO_Positions);
  if FSSBO_Velocities <> 0 then glDeleteBuffers(1, @FSSBO_Velocities);
  if FSSBO_Colors <> 0 then glDeleteBuffers(1, @FSSBO_Colors);
  if FSSBO_Meta <> 0 then glDeleteBuffers(1, @FSSBO_Meta);
  if FSSBO_Targets <> 0 then glDeleteBuffers(1, @FSSBO_Targets);
  if FSSBO_EmitterData <> 0 then glDeleteBuffers(1, @FSSBO_EmitterData);
  if FSSBO_Impacts <> 0 then glDeleteBuffers(1, @FSSBO_Impacts);
  if FSSBO_Colliders <> 0 then glDeleteBuffers(1, @FSSBO_Colliders);
  if FBillboardVBO <> 0 then glDeleteBuffers(1, @FBillboardVBO);
  if FBillboardVAO <> 0 then glDeleteVertexArrays(1, @FBillboardVAO);
  FComputeProgram := 0; FRenderProgram := 0;
  FSSBO_Positions := 0; FSSBO_Velocities := 0; FSSBO_Colors := 0;
  FSSBO_Meta := 0; FSSBO_Targets := 0; FSSBO_EmitterData := 0;
  FSSBO_Impacts := 0; FSSBO_Colliders := 0;
  FBillboardVAO := 0; FBillboardVBO := 0;
  FGPUInitialized := False;
end;

{ BuildBillboardVAO creates a camera-facing quad (2 triangles = 6 vertices)
  with position (location 0) and UV (location 1) attributes. The UV span
  0..1 lets the fragment shader sample a sprite atlas or draw a clean
  radial gradient that maps to a circle. }
procedure TYutaniParticleEngine.BuildBillboardVAO;
var
  Verts: array[0..5] of record
    Pos: TVector3;
    UV:  TVector2;
  end;
  I: Integer;
begin
  for I := 0 to 5 do
  begin
    Verts[I].Pos := QUAD_VERTS[I];
    Verts[I].UV  := QUAD_UVS[I];
  end;
  glGenVertexArrays(1, @FBillboardVAO);
  glBindVertexArray(FBillboardVAO);
  try
    glGenBuffers(1, @FBillboardVBO);
    glBindBuffer(GL_ARRAY_BUFFER, FBillboardVBO);
    glBufferData(GL_ARRAY_BUFFER, SizeOf(Verts), @Verts[0], GL_STATIC_DRAW);
    // Position attribute: location 0, 3 floats, stride = sizeof(pos) + sizeof(uv) = 20 bytes
    glVertexAttribPointer(0, 3, GL_FLOAT, 0, SizeOf(Verts[0]), nil);
    glEnableVertexAttribArray(0);
    // UV attribute: location 1, 2 floats, offset = sizeof(TVector3) = 12 bytes
    glVertexAttribPointer(1, 2, GL_FLOAT, 0, SizeOf(Verts[0]), Pointer(12));
    glEnableVertexAttribArray(1);
  finally glBindVertexArray(0); end;
  glBindBuffer(GL_ARRAY_BUFFER, 0);
end;

{ === Emitter registry <-> GPU upload === }

{ PackModeFlags encodes the small enum/bool fields of TYutaniEmitterData
  into one int that fits in a float slot of the SSBO. Bit layout:
    bits 0-1   lifeMode (0=Continuous, 1=Burst, 2=OneShotAutoRemove)
    bits 2-3   spawnShape (0=Box, 1=Sphere, 2=Cone)
    bit  4     blendMode (0=Alpha, 1=Additive)
    bit  5     useColorOverride
    bit  6     isMaterialize
    bit  7     isDematerialize
    bits 8-15  textureIndex (0..15 used, upper 8 bits reserved) }
function TYutaniParticleEngine.PackModeFlags(const AData: TYutaniEmitterData): Integer;
var
  TexIdx: Integer;
begin
  TexIdx := AData.TextureIndex;
  if TexIdx < 0 then TexIdx := 0;  // procedural path is selected by atlasEnabled uniform
  Result := (Ord(AData.LifeMode) and $3)
          or ((Ord(AData.SpawnShape) and $3) shl 2)
          or ((Ord(AData.BlendMode) and $1) shl 4)
          or ((Ord(AData.UseColorOverride) and $1) shl 5)
          or ((Ord(AData.IsMaterialize) and $1) shl 6)
          or ((Ord(AData.IsDematerialize) and $1) shl 7)
          or ((TexIdx and $FF) shl 8);
end;

{ SyncEmittersToGPU uploads the CPU-side FEmitters array to the emitter SSBO.
  Layout per emitter: 11 vec4 records (176 bytes), see unit header. }
procedure TYutaniParticleEngine.SyncEmittersToGPU;
var
  Buf: array[0..(YUTANI_MAX_EMITTERS*YUTANI_EMITTER_VEC4_COUNT)-1] of TVector4;
  I: Integer;
  E: TYutaniEmitterData;
  StartRGBA, EndRGBA: TVector4;
begin
  if not FGPUInitialized then Exit;
  for I := 0 to YUTANI_MAX_EMITTERS - 1 do
  begin
    if I < FNumEmitters then
    begin
      E := FEmitters[I];
      // [0] origin.xyz, modeFlags
      Buf[I*11 + 0].x := E.Origin.x;
      Buf[I*11 + 0].y := E.Origin.y;
      Buf[I*11 + 0].z := E.Origin.z;
      Buf[I*11 + 0].w := Single(PackModeFlags(E));
      // [1] spawnDir.xyz, spawnRadius (or coneAngle)
      Buf[I*11 + 1].x := E.SpawnDir.x;
      Buf[I*11 + 1].y := E.SpawnDir.y;
      Buf[I*11 + 1].z := E.SpawnDir.z;
      Buf[I*11 + 1].w := E.SpawnRadius;
      // [2] regionMin.xyz, minSpeed
      Buf[I*11 + 2].x := E.RegionMin.x;
      Buf[I*11 + 2].y := E.RegionMin.y;
      Buf[I*11 + 2].z := E.RegionMin.z;
      Buf[I*11 + 2].w := E.MinSpeed;
      // [3] regionMax.xyz, maxSpeed
      Buf[I*11 + 3].x := E.RegionMax.x;
      Buf[I*11 + 3].y := E.RegionMax.y;
      Buf[I*11 + 3].z := E.RegionMax.z;
      Buf[I*11 + 3].w := E.MaxSpeed;
      // [4] minLife, maxLife, startSize, endSize
      Buf[I*11 + 4].x := E.MinLife;
      Buf[I*11 + 4].y := E.MaxLife;
      Buf[I*11 + 4].z := E.StartSize;
      Buf[I*11 + 4].w := E.EndSize;
      // [5] startColor (rgba normalized 0..1)
      StartRGBA.x := E.StartColor.r / 255.0;
      StartRGBA.y := E.StartColor.g / 255.0;
      StartRGBA.z := E.StartColor.b / 255.0;
      StartRGBA.w := E.StartColor.a / 255.0;
      Buf[I*11 + 5] := StartRGBA;
      // [6] endColor (rgba normalized 0..1)
      EndRGBA.x := E.EndColor.r / 255.0;
      EndRGBA.y := E.EndColor.g / 255.0;
      EndRGBA.z := E.EndColor.b / 255.0;
      EndRGBA.w := E.EndColor.a / 255.0;
      Buf[I*11 + 6] := EndRGBA;
      // [7] gravity.xyz, drag
      Buf[I*11 + 7].x := E.Gravity.x;
      Buf[I*11 + 7].y := E.Gravity.y;
      Buf[I*11 + 7].z := E.Gravity.z;
      Buf[I*11 + 7].w := E.Drag;
      // [8] curlStrength, curlFreq, vortex, radial
      Buf[I*11 + 8].x := E.CurlNoiseStrength;
      Buf[I*11 + 8].y := E.CurlNoiseFreq;
      Buf[I*11 + 8].z := E.VortexStrength;
      Buf[I*11 + 8].w := E.RadialForce;
      // [9] glow, trailStrength, spread, floorY
      Buf[I*11 + 9].x := E.Glow;
      Buf[I*11 + 9].y := E.TrailStrength;
      Buf[I*11 + 9].z := E.Spread;
      Buf[I*11 + 9].w := E.FloorY;
      // [10] bounce, textureIndex, reserved, reserved
      Buf[I*11 + 10].x := E.Bounce;
      Buf[I*11 + 10].y := Single(E.TextureIndex);
      Buf[I*11 + 10].z := 0;
      Buf[I*11 + 10].w := Ord(E.Active);
    end
    else
    begin
      // Zero out unused slots so the compute shader's bounds check on
      // numEmitters prevents stray reads.
      Buf[I*11 + 0]  := Vector4Zero;
      Buf[I*11 + 1]  := Vector4Zero;
      Buf[I*11 + 2]  := Vector4Zero;
      Buf[I*11 + 3]  := Vector4Zero;
      Buf[I*11 + 4]  := Vector4Zero;
      Buf[I*11 + 5]  := Vector4Zero;
      Buf[I*11 + 6]  := Vector4Zero;
      Buf[I*11 + 7]  := Vector4Zero;
      Buf[I*11 + 8]  := Vector4Zero;
      Buf[I*11 + 9]  := Vector4Zero;
      Buf[I*11 + 10] := Vector4Zero;
    end;
  end;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_EmitterData);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    YUTANI_MAX_EMITTERS * YUTANI_EMITTER_VEC4_COUNT * SizeOf(TVector4), @Buf[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FEmittersDirty := False;
end;

{ SyncCPUParticlesToGPU pushes the entire CPU mirror to the GPU SSBOs. }
procedure TYutaniParticleEngine.SyncCPUParticlesToGPU;
begin
  if not FGPUInitialized then Exit;
  if FNumParticles = 0 then Exit;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Positions);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    FNumParticles * SizeOf(TVector4), @FCPU_Positions[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Velocities);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    FNumParticles * SizeOf(TVector4), @FCPU_Velocities[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Colors);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    FNumParticles * SizeOf(TVector4), @FCPU_Colors[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Meta);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    FNumParticles * SizeOf(TVector4), @FCPU_Meta[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Targets);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    FNumParticles * SizeOf(TVector4), @FCPU_Targets[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FCPU_Dirty := False;
  FPendingSpawnCount := 0;  // a full sync also covers all pending slots
  FPendingMetaCount := 0;   // ... and all pending meta-only slots
end;

{ SyncPendingSlots uploads ONLY the particle indices in FPendingSpawnSlots
  to the GPU, instead of the entire 500K-particle array. This is critical
  for two reasons:
  1. The VCL thread calls AddEmitter (which populates FPendingSpawnSlots)
     but cannot make OpenGL calls because it doesn't own the GL context.
     The engine thread picks up the pending slots in the next Update.
  2. A full sync would overwrite compute-shader results for already-running
     particles (positions/velocities that the compute shader modified).
     Only syncing the newly-spawned slots preserves the running particles. }
procedure TYutaniParticleEngine.SyncPendingSlots;
var
  I, Idx: Integer;
  Off: NativeInt;
begin
  if not FGPUInitialized then Exit;
  if FPendingSpawnCount <= 0 then Exit;
  for I := 0 to FPendingSpawnCount - 1 do
  begin
    Idx := FPendingSpawnSlots[I];
    if (Idx < 0) or (Idx >= FNumParticles) then Continue;
    Off := Idx * SizeOf(TVector4);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Positions);
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Off, SizeOf(TVector4), @FCPU_Positions[Idx]);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Velocities);
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Off, SizeOf(TVector4), @FCPU_Velocities[Idx]);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Colors);
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Off, SizeOf(TVector4), @FCPU_Colors[Idx]);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Meta);
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Off, SizeOf(TVector4), @FCPU_Meta[Idx]);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Targets);
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Off, SizeOf(TVector4), @FCPU_Targets[Idx]);
  end;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FPendingSpawnCount := 0;
end;

{ SyncPendingMetaSlots uploads ONLY the meta vec4 for the indices in
  FPendingMetaSlots. It does NOT touch positions / velocities / colors /
  targets. This is used by CompactEmitters and RemoveEmitter when the only
  change is an emitterID renumber: the live position/velocity that the
  compute shader has been advancing must NOT be overwritten by the stale
  CPU mirror (which still holds the spawn-time position). Syncing only the
  meta SSBO delivers the renumbered emitterID to the GPU without resetting
  the visible particle motion. }
procedure TYutaniParticleEngine.SyncPendingMetaSlots;
var
  I, Idx: Integer;
  Off: NativeInt;
begin
  if not FGPUInitialized then Exit;
  if FPendingMetaCount <= 0 then Exit;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Meta);
  for I := 0 to FPendingMetaCount - 1 do
  begin
    Idx := FPendingMetaSlots[I];
    if (Idx < 0) or (Idx >= FNumParticles) then Continue;
    Off := Idx * SizeOf(TVector4);
    glBufferSubData(GL_SHADER_STORAGE_BUFFER, Off, SizeOf(TVector4), @FCPU_Meta[Idx]);
  end;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FPendingMetaCount := 0;
end;

{ === Particle slot helpers === }

{ FindFreeParticleSlots scans the CPU mirror for dead slots (posData.w < 0.5)
  and writes up to Count indices into a caller-provided array. Returns the
  actual number of slots found. }
function TYutaniParticleEngine.FindFreeParticleSlots(Count: Integer;
  Slots: PIntegerArray): Integer;
var
  Found, I: Integer;
begin
  Result := 0;
  if not Assigned(Slots) then Exit;
  Found := 0;
  for I := 0 to FNumParticles - 1 do
  begin
    if FCPU_Positions[I].w < 0.5 then
    begin
      Slots[Found] := I;
      Inc(Found);
      if Found >= Count then Break;
    end;
  end;
  Result := Found;
end;

{ SpawnParticleCPU writes the initial state for a single particle based on
  the emitter's spawn shape. Called by AssignParticlesToEmitter on AddEmitter. }
procedure TYutaniParticleEngine.SpawnParticleCPU(Idx: Integer;
  EmitterID: Integer; const AData: TYutaniEmitterData);
var
  RX, RY, RZ: Single;
  Dir: TVector3;
  Speed: Single;
  RightV, UpV, ConeOff: TVector3;
  ConeAng, SpinAng: Single;
begin
  RX := Random; RY := Random; RZ := Random;
  case AData.SpawnShape of
    ssBox:
      begin
        FCPU_Positions[Idx].x := AData.RegionMin.x + (AData.RegionMax.x - AData.RegionMin.x) * RX;
        FCPU_Positions[Idx].y := AData.RegionMin.y + (AData.RegionMax.y - AData.RegionMin.y) * RY;
        FCPU_Positions[Idx].z := AData.RegionMin.z + (AData.RegionMax.z - AData.RegionMin.z) * RZ;
        FCPU_Velocities[Idx].x := 0;
        FCPU_Velocities[Idx].y := 0;
        FCPU_Velocities[Idx].z := 0;
      end;
    ssSphere:
      begin
        Dir.x := RX - 0.5;
        Dir.y := RY - 0.5;
        Dir.z := RZ - 0.5;
        if Vector3Length(Dir) > 0.001 then
          Dir := Vector3Normalize(Dir)
        else
          Dir := Vector3Create(0, 1, 0);
        FCPU_Positions[Idx].x := AData.Origin.x + Dir.x * AData.SpawnRadius * Sqrt(RX);
        FCPU_Positions[Idx].y := AData.Origin.y + Dir.y * AData.SpawnRadius * Sqrt(RX);
        FCPU_Positions[Idx].z := AData.Origin.z + Dir.z * AData.SpawnRadius * Sqrt(RX);
        Speed := AData.MinSpeed + RY * (AData.MaxSpeed - AData.MinSpeed);
        FCPU_Velocities[Idx].x := Dir.x * Speed;
        FCPU_Velocities[Idx].y := Dir.y * Speed;
        FCPU_Velocities[Idx].z := Dir.z * Speed;
      end;
    ssCone:
      begin
        // Spawn at origin, initial velocity along SpawnDir with cone spread.
        // Apply random lateral offset so the plume looks like a cone, not a
        // single beam. The half-angle is AData.SpawnRadius (radians).
        FCPU_Positions[Idx].x := AData.Origin.x;
        FCPU_Positions[Idx].y := AData.Origin.y;
        FCPU_Positions[Idx].z := AData.Origin.z;
        Dir := AData.SpawnDir;
        if Vector3Length(Dir) > 0.001 then
          Dir := Vector3Normalize(Dir)
        else
          Dir := Vector3Create(0, 1, 0);
        // Build a right vector perpendicular to Dir (manual cross product,
        // avoids dependency on Vector3CrossProduct which may not exist in
        // all Raylib Pascal bindings).
        if Abs(Dir.y) > 0.9 then
          RightV := Vector3Create(1, 0, 0)
        else
        begin
          // RightV = normalize(cross(Dir, (0,1,0)))
          // cross(Dir, Up) with Up=(0,1,0) = (-Dir.z, 0, Dir.x)
          RightV.x := -Dir.z;
          RightV.y := 0;
          RightV.z := Dir.x;
          RightV := Vector3Normalize(RightV);
        end;
        // UpV = cross(RightV, Dir)
        UpV.x := RightV.y * Dir.z - RightV.z * Dir.y;
        UpV.y := RightV.z * Dir.x - RightV.x * Dir.z;
        UpV.z := RightV.x * Dir.y - RightV.y * Dir.x;
        // Random angle within the cone half-angle, random spin around axis
        ConeAng := (RX - 0.5) * 2.0 * AData.SpawnRadius;  // -halfAngle .. +halfAngle
        SpinAng := RY * 2.0 * 3.14159265;
        ConeOff.x := RightV.x * Cos(SpinAng) + UpV.x * Sin(SpinAng);
        ConeOff.y := RightV.y * Cos(SpinAng) + UpV.y * Sin(SpinAng);
        ConeOff.z := RightV.z * Cos(SpinAng) + UpV.z * Sin(SpinAng);
        // Scale by sin(half-angle) * spread to get lateral offset
        ConeAng := Sin(ConeAng) * AData.Spread;
        ConeOff.x := ConeOff.x * ConeAng;
        ConeOff.y := ConeOff.y * ConeAng;
        ConeOff.z := ConeOff.z * ConeAng;
        Dir.x := Dir.x + ConeOff.x;
        Dir.y := Dir.y + ConeOff.y;
        Dir.z := Dir.z + ConeOff.z;
        Dir := Vector3Normalize(Dir);
        Speed := AData.MinSpeed + RZ * (AData.MaxSpeed - AData.MinSpeed);
        FCPU_Velocities[Idx].x := Dir.x * Speed;
        FCPU_Velocities[Idx].y := Dir.y * Speed;
        FCPU_Velocities[Idx].z := Dir.z * Speed;
      end;
  end;
  FCPU_Positions[Idx].w := 1.0; // alive
  // Pick a per-particle max life in [minLife, maxLife]
  FCPU_Velocities[Idx].w := 0.0;  // age = 0
  FCPU_Colors[Idx].x := AData.StartColor.r / 255.0;
  FCPU_Colors[Idx].y := AData.StartColor.g / 255.0;
  FCPU_Colors[Idx].z := AData.StartColor.b / 255.0;
  FCPU_Colors[Idx].w := AData.StartColor.a / 255.0;
  FCPU_Meta[Idx].x := AData.StartSize;
  FCPU_Meta[Idx].y := Single(EmitterID);
  FCPU_Meta[Idx].z := AData.MinLife + Random * (AData.MaxLife - AData.MinLife);
  FCPU_Meta[Idx].w := 0.0;  // no spawn delay
  FCPU_Targets[Idx].x := 0;
  FCPU_Targets[Idx].y := 0;
  FCPU_Targets[Idx].z := 0;
  FCPU_Targets[Idx].w := 0;  // stateFlag = 0 (not arrived)
end;

{ AssignParticlesToEmitter spawns ParticleCount particles for the given
  emitter ID and writes their initial state to the CPU mirror. }
procedure TYutaniParticleEngine.AssignParticlesToEmitter(EmitterID: Integer;
  const AData: TYutaniEmitterData);
var
  Slots: array of Integer;
  Found, I, Idx, Count: Integer;
begin
  Count := AData.ParticleCount;
  if Count <= 0 then Exit;
  if Count > FNumParticles then Count := FNumParticles;
  SetLength(Slots, Count);
  Found := FindFreeParticleSlots(Count, PIntegerArray(@Slots[0]));
  if Found < Count then Count := Found;
  for I := 0 to Count - 1 do
  begin
    Idx := Slots[I];
    SpawnParticleCPU(Idx, EmitterID, AData);
    // Append to pending spawn slots so the engine thread (which owns the
    // GL context) syncs ONLY this slot to the GPU in the next Update.
    // This avoids making OpenGL calls from the VCL thread and avoids
    // overwriting compute-shader results for already-running particles.
    if FPendingSpawnCount < Length(FPendingSpawnSlots) then
    begin
      FPendingSpawnSlots[FPendingSpawnCount] := Idx;
      Inc(FPendingSpawnCount);
    end;
  end;
  FCPU_Dirty := True;
end;

{ === Compute dispatch === }

procedure TYutaniParticleEngine.DispatchCompute(const dt: Single);
var GroupX: Cardinal;
    {$IFDEF YUTANI_GL_DEBUG}glErr: Cardinal;{$ENDIF}
begin
  { BUG FIX #2: Flush Raylib batches BEFORE we touch raw GL state, so any
    pending DrawText / DrawRectangle etc. is submitted with Raylib's own
    shader before we swap it out. }
  rlDrawRenderBatchActive;
  glUseProgram(FComputeProgram);
  // Bind all SSBOs (binding 5 is intentionally skipped - was startPositions)
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Positions);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, FSSBO_Velocities);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, FSSBO_Colors);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, FSSBO_Meta);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 4, FSSBO_Targets);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 6, FSSBO_EmitterData);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 7, FSSBO_Impacts);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 8, FSSBO_Colliders);
  // Push uniforms
  glUniform1f(FCompLoc_Time, FTime);
  glUniform1f(FCompLoc_TimeScale, FTimeScale);
  glUniform1f(FCompLoc_DeltaTime, dt);
  glUniform1i(FCompLoc_ParticleCount, FNumParticles);
  glUniform3f(FCompLoc_PushPos, FPushPos.x, FPushPos.y, FPushPos.z);
  glUniform1f(FCompLoc_PushRadius, FPushRadius);
  glUniform1f(FCompLoc_PushStrength, FPushStrength);
  if FPushActive then glUniform1i(FCompLoc_PushActive, 1)
                 else glUniform1i(FCompLoc_PushActive, 0);
  glUniform1i(FCompLoc_NumEmitters, FNumEmitters);
  glUniform3f(FCompLoc_GlobalWind,    FGlobalWind.x,    FGlobalWind.y,    FGlobalWind.z);
  glUniform3f(FCompLoc_GlobalGravity, FGlobalGravity.x, FGlobalGravity.y, FGlobalGravity.z);
  glUniform1f(FCompLoc_HDRMultiplier, FHDRMultiplier);
  glUniform1i(FCompLoc_ImpactWriteIdx, FImpactWriteIdx);
  glUniform1i(FCompLoc_ImpactMax, FImpactMax);
  glUniform1i(FCompLoc_PhysicsSampleRate, FPhysicsSampleRate);
  glUniform1i(FCompLoc_PhysicsColliderCount, FCurrentColliderCount);
  // Dispatch
  GroupX := Cardinal(FNumParticles div YUTANI_PARTICLE_LOCAL_SIZE);
  glDispatchCompute(GroupX, 1, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  // Unbind the compute program (the SSBOs stay bound - they'll be reused by
  // DrawInstances next, and unbinding 8 bindings per frame is pure driver
  // overhead that showed up in the fullscreen profile).
  glUseProgram(0);
  { BUG FIX #2: Restore Raylib's internal rlgl state cache so its
    DrawText / 2D batcher keeps working. rlSetShader(...) is gone - we
    use rlEnableShader + rlActiveTextureSlot + rlSetTexture to sync the
    rlgl cache with the real OpenGL state. }
  rlEnableShader(rlGetShaderIdDefault());
  rlActiveTextureSlot(0);
  rlSetTexture(rlGetTextureIdDefault());
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  { glGetError forces a pipeline flush - skip on every frame, only check
    when YUTANI_GL_DEBUG is defined. }
  {$IFDEF YUTANI_GL_DEBUG}
  glErr := glGetError();
  if glErr <> GL_NO_ERROR then
    OutputDebugStringA(PAnsiChar(AnsiString(Format(
      'Yutani GPU: GL error after compute = 0x%x', [glErr]))));
  {$ENDIF}
end;

{ === Render === }

procedure TYutaniParticleEngine.DrawInstances(const NumInstances: Integer;
  const ACamera: TCamera3D);
var ProjMat, ViewMat: TMatrix;
    {$IFDEF YUTANI_GL_DEBUG}glErr: Cardinal;{$ENDIF}
begin
  if NumInstances <= 0 then Exit;
  ViewMat := rlGetMatrixModelview();
  ProjMat := rlGetMatrixProjection();
  { BUG FIX #2: Flush Raylib batches before we touch raw GL state. }
  rlDrawRenderBatchActive;
  glDisable(GL_CULL_FACE);
  glDisable(GL_DEPTH_TEST);  // Particles ignore depth buffer - always visible, no occlusion
  glDepthMask(0);            // Don't write to depth buffer either
  glEnable(GL_BLEND);
  case FBlendMode of
    bmAdditive: glBlendFunc(GL_SRC_ALPHA, GL_ONE);
  else         glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  end;
  glUseProgram(FRenderProgram);
  // Bind SSBOs needed by vertex shader
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Positions);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, FSSBO_Velocities);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, FSSBO_Colors);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, FSSBO_Meta);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 6, FSSBO_EmitterData);
  // Set common uniforms
  glUniformMatrix4fv(FRendLoc_ProjMatrix, 1, GL_TRUE, @ProjMat);
  glUniformMatrix4fv(FRendLoc_ViewMatrix, 1, GL_TRUE, @ViewMat);
  glUniform1f(FRendLoc_ParticleScale, FParticleScale);
  // Atlas uniform: enable + bind texture if we have one
  if (FAtlasTexID <> 0) and (FRendLoc_AtlasEnabled >= 0) then
  begin
    glUniform1i(FRendLoc_AtlasEnabled, 1);
    if FRendLoc_AtlasSampler >= 0 then
      glUniform1i(FRendLoc_AtlasSampler, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, FAtlasTexID);
  end
  else if FRendLoc_AtlasEnabled >= 0 then
  begin
    glUniform1i(FRendLoc_AtlasEnabled, 0);
  end;
  // Draw 6 vertices (quad) per instance
  glBindVertexArray(FBillboardVAO);
  glDrawArraysInstanced(GL_TRIANGLES, 0, 6, NumInstances);
  { Clean unbind of the custom VAO so Raylib's batcher doesn't accidentally
    write into our vertex attributes. The SSBO bindings (0,1,2,3,6) we leave
    bound - they will be re-bound by the next compute dispatch or overwritten
    by Raylib's own batcher, and unbinding 5 SSBOs per frame costs more
    driver overhead than it saves. The performance-critical fullscreen path
    does compute->draw->EndDrawing, and unnecessary glBindBufferBase calls
    showed up in profiling on the Ryzen 4500U iGPU driver. }
  glBindVertexArray(0);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glUseProgram(0);
  { BUG FIX #2: Restore Raylib's rlgl state cache so DrawText and the 2D
    batcher work again afterwards. We do NOT call rlSetShader (it was the
    source of the font-atlas corruption). rlEnableShader + rlActiveTextureSlot
    + rlSetTexture is the correct sequence to sync the cache with the real
    OpenGL state. }
  rlEnableShader(rlGetShaderIdDefault());
  rlActiveTextureSlot(0);
  rlSetTexture(rlGetTextureIdDefault());
  rlDrawRenderBatchActive;
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);  // Restore default blend func
  glDisable(GL_BLEND);
  glDepthMask(1);
  glEnable(GL_DEPTH_TEST);  // Re-enable depth test for next Raylib pass
  glEnable(GL_CULL_FACE);
  { glGetError forces a pipeline flush - skip it on every frame for speed.
    Only call it when we have a real reason to suspect a GL error. The
    debug-check was useful during development but costs ~0.2ms/frame in
    fullscreen, which is enough to drop below 60fps on the Ryzen iGPU. }
  {$IFDEF YUTANI_GL_DEBUG}
  glErr := glGetError();
  if glErr <> GL_NO_ERROR then
    OutputDebugStringA(PAnsiChar(AnsiString(Format(
      'Yutani GPU: GL error after draw = 0x%x', [glErr]))));
  {$ENDIF}
end;

{ === Public lifecycle === }

procedure TYutaniParticleEngine.Initialise;
begin
  if FGPUInitialized then Exit;
  FLock.Acquire;
  try InitGPUResources;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.Update(const ADeltaTime: Single);
var
  I, J: Integer;
  E: TYutaniEmitterData;
  ExpireList: array of Integer;
  ExpireCount: Integer;
  HasMatEmitter, HasDematEmitter: Boolean;
  MatEmitterID: Integer;
  MatArrived, MatTotal: Integer;
  CubeSize: Single;
begin
  if not FGPUInitialized then InitGPUResources;
  if FNumParticles = 0 then Exit;
  FLock.Acquire;
  try
    { Sync pending changes to the GPU. The engine thread owns the GL context,
      so all sync calls happen here (never in the VCL thread).
      - FFullResyncNeeded: ClearEmitters was called - sync ALL particles.
        Safe because ClearEmitters kills every slot first, so no live
        particle gets its position reset.
      - FPendingSpawnCount > 0: AddEmitter/RemoveEmitter/Auto-Expire spawned
        or killed some particles - sync ONLY those slots to preserve compute
        results for already-running particles.
      - FPendingMetaCount > 0: CompactEmitters/RemoveEmitter renumbered some
        emitter IDs - sync ONLY the Meta SSBO for those slots, NOT positions,
        because the CPU mirror's positions are stale (compute shader only
        updates the GPU, not the CPU). This is the fix for the bug where a
        running particle "jumped back to spawn and started over" when the
        next emitter was added. }
    if FFullResyncNeeded then
    begin
      SyncCPUParticlesToGPU;
      FFullResyncNeeded := False;
    end
    else
    begin
      if FPendingSpawnCount > 0 then SyncPendingSlots;
      if FPendingMetaCount > 0   then SyncPendingMetaSlots;
    end;
    if FEmittersDirty then SyncEmittersToGPU;
    if FPhysicsBridge <> nil then SyncCollidersToGPU;
    FTime := FTime + ADeltaTime;
    DispatchCompute(ADeltaTime);

    { === Solid-cube tracking for Materialize / Dematerialize ===
      Materialize: while the swarm is flying toward the target the cube is
        NOT yet shown. Once every Mat-particle has arrived (target.w >= 0.5
        in the GPU), the swarm is replaced by a single SolidCube and the
        Mat-emitter is killed. This matches the original CPU engine, where
        "SolidCubeReady" was set only when the last (top-layer) particle
        reached its target.
      Dematerialize: the cube is created IMMEDIATELY when the Demat emitter
        starts (so the player sees a solid cube while the swarm fills its
        voxel grid). Once every Demat-particle has sunk below FloorY the
        cube is removed - that is the "cube weg" the user asked for. }
    HasMatEmitter := False;
    HasDematEmitter := False;
    MatEmitterID := -1;
    for I := 0 to FNumEmitters - 1 do
    begin
      E := FEmitters[I];
      if (E.ParticleCount > 0) and E.IsMaterialize then
      begin
        HasMatEmitter := True;
        MatEmitterID := I;
      end;
      if (E.ParticleCount > 0) and E.IsDematerialize then
      begin
        HasDematEmitter := True;
        // The Demat swarm dismantles a solid cube - make sure that cube
        // exists from frame one so the player sees it while the swarm fills
        // its voxel grid. FromMat=False marks it for removal the moment the
        // Demat swarm is gone. Cube size matches the Materialize cube so a
        // Mat cube (still standing) and a Demat cube at the same position
        // dedupe via FindSolidCubeFor instead of stacking two cubes.
        CubeSize := 0.9;
        if E.StartSize > 0 then CubeSize := E.StartSize * 10.0;
        if CubeSize > 0.95 then CubeSize := 0.95;
        if not FindSolidCubeFor(E.Origin, CubeSize) then
          PushSolidCube(E.Origin, CubeSize, E.StartColor, False)
        else
          // Cube already exists (was built by Materialize). Flip its
          // ownership to Demat so the Auto-Expire will remove it.
          MarkSolidCubeForDemat(E.Origin, CubeSize);
      end;
    end;

    { Read back GPU target.w values when there is a live Mat emitter so we
      can detect arrival. The buffer is allocated lazily. To keep the per-frame
      cost down we read back only every few frames; a Mat swarm takes well
      over 100 ms to assemble so sampling at 50 ms granularity is plenty. }
    FReadbackAccum := FReadbackAccum + ADeltaTime;
    if HasMatEmitter and (FSSBO_Targets <> 0) and (FReadbackAccum >= 0.05) then
    begin
      FReadbackAccum := 0.0;
      if Length(FReadbackTargets) < FNumParticles then
        SetLength(FReadbackTargets, FNumParticles);
      glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Targets);
      glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
        FNumParticles * SizeOf(TVector4), @FReadbackTargets[0]);
      glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);

      MatArrived := 0;
      MatTotal := 0;
      for J := 0 to FNumParticles - 1 do
        if Trunc(FCPU_Meta[J].y) = MatEmitterID then
        begin
          Inc(MatTotal);
          if FReadbackTargets[J].w >= 0.5 then Inc(MatArrived);
        end;

      // 3D-printer build: the cube appears the moment the TOP layer (last to
      // finish its spawn delay) snaps into existence. The CPU knows the exact
      // max spawn delay (0.8s for the top Y-layer, see EmitMaterializeCube),
      // so we trigger on time elapsed since spawn. 0.81s = 0.8s top-layer
      // delay + 10ms grace for one readback tick. This makes the cube appear
      // in the same frame the top layer finishes - "zack, cube da", like a
      // beam effect.
      if (FTime - FSpawnTimes[MatEmitterID] >= 0.81) then
      begin
        E := FEmitters[MatEmitterID];
        // Cube edge length is 10 voxels * StartSize, capped at 0.95 so it
        // matches the default 0.1 voxel / 10x10x10 grid (= 0.9).
        CubeSize := 0.9;
        if E.StartSize > 0 then CubeSize := E.StartSize * 10.0;
        if CubeSize > 0.95 then CubeSize := 0.95;
        PushSolidCube(E.Origin, CubeSize, E.StartColor, True);
        // Kill all Mat-particles of this emitter so the swarm vanishes and
        // only the solid cube remains.
        for J := 0 to FNumParticles - 1 do
          if Trunc(FCPU_Meta[J].y) = MatEmitterID then
          begin
            FCPU_Positions[J].w := 0.0;
            FCPU_Meta[J].y := -1.0;
            if FPendingSpawnCount < Length(FPendingSpawnSlots) then
            begin
              FPendingSpawnSlots[FPendingSpawnCount] := J;
              Inc(FPendingSpawnCount);
            end;
          end;
        FEmitters[MatEmitterID].ParticleCount := 0;
        CompactEmitters;
      end;
    end;

    { Dematerialize cleanup is now handled by the Auto-Expire block below
      (RemoveSolidCube is called when the Demat emitter is expired). The
      CPU-side AliveDemat check used to be unreliable because the compute
      shader never writes the dead state back to FCPU_Meta, so the count
      never reached 0. The Auto-Expire fires reliably MaxLife + 2.0s after
      spawn - by that time every Demat particle has sunk to the floor. }

    // === Auto-remove expired one-shot emitters ===
    if FNumEmitters > 0 then
    begin
      ExpireCount := 0;
      SetLength(ExpireList, FNumEmitters);
      for I := 0 to FNumEmitters - 1 do
      begin
        E := FEmitters[I];
        if (E.LifeMode = lmOneShotAutoRemove) then
        begin
          // For Demat the cube must vanish as soon as the swarm has sunk
          // (not after the full MaxLife + 2.0s grace). The Demat swarm timing
          // is: max hold (0.8s) + sink (0.9m / 4 m/s = 0.225s) ~= 1.025s. We
          // give 1.3s so the bottom layer is safely gone. For Mat/other
          // one-shots keep the original MaxLife + 2.0s grace.
          if E.IsDematerialize then
          begin
            if (FTime - FSpawnTimes[I]) >= 1.3 then
            begin
              ExpireList[ExpireCount] := I;
              Inc(ExpireCount);
            end;
          end
          else
          begin
            if (FTime - FSpawnTimes[I]) >= (E.MaxLife + 2.0) then
            begin
              ExpireList[ExpireCount] := I;
              Inc(ExpireCount);
            end;
          end;
        end;
      end;
      for I := ExpireCount - 1 downto 0 do
      begin
        if Assigned(FOnEmitterExpired) then
          FOnEmitterExpired(Self, ExpireList[I], FEmitters[ExpireList[I]]);
        // Fallback: if a Materialize emitter reaches auto-expire without
        // ever pushing a SolidCube (e.g. its particles were killed externally
        // before all arrived), still spawn the cube so the player sees the
        // finished structure. Cube size matches the Mat push logic.
        if FEmitters[ExpireList[I]].IsMaterialize then
        begin
          CubeSize := 0.9;
          if FEmitters[ExpireList[I]].StartSize > 0 then
            CubeSize := FEmitters[ExpireList[I]].StartSize * 10.0;
          if CubeSize > 0.95 then CubeSize := 0.95;
          PushSolidCube(FEmitters[ExpireList[I]].Origin, CubeSize,
            FEmitters[ExpireList[I]].StartColor, True);
        end
        else if FEmitters[ExpireList[I]].IsDematerialize then
        begin
          // Dematerialize emitter has finished its sink - remove the SolidCube
          // it was dismantling. This is the "cube weg" step: the cube must
          // disappear once the swarm has fully sunk. We can't rely on the
          // FCPU_Meta mirror because the compute shader never writes the
          // dead state back to CPU memory, so AliveDemat in the Update loop
          // never reaches 0. The Auto-Expire (MaxLife + 2.0 s after spawn)
          // is the reliable trigger that fires once every Demat particle has
          // had enough time to reach the floor.
          CubeSize := 0.9;
          if FEmitters[ExpireList[I]].StartSize > 0 then
            CubeSize := FEmitters[ExpireList[I]].StartSize * 10.0;
          if CubeSize > 0.95 then CubeSize := 0.95;
          // Remove the Demat-owned cube at this emitter's origin (FromMat=False).
          // Mat-owned cubes (FromMat=True) are kept.
          RemoveSolidCube(FEmitters[ExpireList[I]].Origin, CubeSize, False);
        end;
        for J := 0 to FNumParticles - 1 do
          if Trunc(FCPU_Meta[J].y) = ExpireList[I] then
          begin
            FCPU_Positions[J].w := 0.0;
            FCPU_Meta[J].y := -1.0;
            // CRITICAL: append this killed slot to FPendingSpawnSlots so the
            // engine thread (which owns the GL context) syncs the dead state
            // to the GPU in the next Update. Without this, the CPU mirror
            // says "dead" but the GPU SSBOs still say "alive" - the compute
            // shader keeps animating the dead particles invisibly, and when
            // the user later starts a new effect the old ghosts reappear.
            if FPendingSpawnCount < Length(FPendingSpawnSlots) then
            begin
              FPendingSpawnSlots[FPendingSpawnCount] := J;
              Inc(FPendingSpawnCount);
            end;
          end;
        FEmitters[ExpireList[I]].ParticleCount := 0;
      end;
      if ExpireCount > 0 then CompactEmitters;
    end;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.CompactEmitters;
var
  I, J: Integer;
  NewID: Integer;
begin
  NewID := 0;
  for I := 0 to FNumEmitters - 1 do
  begin
    if FEmitters[I].ParticleCount <= 0 then Continue;
    if I <> NewID then
    begin
      FEmitters[NewID] := FEmitters[I];
      FSpawnTimes[NewID] := FSpawnTimes[I];
      for J := 0 to FNumParticles - 1 do
        if Trunc(FCPU_Meta[J].y) = I then
        begin
          FCPU_Meta[J].y := Single(NewID);
          // Collect this renumbered slot for META-ONLY sync. We must NOT do a
          // full SyncCPUParticlesToGPU here: the CPU mirror's positions are
          // stale (the compute shader has been advancing the GPU positions
          // independently), so a full sync would push the old spawn-time
          // positions back to the GPU and running particles would visibly
          // snap back to their birthplace. Syncing ONLY the Meta SSBO updates
          // the emitterID on the GPU without touching live position/velocity.
          if FPendingMetaCount < Length(FPendingMetaSlots) then
          begin
            FPendingMetaSlots[FPendingMetaCount] := J;
            Inc(FPendingMetaCount);
          end;
        end;
    end;
    Inc(NewID);
  end;
  FNumEmitters := NewID;
  for I := NewID to YUTANI_MAX_EMITTERS - 1 do
    FillChar(FEmitters[I], SizeOf(TYutaniEmitterData), 0);
  FEmittersDirty := True;
  FCPU_Dirty := True;
  // NOTE: No OpenGL sync and NO FFullResyncNeeded here - the renumbered
  // slots are in FPendingMetaSlots and will be Meta-only synced by the
  // engine thread in the next Update.
end;

procedure TYutaniParticleEngine.Render(const ACamera: TCamera3D);
var
  NumInstances: Integer;
  RW, RH: Integer;
  I: Integer;
  C: TSolidCube;
begin
  if not FGPUInitialized then InitGPUResources;
  NumInstances := Trunc(FInstancesX1000 / 1000.0 * FNumParticles);
  FLock.Acquire;
  try
    { Sync the GL viewport to the current Raylib framebuffer. Raylib normally
      does this itself, but when the window is embedded as a child of a VCL
      panel and resized by the VCL thread (FormResize -> SetDimensions),
      Raylib can miss the WM_SIZE message and the GL viewport stays at the
      old small size. The visible symptom is the engine rendering at e.g.
      800x600 and Windows stretching it to fullscreen. Querying the actual
      Raylib framebuffer size here is cheap and guarantees correctness. }
    RW := GetScreenWidth();
    RH := GetScreenHeight();
    if (RW > 0) and (RH > 0) then
      rlViewport(0, 0, RW, RH);
    DrawInstances(NumInstances, ACamera);
    { Draw solid cubes AFTER the particle pass so the opaque cube cleanly
      replaces the swarm where Materialize has completed or where Demat is
      currently dismantling a cube. Uses Raylib's DrawCube (depth-tested,
      opaque, no blend). }
    RenderSolidCubes;
  finally FLock.Release; end;
end;

{ === Solid-cube overlay helpers === }

procedure TYutaniParticleEngine.PushSolidCube(const APos: TVector3;
  ASize: Single; AColor: TColorB; AFromMat: Boolean);
var
  N: Integer;
begin
  if FindSolidCubeFor(APos, ASize) then Exit;
  N := Length(FSolidCubes);
  SetLength(FSolidCubes, N + 1);
  FSolidCubes[N].Active := True;
  FSolidCubes[N].Position := APos;
  FSolidCubes[N].Size := ASize;
  FSolidCubes[N].Color := AColor;
  FSolidCubes[N].FromMat := AFromMat;
end;

function TYutaniParticleEngine.FindSolidCubeFor(const APos: TVector3;
  ASize: Single): Boolean;
var
  I: Integer;
  C: TSolidCube;
begin
  Result := False;
  for I := 0 to High(FSolidCubes) do
  begin
    C := FSolidCubes[I];
    if (Abs(C.Position.x - APos.x) < 0.01) and
       (Abs(C.Position.y - APos.y) < 0.01) and
       (Abs(C.Position.z - APos.z) < 0.01) and
       (Abs(C.Size - ASize) < 0.01) then
      Exit(True);
  end;
end;

procedure TYutaniParticleEngine.RemoveSolidCube(const APos: TVector3;
  ASize: Single; AFromMatFlag: Boolean);
var
  I, J: Integer;
  C: TSolidCube;
begin
  for I := 0 to High(FSolidCubes) do
  begin
    C := FSolidCubes[I];
    if C.FromMat = AFromMatFlag then
      if (Abs(C.Position.x - APos.x) < 0.05) and
         (Abs(C.Position.y - APos.y) < 0.05) and
         (Abs(C.Position.z - APos.z) < 0.05) and
         (Abs(C.Size - ASize) < 0.1) then
      begin
        // Shift remaining cubes down by one to keep the array compact.
        for J := I to High(FSolidCubes) - 1 do
          FSolidCubes[J] := FSolidCubes[J + 1];
        SetLength(FSolidCubes, High(FSolidCubes));
        Exit;
      end;
  end;
end;

procedure TYutaniParticleEngine.MarkSolidCubeForDemat(const APos: TVector3;
  ASize: Single);
var
  I: Integer;
  C: TSolidCube;
begin
  for I := 0 to High(FSolidCubes) do
  begin
    C := FSolidCubes[I];
    if (Abs(C.Position.x - APos.x) < 0.05) and
       (Abs(C.Position.y - APos.y) < 0.05) and
       (Abs(C.Position.z - APos.z) < 0.05) and
       (Abs(C.Size - ASize) < 0.1) then
    begin
      // Demat button click: the cube disappears IMMEDIATELY so the player
      // sees the swarm take over (fill phase -> sink phase). The Demat
      // particles are already spawned at the cube's voxels and visible, so
      // removing the solid cube here does not leave a gap. We also flip
      // FromMat to False so a later Auto-Expire cleanup of the same slot
      // is consistent.
      FSolidCubes[I].Active := False;
      FSolidCubes[I].FromMat := False;
      Exit;
    end;
  end;
end;

procedure TYutaniParticleEngine.RenderSolidCubes;
var
  I: Integer;
  C: TSolidCube;
begin
  for I := 0 to High(FSolidCubes) do
  begin
    C := FSolidCubes[I];
    if not C.Active then Continue;
    DrawCube(C.Position, C.Size, C.Size, C.Size, C.Color);
  end;
end;

procedure TYutaniParticleEngine.Restart;
begin
  FLock.Acquire;
  try FTime := 0;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.Reset;
begin
  FLock.Acquire;
  try
    FTime := 0; FTimeScale := 1.0; FParticleScale := 1.0;
    FInstancesX1000 := 100.0; FBlendMode := bmAlpha;
    FGlobalWind := Vector3Create(0, 0, 0);
    FGlobalGravity := Vector3Create(0, 0, 0);
    FHDRMultiplier := 1.0;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SetPush(const APos: TVector3;
  ARadius, AStrength: Single);
begin
  FLock.Acquire;
  try
    FPushPos := APos;
    FPushRadius := ARadius;
    FPushStrength := AStrength;
    FPushActive := True;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.ClearPush;
begin
  FLock.Acquire;
  try FPushActive := False;
  finally FLock.Release; end;
end;

{ === Global forces / blend mode / atlas === }

procedure TYutaniParticleEngine.SetGlobalWind(const AWind: TVector3);
begin
  FLock.Acquire;
  try FGlobalWind := AWind;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SetGlobalGravity(const AGravity: TVector3);
begin
  FLock.Acquire;
  try FGlobalGravity := AGravity;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SetHDRMultiplier(AMultiplier: Single);
begin
  FLock.Acquire;
  try FHDRMultiplier := AMultiplier;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SetBlendMode(AMode: TYutaniBlendMode);
begin
  FLock.Acquire;
  try FBlendMode := AMode;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SetSpriteAtlas(const ATexture: TTexture2D);
begin
  SetSpriteAtlas(ATexture.id);
end;

procedure TYutaniParticleEngine.SetSpriteAtlas(ATextureID: Cardinal);
begin
  FLock.Acquire;
  try
    FAtlasTexID := ATextureID;
    if ATextureID <> 0 then FAtlasEnabled := 1
                      else FAtlasEnabled := 0;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.ClearSpriteAtlas;
begin
  FLock.Acquire;
  try
    FAtlasTexID := 0;
    FAtlasEnabled := 0;
  finally FLock.Release; end;
end;

{ === Physics-Bridge === }

procedure TYutaniParticleEngine.SetPhysicsBridge(const ABridge: IParticlePhysicsBridge);
begin
  FLock.Acquire;
  try FPhysicsBridge := ABridge;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SetPhysicsSampleRate(ARate: Integer);
begin
  if ARate < 0 then ARate := 0;
  FLock.Acquire;
  try FPhysicsSampleRate := ARate;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.SyncCollidersToGPU;
var
  Bridge: IParticlePhysicsBridge;
  Buf: array[0..63] of TVector4; // 32 AABB pairs * 2 = 64 vec4 max
  Count, I: Integer;
  Src: PColliderAABB;
begin
  if not FGPUInitialized then Exit;
  FCurrentColliderCount := 0;
  Bridge := FPhysicsBridge;
  if Bridge = nil then Exit;
  Count := Bridge.GetColliders(Src, FPhysicsMaxColliders);
  if Count <= 0 then Exit;
  if Count > FPhysicsMaxColliders then Count := FPhysicsMaxColliders;
  for I := 0 to Count - 1 do
  begin
    Buf[I*2 + 0].x := Src[I].Min.x;
    Buf[I*2 + 0].y := Src[I].Min.y;
    Buf[I*2 + 0].z := Src[I].Min.z;
    Buf[I*2 + 0].w := Src[I].Restitution;
    Buf[I*2 + 1].x := Src[I].Max.x;
    Buf[I*2 + 1].y := Src[I].Max.y;
    Buf[I*2 + 1].z := Src[I].Max.z;
    Buf[I*2 + 1].w := 0.0;
  end;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Colliders);
  glBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    Count * 2 * SizeOf(TVector4), @Buf[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  FCurrentColliderCount := Count;
end;

{ === Impact ring buffer (CPU readback for puddle system) === }

function TYutaniParticleEngine.GetImpactBuffer: Pointer;
begin
  Result := nil;
  if not FGPUInitialized then Exit;
  if FSSBO_Impacts = 0 then Exit;
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Impacts);
  glGetBufferSubData(GL_SHADER_STORAGE_BUFFER, 0,
    FImpactMax * SizeOf(TVector4), @FLastImpactBuffer[0]);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  Result := @FLastImpactBuffer[0];
end;

function TYutaniParticleEngine.GetImpactCount: Integer;
begin
  Result := FImpactMax;
end;

procedure TYutaniParticleEngine.AdvanceImpactWriteIdx;
begin
  FImpactWriteIdx := (FImpactWriteIdx + FImpactMax div 2) mod FImpactMax;
end;

function TYutaniParticleEngine.GetActiveInstanceCount: Integer;
begin
  Result := Trunc(FInstancesX1000 / 1000.0 * FNumParticles);
end;

function TYutaniParticleEngine.GetEmitterProp(Idx: Integer): TYutaniEmitterData;
begin
  if (Idx < 0) or (Idx >= FNumEmitters) then
  begin
    FillChar(Result, SizeOf(TYutaniEmitterData), 0);
    Exit;
  end;
  Result := FEmitters[Idx];
end;

{ === Emitter API === }

function TYutaniParticleEngine.AddEmitter(const AData: TYutaniEmitterData): Integer;
var
  Data: TYutaniEmitterData;
begin
  if FNumEmitters >= YUTANI_MAX_EMITTERS then
  begin
    Result := -1;
    Exit;
  end;
  Data := AData;
  // ParticleCount <= 0 means "do not auto-spawn" - the caller is responsible
  // for setting up particle slots itself (used by EmitMaterializeCube /
  // EmitDematerializeCube / EmitMaterializeMesh / EmitDematerializeMesh which
  // need bespoke per-particle voxel positions, not the generic respawnParticle
  // shape). Without this escape hatch, AddEmitter would spawn a default set of
  // 1024 particles here AND the caller would spawn another 1000 with the real
  // voxel positions - resulting in 2000 particles, half of them flying to the
  // origin (0,0,0) because their target vec4 was left zeroed. We still clamp a
  // positive count to FNumParticles below for the normal API path.
  if Data.ParticleCount > FNumParticles then Data.ParticleCount := FNumParticles;
  FLock.Acquire;
  try
    Result := FNumEmitters;
    FEmitters[FNumEmitters] := Data;
    FSpawnTimes[FNumEmitters] := FTime;  // record when this emitter was born
    Inc(FNumEmitters);
    if Data.ParticleCount > 0 then
      AssignParticlesToEmitter(Result, Data);  // appends to FPendingSpawnSlots
    FEmittersDirty := True;
    // NOTE: No OpenGL sync here - the VCL thread doesn't own the GL context.
    // The engine thread will sync the pending slots in the next Update.
  finally FLock.Release; end;
end;

function TYutaniParticleEngine.RemoveEmitter(EmitterID: Integer): Boolean;
var
  I, J: Integer;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    for I := 0 to FNumParticles - 1 do
    begin
      if Trunc(FCPU_Meta[I].y) = EmitterID then
      begin
        FCPU_Positions[I].w := 0.0;
        FCPU_Meta[I].y := -1.0;
        // Append to pending spawn slots so the engine thread syncs this
        // dead slot to the GPU in the next Update.
        if FPendingSpawnCount < Length(FPendingSpawnSlots) then
        begin
          FPendingSpawnSlots[FPendingSpawnCount] := I;
          Inc(FPendingSpawnCount);
        end;
      end;
    end;
    for I := EmitterID to FNumEmitters - 2 do
    begin
      FEmitters[I] := FEmitters[I + 1];
      FSpawnTimes[I] := FSpawnTimes[I + 1];
      for J := 0 to FNumParticles - 1 do
        if Trunc(FCPU_Meta[J].y) = (I + 1) then
        begin
          FCPU_Meta[J].y := Single(I);
          // Collect renumbered slot for META-ONLY sync (same rationale as in
          // CompactEmitters): only the Meta SSBO needs the new emitterID on
          // the GPU - the live position/velocity must NOT be overwritten by
          // the stale CPU mirror, otherwise running particles snap back.
          if FPendingMetaCount < Length(FPendingMetaSlots) then
          begin
            FPendingMetaSlots[FPendingMetaCount] := J;
            Inc(FPendingMetaCount);
          end;
        end;
    end;
    Dec(FNumEmitters);
    FillChar(FEmitters[FNumEmitters], SizeOf(TYutaniEmitterData), 0);
    FCPU_Dirty := True;
    FEmittersDirty := True;
    // NOTE: No OpenGL sync here - VCL thread doesn't own GL context.
    Result := True;
  finally FLock.Release; end;
end;

procedure TYutaniParticleEngine.ClearEmitters;
var I: Integer;
begin
  FLock.Acquire;
  try
    FNumEmitters := 0;
    for I := 0 to FNumParticles - 1 do
    begin
      FCPU_Positions[I].w := 0.0;
      FCPU_Meta[I].y := -1.0;
    end;
    FCPU_Dirty := True;
    FEmittersDirty := True;
    FPendingSpawnCount := 0;       // pending slot list is now stale - drop it
    FPendingMetaCount := 0;         // ... and the meta-only list too
    FFullResyncNeeded := True;     // force a full resync in the next Update
    // Solid cubes belong to the materialize/dematerialize effect - clear them
    // too so a fresh scene does not show stale cubes from a previous run.
    SetLength(FSolidCubes, 0);
    // NOTE: No OpenGL sync here - VCL thread doesn't own GL context.
  finally FLock.Release; end;
end;

function TYutaniParticleEngine.GetEmitterCount: Integer;
begin
  Result := FNumEmitters;
end;

function TYutaniParticleEngine.GetEmitter(EmitterID: Integer;
  out AEmitter: TYutaniEmitterData): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then
  begin
    AEmitter := MakeEmitterData;
    Exit;
  end;
  AEmitter := FEmitters[EmitterID];
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterActive(EmitterID: Integer;
  AActive: Boolean): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].Active := AActive;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterOrigin(EmitterID: Integer;
  const AOrigin: TVector3): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].Origin := AOrigin;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterRegion(EmitterID: Integer;
  const ARegionMin, ARegionMax: TVector3): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].RegionMin := ARegionMin;
    FEmitters[EmitterID].RegionMax := ARegionMax;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterStartColor(EmitterID: Integer;
  const AColor: TColorB): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].StartColor := AColor;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterEndColor(EmitterID: Integer;
  const AColor: TColorB): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].EndColor := AColor;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterGlow(EmitterID: Integer;
  AGlow: Single): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].Glow := AGlow;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterTrailStrength(EmitterID: Integer;
  AStrength: Single): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].TrailStrength := AStrength;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterUseColorOverride(EmitterID: Integer;
  AUse: Boolean): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].UseColorOverride := AUse;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterLifeMode(EmitterID: Integer;
  AMode: TYutaniLifeMode): Boolean;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    FEmitters[EmitterID].LifeMode := AMode;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

function TYutaniParticleEngine.SetEmitterFromTo(EmitterID: Integer;
  const AFromPos, AToPos: TVector3): Boolean;
var
  RegionMin, RegionMax: TVector3;
begin
  Result := False;
  if (EmitterID < 0) or (EmitterID >= FNumEmitters) then Exit;
  FLock.Acquire;
  try
    // RegionMin/RegionMax form a small cube around FromPos so spawn area
    // is localized there. Origin = FromPos. ToPos is stored in the targets
    // SSBO per-particle (only relevant for materialize emitters).
    RegionMin.x := AFromPos.x - 0.1; RegionMin.y := AFromPos.y - 0.1;
    RegionMin.z := AFromPos.z - 0.1;
    RegionMax.x := AToPos.x;         RegionMax.y := AToPos.y;
    RegionMax.z := AToPos.z;
    FEmitters[EmitterID].RegionMin := RegionMin;
    FEmitters[EmitterID].RegionMax := RegionMax;
    FEmitters[EmitterID].Origin := AFromPos;
    FEmittersDirty := True;
    // No sync here - engine thread syncs in next Update
  finally FLock.Release; end;
  Result := True;
end;

{ === Materialize / Dematerialize presets ===
  These create emitters with the IsMaterialize / IsDematerialize flags set.
  Per-particle targets are stored in the targets SSBO. Per-particle spawn
  delays are stored in meta[].w so the cube builds bottom-to-top. }

procedure TYutaniParticleEngine.EmitMaterializeCube(const TargetPos: TVector3;
  const Color: TColorB; VoxelSize: Single);
var
  Data: TYutaniEmitterData;
  EmitID: Integer;
  I, J, K, Idx, Found: Integer;
  Slots: array of Integer;
  VX, VY, VZ: Single;
  LowestY, HeightRange: Single;
  TargetMin, TargetMax: TVector3;
begin
  if VoxelSize <= 0 then VoxelSize := 0.1;
  Data := MakeEmitterData;
  Data.SpawnShape := ssBox;
  TargetMin.x := TargetPos.x - 0.45;
  TargetMin.y := TargetPos.y - 0.45;
  TargetMin.z := TargetPos.z - 0.45;
  TargetMax.x := TargetPos.x + 0.45;
  TargetMax.y := TargetPos.y + 0.45;
  TargetMax.z := TargetPos.z + 0.45;
  Data.Origin := TargetPos;
  Data.RegionMin := TargetMin;
  Data.RegionMax := TargetMax;
  Data.StartColor := Color;
  Data.EndColor := Color;
  Data.StartSize := VoxelSize;
  Data.EndSize := VoxelSize;
  Data.IsMaterialize := True;
  // Use lmOneShotAutoRemove so the emitter is removed once its particles die,
  // instead of lmBurst which leaves the (immortal, 99999-life) particles
  // frozen at the target forever - the user pressing Dematerialize would then
  // see the old materialized cube "still there" on top of the new effect.
  // MaxLife=3s is a fallback: the Readback-based 95% arrival check normally
  // replaces the swarm with a SolidCube well within 1s; if for some reason
  // the readback never triggers, the Auto-Expire at MaxLife + 2.0 = 5.0s
  // fires the SolidCube push as a safety net.
  Data.LifeMode := lmOneShotAutoRemove;
  Data.MinLife := 3.0;
  Data.MaxLife := 3.0;
  Data.ParticleCount := 0;  // do NOT auto-spawn; we set voxel positions below
  Data.Name := 'MatCube';
  EmitID := AddEmitter(Data);
  if EmitID < 0 then Exit;
  Data.ParticleCount := 1000;  // restore for the manual spawn below
  // CRITICAL: write the real ParticleCount back to the emitter record. The
  // Update loop's HasMatEmitter check is "(E.ParticleCount > 0) and
  // E.IsMaterialize" - if we leave it at 0 (the value AddEmitter stored), the
  // readback block is never entered and the SolidCube only appears via the
  // 5-second Auto-Expire fallback. Setting it here makes the readback fire on
  // the very first Update tick after spawn, so the cube appears the moment the
  // top layer's spawn delay expires (0.8s) - no extra wait.
  FEmitters[EmitID].ParticleCount := 1000;

  // Now override the per-particle CPU state with the cube voxel positions
  // and the per-particle target + spawn delay.
  LowestY := TargetMin.y;
  HeightRange := TargetMax.y - TargetMin.y;
  if HeightRange <= 0.001 then HeightRange := 1.0;
  SetLength(Slots, 1000);
  FLock.Acquire;
  try
    Found := FindFreeParticleSlots(1000, PIntegerArray(@Slots[0]));
    if Found < 1000 then
      OutputDebugStringA(PAnsiChar(AnsiString(Format(
        'Yutani GPU EmitMaterializeCube: only %d free slots (need 1000)', [Found]))));
    for I := 0 to Found - 1 do
    begin
      Idx := Slots[I];
      K := I mod 10;
      J := (I div 10) mod 10;
      VX := TargetPos.x + (K * VoxelSize) - 0.45 + (VoxelSize * 0.5);
      VY := TargetPos.y + (J * VoxelSize) - 0.45 + (VoxelSize * 0.5);
      VZ := TargetPos.z + ((I div 100) * VoxelSize) - 0.45 + (VoxelSize * 0.5);
      // 3D-printer look: particles appear DIRECTLY at their target voxel,
      // not in a random cloud around the cube. The voxel is invisible while
      // its layer's spawnDelay counts down, then snaps to visible at the
      // target position. No fly-in - this is "schicht fuer schicht aufbauen".
      FCPU_Positions[Idx].x := VX;
      FCPU_Positions[Idx].y := VY;
      FCPU_Positions[Idx].z := VZ;
      FCPU_Positions[Idx].w := 1.0;
      FCPU_Velocities[Idx].x := 0;
      FCPU_Velocities[Idx].y := 0;
      FCPU_Velocities[Idx].z := 0;
      FCPU_Velocities[Idx].w := 0.0; // age = 0 (count up from spawn)
      FCPU_Colors[Idx].x := Color.r / 255.0;
      FCPU_Colors[Idx].y := Color.g / 255.0;
      FCPU_Colors[Idx].z := Color.b / 255.0;
      FCPU_Colors[Idx].w := 0.0;  // invisible during spawn delay
      FCPU_Meta[Idx].x := VoxelSize;
      FCPU_Meta[Idx].y := Single(EmitID);
      FCPU_Meta[Idx].z := 99999.0;
      // Spawn delay per layer: bottom layer 0s, top layer 0.8s. This is the
      // 3D-printer "schicht fuer schicht" build: each Y-layer of voxels
      // snaps into existence when its delay expires, building the cube from
      // the ground up. Once the top layer (delay=0.8) is done the readback
      // sees 95% arrived and replaces the swarm with a SolidCube. 0.8s
      // matches the Demat dismantle duration so both effects feel equally
      // slow and symmetric.
      FCPU_Meta[Idx].w := ((VY - LowestY) / HeightRange) * 0.8; // bottom-up delay
      FCPU_Targets[Idx].x := VX;
      FCPU_Targets[Idx].y := VY;
      FCPU_Targets[Idx].z := VZ;
      FCPU_Targets[Idx].w := 0.0;  // not arrived
    end;
    FCPU_Dirty := True;
    // Append to pending spawn slots so engine thread syncs these to GPU
    for I := 0 to Found - 1 do
      if FPendingSpawnCount < Length(FPendingSpawnSlots) then
      begin
        FPendingSpawnSlots[FPendingSpawnCount] := Slots[I];
        Inc(FPendingSpawnCount);
      end;
    // NOTE: No OpenGL sync here - VCL thread doesn't own GL context.
  finally
    FLock.Release;
    SetLength(Slots, 0);
  end;
end;

procedure TYutaniParticleEngine.EmitMaterializeCube(const TargetPos: TVector3;
  VoxelSize: Single);
begin
  EmitMaterializeCube(TargetPos, ColorAlpha(BLUE, 255), VoxelSize);
end;

procedure TYutaniParticleEngine.EmitDematerializeCube(const SourcePos: TVector3;
  const Color: TColorB; VoxelSize: Single);
var
  Data: TYutaniEmitterData;
  EmitID: Integer;
  I, J, K, Idx, Found: Integer;
  Slots: array of Integer;
  VX, VY, VZ: Single;
  LowestY, HeightRange: Single;
  TargetMin, TargetMax: TVector3;
  CubeSize: Single;
begin
  if VoxelSize <= 0 then VoxelSize := 0.1;
  Data := MakeEmitterData;
  Data.SpawnShape := ssBox;
  TargetMin.x := SourcePos.x - 0.45;
  TargetMin.y := SourcePos.y - 0.45;
  TargetMin.z := SourcePos.z - 0.45;
  TargetMax.x := SourcePos.x + 0.45;
  TargetMax.y := SourcePos.y + 0.45;
  TargetMax.z := SourcePos.z + 0.45;
  Data.Origin := SourcePos;
  Data.RegionMin := TargetMin;
  Data.RegionMax := TargetMax;
  Data.StartColor := Color;
  Data.EndColor := Color;
  Data.StartSize := VoxelSize;
  Data.EndSize := VoxelSize;
  Data.IsDematerialize := True;
  Data.FloorY := TargetMin.y;  // sink down to this floor
  // lmOneShotAutoRemove so the emitter is removed once its particles die,
  // instead of lmBurst leaving the cube forever. Top layer has 0 hold,
  // bottom layer ~0.5s; sinking speed is -4.0 m/s over ~0.9m = ~0.23s per
  // layer. MaxLife=2.5s gives enough headroom for the bottom layer to finish
  // sinking (0.5s hold + 0.23s sink = 0.73s total per particle), and the
  // Auto-Expire then fires at MaxLife + 2.0 = 4.5s removing the SolidCube.
  Data.LifeMode := lmOneShotAutoRemove;
  Data.MinLife := 2.5;
  Data.MaxLife := 2.5;
  Data.ParticleCount := 0;  // do NOT auto-spawn; we set voxel positions below
  Data.Name := 'DematCube';
  EmitID := AddEmitter(Data);
  if EmitID < 0 then Exit;
  Data.ParticleCount := 1000;  // restore for the manual spawn below
  // Write the real ParticleCount back so the Update loop's HasDematEmitter
  // check ("(E.ParticleCount > 0) and E.IsDematerialize") passes immediately,
  // instead of waiting on the 5-second fallback path.
  FEmitters[EmitID].ParticleCount := 1000;

  // CRITICAL: remove the existing Materialize-built SolidCube IMMEDIATELY when
  // the Demat button is pressed - not on the next Update tick, not on
  // Auto-Expire, but right here. The Demat swarm we are about to spawn will
  // occupy the same voxel grid, so removing the solid cube now leaves no gap.
  // The Update loop's MarkSolidCubeForDemat call (a per-frame fallback) is
  // kept but is now redundant for the common case.
  CubeSize := 0.9;
  if VoxelSize > 0 then CubeSize := VoxelSize * 10.0;
  if CubeSize > 0.95 then CubeSize := 0.95;
  MarkSolidCubeForDemat(SourcePos, CubeSize);

  LowestY := TargetMin.y;
  HeightRange := TargetMax.y - TargetMin.y;
  if HeightRange <= 0.001 then HeightRange := 1.0;
  SetLength(Slots, 1000);
  FLock.Acquire;
  try
    Found := FindFreeParticleSlots(1000, PIntegerArray(@Slots[0]));
    if Found < 1000 then
      OutputDebugStringA(PAnsiChar(AnsiString(Format(
        'Yutani GPU EmitDematerializeCube: only %d free slots (need 1000)', [Found]))));
    for I := 0 to Found - 1 do
    begin
      Idx := Slots[I];
      K := I mod 10;
      J := (I div 10) mod 10;
      VX := SourcePos.x + (K * VoxelSize) - 0.45 + (VoxelSize * 0.5);
      VY := SourcePos.y + (J * VoxelSize) - 0.45 + (VoxelSize * 0.5);
      VZ := SourcePos.z + ((I div 100) * VoxelSize) - 0.45 + (VoxelSize * 0.5);
      FCPU_Positions[Idx].x := VX;
      FCPU_Positions[Idx].y := VY;
      FCPU_Positions[Idx].z := VZ;
      FCPU_Positions[Idx].w := 1.0;
      FCPU_Velocities[Idx].x := 0;
      FCPU_Velocities[Idx].y := 0;
      FCPU_Velocities[Idx].z := 0;
      FCPU_Velocities[Idx].w := 0.0;
      FCPU_Colors[Idx].x := Color.r / 255.0;
      FCPU_Colors[Idx].y := Color.g / 255.0;
      FCPU_Colors[Idx].z := Color.b / 255.0;
      FCPU_Colors[Idx].w := 1.0;
      FCPU_Meta[Idx].x := VoxelSize;
      FCPU_Meta[Idx].y := Single(EmitID);
      // metaData.z = maxLife (must be large so the "age >= maxLife" kill does
      // not fire while the particle is still in its hold or sink phase; the
      // Demat shader kills explicitly via age = maxLife + 1.0 once the floor
      // is reached).
      FCPU_Meta[Idx].z := 99999.0;
      // metaData.w = hold timer: top layer (highest VY) gets 0 so it sinks
      // first, bottom layer gets the full hold time so it sinks last. While
      // the timer runs the spawnDelay block keeps the particle frozen at its
      // cube voxel fully opaque - this is the "fill the cube" phase before the
      // dismantle begins. The 0.8s spread matches the Mat build so the two
      // effects feel symmetric and equally slow.
      FCPU_Meta[Idx].w := ((TargetMax.y - VY) / HeightRange) * 0.8;
      // Target = the particle's own cube voxel (X,Y,Z). The sink floor is
      // em.optParams.w (FloorY), read separately by the shader.
      FCPU_Targets[Idx].x := VX;
      FCPU_Targets[Idx].y := VY;
      FCPU_Targets[Idx].z := VZ;
      FCPU_Targets[Idx].w := 0.0;
    end;
    FCPU_Dirty := True;
    // Append to pending spawn slots so engine thread syncs these to GPU
    for I := 0 to Found - 1 do
      if FPendingSpawnCount < Length(FPendingSpawnSlots) then
      begin
        FPendingSpawnSlots[FPendingSpawnCount] := Slots[I];
        Inc(FPendingSpawnCount);
      end;
    // NOTE: No OpenGL sync here - VCL thread doesn't own GL context.
  finally
    FLock.Release;
    SetLength(Slots, 0);
  end;
end;

procedure TYutaniParticleEngine.EmitDematerializeCube(const SourcePos: TVector3;
  VoxelSize: Single);
begin
  EmitDematerializeCube(SourcePos, ColorAlpha(BLUE, 255), VoxelSize);
end;

procedure TYutaniParticleEngine.EmitMaterializeMesh(const TargetPos: TVector3;
  const Mesh: TMesh; const Color: TColorB);
var
  Data: TYutaniEmitterData;
  EmitID: Integer;
  I, Idx, Found, ToSpawn: Integer;
  Slots: array of Integer;
  VX, VY, VZ, OffX, OffY, OffZ: Single;
  MinY, MaxY, HeightRange: Single;
  TargetMin, TargetMax: TVector3;
begin
  if (Mesh.vertexCount = 0) or (Mesh.vertices = nil) then Exit;
  Data := MakeEmitterData;
  Data.SpawnShape := ssBox;
  MinY := Mesh.vertices[1];
  MaxY := Mesh.vertices[1];
  for I := 0 to Mesh.vertexCount - 1 do
  begin
    VY := Mesh.vertices[I * 3 + 1];
    if VY < MinY then MinY := VY;
    if VY > MaxY then MaxY := VY;
  end;
  HeightRange := MaxY - MinY;
  if HeightRange <= 0.001 then HeightRange := 1.0;
  TargetMin := Vector3Create(TargetPos.x + MinY, TargetPos.y + MinY, TargetPos.z + MinY);
  TargetMax := Vector3Create(TargetPos.x + MaxY, TargetPos.y + MaxY, TargetPos.z + MaxY);
  Data.Origin := TargetPos;
  Data.RegionMin := TargetMin;
  Data.RegionMax := TargetMax;
  Data.StartColor := Color;
  Data.EndColor := Color;
  Data.StartSize := 0.05;
  Data.EndSize := 0.05;
  Data.IsMaterialize := True;
  // lmOneShotAutoRemove so the mesh fades out once MaxLife elapses (no
  // immortal frozen particles left behind). Same rationale as the cube path.
  Data.LifeMode := lmOneShotAutoRemove;
  Data.MinLife := 4.0;
  Data.MaxLife := 4.0;
  ToSpawn := Mesh.vertexCount;
  if ToSpawn > FNumParticles then ToSpawn := FNumParticles;
  Data.ParticleCount := 0;  // do NOT auto-spawn; we set per-vertex positions below
  Data.Name := 'MatMesh';
  EmitID := AddEmitter(Data);
  if EmitID < 0 then Exit;
  Data.ParticleCount := ToSpawn;  // restore for the manual spawn below
  // Write the real ParticleCount back so HasMatEmitter fires immediately.
  FEmitters[EmitID].ParticleCount := ToSpawn;

  SetLength(Slots, ToSpawn);
  FLock.Acquire;
  try
    Found := FindFreeParticleSlots(ToSpawn, PIntegerArray(@Slots[0]));
    if Found = 0 then Exit;
    for I := 0 to Found - 1 do
    begin
      Idx := Slots[I];
      if I < Mesh.vertexCount then
      begin
        VX := Mesh.vertices[I * 3];
        VY := Mesh.vertices[I * 3 + 1];
        VZ := Mesh.vertices[I * 3 + 2];
      end
      else
      begin
        VX := 0; VY := 0; VZ := 0;
      end;
      OffX := (Random * 6.0) - 3.0;
      OffY := (Random * 6.0) - 3.0;
      OffZ := (Random * 6.0) - 3.0;
      FCPU_Positions[Idx].x := TargetPos.x + VX + OffX;
      FCPU_Positions[Idx].y := TargetPos.y + VY + OffY;
      FCPU_Positions[Idx].z := TargetPos.z + VZ + OffZ;
      FCPU_Positions[Idx].w := 1.0;
      FCPU_Velocities[Idx].x := 0;
      FCPU_Velocities[Idx].y := 0;
      FCPU_Velocities[Idx].z := 0;
      FCPU_Velocities[Idx].w := 0.0;
      FCPU_Colors[Idx].x := Color.r / 255.0;
      FCPU_Colors[Idx].y := Color.g / 255.0;
      FCPU_Colors[Idx].z := Color.b / 255.0;
      FCPU_Colors[Idx].w := 0.0;
      FCPU_Meta[Idx].x := 0.05;
      FCPU_Meta[Idx].y := Single(EmitID);
      FCPU_Meta[Idx].z := 99999.0;
      FCPU_Meta[Idx].w := ((VY - MinY) / HeightRange) * 0.3; // bottom-up delay
      FCPU_Targets[Idx].x := TargetPos.x + VX;
      FCPU_Targets[Idx].y := TargetPos.y + VY;
      FCPU_Targets[Idx].z := TargetPos.z + VZ;
      FCPU_Targets[Idx].w := 0.0;
    end;
    FCPU_Dirty := True;
    // Append to pending spawn slots so engine thread syncs these to GPU
    for I := 0 to Found - 1 do
      if FPendingSpawnCount < Length(FPendingSpawnSlots) then
      begin
        FPendingSpawnSlots[FPendingSpawnCount] := Slots[I];
        Inc(FPendingSpawnCount);
      end;
    // NOTE: No OpenGL sync here - VCL thread doesn't own GL context.
  finally
    FLock.Release;
    SetLength(Slots, 0);
  end;
end;

procedure TYutaniParticleEngine.EmitMaterializeMesh(const TargetPos: TVector3;
  const Mesh: TMesh);
begin
  EmitMaterializeMesh(TargetPos, Mesh, ColorAlpha(BLUE, 255));
end;

procedure TYutaniParticleEngine.EmitDematerializeMesh(const SourcePos: TVector3;
  const Mesh: TMesh; const Color: TColorB);
var
  Data: TYutaniEmitterData;
  EmitID: Integer;
  I, Idx, Found, ToSpawn: Integer;
  Slots: array of Integer;
  VX, VY, VZ: Single;
  MinY, MaxY, HeightRange, LowestY: Single;
  TargetMin, TargetMax: TVector3;
begin
  if (Mesh.vertexCount = 0) or (Mesh.vertices = nil) then Exit;
  Data := MakeEmitterData;
  Data.SpawnShape := ssBox;
  MinY := Mesh.vertices[1];
  MaxY := Mesh.vertices[1];
  for I := 0 to Mesh.vertexCount - 1 do
  begin
    VY := Mesh.vertices[I * 3 + 1];
    if VY < MinY then MinY := VY;
    if VY > MaxY then MaxY := VY;
  end;
  HeightRange := MaxY - MinY;
  if HeightRange <= 0.001 then HeightRange := 1.0;
  LowestY := SourcePos.y + MinY;
  TargetMin := Vector3Create(SourcePos.x + MinY, LowestY, SourcePos.z + MinY);
  TargetMax := Vector3Create(SourcePos.x + MaxY, SourcePos.y + MaxY, SourcePos.z + MaxY);
  Data.Origin := SourcePos;
  Data.RegionMin := TargetMin;
  Data.RegionMax := TargetMax;
  Data.StartColor := Color;
  Data.EndColor := Color;
  Data.StartSize := 0.05;
  Data.EndSize := 0.05;
  Data.IsDematerialize := True;
  Data.FloorY := LowestY;
  // lmOneShotAutoRemove + finite MaxLife so the dematerialized mesh is
  // cleaned up once the sink is done. Same rationale as the cube path.
  Data.LifeMode := lmOneShotAutoRemove;
  Data.MinLife := 4.0;
  Data.MaxLife := 4.0;
  ToSpawn := Mesh.vertexCount;
  if ToSpawn > FNumParticles then ToSpawn := FNumParticles;
  Data.ParticleCount := 0;  // do NOT auto-spawn; we set per-vertex positions below
  Data.Name := 'DematMesh';
  EmitID := AddEmitter(Data);
  if EmitID < 0 then Exit;
  Data.ParticleCount := ToSpawn;  // restore for the manual spawn below
  // Write the real ParticleCount back so HasMatEmitter fires immediately.
  FEmitters[EmitID].ParticleCount := ToSpawn;

  SetLength(Slots, ToSpawn);
  FLock.Acquire;
  try
    Found := FindFreeParticleSlots(ToSpawn, PIntegerArray(@Slots[0]));
    if Found = 0 then Exit;
    for I := 0 to Found - 1 do
    begin
      Idx := Slots[I];
      if I < Mesh.vertexCount then
      begin
        VX := Mesh.vertices[I * 3];
        VY := Mesh.vertices[I * 3 + 1];
        VZ := Mesh.vertices[I * 3 + 2];
      end
      else
      begin
        VX := 0; VY := 0; VZ := 0;
      end;
      FCPU_Positions[Idx].x := SourcePos.x + VX;
      FCPU_Positions[Idx].y := SourcePos.y + VY;
      FCPU_Positions[Idx].z := SourcePos.z + VZ;
      FCPU_Positions[Idx].w := 1.0;
      FCPU_Velocities[Idx].x := 0;
      FCPU_Velocities[Idx].y := 0;
      FCPU_Velocities[Idx].z := 0;
      FCPU_Velocities[Idx].w := 0.0;
      FCPU_Colors[Idx].x := Color.r / 255.0;
      FCPU_Colors[Idx].y := Color.g / 255.0;
      FCPU_Colors[Idx].z := Color.b / 255.0;
      FCPU_Colors[Idx].w := 1.0;
      FCPU_Meta[Idx].x := 0.05;
      FCPU_Meta[Idx].y := Single(EmitID);
      // metaData.z = maxLife (large - the Demat shader kills explicitly on
      // floor arrival, not by maxLife expiry).
      FCPU_Meta[Idx].z := 99999.0;
      // metaData.w = hold timer (top sinks first, bottom sinks last).
      FCPU_Meta[Idx].w := ((MaxY - VY) / HeightRange) * 0.5;
      // Target = the particle's own cube voxel (X,Y,Z).
      FCPU_Targets[Idx].x := SourcePos.x + VX;
      FCPU_Targets[Idx].y := SourcePos.y + VY;
      FCPU_Targets[Idx].z := SourcePos.z + VZ;
      FCPU_Targets[Idx].w := 0.0;
    end;
    FCPU_Dirty := True;
    // Append to pending spawn slots so engine thread syncs these to GPU
    for I := 0 to Found - 1 do
      if FPendingSpawnCount < Length(FPendingSpawnSlots) then
      begin
        FPendingSpawnSlots[FPendingSpawnCount] := Slots[I];
        Inc(FPendingSpawnCount);
      end;
    // NOTE: No OpenGL sync here - VCL thread doesn't own GL context.
  finally
    FLock.Release;
    SetLength(Slots, 0);
  end;
end;

procedure TYutaniParticleEngine.EmitDematerializeMesh(const SourcePos: TVector3;
  const Mesh: TMesh);
begin
  EmitDematerializeMesh(SourcePos, Mesh, ColorAlpha(BLUE, 255));
end;

end.
