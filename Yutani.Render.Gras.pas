{*******************************************************************************
  Yutani.Render.Gras v0.2
********************************************************************************
  GPU compute-shader grass field renderer.

  Specialised derivative of the Yutani.Render.Particles.GPU pipeline. The
  compute shader does NOT move particles through the volume - every blade
  is anchored at a procedurally-derived ground position and only its tip
  is bent by a fake wind field (directional wind + travelling gust waves +
  small per-blade turbulence). The vertex shader rebuilds each blade as a
  tall thin triangle standing on the ground, billboarded around the
  camera right axis so the blade is always seen edge-on or face-on
  depending on view angle.

  Features:
    - 1M+ blades at 60 FPS on modest GPUs (compute shader does all motion)
    - Per-blade random height, phase and tint (procedural variation, no
      textures, no per-blade state on the CPU after init)
    - Directional wind + travelling gust waves + per-blade oscillation +
      small turbulence (gusts look natural, not uniform)
    - Fake ambient color shift: blades that bend further get a brighter
      green (mimicking light catching the underside)
    - Field position (origin), width, depth, blade height, blade width,
      blade count, wind direction, wind strength, grass base/tip colors
      and color variation - all configurable from outside through simple
      setters, all live-editable at runtime (no buffer regeneration
      needed when only the uniforms change)

  SSBO layout (single buffer, half the bandwidth of the old 2-slot layout):
    binding=0  positions     vec4   .xy = totalBend (horizontal XZ displacement),
                                   .z  = bendNorm (bendDisp/maxBend, 0..1, color),
                                   .w  = unused
    (binding=1 bladeParams removed - all per-blade randoms now come from
     pcgHash(uint(idx)) inside the shaders, so there is nothing for the CPU
     to upload. At 500K blades this saves ~8 MB VRAM and ~16 MB/frame of
     compute+read bandwidth.)

  The base (root) position of every blade is derived procedurally from
  the particle index in BOTH the compute and vertex shader via a stable
  hash, so changing FieldOrigin / FieldSize at runtime just translates /
  stretches the field smoothly on the next frame - no CPU upload needed.

  Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}

unit Yutani.Render.Gras;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs,
  Winapi.Windows,
  Raylib, RayMath, rlgl;

type
  TYutaniGrassEngine = class
  private
    FLock: TCriticalSection;
    FComputeProgram: Cardinal;
    FRenderProgram: Cardinal;
    FSSBO_Positions: Cardinal;
    { FSSBO_BladeParams removed: all per-blade randoms (u, v, heightFactor,
      phase, leanDir, tint) are now derived in-shader from pcgHash(uint(idx)),
      so there is nothing for the CPU to upload. Saves 1 vec4 per blade of VRAM
      and one glBufferSubData upload per Recreate. }
    FBillboardVAO: Cardinal;
    FBillboardVBO: Cardinal;
    FNumParticles: Integer;
    FTime: Single;
    FGPUInitialized: Boolean;
    // Field configuration (all live-editable)
    FFieldOrigin: TVector3;
    FFieldWidth: Single;
    FFieldDepth: Single;
    FBladeHeight: Single;
    FBladeWidth: Single;
    // Wind (XYZ; only XZ are used by the shader)
    FWindDir: TVector3;
    FWindStrength: Single;
    FWindGustFreq: Single;
    // Grass colors (linear 0..1 RGB)
    FGrassColorBase: TVector3;
    FGrassColorTip: TVector3;
    FColorVariation: Single;
    // Render
    FParticleScale: Single;
    FHDRMultiplier: Single;
    // Bending: 0 = rigid (blades stay upright), 1 = soft (blades bend
    // strongly in the wind). Tunable from the host via SetBendAmount.
    FBendAmount: Single;
    // Mouse push interaction: when pushActive, the compute shader adds a
    // strong horizontal bend to blades near pushPos so it looks like the
    // mouse is parting / flattening the grass.
    FPushPos:      TVector3;
    FPushRadius:   Single;
    FPushStrength: Single;
    FPushActive:   Boolean;
    // Compute shader uniform locations
    FCompLoc_Time:           Integer;
    FCompLoc_DeltaTime:      Integer;
    FCompLoc_FieldOrigin:    Integer;
    FCompLoc_FieldSize:      Integer;
    FCompLoc_WindDir:        Integer;
    FCompLoc_WindStrength:   Integer;
    FCompLoc_WindGustFreq:   Integer;
    FCompLoc_ParticleCount:  Integer;
    FCompLoc_BladeHeight:    Integer;
    FCompLoc_BendAmount:     Integer;
    FCompLoc_PushPos:        Integer;
    FCompLoc_PushRadius:     Integer;
    FCompLoc_PushStrength:   Integer;
    FCompLoc_PushActive:     Integer;
    // Render shader uniform locations
    FRendLoc_ProjMatrix:       Integer;
    FRendLoc_ViewMatrix:       Integer;
    FRendLoc_BladeWidth:       Integer;
    FRendLoc_GrassColorBase:   Integer;
    FRendLoc_GrassColorTip:    Integer;
    FRendLoc_ColorVariation:   Integer;
    FRendLoc_HDRMultiplier:    Integer;
    FRendLoc_FieldOrigin:      Integer;
    FRendLoc_FieldSize:        Integer;
    FRendLoc_CamRight:          Integer;
    FRendLoc_BladeHeight:      Integer;
    procedure InitGPUResources;
    procedure FreeGPUResources;
    procedure BuildBillboardVAO;
    { RegenerateBladeParams removed - per-blade randoms now live in the
      shaders via pcgHash, no CPU upload needed. }
    procedure DispatchCompute(const dt: Single);
    procedure DrawInstances(const NumInstances: Integer; const ACamera: TCamera3D; const ACamRight: TVector3);
  public
    constructor Create(ANumParticles: Integer = 1000000);
    destructor  Destroy; override;
    procedure Initialise;
    procedure Update(const ADeltaTime: Single);
    procedure Render(const ACamera: TCamera3D);
    procedure Reset;
    { Configuration setters - all live-editable, no buffer regeneration }
    procedure SetFieldOrigin(X, Y, Z: Single);
    procedure SetFieldSize(AWidth, ADepth: Single);
    procedure SetBladeHeight(H: Single);
    procedure SetBladeWidth(W: Single);
    procedure SetWindDir(X, Y, Z: Single);
    procedure SetWindStrength(S: Single);
    procedure SetWindGustFreq(F: Single);
    procedure SetGrassColors(BaseR, BaseG, BaseB, TipR, TipG, TipB: Single);
    procedure SetColorVariation(V: Single);
    procedure SetHDRMultiplier(M: Single);
    procedure SetParticleScale(S: Single);
    procedure SetBendAmount(B: Single);
    { Mouse push interaction - when SetPush is called the compute shader
      adds a strong horizontal bend to blades near pushPos, simulating the
      user parting / flattening the grass with the cursor. Call ClearPush
      to disable. Mirrors the SetPush/ClearPush API of the Particles.GPU
      engine so existing call sites transfer directly. }
    procedure SetPush(const APos: TVector3; ARadius, AStrength: Single);
    procedure ClearPush;
    { Read-only properties }
    property NumParticles:   Integer read FNumParticles;
    property Time:           Single  read FTime;
    property GPUInitialized: Boolean read FGPUInitialized;
  end;

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
  GL_ARRAY_BUFFER                = $8892;
  GL_ELEMENT_ARRAY_BUFFER        = $8893;
  GL_SHADER_STORAGE_BUFFER       = $90D2;
  GL_STATIC_DRAW                 = $88E4;
  GL_DYNAMIC_COPY                = $88EA;
  GL_DYNAMIC_DRAW                = $88E8;
  GL_TRIANGLES                   = $0004;
  GL_TRIANGLE_STRIP              = $0005;
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
  PFNGLLINKPROGRAMPROC        = procedure(programObj: Cardinal); stdcall;
  PFNGLDELETEPROGRAMPROC      = procedure(programObj: Cardinal); stdcall;
  PFNGLGETPROGRAMIVPROC        = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;
  PFNGLGETPROGRAMINFOLOGPROC  = procedure(programObj: Cardinal; bufSize: Integer; length: PInteger; infoLog: PAnsiChar); stdcall;
  PFNGLUSEPROGRAMPROC         = procedure(programObj: Cardinal); stdcall;
  PFNGLGETUNIFORMLOCATIONPROC = function(programObj: Cardinal; name: PAnsiChar): Integer; stdcall;
  PFNGLUNIFORM1FPROC           = procedure(location: Integer; v: Single); stdcall;
  PFNGLUNIFORM1IPROC           = procedure(location: Integer; v: Integer); stdcall;
  PFNGLUNIFORM2FPROC           = procedure(location: Integer; x: Single; y: Single); stdcall;
  PFNGLUNIFORM3FPROC           = procedure(location: Integer; x: Single; y: Single; z: Single); stdcall;
  PFNGLUNIFORMMATRIX4FVPROC    = procedure(location: Integer; count: Integer; transpose: Byte; value: PSingle); stdcall;
  PFNGLDISPATCHCOMPUTEPROC    = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;
  PFNGLMEMORYBARRIERPROC      = procedure(barriers: Cardinal); stdcall;
  PFNGLGENVERTEXARRAYSPROC    = procedure(n: Integer; arrays: PCardinal); stdcall;
  PFNGLBINDVERTEXARRAYPROC    = procedure(array_: Cardinal); stdcall;
  PFNGLDELETEVERTEXARRAYSPROC = procedure(n: Integer; arrays: PCardinal); stdcall;
  PFNGLGENBUFFERSPROC         = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLDELETEBUFFERSPROC      = procedure(n: Integer; buffers: PCardinal); stdcall;
  PFNGLBINDBUFFERPROC         = procedure(target: Cardinal; buffer: Cardinal); stdcall;
  PFNGLBUFFERDATAPROC         = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;
  PFNGLBUFFERSUBDATAPROC      = procedure(target: Cardinal; offset: NativeInt; size: NativeInt; data: Pointer); stdcall;
  PFNGLBINDBUFFERBASEPROC     = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;
  PFNGLVERTEXATTRIBPOINTERPROC = procedure(index: Cardinal; size: Integer; type_: Cardinal; normalized: Byte; stride: Integer; pointer: Pointer); stdcall;
  PFNGLENABLEVERTEXATTRIBARRAYPROC = procedure(index: Cardinal); stdcall;
  PFNGLDRAWARRAYSINSTANCEDPROC = procedure(mode: Cardinal; first: Integer; count: Integer; instancecount: Integer); stdcall;
  PFNGLGETERRORPROC           = function: Cardinal; stdcall;
  PFNGLACTIVETEXTUREPROC       = procedure(texture: Cardinal); stdcall;

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';
procedure OutputDebugStringA(lpOutputString: PAnsiChar); stdcall; external 'kernel32.dll';
function rlGetShaderIdDefault: Cardinal; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlGetShaderIdDefault';
function rlGetShaderLocsDefault: PInteger; cdecl; external {$IFNDEF RAY_STATIC}cDllName{$ENDIF} name 'rlGetShaderLocsDefault';
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
  glUniform2f: PFNGLUNIFORM2FPROC;
  glUniform3f: PFNGLUNIFORM3FPROC;
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
  glUniform2f := GetProc('glUniform2f');
  glUniform3f := GetProc('glUniform3f');
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
    Assigned(glUniform2f) and Assigned(glUniform3f) and
    Assigned(glUniformMatrix4fv) and Assigned(glDispatchCompute) and
    Assigned(glMemoryBarrier) and Assigned(glGenVertexArrays) and
    Assigned(glBindVertexArray) and Assigned(glDeleteVertexArrays) and
    Assigned(glGenBuffers) and Assigned(glDeleteBuffers) and
    Assigned(glBindBuffer) and Assigned(glBufferData) and
    Assigned(glBufferSubData) and Assigned(glBindBufferBase) and
    Assigned(glVertexAttribPointer) and
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
    raise Exception.CreateFmt('Yutani.Render.Gras: %s shader compile FAILED:'#10#10'%s', [typeName, string(infoLog)]);
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
    raise Exception.CreateFmt('Yutani.Render.Gras: shader program link FAILED:'#10#10'%s', [string(infoLog)]);
  end;
  for i := Low(shaderIds) to High(shaderIds) do glDeleteShader(shaderIds[i]);
end;

{ ========================================================================== }
{ Embedded shader sources                                                   }
{ ========================================================================== }

const
  { Compute shader: writes the current tip position (xyz) + bend
    magnitude (w), and into a second vec4 slot per blade the normalized
    horizontal wind direction (xz) and a "bend progress" factor (w).

    Hash: we use a real integer PCG-style hash on the uint particle index
    instead of the old sin(float(index)) * 43758.5453 trick. With 1,000,000
    blades, float(idx) starts losing precision around idx = 1.0e6 (only
    ~7 decimal digits of precision at that magnitude), so consecutive
    indices produce near-identical sin() values, and the field develops
    visible stripe / lane artifacts. The uint hash is bit-precise and
    decorrelates consecutive indices cleanly.

    Uniform locations: NO hard-coded layout(location=N) - all uniforms are
    looked up via glGetUniformLocation in InitGPUResources. Some drivers
    collide when mixing explicit mat4 layout locations with implicit ones,
    and we were suspicious this was why "wind did nothing" on some setups. }
  COMPUTE_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout(local_size_x = 1024) in;'#10 +
    'layout(std430, binding=0) buffer ssbo0 { vec4 positions[]; };'#10 +
    'uniform float time;'#10 +
    'uniform float deltaTime;'#10 +
    'uniform vec3 fieldOrigin;'#10 +
    'uniform vec2 fieldSize;'#10 +
    'uniform vec3 windDir;'#10 +
    'uniform float windStrength;'#10 +
    'uniform float windGustFreq;'#10 +
    'uniform int particleCount;'#10 +
    'uniform float bladeHeight;'#10 +
    'uniform float bendAmount;'#10 +
    'uniform vec3  pushPos;'#10 +
    'uniform float pushRadius;'#10 +
    'uniform float pushStrength;'#10 +
    'uniform int   pushActive;'#10 +
    '// Integer PCG-style hash. Returns a 32-bit pseudo-random uint from a uint seed.'#10 +
    '// Bit-precise: consecutive seeds give decorrelated outputs - no float precision loss.'#10 +
    'uint pcgHash(uint state) {'#10 +
    '    state = state * 747796405u + 2891336453u;'#10 +
    '    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;'#10 +
    '    return (word >> 22u) ^ word;'#10 +
    '}'#10 +
    '// Convert a uint hash to a float in [0, 1).'#10 +
    'float hashToFloat(uint h) { return float(h) / 4294967295.0; }'#10 +
    '// Get a per-blade random float for "slot" N. The slot index mixes into the seed'#10 +
    '// so the same blade gets decorrelated values for u, v, lean, phase, etc.'#10 +
    'float bladeRand(uint idx, uint slot) {'#10 +
    '    return hashToFloat(pcgHash(idx * 5u + slot));'#10 +
    '}'#10 +
    'void main() {'#10 +
    '    uint index = gl_GlobalInvocationID.x;'#10 +
    '    if (index >= uint(particleCount)) return;'#10 +
    '    // === Procedural base position via PCG hash ==='#10 +
    '    // (must match the vertex shader - same hash, same slots, same fieldSize).'#10 +
    '    float u = bladeRand(index, 0u);'#10 +
    '    float v = bladeRand(index, 1u);'#10 +
    '    vec3 base = vec3('#10 +
    '        fieldOrigin.x + u * fieldSize.x,'#10 +
    '        fieldOrigin.y,'#10 +
    '        fieldOrigin.z + v * fieldSize.y'#10 +
    '    );'#10 +
    '    // Per-blade random factors: height multiplier, sway phase, color tint,'#10 +
    '    // and a random natural lean direction (XZ) - this is the resting'#10 +
    '    // direction the blade leans even with zero wind, so the field does'#10 +
    '    // not look like a brush head of perfectly vertical blades.'#10 +
    '    float heightFactor = 0.7 + bladeRand(index, 2u) * 0.6; // 0.7..1.3'#10 +
    '    float phase        = bladeRand(index, 3u) * 6.2831;'#10 +
    '    vec2  leanDir      = vec2(bladeRand(index, 4u) * 2.0 - 1.0,'#10 +
    '                              bladeRand(index, 5u) * 2.0 - 1.0);'#10 +
    '    if (length(leanDir) > 0.001) leanDir = normalize(leanDir); else leanDir = vec2(1.0, 0.0);'#10 +
    '    float height = heightFactor * bladeHeight;'#10 +
    '    // === Wind field ==='#10 +
    '    vec2 wind = windDir.xz * windStrength;'#10 +
    '    // Travelling gust: a sin wave moves across the field in the wind direction.'#10 +
    '    float gustWave = sin(time * windGustFreq - dot(base.xz - fieldOrigin.xz, windDir.xz) * 0.3);'#10 +
    '    gustWave = gustWave * 0.5 + 0.5;'#10 +
    '    gustWave = gustWave * gustWave;'#10 +
    '    wind *= (0.4 + gustWave * 0.9);'#10 +
    '    // Per-blade oscillation so blades donot all sync.'#10 +
    '    float sway = sin(time * 2.5 + phase);'#10 +
    '    wind *= (0.85 + sway * 0.15);'#10 +
    '    // Small local turbulence around the base position.'#10 +
    '    wind += vec2(sin(time * 1.7 + phase + base.x * 0.5),'#10 +
    '                 cos(time * 1.3 + phase + base.z * 0.5)) * 0.15;'#10 +
    '    // === Bending model ==='#10 +
    '    // Total horizontal displacement = natural lean + wind-driven bend.'#10 +
    '    //   - Natural lean: small constant offset (10-25% of height) in the blade'#10 +
    '    //     own lean direction. Independent of wind, so the field keeps some'#10 +
    '    //     shape even when windStrength = 0.'#10 +
    '    //   - Wind bend: scaled by bendAmount (slider 0..1) and by windMag. The'#10 +
    '    //     total is clamped to maxBend so the tip never flies past 60% of height.'#10 +
    '    float leanStrength = height * 0.15;'#10 +
    '    vec2  leanOffset   = leanDir * leanStrength;'#10 +
    '    float windMag = length(wind);'#10 +
    '    vec2  windBendDir  = (windMag > 0.001) ? wind / windMag : vec2(0.0);'#10 +
    '    float windBendMag   = windMag * height * 0.3 * bendAmount;'#10 +
    '    vec2  totalBend    = leanOffset + windBendDir * windBendMag;'#10 +
    '    // === Mouse push ==='#10 +
    '    // When pushActive, blades near pushPos in XZ get pushed away from the'#10 +
    '    // mouse with a soft quadratic falloff, and the max bend is lifted so'#10 +
    '    // the blades directly under the cursor can almost flatten out. This'#10 +
    '    // gives the interactive "parting the grass" effect.'#10 +
    '    float maxBend      = height * 0.6;'#10 +
    '    if (pushActive != 0) {'#10 +
    '        vec2  toPush      = base.xz - pushPos.xz;'#10 +
    '        float pushDist    = length(toPush);'#10 +
    '        if (pushDist < pushRadius && pushDist > 0.0001) {'#10 +
    '            float f = pow(1.0 - pushDist / pushRadius, 2.0);'#10 +
    '            vec2  pushDir = toPush / pushDist;'#10 +
    '            totalBend += pushDir * f * pushStrength;'#10 +
    '            // Lift the maxBend under the cursor so blades there can almost'#10 +
    '            // lie flat (95% of blade height) instead of being clamped at 60%.'#10 +
    '            maxBend = mix(maxBend, height * 0.95, f);'#10 +
    '        }'#10 +
    '    }'#10 +
    '    // === Spring-back / inertia ==='#10 +
    '    // Read the previous frame bend vector from the positions SSBO so we can'#10 +
    '    // smooth the bend over time. The mouse pushes blades down quickly, but'#10 +
    '    // when the user releases the button (or moves the cursor away) the blades'#10 +
    '    // should slowly spring back to their resting shape over ~1s, leaving a'#10 +
    '    // visible trail in the grass. Without this inertia the blades snap back'#10 +
    '    // in a single frame and the parting effect flickers.'#10 +
    '    //   Layout note: positions[index] now packs totalBend.xy directly into'#10 +
    '    //   .xy (was previously split across two vec4 slots: bendDir in slot 1'#10 +
    '    //   .xz and bendDisp in slot 1 .w). One vec4 per blade = half the bandwidth.'#10 +
    '    if (deltaTime > 0.0) {'#10 +
    '        vec2 prevBend = positions[index].xy;'#10 +
    '        // Asymmetric response: react fast when the new target bends further'#10 +
    '        // than the previous state (so the mouse pushes the grass down'#10 +
    '        // instantly), but slow when the grass is springing back up (so the'#10 +
    '        // trail remains visible for ~1-1.5s).'#10 +
    '        float prevLen = length(prevBend);'#10 +
    '        float newLen  = length(totalBend);'#10 +
    '        float rate;'#10 +
    '        if (newLen > prevLen) rate = clamp(deltaTime * 20.0, 0.0, 1.0);'#10 +
    '        else                  rate = clamp(deltaTime * 3.0,  0.0, 1.0);'#10 +
    '        totalBend = mix(prevBend, totalBend, rate);'#10 +
    '    }'#10 +
    '    float bendDisp     = length(totalBend);'#10 +
    '    if (bendDisp > maxBend) {'#10 +
    '        totalBend = totalBend * (maxBend / bendDisp);'#10 +
    '        bendDisp = maxBend;'#10 +
    '    }'#10 +
    '    // Output: ONE vec4 per blade in the positions SSBO (was two).'#10 +
    '    //   .xy = totalBend (horizontal XZ displacement of the tip from base)'#10 +
    '    //   .z  = bendDisp / maxBend (normalised 0..1 bend progress, used for color)'#10 +
    '    //   .w  = unused (kept for vec4 alignment)'#10 +
    '    // The vertex shader reconstructs tip and bendDir from .xy directly:'#10 +
    '    //   bendDisp = length(state.xy)'#10 +
    '    //   tip      = base + vec3(state.x, height - bendDisp*0.35, state.y)'#10 +
    '    //   control  = base + vec3(state.x*0.25, bladeHeight*0.65, state.y*0.25)'#10 +
    '    // No bendDirNorm or tip computed here any more - saves the ALU and'#10 +
    '    // the second SSBO write. At 500K blades this is ~8MB less VRAM and'#10 +
    '    // ~16MB/frame less bandwidth on the compute dispatch + render read.'#10 +
    '    positions[index] = vec4(totalBend.x, totalBend.y, bendDisp / maxBend, 0.0);'#10 +
    '}';

  { Vertex shader: builds each blade as a CURVED strip of 3 triangles
    (5 vertices per blade via GL_TRIANGLE_STRIP) using a quadratic Bezier
    curve from base to tip. The control point is placed so the lower half
    of the blade stays mostly upright and only the upper half bends - this
    matches how real grass blades behave (rigid at the base, soft at the top).

    Reads ONE vec4 per blade from the positions SSBO (.xy=totalBend,
    .z=bendNorm) and reconstructs tip + control point locally, so no
    bladeParams SSBO is needed. Frustum-culls off-screen blades and
    applies distance LOD (drop every other blade + widen survivors) past
    w=14 in clip space.

    NO explicit layout(location=N) on uniforms - looked up via
    glGetUniformLocation in InitGPUResources. Some drivers mis-handle
    mat4 uniforms with explicit locations. }

  VERTEX_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'layout (location=0) in vec3 vertexPosition;'#10 +
    'uniform mat4 projectionMatrix;'#10 +
    'uniform mat4 viewMatrix;'#10 +
    'uniform float bladeWidth;'#10 +
    'uniform vec3 grassColorBase;'#10 +
    'uniform vec3 grassColorTip;'#10 +
    'uniform float colorVariation;'#10 +
    'uniform float hdrMultiplier;'#10 +
    'uniform vec3 fieldOrigin;'#10 +
    'uniform vec2 fieldSize;'#10 +
    'uniform vec3 camRight;'#10 +
    'uniform float bladeHeight;'#10 +
    'layout(std430, binding=0) buffer ssbo0 { vec4 positions[]; };'#10 +
    'out vec4 fragColor;'#10 +
    '// Same PCG hash as the compute shader - must produce IDENTICAL'#10 +
    '// values for the same (index, slot) so the vertex shader can'#10 +
    '// reconstruct the same procedural base position the compute shader used.'#10 +
    'uint pcgHash(uint state) {'#10 +
    '    state = state * 747796405u + 2891336453u;'#10 +
    '    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;'#10 +
    '    return (word >> 22u) ^ word;'#10 +
    '}'#10 +
    'float hashToFloat(uint h) { return float(h) / 4294967295.0; }'#10 +
    'float bladeRand(uint idx, uint slot) {'#10 +
    '    return hashToFloat(pcgHash(idx * 5u + slot));'#10 +
    '}'#10 +
    'void main() {'#10 +
    '    int idx = gl_InstanceID;'#10 +
    '    uint uidx = uint(idx);'#10 +
    '    // Read compute-shader output: ONE vec4 per blade (was two).'#10 +
    '    //   .xy = totalBend (horizontal XZ displacement)'#10 +
    '    //   .z  = bendNorm (0..1, for color)'#10 +
    '    //   .w  = unused'#10 +
    '    vec4 state     = positions[idx];'#10 +
    '    vec2 totalBend = state.xy;'#10 +
    '    float bendNorm = state.z;'#10 +
    '    float bendDisp = length(totalBend);'#10 +
    '    // Per-blade tint - now from hash directly (no more bladeParams SSBO).'#10 +
    '    float tint = bladeRand(uidx, 3u);'#10 +
    '    // === Procedural base position - same hash as compute shader ==='#10 +
    '    float u = bladeRand(uidx, 0u);'#10 +
    '    float v = bladeRand(uidx, 1u);'#10 +
    '    vec3 base = vec3('#10 +
    '        fieldOrigin.x + u * fieldSize.x,'#10 +
    '        fieldOrigin.y,'#10 +
    '        fieldOrigin.z + v * fieldSize.y'#10 +
    '    );'#10 +
    '    // === Frustum culling + distance LOD ==='#10 +
    '    // Compute the blade base in clip space and cull off-screen blades early'#10 +
    '    // so the vertex shader does no Bezier/Bezier-side/color work for them.'#10 +
    '    // The 1.35 margin on the x-extent covers the blade height (~2m) slop so'#10 +
    '    // blades whose base is just off-screen but whose tip would be visible'#10 +
    '    // are NOT culled. Anything outside this test is sent to (2,2,2) which is'#10 +
    '    // outside clip space, so the rasterizer discards it for free.'#10 +
    '    vec4 clipBase = projectionMatrix * viewMatrix * vec4(base, 1.0);'#10 +
    '    if (clipBase.w < -1.0 || abs(clipBase.x) > clipBase.w * 1.35) {'#10 +
    '        gl_Position = vec4(2.0, 2.0, 2.0, 1.0);'#10 +
    '        return;'#10 +
    '    }'#10 +
    '    // Distance LOD: blades farther than w=14 (roughly the back of a 20x20 patch'#10 +
    '    // from the default camera) get thinned by 50% - every other blade is dropped,'#10 +
    '    // and the survivors get bladeWidth*1.6 so the field still reads as dense from'#10 +
    '    // far away. This halves pixel overdraw in the distance where it matters most'#10 +
    '    // for fill rate on integrated GPUs.'#10 +
    '    float localBladeWidth = bladeWidth;'#10 +
    '    if (clipBase.w > 14.0) {'#10 +
    '        if ((idx & 1) == 1) {'#10 +
    '            gl_Position = vec4(2.0, 2.0, 2.0, 1.0);'#10 +
    '            return;'#10 +
    '        }'#10 +
    '        localBladeWidth *= 1.6;'#10 +
    '    }'#10 +
    '    // Per-blade height (same formula as compute shader) - needed because we'#10 +
    '    // now reconstruct tip here instead of reading it from the SSBO.'#10 +
    '    float heightFactor = 0.7 + bladeRand(uidx, 2u) * 0.6;'#10 +
    '    float height = heightFactor * bladeHeight;'#10 +
    '    // Reconstruct tip from totalBend + per-blade height (was written by the'#10 +
    '    // compute shader before; now computed here to save the SSBO slot).'#10 +
    '    vec3 tip = base + vec3(totalBend.x, height - bendDisp * 0.35, totalBend.y);'#10 +
    '    // Per-vertex: vertexPosition.x = t (0..1 along blade), vertexPosition.y = side (-1/0/+1).'#10 +
    '    float tParam = vertexPosition.x;'#10 +
    '    float side   = vertexPosition.y;'#10 +
    '    // === Bezier control point ==='#10 +
    '    // Same as before: lower half of blade stays upright, upper half bends.'#10 +
    '    // bendDir * bendDisp = totalBend (when bendDisp > 0), so we use totalBend'#10 +
    '    // directly - no need to normalize then multiply back. When bendDisp is'#10 +
    '    // ~0 the contribution collapses to ~0 anyway, matching the old fallback.'#10 +
    '    vec3 control = base + vec3(totalBend.x * 0.25,'#10 +
    '                              bladeHeight * 0.65,'#10 +
    '                              totalBend.y * 0.25);'#10 +
    '    // Quadratic Bezier: P(t) = (1-t)^2 * base + 2*(1-t)*t * control + t^2 * tip'#10 +
    '    float omt = 1.0 - tParam;'#10 +
    '    vec3 center = omt*omt*base + 2.0*omt*tParam*control + tParam*tParam*tip;'#10 +
    '    // Side offset: blade width tapers quadratically to the tip so the tip'#10 +
    '    // is a sharp point. widthScale goes from 1.0 at the base to ~0.06 at the tip.'#10 +
    '    float widthScale = pow(1.0 - tParam, 0.8);'#10 +
    '    vec3 worldPos = center + camRight * side * localBladeWidth * 0.5 * widthScale;'#10 +
    '    // === Color ==='#10 +
    '    // Base color: lerp from base color (root) to tip color (top), with per-blade tint variation.'#10 +
    '    vec3 col = mix(grassColorBase, grassColorTip, tParam + tint * colorVariation);'#10 +
    '    // Ambient occlusion: darken the foot of the blade heavily so the blades'#10 +
    '    // feel grounded and dense. At tParam = 0 we go to 25% of the base color,'#10 +
    '    // fading out by tParam = 0.3.'#10 +
    '    if (tParam < 0.3) col = mix(grassColorBase * 0.25, col, tParam / 0.3);'#10 +
    '    // Fake light response: blades that are bent further get a subtle extra'#10 +
    '    // green + warm shift, mimicking the underside catching the light.'#10 +
    '    float bendFactor = clamp(bendNorm * 1.5, 0.0, 1.0);'#10 +
    '    col += vec3(0.08, 0.12, 0.05) * bendFactor;'#10 +
    '    fragColor = vec4(col * hdrMultiplier, 1.0);'#10 +
    '    gl_Position = projectionMatrix * viewMatrix * vec4(worldPos, 1.0);'#10 +
    '}';

  FRAGMENT_SHADER_SRC: AnsiString =
    '#version 430'#10 +
    'in vec4 fragColor; out vec4 finalColor;'#10 +
    'void main() { finalColor = fragColor; }';

  { Blade vertex stream for GL_TRIANGLE_STRIP. Each vertex encodes its
    (t, side) pair as vertexPosition.xy - the vertex shader ignores .z.
       t    = 0..1 along the blade (0 = root, 1 = tip)
       side = -1 (left edge), +1 (right edge), 0 (centerline, used at tip)

    5 vertices produce 3 triangles via GL_TRIANGLE_STRIP. Progression of
    optimizations on this stream:
       15 verts GL_TRIANGLES  (5 separate tris)
        7 verts GL_TRIANGLE_STRIP (5 strip tris, 4 unique t values)
        5 verts GL_TRIANGLE_STRIP (3 strip tris, 3 unique t values: 0.0,
           0.52, 1.0)

    The quadratic Bezier curve in the vertex shader (mix(mix(base, control,
    t), mix(control, tip, t), t)) keeps the blade silhouette almost
    identically rounded even with only 2 segments - the polygonal kink at
    t=0.52 is sub-pixel at grass-blade scale and camera distance. Each
    strip triangle reuses 2 vertices from the previous one, so the vertex
    shader runs only 5 times per blade.

    Strip winding (counter-clockwise front-facing):
       strip tri 0: (v0, v1, v2)
       strip tri 1: (v1, v2, v3) [wound as (v2, v1, v3) by the strip]
       strip tri 2: (v2, v3, v4)
    The driver swaps winding on every other triangle, which GL_TRIANGLE_STRIP
    does automatically, so all 3 tris face the camera correctly. }
  BLADE_VERTS: array[0..4] of TVector3 = (
    (x: 0.00; y: -1.0; z: 0.0),  // v0: base-left
    (x: 0.00; y:  1.0; z: 0.0),  // v1: base-right
    (x: 0.52; y: -1.0; z: 0.0),  // v2: mid-left
    (x: 0.52; y:  1.0; z: 0.0),  // v3: mid-right
    (x: 1.00; y:  0.0; z: 0.0)); // v4: tip (centerline, side=0)

{ ========================================================================== }
{ TYutaniGrassEngine                                                         }
{ ========================================================================== }

constructor TYutaniGrassEngine.Create(ANumParticles: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  if ANumParticles < 1024 then ANumParticles := 1024;
  // Round up to a multiple of 1024 (compute shader workgroup size).
  FNumParticles := ((ANumParticles + 1023) div 1024) * 1024;
  FComputeProgram := 0; FRenderProgram := 0;
  FSSBO_Positions := 0;
  FBillboardVAO := 0; FBillboardVBO := 0;
  FTime := 0.0;
  FGPUInitialized := False;
  // Field defaults: a 20x20 patch centred on the origin. The user overrides
  // these from outside - this is just a sensible starting point.
  FFieldOrigin := Vector3Create(-10.0, 0.0, -10.0);
  FFieldWidth   := 20.0;
  FFieldDepth   := 20.0;
  // 2m high blades are tall enough to read individual blades from the
  // default camera distance. 0.06m width is half the previous 0.12 - the
  // thinner blade plus the quadratic taper-to-tip in the vertex shader
  // gives a much more grass-like silhouette (sharp tips, not chunky tips).
  FBladeHeight  := 2.0;
  FBladeWidth   := 0.06;
  // Wind: gentle breeze blowing in +X direction. The defaults give a
  // clearly visible gust ripple across the field straight out of the
  // box - no need to crank the sliders to see motion.
  FWindDir := Vector3Create(1.0, 0.0, 0.2);
  FWindStrength := 1.5;
  FWindGustFreq := 1.0;
  // Grass colors: natural dark green base, brighter yellow-green tip.
  FGrassColorBase := Vector3Create(0.13, 0.34, 0.08);
  FGrassColorTip  := Vector3Create(0.45, 0.70, 0.20);
  FColorVariation := 0.20;
  FParticleScale  := 1.0;
  FHDRMultiplier  := 1.0;
  // Default bend: 0.7 = clearly bendy, but not completely soft. 1.0 = max soft,
  // 0.0 = rigid. The user can tune this from the form's "Bend Amount" slider.
  FBendAmount     := 0.7;
  // Mouse push: defaults safe / disabled until SetPush is called.
  FPushPos      := Vector3Create(0, 0, 0);
  FPushRadius   := 2.2;
  FPushStrength := 2.5;
  FPushActive   := False;
end;

destructor TYutaniGrassEngine.Destroy;
begin
  FreeGPUResources;
  FLock.Free;
  inherited;
end;

procedure TYutaniGrassEngine.InitGPUResources;
var csId, vsId, fsId: Cardinal;
    Positions: array of TVector4;
    I: Integer;
begin
  if FGPUInitialized then Exit;
  if not LoadOpenGL43 then
    raise Exception.Create('Yutani.Render.Gras: OpenGL 4.3+ function pointers not available.');
  csId := CompileShaderRaw(COMPUTE_SHADER_SRC, GL_COMPUTE_SHADER);
  FComputeProgram := LinkProgramRaw([csId]);
  vsId := CompileShaderRaw(VERTEX_SHADER_SRC, GL_VERTEX_SHADER);
  fsId := CompileShaderRaw(FRAGMENT_SHADER_SRC, GL_FRAGMENT_SHADER);
  FRenderProgram := LinkProgramRaw([vsId, fsId]);
  // Compute shader uniform locations
  FCompLoc_Time          := glGetUniformLocation(FComputeProgram, 'time');
  FCompLoc_DeltaTime     := glGetUniformLocation(FComputeProgram, 'deltaTime');
  FCompLoc_FieldOrigin   := glGetUniformLocation(FComputeProgram, 'fieldOrigin');
  FCompLoc_FieldSize     := glGetUniformLocation(FComputeProgram, 'fieldSize');
  FCompLoc_WindDir       := glGetUniformLocation(FComputeProgram, 'windDir');
  FCompLoc_WindStrength  := glGetUniformLocation(FComputeProgram, 'windStrength');
  FCompLoc_WindGustFreq  := glGetUniformLocation(FComputeProgram, 'windGustFreq');
  FCompLoc_ParticleCount := glGetUniformLocation(FComputeProgram, 'particleCount');
  FCompLoc_BladeHeight   := glGetUniformLocation(FComputeProgram, 'bladeHeight');
  FCompLoc_BendAmount    := glGetUniformLocation(FComputeProgram, 'bendAmount');
  FCompLoc_PushPos       := glGetUniformLocation(FComputeProgram, 'pushPos');
  FCompLoc_PushRadius    := glGetUniformLocation(FComputeProgram, 'pushRadius');
  FCompLoc_PushStrength  := glGetUniformLocation(FComputeProgram, 'pushStrength');
  FCompLoc_PushActive    := glGetUniformLocation(FComputeProgram, 'pushActive');
  // Diagnostic: log every compute-shader uniform location so we can verify
  // in the debugger output window that they all resolved to a real location
  // (>= 0). A -1 here means the GLSL compiler optimised the uniform away
  // because it was not used (or had a typo in the name) - the corresponding
  // glUniform* call is then silently ignored, and the shader runs with the
  // default value of 0 for that uniform. This was one of the suspected
  // causes of the "everything is flat" bug.
  OutputDebugStringA(PAnsiChar(AnsiString(Format(
    'Yutani.Render.Gras compute uniforms: time=%d dt=%d origin=%d size=%d windDir=%d windStr=%d gust=%d count=%d bladeH=%d bend=%d pushPos=%d pushR=%d pushS=%d pushA=%d',
    [FCompLoc_Time, FCompLoc_DeltaTime, FCompLoc_FieldOrigin, FCompLoc_FieldSize,
     FCompLoc_WindDir, FCompLoc_WindStrength, FCompLoc_WindGustFreq,
     FCompLoc_ParticleCount, FCompLoc_BladeHeight, FCompLoc_BendAmount,
     FCompLoc_PushPos, FCompLoc_PushRadius, FCompLoc_PushStrength, FCompLoc_PushActive]))));
  // Render shader uniform locations
  FRendLoc_ProjMatrix     := glGetUniformLocation(FRenderProgram, 'projectionMatrix');
  FRendLoc_ViewMatrix     := glGetUniformLocation(FRenderProgram, 'viewMatrix');
  FRendLoc_BladeWidth    := glGetUniformLocation(FRenderProgram, 'bladeWidth');
  FRendLoc_GrassColorBase := glGetUniformLocation(FRenderProgram, 'grassColorBase');
  FRendLoc_GrassColorTip  := glGetUniformLocation(FRenderProgram, 'grassColorTip');
  FRendLoc_ColorVariation := glGetUniformLocation(FRenderProgram, 'colorVariation');
  FRendLoc_HDRMultiplier := glGetUniformLocation(FRenderProgram, 'hdrMultiplier');
  FRendLoc_FieldOrigin   := glGetUniformLocation(FRenderProgram, 'fieldOrigin');
  FRendLoc_FieldSize     := glGetUniformLocation(FRenderProgram, 'fieldSize');
  FRendLoc_CamRight       := glGetUniformLocation(FRenderProgram, 'camRight');
  FRendLoc_BladeHeight   := glGetUniformLocation(FRenderProgram, 'bladeHeight');
  // Positions SSBO: zero-initialised, the compute shader fills it on the
  // first dispatch. ONE vec4 per blade (.xy = totalBend, .z = bendNorm, .w = 0).
  // Was 2 vec4 per blade (tip.xyz+bendAmt + bendDir.xy+bendProgress); we cut
  // it in half by having the vertex shader reconstruct tip from totalBend +
  // per-blade height (also hashed), and drop the separate bendDir slot by
  // deriving direction from totalBend directly. At 500K blades this saves
  // ~8 MB of VRAM and ~16 MB/frame of bandwidth on the dispatch+readback.
  SetLength(Positions, FNumParticles);
  for I := 0 to FNumParticles - 1 do begin
    Positions[I].x := 0; Positions[I].y := 0;
    Positions[I].z := 0; Positions[I].w := 0;
  end;
  glGenBuffers(1, @FSSBO_Positions);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, FSSBO_Positions);
  glBufferData(GL_SHADER_STORAGE_BUFFER, FNumParticles * SizeOf(TVector4), @Positions[0], GL_DYNAMIC_COPY);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
  BuildBillboardVAO;
  // FGPUInitialized must be set before the first Update() call so that
  // DispatchCompute actually runs. There is no RegenerateBladeParams step
  // any more - all per-blade randoms are derived in-shader from pcgHash.
  FGPUInitialized := True;
end;

procedure TYutaniGrassEngine.FreeGPUResources;
begin
  if not FGPUInitialized then Exit;
  if (FComputeProgram <> 0) and Assigned(glDeleteProgram) then glDeleteProgram(FComputeProgram);
  if (FRenderProgram <> 0) and Assigned(glDeleteProgram) then glDeleteProgram(FRenderProgram);
  if FSSBO_Positions   <> 0 then glDeleteBuffers(1, @FSSBO_Positions);
  if FBillboardVBO      <> 0 then glDeleteBuffers(1, @FBillboardVBO);
  if FBillboardVAO      <> 0 then glDeleteVertexArrays(1, @FBillboardVAO);
  FComputeProgram := 0; FRenderProgram := 0;
  FSSBO_Positions := 0;
  FBillboardVAO := 0; FBillboardVBO := 0;
  FGPUInitialized := False;
end;

procedure TYutaniGrassEngine.BuildBillboardVAO;
begin
  glGenVertexArrays(1, @FBillboardVAO);
  glBindVertexArray(FBillboardVAO);
  try
    glGenBuffers(1, @FBillboardVBO);
    glBindBuffer(GL_ARRAY_BUFFER, FBillboardVBO);
    glBufferData(GL_ARRAY_BUFFER, SizeOf(BLADE_VERTS), @BLADE_VERTS[0], GL_STATIC_DRAW);
    glVertexAttribPointer(0, 3, GL_FLOAT, 0, SizeOf(TVector3), nil);
    glEnableVertexAttribArray(0);
  finally
    glBindVertexArray(0);
  end;
end;

procedure TYutaniGrassEngine.Initialise;
begin
  if FGPUInitialized then Exit;
  FLock.Acquire;
  try
    InitGPUResources;
    // First dispatch with dt=0 to fill the positions SSBO with valid
    // initial tip positions. Without this, the buffer is all zeros
    // (initialised by glBufferData) and every blade renders as a flat
    // triangle from its (procedural) base point to the world origin
    // (0,0,0) until the first Update() call. With Autostart in the form
    // the first Update() follows a few frames later, but the user still
    // sees the broken flat frame in between - this dispatch closes
    // that gap.
    DispatchCompute(0);
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.DispatchCompute(const dt: Single);
var GroupX: Cardinal; glErr: Cardinal;
begin
  rlDrawRenderBatchActive;
  rlSetShader(rlGetShaderIdDefault(), rlGetShaderLocsDefault());
  glUseProgram(FComputeProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Positions);
  glUniform1f(FCompLoc_Time,          FTime);
  glUniform1f(FCompLoc_DeltaTime,     dt);
  glUniform3f(FCompLoc_FieldOrigin,   FFieldOrigin.x, FFieldOrigin.y, FFieldOrigin.z);
  glUniform2f(FCompLoc_FieldSize,     FFieldWidth,   FFieldDepth);
  glUniform3f(FCompLoc_WindDir,       FWindDir.x,    FWindDir.y,    FWindDir.z);
  glUniform1f(FCompLoc_WindStrength,  FWindStrength);
  glUniform1f(FCompLoc_WindGustFreq,  FWindGustFreq);
  glUniform1i(FCompLoc_ParticleCount, FNumParticles);
  glUniform1f(FCompLoc_BladeHeight,   FBladeHeight);
  if FCompLoc_BendAmount >= 0 then
    glUniform1f(FCompLoc_BendAmount, FBendAmount);
  // Push uniforms - safe to call with -1 location (silently no-op per spec).
  if FCompLoc_PushPos >= 0 then
    glUniform3f(FCompLoc_PushPos, FPushPos.x, FPushPos.y, FPushPos.z);
  if FCompLoc_PushRadius >= 0 then
    glUniform1f(FCompLoc_PushRadius, FPushRadius);
  if FCompLoc_PushStrength >= 0 then
    glUniform1f(FCompLoc_PushStrength, FPushStrength);
  if FCompLoc_PushActive >= 0 then
    glUniform1i(FCompLoc_PushActive, Ord(FPushActive));
  GroupX := Cardinal(FNumParticles div 1024);
  glDispatchCompute(GroupX, 1, 1);
  glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, 0);
  glUseProgram(0);
  rlSetShader(rlGetShaderIdDefault(), rlGetShaderLocsDefault());
  glErr := glGetError();
  if glErr <> GL_NO_ERROR then
    OutputDebugStringA(PAnsiChar(AnsiString(Format('Yutani Gras: GL error after compute = 0x%x', [glErr]))));
end;

procedure TYutaniGrassEngine.DrawInstances(const NumInstances: Integer;
  const ACamera: TCamera3D; const ACamRight: TVector3);
var ProjMat, ViewMat: TMatrix; glErr: Cardinal;
begin
  if NumInstances <= 0 then Exit;
  ViewMat := rlGetMatrixModelview();
  ProjMat := rlGetMatrixProjection();
  rlDrawRenderBatchActive;
  glDisable(GL_CULL_FACE);
  glDepthMask(1);
  // PERFORMANCE: alpha blending is OFF. All grass blades are fully opaque
  // (fragColor.a = 1.0 in the vertex shader), so blending is wasted work
  // that costs a read-modify-write per fragment on top of the heavy overdraw
  // you get with 500K-1M blades. Disabling GL_BLEND lets the GPU's early-Z
  // reject occluded fragments before they hit the fragment shader, which
  // is a big win on integrated GPUs with limited memory bandwidth.
  glDisable(GL_BLEND);
  glUseProgram(FRenderProgram);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, FSSBO_Positions);
  glUniformMatrix4fv(FRendLoc_ProjMatrix, 1, GL_TRUE, @ProjMat);
  glUniformMatrix4fv(FRendLoc_ViewMatrix, 1, GL_TRUE, @ViewMat);
  glUniform1f(FRendLoc_BladeWidth,      FBladeWidth);
  glUniform3f(FRendLoc_GrassColorBase,  FGrassColorBase.x, FGrassColorBase.y, FGrassColorBase.z);
  glUniform3f(FRendLoc_GrassColorTip,   FGrassColorTip.x,  FGrassColorTip.y,  FGrassColorTip.z);
  glUniform1f(FRendLoc_ColorVariation,  FColorVariation);
  glUniform1f(FRendLoc_HDRMultiplier,   FHDRMultiplier);
  glUniform3f(FRendLoc_FieldOrigin,     FFieldOrigin.x, FFieldOrigin.y, FFieldOrigin.z);
  glUniform2f(FRendLoc_FieldSize,        FFieldWidth,   FFieldDepth);
  glUniform3f(FRendLoc_CamRight,         ACamRight.x,   ACamRight.y,   ACamRight.z);
  glUniform1f(FRendLoc_BladeHeight,      FBladeHeight);
  glBindVertexArray(FBillboardVAO);
  // PERFORMANCE: 5 vertices per blade via GL_TRIANGLE_STRIP. Was 7, was 15
  // before that. With the quadratic Bezier curve (mix(mix(base, control, t),
  // mix(control, tip, t), t)) we still sample 3 unique t values (0.0, 0.52,
  // 1.0) so the curve stays almost identically rounded - the silhouette is
  // only very slightly more polygonal, invisible at grass-blade scale - but
  // the vertex shader now runs only 5 times per blade instead of 7, another
  // ~30% reduction on top of the 7->15 cut.
  glDrawArraysInstanced(GL_TRIANGLE_STRIP, 0, 5, NumInstances);
  glBindVertexArray(0);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
  glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, 0);
  glUseProgram(0);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, 0);
  rlSetShader(rlGetShaderIdDefault(), rlGetShaderLocsDefault());
  // GL_BLEND was already disabled above - leave it disabled for the next
  // pass (we don't want to re-enable it just to have someone else disable
  // it again). Just restore cull-face and depth mask.
  glDepthMask(1);
  glEnable(GL_CULL_FACE);
  rlDrawRenderBatchActive;
  glErr := glGetError();
  if glErr <> GL_NO_ERROR then
    OutputDebugStringA(PAnsiChar(AnsiString(Format('Yutani Gras: GL error after draw = 0x%x', [glErr]))));
end;

procedure TYutaniGrassEngine.Update(const ADeltaTime: Single);
begin
  if not FGPUInitialized then InitGPUResources;
  if FNumParticles = 0 then Exit;
  FLock.Acquire;
  try
    FTime := FTime + ADeltaTime;
    DispatchCompute(ADeltaTime);
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.Render(const ACamera: TCamera3D);
var
  NumInstances: Integer;
  Fwd, Right: TVector3;
begin
  if not FGPUInitialized then InitGPUResources;
  NumInstances := FNumParticles;
  // Compute the camera right vector in world space for blade billboarding.
  // Doing it on the host avoids any matrix-layout ambiguity in the shader
  // (the existing Particles.GPU passes viewMatrix with GL_TRUE transpose
  // and reading its rows/columns for the right vector is fragile).
  Fwd.x := ACamera.target.x - ACamera.position.x;
  Fwd.y := ACamera.target.y - ACamera.position.y;
  Fwd.z := ACamera.target.z - ACamera.position.z;
  Fwd := Vector3Normalize(Fwd);
  Right := Vector3CrossProduct(Fwd, ACamera.up);
  Right := Vector3Normalize(Right);
  FLock.Acquire;
  try
    DrawInstances(NumInstances, ACamera, Right);
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.Reset;
begin
  FLock.Acquire;
  try
    FTime := 0.0;
  finally
    FLock.Release;
  end;
end;

{ ========================================================================== }
{ Configuration setters - all live-editable, no buffer regeneration         }
{ ========================================================================== }

procedure TYutaniGrassEngine.SetFieldOrigin(X, Y, Z: Single);
begin
  FLock.Acquire;
  try
    FFieldOrigin := Vector3Create(X, Y, Z);
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetFieldSize(AWidth, ADepth: Single);
begin
  FLock.Acquire;
  try
    FFieldWidth := AWidth;
    FFieldDepth := ADepth;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetBladeHeight(H: Single);
begin
  FLock.Acquire;
  try
    FBladeHeight := H;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetBladeWidth(W: Single);
begin
  FLock.Acquire;
  try
    FBladeWidth := W;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetWindDir(X, Y, Z: Single);
var Len: Single;
begin
  FLock.Acquire;
  try
    Len := Sqrt(X*X + Y*Y + Z*Z);
    if Len < 0.0001 then
      FWindDir := Vector3Create(1.0, 0.0, 0.0)
    else
      FWindDir := Vector3Create(X/Len, Y/Len, Z/Len);
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetWindStrength(S: Single);
begin
  FLock.Acquire;
  try
    FWindStrength := S;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetWindGustFreq(F: Single);
begin
  FLock.Acquire;
  try
    FWindGustFreq := F;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetGrassColors(BaseR, BaseG, BaseB, TipR, TipG, TipB: Single);
begin
  FLock.Acquire;
  try
    FGrassColorBase := Vector3Create(BaseR, BaseG, BaseB);
    FGrassColorTip  := Vector3Create(TipR,  TipG,  TipB);
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetColorVariation(V: Single);
begin
  FLock.Acquire;
  try
    FColorVariation := V;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetHDRMultiplier(M: Single);
begin
  FLock.Acquire;
  try
    FHDRMultiplier := M;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetParticleScale(S: Single);
begin
  FLock.Acquire;
  try
    FParticleScale := S;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetBendAmount(B: Single);
begin
  // Clamp to a sane range. 0 = rigid (no bending, blades stand straight
  // up regardless of wind), 1 = max soft (tip displaced by up to 0.6 * height
  // in the wind direction). Negative values would invert the bending
  // direction (tip bends into the wind) - not physically meaningful.
  if B < 0.0 then B := 0.0;
  if B > 1.0 then B := 1.0;
  FLock.Acquire;
  try
    FBendAmount := B;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.SetPush(const APos: TVector3; ARadius, AStrength: Single);
begin
  FLock.Acquire;
  try
    FPushPos      := APos;
    FPushRadius   := ARadius;
    FPushStrength := AStrength;
    FPushActive   := True;
  finally
    FLock.Release;
  end;
end;

procedure TYutaniGrassEngine.ClearPush;
begin
  FLock.Acquire;
  try
    FPushActive := False;
  finally
    FLock.Release;
  end;
end;

end.
