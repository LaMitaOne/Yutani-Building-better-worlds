{*******************************************************************************
  Yutani.GPUInfo v1.0 — Universal Hardware-Based GPU Capability & Speed Detector
********************************************************************************
  Detects actual GPU hardware capabilities, dedicated vs. shared VRAM, and
  real compute shader throughput without relying on fragile GPU name lists.

  Works across all Windows WDDM and OpenGL 4.3+ GPUs (NVIDIA, AMD, Intel HD/Iris/
  Arc, Moore Threads, Zhaoxin, virtualized / cloud / server GPUs) via a 3-step
  detection pipeline:
    1. DXGI Adapter Query (dxgi.dll): Reads true DedicatedVideoMemory and
       SharedSystemMemory across every Windows WDDM driver.
    2. OpenGL Vendor Extensions (NVX_gpu_memory_info / ATI_meminfo): Fallback
       and live free-VRAM detection for non-DXGI environments (Wine / Proton).
    3. Live Compute Micro-Benchmark (~10-15 ms): Dispatches a lightweight
       262K-element SSBO compute workload (with glFinish timing) to measure
       real GPU memory bandwidth and ALU throughput in milliseconds.

  Author:  Lara Miriam Tamy Reschke / LaMitaOne
  License: MIT
*******************************************************************************}
unit Yutani.GPUInfo;

interface

uses
  System.SysUtils, System.Classes, System.Math, Winapi.Windows;

type
  TGPUQualityTier = (gtFallback,     // No OpenGL 4.3 compute support (software / legacy hardware)
    gtLowIGPU,      // Low-power / older iGPU (e.g. Intel HD 515 / Core m3)
    gtMidIGPU,      // Modern iGPU with UMA memory (e.g. Ryzen Vega 6 / Iris Xe)
    gtDedicatedGPU  // Dedicated GPU with own VRAM (RTX, RX, Intel Arc, Server GPU)
  );

  TGPUCapabilities = record
    // Basic identification strings (for display / logging only)
    Vendor: string;
    Renderer: string;
    GLVersionStr: string;
    GLSLVersionStr: string;
    MajorVersion: Integer;
    MinorVersion: Integer;

    // Actual OpenGL hardware capabilities
    HasComputeShaders: Boolean;
    HasSSBO: Boolean;
    HasImageLoadStore: Boolean;
    HasBindlessTextures: Boolean;

    // Hardware resource limits
    MaxComputeWorkGroupsX: Integer;
    MaxComputeWorkGroupsY: Integer;
    MaxComputeWorkGroupsZ: Integer;
    MaxComputeWorkGroupInvocations: Integer;
    MaxSSBOSizeBytes: Int64;
    MaxTextureSize: Integer;
    MaxArrayTextureLayers: Integer;

    // Video memory metrics in MB (DXGI + OpenGL combined)
    DedicatedVRAM_MB: Integer;
    SharedRAM_MB: Integer;
    FreeVRAM_MB: Integer;
    HasDedicatedVRAM: Boolean;
    IsSoftwareAdapter: Boolean;

    // Live compute micro-benchmark results
    BenchmarkRan: Boolean;
    BenchmarkTimeMs: Double;   // Elapsed time for 10x 262K compute dispatches (ms)
    ComputeScore: Integer;     // Normalized score (e.g. m3 ~ 25, Ryzen iGPU ~ 300, RTX ~ 700+)

    // Automatic tier classification & workload budgets
    QualityTier: TGPUQualityTier;
    TierName: string;
    RecommendedParticles: Integer;
    RecommendedGrassBlades: Integer;
  end;

function DetectGPUCapabilities(ARunBenchmark: Boolean = True): TGPUCapabilities;

function FormatGPUReport(const ACaps: TGPUCapabilities): string;

procedure LogGPUInfo(const ACaps: TGPUCapabilities);

implementation

const
  // Core OpenGL string & version constants
  GL_VENDOR = $1F00;
  GL_RENDERER = $1F01;
  GL_VERSION = $1F02;
  GL_SHADING_LANGUAGE_VERSION = $8B8C;
  GL_EXTENSIONS = $1F03;
  GL_MAJOR_VERSION = $821B;
  GL_MINOR_VERSION = $821C;
  GL_NUM_EXTENSIONS = $821D;

  // Texture & Compute Shader constants (OpenGL 4.3+)
  GL_MAX_TEXTURE_SIZE = $0D33;
  GL_MAX_ARRAY_TEXTURE_LAYERS = $88FF;
  GL_COMPUTE_SHADER = $91B9;
  GL_COMPILE_STATUS = $8B81;
  GL_LINK_STATUS = $8B82;
  GL_SHADER_STORAGE_BUFFER = $90D2;
  GL_DYNAMIC_COPY = $88EA;
  GL_SHADER_STORAGE_BARRIER_BIT = $2000;
  GL_FALSE = 0;
  GL_MAX_COMPUTE_WORK_GROUP_COUNT = $91BE;
  GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS = $90EB;
  GL_MAX_SHADER_STORAGE_BLOCK_SIZE = $90DE;

  // NVIDIA VRAM extension (GL_NVX_gpu_memory_info)
  GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX = $9047;
  GL_GPU_MEMORY_INFO_TOTAL_AVAILABLE_MEMORY_NVX = $9048;
  GL_GPU_MEMORY_INFO_CURRENT_AVAILABLE_VIDMEM_NVX = $9049;

  // AMD / ATI VRAM extension (GL_ATI_meminfo)
  GL_VBO_FREE_MEMORY_ATI = $87FB;
  GL_TEXTURE_FREE_MEMORY_ATI = $87FC;

  // DXGI constants for WDDM adapter enumeration
  DXGI_ADAPTER_FLAG_SOFTWARE = 2;
  IID_IDXGIFactory1: TGUID = '{770aae78-f26f-4dba-a829-253c83d1b387}';

type
  DXGI_ADAPTER_DESC1 = record
    Description: array[0..127] of WideChar;
    VendorId: Cardinal;
    DeviceId: Cardinal;
    SubSysId: Cardinal;
    Revision: Cardinal;
    DedicatedVideoMemory: NativeUInt;
    DedicatedSystemMemory: NativeUInt;
    SharedSystemMemory: NativeUInt;
    AdapterLuid: Int64;
    Flags: Cardinal;
  end;

  IDXGIAdapter1 = interface(IUnknown)
    ['{29038f61-3839-4626-91fd-086879011a05}']
    function SetPrivateData(const Name: TGUID; DataSize: Cardinal; pData: Pointer): HResult; stdcall;
    function SetPrivateDataInterface(const Name: TGUID; const pUnknown: IUnknown): HResult; stdcall;
    function GetPrivateData(const Name: TGUID; var pDataSize: Cardinal; pData: Pointer): HResult; stdcall;
    function GetParent(const riid: TGUID; out ppParent): HResult; stdcall;
    function EnumOutputs(Output: Cardinal; out ppOutput: IUnknown): HResult; stdcall;
    function GetDesc(out pDesc: Pointer): HResult; stdcall;
    function CheckInterfaceSupport(const InterfaceName: TGUID; out pUMDVersion: Int64): HResult; stdcall;
    function GetDesc1(out pDesc: DXGI_ADAPTER_DESC1): HResult; stdcall;
  end;

  IDXGIFactory1 = interface(IUnknown)
    ['{770aae78-f26f-4dba-a829-253c83d1b387}']
    function SetPrivateData(const Name: TGUID; DataSize: Cardinal; pData: Pointer): HResult; stdcall;
    function SetPrivateDataInterface(const Name: TGUID; const pUnknown: IUnknown): HResult; stdcall;
    function GetPrivateData(const Name: TGUID; var pDataSize: Cardinal; pData: Pointer): HResult; stdcall;
    function GetParent(const riid: TGUID; out ppParent): HResult; stdcall;
    function EnumAdapters(Adapter: Cardinal; out ppAdapter: IUnknown): HResult; stdcall;
    function MakeWindowAssociation(WindowHandle: HWND; Flags: Cardinal): HResult; stdcall;
    function GetWindowAssociation(out pWindowHandle: HWND): HResult; stdcall;
    function CreateSwapChain(const pDevice: IUnknown; pDesc: Pointer; out ppSwapChain: IUnknown): HResult; stdcall;
    function CreateSoftwareAdapter(Module: HMODULE; out ppAdapter: IUnknown): HResult; stdcall;
    function EnumAdapters1(Adapter: Cardinal; out ppAdapter: IDXGIAdapter1): HResult; stdcall;
    function IsCurrent: BOOL; stdcall;
  end;

  TFNCreateDXGIFactory1 = function(const riid: TGUID; out ppFactory): HResult; stdcall;

  // Dynamic OpenGL function pointer types
  PFNGLGETSTRINGPROC = function(name: Cardinal): PAnsiChar; stdcall;

  PFNGLGETSTRINGIPROC = function(name: Cardinal; index: Cardinal): PAnsiChar; stdcall;

  PFNGLGETINTEGERVPROC = procedure(pname: Cardinal; params: PInteger); stdcall;

  PFNGLGETINTEGERI_VPROC = procedure(target: Cardinal; index: Cardinal; data: PInteger); stdcall;

  PFNGLGETINTEGER64VPROC = procedure(pname: Cardinal; data: PInt64); stdcall;

  PFNGLGETERRORPROC = function: Cardinal; stdcall;

  PFNGLFINISHPROC = procedure; stdcall;

  PFNGLCREATESHADERPROC = function(shaderType: Cardinal): Cardinal; stdcall;

  PFNGLSHADERSOURCEPROC = procedure(shader: Cardinal; count: Integer; str: PPAnsiChar; len: PInteger); stdcall;

  PFNGLCOMPILESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLDELETESHADERPROC = procedure(shader: Cardinal); stdcall;

  PFNGLGETSHADERIVPROC = procedure(shader: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLCREATEPROGRAMPROC = function: Cardinal; stdcall;

  PFNGLATTACHSHADERPROC = procedure(programObj: Cardinal; shader: Cardinal); stdcall;

  PFNGLLINKPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLDELETEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLGETPROGRAMIVPROC = procedure(programObj: Cardinal; pname: Cardinal; params: PInteger); stdcall;

  PFNGLUSEPROGRAMPROC = procedure(programObj: Cardinal); stdcall;

  PFNGLDISPATCHCOMPUTEPROC = procedure(num_groups_x, num_groups_y, num_groups_z: Cardinal); stdcall;

  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;

  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;

  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;

  PFNGLBINDBUFFERBASEPROC = procedure(target: Cardinal; index: Cardinal; buffer: Cardinal); stdcall;

function wglGetProcAddress(name: PAnsiChar): Pointer; stdcall; external 'opengl32.dll';

{ Resolves an OpenGL entry point via wglGetProcAddress or opengl32.dll export }
function GetGLProc(Lib: HMODULE; const Name: PAnsiChar): Pointer;
begin
  Result := wglGetProcAddress(Name);
  if (Result = nil) and (Lib <> 0) then
    Result := GetProcAddress(Lib, Name);
end;

{ Checks whether a specific OpenGL extension is supported by the active context }
function HasGLExtension(const ExtName: string; glGetString: PFNGLGETSTRINGPROC; glGetStringi: PFNGLGETSTRINGIPROC; glGetIntegerv: PFNGLGETINTEGERVPROC): Boolean;
var
  NumExt, I: Integer;
  P: PAnsiChar;
  AllExt: string;
begin
  Result := False;
  if Assigned(glGetStringi) and Assigned(glGetIntegerv) then
  begin
    NumExt := 0;
    glGetIntegerv(GL_NUM_EXTENSIONS, @NumExt);
    for I := 0 to NumExt - 1 do
    begin
      P := glGetStringi(GL_EXTENSIONS, Cardinal(I));
      if (P <> nil) and SameText(string(P), ExtName) then
        Exit(True);
    end;
  end
  else if Assigned(glGetString) then
  begin
    P := glGetString(GL_EXTENSIONS);
    if P <> nil then
    begin
      AllExt := ' ' + string(P) + ' ';
      Result := Pos(' ' + ExtName + ' ', AllExt) > 0;
    end;
  end;
end;
{ Queries vendor-agnostic WDDM adapter memory via DXGI (works for NVIDIA, AMD, Intel, Arc, etc.) }

procedure QueryDXGIMemory(var ACaps: TGPUCapabilities);
var
  DXGILib: HMODULE;
  CreateFactory1: TFNCreateDXGIFactory1;
  Factory: IDXGIFactory1;
  Adapter: IDXGIAdapter1;
  Desc: DXGI_ADAPTER_DESC1;
  Idx: Cardinal;
  BestDedMB, BestSharedMB, CurDedMB, CurSharedMB: Integer;
  BestIsSoftware: Boolean;
begin
  DXGILib := LoadLibrary('dxgi.dll');
  if DXGILib = 0 then
    Exit;
  try
    CreateFactory1 := GetProcAddress(DXGILib, 'CreateDXGIFactory1');
    if not Assigned(CreateFactory1) then
      Exit;
    if Failed(CreateFactory1(IID_IDXGIFactory1, Factory)) or not Assigned(Factory) then
      Exit;
    BestDedMB := -1;
    BestSharedMB := 0;
    BestIsSoftware := False;
    Idx := 0;
// Enumerate all WDDM adapters and select the strongest physical hardware device
    while Factory.EnumAdapters1(Idx, Adapter) = S_OK do
    begin
      if Succeeded(Adapter.GetDesc1(Desc)) then
      begin
        CurDedMB := Integer(Desc.DedicatedVideoMemory div (1024 * 1024));
        CurSharedMB := Integer(Desc.SharedSystemMemory div (1024 * 1024));
// Ignore Microsoft Basic Render Driver unless no hardware adapter exists
        if (Desc.Flags and DXGI_ADAPTER_FLAG_SOFTWARE) <> 0 then
        begin
          if BestDedMB < 0 then
          begin
            BestDedMB := CurDedMB;
            BestSharedMB := CurSharedMB;
            BestIsSoftware := True;
          end;
        end
        else if (CurDedMB > BestDedMB) or BestIsSoftware then
        begin
          BestDedMB := CurDedMB;
          BestSharedMB := CurSharedMB;
          BestIsSoftware := False;
        end;
      end;
      Adapter := nil;
      Inc(Idx);
    end;
    if BestDedMB >= 0 then
    begin
      ACaps.DedicatedVRAM_MB := BestDedMB;
      ACaps.SharedRAM_MB := BestSharedMB;
      ACaps.IsSoftwareAdapter := BestIsSoftware;
// Dedicated GPUs (RTX, RX, Intel Arc, Moore Threads, Server) report >= 1024 MB dedicated VRAM
      ACaps.HasDedicatedVRAM := (not BestIsSoftware) and (BestDedMB >= 1024);
    end;
  finally
    Factory := nil;
    FreeLibrary(DXGILib);
  end;
end;
{ Runs a lightweight ~10-15 ms compute shader micro-benchmark to measure real GPU throughput }

procedure RunComputeMicroBenchmark(GLMod: HMODULE; var ACaps: TGPUCapabilities);
const
  BENCH_SHADER: AnsiString = '#version 430'#10 + 'layout(local_size_x = 256) in;'#10 + 'layout(std430, binding = 0) buffer Buf { vec4 data[]; };'#10 + 'void main() {'#10 + '  uint i = gl_GlobalInvocationID.x;'#10 + '  vec4 v = data[i];'#10 + '  v.xy += sin(v.zw * 3.14159) * 0.01;'#10 + '  v.zw = cos(v.xy * 1.61803);'#10 + '  data[i] = v;'#10 + '}';
  ELEM_COUNT = 262144; // 256K vec4 elements = 4 MB SSBO
  DISPATCH_PASSES = 10;
var
  glCreateShader: PFNGLCREATESHADERPROC;
  glShaderSource: PFNGLSHADERSOURCEPROC;
  glCompileShader: PFNGLCOMPILESHADERPROC;
  glDeleteShader: PFNGLDELETESHADERPROC;
  glGetShaderiv: PFNGLGETSHADERIVPROC;
  glCreateProgram: PFNGLCREATEPROGRAMPROC;
  glAttachShader: PFNGLATTACHSHADERPROC;
  glLinkProgram: PFNGLLINKPROGRAMPROC;
  glDeleteProgram: PFNGLDELETEPROGRAMPROC;
  glGetProgramiv: PFNGLGETPROGRAMIVPROC;
  glUseProgram: PFNGLUSEPROGRAMPROC;
  glDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
  glMemoryBarrier: PFNGLMEMORYBARRIERPROC;
  glGenBuffers: PFNGLGENBUFFERSPROC;
  glDeleteBuffers: PFNGLDELETEBUFFERSPROC;
  glBindBuffer: PFNGLBINDBUFFERPROC;
  glBufferData: PFNGLBUFFERDATAPROC;
  glBindBufferBase: PFNGLBINDBUFFERBASEPROC;
  glFinish: PFNGLFINISHPROC;
  Shader, Prog, SSBO: Cardinal;
  P: PAnsiChar;
  L, Ok, Pass: Integer;
  Freq, T0, T1: Int64;
  ElapsedMs: Double;
begin
  glCreateShader := GetGLProc(GLMod, 'glCreateShader');
  glShaderSource := GetGLProc(GLMod, 'glShaderSource');
  glCompileShader := GetGLProc(GLMod, 'glCompileShader');
  glDeleteShader := GetGLProc(GLMod, 'glDeleteShader');
  glGetShaderiv := GetGLProc(GLMod, 'glGetShaderiv');
  glCreateProgram := GetGLProc(GLMod, 'glCreateProgram');
  glAttachShader := GetGLProc(GLMod, 'glAttachShader');
  glLinkProgram := GetGLProc(GLMod, 'glLinkProgram');
  glDeleteProgram := GetGLProc(GLMod, 'glDeleteProgram');
  glGetProgramiv := GetGLProc(GLMod, 'glGetProgramiv');
  glUseProgram := GetGLProc(GLMod, 'glUseProgram');
  glDispatchCompute := GetGLProc(GLMod, 'glDispatchCompute');
  glMemoryBarrier := GetGLProc(GLMod, 'glMemoryBarrier');
  glGenBuffers := GetGLProc(GLMod, 'glGenBuffers');
  glDeleteBuffers := GetGLProc(GLMod, 'glDeleteBuffers');
  glBindBuffer := GetGLProc(GLMod, 'glBindBuffer');
  glBufferData := GetGLProc(GLMod, 'glBufferData');
  glBindBufferBase := GetGLProc(GLMod, 'glBindBufferBase');
  glFinish := GetGLProc(GLMod, 'glFinish');
  if not Assigned(glCreateShader) or not Assigned(glDispatchCompute) or not Assigned(glFinish) then
    Exit;
  Shader := 0;
  Prog := 0;
  SSBO := 0;
  try
    Shader := glCreateShader(GL_COMPUTE_SHADER);
    P := PAnsiChar(BENCH_SHADER);
    L := Length(BENCH_SHADER);
    glShaderSource(Shader, 1, @P, @L);
    glCompileShader(Shader);
    glGetShaderiv(Shader, GL_COMPILE_STATUS, @Ok);
    if Ok = GL_FALSE then
      Exit;
    Prog := glCreateProgram();
    glAttachShader(Prog, Shader);
    glLinkProgram(Prog);
    glGetProgramiv(Prog, GL_LINK_STATUS, @Ok);
    if Ok = GL_FALSE then
      Exit;
    glGenBuffers(1, @SSBO);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER, SSBO);
    glBufferData(GL_SHADER_STORAGE_BUFFER, ELEM_COUNT * 16, nil, GL_DYNAMIC_COPY);
    glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 0, SSBO);
    glUseProgram(Prog);
// Single warmup pass to trigger shader compilation & GPU clock boost
    glDispatchCompute(ELEM_COUNT div 256, 1, 1);
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
    glFinish();
    QueryPerformanceFrequency(Freq);
    QueryPerformanceCounter(T0);
    for Pass := 1 to DISPATCH_PASSES do
    begin
      glDispatchCompute(ELEM_COUNT div 256, 1, 1);
      glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
    end;
    glFinish();
    QueryPerformanceCounter(T1);
    ElapsedMs := ((T1 - T0) * 1000.0) / Max(Freq, 1);
    if ElapsedMs < 0.05 then
      ElapsedMs := 0.05;
    ACaps.BenchmarkRan := True;
    ACaps.BenchmarkTimeMs := ElapsedMs;
    ACaps.ComputeScore := Round(1000.0 / ElapsedMs);
  finally
    if Assigned(glUseProgram) then
      glUseProgram(0);
    if (SSBO <> 0) and Assigned(glDeleteBuffers) then
      glDeleteBuffers(1, @SSBO);
    if (Prog <> 0) and Assigned(glDeleteProgram) then
      glDeleteProgram(Prog);
    if (Shader <> 0) and Assigned(glDeleteShader) then
      glDeleteShader(Shader);
  end;
end;

function DetectGPUCapabilities(ARunBenchmark: Boolean = True): TGPUCapabilities;
var
  GLMod: HMODULE;
  glGetString: PFNGLGETSTRINGPROC;
  glGetStringi: PFNGLGETSTRINGIPROC;
  glGetIntegerv: PFNGLGETINTEGERVPROC;
  glGetIntegeri_v: PFNGLGETINTEGERI_VPROC;
  glGetInteger64v: PFNGLGETINTEGER64VPROC;
  glGetError: PFNGLGETERRORPROC;
  P: PAnsiChar;
  ValInt, DedicatedKB, TotalKB, FreeKB: Integer;
  ATIMem: array[0..3] of Integer;
  HasNVXMem, HasATIMem: Boolean;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.TierName := 'Fallback (No Compute)';
// Step 1: Vendor-agnostic WDDM video memory detection via DXGI
  QueryDXGIMemory(Result);
  GLMod := GetModuleHandle('opengl32.dll');
  if GLMod = 0 then
    GLMod := LoadLibrary('opengl32.dll');
  glGetString := GetGLProc(GLMod, 'glGetString');
  glGetStringi := GetGLProc(GLMod, 'glGetStringi');
  glGetIntegerv := GetGLProc(GLMod, 'glGetIntegerv');
  glGetIntegeri_v := GetGLProc(GLMod, 'glGetIntegeri_v');
  glGetInteger64v := GetGLProc(GLMod, 'glGetInteger64v');
  glGetError := GetGLProc(GLMod, 'glGetError');
  if not Assigned(glGetString) or not Assigned(glGetIntegerv) then
    Exit;
// Drain any pre-existing OpenGL error flags
  if Assigned(glGetError) then
    while glGetError() <> 0 do
    ;
// Step 2: Query OpenGL identification strings & version
  P := glGetString(GL_VENDOR);
  if P <> nil then
    Result.Vendor := string(P);
  P := glGetString(GL_RENDERER);
  if P <> nil then
    Result.Renderer := string(P);
  P := glGetString(GL_VERSION);
  if P <> nil then
    Result.GLVersionStr := string(P);
  P := glGetString(GL_SHADING_LANGUAGE_VERSION);
  if P <> nil then
    Result.GLSLVersionStr := string(P);
  glGetIntegerv(GL_MAJOR_VERSION, @Result.MajorVersion);
  glGetIntegerv(GL_MINOR_VERSION, @Result.MinorVersion);
  if Assigned(glGetError) then
    while glGetError() <> 0 do
    ;
// Step 3: Verify OpenGL 4.3+ / ARB compute & buffer capabilities
  Result.HasComputeShaders := ((Result.MajorVersion > 4) or ((Result.MajorVersion = 4) and (Result.MinorVersion >= 3))) or HasGLExtension('GL_ARB_compute_shader', glGetString, glGetStringi, glGetIntegerv);
  Result.HasSSBO := ((Result.MajorVersion > 4) or ((Result.MajorVersion = 4) and (Result.MinorVersion >= 3))) or HasGLExtension('GL_ARB_shader_storage_buffer_object', glGetString, glGetStringi, glGetIntegerv);
  Result.HasImageLoadStore := ((Result.MajorVersion > 4) or ((Result.MajorVersion = 4) and (Result.MinorVersion >= 2))) or HasGLExtension('GL_ARB_shader_image_load_store', glGetString, glGetStringi, glGetIntegerv);
  Result.HasBindlessTextures := HasGLExtension('GL_ARB_bindless_texture', glGetString, glGetStringi, glGetIntegerv);
// Step 4: Query hardware resource limits
  glGetIntegerv(GL_MAX_TEXTURE_SIZE, @Result.MaxTextureSize);
  glGetIntegerv(GL_MAX_ARRAY_TEXTURE_LAYERS, @Result.MaxArrayTextureLayers);
  if Result.HasComputeShaders then
  begin
    if Assigned(glGetIntegeri_v) then
    begin
      glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 0, @Result.MaxComputeWorkGroupsX);
      glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 1, @Result.MaxComputeWorkGroupsY);
      glGetIntegeri_v(GL_MAX_COMPUTE_WORK_GROUP_COUNT, 2, @Result.MaxComputeWorkGroupsZ);
    end;
    glGetIntegerv(GL_MAX_COMPUTE_WORK_GROUP_INVOCATIONS, @Result.MaxComputeWorkGroupInvocations);
    if Assigned(glGetInteger64v) then
      glGetInteger64v(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, @Result.MaxSSBOSizeBytes)
    else
    begin
      ValInt := 0;
      glGetIntegerv(GL_MAX_SHADER_STORAGE_BLOCK_SIZE, @ValInt);
      Result.MaxSSBOSizeBytes := ValInt;
    end;
  end;
  if Assigned(glGetError) then
    while glGetError() <> 0 do
    ;
// Step 5: OpenGL VRAM extensions (NVIDIA / AMD) as fallback & live free-VRAM check
  HasNVXMem := HasGLExtension('GL_NVX_gpu_memory_info', glGetString, glGetStringi, glGetIntegerv);
  HasATIMem := HasGLExtension('GL_ATI_meminfo', glGetString, glGetStringi, glGetIntegerv);
  if HasNVXMem then
  begin
    DedicatedKB := 0;
    TotalKB := 0;
    FreeKB := 0;
    glGetIntegerv(GL_GPU_MEMORY_INFO_DEDICATED_VIDMEM_NVX, @DedicatedKB);
    glGetIntegerv(GL_GPU_MEMORY_INFO_TOTAL_AVAILABLE_MEMORY_NVX, @TotalKB);
    glGetIntegerv(GL_GPU_MEMORY_INFO_CURRENT_AVAILABLE_VIDMEM_NVX, @FreeKB);
    if (Result.DedicatedVRAM_MB = 0) and (DedicatedKB > 0) then
    begin
      Result.DedicatedVRAM_MB := DedicatedKB div 1024;
      Result.HasDedicatedVRAM := Result.DedicatedVRAM_MB >= 1024;
    end;
    Result.FreeVRAM_MB := FreeKB div 1024;
  end
  else if HasATIMem then
  begin
    FillChar(ATIMem, SizeOf(ATIMem), 0);
    glGetIntegerv(GL_TEXTURE_FREE_MEMORY_ATI, @ATIMem[0]);
    if ATIMem[0] <= 0 then
      glGetIntegerv(GL_VBO_FREE_MEMORY_ATI, @ATIMem[0]);

    Result.FreeVRAM_MB := ATIMem[0] div 1024;
    if Result.DedicatedVRAM_MB = 0 then
    begin
      Result.DedicatedVRAM_MB := Result.FreeVRAM_MB;
      Result.HasDedicatedVRAM := Result.DedicatedVRAM_MB >= 2048;
    end;
  end;

  if Assigned(glGetError) then
    while glGetError() <> 0 do
    ;
// Step 6: Run optional ~15 ms live compute micro-benchmark
  if ARunBenchmark and Result.HasComputeShaders and Result.HasSSBO then
    RunComputeMicroBenchmark(GLMod, Result);
  if Assigned(glGetError) then
    while glGetError() <> 0 do
    ;
// Step 7: Classify hardware tier & assign recommended particle / geometry budgets
  if not (Result.HasComputeShaders and Result.HasSSBO) or Result.IsSoftwareAdapter then
  begin
    Result.QualityTier := gtFallback;
    Result.TierName := 'Fallback (CPU / Software / No GL 4.3 Compute)';
    Result.RecommendedParticles := 10000;
    Result.RecommendedGrassBlades := 0;
  end
  else if (Result.HasDedicatedVRAM and (not Result.BenchmarkRan or (Result.ComputeScore >= 250))) or (Result.BenchmarkRan and (Result.ComputeScore >= 350)) then
  begin
    Result.QualityTier := gtDedicatedGPU;
    Result.TierName := 'Dedicated / High-Speed GPU';
    Result.RecommendedParticles := 8000000;
    Result.RecommendedGrassBlades := 2500000;
  end
  else if (Result.DedicatedVRAM_MB >= 384) or (Result.BenchmarkRan and (Result.ComputeScore >= 55)) then
  begin
    Result.QualityTier := gtMidIGPU;
    Result.TierName := 'Modern iGPU / UMA (Balanced)';
    Result.RecommendedParticles := 1500000;
    Result.RecommendedGrassBlades := 500000;
  end
  else
  begin
    Result.QualityTier := gtLowIGPU;
    Result.TierName := 'Low-Power / Legacy iGPU (Eco)';
    Result.RecommendedParticles := 200000;
    Result.RecommendedGrassBlades := 75000;
  end;
end;

function BoolToYesNo(B: Boolean): string;
begin
  if B then
    Result := 'YES'
  else
    Result := 'NO';
end;

function FormatGPUReport(const ACaps: TGPUCapabilities): string;
var
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Add('=== Yutani Universal GPU Report ===');
    SL.Add('Vendor:          ' + ACaps.Vendor);
    SL.Add('Renderer:        ' + ACaps.Renderer);
    SL.Add(Format('OpenGL / GLSL:   %s (v%d.%d) | %s', [ACaps.GLVersionStr, ACaps.MajorVersion, ACaps.MinorVersion, ACaps.GLSLVersionStr]));
    SL.Add('-----------------------------------');
    SL.Add('Compute Shader:  ' + BoolToYesNo(ACaps.HasComputeShaders));
    SL.Add('SSBO Support:    ' + BoolToYesNo(ACaps.HasSSBO));
    SL.Add('ImageLoadStore:  ' + BoolToYesNo(ACaps.HasImageLoadStore));
    SL.Add('Bindless Tex:    ' + BoolToYesNo(ACaps.HasBindlessTextures));
    SL.Add('-----------------------------------');
    SL.Add(Format('Dedicated VRAM:  %d MB (Dedicated Hardware: %s)', [ACaps.DedicatedVRAM_MB, BoolToYesNo(ACaps.HasDedicatedVRAM)]));
    if ACaps.SharedRAM_MB > 0 then
      SL.Add(Format('Shared Sys-RAM:  %d MB', [ACaps.SharedRAM_MB]));
    if ACaps.FreeVRAM_MB > 0 then
      SL.Add(Format('Free VRAM (GL):  %d MB', [ACaps.FreeVRAM_MB]));
    if ACaps.HasComputeShaders then
    begin
      SL.Add(Format('WorkGroups Max:  %d x %d x %d', [ACaps.MaxComputeWorkGroupsX, ACaps.MaxComputeWorkGroupsY, ACaps.MaxComputeWorkGroupsZ]));
      SL.Add(Format('Max SSBO Size:   %d MB', [ACaps.MaxSSBOSizeBytes div (1024 * 1024)]));
    end;
    if ACaps.BenchmarkRan then
      SL.Add(Format('15ms GPU Bench:  %.2f ms (Compute Score: %d)', [ACaps.BenchmarkTimeMs, ACaps.ComputeScore]));
    SL.Add('-----------------------------------');
    SL.Add('Detected Tier:   ' + ACaps.TierName);
    SL.Add(Format('Auto-Budget:     %d Particles | %d Grass Blades', [ACaps.RecommendedParticles, ACaps.RecommendedGrassBlades]));
    SL.Add('===================================');
    Result := SL.Text;
  finally
    SL.Free;
  end;
end;

procedure LogGPUInfo(const ACaps: TGPUCapabilities);
begin
  if IsConsole then
    WriteLn(FormatGPUReport(ACaps));
end;

end.

