unit Yutani.Chaos.Skia.GPU;

{==============================================================================*
 *  Yutani C.H.A.O.S. Skia GPU v0.2 - Holographic AI Desktop Overlay
 *------------------------------------------------------------------------------
 *  Module : Yutani.Chaos.Skia.GPU
 *  Type   : GPU-Accelerated Holographic AI Interface & Desktop Canvas
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *------------------------------------------------------------------------------
 *  Description:
 *  This unit renders a dynamic, holographic AI face ("Chaos") and free-form
 *  desktop projections using an OpenGL 4.3 Compute Shader pipeline. Particle
 *  spring physics, 3D perspective projection, depth-based volumetric shading,
 *  and soft radial glow splatting are executed entirely on the GPU via SSBOs
 *  and coherent image load/store operations. The resulting premultiplied-alpha
 *  frame is composited via Skia onto a transparent, click-through FireMonkey
 *  layered window with minimal CPU/GPU footprint, supporting full build-up
 *  (formation), tear-down (gravity fade), and adaptive FPS scaling.
 *==============================================================================}

interface

uses
  Winapi.Windows, System.SysUtils, System.Types, System.Classes, System.Math,
  System.Math.Vectors, System.UITypes, System.SyncObjs, FMX.Types, FMX.Controls,
  FMX.Graphics, FMX.Forms, FMX.Platform.Win, FMX.Skia, System.Skia,
  uSkiaCustomThreadedBase, Yutani.MeshLoader, Yutani.PhotoTo3D;

const
  CHAOS_WIDTH = 236;
  CHAOS_HEIGHT = 252;
  PARTICLE_MAX = 500000;
  DEFAULT_PARTICLE_BUDGET = 250000;
  SSBO_PARTICLE_SIZE = 52;    // FIX: was 48, sizeof(TParticleCPU)=52
  DEPTH_MAP_STEP = 10;    // match CPU original
  WGL_CONTEXT_MAJOR_VERSION_ARB = $2091;
  WGL_CONTEXT_MINOR_VERSION_ARB = $2092;
  WGL_CONTEXT_PROFILE_MASK_ARB = $9126;
  WGL_CONTEXT_CORE_PROFILE_BIT_ARB = $00000001;
  GL_COMPUTE_SHADER = $91B9;
  GL_SHADER_STORAGE_BUFFER = $90D2;
  GL_SHADER_STORAGE_BARRIER_BIT = $00002000;
  GL_SHADER_IMAGE_ACCESS_BARRIER_BIT = $00000020;
  GL_TEXTURE_2D = $0DE1;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_WRAP_S = $2802;
  GL_TEXTURE_WRAP_T = $2803;
  GL_CLAMP_TO_EDGE = $812F;
  GL_LINEAR = $2601;
  GL_RGBA8 = $8058;
  GL_BGRA = $80E1;
  GL_UNSIGNED_BYTE = $1401;
  GL_COMPILE_STATUS = $8B81;
  GL_LINK_STATUS = $8B82;
  GL_INFO_LOG_LENGTH = $8B84;
  GL_READ_ONLY = $88B8;
  GL_WRITE_ONLY = $88B9;
  GL_READ_WRITE = $88BA;
  GL_PIXEL_PACK_BUFFER = $88EB;
  GL_STREAM_READ = $88E1;
  GL_MAP_READ_BIT = $0001;
  GL_DYNAMIC_COPY = $88EA;

  { Visual style identifiers sent to the holo shader as uHoloStyle. }
  HOLO_STYLE_CLASSIC = 0;
  HOLO_STYLE_CYBER = 1;
  HOLO_STYLE_VOLUMETRIC = 2;
  HOLO_STYLE_PHOTO = 3;

  { Flag bit marking the inner brain-core layer of the volumetric style.
    The low nibble of Flags still carries the body-region id used for
    contour / circuit placement (1 head, 2 torso/neck, 3 arms, 4 legs). }
  PARTICLE_FLAG_INNER_CORE = $00000100;

  { Curated demo meshes probed next to the executable at startup. The .dae
    COLLADA variant is not handled by the mesh loader; ship the .glb export. }
  ASSET_PROBE_LIST: array[0..1] of string = ('angelica.glb', 'scifi_girl_v.01.glb');

type
  TChaosState = (csIdle, csForming, csActive, csFading, csFinished);

  TMouthState = (msClosed, msMin, msMid, msFull);

  TEyeState = (esOpen, esMid, esClosed);

  TEmotionMode = (emNeutral, emThinking, emHappy, emAlert);

  { Switchable material / colour mode for the hologram renderer. }
  THoloStyle = (hsClassic, hsCyber, hsVolumetric, hsPhoto);

  { Active particle source. The depth-map face is the legacy path; mesh,
    photo and hybrid route through the holo shader. }
  TChaosSource = (srcDepthMap, srcMesh, srcPhoto, srcHybrid);

  TParticleCPU = packed record
    PX, PY, PZ: Single;
    VX, VY, VZ: Single;
    TX, TY, TZ: Single;
    Color: Cardinal;
    Flags: Cardinal;
    Pad0, Pad1: Cardinal;
  end;

type
  PFNGLCREATESHADERPROC = function(shaderType: Cardinal): Cardinal; stdcall;

  PFNGLDELETESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLSHADERSOURCEPROC = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;

  PFNGLCOMPILESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLGETSHADERIVPROC = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETSHADERINFOLOGPROC = procedure(shader: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;

  PFNGLCREATEPROGRAMPROC = function: Cardinal; stdcall;

  PFNGLATTACHSHADERPROC = procedure(programObj: Cardinal; shader: Cardinal); stdcall;

  PFNGLLINKPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLDELETEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETPROGRAMIVPROC = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETPROGRAMINFOLOGPROC = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;

  PFNGLUSEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;

  PFNGLUNIFORM1FPROC = procedure(location: Integer; v: Single); stdcall;

  PFNGLUNIFORM2FPROC = procedure(location: Integer; x, y: Single); stdcall;

  PFNGLUNIFORM4FPROC = procedure(location: Integer; x, y, z, w: Single); stdcall;

  PFNGLUNIFORM1IPROC = procedure(location: Integer; v: Integer); stdcall;

  PFNGLUNIFORM1UIPROC = procedure(location: Integer; v: Cardinal); stdcall;

  PFNGLDISPATCHCOMPUTEPROC = procedure(gx, gy, gz: Cardinal); stdcall;

  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;

  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;

  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;

  PFNGLBUFFERSUBDATAPROC = procedure(target: Cardinal; offset: NativeInt; size: NativeInt; data: Pointer); stdcall;

  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;

  PFNGLMAPBUFFERRANGEPROC = function(target: Cardinal; offset: NativeInt; length: NativeInt; access: Cardinal): Pointer; stdcall;

  PFNGLUNMAPBUFFERPROC = function(target: Cardinal): ByteBool; stdcall;

  PFNGLGENTEXTURESPROC = procedure(n: Integer; textures: PCardinal); stdcall;

  PFNGLDELETETEXTURESPROC = procedure(n: Integer; textures: PCardinal); stdcall;

  PFNGLBINDTEXTUREPROC = procedure(target: Cardinal; texture: Cardinal); stdcall;

  PFNGLTEXPARAMETERIPROC = procedure(target: Cardinal; pname: Cardinal; param: Integer); stdcall;

  PFNGLTEXSTORAGE2DPROC = procedure(target: Cardinal; levels: Integer; internalformat: Cardinal; width, height: Integer); stdcall;

  PFNGLACTIVETEXTUREPROC = procedure(texture: Cardinal); stdcall;

  PFNGLBINDIMAGETEXTUREPROC = procedure(unit_: Cardinal; texture: Cardinal; level: Integer; layered: Cardinal; layer: Integer; access: Cardinal; format: Cardinal); stdcall;

  PFNGLGETTEXIMAGEPROC = procedure(target: Cardinal; level: Integer; format: Cardinal; type_: Cardinal; pixels: Pointer); stdcall;

  PFNWGLCREATECONTEXTATTRIBSARBPROC = function(hdc: HDC; shareContext: HGLRC; const attribList: PInteger): HGLRC; stdcall;

function wglCreateContext(hdc: HDC): HGLRC; stdcall; external 'opengl32.dll';

function wglDeleteContext(hglrc: HGLRC): BOOL; stdcall; external 'opengl32.dll';

function wglMakeCurrent(hdc: HDC; hglrc: HGLRC): BOOL; stdcall; external 'opengl32.dll';

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';

type
  TSkChaos = class(TSkiaCustomThreadedBase)
  private
    FMouthState: TMouthState;
    FEyeState: TEyeState;
    FDummyWnd: HWND;
    FDummyDC: HDC;
    FGLContext: HGLRC;
    FGLReady: Boolean;
    FGLFailed: Boolean;
    FOutputTex: Cardinal;
    FTempTex: Cardinal;             // ping-pong target for separable blur
    FParticleSSBO: Cardinal;
    FParticleCount: Cardinal;
    FParticleCPU: TBytes;
    FParticleProgram: Cardinal;
    FClearProgram: Cardinal;        // clears output texture per frame
    FBlurProgram: Cardinal;         // separable gaussian blur (H + V)
    FLocP_DeltaTime, FLocP_Time, FLocP_Resolution: Integer;
    FLocP_ParticleCount, FLocP_BuildScanY, FLocP_DespawnScanY, FLocP_State: Integer;
    FLocP_ChaosLevel, FLocP_MouthOpen, FLocP_EyeOpeness: Integer;
    FLocP_LookX, FLocP_LookY, FLocP_PivotY, FLocP_EmotionMode: Integer;
    FLocP_AccentColor, FLocP_EyeColor, FLocP_MouthColor, FLocP_FaceColor: Integer;
    FLocP_HighlightRect, FLocP_HighlightPulse: Integer;
    FLocP_MinY, FLocP_MaxY: Integer;
    FLocC_Resolution: Integer;      // clear program uniforms
    FLocB_Resolution: Integer;      // blur program uniforms
    FLocB_Horizontal: Integer;
    FPBOs: array[0..1] of Cardinal;
    FPBOIndex: Integer;
    FPBOHasData: Boolean;
    FPBOSize: NativeInt;
    FPixelBuffer: TBytes;
    FState: TChaosState;
    FQuitAfterDespawn: Boolean;
    FMouseFollow: Boolean;
    FStayOnTop: Boolean;
    FClickThrough: Boolean;
    FLookTargetX, FLookTargetY: Single;
    FCurrentMeshFile: string;
    FCurrentPhotoFile: string;
    FPivotY: Single;
    FNeckPivotRatio: Single;
    FGlobalTime: Double;
    FLastTime: Double;              // for real DeltaTime tracking
    FBuildScanY, FDespawnScanY: Single;
    FMinY, FMaxY: Single;
    FChaosLevel, FMouthOpen, FEyeOpeness: Single;
    FLookX, FLookY: Single;
    FEmotionMode: TEmotionMode;
    FAccentColor, FEyeColor, FMouthColor, FFaceColor: TAlphaColor;
    FHighlightRect: TRect;
    FHighlightActive: Boolean;
    FDepthMap: FMX.Graphics.TBitmap;
    FParticleBudget: Cardinal;
    FTrailPersistence: Single;
    FScaleFactor: Single;
    FnCreateShader: PFNGLCREATESHADERPROC;
    FnDeleteShader: PFNGLDELETESHADERPROC;
    FnShaderSource: PFNGLSHADERSOURCEPROC;
    FnCompileShader: PFNGLCOMPILESHADERPROC;
    FnGetShaderiv: PFNGLGETSHADERIVPROC;
    FnGetShaderInfoLog: PFNGLGETSHADERINFOLOGPROC;
    FnCreateProgram: PFNGLCREATEPROGRAMPROC;
    FnAttachShader: PFNGLATTACHSHADERPROC;
    FnLinkProgram: PFNGLLINKPROGRAMPROC;
    FnDeleteProgram: PFNGLDELETEPROGRAMPROC;
    FnGetProgramiv: PFNGLGETPROGRAMIVPROC;
    FnGetProgramInfoLog: PFNGLGETPROGRAMINFOLOGPROC;
    FnUseProgram: PFNGLUSEPROGRAMPROC;
    FnGetUniformLocation: PFNGLGETUNIFORMLOCATIONPROC;
    FnUniform1f: PFNGLUNIFORM1FPROC;
    FnUniform2f: PFNGLUNIFORM2FPROC;
    FnUniform4f: PFNGLUNIFORM4FPROC;
    FnUniform1i: PFNGLUNIFORM1IPROC;
    FnUniform1ui: PFNGLUNIFORM1UIPROC;
    FnDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
    FnMemoryBarrier: PFNGLMEMORYBARRIERPROC;
    FnGenBuffers: PFNGLGENBUFFERSPROC;
    FnDeleteBuffers: PFNGLDELETEBUFFERSPROC;
    FnBindBuffer: PFNGLBINDBUFFERPROC;
    FnBufferData: PFNGLBUFFERDATAPROC;
    FnBufferSubData: PFNGLBUFFERSUBDATAPROC;
    FnBindBufferBase: PFNGLBINDBUFFERBASEPROC;
    FnMapBufferRange: PFNGLMAPBUFFERRANGEPROC;
    FnUnmapBuffer: PFNGLUNMAPBUFFERPROC;
    FnGenTextures: PFNGLGENTEXTURESPROC;
    FnDeleteTextures: PFNGLDELETETEXTURESPROC;
    FnBindTexture: PFNGLBINDTEXTUREPROC;
    FnTexParameteri: PFNGLTEXPARAMETERIPROC;
    FnTexStorage2D: PFNGLTEXSTORAGE2DPROC;
    FnActiveTexture: PFNGLACTIVETEXTUREPROC;
    FnBindImageTexture: PFNGLBINDIMAGETEXTUREPROC;
    FnGetTexImage: PFNGLGETTEXIMAGEPROC;
    FnCreateContextAttribs: PFNWGLCREATECONTEXTATTRIBSARBPROC;
    { Holographic style + multi-source state }
    FHoloStyle: THoloStyle;
    FSourceType: TChaosSource;
    FStepFilter: Integer;
    FParticleSize: Single;
    FGlowIntensity: Single;
    FRimLightStrength: Single;
    FHoloAlpha: Single;
    FJitterAmount: Single;
    FInnerCore: Boolean;
    FHoloProgram: Cardinal;
    FLocH_DeltaTime, FLocH_Time, FLocH_Resolution: Integer;
    FLocH_ParticleCount, FLocH_State, FLocH_BuildScanY, FLocH_DespawnScanY: Integer;
    FLocH_LookX, FLocH_LookY, FLocH_PivotY: Integer;
    FLocH_HoloStyle, FLocH_ParticleSize, FLocH_GlowIntensity: Integer;
    FLocH_RimLightStrength, FLocH_Alpha, FLocH_Jitter: Integer;
    FLocH_FaceColor, FLocH_AccentColor: Integer;
    { Mesh / photo source data, kept for morph-target animation }
    FMeshResult: TMeshLoadResult;
    FMeshBase: TArray<TMeshParticlePoint>;
    FMeshScale: Single;
    FMeshFlipY: Boolean;
    FMorphWeights: TArray<Single>;
    FActiveSequence: Integer;
    FAnimTime: Double;
    FAutoMeshFile: string;
    procedure SetHoloStyle(const Value: THoloStyle);
    procedure SetStepFilter(const Value: Integer);
    procedure SetParticleSize(const Value: Single);
    procedure SetGlowIntensity(const Value: Single);
    procedure SetRimLightStrength(const Value: Single);
    procedure SetHoloAlpha(const Value: Single);
    procedure SetJitterAmount(const Value: Single);
    procedure SetInnerCore(const Value: Boolean);
    procedure SetParticleBudget(const Value: Cardinal);
    procedure SetNeckPivotRatio(const Value: Single);
    procedure SetMouseFollow(const Value: Boolean);
    procedure SetStayOnTop(const Value: Boolean);
    procedure SetClickThrough(const Value: Boolean);
    function FindOwnerForm: TForm;
    procedure ApplyStayOnTop;
    procedure BuildMeshTargets(const APoints: TArray<TMeshParticlePoint>);
    procedure DispatchHoloFrame(ADeltaTime, ATime: Double);
    procedure ApplyHoloUniforms(ATime, ADeltaTime: Double);
    procedure AdvanceMorphAnimation(ADeltaTime: Double);
    procedure ApplyCurrentMorph;
    procedure UpdateTargetsFromMesh;
    function ProbeAutoAsset: string;
    function InitOffscreenGL: Boolean;
    procedure CleanupOffscreenGL;
    procedure LoadGLFunctions;
    function CompileShader(AShaderType: Cardinal; const ASrc: AnsiString): Cardinal;
    function LinkProgram(const AShaders: array of Cardinal): Cardinal;
    procedure InitShaders;
    procedure InitGLResources;
    procedure EnsureOutputTexture(W, H: Integer);
    procedure GenerateFaceTargets;
    procedure UploadSSBO;
    procedure ApplyUniforms(ATime, ADeltaTime: Double);
    procedure DispatchClear;             // NEW
    procedure DispatchFrame(ADeltaTime, ATime: Double);
    procedure DispatchBlur(AHorizontal: Boolean);  // NEW
    procedure ReadbackToPixelBuffer;
    procedure ReinitParticlesForForming;           // NEW
    procedure SetMouthState(const Value: TMouthState);
    procedure SetEyeState(const Value: TEyeState);
    procedure SetEmotionMode(const Value: TEmotionMode);
  protected
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadDepthMap(const AFileName: string);
    procedure LoadMeshFile(const AFileName: string; ATargetRadius: Single = 150.0; AStep: Integer = 1; AMaxParticles: Integer = 120000);
    procedure LoadPhotoFile(const AFileName: string; ATargetRadius: Single = 130.0; AStep: Integer = 2; AMaxParticles: Integer = 80000);
    procedure LoadHybrid(const AMeshFile, APhotoFile: string);
    { Sets a single morph-target weight by name (head_neutral, mouth_open,
      smile, blink, ...). Stops any playing vertex-frame animation so the
      manual weight takes over. }
    procedure SetMorphTargetWeight(const AName: string; AWeight: Single);
    { Plays a loaded vertex-frame sequence (body movement / expression clip). }
    procedure PlayVertexFrame(AIndex: Integer);
    { Re-trigger the spawn (forming) animation from scattered positions. }
    procedure Spawn;
    { Trigger the despawn (fading) animation; particles fall away scanline by
      scanline. }
    procedure Despawn;
    { Play the despawn animation and quit the application once it completes. }
    procedure QuitAfterDespawn;
    { Re-apply the click-through window style to the host form. Call after the
      form's window handle is (re)created: FMX recreates the HWND for
      Transparency / FormStyle changes, which drops the raw WS_EX_TRANSPARENT
      flag this sets, so the style must be re-applied once the handle is stable. }
    procedure ApplyClickThrough;
    property State: TChaosState read FState;
    property MouthState: TMouthState read FMouthState write SetMouthState;
    property EyeState: TEyeState read FEyeState write SetEyeState;
    property FaceColor: TAlphaColor read FFaceColor write FFaceColor;
    property EyeColor: TAlphaColor read FEyeColor write FEyeColor;
    property MouthColor: TAlphaColor read FMouthColor write FMouthColor;
    property AccentColor: TAlphaColor read FAccentColor write FAccentColor;
    property ChaosLevel: Single read FChaosLevel write FChaosLevel;
    property MouthOpen: Single read FMouthOpen write FMouthOpen;
    property EyeOpeness: Single read FEyeOpeness write FEyeOpeness;
    property EmotionMode: TEmotionMode read FEmotionMode write SetEmotionMode;
    property HighlightRect: TRect read FHighlightRect write FHighlightRect;
    property HighlightActive: Boolean read FHighlightActive write FHighlightActive;
    property ParticleBudget: Cardinal read FParticleBudget write SetParticleBudget;
    property TrailPersistence: Single read FTrailPersistence write FTrailPersistence;
    { Switchable visual style and live tuning knobs. }
    property HoloStyle: THoloStyle read FHoloStyle write SetHoloStyle;
    property SourceType: TChaosSource read FSourceType;
    property StepFilter: Integer read FStepFilter write SetStepFilter;
    property ParticleSize: Single read FParticleSize write SetParticleSize;
    property GlowIntensity: Single read FGlowIntensity write SetGlowIntensity;
    property RimLightStrength: Single read FRimLightStrength write SetRimLightStrength;
    property HoloAlpha: Single read FHoloAlpha write SetHoloAlpha;
    property JitterAmount: Single read FJitterAmount write SetJitterAmount;
    { Toggles the pulsating inner brain-core layer (~33% of head particles
      become INNER_CORE). Off by default for a clean shell surface; enable it
      later for the volumetric "brain inside" look. }
    property InnerCore: Boolean read FInnerCore write SetInnerCore default False;
    { Avatar smoothly turns its gaze toward the mouse cursor. }
    property MouseFollow: Boolean read FMouseFollow write SetMouseFollow default False;
    { Neck pivot as a fraction of the mesh Y range (0 = top, 1 = bottom);
      head particles above the pivot rotate toward the cursor, shoulders
      below stay. Auto-set to 0.33 on build, tunable live. }
    property NeckPivotRatio: Single read FNeckPivotRatio write SetNeckPivotRatio;
    { Keep the host window above all other top-level windows. }
    property StayOnTop: Boolean read FStayOnTop write SetStayOnTop default False;
    { Let mouse clicks pass through the host window to what is behind. }
    property ClickThrough: Boolean read FClickThrough write SetClickThrough default False;
    property AutoMeshFile: string read FAutoMeshFile;
  end;

implementation

const
  { PARTICLE_SRC: per-particle update + single-pixel premultiplied splat.

    Each invocation advances one particle (spring toward target, gravity
    fall while despawning) and splats a core+glow kernel into uOutput.
    Compositing keeps rgb <= a so the transparent desktop window never
    floods alpha.

    State machine mirrors the CPU build-up:
      uState=0 Forming:  particle visible only when tgt.y <= uBuildScanY.
      uState=1 Active:   hover drift around target.
      uState=2 Fading:   despawn scanline triggers gravity-fall.
      uState=3 Finished: dispatch returns immediately - overlay stays empty. }
  PARTICLE_SRC: AnsiString =
    // GLSL 4.30 compute shader - one work item per particle.
    '#version 430 core'#10 + 'layout(local_size_x = 256) in;'#10 +
    // Particle pool in a std430 SSBO; uOutput is the RGBA8 splat target.
    'struct Particle {'#10 + '  float px, py, pz;'#10 + '  float vx, vy, vz;'#10 + '  float tx, ty, tz;'#10 + '  uint  color;'#10 + '  uint  flags;'#10 + '  uint  pad0, pad1;'#10 + '};'#10 + 'layout(std430, binding = 0) buffer SSBO { Particle P[]; };'#10 + 'layout(rgba8, binding = 0) coherent uniform image2D uOutput;'#10 + ''#10 +
    // CPU uniforms: timing, resolution, state machine, look/pivot, palette.
    'uniform float uDeltaTime;'#10 + 'uniform float uTime;'#10 + 'uniform vec2  uResolution;'#10 + 'uniform uint  uParticleCount;'#10 + 'uniform float uBuildScanY;'#10 + 'uniform float uDespawnScanY;'#10 + 'uniform int   uState;'#10 + 'uniform float uChaosLevel;'#10 + 'uniform float uMouthOpen;'#10 + 'uniform float uEyeOpeness;'#10 + 'uniform float uLookX;'#10 + 'uniform float uLookY;'#10 + 'uniform float uPivotY;'#10 + 'uniform int   uEmotionMode;'#10 + 'uniform vec4  uFaceColor;'#10 + 'uniform vec4  uEyeColor;'#10 + 'uniform vec4  uMouthColor;'#10 + 'uniform vec4  uAccentColor;'#10 + ''#10 +
    // project3D - rotate the head around the neck pivot (uPivotY) toward the
    // cursor with mild perspective; smoothstep fades rotation below the pivot
    // so the shoulders stay still.
    'vec2 project3D(vec3 p) {'#10 + '  float rotY = -uLookX * 0.4;'#10 + '  float rotX = -uLookY * 0.25;'#10 + '  float pivotY = uPivotY;'#10 + '  float w = 1.0 - smoothstep(pivotY - 14.0, pivotY + 18.0, p.y);'#10 + '  float wy = 0.15 + 0.85 * w;'#10 + '  float wx = w;'#10 + '  float ry = rotY * wy;'#10 + '  float rx = rotX * wx;'#10 + '  float py = p.y - pivotY;'#10 + '  float x1 = p.x * cos(ry) - p.z * sin(ry);'#10 + '  float z1 = p.x * sin(ry) + p.z * cos(ry);'#10 + '  float y1 = py * cos(rx) - z1 * sin(rx);'#10 + '  float z2 = py * sin(rx) + z1 * cos(rx);'#10 + '  float persp = 1.0 + (z2 * 0.0022);'#10 + '  return vec2(x1 * persp, (y1 + pivotY) * persp + 15.0);'#10 + '}'#10 + ''#10 +
    // toScreenFloat - offset projected coords to pixel space (viewport-center origin).
    'vec2 toScreenFloat(vec2 p2) {'#10 + '  return vec2(p2.x + uResolution.x * 0.5,'#10 + '              p2.y + uResolution.y * 0.5);'#10 + '}'#10 + ''#10 +
    // rand - cheap deterministic hash for per-particle randomness.
    'float rand(float s) {'#10 + '  return fract(sin(s * 12.9898) * 43758.5453);'#10 + '}'#10 + ''#10 +
    // main - one particle per invocation.
    'void main() {'#10 +
    // csFinished: overlay stays empty, bail before any work.
    '  if (uState == 3) return;'#10 + '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 256u) + gl_GlobalInvocationID.x;'#10 + '  if (idx >= uParticleCount) return;'#10 + '  float dt = clamp(uDeltaTime, 0.0, 0.033);'#10 + '  uint flags = P[idx].flags;'#10 + '  vec3 pos = vec3(P[idx].px, P[idx].py, P[idx].pz);'#10 + '  vec3 vel = vec3(P[idx].vx, P[idx].vy, P[idx].vz);'#10 + '  vec3 tgt = vec3(P[idx].tx, P[idx].ty, P[idx].tz);'#10 + '  bool visible = true;'#10 + '  bool falling = false;'#10 +
    // State machine: 0 = forming (reveal up to build scanline),
    // 2 = fading (drop below despawn scanline).
    '  if (uState == 0) {'#10 + '    if (tgt.y > uBuildScanY) visible = false;'#10 + '  } else if (uState == 2) {'#10 + '    if (pos.y <= uDespawnScanY) {'#10 + '      if (vel.y < 1.0) vel.y = 240.0 + 140.0 * rand(float(idx));'#10 + '      falling = true;'#10 + '    }'#10 + '  }'#10 +
    // Falling: gravity carries the particle down and out of the viewport.
    '  if (falling) {'#10 + '    vel.y += 700.0 * dt;'#10 + '    pos += vel * dt;'#10 +
    // Otherwise spring toward target; add hover drift while active.
    '  } else if (visible) {'#10 + '    vec3 d = tgt - pos;'#10 + '    float stiff = 220.0;'#10 + '    float damp = 18.0;'#10 + '    vel += (d * stiff - vel * damp) * dt;'#10 + '    pos += vel * dt;'#10 + '    if (uState == 1) {'#10 + '      vec3 hover = vec3(sin(uTime * 1.3 + float(idx) * 0.37),'#10 + '                        cos(uTime * 1.1 + float(idx) * 0.53), 0.0) * 0.4;'#10 + '      pos += hover * dt;'#10 + '    }'#10 + '  }'#10 +
    // Write back position and velocity.
    '  P[idx].px = pos.x; P[idx].py = pos.y; P[idx].pz = pos.z;'#10 + '  P[idx].vx = vel.x; P[idx].vy = vel.y; P[idx].vz = vel.z;'#10 + '  if (!visible) return;'#10 + ''#10 + '  // Thin out eye and mouth rings so individual light points emerge'#10 + '  if ((flags == 2u || flags == 3u || flags == 4u) && ((idx % 2u) != 0u)) return;'#10 + ''#10 + '  vec2 p2 = project3D(pos);'#10 + '  vec2 center = toScreenFloat(p2);'#10 + '  ivec2 basePx = ivec2(round(center));'#10 + '  int resX = int(uResolution.x);'#10 + '  int resY = int(uResolution.y);'#10 + '  if (basePx.x < -5 || basePx.x >= resX + 5 ||'#10 + '      basePx.y < -5 || basePx.y >= resY + 5) return;'#10 + ''#10 +
    // Depth and radial fade drive particle size and brightness.
    '  float rawDepth = clamp(pos.z / 110.0, 0.0, 1.0);'#10 + '  float depth = pow(rawDepth, 1.8);'#10 + '  float radialFade = clamp(1.0 - length(pos.xy) * 0.0045, 0.35, 1.0);'#10 + ''#10 + '  vec4 col;'#10 + '  float typeBoost = 1.0;'#10 + '  float coreRadius = mix(0.75, 1.35, depth);'#10 + '  float glowRadius = mix(2.2, 3.8, depth);'#10 + ''#10 +
    // Per-type color and glow sizing: eyes and mouth smaller and brighter than face.
    '  if (flags == 2u || flags == 3u) {'#10 + '    col = uEyeColor;'#10 + '    typeBoost = 0.90;'#10 + '    depth = 0.78;'#10 + '    coreRadius = 0.95;'#10 + '    glowRadius = 2.8;'#10 + '  } else if (flags == 4u) {'#10 + '    col = uMouthColor;'#10 + '    typeBoost = 0.90;'#10 + '    depth = 0.75;'#10 + '    coreRadius = 0.90;'#10 + '    glowRadius = 2.6;'#10 + '  } else {'#10 + '    col = uFaceColor;'#10 + '    typeBoost = 1.0;'#10 + '  }'#10 + ''#10 +
    // Flicker and base intensity; fade out smoothly while falling so nothing is cut off.
    '  float flick = 0.90 + 0.10 * sin(uTime * 14.0 + float(idx) * 1.31);'#10 + '  float baseIntensity = mix(0.14, 1.05, depth) * radialFade * flick * typeBoost;'#10 + '  if (falling) baseIntensity *= clamp(1.0 - (pos.y - 60.0) / 90.0, 0.0, 1.0);'#10 + ''#10 +
    // Splat a core+glow kernel into uOutput with premultiplied-alpha compositing.
    '  for (int dy = -4; dy <= 4; ++dy) {'#10 + '    for (int dx = -4; dx <= 4; ++dx) {'#10 + '      ivec2 px = basePx + ivec2(dx, dy);'#10 + '      if (px.x < 0 || px.x >= resX || px.y < 0 || px.y >= resY) continue;'#10 + '      float dist = length(vec2(px) + 0.5 - center);'#10 + '      if (dist > glowRadius) continue;'#10 + '      float core = exp(-(dist * dist) / (coreRadius * coreRadius));'#10 + '      float glow = exp(-(dist * dist) / (glowRadius * glowRadius * 0.4)) * 0.35;'#10 +
    '      float a = clamp((core + glow) * baseIntensity, 0.0, 1.0);'#10 + '      if (a <= 0.004) continue;'#10 + '      // Strict premultiplied alpha (rgb <= a) for clean desktop transparency'#10 + '      vec4 src = vec4(col.rgb * a, a);'#10 + '      vec4 dst = imageLoad(uOutput, px);'#10 + '      float outA = clamp(max(dst.a, src.a) + min(dst.a, src.a) * 0.25, 0.0, 1.0);'#10 + '      vec3 outRGB = clamp(max(dst.rgb, src.rgb) + min(dst.rgb, src.rgb) * 0.25, 0.0, outA);'#10 + '      imageStore(uOutput, px, vec4(outRGB, outA));'#10 + '    }'#10 + '  }'#10 + '}';
  CLEAR_SRC: AnsiString =
    // CLEAR_SRC - zero out uOutput (one 16x16 tile per invocation).
    '#version 430 core'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) writeonly uniform image2D uOutput;'#10 + 'uniform vec2 uResolution;'#10 + 'void main() {'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(uResolution.x) || px.y >= int(uResolution.y)) return;'#10 + '  imageStore(uOutput, px, vec4(0.0));'#10 + '}';
  BLUR_SRC: AnsiString =
    // BLUR_SRC - separable Gaussian blur (horizontal then vertical pass).
    '#version 430 core'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) readonly  uniform image2D uInput;'#10 + 'layout(rgba8, binding = 1) writeonly uniform image2D uOutput;'#10 + 'uniform vec2 uResolution;'#10 + 'uniform int   uHorizontal;'#10 +
    // Accumulate a weighted kernel; keep the brighter of center vs. blurred so glows do not dim sharp cores.
    'void main() {'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(uResolution.x) || px.y >= int(uResolution.y)) return;'#10 + '  const int RADIUS = 2;'#10 + '  const float SIGMA = 1.2;'#10 + '  vec4 centerCol = imageLoad(uInput, px);'#10 + '  vec4 sum = vec4(0.0);'#10 + '  float wsum = 0.0;'#10 + '  for (int i = -RADIUS; i <= RADIUS; ++i) {'#10 + '    float w = exp(-float(i*i) / (2.0 * SIGMA * SIGMA));'#10 + '    ivec2 sp = px;'#10 +
    '    if (uHorizontal == 1) sp.x += i; else sp.y += i;'#10 + '    if (sp.x < 0 || sp.x >= int(uResolution.x) ||'#10 + '        sp.y < 0 || sp.y >= int(uResolution.y)) continue;'#10 + '    sum += imageLoad(uInput, sp) * w;'#10 + '    wsum += w;'#10 + '  }'#10 + '  vec4 blurred = sum / wsum;'#10 + '  float outA = clamp(max(centerCol.a, blurred.a * 1.15), 0.0, 1.0);'#10 + '  vec3 outRGB = clamp(max(centerCol.rgb, blurred.rgb * 1.15), 0.0, outA);'#10 + '  imageStore(uOutput, px, vec4(outRGB, outA));'#10 + '}';
  HOLO_PARTICLE_SRC: AnsiString =
    // GLSL 4.30 compute shader - holo-style renderer, one work item per particle.
    '#version 430 core'#10 + 'layout(local_size_x = 256) in;'#10 +
    // Particle pool in a std430 SSBO; uOutput is the RGBA8 splat target.
    'struct Particle {'#10 + '  float px, py, pz;'#10 + '  float vx, vy, vz;'#10 + '  float tx, ty, tz;'#10 + '  uint  color;'#10 + '  uint  flags;'#10 + '  uint  pad0, pad1;'#10 + '};'#10 + 'layout(std430, binding = 0) buffer SSBO { Particle P[]; };'#10 + 'layout(rgba8, binding = 0) coherent uniform image2D uOutput;'#10 + ''#10 +
    // CPU uniforms: timing, resolution, state machine, look/pivot, style, palette.
    'uniform float uDeltaTime;'#10 + 'uniform float uTime;'#10 + 'uniform vec2  uResolution;'#10 + 'uniform uint  uParticleCount;'#10 + 'uniform int   uState;'#10 + 'uniform float uBuildScanY;'#10 + 'uniform float uDespawnScanY;'#10 + 'uniform float uLookX;'#10 + 'uniform float uLookY;'#10 + 'uniform float uPivotY;'#10 + 'uniform int   uHoloStyle;'#10 + 'uniform float uParticleSize;'#10 + 'uniform float uGlowIntensity;'#10 + 'uniform float uRimLightStrength;'#10 + 'uniform float uAlpha;'#10 + 'uniform float uJitter;'#10 + 'uniform vec4  uFaceColor;'#10 + 'uniform vec4  uAccentColor;'#10 + ''#10 +
    // project3D - rotate the head around the neck pivot (uPivotY) toward the
    // cursor with mild perspective; smoothstep fades rotation below the pivot.
    'vec2 project3D(vec3 p) {'#10 + '  float rotY = -uLookX * 0.4;'#10 + '  float rotX = -uLookY * 0.25;'#10 + '  float pivotY = uPivotY;'#10 + '  float w = 1.0 - smoothstep(pivotY - 14.0, pivotY + 18.0, p.y);'#10 + '  float wy = 0.15 + 0.85 * w;'#10 + '  float wx = w;'#10 + '  float ry = rotY * wy;'#10 + '  float rx = rotX * wx;'#10 + '  float py = p.y - pivotY;'#10 + '  float x1 = p.x * cos(ry) - p.z * sin(ry);'#10 + '  float z1 = p.x * sin(ry) + p.z * cos(ry);'#10 + '  float y1 = py * cos(rx) - z1 * sin(rx);'#10 + '  float z2 = py * sin(rx) + z1 * cos(rx);'#10 + '  float persp = 1.0 + (z2 * 0.0022);'#10 + '  return vec2(x1 * persp, (y1 + pivotY) * persp + 15.0);'#10 + '}'#10 +
    // toScreenFloat - offset projected coords to pixel space.
    'vec2 toScreenFloat(vec2 p2) {'#10 + '  return vec2(p2.x + uResolution.x * 0.5, p2.y + uResolution.y * 0.5);'#10 + '}'#10 +
    // rand - cheap deterministic hash.
    'float rand(float s) { return fract(sin(s * 12.9898) * 43758.5453); }'#10 +
    // decodeNormal - unpack two 16-bit normal components stored in the pad words.
    'vec3 decodeNormal(uint pad0, uint pad1) {'#10 + '  float nx = float(pad0 & 0xFFFFu) / 65535.0 * 2.0 - 1.0;'#10 + '  float ny = float(pad0 >> 16u) / 65535.0 * 2.0 - 1.0;'#10 + '  float nz = float(pad1 & 0xFFFFu) / 65535.0 * 2.0 - 1.0;'#10 + '  vec3 n = vec3(nx, ny, nz);'#10 + '  if (dot(n, n) < 0.0001) return vec3(0.0, 0.0, 1.0);'#10 + '  return normalize(n);'#10 + '}'#10 +
    // unpackColor - RGB from the packed color word (photo style reads vertex color).
    'vec4 unpackColor(uint c) {'#10 + '  float r = float((c >> 16u) & 0xFFu) / 255.0;'#10 + '  float g = float((c >> 8u)  & 0xFFu) / 255.0;'#10 + '  float b = float(c & 0xFFu) / 255.0;'#10 + '  return vec4(r, g, b, 1.0);'#10 + '}'#10 +
    // main - one particle per invocation.
    'void main() {'#10 +
    // csFinished: overlay stays empty, bail before any work.
    '  if (uState == 3) return;'#10 + '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 256u) + gl_GlobalInvocationID.x;'#10 + '  if (idx >= uParticleCount) return;'#10 + '  float dt = clamp(uDeltaTime, 0.0, 0.033);'#10 + '  uint flags = P[idx].flags;'#10 + '  uint region = flags & 0xFu;'#10 + '  bool innerCore = (flags & 0x100u) != 0u;'#10 + ''#10 + '  vec3 pos = vec3(P[idx].px, P[idx].py, P[idx].pz);'#10 + '  vec3 vel = vec3(P[idx].vx, P[idx].vy, P[idx].vz);'#10 + '  vec3 tgt = vec3(P[idx].tx, P[idx].ty, P[idx].tz);'#10 +
    // Inner brain-core particles sit closer to the center of the head.
    '  if (innerCore) tgt *= 0.55;'#10 + ''#10 + '  bool visible = true;'#10 + '  bool falling = false;'#10 +
    // State machine: 0 = forming (reveal up to build scanline), 2 = fading (drop below despawn scanline).
    '  if (uState == 0) { if (tgt.y > uBuildScanY) visible = false; } else if (uState == 2) { if (pos.y <= uDespawnScanY) { if (vel.y < 1.0) vel.y = 240.0 + 140.0 * rand(float(idx)); falling = true; } }'#10 +
    // Falling: gravity carries the particle down and out of the viewport.
    '  if (falling) {'#10 + '    vel.y += 700.0 * dt;'#10 + '    pos += vel * dt;'#10 +
    // Otherwise spring toward target; add hover drift and per-style jitter.
    '  } else if (visible) {'#10 + '    vec3 d = tgt - pos;'#10 + '    float stiff = 220.0;'#10 + '    float damp = 18.0;'#10 + '    vel += (d * stiff - vel * damp) * dt;'#10 + '    pos += vel * dt;'#10 + '    if (uState == 1) {'#10 + '      vec3 hover = vec3(sin(uTime * 1.3 + float(idx) * 0.37),'#10 + '                        cos(uTime * 1.1 + float(idx) * 0.53), 0.0) * 0.4;'#10 + '      pos += hover * dt;'#10 + '    }'#10 + '    pos += vec3(rand(float(idx) + uTime) - 0.5,'#10 +
    '                rand(float(idx) * 1.7 + uTime) - 0.5,'#10 + '                rand(float(idx) * 2.3 + uTime) - 0.5) * uJitter;'#10 + '    if (uHoloStyle == 2) {'#10 + '      pos += vec3(rand(float(idx) * 0.5 + uTime * 0.7) - 0.5,'#10 + '                  rand(float(idx) * 0.9 + uTime * 0.5) - 0.5, 0.0) * 0.9;'#10 + '    }'#10 + '  }'#10 +
    // Write back position and velocity.
    '  P[idx].px = pos.x; P[idx].py = pos.y; P[idx].pz = pos.z;'#10 + '  P[idx].vx = vel.x; P[idx].vy = vel.y; P[idx].vz = vel.z;'#10 + '  if (!visible) return;'#10 + ''#10 +
    // Project to screen and cull particles outside the viewport.
    '  vec3 normal = decodeNormal(P[idx].pad0, P[idx].pad1);'#10 + '  vec2 p2 = project3D(pos);'#10 + '  vec2 center = toScreenFloat(p2);'#10 + '  ivec2 basePx = ivec2(round(center));'#10 + '  int resX = int(uResolution.x);'#10 + '  int resY = int(uResolution.y);'#10 + '  if (basePx.x < -9 || basePx.x >= resX + 9 ||'#10 + '      basePx.y < -9 || basePx.y >= resY + 9) return;'#10 + ''#10 + '  float rawDepth = clamp(pos.z / 110.0, 0.0, 1.0);'#10 + '  float depth = pow(rawDepth, 1.8);'#10 + ''#10 +
    // Rim light from the surface normal; facing fades the body, rim highlights edges.
    '  float rim = clamp(1.0 - abs(normal.z), 0.0, 1.0);'#10 + '  rim = pow(rim, 2.0) * uRimLightStrength;'#10 + '  float facing = clamp(normal.z * 0.5 + 0.5, 0.0, 1.0);'#10 + ''#10 +
    // Core/glow radius scales with particle count so coverage stays even.
    '  float density = float(uParticleCount);'#10 + '  float coreRadius, glowRadius;'#10 + '  if (density < 5000.0) {'#10 + '    float t = clamp(density / 5000.0, 0.0, 1.0);'#10 + '    coreRadius = mix(2.5, 1.6, t);'#10 + '    glowRadius = mix(9.0, 7.0, t);'#10 + '  } else if (density > 50000.0) {'#10 + '    float t = clamp((density - 50000.0) / 200000.0, 0.0, 1.0);'#10 + '    coreRadius = mix(1.2, 0.6, t);'#10 + '    glowRadius = mix(4.0, 1.0, t);'#10 + '  } else {'#10 + '    coreRadius = 1.2;'#10 + '    glowRadius = 4.0;'#10 + '  }'#10 + '  coreRadius *= uParticleSize;'#10 + '  glowRadius *= uParticleSize;'#10 + '  int ir = int(ceil(glowRadius));'#10 + '  if (ir < 1) ir = 1;'#10 + '  if (ir > 9) ir = 9;'#10 + ''#10 +
    // Color by style: photo reads vertex color, volumetric inner-core uses accent, else face color.
    '  vec4 col;'#10 + '  if (uHoloStyle == 3) {'#10 + '    col = unpackColor(P[idx].color);'#10 + '  } else if (innerCore && uHoloStyle == 2) {'#10 + '    col = uAccentColor;'#10 + '  } else {'#10 + '    col = uFaceColor;'#10 + '  }'#10 + ''#10 +
    // Flicker, inner-core pulse, rim boost, and final alpha; fade out smoothly while falling.
    '  float flick = 0.90 + 0.10 * sin(uTime * 14.0 + float(idx) * 1.31);'#10 + '  float pulse = innerCore ? (0.6 + 0.4 * sin(uTime * 6.0 + float(idx) * 0.21)) : 1.0;'#10 + ''#10 + '  float baseIntensity = mix(0.14, 1.05, depth) * facing * flick * uGlowIntensity;'#10 + '  if (uHoloStyle == 1 && (region == 1u || region == 2u)) {'#10 + '    baseIntensity += rim * 0.5 * uRimLightStrength;'#10 + '    col.rgb = col.rgb + uAccentColor.rgb * rim * pulse * 0.5;'#10 + '  } else {'#10 + '    baseIntensity += rim * 0.3 * uRimLightStrength;'#10 + '  }'#10 + '  baseIntensity *= pulse * uAlpha;'#10 + '  if (falling) baseIntensity *= clamp(1.0 - (pos.y - 60.0) / 90.0, 0.0, 1.0);'#10 + ''#10 +
    // Splat a core+glow kernel into uOutput with premultiplied-alpha compositing.
    '  for (int dy = -ir; dy <= ir; ++dy) {'#10 + '    for (int dx = -ir; dx <= ir; ++dx) {'#10 + '      ivec2 px = basePx + ivec2(dx, dy);'#10 + '      if (px.x < 0 || px.x >= resX || px.y < 0 || px.y >= resY) continue;'#10 + '      float dist = length(vec2(px) + 0.5 - center);'#10 + '      if (dist > glowRadius) continue;'#10 + '      float core = exp(-(dist * dist) / (coreRadius * coreRadius));'#10 + '      float glow = exp(-(dist * dist) / (glowRadius * glowRadius * 0.4)) * 0.35;'#10 +
    '      float a = clamp((core + glow) * baseIntensity, 0.0, 1.0);'#10 + '      if (a <= 0.004) continue;'#10 + '      vec4 src = vec4(col.rgb * a, a);'#10 + '      vec4 dst = imageLoad(uOutput, px);'#10 + '      float outA = clamp(max(dst.a, src.a) + min(dst.a, src.a) * 0.25, 0.0, 1.0);'#10 + '      vec3 outRGB = clamp(max(dst.rgb, src.rgb) + min(dst.rgb, src.rgb) * 0.25, 0.0, outA);'#10 + '      imageStore(uOutput, px, vec4(outRGB, outA));'#10 + '    }'#10 + '  }'#10 + '}';


//==============================================================================
// Construct / Destroy
//==============================================================================
constructor TSkChaos.Create(AOwner: TComponent);
var
  ExePath, DepthFile: string;
begin
  inherited Create(AOwner);
  Width := CHAOS_WIDTH;
  Height := CHAOS_HEIGHT;
  FState := csIdle;
  FScaleFactor := 0.75;   // match CPU original
  FMouthOpen := 0.15;
  FEyeOpeness := 1.0;
  FEmotionMode := emNeutral;
  FAccentColor := $FF00BFFF;
  FFaceColor := $FF00BFFF;
  FEyeColor := $FF00BFFF;
  FMouthColor := $FF00BFFF;
  FMouthState := msMin;
  FEyeState := esOpen;
  FHighlightRect := Rect(-1, -1, -1, -1);
  FHighlightActive := False;
  FParticleBudget := DEFAULT_PARTICLE_BUDGET;
  FTrailPersistence := 0.85;   // kept for API compat; no longer used as decay
  FChaosLevel := 0.0;          // 0 = no drift (matches CPU look)
  FParticleCount := 0;
  FPBOIndex := 0;
  FPBOHasData := False;
  FGLReady := False;
  FGLFailed := False;
  FDepthMap := nil;
  FLastTime := 0;
  FTempTex := 0;
  FClearProgram := 0;
  FBlurProgram := 0;
  ExePath := ExtractFilePath(ParamStr(0));
  DepthFile := ExePath + 'depthmap.png';
  if FileExists(DepthFile) then
    LoadDepthMap(DepthFile);

  { Holographic style + live-control defaults. Classic mirrors the legacy
    cyan depth-map look; mesh / photo sources switch to a richer style on
    load. }
  FHoloStyle := hsClassic;
  FSourceType := srcDepthMap;
  FStepFilter := 1;
  FParticleSize := 1.0;
  FGlowIntensity := 1.0;
  FRimLightStrength := 1.0;
  FHoloAlpha := 0.85;
  FJitterAmount := 0.4;
  FHoloProgram := 0;
  FMeshScale := 1.0;
  FMeshFlipY := True;
  FActiveSequence := -1;
  FAnimTime := 0;
  FInnerCore := False;

  { Adaptive idle FPS: 38 FPS while the avatar speaks / animates / morphs,
    dropping to 15 FPS after three seconds of silence. Exposed on the base
    class so it can be fine-tuned at runtime. }
  AdaptiveFPS := True;
  ActiveTargetFPS := 38;
  IdleTargetFPS := 15;
  IdleTimeoutSec := 3.0;
  FNeckPivotRatio := 0.58;

  { Probe the curated demo meshes shipped beside the executable and load the
    first one found. A corrupt or unsupported file falls back silently to
    the depth-map path so the app still starts. }
  FAutoMeshFile := ProbeAutoAsset;
  if FAutoMeshFile <> '' then
  begin
    try
      { Fit the mesh into the actual control size instead of a fixed world
        radius: the avatar control is only 236x252, so a radius of 150 made
        the cloud span ~300 units and the head was clipped at the top. }
      LoadMeshFile(FAutoMeshFile, Min(Width, Height) * 0.45, 1, 120000);
    except
      FAutoMeshFile := '';
      FSourceType := srcDepthMap;
    end;
  end;
end;

destructor TSkChaos.Destroy;
begin
  inherited;
  FreeAndNil(FDepthMap);
end;

procedure TSkChaos.LoadDepthMap(const AFileName: string);
begin
  FreeAndNil(FDepthMap);
  if not FileExists(AFileName) then
    Exit;
  FDepthMap := FMX.Graphics.TBitmap.Create;
  try
    FDepthMap.LoadFromFile(AFileName);
  except
    FreeAndNil(FDepthMap);
  end;
  { Switching to the depth-map source: rebuild the face targets and restart
    the spawn animation so the old mesh/photo cloud does not bleed through. }
  if Assigned(FDepthMap) then
  begin
    FSourceType := srcDepthMap;
    if FGLReady then
    begin
      GenerateFaceTargets;
      ReinitParticlesForForming;
      FState := csForming;
      FBuildScanY := FMinY;
      FDespawnScanY := FMinY;
    end;
  end;
end;
//==============================================================================
// GL Setup
//==============================================================================

function TSkChaos.InitOffscreenGL: Boolean;
var
  PFD: TPixelFormatDescriptor;
  PixFmt: Integer;
  WndClass: TWndClassW;
  Attribs: array[0..4] of Integer;
  DC: HDC;
begin
  Result := False;
  if FGLReady then
    Exit(True);
  if FGLFailed then
    Exit(False);
  FillChar(WndClass, SizeOf(WndClass), 0);
  WndClass.lpfnWndProc := @DefWindowProcW;
  WndClass.hInstance := HInstance;
  WndClass.lpszClassName := 'ChaosGPUOffscreen';
  RegisterClassW(WndClass);
  FDummyWnd := CreateWindowExW(0, WndClass.lpszClassName, '', WS_POPUP, 0, 0, 16, 16, 0, 0, HInstance, nil);
  if FDummyWnd = 0 then
  begin
    FGLFailed := True;
    Exit;
  end;
  FDummyDC := GetDC(FDummyWnd);
  ZeroMemory(@PFD, SizeOf(PFD));
  PFD.nSize := SizeOf(PFD);
  PFD.nVersion := 1;
  PFD.dwFlags := PFD_DRAW_TO_WINDOW or PFD_SUPPORT_OPENGL or PFD_DOUBLEBUFFER;
  PFD.iPixelType := PFD_TYPE_RGBA;
  PFD.cColorBits := 32;
  PFD.cAlphaBits := 8;
  PixFmt := ChoosePixelFormat(FDummyDC, @PFD);
  if PixFmt = 0 then
  begin
    FGLFailed := True;
    Exit;
  end;
  SetPixelFormat(FDummyDC, PixFmt, @PFD);
  FGLContext := wglCreateContext(FDummyDC);
  if FGLContext = 0 then
  begin
    FGLFailed := True;
    Exit;
  end;
  wglMakeCurrent(FDummyDC, FGLContext);
  LoadGLFunctions;
  if not Assigned(FnCreateContextAttribs) then
  begin
    FGLFailed := True;
    Exit;
  end;
  Attribs[0] := WGL_CONTEXT_MAJOR_VERSION_ARB;
  Attribs[1] := 4;
  Attribs[2] := WGL_CONTEXT_MINOR_VERSION_ARB;
  Attribs[3] := 3;
  Attribs[4] := 0;
  DC := FDummyDC;
  wglMakeCurrent(0, 0);
  wglDeleteContext(FGLContext);
  FGLContext := FnCreateContextAttribs(DC, 0, @Attribs[0]);
  if FGLContext = 0 then
  begin
    FGLFailed := True;
    Exit;
  end;
  wglMakeCurrent(DC, FGLContext);
  InitShaders;
  InitGLResources;
  FGLReady := True;
  Result := True;
end;

procedure TSkChaos.CleanupOffscreenGL;
begin
  if FGLContext <> 0 then
  begin
    wglMakeCurrent(0, 0);
    wglDeleteContext(FGLContext);
    FGLContext := 0;
  end;
  if FDummyDC <> 0 then
  begin
    ReleaseDC(FDummyWnd, FDummyDC);
    FDummyDC := 0;
  end;
  if FDummyWnd <> 0 then
  begin
    DestroyWindow(FDummyWnd);
    FDummyWnd := 0;
  end;
  FGLReady := False;
end;

procedure TSkChaos.LoadGLFunctions;

  function GetProc(const Name: AnsiString): Pointer;
  begin
    Result := wglGetProcAddress(PAnsiChar(Name));
    if (Result = nil) or (NativeUInt(Result) <= 3) or (NativeUInt(Result) = NativeUInt(-1)) then
      Result := GetProcAddress(GetModuleHandle('opengl32.dll'), PAnsiChar(Name));
  end;

begin
  FnCreateShader := GetProc('glCreateShader');
  FnDeleteShader := GetProc('glDeleteShader');
  FnShaderSource := GetProc('glShaderSource');
  FnCompileShader := GetProc('glCompileShader');
  FnGetShaderiv := GetProc('glGetShaderiv');
  FnGetShaderInfoLog := GetProc('glGetShaderInfoLog');
  FnCreateProgram := GetProc('glCreateProgram');
  FnAttachShader := GetProc('glAttachShader');
  FnLinkProgram := GetProc('glLinkProgram');
  FnDeleteProgram := GetProc('glDeleteProgram');
  FnGetProgramiv := GetProc('glGetProgramiv');
  FnGetProgramInfoLog := GetProc('glGetProgramInfoLog');
  FnUseProgram := GetProc('glUseProgram');
  FnGetUniformLocation := GetProc('glGetUniformLocation');
  FnUniform1f := GetProc('glUniform1f');
  FnUniform2f := GetProc('glUniform2f');
  FnUniform4f := GetProc('glUniform4f');
  FnUniform1i := GetProc('glUniform1i');
  FnUniform1ui := GetProc('glUniform1ui');
  FnDispatchCompute := GetProc('glDispatchCompute');
  FnMemoryBarrier := GetProc('glMemoryBarrier');
  FnGenBuffers := GetProc('glGenBuffers');
  FnDeleteBuffers := GetProc('glDeleteBuffers');
  FnBindBuffer := GetProc('glBindBuffer');
  FnBufferData := GetProc('glBufferData');
  FnBufferSubData := GetProc('glBufferSubData');
  FnBindBufferBase := GetProc('glBindBufferBase');
  FnMapBufferRange := GetProc('glMapBufferRange');
  FnUnmapBuffer := GetProc('glUnmapBuffer');
  FnGenTextures := GetProc('glGenTextures');
  FnDeleteTextures := GetProc('glDeleteTextures');
  FnBindTexture := GetProc('glBindTexture');
  FnTexParameteri := GetProc('glTexParameteri');
  FnTexStorage2D := GetProc('glTexStorage2D');
  FnActiveTexture := GetProc('glActiveTexture');
  FnBindImageTexture := GetProc('glBindImageTexture');
  FnGetTexImage := GetProc('glGetTexImage');
  FnCreateContextAttribs := GetProc('wglCreateContextAttribsARB');
  if not Assigned(FnDispatchCompute) or not Assigned(FnBindImageTexture) then
    raise Exception.Create('OpenGL 4.3 Compute Shaders nicht verfuegbar');
end;

function TSkChaos.CompileShader(AShaderType: Cardinal; const ASrc: AnsiString): Cardinal;
var
  SrcPtr: PAnsiChar;
  Len, Status, LogLen: Integer;
  Log: AnsiString;
begin
  Result := FnCreateShader(AShaderType);
  SrcPtr := PAnsiChar(ASrc);
  Len := Length(ASrc);
  FnShaderSource(Result, 1, @SrcPtr, @Len);
  FnCompileShader(Result);
  FnGetShaderiv(Result, GL_COMPILE_STATUS, @Status);
  if Status = 0 then
  begin
    FnGetShaderiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(Log, LogLen);
    if LogLen > 0 then
      FnGetShaderInfoLog(Result, LogLen, nil, PAnsiChar(Log));
    FnDeleteShader(Result);
    raise Exception.Create('Shader compile error: ' + string(Log));
  end;
end;

function TSkChaos.LinkProgram(const AShaders: array of Cardinal): Cardinal;
var
  I, Status, LogLen: Integer;
  Log: AnsiString;
begin
  Result := FnCreateProgram;
  for I := Low(AShaders) to High(AShaders) do
    FnAttachShader(Result, AShaders[I]);
  FnLinkProgram(Result);
  FnGetProgramiv(Result, GL_LINK_STATUS, @Status);
  if Status = 0 then
  begin
    FnGetProgramiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(Log, LogLen);
    if LogLen > 0 then
      FnGetProgramInfoLog(Result, LogLen, nil, PAnsiChar(Log));
    FnDeleteProgram(Result);
    raise Exception.Create('Program link error: ' + string(Log));
  end;
  for I := Low(AShaders) to High(AShaders) do
    FnDeleteShader(AShaders[I]);
end;

procedure TSkChaos.InitShaders;
var
  PS, CS, BS, HS: Cardinal;
begin
  PS := CompileShader(GL_COMPUTE_SHADER, PARTICLE_SRC);
  CS := CompileShader(GL_COMPUTE_SHADER, CLEAR_SRC);
  BS := CompileShader(GL_COMPUTE_SHADER, BLUR_SRC);
  FParticleProgram := LinkProgram([PS]);
  FClearProgram := LinkProgram([CS]);
  FBlurProgram := LinkProgram([BS]);
  FnUseProgram(FParticleProgram);
  FLocP_DeltaTime := FnGetUniformLocation(FParticleProgram, 'uDeltaTime');
  FLocP_Time := FnGetUniformLocation(FParticleProgram, 'uTime');
  FLocP_Resolution := FnGetUniformLocation(FParticleProgram, 'uResolution');
  FLocP_ParticleCount := FnGetUniformLocation(FParticleProgram, 'uParticleCount');
  FLocP_BuildScanY := FnGetUniformLocation(FParticleProgram, 'uBuildScanY');
  FLocP_DespawnScanY := FnGetUniformLocation(FParticleProgram, 'uDespawnScanY');
  FLocP_State := FnGetUniformLocation(FParticleProgram, 'uState');
  FLocP_ChaosLevel := FnGetUniformLocation(FParticleProgram, 'uChaosLevel');
  FLocP_MouthOpen := FnGetUniformLocation(FParticleProgram, 'uMouthOpen');
  FLocP_EyeOpeness := FnGetUniformLocation(FParticleProgram, 'uEyeOpeness');
  FLocP_LookX := FnGetUniformLocation(FParticleProgram, 'uLookX');
  FLocP_LookY := FnGetUniformLocation(FParticleProgram, 'uLookY');
  FLocP_PivotY := FnGetUniformLocation(FParticleProgram, 'uPivotY');
  FLocP_EmotionMode := FnGetUniformLocation(FParticleProgram, 'uEmotionMode');
  FLocP_FaceColor := FnGetUniformLocation(FParticleProgram, 'uFaceColor');
  FLocP_EyeColor := FnGetUniformLocation(FParticleProgram, 'uEyeColor');
  FLocP_MouthColor := FnGetUniformLocation(FParticleProgram, 'uMouthColor');
  FLocP_AccentColor := FnGetUniformLocation(FParticleProgram, 'uAccentColor');
  FLocP_HighlightRect := FnGetUniformLocation(FParticleProgram, 'uHighlightRect');
  FLocP_HighlightPulse := FnGetUniformLocation(FParticleProgram, 'uHighlightPulse');
  FLocP_MinY := FnGetUniformLocation(FParticleProgram, 'uMinY');
  FLocP_MaxY := FnGetUniformLocation(FParticleProgram, 'uMaxY');
  FnUseProgram(FClearProgram);
  FLocC_Resolution := FnGetUniformLocation(FClearProgram, 'uResolution');
  FnUseProgram(FBlurProgram);
  FLocB_Resolution := FnGetUniformLocation(FBlurProgram, 'uResolution');
  FLocB_Horizontal := FnGetUniformLocation(FBlurProgram, 'uHorizontal');
  FnUseProgram(0);
  { Holographic style shader for mesh / photo / hybrid sources. }
  HS := CompileShader(GL_COMPUTE_SHADER, HOLO_PARTICLE_SRC);
  FHoloProgram := LinkProgram([HS]);
  FnUseProgram(FHoloProgram);
  FLocH_DeltaTime := FnGetUniformLocation(FHoloProgram, 'uDeltaTime');
  FLocH_Time := FnGetUniformLocation(FHoloProgram, 'uTime');
  FLocH_Resolution := FnGetUniformLocation(FHoloProgram, 'uResolution');
  FLocH_ParticleCount := FnGetUniformLocation(FHoloProgram, 'uParticleCount');
  FLocH_State := FnGetUniformLocation(FHoloProgram, 'uState');
  FLocH_BuildScanY := FnGetUniformLocation(FHoloProgram, 'uBuildScanY');
  FLocH_DespawnScanY := FnGetUniformLocation(FHoloProgram, 'uDespawnScanY');
  FLocH_LookX := FnGetUniformLocation(FHoloProgram, 'uLookX');
  FLocH_LookY := FnGetUniformLocation(FHoloProgram, 'uLookY');
  FLocH_PivotY := FnGetUniformLocation(FHoloProgram, 'uPivotY');
  FLocH_HoloStyle := FnGetUniformLocation(FHoloProgram, 'uHoloStyle');
  FLocH_ParticleSize := FnGetUniformLocation(FHoloProgram, 'uParticleSize');
  FLocH_GlowIntensity := FnGetUniformLocation(FHoloProgram, 'uGlowIntensity');
  FLocH_RimLightStrength := FnGetUniformLocation(FHoloProgram, 'uRimLightStrength');
  FLocH_Alpha := FnGetUniformLocation(FHoloProgram, 'uAlpha');
  FLocH_Jitter := FnGetUniformLocation(FHoloProgram, 'uJitter');
  FLocH_FaceColor := FnGetUniformLocation(FHoloProgram, 'uFaceColor');
  FLocH_AccentColor := FnGetUniformLocation(FHoloProgram, 'uAccentColor');
  FnUseProgram(0);
end;

procedure TSkChaos.InitGLResources;
var
  SSBOSize: NativeInt;
begin
  FnGenBuffers(1, @FParticleSSBO);
  SSBOSize := NativeInt(PARTICLE_MAX) * SSBO_PARTICLE_SIZE;
  FnBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  FnBufferData(GL_SHADER_STORAGE_BUFFER, SSBOSize, nil, GL_DYNAMIC_COPY);
  FnBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  SetLength(FParticleCPU, SSBOSize);
  FillChar(FParticleCPU[0], SSBOSize, 0);
end;

procedure TSkChaos.EnsureOutputTexture(W, H: Integer);
var
  I: Integer;

  procedure SetupTex(Tex: Cardinal);
  begin
    FnBindTexture(GL_TEXTURE_2D, Tex);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    FnTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
  end;

begin
  if FOutputTex <> 0 then
    FnDeleteTextures(1, @FOutputTex);
  if FTempTex <> 0 then
    FnDeleteTextures(1, @FTempTex);
  FnGenTextures(1, @FOutputTex);
  FnGenTextures(1, @FTempTex);
  SetupTex(FOutputTex);
  SetupTex(FTempTex);
  SetLength(FPixelBuffer, W * H * 4);
  FillChar(FPixelBuffer[0], Length(FPixelBuffer), 0);
  FPBOSize := W * H * 4;
  for I := 0 to 1 do
    if FPBOs[I] <> 0 then
      FnDeleteBuffers(1, @FPBOs[I]);
  FnGenBuffers(2, @FPBOs[0]);
  for I := 0 to 1 do
  begin
    FnBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
    FnBufferData(GL_PIXEL_PACK_BUFFER, FPBOSize, nil, GL_STREAM_READ);
  end;
  FnBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  FPBOIndex := 0;
  FPBOHasData := False;
end;
//==============================================================================
// Face-Targets
//==============================================================================

procedure TSkChaos.GenerateFaceTargets;
var
  X, Y, Step, OffsetY, Idx, BudgetUsed: Integer;
  BitmapData: FMX.Graphics.TBitmapData;
  PixelColor: TAlphaColor;
  R: Byte;
  Helligkeit: Single;
  P: ^TParticleCPU;
  CenterX, CenterY: Single;
  DepthW, DepthH: Integer;

  procedure AddParticle(AFlag: Cardinal; AX, AY, AZ: Single);
  begin
    if BudgetUsed >= Integer(FParticleBudget) then
      Exit;
    P := @FParticleCPU[BudgetUsed * SSBO_PARTICLE_SIZE];
    FillChar(P^, SSBO_PARTICLE_SIZE, 0);
    P.PX := AX;
    P.PY := AY;
    P.PZ := AZ;
    P.TX := AX;
    P.TY := AY;
    P.TZ := AZ;
    P.Color := $FF00BFFF;
    P.Flags := AFlag;
    Inc(BudgetUsed);
  end;

  function GetPixel(X, Y: Integer): TAlphaColor;
  var
    PixPtr: PCardinal;
  begin
    PixPtr := PCardinal(PByte(BitmapData.Data) + (Y * BitmapData.Pitch) + (X * 4));
    Result := PixPtr^;
  end;

begin
  if not Assigned(FDepthMap) then
    Exit;
  if not FDepthMap.Map(TMapAccess.Read, BitmapData) then
    Exit;
  try
    DepthW := FDepthMap.Width;
    DepthH := FDepthMap.Height;
    BudgetUsed := 0;
    CenterX := DepthW / 2;
    CenterY := (DepthH - 28) / 2;
    FMinY := 10000;
    FMaxY := -10000;
    Step := DEPTH_MAP_STEP;
    OffsetY := 28;
    for Y := OffsetY to DepthH - 1 do
    begin
      if ((Y - OffsetY) mod Step) <> 0 then
        Continue;
      for X := 0 to DepthW - 1 do
      begin
        if (X mod Step) <> 0 then
          Continue;
        PixelColor := GetPixel(X, Y);
        R := (PixelColor shr 16) and $FF;
        if R > 5 then
        begin
          Helligkeit := R / 255.0;
          AddParticle(1, (X - CenterX) * FScaleFactor, ((Y - OffsetY) - CenterY) * FScaleFactor, Helligkeit * 112.5);
          if P.PY < FMinY then
            FMinY := P.PY;
          if P.PY > FMaxY then
            FMaxY := P.PY;
        end;
      end;
    end;
    for Idx := 0 to 49 do
      AddParticle(2, (-45 + Cos((Idx / 50) * 2 * Pi) * 22), (-50 + Sin((Idx / 50) * 2 * Pi) * 8), 40.0);
    for Idx := 0 to 49 do
      AddParticle(3, (45 + Cos((Idx / 50) * 2 * Pi) * 22), (-50 + Sin((Idx / 50) * 2 * Pi) * 8), 40.0);
    for Idx := 0 to 39 do
      AddParticle(4, Cos((Idx / 40) * 2 * Pi) * 35, (65 + Sin((Idx / 40) * 2 * Pi) * 4), 35.0);
    FPivotY := FMinY + (FMaxY - FMinY) * FNeckPivotRatio;
    FParticleCount := BudgetUsed;
  finally
    FDepthMap.Unmap(BitmapData);
  end;
end;

procedure TSkChaos.UploadSSBO;
begin
  if FParticleSSBO = 0 then
    Exit;
  FnBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
  FnBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, NativeInt(FParticleCount) * SSBO_PARTICLE_SIZE, @FParticleCPU[0]);
  FnBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TSkChaos.ReinitParticlesForForming;
var
  I: Integer;
  P: ^TParticleCPU;
begin
  // Scatter every particle to a random start offset near the vertical centre
  // so the forming animation lerps them toward their target (zoom-in effect
  // matching the CPU version's "Pos3D := Target + Random(30)-15, -15+Random(15)").
  for I := 0 to Integer(FParticleCount) - 1 do
  begin
    P := @FParticleCPU[I * SSBO_PARTICLE_SIZE];
    P^.PX := P^.TX + (Random(30) - 15);
    P^.PY := -15 + Random(15);
    P^.PZ := P^.TZ;
    P^.VX := 0;
    P^.VY := 0;
    P^.VZ := 0;
  end;
  UploadSSBO;
end;
//==============================================================================
// Uniforms / Dispatch
//==============================================================================

procedure ColorToVec4(C: TAlphaColor; out R, G, B, A: Single);
begin
  R := (C shr 16 and $FF) / 255;
  G := (C shr 8 and $FF) / 255;
  B := (C and $FF) / 255;
  A := (C shr 24 and $FF) / 255;
end;

procedure TSkChaos.ApplyUniforms(ATime, ADeltaTime: Double);
var
  R, G, B, A: Single;
  StateInt, OrdEmo: Integer;
begin
  FnUseProgram(FParticleProgram);
  case FState of
    csForming:
      StateInt := 0;
    csActive:
      StateInt := 1;
    csFading:
      StateInt := 2;
    csFinished:
      StateInt := 3;
  else
    StateInt := 0;
  end;
  FnUniform1f(FLocP_DeltaTime, ADeltaTime);
  FnUniform1f(FLocP_Time, ATime);
  FnUniform2f(FLocP_Resolution, CHAOS_WIDTH, CHAOS_HEIGHT);
  FnUniform1ui(FLocP_ParticleCount, FParticleCount);
  FnUniform1f(FLocP_BuildScanY, FBuildScanY);
  FnUniform1f(FLocP_DespawnScanY, FDespawnScanY);
  FnUniform1i(FLocP_State, StateInt);
  FnUniform1f(FLocP_ChaosLevel, FChaosLevel);
  FnUniform1f(FLocP_MouthOpen, FMouthOpen);
  FnUniform1f(FLocP_EyeOpeness, FEyeOpeness);
  FnUniform1f(FLocP_LookX, FLookX);
  FnUniform1f(FLocP_LookY, FLookY);
  FnUniform1f(FLocP_PivotY, FPivotY);
  OrdEmo := Ord(FEmotionMode);
  FnUniform1i(FLocP_EmotionMode, OrdEmo);
  ColorToVec4(FFaceColor, R, G, B, A);
  FnUniform4f(FLocP_FaceColor, R, G, B, A);
  ColorToVec4(FEyeColor, R, G, B, A);
  FnUniform4f(FLocP_EyeColor, R, G, B, A);
  ColorToVec4(FMouthColor, R, G, B, A);
  FnUniform4f(FLocP_MouthColor, R, G, B, A);
  ColorToVec4(FAccentColor, R, G, B, A);
  FnUniform4f(FLocP_AccentColor, R, G, B, A);
end;

procedure TSkChaos.DispatchClear;
var
  GX, GY: Cardinal;
begin
  FnUseProgram(FClearProgram);
  FnUniform2f(FLocC_Resolution, CHAOS_WIDTH, CHAOS_HEIGHT);
  FnBindImageTexture(0, FOutputTex, 0, 0, 0, GL_WRITE_ONLY, GL_RGBA8);
  GX := (Cardinal(CHAOS_WIDTH) + 15) div 16;
  GY := (Cardinal(CHAOS_HEIGHT) + 15) div 16;
  FnDispatchCompute(GX, GY, 1);
  FnMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  FnUseProgram(0);
end;

procedure TSkChaos.DispatchFrame(ADeltaTime, ATime: Double);
var
  TotalGroups, GX, GY: Cardinal;
begin
  FnUseProgram(FParticleProgram);
  ApplyUniforms(ATime, ADeltaTime);
  FnBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  FnBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FParticleSSBO);
  TotalGroups := (FParticleCount + 255) div 256;
  GX := TotalGroups;
  GY := 1;
  if GX > 65535 then
  begin
    GX := 65535;
    GY := (TotalGroups + 65534) div 65535;
  end;
  FnDispatchCompute(GX, GY, 1);
  FnMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT or GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  FnUseProgram(0);
end;

procedure TSkChaos.DispatchBlur(AHorizontal: Boolean);
var
  GX, GY, InputTex, OutputTex: Cardinal;
begin
  FnUseProgram(FBlurProgram);
  FnUniform2f(FLocB_Resolution, CHAOS_WIDTH, CHAOS_HEIGHT);
  if AHorizontal then
  begin
    FnUniform1i(FLocB_Horizontal, 1);
    InputTex := FOutputTex;
    OutputTex := FTempTex;
  end
  else
  begin
    FnUniform1i(FLocB_Horizontal, 0);
    InputTex := FTempTex;
    OutputTex := FOutputTex;
  end;
  FnBindImageTexture(0, InputTex, 0, 0, 0, GL_READ_ONLY, GL_RGBA8);
  FnBindImageTexture(1, OutputTex, 0, 0, 0, GL_WRITE_ONLY, GL_RGBA8);
  GX := (Cardinal(CHAOS_WIDTH) + 15) div 16;
  GY := (Cardinal(CHAOS_HEIGHT) + 15) div 16;
  FnDispatchCompute(GX, GY, 1);
  FnMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  FnUseProgram(0);
end;

procedure TSkChaos.ReadbackToPixelBuffer;
var
  ReadPBO, WritePBO: Cardinal;
  Mapped: Pointer;
begin
  if FPBOHasData then
  begin
    ReadPBO := FPBOs[FPBOIndex xor 1];
    FnBindBuffer(GL_PIXEL_PACK_BUFFER, ReadPBO);
    Mapped := FnMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT);
    if Mapped <> nil then
    begin
      System.Move(Mapped^, Pointer(FPixelBuffer)^, FPBOSize);
      FnUnmapBuffer(GL_PIXEL_PACK_BUFFER);
    end;
    FnBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  end;
  WritePBO := FPBOs[FPBOIndex];
  FnBindBuffer(GL_PIXEL_PACK_BUFFER, WritePBO);
  FnBindTexture(GL_TEXTURE_2D, FOutputTex);
  FnGetTexImage(GL_TEXTURE_2D, 0, GL_BGRA, GL_UNSIGNED_BYTE, nil);
  FnBindTexture(GL_TEXTURE_2D, 0);
  FnBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  FPBOIndex := FPBOIndex xor 1;
  FPBOHasData := True;
end;
//==============================================================================
// RenderEffect
//==============================================================================

procedure TSkChaos.RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double);
var
  ImgInfo: TSkImageInfo;
  GPUImg: ISkImage;
  DeltaTime: Double;
  ScanSpeed: Single;
  Cur: TPoint;
  C: TPointF;
begin
  if not Active then
  begin
    inherited RenderEffect(ACanvas, ADest, ATime);
    Exit;
  end;
  if not FGLReady then
  begin
    wglMakeCurrent(0, 0);
    if not InitOffscreenGL then
      Exit;
    EnsureOutputTexture(CHAOS_WIDTH, CHAOS_HEIGHT);
    if FSourceType = srcDepthMap then
      GenerateFaceTargets
    else
      BuildMeshTargets(FMeshResult.Points);
    UploadSSBO;
    FLastTime := 0;
  end;
  wglMakeCurrent(FDummyDC, FGLContext);

  // Real DeltaTime from the monotonic ATime the base thread passes in.
  if FLastTime = 0 then
    DeltaTime := 1.0 / 60.0
  else
    DeltaTime := ATime - FLastTime;
  FLastTime := ATime;
  if (DeltaTime <= 0) or (DeltaTime > 0.25) then
    DeltaTime := 1.0 / 60.0;

  { Mouse-follow: smoothly steer the look direction toward the cursor,
    or ease back to centre when the option is off. }
  if FMouseFollow then
  begin
    if GetCursorPos(Cur) then
    begin
      C := Self.LocalToScreen(PointF(Self.Width * 0.5, Self.Height * 0.5));
      FLookTargetX := EnsureRange((Cur.X - C.X) / 300, -1.2, 1.2);
      FLookTargetY := EnsureRange((Cur.Y - C.Y) / 300, -0.9, 0.9);
    end;
  end
  else
  begin
    FLookTargetX := 0;
    FLookTargetY := 0;
  end;
  FLookX := FLookX + (FLookTargetX - FLookX) * EnsureRange(6.0 * DeltaTime, 0, 1);
  FLookY := FLookY + (FLookTargetY - FLookY) * EnsureRange(6.0 * DeltaTime, 0, 1);

  FGlobalTime := ATime;

  // First activation: kick off the forming animation.
  if FState = csIdle then
  begin
    ReinitParticlesForForming;
    FState := csForming;
    FBuildScanY := FMinY;
    FDespawnScanY := FMinY;
  end;

  // Advance the build-up scanline; transition to Active when it passed the
  // lowest particle. Matches CPU BUILD_TIME = 1.5s.
  if FState = csForming then
  begin
    ScanSpeed := (FMaxY - FMinY + 50) / 1.5;
    FBuildScanY := FBuildScanY + ScanSpeed * DeltaTime;
    if FBuildScanY >= FMaxY + 50 then
      FState := csActive;
  end;

  // Despawn scanline advances so particles below it drop with gravity,
  // mirroring the forming reveal; transitions to csFinished when done.
  if FState = csFading then
  begin
    ScanSpeed := (FMaxY - FMinY + 200) / 1.8;
    FDespawnScanY := FDespawnScanY + ScanSpeed * DeltaTime;
    if FDespawnScanY >= FMaxY + 200 then
    begin
      FState := csFinished;
      if FQuitAfterDespawn then
        TThread.Queue(nil,
          procedure
          begin
            Application.Terminate;
          end);
    end;
  end;

  // Per-frame pipeline: clear -> particles -> blur H -> blur V -> readback.
  if FSourceType <> srcDepthMap then
    AdvanceMorphAnimation(DeltaTime);
  DispatchClear;
  if FSourceType = srcDepthMap then
    DispatchFrame(DeltaTime, ATime)
  else
    DispatchHoloFrame(DeltaTime, ATime);
 // DispatchBlur(True);    // output -> temp
 // DispatchBlur(False);   // temp   -> output
  ReadbackToPixelBuffer;

  ACanvas.Clear($00000000);
  if FPBOHasData and (Length(FPixelBuffer) > 0) then
  begin
    ImgInfo := TSkImageInfo.Create(CHAOS_WIDTH, CHAOS_HEIGHT, TSkColorType.BGRA8888, TSkAlphaType.Premul);
    GPUImg := TSkImage.MakeFromRaster(ImgInfo, PByte(FPixelBuffer), CHAOS_WIDTH * 4);
    if Assigned(GPUImg) then
      ACanvas.DrawImageRect(GPUImg, RectF(0, 0, CHAOS_WIDTH, CHAOS_HEIGHT), RectF(0, 0, CHAOS_WIDTH, CHAOS_HEIGHT), TSkSamplingOptions.Medium);
  end;
end;
//==============================================================================
// Properties
//==============================================================================

procedure TSkChaos.SetMouthState(const Value: TMouthState);
begin
  NotifyActivity;
  FMouthState := Value;
  case Value of
    msClosed:
      FMouthOpen := 0.0;
    msMin:
      FMouthOpen := 0.15;
    msMid:
      FMouthOpen := 0.55;
    msFull:
      FMouthOpen := 1.0;
  end;
end;

procedure TSkChaos.SetEyeState(const Value: TEyeState);
begin
  NotifyActivity;
  FEyeState := Value;
  case Value of
    esOpen:
      FEyeOpeness := 1.0;
    esMid:
      FEyeOpeness := 0.4;
    esClosed:
      FEyeOpeness := 0.05;
  end;
end;

procedure TSkChaos.SetEmotionMode(const Value: TEmotionMode);
begin
  NotifyActivity;
  FEmotionMode := Value;
  case Value of
    emAlert:
      FAccentColor := $FFFF4040;
    emHappy:
      FAccentColor := $FF40FF80;
    emThinking:
      FAccentColor := $FFC040FF;
  else
    FAccentColor := $FF00BFFF;
  end;
end;

{==============================================================================
  Multi-source loaders + holographic style dispatch
==============================================================================}

function ClampNormal16(V: Single): Word;
begin
  { Quantize a signed normal component (-1..1) into an unsigned 16-bit field
    so it packs into the unused Pad0/Pad1 cardinals of TParticleCPU. }
  Result := Word(Round((EnsureRange(V, -1, 1) * 0.5 + 0.5) * 65535));
end;

procedure TSkChaos.BuildMeshTargets(const APoints: TArray<TMeshParticlePoint>);
var
  I, BudgetUsed: Integer;
  P: ^TParticleCPU;
  Pos: TPoint3D;
  Region: Cardinal;
  IsHead, MakeInner: Boolean;
begin
  BudgetUsed := 0;
  FMinY := 10000;
  FMaxY := -10000;
  for I := 0 to High(APoints) do
  begin
    if BudgetUsed >= Integer(FParticleBudget) then
      Break;
    P := @FParticleCPU[BudgetUsed * SSBO_PARTICLE_SIZE];
    FillChar(P^, SSBO_PARTICLE_SIZE, 0);
    Pos := APoints[I].Position;
    P^.PX := Pos.X;
    P^.PY := Pos.Y;
    P^.PZ := Pos.Z;
    P^.TX := Pos.X;
    P^.TY := Pos.Y;
    P^.TZ := Pos.Z;
    { A white colour means the source had no real tint (mesh body); use the
      face colour. Photo / hybrid particles carry their true RGB instead. }
    if APoints[I].Color = $FFFFFFFF then
      P^.Color := FFaceColor
    else
      P^.Color := APoints[I].Color;
    { Body-region id in the low nibble drives contour / circuit placement. }
    case APoints[I].BodyPart of
      bpHead:
        Region := 1;
      bpNeck, bpTorso:
        Region := 2;
      bpUpperArmLeft, bpUpperArmRight, bpLowerArmLeft, bpLowerArmRight, bpHandLeft, bpHandRight:
        Region := 3;
      bpUpperLegLeft, bpUpperLegRight, bpLowerLegLeft, bpLowerLegRight, bpFootLeft, bpFootRight:
        Region := 4;
    else
      Region := 1;
    end;
    IsHead := APoints[I].BodyPart = bpHead;
    { Every third head particle becomes an inner brain-core point so the
      volumetric style forms a pulsating inner layer (~33 %). }
    MakeInner := FInnerCore and IsHead and ((I mod 3) = 0);
    P^.Flags := Region;
    if MakeInner then
      P^.Flags := P^.Flags or PARTICLE_FLAG_INNER_CORE;
    { Pack the surface normal into the pad fields for the rim-light shader. }
    P^.Pad0 := Cardinal(ClampNormal16(APoints[I].Normal.X)) or (Cardinal(ClampNormal16(APoints[I].Normal.Y)) shl 16);
    P^.Pad1 := Cardinal(ClampNormal16(APoints[I].Normal.Z));
    if P^.TY < FMinY then
      FMinY := P^.TY;
    if P^.TY > FMaxY then
      FMaxY := P^.TY;
    Inc(BudgetUsed);
  end;
  { Neck pivot: 1/3 down from the top of the target Y range so the head
    rotates toward the cursor while the shoulders stay put. }
  FPivotY := FMinY + (FMaxY - FMinY) * FNeckPivotRatio;
  FParticleCount := BudgetUsed;
end;

procedure TSkChaos.ApplyHoloUniforms(ATime, ADeltaTime: Double);
var
  StateInt: Integer;
  R, G, B, A: Single;
begin
  FnUseProgram(FHoloProgram);
  case FState of
    csForming:
      StateInt := 0;
    csActive:
      StateInt := 1;
    csFading:
      StateInt := 2;
    csFinished:
      StateInt := 3;
  else
    StateInt := 0;
  end;
  FnUniform1f(FLocH_DeltaTime, ADeltaTime);
  FnUniform1f(FLocH_Time, ATime);
  FnUniform2f(FLocH_Resolution, CHAOS_WIDTH, CHAOS_HEIGHT);
  FnUniform1ui(FLocH_ParticleCount, FParticleCount);
  FnUniform1i(FLocH_State, StateInt);
  FnUniform1f(FLocH_BuildScanY, FBuildScanY);
  FnUniform1f(FLocH_DespawnScanY, FDespawnScanY);
  FnUniform1f(FLocH_LookX, FLookX);
  FnUniform1f(FLocH_LookY, FLookY);
  FnUniform1f(FLocH_PivotY, FPivotY);
  FnUniform1i(FLocH_HoloStyle, Ord(FHoloStyle));
  FnUniform1f(FLocH_ParticleSize, FParticleSize);
  FnUniform1f(FLocH_GlowIntensity, FGlowIntensity);
  FnUniform1f(FLocH_RimLightStrength, FRimLightStrength);
  FnUniform1f(FLocH_Alpha, FHoloAlpha);
  FnUniform1f(FLocH_Jitter, FJitterAmount);
  ColorToVec4(FFaceColor, R, G, B, A);
  FnUniform4f(FLocH_FaceColor, R, G, B, A);
  ColorToVec4(FAccentColor, R, G, B, A);
  FnUniform4f(FLocH_AccentColor, R, G, B, A);
end;

procedure TSkChaos.DispatchHoloFrame(ADeltaTime, ATime: Double);
var
  TotalGroups, GX, GY: Cardinal;
begin
  FnUseProgram(FHoloProgram);
  ApplyHoloUniforms(ATime, ADeltaTime);
  FnBindImageTexture(0, FOutputTex, 0, 0, 0, GL_READ_WRITE, GL_RGBA8);
  FnBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FParticleSSBO);
  TotalGroups := (FParticleCount + 255) div 256;
  GX := TotalGroups;
  GY := 1;
  if GX > 65535 then
  begin
    GX := 65535;
    GY := (TotalGroups + 65534) div 65535;
  end;
  FnDispatchCompute(GX, GY, 1);
  FnMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT or GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);
  FnUseProgram(0);
end;

procedure TSkChaos.ApplyCurrentMorph;
var
  Weights: TArray<Single>;
  I, T: Integer;
  YSign, W: Single;
  D, Acc: TPoint3D;
begin
  if Length(FMeshBase) = 0 then
    Exit;
  if FActiveSequence >= 0 then
    Weights := TYutaniMeshLoader.SampleFrameWeights(FMeshResult.VertexFrames[FActiveSequence], FAnimTime)
  else
    Weights := FMorphWeights;
  { Always reset the working copy to the pristine base before accumulating
    deltas so weights stay stable across calls. }
  for I := 0 to High(FMeshBase) do
    FMeshResult.Points[I].Position := FMeshBase[I].Position;
  if (Length(Weights) = 0) or (Length(FMeshResult.MorphTargets) = 0) then
    Exit;
  if FMeshFlipY then
    YSign := -1
  else
    YSign := 1;
  for T := 0 to High(FMeshResult.MorphTargets) do
  begin
    if T > High(Weights) then
      Break;
    W := Weights[T];
    if W = 0 then
      Continue;
    if Length(FMeshResult.MorphTargets[T].PositionDeltas) <> Length(FMeshBase) then
      Continue;
    for I := 0 to High(FMeshBase) do
    begin
      D := FMeshResult.MorphTargets[T].PositionDeltas[I];
      { Deltas live in raw glTF space; apply the same uniform scale and Y
        flip the base went through so morphing stays aligned. }
      D := TPoint3D.Create(D.X * FMeshScale, D.Y * FMeshScale * YSign, D.Z * FMeshScale);
      Acc := FMeshResult.Points[I].Position;
      FMeshResult.Points[I].Position := TPoint3D.Create(Acc.X + D.X * W, Acc.Y + D.Y * W, Acc.Z + D.Z * W);
    end;
  end;
end;

procedure TSkChaos.UpdateTargetsFromMesh;
var
  I: Integer;
  P: ^TParticleCPU;
begin
  if (FParticleCount = 0) or (Length(FMeshResult.Points) = 0) then
    Exit;
  for I := 0 to Integer(FParticleCount) - 1 do
  begin
    if I > High(FMeshResult.Points) then
      Break;
    P := @FParticleCPU[I * SSBO_PARTICLE_SIZE];
    P^.TX := FMeshResult.Points[I].Position.X;
    P^.TY := FMeshResult.Points[I].Position.Y;
    P^.TZ := FMeshResult.Points[I].Position.Z;
  end;
  UploadSSBO;
end;

procedure TSkChaos.AdvanceMorphAnimation(ADeltaTime: Double);
begin
  if (FSourceType = srcDepthMap) or (Length(FMeshBase) = 0) then
    Exit;
  if FActiveSequence >= 0 then
  begin
    { Sample the active vertex-frame sequence at the advanced time and push
      the resulting target positions into the SSBO. The spring physics in
      the shader lerps the particles toward these updated targets. }
    FAnimTime := FAnimTime + ADeltaTime;
    NotifyActivity;
    ApplyCurrentMorph;
    UpdateTargetsFromMesh;
  end;
end;

function TSkChaos.ProbeAutoAsset: string;
var
  ExePath, F: string;
  SR: TSearchRec;
begin
  Result := '';
  ExePath := ExtractFilePath(ParamStr(0));
  { Prefer the curated demo meshes, then fall back to any .glb / .obj beside
    the exe so a demo mesh loads regardless of its filename. }
  for F in ASSET_PROBE_LIST do
    if FileExists(ExePath + F) then
      Exit(ExePath + F);
  if FindFirst(ExePath + '*.glb', faAnyFile, SR) = 0 then
  try
    Result := ExePath + SR.Name;
  finally
    FindClose(SR);
  end;
  if Result = '' then
    if FindFirst(ExePath + '*.obj', faAnyFile, SR) = 0 then
    try
      Result := ExePath + SR.Name;
    finally
      FindClose(SR);
    end;
end;

procedure TSkChaos.LoadMeshFile(const AFileName: string; ATargetRadius: Single; AStep: Integer; AMaxParticles: Integer);
var
  Opt: TMeshLoadOptions;
begin
  Opt := TMeshLoadOptions.Default;
  Opt.TargetRadius := ATargetRadius;
  Opt.Step := Max(1, AStep);
  Opt.MaxParticles := AMaxParticles;
  FCurrentMeshFile := AFileName;
  FMeshResult := TYutaniMeshLoader.LoadFromFile(AFileName, Opt);
  FMeshBase := Copy(FMeshResult.Points);
  FMeshScale := FMeshResult.Scale;
  FMeshFlipY := Opt.FlipY;
  FSourceType := srcMesh;
  SetLength(FMorphWeights, Length(FMeshResult.MorphTargets));
  FActiveSequence := -1;
  FAnimTime := 0;
  ApplyCurrentMorph;
  if FHoloStyle = hsClassic then
    FHoloStyle := hsCyber;
  if FGLReady then
  begin
    BuildMeshTargets(FMeshResult.Points);
    { Wipe stale positions and restart the spawn animation so the previous
      mesh/photo cloud cannot bleed through as a morphing mix. }
    ReinitParticlesForForming;
    FState := csForming;
    FBuildScanY := FMinY;
    FDespawnScanY := FMinY;
  end;
  NotifyActivity;
end;

procedure TSkChaos.LoadPhotoFile(const AFileName: string; ATargetRadius: Single; AStep: Integer; AMaxParticles: Integer);
var
  Opt: TPhotoLoadOptions;
  Pts: TArray<TMeshParticlePoint>;
begin
  Opt := TPhotoLoadOptions.Default;
  Opt.TargetRadius := ATargetRadius;
  Opt.Step := Max(1, AStep);
  Opt.MaxParticles := AMaxParticles;
  FCurrentPhotoFile := AFileName;
  Pts := TYutaniPhotoTo3D.LoadFromFile(AFileName, Opt);
  FMeshResult.Points := Pts;
  FMeshResult.MorphTargets := nil;
  FMeshResult.VertexFrames := nil;
  FMeshResult.MeshNames := nil;
  FMeshBase := Copy(Pts);
  FMeshScale := 1.0;
  FMeshFlipY := Opt.FlipY;
  FSourceType := srcPhoto;
  SetLength(FMorphWeights, 0);
  FActiveSequence := -1;
  FAnimTime := 0;
  if FHoloStyle = hsClassic then
    FHoloStyle := hsPhoto;
  if FGLReady then
  begin
    BuildMeshTargets(Pts);
    ReinitParticlesForForming;
    FState := csForming;
    FBuildScanY := FMinY;
    FDespawnScanY := FMinY;
  end;
  NotifyActivity;
end;

procedure TSkChaos.LoadHybrid(const AMeshFile, APhotoFile: string);
var
  MeshOpt: TMeshLoadOptions;
  PhotoOpt: TPhotoLoadOptions;
  MeshPts, PhotoPts: TArray<TMeshParticlePoint>;
  Base, I: Integer;
begin
  MeshOpt := TMeshLoadOptions.Default;
  MeshOpt.TargetRadius := 180.0;
  MeshOpt.Step := 1;
  MeshOpt.MaxParticles := 90000;
  MeshPts := TYutaniMeshLoader.LoadFromFile(AMeshFile, MeshOpt).Points;
  PhotoOpt := TPhotoLoadOptions.Default;
  PhotoOpt.TargetRadius := 90.0;
  PhotoOpt.Step := 2;
  PhotoOpt.MaxParticles := 30000;
  PhotoPts := TYutaniPhotoTo3D.LoadFromFile(APhotoFile, PhotoOpt);
  { Stitch the photo face onto the upper third of the mesh body. }
  Base := Length(MeshPts);
  SetLength(FMeshResult.Points, Base + Length(PhotoPts));
  for I := 0 to Base - 1 do
    FMeshResult.Points[I] := MeshPts[I];
  for I := 0 to High(PhotoPts) do
  begin
    PhotoPts[I].Position := TPoint3D.Create(PhotoPts[I].Position.X, PhotoPts[I].Position.Y - 60.0, PhotoPts[I].Position.Z);
    FMeshResult.Points[Base + I] := PhotoPts[I];
  end;
  FMeshResult.MorphTargets := nil;
  FMeshResult.VertexFrames := nil;
  FMeshResult.MeshNames := nil;
  FMeshBase := Copy(FMeshResult.Points);
  FMeshScale := 1.0;
  FMeshFlipY := True;
  FSourceType := srcHybrid;
  SetLength(FMorphWeights, 0);
  FActiveSequence := -1;
  FAnimTime := 0;
  if FHoloStyle = hsClassic then
    FHoloStyle := hsCyber;
  if FGLReady then
  begin
    BuildMeshTargets(FMeshResult.Points);
    { Wipe stale positions and restart the spawn animation so the previous
      mesh/photo cloud cannot bleed through as a morphing mix. }
    ReinitParticlesForForming;
    FState := csForming;
    FBuildScanY := FMinY;
    FDespawnScanY := FMinY;
  end;
  NotifyActivity;
end;

procedure TSkChaos.SetMorphTargetWeight(const AName: string; AWeight: Single);
var
  Idx: Integer;
begin
  Idx := TYutaniMeshLoader.FindMorphTarget(FMeshResult.MorphTargets, AName);
  if Idx < 0 then
    Exit;
  if Idx > High(FMorphWeights) then
    SetLength(FMorphWeights, Idx + 1);
  FMorphWeights[Idx] := AWeight;
  { Manual control overrides any playing vertex-frame sequence. }
  FActiveSequence := -1;
  ApplyCurrentMorph;
  if FGLReady then
    UpdateTargetsFromMesh;
  NotifyActivity;
end;

procedure TSkChaos.PlayVertexFrame(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex > High(FMeshResult.VertexFrames)) then
    Exit;
  FActiveSequence := AIndex;
  FAnimTime := 0;
  NotifyActivity;
end;

procedure TSkChaos.SetHoloStyle(const Value: THoloStyle);
begin
  if FHoloStyle <> Value then
  begin
    FHoloStyle := Value;
    NotifyActivity;
  end;
end;

procedure TSkChaos.SetStepFilter(const Value: Integer);
begin
  if FStepFilter <> Value then
  begin
    FStepFilter := Max(1, Value);
    { Live retune: reload the currently loaded source with the updated
      stride. FCurrentMeshFile / FCurrentPhotoFile track what the user
      actually picked via the OpenDialog, so a StepFilter change no longer
      snaps back to the auto-detected demo mesh. }
    if (FSourceType = srcMesh) and (FCurrentMeshFile <> '') then
      LoadMeshFile(FCurrentMeshFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget)
    else if (FSourceType = srcPhoto) and (FCurrentPhotoFile <> '') then
      LoadPhotoFile(FCurrentPhotoFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget);
  end;
end;

procedure TSkChaos.SetParticleSize(const Value: Single);
begin
  if FParticleSize <> Value then
    FParticleSize := EnsureRange(Value, 0.1, 8.0);
end;

procedure TSkChaos.SetGlowIntensity(const Value: Single);
begin
  if FGlowIntensity <> Value then
    FGlowIntensity := EnsureRange(Value, 0.0, 4.0);
end;

procedure TSkChaos.SetRimLightStrength(const Value: Single);
begin
  if FRimLightStrength <> Value then
    FRimLightStrength := EnsureRange(Value, 0.0, 4.0);
end;

procedure TSkChaos.SetHoloAlpha(const Value: Single);
begin
  if FHoloAlpha <> Value then
    FHoloAlpha := EnsureRange(Value, 0.0, 1.0);
end;

procedure TSkChaos.SetJitterAmount(const Value: Single);
begin
  if FJitterAmount <> Value then
    FJitterAmount := EnsureRange(Value, 0.0, 2.0);
end;

procedure TSkChaos.Spawn;
begin
  if FParticleCount = 0 then
    Exit;
  ReinitParticlesForForming;
  FState := csForming;
  FBuildScanY := FMinY;
  FDespawnScanY := FMinY;
  NotifyActivity;
end;

procedure TSkChaos.Despawn;
begin
  if (FState = csActive) or (FState = csForming) then
  begin
    FState := csFading;
    FDespawnScanY := FMinY;
    NotifyActivity;
  end;
end;

procedure TSkChaos.QuitAfterDespawn;
begin
  FQuitAfterDespawn := True;
  { If the despawn animation already completed (csFinished) there is
    nothing left to animate, and Despawn is a no-op in that state - so
    the app would never terminate. Close immediately instead of waiting
    for a state-machine transition that will never fire. }
  if FState = csFinished then
    TThread.Queue(nil,
      procedure
      begin
        Application.Terminate;
      end)
  else
    Despawn;
end;

procedure TSkChaos.SetInnerCore(const Value: Boolean);
begin
  if FInnerCore <> Value then
  begin
    FInnerCore := Value;
    { The INNER_CORE flag is baked into each particle during BuildMeshTargets,
      so toggling must rebuild the cloud from the current source to apply. }
    if FGLReady and (FSourceType <> srcDepthMap) and (Length(FMeshResult.Points) > 0) then
    begin
      BuildMeshTargets(FMeshResult.Points);
      ReinitParticlesForForming;
      FState := csForming;
      FBuildScanY := FMinY;
      FDespawnScanY := FMinY;
    end;
    NotifyActivity;
  end;
end;

procedure TSkChaos.SetParticleBudget(const Value: Cardinal);
begin
  if FParticleBudget <> Value then
  begin
    FParticleBudget := Value;
    { Budget caps how many source points the loader samples; FMeshResult.Points
      is already clipped at the previous budget, so rebuild-from-points cannot
      raise the count above the old cap. Reload the current source file with the
      new budget so 250k+ actually takes effect; fall back to rebuild-from-points
      for hybrid / depth-map sources that have no single file to reload. }
    if (FSourceType = srcMesh) and (FCurrentMeshFile <> '') then
      LoadMeshFile(FCurrentMeshFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget)
    else if (FSourceType = srcPhoto) and (FCurrentPhotoFile <> '') then
      LoadPhotoFile(FCurrentPhotoFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget)
    else if FGLReady and (Length(FMeshResult.Points) > 0) then
    begin
      BuildMeshTargets(FMeshResult.Points);
      ReinitParticlesForForming;
      FState := csForming;
      FBuildScanY := FMinY;
      FDespawnScanY := FMinY;
    end;
    NotifyActivity;
  end;
end;

procedure TSkChaos.SetMouseFollow(const Value: Boolean);
begin
  if FMouseFollow <> Value then
  begin
    FMouseFollow := Value;
    if not FMouseFollow then
    begin
      FLookTargetX := 0;
      FLookTargetY := 0;
    end;
    NotifyActivity;
  end;
end;

procedure TSkChaos.SetStayOnTop(const Value: Boolean);
begin
  if FStayOnTop <> Value then
  begin
    FStayOnTop := Value;
    ApplyStayOnTop;
  end;
end;

procedure TSkChaos.SetClickThrough(const Value: Boolean);
begin
  if FClickThrough <> Value then
  begin
    FClickThrough := Value;
    ApplyClickThrough;
  end;
end;

function TSkChaos.FindOwnerForm: TForm;
var
  Obj: TFMXObject;
begin
  Result := nil;
  Obj := Self.Parent;
  while Assigned(Obj) do
  begin
    if Obj is TForm then
      Exit(TForm(Obj));
    Obj := Obj.Parent;
  end;
end;

procedure TSkChaos.ApplyStayOnTop;
var
  F: TForm;
begin
  F := FindOwnerForm;
  if Assigned(F) then
  begin
    if FStayOnTop then
      F.FormStyle := TFormStyle.StayOnTop
    else
      F.FormStyle := TFormStyle.Normal;
    { FormStyle change recreates the HWND, so re-apply click-through. }
    ApplyClickThrough;
  end;
end;

procedure TSkChaos.ApplyClickThrough;
var
  F: TForm;
  Wnd: HWND;
begin
  F := FindOwnerForm;
  if Assigned(F) then
  begin
    Wnd := WindowHandleToPlatform(F.Handle).Wnd;
    if FClickThrough then
      SetWindowLong(Wnd, GWL_EXSTYLE, GetWindowLong(Wnd, GWL_EXSTYLE) or WS_EX_TRANSPARENT)
    else
      SetWindowLong(Wnd, GWL_EXSTYLE, GetWindowLong(Wnd, GWL_EXSTYLE) and not WS_EX_TRANSPARENT);
  end;
end;

procedure TSkChaos.SetNeckPivotRatio(const Value: Single);
begin
  if not SameValue(FNeckPivotRatio, Value, 1e-4) then
  begin
    FNeckPivotRatio := EnsureRange(Value, 0.0, 1.0);
    FPivotY := FMinY + (FMaxY - FMinY) * FNeckPivotRatio;
    NotifyActivity;
  end;
end;

end.

