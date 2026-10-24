{*******************************************************************************
  Yutani.Render.PathTracing v0.1
********************************************************************************
  GPU Path Tracing Engine for the Yutani Sandbox
  -----------------------------------------------
  A 1:1 Object Pascal port of NarcisDR / Narcis' C++ raylib Path Tracing
  sample, reworked into a single, cohesive unit that plugs into the existing
  Yutani threaded Raylib wrapper architecture.

  Design Pillars:
    - GPU-ONLY path tracer. All ray work happens in the GLSL compute shader
      (ptShader.comp). Delphi only acts as the orchestrator: building the BVH,
      streaming triangle / BVH SSBOs, uploading camera matrices, firing the
      compute dispatch, and drawing the final texture with Raylib.

    - Full PBR feature set on GPU: Diffuse (cosine hemisphere sampling),
      GGX microfacet specular, refraction with Beer-Lambert absorption and
      colored tint, HDRI / procedural sky / sun lighting, caustics buffer,
      volumetric scattering, emissive triangles, multi-sample accumulation.

    - Custom Flat-BVH built directly in Object Pascal. The build uses the
      same avg-split heuristics as the original and flattens into a
      CompactBVHGPU array that maps 1:1 to the std430 SSBO layout declared
      in the compute shader.

    - PTCam ported as a Delphi record keeping aperture / ISO / sensor-size /
      focus distance / dynamic DoF click exactly like the C++ struct.

    - Single unit, multi-threaded friendly. All comments in English.

  Hardware Requirements:
    OpenGL 4.3+ (Compute Shaders, SSBOs, ImageTextures, glMemoryBarrier).
    Raylib 4.x with rlgl access.

  Author: Lara Miriam Tamy Reschke / LamitaOne (Delphi port of the C++ original)
*******************************************************************************}

unit Yutani.Render.PathTracing;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Types, System.StrUtils,
  Winapi.Windows,
  Raylib, RayMath, rlgl;

{==============================================================================*
 *  OpenGL Constants & Function Pointer Types
 *==============================================================================}
const
  GL_COMPUTE_SHADER                  = $91B9;
  GL_SHADER_STORAGE_BUFFER           = $90D2;
  GL_UNIFORM_BUFFER                  = $8A11;
  GL_DYNAMIC_DRAW                    = $88E8;
  GL_STATIC_DRAW                     = $88E4;
  GL_READ_WRITE                      = $88BA;
  GL_WRITE_ONLY                      = $88B9;
  GL_READ_ONLY                       = $88B8;
  GL_SHADER_IMAGE_ACCESS_BARRIER_BIT = $00000020;
  GL_BUFFER_UPDATE_BARRIER_BIT       = $00000100;
  GL_TEXTURE_FETCH_BARRIER_BIT       = $00000008;
  GL_TEXTURE_2D                      = $0DE1;
  GL_TEXTURE0                        = $84C0;
  GL_TEXTURE_MIN_FILTER              = $2801;
  GL_TEXTURE_MAG_FILTER              = $2800;
  GL_TEXTURE_WRAP_S                  = $2802;
  GL_TEXTURE_WRAP_T                  = $2803;
  GL_LINEAR                          = $2601;
  GL_NEAREST                         = $2600;
  GL_CLAMP_TO_EDGE                   = $812F;
  GL_RGBA32F                         = $8814;
  GL_COMPILE_STATUS                  = $8B81;
  GL_LINK_STATUS                     = $8B82;
  GL_INFO_LOG_LENGTH                 = $8B84;
  GL_FALSE                           = 0;
  GL_TRUE                            = 1;

type
  PFNGLCREATESHADERPROC      = function(shaderType: Cardinal): Cardinal; stdcall;
  PFNGLSHADERSOURCEPROC      = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;
  PFNGLCOMPILESHADERPROC     = procedure(shader: Cardinal); stdcall;
  PFNGLDELETESHADERPROC      = procedure(shader: Cardinal); stdcall;
  PFNGLGETSHADERIVPROC       = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETSHADERINFOLOGPROC  = procedure(shader: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLCREATEPROGRAMPROC     = function: Cardinal; stdcall;
  PFNGLATTACHSHADERPROC      = procedure(programObj: Cardinal; shader: Cardinal); stdcall;
  PFNGLLINKPROGRAMPROC       = procedure(programObj: Cardinal); stdcall;
  PFNGLUSEPROGRAMPROC        = procedure(programObj: Cardinal); stdcall;
  PFNGLDELETEPROGRAMPROC     = procedure(programObj: Cardinal); stdcall;
  PFNGLGETPROGRAMIVPROC      = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETPROGRAMINFOLOGPROC = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;
  PFNGLUNIFORM1FPROC          = procedure(location: Integer; v: Single); stdcall;
  PFNGLUNIFORM1IPROC          = procedure(location: Integer; v: Integer); stdcall;
  PFNGLUNIFORM1UIPROC         = procedure(location: Integer; v: Cardinal); stdcall;
  PFNGLUNIFORM3FPROC          = procedure(location: Integer; x, y, z: Single); stdcall;
  PFNGLUNIFORM4FPROC          = procedure(location: Integer; x, y, z, w: Single); stdcall;
  PFNGLGENBUFFERSPROC         = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLDELETEBUFFERSPROC      = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLBINDBUFFERPROC         = procedure(target: Cardinal; buffer: Cardinal); stdcall;
  PFNGLBUFFERDATAPROC         = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;
  PFNGLBUFFERSUBDATAPROC      = procedure(target: Cardinal; offset: NativeInt; size: NativeInt; data: Pointer); stdcall;
  PFNGLBINDBUFFERBASEPROC     = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;
  PFNGLGENTEXTURESPROC        = procedure(n: Integer; textures: PCardinal); stdcall;
  PFNGLDELETETEXTURESPROC     = procedure(n: Integer; textures: PCardinal); stdcall;
  PFNGLBINDTEXTUREPROC        = procedure(target: Cardinal; texture: Cardinal); stdcall;
  PFNGLTEXSTORAGE2DPROC       = procedure(target: Cardinal; levels: Integer; internalFormat: Cardinal; width: Integer; height: Integer); stdcall;
  PFNGLTEXPARAMETERIPROC      = procedure(target: Cardinal; pname: Cardinal; param: Integer); stdcall;
  PFNGLACTIVETEXTUREPROC      = procedure(texture: Cardinal); stdcall;
  PFNGLBINDIMAGETEXTUREPROC   = procedure(unit_: Cardinal; texture: Cardinal; level: Integer; layered: Byte; layer: Integer; access: Cardinal; format: Cardinal); stdcall;
  PFNGLDISPATCHCOMPUTEPROC    = procedure(num_groups_x: Cardinal; num_groups_y: Cardinal; num_groups_z: Cardinal); stdcall;
  PFNGLMEMORYBARRIERPROC      = procedure(barriers: Cardinal); stdcall;

{==============================================================================*
 *  Named dynamic array types (must be declared before any type that uses them
 *  in field/method signatures - Delphi has no forward references for records)
 *==============================================================================}
type
  TCardinalArray = array of Cardinal;

{==============================================================================*
 *  Records: Materials
 *==============================================================================}
  PTMaterial = record
    albedo:            TVector3;
    specularCol:       TVector3;
    emissionCol:       TVector3;
    absorptionCol:     TVector3;
    volumeCol:         TVector3;
    IOR:               Single;
    roughness:         Single;
    emissionIntensity: Single;
    refraction:        Single;
    absorption:        Single;
    volume:            Single;
    density:           Single;
    metalness:         Single;
  end;

  PTMaterialGPU = record
    albedo_roughness:    TVector4;
    specular_metalness:  TVector4;
    emission_intensity:  TVector4;
    absorption_amount:   TVector4;
    volume_density:      TVector4;
    extraParams:         TVector4;
  end;

{==============================================================================*
 *  Records: Triangles
 *==============================================================================}
  // CPU-side triangle, mirrors the C++ Tri struct. Material is stored BY VALUE
  // (each triangle has its own copy) - same as the C++ original.
  Tri = record
    mat:         PTMaterial;
    a, b, c:     TVector3;
    aN, bN, cN:  TVector3;
    eA, eB:      TVector3;
    normal:      TVector3;
    minV, maxV:  TVector3;
    center:      TVector3;
    id:          Cardinal;
    doubleSided: Boolean;
    modelId:     Cardinal;
    procedure Init(const AMat: PTMaterial; const A, B, C, AN, BN, CN: TVector3; ADoubleSided: Boolean);
    procedure InitNormal;
    procedure CalculateAABB;
    procedure CalculateCenter;
  end;
  TTriArray = array of Tri;

  TriGPU = record
    mat:           PTMaterialGPU;
    a, b, c:       TVector4;
    aN, bN, cN:    TVector4;
    eA, eB:        TVector4;
    normal:        TVector4;
    minV, maxV:    TVector4;
    center:        TVector4;
    id:            Cardinal;
    doubleSided:   Cardinal;
    modelId:       Cardinal;
    padding:       Cardinal;
  end;
  TTriGPUArray = array of TriGPU;

{==============================================================================*
 *  Records: BVH
 *  BVHNode is a plain data record (no methods). Construction logic lives in
 *  standalone procedures BVHNodeInit / BVHNodeCreateChildren / etc., because
 *  those procedures need to take a TBVHNodeArray parameter, and TBVHNodeArray
 *  can only be declared AFTER BVHNode. Methods on a record cannot use a type
 *  declared later - hence the workaround.
 *==============================================================================}
  BVHNode = record
    minV, maxV:      TVector3;
    splitPoint:      TVector3;
    children:        array[0..1] of Cardinal;
    indexData:       Cardinal;
    endIndex:        Cardinal;
    next:            Cardinal;
  end;
  TBVHNodeArray = array of BVHNode;

  CompactBVH = record
    minV, maxV:  TVector3;
    indexData:   Cardinal;
    triCount:    Cardinal;
  end;
  TCompactBVHArray = array of CompactBVH;

  CompactBVHGPU = record
    minV, maxV:    TVector4;
    indexData:     Cardinal;
    triCount:      Cardinal;
    padding0:      Cardinal;
    padding1:      Cardinal;
  end;
  TCompactBVHGPUArray = array of CompactBVHGPU;

{==============================================================================*
 *  BVH construction procedures (free-standing because they reference
 *  TBVHNodeArray which is declared after BVHNode)
 *==============================================================================}
procedure BVHNodeInit(var node: BVHNode; AIndexData, AEndIndex: Cardinal);
procedure BVHNodeCalculateAABB(var node: BVHNode; var triIndices: TCardinalArray; var tris: TTriArray);
procedure BVHNodeAvgSplit(var node: BVHNode; var triIndices: TCardinalArray; var tris: TTriArray);

// BVHNodeCreateChildren and BVHNodeCalculateNextNeighbor take a node INDEX
// instead of a `var node` reference. This is critical: SetLength() inside
// CreateChildren can move the entire dynamic array to a new memory location,
// which would invalidate any `var node` pointer that pointed at an element
// of the old array. Index-based access (globalBVH[nodeIdx]) stays valid
// after SetLength because the index is logical, not a raw pointer.
procedure BVHNodeCreateChildren(nodeIdx: Cardinal; var triIndices: TCardinalArray;
                                var tris: TTriArray; var globalBVH: TBVHNodeArray);
procedure BVHNodeCalculateNextNeighbor(nodeIdx: Cardinal; var globalBVH: TBVHNodeArray);

{==============================================================================*
 *  Forward Declarations (classes only - records cannot be forward declared)
 *==============================================================================}
 type
  PTModel = class;
  TYutaniPathTracer = class;

{==============================================================================*
 *  Records: AreaLight
 *==============================================================================}
  AreaLight = record
    pos:              TVector3;
    emissionCol:      TVector3;
    emissionStrength: Single;
    sizeV:            Single;
    triA, triB:       Cardinal;
    areaLightMat:     PTMaterial;
  end;
  TAreaLightArray = array of AreaLight;

{==============================================================================*
 *  Records: PTData
 *==============================================================================}
  PTData = record
    tris:           TTriArray;
    trisGPU:        TTriGPUArray;
    models:         array of PTModel;
    areaLights:     TAreaLightArray;
    triMap:         TCardinalArray;
    frameBuffer:    array of TColorB;
    accumBuffer:    array of TVector3;
    causticsBuffer: array of TVector3;
  end;

{==============================================================================*
 *  Records: Params
 *==============================================================================}
  PTParams = record
    screenSize:        TVector2;
    dt:                Single;

    res:               Integer;

    maxBounces:        Integer;
    prevMaxBounces:    Integer;
    maxSamples:        Integer;
    raysPerPixel:      Integer;
    currentSample:     Integer;

    enableSky:         Boolean;
    enableHDRI:        Boolean;
    skyIntensity:      Single;
    blur:              Single;
    exposure:          Single;
    contrast:          Single;
    hdriThreshold:     Single;
    hdriBrigthest:     Single;

    hdri:              TImage;
    hdriRotation:      Single;

    enableSun:         Boolean;
    sunDir:            TVector3;
    sunColor:          TVector3;
    sunIntensity:      Single;
    sunAngle:          Single;

    skyTopOriginal:    TVector3;
    skyBaseOriginal:   TVector3;
    skyTop:            TVector3;
    skyBase:           TVector3;

    refractiveAmount:  Cardinal;

    totalMs:           Single;
    totalFrames:       Integer;

    shouldSample:      Boolean;
    enableSampling:    Boolean;

    isMouseHoveringUI: Boolean;
    enableDebugRay:    Boolean;
    enableSelection:   Boolean;
    render:            Boolean;

    enableCaustics:    Boolean;
    enableBiasCaustics:Boolean;
    causticsIntensity: Single;
    biasCausticsContactClamp: Single;

    mainBufferIntensity: Single;
    renderTime:        Single;

    rayMarcher:        Boolean;
    pathTracer:        Boolean;

    rmMaxSteps:        Integer;
    rmNearPlane:       Single;
    rmFarPlane:        Single;
    rmNormalPrecision: Single;

    rmMat:             PTMaterial;
    rmMatGPU:          PTMaterialGPU;

    rmLodAmount:       Single;
    rmLodMinDistMult:  Single;
    rmPBR:             Boolean;

    enableGPU:         Boolean;
    exportRender:      Boolean;

    hasSceneChanged:   Boolean;
    updateGPU:         Boolean;
    updateCPU:         Boolean;

    addAreaLight:      Boolean;

    selectedModelsAmount: Cardinal;
  end;

{==============================================================================*
 *  Records: Screen
 *==============================================================================}
  PTScreen = record
    screenSizeX: Single;
    screenSizeY: Single;
    ratio:       Single;
    resX:        Integer;
    resY:        Integer;
    procedure InitScreen(var res: Integer; var data: PTData);
  end;

{==============================================================================*
 *  Records: PTCam
 *==============================================================================}
  PTCam = record
    camPos:           TVector3;
    camTarget:        TVector3;
    targetDist:       Single;
    camSpeed:         Single;
    fov:              Single;

    focalLengthMM:    Single;
    focalLength:      Single;
    aperture:         Single;
    fStop:            Single;
    ISO:              Single;
    focusDist:        Single;
    sensorSize:       Single;

    clickDof:         Boolean;

    camNormal:        TVector3;
    worldUp:          TVector3;
    right:            TVector3;
    up:               TVector3;
    halfFovRadians:   Single;
    verticalScale:    Single;

    targetNormal:     TVector3;
    focalPoint:       TVector3;

    fovH:             Single;
    fovV:             Single;

    mouseSensitivity: Single;

    function KeyDownSample(key: Integer; var params: PTParams): Boolean;
    function MouseDownSample(button: Integer; var params: PTParams): Boolean;
    procedure CameraLogic(var params: PTParams; var ratio: Single);
  end;

{==============================================================================*
 *  PTModel
 *==============================================================================}
  PTModel = class
  private
    FMat:           PTMaterial;
    FDoubleSided:   Boolean;
    FTris:          TCardinalArray;
    FOrigin:        TVector3;
    FOriginalOrigin:TVector3;
    FSelected:      Boolean;
    FId:            Cardinal;
  public
    constructor Create(const AMat: PTMaterial; ADoubleSided: Boolean);
    destructor Destroy; override;

    procedure CalculateOriginCenter(var data: PTData);

    property Mat:           PTMaterial read FMat write FMat;
    property DoubleSided:   Boolean read FDoubleSided write FDoubleSided;
    property Origin:        TVector3 read FOrigin write FOrigin;
    property Selected:      Boolean read FSelected write FSelected;
    property Id:            Cardinal read FId write FId;

    function  GetTriCount: Integer;
    function  GetTri(idx: Integer): Cardinal;
    procedure AddTri(triIdx: Cardinal);
    procedure ClearTris;
  end;

{==============================================================================*
 *  OBJ Importer
 *==============================================================================}
  TObjImporter = class
  public
    class function Load(const fileName: string; var data: PTData;
                        const mat: PTMaterial; doubleSided: Boolean): Cardinal;
  end;

{==============================================================================*
 *  The Path Tracer Engine
 *==============================================================================}
  TYutaniPathTracer = class
  private
    FAccumTextureID:    Cardinal;
    FGpuAccumBuffer:    TTexture2D;
    FCausticsTextureID: Cardinal;
    FGpuCausticsBuffer: TTexture2D;
    FFinalTextureID:    Cardinal;
    FGpuFinalBuffer:    TTexture2D;

    FComputeProgram:    Cardinal;
    FTriangleSSBO:      Cardinal;
    FBVHSSBO:           Cardinal;
    FMaterialUBO:       Cardinal;

    FHdriTex:           TTexture2D;
    FHdriUnit:          Cardinal;

    FGlobalBVH:           TBVHNodeArray;
    FGlobalCompactBVH:    TCompactBVHArray;
    FGlobalCompactBVHGPU: TCompactBVHGPUArray;

    FLocTime, FLocBlur: Integer;
    FLocScreenRatio, FLocResX, FLocResY: Integer;
    FLocCurrentSample, FLocMaxSamples, FLocShouldSample: Integer;
    FLocRayMarcher, FLocPathTracer: Integer;
    FLocEnableCaustics: Integer;
    FLocSkyIntensity, FLocEnableSky, FLocSkyTop, FLocSkyBase: Integer;
    FLocEnableHDRI: Integer;
    FLocEnableSun, FLocSunAngle, FLocSunColor, FLocSunIntensity, FLocSunDir: Integer;
    FLocBounces: Integer;
    FLocRaysPerPixel: Integer;
    FLocHdriRotation, FLocHdriBrigthest, FLocHdriThreshold: Integer;
    FLocRmMaxSteps, FLocRmNearPlane, FLocRmFarPlane, FLocRmPBR: Integer;
    FLocRmLodMinDistMult, FLocRmLodAmount, FLocRmNormalPrecision: Integer;
    FLocAperture, FLocCamPos, FLocRight, FLocUp, FLocCamNormal: Integer;
    FLocSensorSize, FLocISO, FLocFocalPoint, FLocFocusDist: Integer;
    FLocNodeCount, FLocHdri: Integer;
    FLocMainBufferIntensity, FLocCausticsIntensity: Integer;
    FLocExposure, FLocContrast: Integer;

    FInitialized: Boolean;

    procedure CreateComputeTexture(resX, resY: Integer);
    function  CompileComputeShader(const path: string): Cardinal;
    procedure CacheUniformLocations;
    procedure GpuSampleLogic(var params: PTParams);
  public
    constructor Create;
    destructor Destroy; override;

    procedure CreateFlatBVH(var data: PTData);
    procedure FlattenBVH(buildNodeIdx: Cardinal; var buildNodes: TBVHNodeArray;
                         var flatNodes: TCompactBVHArray);

    procedure InitTriangleSSBO(const trisGPU: TTriGPUArray);
    procedure InitBVHSSBO(const bvhGPU: TCompactBVHGPUArray);
    procedure UploadTriangles(var data: PTData);
    procedure UploadBVH;
    procedure UpdateRMMaterialGPU(var params: PTParams);
    procedure LoadHDRI(var params: PTParams);
    procedure HdriBrightestValue(var hdri: TImage; var maxVal: Single);

    procedure InitCompute(resX, resY: Integer; const shaderPath: string);

    procedure RunShader(screenSize: TVector2; resX, resY: Integer;
                        var myCam: PTCam; var params: PTParams; var screen: PTScreen);

    function GetGlobalCompactBVHGPUCopy: TCompactBVHGPUArray;
    property GpuFinalBuffer: TTexture2D read FGpuFinalBuffer;
    property Initialized: Boolean read FInitialized;
  end;

{==============================================================================*
 *  Standalone: AreaLight initialization
 *==============================================================================}
procedure InitAreaLight(var al: AreaLight; const APos, AEmissionCol: TVector3;
                        AEmissionStrength, ASize: Single; var data: PTData);

{==============================================================================*
 *  Global IDs (mirror the C++ externs)
 *==============================================================================}
var
  GlobalTriId:   Cardinal = 0;
  GlobalModelId: Cardinal = 0;

{==============================================================================*
 *  GL function pointers (resolved at startup via wglGetProcAddress)
 *==============================================================================}
var
  glCreateShader:        PFNGLCREATESHADERPROC;
  glShaderSource:        PFNGLSHADERSOURCEPROC;
  glCompileShader:       PFNGLCOMPILESHADERPROC;
  glDeleteShader:        PFNGLDELETESHADERPROC;
  glGetShaderiv:         PFNGLGETSHADERIVPROC;
  glGetShaderInfoLog:    PFNGLGETSHADERINFOLOGPROC;
  glCreateProgram:       PFNGLCREATEPROGRAMPROC;
  glAttachShader:        PFNGLATTACHSHADERPROC;
  glLinkProgram:         PFNGLLINKPROGRAMPROC;
  glUseProgram:          PFNGLUSEPROGRAMPROC;
  glDeleteProgram:       PFNGLDELETEPROGRAMPROC;
  glGetProgramiv:        PFNGLGETPROGRAMIVPROC;
  glGetProgramInfoLog:   PFNGLGETPROGRAMINFOLOGPROC;
  glGetUniformLocation:  PFNGLGETUNIFORMLOCATIONPROC;
  glUniform1f:           PFNGLUNIFORM1FPROC;
  glUniform1i:           PFNGLUNIFORM1IPROC;
  glUniform1ui:          PFNGLUNIFORM1UIPROC;
  glUniform3f:           PFNGLUNIFORM3FPROC;
  glUniform4f:           PFNGLUNIFORM4FPROC;
  glGenBuffers:          PFNGLGENBUFFERSPROC;
  glDeleteBuffers:       PFNGLDELETEBUFFERSPROC;
  glBindBuffer:          PFNGLBINDBUFFERPROC;
  glBufferData:          PFNGLBUFFERDATAPROC;
  glBufferSubData:       PFNGLBUFFERSUBDATAPROC;
  glBindBufferBase:      PFNGLBINDBUFFERBASEPROC;
  glGenTextures:         PFNGLGENTEXTURESPROC;
  glDeleteTextures:      PFNGLDELETETEXTURESPROC;
  glBindTexture:         PFNGLBINDTEXTUREPROC;
  glTexStorage2D:        PFNGLTEXSTORAGE2DPROC;
  glTexParameteri:       PFNGLTEXPARAMETERIPROC;
  glActiveTexture:       PFNGLACTIVETEXTUREPROC;
  glBindImageTexture:    PFNGLBINDIMAGETEXTUREPROC;
  glDispatchCompute:     PFNGLDISPATCHCOMPUTEPROC;
  glMemoryBarrier:       PFNGLMEMORYBARRIERPROC;

  GLReady: Boolean = False;

implementation

{==============================================================================*
 *  wglGetProcAddress - declared externally because some Delphi editions don't
 *  expose it in Winapi.Windows.
 *==============================================================================}
function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';

{==============================================================================*
 *  Vector / GL helpers
 *==============================================================================}
function V3(x, y, z: Single): TVector3;
begin
  Result.x := x;
  Result.y := y;
  Result.z := z;
end;

function V4(const v: TVector3; w: Single): TVector4;
begin
  Result.x := v.x;
  Result.y := v.y;
  Result.z := v.z;
  Result.w := w;
end;

// Read a single component of a TVector3 by index. TVector3 is a record without
// a default indexed property, so v[axis] does NOT compile in Delphi.
function Vec3Get(const v: TVector3; idx: Integer): Single;
begin
  case idx of
    0: Result := v.x;
    1: Result := v.y;
    2: Result := v.z;
    else
      Result := 0;
  end;
end;

function Vec3Min(const a, b: TVector3): TVector3;
begin
  if a.x < b.x then Result.x := a.x else Result.x := b.x;
  if a.y < b.y then Result.y := a.y else Result.y := b.y;
  if a.z < b.z then Result.z := a.z else Result.z := b.z;
end;

function Vec3Max(const a, b: TVector3): TVector3;
begin
  if a.x > b.x then Result.x := a.x else Result.x := b.x;
  if a.y > b.y then Result.y := a.y else Result.y := b.y;
  if a.z > b.z then Result.z := a.z else Result.z := b.z;
end;

// Wrap glGetUniformLocation with the AnsiString -> PAnsiChar cast baked in.
function GetLoc(prog: Cardinal; const name: AnsiString): Integer;
begin
  Result := glGetUniformLocation(prog, PAnsiChar(name));
end;

procedure SwapCardinal(var a, b: Cardinal);
var
  tmp: Cardinal;
begin
  tmp := a; a := b; b := tmp;
end;

{==============================================================================*
 *  OpenGL Loader
 *==============================================================================}
function LoadOpenGL43: Boolean;

  function GetProc(const name: AnsiString): Pointer;
  begin
    Result := wglGetProcAddress(PAnsiChar(name));
    if Result = nil then
      Result := GetProcAddress(GetModuleHandle('opengl32.dll'), PAnsiChar(name));
  end;

begin
  if GLReady then
    Exit(True);

  glCreateShader        := GetProc('glCreateShader');
  glShaderSource        := GetProc('glShaderSource');
  glCompileShader       := GetProc('glCompileShader');
  glDeleteShader        := GetProc('glDeleteShader');
  glGetShaderiv         := GetProc('glGetShaderiv');
  glGetShaderInfoLog    := GetProc('glGetShaderInfoLog');
  glCreateProgram       := GetProc('glCreateProgram');
  glAttachShader        := GetProc('glAttachShader');
  glLinkProgram         := GetProc('glLinkProgram');
  glUseProgram          := GetProc('glUseProgram');
  glDeleteProgram       := GetProc('glDeleteProgram');
  glGetProgramiv        := GetProc('glGetProgramiv');
  glGetProgramInfoLog   := GetProc('glGetProgramInfoLog');
  glGetUniformLocation  := GetProc('glGetUniformLocation');
  glUniform1f           := GetProc('glUniform1f');
  glUniform1i           := GetProc('glUniform1i');
  glUniform1ui          := GetProc('glUniform1ui');
  glUniform3f           := GetProc('glUniform3f');
  glUniform4f           := GetProc('glUniform4f');
  glGenBuffers          := GetProc('glGenBuffers');
  glDeleteBuffers       := GetProc('glDeleteBuffers');
  glBindBuffer          := GetProc('glBindBuffer');
  glBufferData          := GetProc('glBufferData');
  glBufferSubData       := GetProc('glBufferSubData');
  glBindBufferBase      := GetProc('glBindBufferBase');
  glGenTextures         := GetProc('glGenTextures');
  glDeleteTextures      := GetProc('glDeleteTextures');
  glBindTexture         := GetProc('glBindTexture');
  glTexStorage2D        := GetProc('glTexStorage2D');
  glTexParameteri       := GetProc('glTexParameteri');
  glActiveTexture       := GetProc('glActiveTexture');
  glBindImageTexture    := GetProc('glBindImageTexture');
  glDispatchCompute     := GetProc('glDispatchCompute');
  glMemoryBarrier       := GetProc('glMemoryBarrier');

  GLReady :=
    Assigned(glCreateShader)       and Assigned(glShaderSource)       and
    Assigned(glCompileShader)      and Assigned(glDeleteShader)       and
    Assigned(glGetShaderiv)        and Assigned(glGetShaderInfoLog)   and
    Assigned(glCreateProgram)      and Assigned(glAttachShader)       and
    Assigned(glLinkProgram)        and Assigned(glUseProgram)         and
    Assigned(glDeleteProgram)      and Assigned(glGetProgramiv)       and
    Assigned(glGetProgramInfoLog)  and Assigned(glGetUniformLocation) and
    Assigned(glUniform1f)          and Assigned(glUniform1i)          and
    Assigned(glUniform1ui)         and Assigned(glUniform3f)          and
    Assigned(glUniform4f)          and Assigned(glGenBuffers)         and
    Assigned(glDeleteBuffers)      and Assigned(glBindBuffer)         and
    Assigned(glBufferData)         and Assigned(glBufferSubData)      and
    Assigned(glBindBufferBase)     and Assigned(glGenTextures)        and
    Assigned(glDeleteTextures)     and Assigned(glBindTexture)        and
    Assigned(glTexStorage2D)       and Assigned(glTexParameteri)      and
    Assigned(glActiveTexture)      and Assigned(glBindImageTexture)   and
    Assigned(glDispatchCompute)    and Assigned(glMemoryBarrier);

  Result := GLReady;
end;

{==============================================================================*
 *  Tri
 *==============================================================================}
procedure Tri.Init(const AMat: PTMaterial; const A, B, C, AN, BN, CN: TVector3; ADoubleSided: Boolean);
begin
  mat         := AMat;
  Self.a      := A;
  Self.b      := B;
  Self.c      := C;
  Self.aN     := AN;
  Self.bN     := BN;
  Self.cN     := CN;
  doubleSided := ADoubleSided;
  id          := GlobalTriId;
  Inc(GlobalTriId);
  InitNormal;
  CalculateAABB;
  CalculateCenter;
end;

procedure Tri.InitNormal;
begin
  eA := Vector3Subtract(b, a);
  eB := Vector3Subtract(c, a);
  normal := Vector3Normalize(Vector3CrossProduct(eA, eB));
end;

procedure Tri.CalculateAABB;
begin
  minV := Vec3Min(a, Vec3Min(b, c));
  maxV := Vec3Max(a, Vec3Max(b, c));
end;

procedure Tri.CalculateCenter;
begin
  center := Vector3Scale(Vector3Add(Vector3Add(a, b), c), 1.0 / 3.0);
end;

{==============================================================================*
 *  BVH construction procedures
 *==============================================================================}
procedure BVHNodeInit(var node: BVHNode; AIndexData, AEndIndex: Cardinal);
begin
  node.minV       := V3(0, 0, 0);
  node.maxV       := V3(0, 0, 0);
  node.splitPoint := V3(0, 0, 0);
  node.children[0] := $FFFFFFFF;
  node.children[1] := $FFFFFFFF;
  node.indexData  := AIndexData;
  node.endIndex   := AEndIndex;
  node.next       := 0;
end;

procedure BVHNodeCalculateAABB(var node: BVHNode; var triIndices: TCardinalArray; var tris: TTriArray);
var
  i: Cardinal;
  clampedEnd: Cardinal;
begin
  node.minV := V3(MaxSingle, MaxSingle, MaxSingle);
  node.maxV := V3(-MaxSingle, -MaxSingle, -MaxSingle);

  if (node.indexData > node.endIndex) or (node.indexData >= Cardinal(Length(tris))) then
    Exit;

  if node.endIndex >= Cardinal(Length(tris)) then
    clampedEnd := Cardinal(Length(tris)) - 1
  else
    clampedEnd := node.endIndex;

  for i := node.indexData to clampedEnd do
  begin
    node.minV := Vec3Min(node.minV, tris[triIndices[i]].minV);
    node.maxV := Vec3Max(node.maxV, tris[triIndices[i]].maxV);
  end;
end;

procedure BVHNodeAvgSplit(var node: BVHNode; var triIndices: TCardinalArray; var tris: TTriArray);
var
  i: Cardinal;
  clampedEnd, count: Cardinal;
begin
  node.splitPoint := V3(0, 0, 0);

  if (node.indexData > node.endIndex) or (node.indexData >= Cardinal(Length(tris))) then
    Exit;

  if node.endIndex >= Cardinal(Length(tris)) then
    clampedEnd := Cardinal(Length(tris)) - 1
  else
    clampedEnd := node.endIndex;

  count := clampedEnd - node.indexData + 1;
  if count = 0 then
    Exit;

  for i := node.indexData to clampedEnd do
    node.splitPoint := Vector3Add(node.splitPoint, tris[triIndices[i]].center);

  node.splitPoint := Vector3Scale(node.splitPoint, 1.0 / count);
end;

procedure BVHNodeCreateChildren(nodeIdx: Cardinal; var triIndices: TCardinalArray;
                                var tris: TTriArray; var globalBVH: TBVHNodeArray);
var
  // Local copy of the node record. Working on a copy is critical because
  // SetLength() below can move the entire dynamic array - any direct reference
  // to globalBVH[nodeIdx] would dangle after that. We make our own copy up
  // front, mutate it, and write it back at the very end when no more SetLength
  // calls are coming.
  node: BVHNode;
  extent: TVector3;
  axis: Integer;
  aIdx: Cardinal;
  i: Cardinal;
  isChildA: Boolean;
  leftCount, rightCount: Cardinal;
  childAIdx, childBIdx: Cardinal;
  centerAxisVal, splitAxisVal: Single;
  nodeIndexData, nodeEndIndex: Cardinal;
begin
  // Snapshot the node so subsequent SetLength calls on globalBVH cannot
  // invalidate our reads of node.indexData / node.endIndex.
  node           := globalBVH[nodeIdx];
  nodeIndexData  := node.indexData;
  nodeEndIndex   := node.endIndex;

  extent := Vector3Subtract(node.maxV, node.minV);
  axis := 0;
  if extent.y > extent.x then axis := 1;
  if extent.z > Vec3Get(extent, axis) then axis := 2;

  aIdx := nodeIndexData;

  i := nodeIndexData;
  while (i <= nodeEndIndex) and (i < Cardinal(Length(triIndices))) do
  begin
    centerAxisVal := Vec3Get(tris[triIndices[i]].center, axis);
    splitAxisVal  := Vec3Get(node.splitPoint, axis);
    isChildA := centerAxisVal < splitAxisVal;
    if isChildA then
    begin
      if i = aIdx then
      begin
        Inc(aIdx);
      end
      else
      begin
        SwapCardinal(triIndices[i], triIndices[aIdx]);
        Inc(aIdx);
      end;
    end;
    Inc(i);
  end;

  if aIdx > nodeIndexData then
    leftCount := aIdx - nodeIndexData
  else
    leftCount := 0;

  if (nodeEndIndex >= aIdx) and (aIdx < Cardinal(Length(tris))) then
    rightCount := nodeEndIndex - aIdx + 1
  else
    rightCount := 0;

  if (leftCount = 0) or (rightCount = 0) then
    Exit;

  // Build child A. After SetLength the array may have moved, but our local
  // `node` copy and the snapshot vars are safe.
  childAIdx := Cardinal(Length(globalBVH));
  SetLength(globalBVH, Length(globalBVH) + 1);
  BVHNodeInit(globalBVH[childAIdx], nodeIndexData, aIdx - 1);
  BVHNodeCalculateAABB(globalBVH[childAIdx], triIndices, tris);
  BVHNodeAvgSplit(globalBVH[childAIdx], triIndices, tris);
  // Recursive call uses the index, NOT a `var` reference - safe across SetLength.
  BVHNodeCreateChildren(childAIdx, triIndices, tris, globalBVH);
  BVHNodeCalculateNextNeighbor(childAIdx, globalBVH);

  // Build child B the same way.
  childBIdx := Cardinal(Length(globalBVH));
  SetLength(globalBVH, Length(globalBVH) + 1);
  BVHNodeInit(globalBVH[childBIdx], aIdx, nodeEndIndex);
  BVHNodeCalculateAABB(globalBVH[childBIdx], triIndices, tris);
  BVHNodeAvgSplit(globalBVH[childBIdx], triIndices, tris);
  BVHNodeCreateChildren(childBIdx, triIndices, tris, globalBVH);
  BVHNodeCalculateNextNeighbor(childBIdx, globalBVH);

  // Write the children indices back into our local copy and then store it
  // back into the array. The array may have moved during the SetLength calls
  // above, but globalBVH[nodeIdx] resolves to the correct (possibly new)
  // memory address at this point.
  node.children[0] := childAIdx;
  node.children[1] := childBIdx;
  globalBVH[nodeIdx] := node;
end;

procedure BVHNodeCalculateNextNeighbor(nodeIdx: Cardinal; var globalBVH: TBVHNodeArray);
var
  node: BVHNode;
  i: Integer;
  idx: Cardinal;
begin
  // Take a local snapshot, mutate, write back. Same reasoning as in
  // BVHNodeCreateChildren - keeps us safe if the caller ever does SetLength
  // on globalBVH between calls.
  node := globalBVH[nodeIdx];
  node.next := 0;
  for i := 0 to 1 do
  begin
    idx := node.children[i];
    if idx = $FFFFFFFF then
      Continue;
    node.next := node.next + globalBVH[idx].next;
    Inc(node.next);
  end;
  globalBVH[nodeIdx] := node;
end;

{==============================================================================*
 *  PTModel
 *==============================================================================}
constructor PTModel.Create(const AMat: PTMaterial; ADoubleSided: Boolean);
begin
  inherited Create;
  FMat         := AMat;
  FDoubleSided := ADoubleSided;
  FId          := GlobalModelId;
  Inc(GlobalModelId);
  SetLength(FTris, 0);
  FOrigin        := V3(0, 0, 0);
  FOriginalOrigin:= V3(0, 0, 0);
  FSelected      := False;
end;

destructor PTModel.Destroy;
begin
  SetLength(FTris, 0);
  inherited;
end;

function PTModel.GetTriCount: Integer;
begin
  Result := Length(FTris);
end;

function PTModel.GetTri(idx: Integer): Cardinal;
begin
  Result := FTris[idx];
end;

procedure PTModel.AddTri(triIdx: Cardinal);
begin
  SetLength(FTris, Length(FTris) + 1);
  FTris[High(FTris)] := triIdx;
end;

procedure PTModel.ClearTris;
begin
  SetLength(FTris, 0);
end;

procedure PTModel.CalculateOriginCenter(var data: PTData);
var
  i: Integer;
begin
  FOrigin := V3(0, 0, 0);
  for i := 0 to High(FTris) do
    FOrigin := Vector3Add(FOrigin, data.tris[FTris[i]].center);
  if Length(FTris) > 0 then
    FOrigin := Vector3Scale(FOrigin, 1.0 / Length(FTris));
end;

{==============================================================================*
 *  PTCam
 *==============================================================================}
function PTCam.KeyDownSample(key: Integer; var params: PTParams): Boolean;
begin
  if IsKeyDown(key) then
  begin
    params.shouldSample := False;
    params.enableSampling := False;
    Result := True;
  end
  else
  begin
    params.enableSampling := True;
    Result := False;
  end;
end;

function PTCam.MouseDownSample(button: Integer; var params: PTParams): Boolean;
begin
  if IsMouseButtonDown(button) then
  begin
    params.shouldSample := False;
    params.enableSampling := False;
    Result := True;
  end
  else
  begin
    params.enableSampling := True;
    Result := False;
  end;
end;

procedure PTCam.CameraLogic(var params: PTParams; var ratio: Single);
var
  currentSpeed: Single;
  mDelta: TVector2;
  teleported: Boolean;
  newTarget: TVector3;
  mPos: TVector2;
  camD: TVector3;
  sensorWidth, sensorHeight: Single;
begin
  currentSpeed := camSpeed * params.dt;

  if not params.isMouseHoveringUI then
  begin
    if KeyDownSample(KEY_A,            params) then camPos := Vector3Subtract(camPos, Vector3Scale(right,    currentSpeed));
    if KeyDownSample(KEY_D,            params) then camPos := Vector3Add     (camPos, Vector3Scale(right,    currentSpeed));
    if KeyDownSample(KEY_S,            params) then camPos := Vector3Subtract(camPos, Vector3Scale(camNormal,currentSpeed));
    if KeyDownSample(KEY_W,            params) then camPos := Vector3Add     (camPos, Vector3Scale(camNormal,currentSpeed));
    if KeyDownSample(KEY_LEFT_CONTROL, params) then camPos.z := camPos.z - currentSpeed;
    if KeyDownSample(KEY_LEFT_SHIFT,   params) then camPos.z := camPos.z + currentSpeed;
  end;

  if IsMouseButtonDown(MOUSE_BUTTON_RIGHT) then
    camSpeed := Max(camSpeed + GetMouseWheelMove(), 0.1);

  mDelta := GetMouseDelta();
  if (not params.isMouseHoveringUI) and ((mDelta.x <> 0.0) or (mDelta.y <> 0.0)) then
  begin
    if MouseDownSample(MOUSE_BUTTON_RIGHT, params) then
    begin
      teleported := False;
      mPos := GetMousePosition();
      if mPos.x < 0.0 then
      begin
        SetMousePosition(Trunc(params.screenSize.x), Trunc(mPos.y));
        teleported := True;
      end;
      if mPos.x > params.screenSize.x then
      begin
        SetMousePosition(0, Trunc(mPos.y));
        teleported := True;
      end;
      if mPos.y < 0.0 then
      begin
        SetMousePosition(Trunc(mPos.x), Trunc(params.screenSize.y));
        teleported := True;
      end;
      if mPos.y > params.screenSize.y then
      begin
        SetMousePosition(Trunc(mPos.x), 0);
        teleported := True;
      end;

      if not teleported then
      begin
        newTarget := Vector3Add(camPos, Vector3Scale(targetNormal, 10.0));
        ratio := params.screenSize.x / params.screenSize.y;

        if mDelta.x <> 0.0 then
          newTarget := Vector3Add(newTarget, Vector3Scale(right, mDelta.x * mouseSensitivity));

        if mDelta.y <> 0.0 then
          newTarget := Vector3Subtract(newTarget, Vector3Scale(up, mDelta.y * ratio * mouseSensitivity));

        targetNormal := Vector3Normalize(Vector3Subtract(newTarget, camPos));
      end;
    end;
  end;

  camTarget := Vector3Add(camPos, Vector3Scale(targetNormal, 10.0));

  halfFovRadians := DegToRad(fov) * 0.5;
  verticalScale  := Single(System.Math.Tan(halfFovRadians));

  camD := Vector3Subtract(camTarget, camPos);
  camNormal := Vector3Normalize(camD);

  right := Vector3Normalize(Vector3CrossProduct(camNormal, worldUp));
  up    := Vector3Normalize(Vector3CrossProduct(right, camNormal));

  focalLength := focalLengthMM / 1000.0;
  sensorWidth  := sensorSize / 1000.0;
  sensorHeight := sensorWidth / ratio;

  fovH := 2.0 * RadToDeg(Single(System.Math.ArcTan2(sensorWidth,  2.0 * focalLength)));
  fovV := 2.0 * RadToDeg(Single(System.Math.ArcTan2(sensorHeight, 2.0 * focalLength)));

  focalPoint := Vector3Add(camPos, Vector3Scale(camNormal, focalLength));
end;

{==============================================================================*
 *  AreaLight initialization
 *==============================================================================}
procedure InitAreaLight(var al: AreaLight; const APos, AEmissionCol: TVector3;
                        AEmissionStrength, ASize: Single; var data: PTData);
var
  lightMat: PTMaterial;
  model: PTModel;
  // Note: variable names use the 'p' prefix (point) instead of 'v' to avoid
  // a case-insensitive name clash with the V3() helper function. Without
  // this rename, the compiler parses `V3(0,0,0)` as an indexed access on a
  // variable named `v3` and aborts with E2066 "Operator or semicolon missing".
  p1, p2, p3, p4, p5, p6: TVector3;
  zeroVec: TVector3;
begin
  al.pos              := APos;
  al.emissionCol      := AEmissionCol;
  al.emissionStrength := AEmissionStrength;
  al.sizeV            := ASize;

  // Build a material that is pure emissive and emits the requested color.
  // Materials are records stored BY VALUE inside each Tri, so we just build
  // a local record here and the Tri.Init call will copy it.
  lightMat.albedo            := V3(0, 0, 0);
  lightMat.specularCol       := V3(0, 0, 0);
  lightMat.emissionCol       := AEmissionCol;
  lightMat.absorptionCol     := V3(0, 0, 0);
  lightMat.volumeCol         := V3(0, 0, 0);
  lightMat.IOR               := 1.0;
  lightMat.roughness         := 1.0;
  lightMat.emissionIntensity := AEmissionStrength;
  lightMat.refraction        := 0.0;
  lightMat.absorption        := 0.0;
  lightMat.volume            := 0.0;
  lightMat.density           := 0.0;
  lightMat.metalness         := 0.0;
  al.areaLightMat := lightMat;

  zeroVec := V3(0, 0, 0);

  // Pre-compute the 6 triangle vertices so the parser doesn't choke on
  // inline expressions like Vector3Create(-size + APos.x, ...).
  p1.x := -ASize + APos.x; p1.y := -ASize + APos.y; p1.z := APos.z;
  p2.x :=  ASize + APos.x; p2.y :=  ASize + APos.y; p2.z := APos.z;
  p3.x :=  ASize + APos.x; p3.y := -ASize + APos.y; p3.z := APos.z;
  p4.x := -ASize + APos.x; p4.y :=  ASize + APos.y; p4.z := APos.z;

  p5 := p2;
  p6 := p1;

  // Register a fresh PTModel that owns the two triangles forming the area light
  model := PTModel.Create(lightMat, False);
  SetLength(data.models, Length(data.models) + 1);
  data.models[High(data.models)] := model;

  // Triangle A: p1, p2, p3
  al.triA := GlobalTriId;
  SetLength(data.tris, Length(data.tris) + 1);
  data.tris[High(data.tris)].Init(lightMat, p1, p2, p3, zeroVec, zeroVec, zeroVec, False);

  // Triangle B: p5, p6, p4  (= p2, p1, p4)
  al.triB := GlobalTriId;
  SetLength(data.tris, Length(data.tris) + 1);
  data.tris[High(data.tris)].Init(lightMat, p5, p6, p4, zeroVec, zeroVec, zeroVec, False);

  data.tris[al.triA].modelId := model.Id;
  data.tris[al.triB].modelId := model.Id;
  model.AddTri(al.triA);
  model.AddTri(al.triB);
  model.CalculateOriginCenter(data);
end;

{==============================================================================*
 *  PTScreen
 *==============================================================================}
procedure PTScreen.InitScreen(var res: Integer; var data: PTData);
begin
  screenSizeX := GetScreenWidth();
  screenSizeY := GetScreenHeight();

  if screenSizeY <> 0 then
    ratio := screenSizeX / screenSizeY
  else
    ratio := 1.0;

  resX := res;
  resY := Trunc(res / ratio);

  SetLength(data.frameBuffer,    resX * resY);
  SetLength(data.accumBuffer,    resX * resY);
  SetLength(data.causticsBuffer, resX * resY);
end;

{==============================================================================*
 *  TObjImporter
 *==============================================================================}
class function TObjImporter.Load(const fileName: string; var data: PTData;
                                 const mat: PTMaterial; doubleSided: Boolean): Cardinal;
var
  fFile: TextFile;
  line, token: string;
  vertices: array of TVector3;
  normals:   array of TVector3;
  vertexIndices, normalIndices: array of Integer;
  model: PTModel;
  vIdx, nIdx, firstSlash, secondSlash, i: Integer;
  v: TVector3;
  n: TVector3;
  iA, iB, iC, nA, nB, nC: Integer;
  aN, bN, cN: TVector3;
  sceneScale: Single;
  triIdx: Cardinal;

  function NextToken(var s: string): string;
  var
    p: Integer;
  begin
    s := Trim(s);
    p := Pos(' ', s);
    if p = 0 then
    begin
      Result := s;
      s := '';
    end
    else
    begin
      Result := Copy(s, 1, p - 1);
      s := Trim(Copy(s, p + 1, MaxInt));
    end;
  end;

  function ParseFloat(const s: string): Single;
  var
    code: Integer;
  begin
    Val(s, Result, code);
    if code <> 0 then
      Result := 0.0;
  end;

  function ParseInt(const s: string): Integer;
  var
    code: Integer;
  begin
    Val(s, Result, code);
    if code <> 0 then
      Result := -1;
  end;

begin
  Result := 0;
  sceneScale := 1.0;

  if not System.SysUtils.FileExists(fileName) then
  begin
    WriteLn(ErrOutput, 'OBJ file not found: ' + fileName);
    Exit;
  end;

  AssignFile(fFile, fileName);
  Reset(fFile);

  SetLength(vertices, 0);
  SetLength(normals, 0);

  // Register a new model that owns all triangles we are about to create
  model := PTModel.Create(mat, doubleSided);
  SetLength(data.models, Length(data.models) + 1);
  data.models[High(data.models)] := model;

  while not EOF(fFile) do
  begin
    ReadLn(fFile, line);
    line := Trim(line);
    if line = '' then
      Continue;
    if (line[1] = '#') then
      Continue;

    token := NextToken(line);

    if token = 'v' then
    begin
      SetLength(vertices, Length(vertices) + 1);
      v.x := ParseFloat(NextToken(line));
      v.y := ParseFloat(NextToken(line));
      v.z := ParseFloat(NextToken(line));
      vertices[High(vertices)] := v;
    end
    else if token = 'vn' then
    begin
      SetLength(normals, Length(normals) + 1);
      n.x := ParseFloat(NextToken(line));
      n.y := ParseFloat(NextToken(line));
      n.z := ParseFloat(NextToken(line));
      normals[High(normals)] := Vector3Normalize(n);
    end
    else if token = 'f' then
    begin
      SetLength(vertexIndices, 0);
      SetLength(normalIndices, 0);

      while line <> '' do
      begin
        vIdx := -1;
        nIdx := -1;

        token := NextToken(line);

        firstSlash  := Pos('/', token);
        if firstSlash = 0 then
        begin
          vIdx := ParseInt(token);
        end
        else
        begin
          vIdx := ParseInt(Copy(token, 1, firstSlash - 1));
          secondSlash := PosEx('/', token, firstSlash + 1);
          if (secondSlash <> 0) and (secondSlash + 1 <= Length(token)) then
            nIdx := ParseInt(Copy(token, secondSlash + 1, MaxInt));
        end;

        if vIdx < 0 then
          vIdx := Length(vertices) + vIdx
        else
          Dec(vIdx);

        if (nIdx < 0) and (nIdx <> -1) then
          nIdx := Length(normals) + nIdx
        else if nIdx <> -1 then
          Dec(nIdx);

        SetLength(vertexIndices, Length(vertexIndices) + 1);
        vertexIndices[High(vertexIndices)] := vIdx;
        SetLength(normalIndices, Length(normalIndices) + 1);
        normalIndices[High(normalIndices)] := nIdx;
      end;

      // Fan-triangulate the polygon
      i := 1;
      while i + 1 < Length(vertexIndices) do
      begin
        iA := vertexIndices[0];
        iB := vertexIndices[i];
        iC := vertexIndices[i + 1];

        nA := normalIndices[0];
        nB := normalIndices[i];
        nC := normalIndices[i + 1];

        if (iA < 0) or (iB < 0) or (iC < 0) or
           (iA >= Length(vertices)) or (iB >= Length(vertices)) or (iC >= Length(vertices)) then
        begin
          WriteLn(ErrOutput, 'Face index out of range');
          Inc(i);
          Continue;
        end;

        aN := V3(0, 0, 0);
        bN := V3(0, 0, 0);
        cN := V3(0, 0, 0);
        if (nA >= 0) and (nA < Length(normals)) then aN := normals[nA];
        if (nB >= 0) and (nB < Length(normals)) then bN := normals[nB];
        if (nC >= 0) and (nC < Length(normals)) then cN := normals[nC];

        triIdx := GlobalTriId;
        SetLength(data.tris, Length(data.tris) + 1);
        data.tris[High(data.tris)].Init(
          mat,
          Vector3Scale(vertices[iA], sceneScale),
          Vector3Scale(vertices[iB], sceneScale),
          Vector3Scale(vertices[iC], sceneScale),
          aN, bN, cN,
          doubleSided);

        data.tris[High(data.tris)].modelId := model.Id;
        model.AddTri(triIdx);

        Inc(i);
      end;
    end;
  end;

  CloseFile(fFile);

  model.CalculateOriginCenter(data);
  Result := model.Id;
end;

{==============================================================================*
 *  TYutaniPathTracer
 *==============================================================================}
constructor TYutaniPathTracer.Create;
begin
  inherited Create;
  FAccumTextureID    := 0;
  FCausticsTextureID := 0;
  FFinalTextureID    := 0;
  FComputeProgram    := 0;
  FTriangleSSBO      := 0;
  FBVHSSBO           := 0;
  FMaterialUBO       := 0;
  FHdriUnit          := 3;
  FInitialized       := False;
end;

destructor TYutaniPathTracer.Destroy;
begin
  if GLReady then
  begin
    if FAccumTextureID    <> 0 then glDeleteTextures(1, @FAccumTextureID);
    if FCausticsTextureID <> 0 then glDeleteTextures(1, @FCausticsTextureID);
    if FFinalTextureID    <> 0 then glDeleteTextures(1, @FFinalTextureID);
    if FTriangleSSBO      <> 0 then glDeleteBuffers(1, @FTriangleSSBO);
    if FBVHSSBO           <> 0 then glDeleteBuffers(1, @FBVHSSBO);
    if FMaterialUBO       <> 0 then glDeleteBuffers(1, @FMaterialUBO);
    if FComputeProgram    <> 0 then glDeleteProgram(FComputeProgram);
  end;
  inherited;
end;

function TYutaniPathTracer.CompileComputeShader(const path: string): Cardinal;
var
  sl: TStringList;
  src: AnsiString;
  srcPtr: PAnsiChar;
  srcLen: Integer;
  shader: Cardinal;
  success: Integer;
  infoLog: array[0..511] of AnsiChar;
  programObj: Cardinal;
begin
  Result := 0;

  if not System.SysUtils.FileExists(path) then
    raise Exception.Create('Compute shader not found: ' + path);

  sl := TStringList.Create;
  try
    sl.LoadFromFile(path);
    src := AnsiString(sl.Text);
  finally
    sl.Free;
  end;

  if Length(src) = 0 then
    raise Exception.Create('Compute shader is empty: ' + path);

  srcPtr := PAnsiChar(src);
  srcLen := Length(src);

  shader := glCreateShader(GL_COMPUTE_SHADER);
  glShaderSource(shader, 1, @srcPtr, @srcLen);
  glCompileShader(shader);

  glGetShaderiv(shader, GL_COMPILE_STATUS, @success);
  if success = GL_FALSE then
  begin
    FillChar(infoLog, SizeOf(infoLog), 0);
    glGetShaderInfoLog(shader, SizeOf(infoLog), nil, infoLog);
    WriteLn(ErrOutput, 'ERROR::SHADER::COMPUTE::COMPILATION_FAILED');
    WriteLn(ErrOutput, infoLog);
    glDeleteShader(shader);
    Exit;
  end;

  programObj := glCreateProgram;
  glAttachShader(programObj, shader);
  glLinkProgram(programObj);

  glGetProgramiv(programObj, GL_LINK_STATUS, @success);
  if success = GL_FALSE then
  begin
    FillChar(infoLog, SizeOf(infoLog), 0);
    glGetProgramInfoLog(programObj, SizeOf(infoLog), nil, infoLog);
    WriteLn(ErrOutput, 'ERROR::PROGRAM::LINKING_FAILED');
    WriteLn(ErrOutput, infoLog);
    glDeleteShader(shader);
    glDeleteProgram(programObj);
    Exit;
  end;

  glDeleteShader(shader);
  Result := programObj;
end;

procedure TYutaniPathTracer.CreateComputeTexture(resX, resY: Integer);
begin
  glGenTextures(1, @FAccumTextureID);
  glBindTexture(GL_TEXTURE_2D, FAccumTextureID);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, resX, resY);
  FGpuAccumBuffer.id     := FAccumTextureID;
  FGpuAccumBuffer.width  := resX;
  FGpuAccumBuffer.height := resY;
  FGpuAccumBuffer.mipmaps:= 1;
  FGpuAccumBuffer.format := PIXELFORMAT_UNCOMPRESSED_R32G32B32A32;
  SetTextureFilter(FGpuAccumBuffer, TEXTURE_FILTER_POINT);

  glGenTextures(1, @FCausticsTextureID);
  glBindTexture(GL_TEXTURE_2D, FCausticsTextureID);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, resX, resY);
  FGpuCausticsBuffer.id     := FCausticsTextureID;
  FGpuCausticsBuffer.width  := resX;
  FGpuCausticsBuffer.height := resY;
  FGpuCausticsBuffer.mipmaps:= 1;
  FGpuCausticsBuffer.format := PIXELFORMAT_UNCOMPRESSED_R32G32B32A32;
  SetTextureFilter(FGpuCausticsBuffer, TEXTURE_FILTER_POINT);

  glGenTextures(1, @FFinalTextureID);
  glBindTexture(GL_TEXTURE_2D, FFinalTextureID);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA32F, resX, resY);
  FGpuFinalBuffer.id     := FFinalTextureID;
  FGpuFinalBuffer.width  := resX;
  FGpuFinalBuffer.height := resY;
  FGpuFinalBuffer.mipmaps:= 1;
  FGpuFinalBuffer.format := PIXELFORMAT_UNCOMPRESSED_R32G32B32A32;
  SetTextureFilter(FGpuFinalBuffer, TEXTURE_FILTER_POINT);

  glBindTexture(GL_TEXTURE_2D, 0);
end;

procedure TYutaniPathTracer.InitTriangleSSBO(const trisGPU: TTriGPUArray);
begin
  glGenBuffers(1, @FTriangleSSBO);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FTriangleSSBO);

  if Length(trisGPU) > 0 then
    glBufferData(GL_SHADER_STORAGE_BUFFER,
                 NativeInt(Length(trisGPU)) * NativeInt(SizeOf(TriGPU)),
                 @trisGPU[0],
                 GL_STATIC_DRAW)
  else
    glBufferData(GL_SHADER_STORAGE_BUFFER, 0, nil, GL_STATIC_DRAW);

  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, FTriangleSSBO);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TYutaniPathTracer.InitBVHSSBO(const bvhGPU: TCompactBVHGPUArray);
begin
  glGenBuffers(1, @FBVHSSBO);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FBVHSSBO);

  if Length(bvhGPU) > 0 then
    glBufferData(GL_SHADER_STORAGE_BUFFER,
                 NativeInt(Length(bvhGPU)) * NativeInt(SizeOf(CompactBVHGPU)),
                 @bvhGPU[0],
                 GL_STATIC_DRAW)
  else
    glBufferData(GL_SHADER_STORAGE_BUFFER, 0, nil, GL_STATIC_DRAW);

  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 4, FBVHSSBO);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TYutaniPathTracer.UploadTriangles(var data: PTData);
var
  i: Integer;
  t: ^Tri;
  gpuTri: ^TriGPU;
  iorRefTransVec: TVector3;
begin
  SetLength(data.trisGPU, Length(data.tris));

  for i := 0 to High(data.tris) do
  begin
    t      := @data.tris[i];
    gpuTri := @data.trisGPU[i];

    // Pack material into the GPU vec4 layout. Materials are stored BY VALUE
    // inside Tri, so t^.mat is the PTMaterial record directly.
    gpuTri.mat.albedo_roughness   := V4(t.mat.albedo,            t.mat.roughness);
    gpuTri.mat.specular_metalness := V4(t.mat.specularCol,       t.mat.metalness);
    gpuTri.mat.emission_intensity := V4(t.mat.emissionCol,       t.mat.emissionIntensity);
    gpuTri.mat.absorption_amount  := V4(t.mat.absorptionCol,     t.mat.absorption);
    gpuTri.mat.volume_density     := V4(t.mat.volumeCol,         t.mat.density);

    iorRefTransVec.x := t.mat.IOR;
    iorRefTransVec.y := t.mat.refraction;
    iorRefTransVec.z := t.mat.volume;
    gpuTri.mat.extraParams := V4(iorRefTransVec, 0.0);

    gpuTri.a       := V4(t.a,       1.0);
    gpuTri.b       := V4(t.b,       1.0);
    gpuTri.c       := V4(t.c,       1.0);
    gpuTri.aN      := V4(t.aN,      0.0);
    gpuTri.bN      := V4(t.bN,      0.0);
    gpuTri.cN      := V4(t.cN,      0.0);
    gpuTri.eA      := V4(t.eA,      0.0);
    gpuTri.eB      := V4(t.eB,      0.0);
    gpuTri.normal  := V4(t.normal,  0.0);
    gpuTri.minV    := V4(t.minV,    0.0);
    gpuTri.maxV    := V4(t.maxV,    0.0);
    gpuTri.center  := V4(t.center,  0.0);

    gpuTri.id          := t.id;
    if t.doubleSided then
      gpuTri.doubleSided := 1
    else
      gpuTri.doubleSided := 0;
    gpuTri.modelId     := t.modelId;
    gpuTri.padding     := 0;
  end;

  // Guard: the actual GPU upload only works once the SSBO has been created
  // (InitTriangleSSBO) AND OpenGL 4.3 function pointers are loaded
  // (InitCompute -> LoadOpenGL43). During initial scene setup, this method
  // is called BEFORE InitCompute - in that case we just pack the CPU-side
  // data.trisGPU array and return. The real upload happens via
  // InitTriangleSSBO immediately after.
  if (FTriangleSSBO = 0) or (not GLReady) then
    Exit;

  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FTriangleSSBO);
  // Orphan-then-reupload pattern (mirrors the C++ version)
  glBufferData(GL_SHADER_STORAGE_BUFFER, 0, nil, GL_DYNAMIC_DRAW);
  if Length(data.trisGPU) > 0 then
    glBufferData(GL_SHADER_STORAGE_BUFFER,
                 NativeInt(Length(data.trisGPU)) * NativeInt(SizeOf(TriGPU)),
                 @data.trisGPU[0],
                 GL_DYNAMIC_DRAW);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TYutaniPathTracer.UploadBVH;
begin
  // Guard: same reasoning as UploadTriangles. The BVH SSBO doesn't exist
  // until InitBVHSSBO has been called, and GL pointers aren't loaded until
  // InitCompute has run.
  if (FBVHSSBO = 0) or (not GLReady) then
    Exit;

  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FBVHSSBO);
  glBufferData(GL_SHADER_STORAGE_BUFFER, 0, nil, GL_DYNAMIC_DRAW);
  if Length(FGlobalCompactBVHGPU) > 0 then
    glBufferData(GL_SHADER_STORAGE_BUFFER,
                 NativeInt(Length(FGlobalCompactBVHGPU)) * NativeInt(SizeOf(CompactBVHGPU)),
                 @FGlobalCompactBVHGPU[0],
                 GL_DYNAMIC_DRAW);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
end;

procedure TYutaniPathTracer.UpdateRMMaterialGPU(var params: PTParams);
var
  iorRefTransVec: TVector3;
begin
  params.rmMatGPU.albedo_roughness   := V4(params.rmMat.albedo,        params.rmMat.roughness);
  params.rmMatGPU.specular_metalness := V4(params.rmMat.specularCol,   params.rmMat.metalness);
  params.rmMatGPU.emission_intensity := V4(params.rmMat.emissionCol,   params.rmMat.emissionIntensity);
  params.rmMatGPU.absorption_amount  := V4(params.rmMat.absorptionCol, params.rmMat.absorption);
  params.rmMatGPU.volume_density     := V4(params.rmMat.volumeCol,     params.rmMat.density);

  iorRefTransVec.x := params.rmMat.IOR;
  iorRefTransVec.y := params.rmMat.refraction;
  iorRefTransVec.z := params.rmMat.volume;
  params.rmMatGPU.extraParams := V4(iorRefTransVec, 0.0);
end;

procedure TYutaniPathTracer.LoadHDRI(var params: PTParams);
begin
  FHdriTex := LoadTextureFromImage(params.hdri);
  SetTextureFilter(FHdriTex, TEXTURE_FILTER_BILINEAR);
end;

procedure TYutaniPathTracer.HdriBrightestValue(var hdri: TImage; var maxVal: Single);
var
  i, j: Integer;
  pIdx: Integer;
  data: PSingle;
  pCol: TVector3;
  val: Single;
begin
  maxVal := 0.0;
  if (hdri.data = nil) or (hdri.width <= 0) or (hdri.height <= 0) then
    Exit;

  data := PSingle(hdri.data);
  for i := 0 to hdri.height - 1 do
  begin
    for j := 0 to hdri.width - 1 do
    begin
      pIdx := (i * hdri.width + j) * 3;
      pCol.x := data[pIdx + 0];
      pCol.y := data[pIdx + 1];
      pCol.z := data[pIdx + 2];
      val := (pCol.x + pCol.y + pCol.z) / 3.0;
      if val > maxVal then
        maxVal := val;
    end;
  end;
end;

procedure TYutaniPathTracer.CreateFlatBVH(var data: PTData);
var
  triIndices: TCardinalArray;
  i: Integer;
  sorted: TTriArray;
  root: BVHNode;
begin
  SetLength(FGlobalBVH, 0);
  if Length(data.tris) = 0 then
    Exit;

  SetLength(FGlobalBVH, 1);

  SetLength(triIndices, Length(data.tris));
  for i := 0 to High(triIndices) do
    triIndices[i] := i;

  BVHNodeInit(root, 0, Length(data.tris) - 1);
  BVHNodeCalculateAABB(root, triIndices, data.tris);
  BVHNodeAvgSplit(root, triIndices, data.tris);

  // Place the root at index 0 BEFORE recursing into children. The child
  // builder is now index-based (it expects globalBVH[nodeIdx] to exist),
  // so the root must live in the array, not just in the local `root` var.
  FGlobalBVH[0] := root;

  if Length(data.tris) >= 3 then
  begin
    BVHNodeCreateChildren(0, triIndices, data.tris, FGlobalBVH);
    BVHNodeCalculateNextNeighbor(0, FGlobalBVH);
    // Refresh our local copy in case CreateChildren mutated the root
    // (it does - it sets children[0] and children[1] on the stored node).
    root := FGlobalBVH[0];
  end;

  // Reorder tris to match the sorted indices (BVH leaf references use the
  // final sorted order)
  SetLength(sorted, Length(data.tris));
  for i := 0 to High(triIndices) do
  begin
    sorted[i] := data.tris[triIndices[i]];
    sorted[i].id := i;
  end;
  data.tris := sorted;

  // Rebuild model -> triangle index mapping (the sort invalidated it)
  for i := 0 to High(data.models) do
    data.models[i].ClearTris;
  for i := 0 to High(data.tris) do
    data.models[data.tris[i].modelId].AddTri(i);

  // Flatten into the GPU-friendly layout
  SetLength(FGlobalCompactBVH, 0);
  FlattenBVH(0, FGlobalBVH, FGlobalCompactBVH);

  // Pack into CompactBVHGPU (vec4 + 4 uints, 48 bytes per node, std430 aligned)
  SetLength(FGlobalCompactBVHGPU, Length(FGlobalCompactBVH));
  for i := 0 to High(FGlobalCompactBVH) do
  begin
    FGlobalCompactBVHGPU[i].minV       := V4(FGlobalCompactBVH[i].minV, 0.0);
    FGlobalCompactBVHGPU[i].maxV       := V4(FGlobalCompactBVH[i].maxV, 0.0);
    FGlobalCompactBVHGPU[i].indexData  := FGlobalCompactBVH[i].indexData;
    FGlobalCompactBVHGPU[i].triCount   := FGlobalCompactBVH[i].triCount;
    FGlobalCompactBVHGPU[i].padding0   := 0;
    FGlobalCompactBVHGPU[i].padding1   := 0;
  end;
end;

procedure TYutaniPathTracer.FlattenBVH(buildNodeIdx: Cardinal; var buildNodes: TBVHNodeArray;
                                       var flatNodes: TCompactBVHArray);
var
  buildNode: ^BVHNode;
  compactNode: CompactBVH;
  myFlatIndex: Cardinal;
  count: Cardinal;
  rightChildFlatIdx: Cardinal;
begin
  buildNode := @buildNodes[buildNodeIdx];

  compactNode.minV := buildNode.minV;
  compactNode.maxV := buildNode.maxV;

  myFlatIndex := Cardinal(Length(flatNodes));
  SetLength(flatNodes, Length(flatNodes) + 1);

  if (buildNode.children[0] = $FFFFFFFF) and (buildNode.children[1] = $FFFFFFFF) then
  begin
    count := buildNode.endIndex - buildNode.indexData + 1;
    compactNode.triCount  := count;
    compactNode.indexData := buildNode.indexData;
  end
  else
  begin
    compactNode.triCount := 0;

    FlattenBVH(buildNode.children[0], buildNodes, flatNodes);

    rightChildFlatIdx := Cardinal(Length(flatNodes));
    FlattenBVH(buildNode.children[1], buildNodes, flatNodes);

    compactNode.indexData := rightChildFlatIdx;
  end;

  flatNodes[myFlatIndex] := compactNode;
end;

procedure TYutaniPathTracer.CacheUniformLocations;
begin
  FLocTime        := GetLoc(FComputeProgram, 'time');
  FLocBlur        := GetLoc(FComputeProgram, 'blur');
  FLocScreenRatio := GetLoc(FComputeProgram, 'screenRatio');
  FLocResX        := GetLoc(FComputeProgram, 'resX');
  FLocResY        := GetLoc(FComputeProgram, 'resY');
  FLocCurrentSample := GetLoc(FComputeProgram, 'currentSample');
  FLocMaxSamples    := GetLoc(FComputeProgram, 'maxSamples');
  FLocShouldSample  := GetLoc(FComputeProgram, 'shouldSample');
  FLocRayMarcher    := GetLoc(FComputeProgram, 'rayMarcher');
  FLocPathTracer    := GetLoc(FComputeProgram, 'pathTracer');
  FLocEnableCaustics:= GetLoc(FComputeProgram, 'enableCaustics');
  FLocSkyIntensity  := GetLoc(FComputeProgram, 'skyIntensity');
  FLocEnableSky     := GetLoc(FComputeProgram, 'enableSky');
  FLocSkyTop        := GetLoc(FComputeProgram, 'skyTop');
  FLocSkyBase       := GetLoc(FComputeProgram, 'skyBase');
  FLocEnableHDRI    := GetLoc(FComputeProgram, 'enableHDRI');
  FLocEnableSun     := GetLoc(FComputeProgram, 'enableSun');
  FLocSunAngle      := GetLoc(FComputeProgram, 'sunAngle');
  FLocSunColor      := GetLoc(FComputeProgram, 'sunColor');
  FLocSunIntensity  := GetLoc(FComputeProgram, 'sunIntensity');
  FLocSunDir        := GetLoc(FComputeProgram, 'sunDir');
  FLocBounces       := GetLoc(FComputeProgram, 'maxBounces');
  FLocRaysPerPixel  := GetLoc(FComputeProgram, 'raysPerPixel');
  FLocHdriRotation  := GetLoc(FComputeProgram, 'hdriRotation');
  FLocHdriBrigthest := GetLoc(FComputeProgram, 'hdriBrigthest');
  FLocHdriThreshold := GetLoc(FComputeProgram, 'hdriThreshold');
  FLocRmMaxSteps    := GetLoc(FComputeProgram, 'rmMaxSteps');
  FLocRmNearPlane   := GetLoc(FComputeProgram, 'rmNearPlane');
  FLocRmFarPlane    := GetLoc(FComputeProgram, 'rmFarPlane');
  FLocRmPBR         := GetLoc(FComputeProgram, 'rmPBR');
  FLocRmLodMinDistMult := GetLoc(FComputeProgram, 'rmLodMinDistMult');
  FLocRmLodAmount     := GetLoc(FComputeProgram, 'rmLodAmount');
  FLocRmNormalPrecision := GetLoc(FComputeProgram, 'rmNormalPrecision');
  FLocAperture    := GetLoc(FComputeProgram, 'aperture');
  FLocCamPos      := GetLoc(FComputeProgram, 'camPos');
  FLocRight       := GetLoc(FComputeProgram, 'right');
  FLocUp          := GetLoc(FComputeProgram, 'up');
  FLocCamNormal   := GetLoc(FComputeProgram, 'camNormal');
  FLocSensorSize  := GetLoc(FComputeProgram, 'sensorSize');
  FLocISO         := GetLoc(FComputeProgram, 'ISO');
  FLocFocalPoint  := GetLoc(FComputeProgram, 'focalPoint');
  FLocFocusDist   := GetLoc(FComputeProgram, 'focusDist');
  FLocNodeCount   := GetLoc(FComputeProgram, 'nodeCount');
  FLocHdri        := GetLoc(FComputeProgram, 'hdri');
  FLocMainBufferIntensity := GetLoc(FComputeProgram, 'mainBufferIntensity');
  FLocCausticsIntensity   := GetLoc(FComputeProgram, 'causticsIntensity');
  FLocExposure   := GetLoc(FComputeProgram, 'exposure');
  FLocContrast   := GetLoc(FComputeProgram, 'contrast');
end;

procedure TYutaniPathTracer.InitCompute(resX, resY: Integer; const shaderPath: string);
begin
  if not LoadOpenGL43 then
    raise Exception.Create('OpenGL 4.3+ not available. The Yutani path tracer requires compute shader support.');

  CreateComputeTexture(resX, resY);

  FComputeProgram := CompileComputeShader(shaderPath);
  if FComputeProgram = 0 then
    raise Exception.Create('Failed to compile compute shader: ' + shaderPath);

  CacheUniformLocations;

  // Material UBO (binding = 5, matches the GLSL layout)
  glGenBuffers(1, @FMaterialUBO);
  glBindBuffer(GL_UNIFORM_BUFFER, FMaterialUBO);
  glBufferData(GL_UNIFORM_BUFFER, SizeOf(PTMaterialGPU), nil, GL_DYNAMIC_DRAW);
  glBindBufferBase(GL_UNIFORM_BUFFER, 5, FMaterialUBO);
  glBindBuffer(GL_UNIFORM_BUFFER, 0);

  FInitialized := True;
end;

procedure TYutaniPathTracer.GpuSampleLogic(var params: PTParams);
begin
  if params.hasSceneChanged then
    params.shouldSample := False;

  if not params.shouldSample then
  begin
    params.currentSample := 1;
    params.renderTime    := 0.0;
  end;

  if (not params.shouldSample) or (params.currentSample < params.maxSamples) then
  begin
    if params.shouldSample then
      Inc(params.currentSample);
  end;
end;

function TYutaniPathTracer.GetGlobalCompactBVHGPUCopy: TCompactBVHGPUArray;
var
  i: Integer;
begin
  SetLength(Result, Length(FGlobalCompactBVHGPU));
  for i := 0 to High(FGlobalCompactBVHGPU) do
    Result[i] := FGlobalCompactBVHGPU[i];
end;

procedure TYutaniPathTracer.RunShader(screenSize: TVector2; resX, resY: Integer;
                                      var myCam: PTCam; var params: PTParams; var screen: PTScreen);
var
  numGroupsX, numGroupsY: Cardinal;
  srcRect, dstRect: TRectangle;
  origin: TVector2;
begin
  if not FInitialized then
    Exit;

  glUseProgram(FComputeProgram);

  // -- Global params
  glUniform1f(FLocTime,        params.totalMs);
  glUniform1f(FLocBlur,        params.blur);
  glUniform1f(FLocScreenRatio, screen.ratio);
  glUniform1i(FLocResX,        screen.resX);
  glUniform1i(FLocResY,        screen.resY);

  GpuSampleLogic(params);

  glUniform1i(FLocCurrentSample, params.currentSample);
  glUniform1i(FLocMaxSamples,    params.maxSamples);
  if params.shouldSample then
    glUniform1i(FLocShouldSample, 1)
  else
    glUniform1i(FLocShouldSample, 0);

  if params.rayMarcher then
    glUniform1i(FLocRayMarcher, 1)
  else
    glUniform1i(FLocRayMarcher, 0);
  if params.pathTracer then
    glUniform1i(FLocPathTracer, 1)
  else
    glUniform1i(FLocPathTracer, 0);
  if params.enableCaustics then
    glUniform1i(FLocEnableCaustics, 1)
  else
    glUniform1i(FLocEnableCaustics, 0);

  glUniform1f(FLocSkyIntensity, params.skyIntensity);
  if params.enableSky then
    glUniform1i(FLocEnableSky, 1)
  else
    glUniform1i(FLocEnableSky, 0);
  glUniform3f(FLocSkyTop, params.skyTop.x, params.skyTop.y, params.skyTop.z);
  glUniform3f(FLocSkyBase, params.skyBase.x, params.skyBase.y, params.skyBase.z);

  if params.enableHDRI then
    glUniform1i(FLocEnableHDRI, 1)
  else
    glUniform1i(FLocEnableHDRI, 0);

  if params.enableSun then
    glUniform1i(FLocEnableSun, 1)
  else
    glUniform1i(FLocEnableSun, 0);
  glUniform1f(FLocSunAngle,     params.sunAngle);
  glUniform3f(FLocSunColor,     params.sunColor.x, params.sunColor.y, params.sunColor.z);
  glUniform1f(FLocSunIntensity, params.sunIntensity);
  glUniform3f(FLocSunDir,       params.sunDir.x, params.sunDir.y, params.sunDir.z);

  glUniform1i(FLocBounces,      params.maxBounces);
  glUniform1i(FLocRaysPerPixel, params.raysPerPixel);

  glUniform1f(FLocHdriRotation,  params.hdriRotation);
  glUniform1f(FLocHdriBrigthest, params.hdriBrigthest);
  glUniform1f(FLocHdriThreshold, params.hdriThreshold);

  // -- Ray marching params
  glUniform1i(FLocRmMaxSteps,  params.rmMaxSteps);
  glUniform1f(FLocRmNearPlane, params.rmNearPlane);
  glUniform1f(FLocRmFarPlane,  params.rmFarPlane);
  if params.rmPBR then
    glUniform1i(FLocRmPBR, 1)
  else
    glUniform1i(FLocRmPBR, 0);
  glUniform1f(FLocRmLodMinDistMult, params.rmLodMinDistMult);
  glUniform1f(FLocRmLodAmount,      params.rmLodAmount);
  glUniform1f(FLocRmNormalPrecision, params.rmNormalPrecision);

  // -- Ray marching material UBO update
  UpdateRMMaterialGPU(params);
  glBindBuffer(GL_UNIFORM_BUFFER, FMaterialUBO);
  glBufferSubData(GL_UNIFORM_BUFFER, 0, SizeOf(PTMaterialGPU), @params.rmMatGPU);
  glBindBuffer(GL_UNIFORM_BUFFER, 0);

  // -- Camera params
  glUniform1f(FLocAperture,   myCam.aperture);
  glUniform3f(FLocCamPos,     myCam.camPos.x,  myCam.camPos.y,  myCam.camPos.z);
  glUniform3f(FLocRight,      myCam.right.x,   myCam.right.y,   myCam.right.z);
  glUniform3f(FLocUp,         myCam.up.x,      myCam.up.y,      myCam.up.z);
  glUniform3f(FLocCamNormal,  myCam.camNormal.x, myCam.camNormal.y, myCam.camNormal.z);
  glUniform1f(FLocSensorSize, myCam.sensorSize);
  glUniform1f(FLocISO,        myCam.ISO);
  glUniform3f(FLocFocalPoint, myCam.focalPoint.x, myCam.focalPoint.y, myCam.focalPoint.z);
  glUniform1f(FLocFocusDist,  myCam.focusDist);

  // -- Scene data
  glUniform1ui(FLocNodeCount, Cardinal(Length(FGlobalCompactBVHGPU)));

  glActiveTexture(GL_TEXTURE0 + FHdriUnit);
  glBindTexture(GL_TEXTURE_2D, FHdriTex.id);
  glUniform1i(FLocHdri, FHdriUnit);

  // -- Image params
  glUniform1f(FLocMainBufferIntensity, params.mainBufferIntensity);
  glUniform1f(FLocCausticsIntensity,   params.causticsIntensity);
  glUniform1f(FLocExposure,            params.exposure);
  glUniform1f(FLocContrast,            params.contrast);

  // -- Bind the three image textures
  glBindImageTexture(0, FAccumTextureID,    0, GL_FALSE, 0, GL_READ_WRITE, GL_RGBA32F);
  glBindImageTexture(1, FFinalTextureID,    0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA32F);
  glBindImageTexture(2, FCausticsTextureID, 0, GL_FALSE, 0, GL_WRITE_ONLY, GL_RGBA32F);

  // -- Dispatch in 16x16 workgroups
  numGroupsX := (resX + 15) div 16;
  numGroupsY := (resY + 15) div 16;
  glDispatchCompute(numGroupsX, numGroupsY, 1);

  // Make sure the final image is fully written before DrawTexturePro reads it
  glMemoryBarrier(GL_SHADER_IMAGE_ACCESS_BARRIER_BIT);

  // -- Blit the final texture to the screen via Raylib
  srcRect.x := 0.0; srcRect.y := 0.0;
  srcRect.width  := FGpuFinalBuffer.width;
  srcRect.height := FGpuFinalBuffer.height;
  origin.x := 0.0; origin.y := 0.0;
  dstRect.x := 0.0; dstRect.y := 0.0;
  dstRect.width  := screenSize.x;
  dstRect.height := screenSize.y;
  DrawTexturePro(FGpuFinalBuffer, srcRect, dstRect, origin, 0.0, WHITE);
end;

end.

