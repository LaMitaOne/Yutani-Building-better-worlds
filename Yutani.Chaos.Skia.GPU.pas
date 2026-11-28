unit Yutani.Chaos.Skia.GPU;
{==============================================================================*
 *  Yutani C.H.A.O.S. Skia GPU v0.43 - Holographic AI Desktop Overlay
 *------------------------------------------------------------------------------
 *  Module : Yutani.Chaos.Skia.GPU
 *  Type   : GPU-Accelerated Holographic AI Interface & Desktop Canvas
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *------------------------------------------------------------------------------
 *  Description:
 *  This unit renders a dynamic, holographic AI avatar ("Chaos") and free-form
 *  desktop projections using an OpenGL 4.3 Compute Shader pipeline. Particle
 *  spring physics, interactive 3D cursor force-field displacement/swirl,
 *  3D perspective projection with anatomical neck-pivot or rigid head tracking,
 *  depth-based volumetric shading, and soft radial glow splatting are executed
 *  entirely on the GPU via SSBOs and coherent image load/store operations.
 *  Supports procedural faces, 3D meshes (.glb/.obj) with sub-mesh filtering,
 *  per-part colour tints, an independent inner-core / brain mesh layer with
 *  instant SSBO offset/scale updates, five distinct shader styles (Hologram,
 *  Android Circuit, Cyber Matrix, Blueprint, Solid), automatic or custom eye
 *  sub-mesh dim-blinking with randomized intervals and double-blinks, idle
 *  breathing & saccadic micro-glances, jaw-hinge mouth animation with speech-
 *  energy glow, and photo-to-particle targets.
 *
 *  Composited via Skia onto a transparent, click-through FireMonkey layered
 *  window with auto-dim on cursor hover, interactive mouse dragging, live
 *  avatar resizing, a decoupled fullscreen Skia screen highlighter with
 *  DirtyRect clipping, full formation/dissolve states (0% load when despawned),
 *  and adaptive FPS. Complete per-head setups (mesh pair, orientation, style,
 *  appearance, behavior toggles, overlay placement, per-part tints and
 *  visibility) serialize to INI presets with automatic per-mesh restoration,
 *  auto-save on exit, and startup session continuation via last.ini.
 *==============================================================================}



interface

uses
  Winapi.Windows, System.SysUtils, System.Types, System.Classes, System.Math,
  System.Math.Vectors, System.UITypes, System.SyncObjs, System.IniFiles,
  System.IOUtils, System.Generics.Collections, FMX.Types, FMX.Controls,
  FMX.Graphics, FMX.Forms, FMX.Platform.Win, FMX.Skia, System.Skia,
  uSkiaCustomThreadedBase, uSkiaAliveHighlighter, Yutani.MeshLoader,
  Yutani.PhotoTo3D, Yutani.AI.Client, Yutani.Audio.Pipeline,
  Yutani.GPUInfo;

const
  CHAOS_WIDTH = 236;
  CHAOS_HEIGHT = 252;
  PARTICLE_MAX = 500000;
  DEFAULT_PARTICLE_BUDGET = 250000;
  SSBO_PARTICLE_SIZE = 52;
  DEPTH_MAP_STEP = 10;
  { Kill switch for the zero-copy persistent-mapped readback. Defaults to
    False: several AMD OpenGL drivers (e.g. Vega iGPU on Windows) do not
    honour GL_MAP_COHERENT_BIT on GL_PIXEL_PACK_BUFFER - the DMA engine of
    glGetTexImage writes past the CPU cache, so the CPU reads stale/unmapped
    memory (red pixel mush) while the GPU is still writing. The classic
    map/copy fallback then runs (~238 KB, ~0.02 ms) and is still zero-allocation
    per frame because FSkiaImages[0] caches FPixelBuffer. Set to True to
    re-enable the persistent path on drivers known to behave. }
  USE_PERSISTENT_PBO_READBACK = False;
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
  GL_NEAREST = $2600;
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
  { glBufferStorage flags for the persistent-mapped readback PBO. }
  GL_MAP_PERSISTENT_BIT = $0040;
  GL_MAP_COHERENT_BIT = $0080;
  GL_DYNAMIC_COPY = $88EA;

  { Monitor enumeration (value not exposed by Winapi.Windows): the
    primary flag of MONITORINFOEX.dwFlags. The SetWindowPos flags
    (SWP_NOSIZE / SWP_NOZORDER / SWP_NOACTIVATE) come from
    Winapi.Windows, which the unit already uses. }
  MONITORINFOF_PRIMARY = $00000001;

  { Visual style identifiers sent to the holo shader as uHoloStyle; the
    values must stay in sync with Ord(THoloStyle). }
  HOLO_STYLE_HOLOGRAM = 0;
  HOLO_STYLE_CIRCUIT = 1;
  HOLO_STYLE_CYBER = 2;
  HOLO_STYLE_BLUEPRINT = 3;
  HOLO_STYLE_SOLID = 4;

  { Flag bit marking the inner brain-core layer of the volumetric style.
    The low nibble of Flags still carries the body-region id used for
    contour / circuit placement (1 head, 2 torso/neck, 3 arms, 4 legs). }
  PARTICLE_FLAG_INNER_CORE = $00000100;

  { Flag bit marking eye geometry (eyeball / sclera / iris meshes whose name
    contains "eye" but not "lash" / "brow"). The holo shader dims particles
    carrying this flag with uEyeOpeness so a blink reads as a smooth
    holographic fade instead of a geometric lid displacement. }
  PARTICLE_FLAG_EYE = $00000200;

  { Auto-dim on mouseover: alpha multiplier the avatar eases to while the
    cursor hovers its screen rect (0.22 keeps the avatar visible but easy
    to see through), and the interpolation speed in 1/s units. }
  AUTO_DIM_ALPHA = 0.22;
  AUTO_DIM_SPEED = 8.0;

type
  TChaosState = (csIdle, csForming, csActive, csFading, csFinished);

  TMouthState = (msClosed, msMin, msMid, msFull);

  TEyeState = (esOpen, esMid, esClosed);

  TEmotionMode = (emNeutral, emThinking, emHappy, emAlert);

  { Switchable material / colour mode for the hologram renderer. The five
    styles map 1:1 onto the uHoloStyle values the shader branches on. }
  THoloStyle = (hsHologram, hsAndroidCircuit, hsCyberMatrix, hsBlueprint, hsSolid);

  { Selectable touch effect style. The Ord values map 1:1 onto the
    uTouchEffectStyle values the holo shader branches on:
    0 = Forcefield (soft radial push, the original behaviour),
    1 = Glow (no displacement, brightness lift inside the touch radius),
    2 = ColorFade (no displacement, colour blend into TouchEffectColor),
    3 = Ripple (soft concentric sine wave, Z displacement + shimmer). }
  TChaosTouchEffectStyle = (tesForcefield, tesGlow, tesColorFade, tesRipple);

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

  { Physical (device / pixel) bounds of one attached monitor plus its
    primary flag - what SendToDisplay snaps the host window onto. }
  TChaosDisplayInfo = record
    Bounds: TRect;
    Primary: Boolean;
  end;

  { MONITORINFOEXW for the EnumDisplayMonitors callback; TChaosDisplayInfo
    is the trimmed public view the panel consumes. }
  TMonitorInfoEx = record
    cbSize: Cardinal;
    rcMonitor: TRect;
    rcWork: TRect;
    dwFlags: Cardinal;
    szDevice: array[0..31] of WideChar;
  end;
  PMonitorInfoEx = ^TMonitorInfoEx;

  TMonitorEnumProc = function(hMonitor: THandle; hdcMonitor: HDC;
    lprcMonitor: PRect; dwData: NativeInt): LongBool; stdcall;

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

  PFNGLUNIFORM3FPROC = procedure(location: Integer; x, y, z: Single); stdcall;

  PFNGLUNIFORM4FPROC = procedure(location: Integer; x, y, z, w: Single); stdcall;

  PFNGLUNIFORM1IPROC = procedure(location: Integer; v: Integer); stdcall;

  PFNGLUNIFORM1UIPROC = procedure(location: Integer; v: Cardinal); stdcall;

  PFNGLDISPATCHCOMPUTEPROC = procedure(gx, gy, gz: Cardinal); stdcall;

  PFNGLMEMORYBARRIERPROC = procedure(barriers: Cardinal); stdcall;

  PFNGLGENBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLDELETEBUFFERSPROC = procedure(n: Integer; buffers: PCardinal); stdcall;

  PFNGLBINDBUFFERPROC = procedure(target: Cardinal; buffer: Cardinal); stdcall;

  PFNGLBUFFERDATAPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; usage: Cardinal); stdcall;

  { glBufferStorage (GL 4.4): immutable storage, flags allow persistent mapping. }

  PFNGLBUFFERSTORAGEPROC = procedure(target: Cardinal; size: NativeInt; data: Pointer; flags: Cardinal); stdcall;

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
  { True once wglMakeCurrent(FDummyDC, FGLContext) has been issued on the
    render thread. RenderEffect always runs on that one thread, so the
    binding is done once at init instead of per frame. }
    FContextBound: Boolean;
    FOutputTex: Cardinal;
    FParticleSSBO: Cardinal;
    FParticleCount: Cardinal;
    FParticleCPU: TBytes;
    { Set on the UI thread when the particle cloud / count changed and the
      SSBO must be re-uploaded. The actual glBindBuffer / glBufferSubData call
      happens on the render thread in RenderEffect, where FGLContext is
      current. Doing it on the UI thread silently fails because
      wglGetCurrentContext() is 0 there. }
    FSSBODirty: Boolean;
    { Serializes every access to FParticleCPU / FParticleCount / FSSBODirty
      between the UI thread (mesh loads, tint rewrites, budget retunes) and
      the render thread (SSBO upload, forming init). Without it the startup
      mesh build races the first RenderEffect passes and the interleaved
      writes stall the forming animation for a second or two. }
    FDataLock: TCriticalSection;
    FParticleProgram: Cardinal;
    FClearProgram: Cardinal;        // clears output texture per frame
    FLocP_DeltaTime, FLocP_Time, FLocP_Resolution: Integer;
    FLocP_ParticleCount, FLocP_BuildScanY, FLocP_DespawnScanY, FLocP_State: Integer;
    FLocP_ChaosLevel, FLocP_MouthOpen, FLocP_EyeOpeness: Integer;
    FLocP_LookX, FLocP_LookY, FLocP_PivotY, FLocP_EmotionMode: Integer;
    FLocP_AccentColor, FLocP_EyeColor, FLocP_MouthColor, FLocP_FaceColor: Integer;
    FLocP_HighlightRect, FLocP_HighlightPulse: Integer;
    FLocP_MinY, FLocP_MaxY: Integer;
    FLocC_Resolution: Integer;      // clear program uniforms
    FPBOs: array[0..1] of Cardinal;
    { Persistent per-PBO mappings (persistent path only); FPBOMaps[Index]
      belongs to FPBOs[Index]. }
    FPBOMaps: array[0..1] of Pointer;
    FPBOIndex: Integer;
    FPBOHasData: Boolean;
    FPBOSize: NativeInt;
    { One cached ISkImage per readback target. SkImages::RasterFromPixmap
      only *references* the pixels (verified in the sk4d source:
      sk4d_image_make_from_raster calls the sharing factory, no copy), so
      the images stay live on their backing memory. On the persistent path
      (USE_PERSISTENT_PBO_READBACK = True) index I wraps PBO I's mapping
      and RenderEffect draws the image of the finished frame's PBO
      (FPBOIndex xor 1). On the classic path (AMD driver default) index 0
      wraps FPixelBuffer - the staging buffer the fallback System.Move
      fills - so RenderEffect needs no MakeFromRaster allocation per frame
      either. FPixelBuffer must not be SetLength'd/reallocated anywhere
      after EnsureOutputTexture, or the image would point into freed heap. }
    FSkiaImages: array[0..1] of ISkImage;
    { True when the driver exported glBufferStorage (GL 4.4+); enables the
      zero-copy persistent-mapped readback path, otherwise the classic
      map/copy fallback runs. }
    FHasBufferStorage: Boolean;
    FPixelBuffer: TBytes;
    FState: TChaosState;
    FQuitAfterDespawn: Boolean;
    FMouseFollow: Boolean;
    FStayOnTop: Boolean;
  { Master switch for the procedural blink in RenderEffect (default True). }
    FAutoBlink: Boolean;
    { Feature toggles for isolated measurement / disabling, default True.
      TouchEffectsEnabled = False parks the cursor marker outside the
      shader (uMouseLocal = (-9999, -9999)) and stops velocity tracking,
      so the touch effects cost exactly nothing. IdleLifeMotion = False
      zeroes the idle head drift and the saccade offsets, freezing the
      rest pose. NaturalBlinking = False pins FBlinkPhase at 0 and skips
      the blink timer entirely. }
    FTouchEffectsEnabled: Boolean;
    { Modular touch effect: which of the four TChaosTouchEffectStyle
      variants the shader applies inside the cursor's influence radius,
      and the accent colour ColorFade blends into (Glow tints its
      brightness lift toward it as well; Forcefield / Ripple stay
      colour-neutral and purely geometric). }
    FTouchEffectStyle: TChaosTouchEffectStyle;
    FTouchEffectColor: TAlphaColor;
    FIdleLifeMotion: Boolean;
    FClickThrough: Boolean;
    FLookTargetX, FLookTargetY: Single;
    FCurrentMeshFile: string;
    FCurrentPhotoFile: string;
    { While a preset applies, mesh (re)loads must not trigger the automatic
      per-mesh preset load again - the preset is already being applied and
      the recursion would fight the very state it is restoring. }
    FLoadingPreset: Boolean;
    { True when a preset already restored the overlay placement at start,
      either from last.ini or from the probed mesh's own automatic slot.
      The host form checks this before stamping its default corner
      position over the restored one. }
    FStartupPresetLoaded: Boolean;
    { Placement captured while the control still has no parent (startup
      restore inside the constructor); re-applied, and clamped into the
      host form, from ParentChanged. }
    FHasPendingStartupPlacement: Boolean;
    FPendingStartupPos: TPointF;
    { Attached monitors, refreshed by RefreshDisplays (EnumDisplayMonitors
      walks the WinAPI list in device order; index 0..Count-1 is exactly
      what DisplayInfo / SendToDisplay address). Primary-first ordering
      would reshuffle on every refresh, so the device order stays as-is
      and CurrentDisplayIndex locates the entry geometrically instead. }
    FDisplays: TArray<TChaosDisplayInfo>;
    { Raised by SendToDisplay on the UI thread after the host window
      jumped: RenderEffect (render thread) consumes it right before its
      touch block to park uMouseLocal outside and zero the velocity, so
      no cursor-delta spike fires across the monitor jump. Interlocked
      because it is written UI-side and read/cleared render-side. }
    FTouchResetPending: Integer;
    { Per-part include filter persisted on the avatar so the controls panel
      can toggle parts on/off live and re-load the current source. Empty means
      "load every part that survives the exclude keyword list"; non-empty means
      only meshes whose name contains one of these keywords are emitted. }
    FMeshIncludeNames: TArray<string>;
    { Name of the mesh part to force-flag as the eyes, overriding the
      automatic "eye" name heuristic. Empty or '(Auto)' keeps the automatic
      detection; any other value must match a MeshNames entry exactly. }
    FCustomEyePartName: string;
    FPivotY: Single;
    FNeckPivotRatio: Single;
    FGlobalTime: Double;
    FLastTime: Double;              // for real DeltaTime tracking
    FBuildScanY, FDespawnScanY: Single;
    FMinY, FMaxY: Single;
  { Head bounding box (min/max over all bpHead particles) and its center /
    size derived in BuildMeshTargets / GenerateFaceTargets. They feed the
    uHeadCenter / uHeadSize uniforms so the shader can deform the mouth in
    normalized face coordinates (rel.y: -0.5 = crown, +0.5 = chin)
    without every particle evaluating its own bounds. }
    FHeadMinX, FHeadMaxX, FHeadMinY, FHeadMaxY, FHeadMinZ, FHeadMaxZ: Single;
    FHeadCenter: TPoint3D;
    FHeadSize: TPoint3D;
  { Auto-blink: procedural eye blink driven in RenderEffect. FBlinkTimer
    counts up in seconds; once it passes the current inter-blink pause a
    blink of BlinkDuration seconds runs. FBlinkPhase runs 0..1 through the
    blink (0 = open, 1 = closed) and is applied as a factor onto
    FEyeOpeness so a manually set EyeOpeness still scales correctly.
    Natural irregularity: FNextBlinkDelay is re-rolled after every blink
    (1.8-6.2 s, power-distributed toward shorter pauses; ~18 % of blinks
    chain into a double blink after only 0.14-0.22 s), and the single
    blink length itself varies by +-25 ms around BlinkDuration, so the
    rhythm never reads as a metronome. The old BlinkInterval property is
    gone; old presets carrying the key are simply ignored on load - the
    natural re-roll owns every pause. }
    FBlinkTimer: Double;
    FBlinkPhase: Single;
    FNextBlinkDelay: Single;
    FDoubleBlinkPending: Boolean;
    { Length of the currently running blink (BlinkDuration base varied by
     +-25 ms per blink); starts at the property default until the first
     completed blink re-rolls it. }
    FCurrentBlinkDuration: Single;
    FBlinkDuration: Single;
    FChaosLevel, FMouthOpen, FEyeOpeness: Single;
    FLookX, FLookY: Single;
    { Idle-life state: a resting cursor (or MouseFollow off) must not freeze
      the avatar. FMouseStillTimer counts the seconds the cursor stayed
      within 2 px (mouse sampling jitter tolerance); past 1.4 s FIdleBlend
      crossfades the multi-sinus head drift in. FSaccadeTimer paces
      unregular fixation changes - mostly tiny micro-saccades, occasionally
      a distinct sideways "thinking" glance. The rolled offsets are chase
      targets for FSaccadeSmoothX/Y, which ease toward them at 10/s so the
      head (eyes included - they rotate rigidly with it) glides into the
      new fixation instead of snapping within a single frame. }
    FSaccadeTimer: Single;
    FSaccadeOffsetX, FSaccadeOffsetY: Single;
    FSaccadeSmoothX, FSaccadeSmoothY: Single;
    FLastCursorPos: TPoint;
    FMouseStillTimer: Single;
    FIdleBlend: Single;
    { Mouse touch effects: cursor position converted into buffer
      coordinates plus its smoothed velocity, uploaded as uMouseLocal /
      uMouseVel. (-9999, -9999) marks "outside the control" so the shader's
      radius test never fires; the velocity decays while outside. }
    FMouseLocalX, FMouseLocalY: Single;
    FMouseVelX, FMouseVelY: Single;
    FMouseInside: Boolean;
    { Thread-safe screen geometry: the control's top-left in screen
      coordinates plus its size, refreshed by RefreshScreenGeometry on
      the UI thread (every Draw, on ParentChanged, while dragging and on
      avatar resize). The background render thread turns the raw
      GetCursorPos sample into control coordinates with pure subtraction
      against these caches - LocalToScreen / ScreenToLocal walk the FMX
      scene tree and must never run off the UI thread. X and Y are
      written in order, so the worst torn read is one stale coordinate
      for a single frame, corrected by the next refresh. }
    FScreenOrigin: TPoint;
    FControlW, FControlH: Single;
    { Auto-dim: current interpolated alpha multiplier applied on top of
      HoloAlpha. Eases toward AUTO_DIM_ALPHA while the cursor hovers the
      avatar rect and back to 1.0 when it leaves. }
    FCurrentHoverAlphaMul: Single;
    FAutoDimOnHover: Boolean;
    { Highlighter mouse-follow mode: when on, RenderEffect feeds the live
      cursor position (converted into the control's local frame) to the
      highlighter every frame so it keeps stalking the mouse. }
    FHighlightFollowMouse: Boolean;
    { Fired on the UI thread whenever something activates the highlighter
      (HighlightPoint / HighlightRect / enabling HighlightFollowMouse) so
      the full-desktop overlay host can switch itself visible immediately
      instead of waiting for its sleeping render loop to notice. }
    FOnHighlighterWake: TNotifyEvent;
    FEmotionMode: TEmotionMode;
    FAccentColor, FEyeColor, FMouthColor, FFaceColor: TAlphaColor;
    { Alive highlighter entity (organic light-snake overlay) drawn on top of
      the avatar image in RenderEffect. }
    FHighlighter: TAliveHighlighter;
    FHighlightActive: Boolean;
    FDepthMap: FMX.Graphics.TBitmap;
    FParticleBudget: Cardinal;
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
    FnUniform3f: PFNGLUNIFORM3FPROC;
    FnUniform4f: PFNGLUNIFORM4FPROC;
    FnUniform1i: PFNGLUNIFORM1IPROC;
    FnUniform1ui: PFNGLUNIFORM1UIPROC;
    FnDispatchCompute: PFNGLDISPATCHCOMPUTEPROC;
    FnMemoryBarrier: PFNGLMEMORYBARRIERPROC;
    FnGenBuffers: PFNGLGENBUFFERSPROC;
    FnDeleteBuffers: PFNGLDELETEBUFFERSPROC;
    FnBindBuffer: PFNGLBINDBUFFERPROC;
    FnBufferData: PFNGLBUFFERDATAPROC;
    FnBufferStorage: PFNGLBUFFERSTORAGEPROC;
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
    { Custom inner core / brain mesh, loaded independently of the outer
      cloud. BuildMeshTargets appends its points inside the head while
      FInnerCore is on; FInnerPartColors holds per-part tint overrides
      parallel to FInnerMeshResult.MeshNames. }
    FInnerMeshFile: string;
    FInnerMeshResult: TMeshLoadResult;
    FInnerPartColors: TArray<TAlphaColor>;
    FInnerCoreScale: Single;
    FInnerCoreOffsetY: Single;
    FInnerCoreBudget: Cardinal;
    { Slice markers of the custom inner core inside FParticleCPU, written
      by BuildMeshTargets (FInnerCoreCount = 0 while no core is emitted):
      UpdateInnerCoreTargets rewrites exactly this index range when scale
      or offset change, without touching the outer cloud. }
    FInnerCoreStartIdx: Integer;
    FInnerCoreCount: Integer;
    { Appearance split between the outer shell and the inner core: glow
      intensity, particle size, glow-kernel softness and rim falloff power.
      The inner set keeps the brain from over-glowing behind the eyes /
      forehead, independent of the shell's tuning. }
    FSoftness: Single;
    FRimPower: Single;
    FInnerGlow: Single;
    FInnerParticleSize: Single;
    FInnerSoftness: Single;
    FInnerRimPower: Single;
    { Offscreen buffer size. Mesh clouds are authored in control-sized world
      units (the loader scales them to Min(Width, Height) * 0.45), so the
      buffer tracks the control: FPendingBuf* carries the requested size,
      FBuf* is the size the GL objects were created with. The swap runs in
      RenderEffect, the only thread with the context current. Depth-map
      sources render through the fixed-resolution legacy pipeline and pin
      the buffer to the default CHAOS dims. }
    FBufW, FBufH: Integer;
    FPendingBufW, FPendingBufH: Integer;
    FBufResizePending: Boolean;
    { Interactive dragging: while DragMode is on, the control takes mouse
      input (click-through temporarily off) and the left button moves it
      inside the parent bounds. FDragStartMouse / FDragStartPos hold the
      grab anchor in parent coordinates. }
    FDragMode: Boolean;
    FDragging: Boolean;
    FDragStartMouse: TPointF;
    FDragStartPos: TPointF;
    FSavedClickThrough: Boolean;
    FHoloProgram: Cardinal;
    FLocH_DeltaTime, FLocH_Time, FLocH_Resolution: Integer;
    FLocH_ParticleCount, FLocH_State, FLocH_BuildScanY, FLocH_DespawnScanY: Integer;
    FLocH_LookX, FLocH_LookY, FLocH_PivotY: Integer;
    { Mouse touch-force uniforms: uMouseLocal is the cursor in buffer
      coordinates (-9999 = outside), uMouseVel its smoothed velocity in
      buffer pixels per second. uTouchEffectStyle selects which of the
      four touch effects the shader applies, uTouchEffectColor carries
      the accent colour (ColorFade target, Glow tint). }
    FLocH_MouseLocal, FLocH_MouseVel: Integer;
    FLocH_TouchEffectStyle: Integer;
    FLocH_TouchEffectColor: Integer;
    { Locations of the precomputed head-rotation trig endpoint uniforms
      (uTrigY / uTrigX, vec4 each). The CPU computes cos/sin once per frame;
      the shader mixes these endpoints per particle instead of evaluating
      four sin/cos calls inside project3D. }
    FLocH_TrigY, FLocH_TrigX: Integer;
    FLocP_TrigY, FLocP_TrigX: Integer;
    FLocH_HoloStyle, FLocH_ParticleSize, FLocH_GlowIntensity: Integer;
    FLocH_RimLightStrength, FLocH_Alpha, FLocH_Jitter: Integer;
    FLocH_FaceColor, FLocH_AccentColor: Integer;
    { Locations of the facial-animation uniforms: uMouthOpen drives the
      mouth-jaw deformation, uEyeOpeness the eye dim-blink; uHeadCenter /
      uHeadSize (vec4 each, .w unused) define the head-local coordinate
      frame the mouth mask is evaluated in. }
    FLocH_MouthOpen, FLocH_EyeOpeness, FLocH_HeadCenter, FLocH_HeadSize: Integer;
    { Location of uCustomInnerMesh: 1 while a custom inner-core mesh is
      loaded, 0 for the procedural inner layer. }
    FLocH_CustomInnerMesh: Integer;
    { Locations of the appearance uniforms: uSoftness / uRimPower drive the
      outer shell, uInnerAppearance packs the inner-core counterparts
      (x glow, y size, z softness, w rim power). }
    FLocH_Softness, FLocH_RimPower, FLocH_InnerAppearance: Integer;
    { Mesh / photo source data, kept for morph-target animation }
    FMeshResult: TMeshLoadResult;
    { Per-part tint overrides indexed by GroupTag (parallel to
      FMeshResult.MeshNames). $00000000 means "use the default style /
      face colour"; any other value tints every particle of that part via
      the $FE alpha marker the holo shader detects. }
    FPartColors: TArray<TAlphaColor>;
    FMeshBase: TArray<TMeshParticlePoint>;
    FMeshScale: Single;
    FMeshFlipY: Boolean;
    FMorphWeights: TArray<Single>;
    FActiveSequence: Integer;
    FAnimTime: Double;
    FAutoMeshFile: string;
    { ---- AI + voice pipeline state ----------------------------------------
      The avatar talks to any OpenAI-compatible endpoint through TYutaniAIClient
      and (optionally) runs the full microphone -> Vosk STT -> AI -> Piper TTS
      chain through TYutaniVoicePipeline. Both objects live on the main thread;
      the pipeline's own events marshal into it. }
    FAIClient: TYutaniAIClient;
    FVoicePipeline: TYutaniVoicePipeline;
    { Two INDEPENDENT voice toggles (one master switch was too coarse):
      TTS = ma_engine + PiperTTS only, STT = capture device + Vosk only.
      Both off keep the pipeline away entirely - pure text chat. }
    FVoiceTtsEnabled: Boolean;
    FVoiceSttEnabled: Boolean;
    { Deferred wiring: ActivatePendingVoice is called from the controls panel
      after the user saved model paths to the INI; it sets up the pipeline and
      wires its events. Kept public so the panel can call it explicitly. }
    FPendingVoiceActivation: Boolean;
    { Head-gesture spring targets: soft damped impulses on the head rotation
      driven by the AI action tags (nod / shake / tilt / think / alert). }
    FGestureVelX, FGestureVelY: Single;
    FGestureOffsetX, FGestureOffsetY: Single;
    { Human-readable voice status for the panel's live label:
      Idle / Listening / Thinking / Speaking / Fallback: <reason>. }
    FVoiceStatusText: string;
    { Last model paths a pipeline was actually built with (set by
      ActivatePendingVoice): re-activation with the SAME paths keeps the
      running pipeline, with changed paths tears it down and rebuilds. }
    FActiveVoskModelDir: string;
    FActivePiperVoice: string;
    { ---- Info / Debug live log ------------------------------------------------
      Ring-buffered, FDebugLogLock-guarded log lines the panel's Info / Debug
      tab shows. AppendDebugLog is called from the render thread (GPU init),
      the audio worker threads (Vosk / piper fallbacks) and the AI client's
      TThread.Queue handlers on the main thread, hence the lock. }
    FDebugLogLock: TObject;
    FDebugLog: TList<string>;
    FDebugLogSerial: Integer;
    { GPU detection snapshot (renderer, tier, VRAM, compute score) filled
      once by DetectGPUCapabilities right after InitOffscreenGL - the panel's
      Info / Debug tab shows GpuInfoText and offers GpuRecommendedParticles
      as the particle budget. }
    FGpuInfoText: string;
    FGpuRecommendedParticles: Integer;
    FGpuCaps: TGpuCapabilities;
    { 60-FPS lip-sync: FMouthAutoTarget is what CurrentAmplitude drives the
      mouth toward while the pipeline speaks; it eases back to the manual
      FMouthOpen rest value when the voice goes silent. }
    FMouthAutoTarget: Single;
    { AI / voice wiring handlers (main thread). }
    procedure HandleSpeechFinal(Sender: TObject; const AText: string; AIsFinal: Boolean);
    procedure HandleSpeechPartial(Sender: TObject; const AText: string; AIsFinal: Boolean);
    procedure HandleAIThinking(Sender: TObject);
    procedure HandleAIActionTag(Sender: TObject; const ATag: string);
    procedure HandleAIResponse(Sender: TObject; const ASpokenText: string);
    { Strips every bracketed action tag ([nod] ... [alert]) from anywhere in
      the text so the TTS never speaks them; ARemoved lists them for the log. }
    function StripActionTags(const AText: string; out ARemoved: string): string;
    procedure HandleAIError(Sender: TObject; const AErrorMsg: string);
    procedure HandleVoiceTtsStart(Sender: TObject; const AMsg: string);
    procedure HandleVoiceTtsEnd(Sender: TObject; const AMsg: string);
    procedure HandleVoiceError(Sender: TObject; const AMsg: string);
    procedure HandleVoiceFallback(Sender: TObject; const AMsg: string);
    { Builds the voice pipeline with the INI-saved model paths and wires every
      event. Missing Vosk / piper files degrade gracefully (STT off, SAPI
      fallback) - Setup only raises on a genuinely broken microphone. }
    procedure SetupVoicePipeline(const AVoskModelDir, APiperVoice: string);
    { Piper sidecar resolution: tokens.txt / espeak-ng-data / lexicon.txt
      beside the onnx, then beside its parent folder (nested voice layout). }
    procedure ResolvePiperSidecars(const AOnnxPath, AOnnxFolder: string;
      out ATokens, AEspeak, ALexicon: string);
    function FindFirstOnnxInFolder(const AFolder: string): string;
    { First .onnx directly in the folder or one subfolder level deeper. }
    function FindFirstOnnxNested(const AFolder: string): string;
    procedure UpdateLipSync(ADeltaTime: Double);
    procedure UpdateGestureSprings(ADeltaTime: Double);
    procedure ApplyHeadGesture(const ATag: string);
    { Split toggle setters: enabling either side activates the pending
      pipeline setup (the pipeline internally skips the capture device /
      engine per side), disabling stops feeding that side. }
    procedure SetVoiceTtsEnabled(const Value: Boolean);
    procedure SetVoiceSttEnabled(const Value: Boolean);
    procedure UploadTrigUniforms(ALocY, ALocX: Integer);
    procedure SetHoloStyle(const Value: THoloStyle);
    procedure SetStepFilter(const Value: Integer);
    procedure SetParticleSize(const Value: Single);
    procedure SetGlowIntensity(const Value: Single);
    procedure SetRimLightStrength(const Value: Single);
    procedure SetHoloAlpha(const Value: Single);
    procedure SetJitterAmount(const Value: Single);
    procedure SetSoftness(const Value: Single);
    procedure SetRimPower(const Value: Single);
    procedure SetInnerGlow(const Value: Single);
    procedure SetInnerParticleSize(const Value: Single);
    procedure SetInnerSoftness(const Value: Single);
    procedure SetInnerRimPower(const Value: Single);
    procedure SetInnerCore(const Value: Boolean);
    procedure SetInnerCoreScale(const Value: Single);
    procedure SetInnerCoreOffsetY(const Value: Single);
    { Instant retarget of the custom inner core after a scale / offset
      change: rewrites only the TX/TY/TZ of the core slice inside
      FParticleCPU under FDataLock and flags the SSBO dirty, so the live
      cloud morphs to the new placement without a rebuild and without
      restarting the forming animation. No-op unless a custom core mesh
      with points is active. }
    procedure UpdateInnerCoreTargets;
    procedure SetInnerCoreBudget(const Value: Cardinal);
    procedure SetParticleBudget(const Value: Cardinal);
    procedure SetNeckPivotRatio(const Value: Single);
    procedure SetMouseFollow(const Value: Boolean);
    procedure SetStayOnTop(const Value: Boolean);
    procedure SetClickThrough(const Value: Boolean);
    { Drag session management: enabling drag drops click-through and takes
      the saved value back on disable. }
    procedure SetDragMode(const Value: Boolean);
    { Keeps the control fully inside the parent client area so drags and
      resizes can never strand it half off-screen. }
    procedure ClampIntoParent(var X, Y: Single);
    { Interactive dragging: the left button moves the control by the cursor
      delta, measured in parent coordinates so it maps 1:1 onto Position
      regardless of DPI scaling. }
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Single); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single); override;
    { Applies a placement that was restored before this control had a
      parent; FMX fires this once Parent is finally assigned. }
    procedure ParentChanged; override;
    function FindOwnerForm: TForm;
    procedure ApplyStayOnTop;
    procedure BuildMeshTargets(const APoints: TArray<TMeshParticlePoint>);
    { Folds the head min/max fields into FHeadCenter / FHeadSize and clamps
      the size components to >= 1 so the shader's rel = (tgt - center) / size
      division can never blow up on a degenerate (flat) dimension. Called at
      the end of BuildMeshTargets and GenerateFaceTargets. }
    procedure FinalizeHeadBounds;
    procedure DispatchHoloFrame(ADeltaTime, ATime: Double);
    procedure ApplyHoloUniforms(ATime, ADeltaTime: Double);
    procedure AdvanceMorphAnimation(ADeltaTime: Double);
    procedure ApplyCurrentMorph;
    procedure UpdateTargetsFromMesh;
    function ProbeAutoAsset: string;
    function InitOffscreenGL: Boolean;
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
    procedure ReadbackToPixelBuffer;
    procedure ReinitParticlesForForming;           // NEW
    procedure SetMouthState(const Value: TMouthState);
    procedure SetEyeState(const Value: TEyeState);
    procedure SetEmotionMode(const Value: TEmotionMode);
    procedure SetBlinkDuration(const Value: Single);
    procedure SetNaturalBlinking(const Value: Boolean);
    procedure SetHighlightFollowMouse(const Value: Boolean);
    { UI-thread helper: re-show the control after the csFinished render
      sleep hid it. Called by every path that restarts the forming
      animation (Spawn, mesh / photo / depth-map loads, budget and
      rebuild paths). }
    procedure EnsureVisibleForSpawn;
  protected
    { UI thread only: re-caches FScreenOrigin / FControlW / FControlH
      from the live control geometry so the background render thread can
      convert cursor samples with plain arithmetic. Never call from
      RenderEffect - it runs on the render thread. }
    procedure RefreshScreenGeometry;
    { Send-to-monitor plumbing: RefreshDisplays re-reads the WinAPI
      monitor list into FDisplays; AddDisplay appends one entry (called
      by the ChaosEnumDisplaysProc callback through dwData = Self, which
      is safe because the callback only runs while RefreshDisplays is
      on the stack). }
    procedure RefreshDisplays;
    procedure AddDisplay(const AInfo: TMonitorInfoEx);
    procedure Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single); override;
    procedure RenderEffect(const ACanvas: ISkCanvas; const ADest: TRectF; const ATime: Double); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure LoadDepthMap(const AFileName: string);
    procedure LoadMeshFile(const AFileName: string; ATargetRadius: Single = 150.0; AStep: Integer = 1; AMaxParticles: Integer = 120000);
    procedure LoadPhotoFile(const AFileName: string; ATargetRadius: Single = 130.0; AStep: Integer = 2; AMaxParticles: Integer = 80000);
    procedure LoadHybrid(const AMeshFile, APhotoFile: string);
    { Re-applies the currently loaded source (mesh or photo) with the current
      StepFilter / ParticleBudget / MeshIncludeNames. Used by the controls
      panel so a per-part checkbox toggle or a budget change can re-load the
      same file the user picked without the panel needing to remember the
      path. No-op when no source file is loaded. }
    procedure ReloadCurrentSource;
    { Preset slot of the currently loaded mesh, under <ExeDir>\presets. The
      parent folder name joins the file base name so models that share
      generic file names (scene.glb, head.obj) never overwrite each
      other's presets. Empty while no mesh is loaded. }
    function GetAutoPresetPath: string;
    { True when APartName is the custom eye part: an exact (case-insensitive)
      match, or the picked name appears inside the part name, so a selection
      that only approximates the loaded mesh's naming (e.g. "Eyes" vs.
      "LeftEye_Mesh.001") still lands on the right part. A custom name of
      '' or '(Auto)' never matches - that keeps the automatic eye-name
      heuristic in charge. }
    function MatchesEyePartName(const APartName: string): Boolean;
    { Writes the complete avatar setup (mesh pair, style, animation pacing,
      overlay placement, per-part tints and visibility) to an ini file. }
    procedure SavePresetToFile(const AIniFile: string);
    { Reads a preset ini back onto the avatar. A different MeshFile entry
      loads that mesh first (with the preset's own filters); returns True
      when the file existed and was applied. }
    function LoadPresetFromFile(const AIniFile: string): Boolean;
    { Saves to the per-mesh automatic slot, so re-opening this head
      restores the setup on load. }
    procedure SaveCurrentMeshPreset;
    { Loads the preset last.ini points at, so a start continues the last
      session instead of the demo asset. Returns True when a preset was
      found and applied. }
    function LoadLastStartupPreset: Boolean;
    { True when a preset restored the overlay placement during startup,
      so the host form can skip its default corner positioning. }
    property StartupPresetLoaded: Boolean read FStartupPresetLoaded;
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
    { Rebuilds the particle cloud from the current source points (flags,
      colours and inner-core placement are baked per build) and restarts
      the forming animation, shared by the inner-core setters, loaders and
      the eye-part override in the controls panel. }
    procedure RebuildTargetCloud;
    { Per-part colour override for the loaded mesh. AIndex indexes MeshNames
      (the same order the controls panel's parts list shows). $00000000 clears
      the override and returns the part to the default style / face colour;
      any other colour tints the part live, without reloading the mesh. }
    procedure SetPartColor(AIndex: Integer; AColor: TAlphaColor);
    { Current override for a part, or $00000000 when the part uses the
      default style / face colour. }
    function GetPartColor(AIndex: Integer): TAlphaColor;
    { Per-part visibility, expressed through the manual include list: hiding
      removes the part's name, showing ensures it is present. The loader
      honours a non-empty list verbatim (auto-exclude bypassed), so this
      reconstructs any per-part setup exactly. Returns True when the list
      changed; visibility itself applies on the next mesh load. }
    function SetPartHidden(AIndex: Integer; AHidden: Boolean): Boolean;
    { True when a mesh name matches the loader's auto-exclude keywords,
      i.e. the part is not visible while the include list is empty. }
    function IsPartAutoExcluded(const AName: string): Boolean;
    { Shared folder for every preset file: <ExeDir>\presets. }
    function GetPresetsFolder: string;
    { Path of the startup index that remembers the most recently saved or
      loaded preset. }
    function GetLastPresetIndexPath: string;
    { Records a preset path as the most recent one so the next start
      restores it. }
    procedure UpdateLastPresetIndex(const AIniFile: string);
    { Loads a standalone .glb/.obj core / brain mesh that renders inside the
      head once InnerCore is on; $FE-marked tints from SetInnerPartColor (or
      the accent colour by default) make it stand out in every style. }
    procedure LoadInnerMeshFile(const AFileName: string);
    { Drops the custom core mesh so the inner layer falls back to the
      procedural inner head points while InnerCore stays on. }
    procedure ClearInnerMesh;
    { Per-part tint override for the custom inner mesh. AIndex indexes
      InnerMeshNames; $00000000 clears the override back to the accent
      colour. Rewrites the live core particles without a rebuild. }
    procedure SetInnerPartColor(AIndex: Integer; AColor: TAlphaColor);
    { Current inner-mesh part override, or $00000000 for the accent
      colour default. }
    function GetInnerPartColor(AIndex: Integer): TAlphaColor;
    { ---- AI & voice ---------------------------------------------------------
      On-demand AI client creation: configures BaseURL / Model / ApiKey /
      SystemPrompt from the given values ANY time it is called - also with
      both voice toggles off, so pure text chat works without any audio
      stack. The values the panel passes come straight from the AI & Voice
      tab. }
    procedure EnsureAIClient(const ABaseURL, AModel, AApiKey, ASystemPrompt: string);
    { Sends AText to the AI (works with or without voice). While the TTS
      toggle is active and the pipeline exists, the response speaks through
      the pipeline; otherwise the status returns to Idle after the
      gestures. }
    procedure AskAI(const AText: string);
    { Live voice / AI state for the panel's status label (Idle / Listening /
      Thinking / Speaking / Fallback: ...). }
    property VoiceStatusText: string read FVoiceStatusText;
    { ---- Info / Debug live log (panel's Info / Debug tab) ---------------
      Thread-safe append with a [HH:NN:SS] timestamp; the panel polls
      GetDebugLogText through its FPS timer and only re-reads when
      DebugLogSerial changed, so scrolling / marking inside the memo works
      undisturbed. KeepDebugLog may drop the buffer after copying. }
    procedure AppendDebugLog(const AMsg: string);
    function GetDebugLogText: string;
    { Empties the ring buffer (panel's Clear Log button); the serial bump
      tells the polling tab the next read is due. }
    procedure ClearDebugLog;
    { Monotonic line counter - bump on every append so the panel can detect
      "new text arrived" without comparing the whole blob. }
    property DebugLogSerial: Integer read FDebugLogSerial;
    { GPU detection snapshot filled once after InitOffscreenGL (the panel's
      GPU & SYSTEM INFO section reads it live). }
    property GpuInfoText: string read FGpuInfoText;
    { GPU-recommended particle budget (GpuInfoText's companion value);
      0 while no detection ran or the benchmark failed. }
    property GpuRecommendedParticles: Integer read FGpuRecommendedParticles;
    { Split toggles + pipeline access for the controls panel. }
    property VoiceTtsEnabled: Boolean read FVoiceTtsEnabled write SetVoiceTtsEnabled;
    property VoiceSttEnabled: Boolean read FVoiceSttEnabled write SetVoiceSttEnabled;
    property VoicePipeline: TYutaniVoicePipeline read FVoicePipeline;
    property AIClient: TYutaniAIClient read FAIClient;
    { Explicit pipeline activation entry point for the panel: sets the
      pending flag and immediately tries SetupVoicePipeline with the given
      model paths (empty strings fall back to what the INI last stored),
      so toggling the master switch takes effect without an app restart.
      Public because uControls drives it from the AI & Voice tab. }
    procedure ActivatePendingVoice(const AVoskModelDir: string = ''; const APiperVoice: string = '');
    { Makes the avatar say something through the piper/SAPI voice; no-op
      while no pipeline exists. }
    procedure SpeakVoice(const AText: string);
    property State: TChaosState read FState;
    property MouthState: TMouthState read FMouthState write SetMouthState;
    property EyeState: TEyeState read FEyeState write SetEyeState;
    property FaceColor: TAlphaColor read FFaceColor write FFaceColor;
    property EyeColor: TAlphaColor read FEyeColor write FEyeColor;
    property MouthColor: TAlphaColor read FMouthColor write FMouthColor;
    property AccentColor: TAlphaColor read FAccentColor write FAccentColor;
    property MouthOpen: Single read FMouthOpen write FMouthOpen;
    property EyeOpeness: Single read FEyeOpeness write FEyeOpeness;
    { Procedural auto-blink on top of the manual EyeOpeness state; the blink
      factor multiplies FEyeOpeness, so both stay controllable. }
    property AutoBlink: Boolean read FAutoBlink write FAutoBlink default True;
    { Natural blinking (rename of the legacy AutoBlink flag, same
      semantics): False pins the eyes open and skips the blink timer. }
    property NaturalBlinking: Boolean read FAutoBlink write SetNaturalBlinking default True;
    { Touch effects (soft force field / glow / colour fade / ripple in
      the holo shader), default on. Renamed from MouseForceField - the
      toggle now gates all four TChaosTouchEffectStyle variants. }
    property TouchEffectsEnabled: Boolean read FTouchEffectsEnabled write FTouchEffectsEnabled default True;
    { Which touch effect runs while the cursor is over the control. }
    property TouchEffectStyle: TChaosTouchEffectStyle read FTouchEffectStyle write FTouchEffectStyle default tesForcefield;
    { Accent colour of the ColorFade / Glow touch effects. }
    property TouchEffectColor: TAlphaColor read FTouchEffectColor write FTouchEffectColor;
    { Idle breathing drift + micro-saccades while the cursor rests. }
    property IdleLifeMotion: Boolean read FIdleLifeMotion write FIdleLifeMotion default True;
    { Auto-blink timing: blink length in seconds (default 0.38), inside
      the natural 100-400 ms range of human reflex blinking. The pause
      rhythm is fully automatic (see FNextBlinkDelay). }
    property BlinkDuration: Single read FBlinkDuration write SetBlinkDuration;
    property EmotionMode: TEmotionMode read FEmotionMode write SetEmotionMode;
    property HighlightActive: Boolean read FHighlightActive write FHighlightActive;
    { Alive-highlighter overlay control: send the entity to a screen point
      or rectangle (it flies there and orbits), or dismiss it with its exit
      animation. The entity itself is drawn by a full-desktop overlay
      control through RenderHighlighterOverlay, tinted with AccentColor. }
    procedure HighlightPoint(AX, AY: Single);
    procedure HighlightRect(const ARect: TRectF);
    procedure DismissHighlight;
    { True while the alive highlighter entity is on (or leaving) the
      desktop: a full-screen overlay control uses this to skip its render
      loop work entirely when there is nothing to draw. }
    function HighlighterBusy: Boolean;
    { Publishes the highlighter's wall model to the full-desktop overlay
      control: bounds mirror the overlay's client size (the whole screen),
      not this avatar control's small rect, so the entity can travel
      across the entire desktop instead of being clipped to the avatar. }
    procedure SetHighlighterBounds(AWidth, AHeight: Single);
    { Advances mouse-follow (cursor already converted into the overlay's
      coordinate frame by the caller), steps the entity's logic and draws
      it onto the overlay canvas. Runs on the overlay's render thread with
      that frame's delta time; call every frame while HighlighterBusy (or
      HighlightFollowMouse) is True. }
    procedure RenderHighlighterOverlay(const ACanvas: ISkCanvas; ADeltaTime: Single; AMouseX, AMouseY: Single; AHasMouse: Boolean);
    { Union of the highlighter entity's current and previous footprint,
      clamped to the screen bounds - lets the overlay host clip its
      canvas so only the ~entity-sized region is rasterized instead of
      the entire desktop. Empty rect while the entity is idle. }
    function HighlighterDirtyRect: TRect;
    property ParticleBudget: Cardinal read FParticleBudget write SetParticleBudget;
    { Switchable visual style and live tuning knobs. }
    property HoloStyle: THoloStyle read FHoloStyle write SetHoloStyle;
    property SourceType: TChaosSource read FSourceType;
    property StepFilter: Integer read FStepFilter write SetStepFilter;
    property ParticleSize: Single read FParticleSize write SetParticleSize;
    property GlowIntensity: Single read FGlowIntensity write SetGlowIntensity;
    property RimLightStrength: Single read FRimLightStrength write SetRimLightStrength;
    property HoloAlpha: Single read FHoloAlpha write SetHoloAlpha;
    property JitterAmount: Single read FJitterAmount write SetJitterAmount;
    { Outer-shell appearance: softness widens the glow-kernel falloff and
      rim power sharpens the rim edge highlight (2.0 reproduces the default
      squared falloff). }
    property Softness: Single read FSoftness write SetSoftness;
    property RimPower: Single read FRimPower write SetRimPower;
    { Inner-core appearance: the brain keeps its own glow, particle size,
      softness and rim power so it never over-glows behind the eyes /
      forehead, whatever the shell's tuning. }
    property InnerGlow: Single read FInnerGlow write SetInnerGlow;
    property InnerParticleSize: Single read FInnerParticleSize write SetInnerParticleSize;
    property InnerSoftness: Single read FInnerSoftness write SetInnerSoftness;
    property InnerRimPower: Single read FInnerRimPower write SetInnerRimPower;
    { Toggles the inner brain-core layer: with a custom inner mesh loaded
      its points form the layer, otherwise every third head particle
      (~33%) becomes a procedural inner core. Off by default for a clean
      shell surface. }
    property InnerCore: Boolean read FInnerCore write SetInnerCore default False;
    { Custom core mesh placement and density. Scale shrinks the loaded
      points around the head centre, OffsetY shifts them vertically so a
      brain sits inside the cranium, Budget caps how many core points are
      emitted. Each change rebuilds the combined cloud. }
    property InnerCoreScale: Single read FInnerCoreScale write SetInnerCoreScale;
    property InnerCoreOffsetY: Single read FInnerCoreOffsetY write SetInnerCoreOffsetY;
    property InnerCoreBudget: Cardinal read FInnerCoreBudget write SetInnerCoreBudget;
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
    { Interactive dragging: the left button moves the avatar inside its
      parent. Enabling temporarily drops click-through so the control
      actually receives mouse input; disabling restores it. }
    property DragMode: Boolean read FDragMode write SetDragMode default False;
    { Live resizing: keeps the default 252 / 236 aspect, anchors the bottom
      centre inside the parent and, for mesh sources, re-fits the particle
      clouds and the offscreen buffer to the new size. }
    procedure SetAvatarSize(AWidth: Single);
    { ---- Send to Monitor ------------------------------------------------
      DisplayCount / DisplayInfo enumerate the currently attached
      monitors (list refreshed on every call, hot-plug safe): Index
      0..Count-1, physical pixel Bounds, Primary flag. CurrentDisplayIndex
      returns the index whose bounds contain the host window's centre
      right now, or -1 when it sits on no attached monitor.
      SendToDisplay snaps the host window onto the target monitor's full
      BoundsRect in a per-monitor-DPI-safe order: pure position move
      first (WM_DPICHANGED arrives while the old size is still valid),
      then the exact target width / height, then a geometry refresh +
      repaint so the render buffer and the cursor conversion follow
      immediately. }
    function DisplayCount: Integer;
    function DisplayInfo(AIndex: Integer): TChaosDisplayInfo;
    function CurrentDisplayIndex: Integer;
    procedure SendToDisplay(AIndex: Integer);
    property AutoMeshFile: string read FAutoMeshFile;
    { Per-part include filter. Pass the mesh-name keywords (e.g. ['head','torso','arm_l','leg_l'])
      to load only those parts on the next LoadMeshFile call; pass nil to clear
      the filter and load every surviving part. The controls panel toggles this
      live and reloads the current mesh so the user sees the result immediately. }
    property MeshIncludeNames: TArray<string> read FMeshIncludeNames write FMeshIncludeNames;
    { Names of every mesh/group the most recent mesh load saw - exposed so the
      controls panel can build the per-part checkbox list after a mesh loads
      without having to re-parse the file itself. Returns the same list the
      MeshLoader wrote to FMeshResult.MeshNames. Empty for photo/depth sources. }
    property MeshNames: TArray<string> read FMeshResult.MeshNames;
    { Names of the groups inside the custom inner core mesh, in the order the
      loader wrote them - drives the per-part colour list of the Inner Core
      tab. Empty while no core mesh is loaded. }
    property InnerMeshNames: TArray<string> read FInnerMeshResult.MeshNames;
    { Forces the mesh part with this exact name to carry PARTICLE_FLAG_EYE,
      overriding the automatic eye-name heuristic in BuildMeshTargets. Set to
      '' or '(Auto)' to return to the automatic detection; changes apply on
      the next rebuild of the particle cloud. }
    property CustomEyePartName: string read FCustomEyePartName write FCustomEyePartName;
    { Alive highlighter: when True, the full-desktop overlay converts the
      live cursor position into its own frame every frame and keeps the
      highlighter stalking it, without re-triggering the spawn so the tail
      stays fluid. }
    property HighlightFollowMouse: Boolean read FHighlightFollowMouse write SetHighlightFollowMouse;
    { UI hook for the full-desktop overlay host: fires on the UI thread
      whenever the highlighter is activated (highlight send or follow
      toggle), letting the host un-hide its sleeping control at once. }
    property OnHighlighterWake: TNotifyEvent read FOnHighlighterWake write FOnHighlighterWake;
    { Auto-dim on mouseover: eases the avatar's alpha multiplier toward
      AUTO_DIM_ALPHA while the cursor is over the control's screen rect and
      back to full when it leaves. Works through GetCursorPos, so it also
      fires while the window is click-through (WS_EX_TRANSPARENT). }
    property AutoDimOnHover: Boolean read FAutoDimOnHover write FAutoDimOnHover;
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
    'uniform float uDeltaTime;'#10 + 'uniform float uTime;'#10 + 'uniform vec2  uResolution;'#10 + 'uniform uint  uParticleCount;'#10 + 'uniform float uBuildScanY;'#10 + 'uniform float uDespawnScanY;'#10 + 'uniform int   uState;'#10 + 'uniform float uChaosLevel;'#10 + 'uniform float uMouthOpen;'#10 + 'uniform float uEyeOpeness;'#10 + 'uniform float uLookX;'#10 + 'uniform float uLookY;'#10 + 'uniform float uPivotY;'#10 + 'uniform int   uEmotionMode;'#10 + 'uniform vec4  uFaceColor;'#10 + 'uniform vec4  uEyeColor;'#10 + 'uniform vec4  uMouthColor;'#10 + 'uniform vec4  uAccentColor;'#10 +
    // uTrigY/uTrigX: cos/sin of the neck-pivot rotation at the smoothstep
    // weight endpoints (head w=1, shoulders w=0) - precomputed on the CPU so
    // project3D costs zero trig per particle.
    'uniform vec4  uTrigY;'#10 + 'uniform vec4  uTrigX;'#10 + ''#10 +
    // project3D - rotate the head around the neck pivot (uPivotY) toward the
    // cursor with mild perspective; smoothstep fades rotation below the pivot
    // so the shoulders stay still.
    'vec2 project3D(vec3 p) {'#10 + '  float pivotY = uPivotY;'#10 + '  float w = (uPivotY <= -9000.0) ? 1.0 : (1.0 - smoothstep(pivotY - 14.0, pivotY + 18.0, p.y));'#10 + '  if (uPivotY <= -9000.0) pivotY = 0.0;'#10 + '  float cy = mix(uTrigY.z, uTrigY.x, w);'#10 + '  float sy = mix(uTrigY.w, uTrigY.y, w);'#10 + '  float cx = mix(1.0, uTrigX.x, w);'#10 + '  float sx = mix(0.0, uTrigX.y, w);'#10 + '  float py = p.y - pivotY;'#10 + '  float x1 = p.x * cy - p.z * sy;'#10 + '  float z1 = p.x * sy + p.z * cy;'#10 + '  float y1 = py * cx - z1 * sx;'#10 + '  float z2 = py * sx + z1 * cx;'#10 + '  float persp = 1.0 + (z2 * 0.0022);'#10 + '  return vec2(x1 * persp, (y1 + pivotY) * persp + 15.0);'#10 + '}'#10 + ''#10 +
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
    '  float rawDepth = clamp(pos.z / 110.0, 0.0, 1.0);'#10 + '  float depth = rawDepth * rawDepth;'#10 + '  float radialFade = clamp(1.0 - length(pos.xy) * 0.0045, 0.35, 1.0);'#10 + ''#10 + '  vec4 col;'#10 + '  float typeBoost = 1.0;'#10 + '  float coreRadius = mix(0.75, 1.35, depth);'#10 + '  float glowRadius = mix(2.2, 3.8, depth);'#10 + ''#10 +
    // Per-type color and glow sizing: eyes and mouth smaller and brighter than face.
    '  if (flags == 2u || flags == 3u) {'#10 + '    col = uEyeColor;'#10 + '    typeBoost = 0.90;'#10 + '    depth = 0.78;'#10 + '    coreRadius = 0.95;'#10 + '    glowRadius = 2.8;'#10 + '  } else if (flags == 4u) {'#10 + '    col = uMouthColor;'#10 + '    typeBoost = 0.90;'#10 + '    depth = 0.75;'#10 + '    coreRadius = 0.90;'#10 + '    glowRadius = 2.6;'#10 + '  } else {'#10 + '    col = uFaceColor;'#10 + '    typeBoost = 1.0;'#10 + '  }'#10 + ''#10 +
    // Flicker and base intensity; fade out smoothly while falling so nothing is cut off.
    '  float flick = 0.90 + 0.10 * sin(uTime * 14.0 + float(idx) * 1.31);'#10 + '  float baseIntensity = mix(0.14, 1.05, depth) * radialFade * flick * typeBoost;'#10 + '  if (falling) baseIntensity *= clamp(1.0 - (pos.y - 60.0) / 90.0, 0.0, 1.0);'#10 + ''#10 +
    // Splat a core+glow kernel into uOutput with premultiplied-alpha compositing.
    '  float coreR2 = coreRadius * coreRadius;'#10 + '  float glowR2 = glowRadius * glowRadius;'#10 + '  float glowDenom = glowR2 * 0.4;'#10 + '  for (int dy = -4; dy <= 4; ++dy) {'#10 + '    for (int dx = -4; dx <= 4; ++dx) {'#10 + '      ivec2 px = basePx + ivec2(dx, dy);'#10 + '      if (px.x < 0 || px.x >= resX || px.y < 0 || px.y >= resY) continue;'#10 + '      vec2 d2v = vec2(px) + 0.5 - center;'#10 + '      float dist2 = dot(d2v, d2v);'#10 + '      if (dist2 > glowR2) continue;'#10 +
    '      float core = exp(-dist2 / coreR2);'#10 + '      float glow = exp(-dist2 / glowDenom) * 0.35;'#10 + '      float a = clamp((core + glow) * baseIntensity, 0.0, 1.0);'#10 + '      if (a <= 0.004) continue;'#10 + '      // Strict premultiplied alpha (rgb <= a) for clean desktop transparency'#10 + '      vec4 src = vec4(col.rgb * a, a);'#10 + '      vec4 dst = imageLoad(uOutput, px);'#10 + '      float outA = clamp(max(dst.a, src.a) + min(dst.a, src.a) * 0.25, 0.0, 1.0);'#10 + '      vec3 outRGB = clamp(max(dst.rgb, src.rgb) + min(dst.rgb, src.rgb) * 0.25, 0.0, outA);'#10 + '      imageStore(uOutput, px, vec4(outRGB, outA));'#10 + '    }'#10 + '  }'#10 + '}';
  CLEAR_SRC: AnsiString =
    // CLEAR_SRC - zero out uOutput (one 16x16 tile per invocation).
    '#version 430 core'#10 + 'layout(local_size_x = 16, local_size_y = 16) in;'#10 + 'layout(rgba8, binding = 0) writeonly uniform image2D uOutput;'#10 + 'uniform vec2 uResolution;'#10 + 'void main() {'#10 + '  ivec2 px = ivec2(gl_GlobalInvocationID.xy);'#10 + '  if (px.x >= int(uResolution.x) || px.y >= int(uResolution.y)) return;'#10 + '  imageStore(uOutput, px, vec4(0.0));'#10 + '}';
  HOLO_PARTICLE_SRC: AnsiString =
    // GLSL 4.30 compute shader - holo-style renderer, one work item per particle.
    '#version 430 core'#10 + 'layout(local_size_x = 256) in;'#10 +
    // Particle pool in a std430 SSBO; uOutput is the RGBA8 splat target.
    'struct Particle {'#10 + '  float px, py, pz;'#10 + '  float vx, vy, vz;'#10 + '  float tx, ty, tz;'#10 + '  uint  color;'#10 + '  uint  flags;'#10 + '  uint  pad0, pad1;'#10 + '};'#10 + 'layout(std430, binding = 0) buffer SSBO { Particle P[]; };'#10 + 'layout(rgba8, binding = 0) coherent uniform image2D uOutput;'#10 + ''#10 +
    // CPU uniforms: timing, resolution, state machine, look/pivot, style, palette.
    'uniform float uDeltaTime;'#10 + 'uniform float uTime;'#10 + 'uniform vec2  uResolution;'#10 + 'uniform uint  uParticleCount;'#10 + 'uniform int   uState;'#10 + 'uniform float uBuildScanY;'#10 + 'uniform float uDespawnScanY;'#10 + 'uniform float uLookX;'#10 + 'uniform float uLookY;'#10 + 'uniform float uPivotY;'#10 + 'uniform int   uHoloStyle;'#10 + 'uniform float uParticleSize;'#10 + 'uniform float uGlowIntensity;'#10 + 'uniform float uRimLightStrength;'#10 + 'uniform float uAlpha;'#10 + 'uniform float uJitter;'#10 + 'uniform vec4  uFaceColor;'#10 + 'uniform vec4  uAccentColor;'#10 +
    // Touch force field: uMouseLocal is the cursor in buffer coordinates,
    // (-9999, -9999) while it is outside the control so the radius test
    // below never fires; uMouseVel is its smoothed velocity in buffer
    // pixels per second, driving the carry-along swirl.
    'uniform vec2  uMouseLocal;'#10 + 'uniform vec2  uMouseVel;'#10 +
    // Touch effect selection + accent colour: uTouchEffectStyle picks the
    // variant applied inside the cursor's smoothstep influence radius
    // (0 = Forcefield, 1 = Glow, 2 = ColorFade, 3 = Ripple);
    // uTouchEffectColor is the ColorFade blend target / Glow tint.
    'uniform int   uTouchEffectStyle;'#10 + 'uniform vec3  uTouchEffectColor;'#10 + ''#10 +
    // uTrigY/uTrigX: cos/sin of the neck-pivot rotation at the smoothstep
    // weight endpoints (head w=1, shoulders w=0) - precomputed on the CPU so
    // project3D costs zero trig per particle.
    'uniform vec4  uTrigY;'#10 + 'uniform vec4  uTrigX;'#10 + ''#10 +
    // Facial animation: uMouthOpen drives the jaw deformation and
    // uEyeOpeness the eye dim-blink, both evaluated in the head-local
    // coordinate frame (center + size, .w unused). uCustomInnerMesh is 1
    // while a custom inner-core mesh is loaded - its points already carry
    // the exact scale / offset placement, so only the procedural fallback
    // layer shrinks toward the head centre.
    'uniform float uMouthOpen;'#10 + 'uniform float uEyeOpeness;'#10 + 'uniform vec4  uHeadCenter;'#10 + 'uniform vec4  uHeadSize;'#10 + 'uniform int   uCustomInnerMesh;'#10 + ''#10 +
    // Appearance uniforms: uSoftness widens the glow-kernel falloff and
    // uRimPower sharpens the rim edge highlight for the outer shell;
    // uInnerAppearance packs the inner-core counterparts (x glow, y size,
    // z softness, w rim power) so the brain keeps its own look.
    'uniform float uSoftness;'#10 + 'uniform float uRimPower;'#10 + 'uniform vec4  uInnerAppearance;'#10 + ''#10 +
    // project3D - rotate the head around the neck pivot (uPivotY) toward the
    // cursor with mild perspective; smoothstep fades rotation below the pivot.
    'vec2 project3D(vec3 p) {'#10 + '  float pivotY = uPivotY;'#10 + '  float w = (uPivotY <= -9000.0) ? 1.0 : (1.0 - smoothstep(pivotY - 14.0, pivotY + 18.0, p.y));'#10 + '  if (uPivotY <= -9000.0) pivotY = 0.0;'#10 + '  float cy = mix(uTrigY.z, uTrigY.x, w);'#10 + '  float sy = mix(uTrigY.w, uTrigY.y, w);'#10 + '  float cx = mix(1.0, uTrigX.x, w);'#10 + '  float sx = mix(0.0, uTrigX.y, w);'#10 + '  float py = p.y - pivotY;'#10 + '  float x1 = p.x * cy - p.z * sy;'#10 + '  float z1 = p.x * sy + p.z * cy;'#10 + '  float y1 = py * cx - z1 * sx;'#10 + '  float z2 = py * sx + z1 * cx;'#10 + '  float persp = 1.0 + (z2 * 0.0022);'#10 + '  return vec2(x1 * persp, (y1 + pivotY) * persp + 15.0);'#10 + '}'#10 +
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
    '  if (uState == 3) return;'#10 + '  uint idx = gl_GlobalInvocationID.y * (gl_NumWorkGroups.x * 256u) + gl_GlobalInvocationID.x;'#10 + '  if (idx >= uParticleCount) return;'#10 + '  float dt = clamp(uDeltaTime, 0.0, 0.033);'#10 + '  uint flags = P[idx].flags;'#10 + '  uint region = flags & 0xFu;'#10 + '  bool innerCore = (flags & 0x100u) != 0u;'#10 + '  bool isEye = (flags & 0x200u) != 0u;'#10 + ''#10 + '  vec3 pos = vec3(P[idx].px, P[idx].py, P[idx].pz);'#10 + '  vec3 vel = vec3(P[idx].vx, P[idx].vy, P[idx].vz);'#10 + '  vec3 tgt = vec3(P[idx].tx, P[idx].ty, P[idx].tz);'#10 +
    // Inner brain-core particles sit closer to the center of the head.
    // Facial deformation (region 1 = head, front side only so the back of
    // the head never moves): normalized face coords rel = (tgt - center) /
    // size; +Y points down and +Z toward the viewer, so y: -0.5 = crown,
    // +0.5 = chin; x: 0 = nose axis.
    // Mouth: a true lip split at rel.y ~ 0.21. The upper lip stays put and
    // lifts only a hair, while the lower lip and chin rotate down and back
    // around a hinge behind the upper lip, so the lips genuinely part
    // instead of the whole chin shifting down. rel / mouthSlit stay zero
    // outside the front head so the speech glow after the block is inert
    // for other regions. Eye particles are never displaced geometrically -
    // the blink dims PARTICLE_FLAG_EYE particles further below instead.
    '  vec3 rel = vec3(0.0);'#10 + '  float mouthSlit = 0.0;'#10 + '  if (region == 1u && tgt.z > uHeadCenter.z) {'#10 + '    rel = (tgt - uHeadCenter.xyz) / uHeadSize.xyz;'#10 + '    float upperLipMask = smoothstep(0.15, 0.19, rel.y) * (1.0 - smoothstep(0.20, 0.215, rel.y)) * (1.0 - smoothstep(0.18, 0.22, abs(rel.x)));'#10 + '    tgt.y -= uMouthOpen * 0.008 * uHeadSize.y * upperLipMask;'#10 + '    float lowerLipMask = smoothstep(0.202, 0.225, rel.y) * (1.0 - smoothstep(0.24, 0.40, abs(rel.x)));'#10 +
    '    float chinMask = smoothstep(0.225, 0.34, rel.y) * (1.0 - smoothstep(0.32, 0.50, abs(rel.x)));'#10 + '    float jawWeight = max(lowerLipMask, chinMask * 0.75);'#10 + '    vec3 jawPivot = vec3(uHeadCenter.x, uHeadCenter.y + 0.05 * uHeadSize.y, uHeadCenter.z - 0.18 * uHeadSize.z);'#10 + '    float jawAngle = uMouthOpen * 0.11 * jawWeight;'#10 + '    vec3 dj = tgt - jawPivot;'#10 + '    float ca = cos(jawAngle);'#10 + '    float sa = sin(jawAngle);'#10 +
    '    tgt.y = jawPivot.y + dj.y * ca + dj.z * sa;'#10 + '    tgt.z = jawPivot.z - dj.y * sa + dj.z * ca;'#10 + '    tgt.x -= (tgt.x - uHeadCenter.x) * uMouthOpen * 0.10 * lowerLipMask;'#10 + '    mouthSlit = smoothstep(0.16, 0.205, rel.y) * (1.0 - smoothstep(0.215, 0.26, rel.y)) * (1.0 - smoothstep(0.12, 0.21, abs(rel.x)));'#10 + '  }'#10 + ''#10 +
    // Speech energy: while the mouth is open, a multi-frequency voice wave
    // (two beating sines with spatial phase from rel.x) runs across the
    // parting lips, giving a holographic voice-modulation glow in the
    // aperture between upper and lower lip.
    '  float speech = 0.0;'#10 + '  if (uMouthOpen > 0.02)'#10 + '    speech = mouthSlit * uMouthOpen * (0.5 + 0.5 * sin(uTime * 34.0 + rel.x * 26.0) * cos(uTime * 19.0 - rel.x * 14.0));'#10 + ''#10 +
    // Procedural inner-core points hug the head centre (0.55 shrink); a
    // custom core mesh keeps its own scale / offset placement.
    '  if (innerCore && uCustomInnerMesh == 0) tgt *= 0.55;'#10 + ''#10 + '  bool visible = true;'#10 + '  bool falling = false;'#10 +
    // Single shared projection: p2 / center are computed exactly once per
    // particle. Falling particles project after their gravity step; visible
    // particles before the spring integration, so the same screen
    // coordinates drive the mouse touch force below AND the pixel splat
    // further down - the second project3D call is gone.
    '  vec2 p2 = vec2(0.0);'#10 + '  vec2 center = vec2(0.0);'#10 +
    // Touch effect state shared by the style dispatch in the spring
    // branch below and the colour / glow consumers in the splat section
    // further down - hence declared here in main()'s scope, not inside
    // the branch. touchInfluence is the butter-smooth
    // smoothstep(radius, 0.0, dist) envelope around the cursor;
    // touchDist / touchDir its raw distance and direction;
    // touchGlow / touchRippleGlow the per-style brightness additions.
    // All-zero (cursor outside, uMouseLocal parked at -9999, or falling
    // particles) is exactly neutral: every consumer reads 0.
    '  float touchInfluence = 0.0;'#10 + '  float touchDist = 0.0;'#10 + '  vec2  touchDir = vec2(0.0, 1.0);'#10 +
    '  float touchGlow = 0.0;'#10 + '  float touchRippleGlow = 0.0;'#10 +
    // State machine: 0 = forming (reveal up to build scanline), 2 = fading (drop below despawn scanline).
    '  if (uState == 0) { if (tgt.y > uBuildScanY) visible = false; } else if (uState == 2) { if (pos.y <= uDespawnScanY) { if (vel.y < 1.0) vel.y = 240.0 + 140.0 * rand(float(idx)); falling = true; } }'#10 +
    // Falling: gravity carries the particle down and out of the viewport.
    '  if (falling) {'#10 + '    vel.y += 700.0 * dt;'#10 + '    pos += vel * dt;'#10 + '    p2 = project3D(pos);'#10 + '    center = toScreenFloat(p2);'#10 +
    // Otherwise spring toward target; add hover drift and per-style jitter.
    '  } else if (visible) {'#10 + '    vec3 d = tgt - pos;'#10 + '    float stiff = 220.0;'#10 + '    float damp = 18.0;'#10 +
    // Touch effects: while the cursor is over the control, the shared
    // influence falloff (smoothstep over the 58 px touch radius) drives
    // the selected uTouchEffectStyle variant - Forcefield keeps the
    // original strong, soft radial push plus carry-along, Z-dent and
    // locally yielding spring; Glow / ColorFade stay purely visual (see
    // the splat section); Ripple runs a soft harmonic sine wave. The
    // shared projection above (p2 / center) doubles as the screen-space
    // position; once the cursor moves on, everything eases organically
    // back into the face.
    '    p2 = project3D(pos);'#10 + '    center = toScreenFloat(p2);'#10 +
    // Touch effects: the shared screen-space distance to the cursor and
    // its butter-smooth influence falloff (smoothstep over the 58 px
    // touch radius) drive every style variant below. touchInfluence /
    // touchDist / touchDir stay at their neutral defaults (0 influence)
    // whenever the cursor is outside the control, so the colour / glow
    // consumers further down read exactly 0 and cost nothing.
    '    if (uState <= 1) {'#10 + '      if (uMouseLocal.x > -9000.0) {'#10 + '        vec2 diff = center - uMouseLocal;'#10 + '        float dist = length(diff);'#10 + '        float radius = 58.0;'#10 + '        if (dist > 0.001) {'#10 + '          touchInfluence = smoothstep(radius, 0.0, dist);'#10 + '          if (touchInfluence > 0.0) {'#10 + '            touchDist = dist;'#10 + '            touchDir = diff / dist;'#10 +
    // Style 0 (Forcefield): the original behaviour kept exactly as it
    // was - particles within the radius are softly pushed away from the
    // cursor, carried along by its velocity and dented in Z, with the
    // return spring locally yielding so the cloud genuinely gives way.
    // The max() clamp on the pow() base only guards the float rounding
    // edge at dist == radius; inside this branch dist < radius already
    // holds because the smoothstep envelope above is > 0.
    '            if (uTouchEffectStyle == 0) {'#10 + '              float falloff = pow(max(1.0 - dist / radius, 0.0), 1.5);'#10 + '              stiff *= (1.0 - 0.88 * falloff);'#10 + '              damp *= (1.0 - 0.55 * falloff);'#10 + '              vel.xy += touchDir * falloff * 1800.0 * dt;'#10 + '              vel.xy += uMouseVel * falloff * 3.5 * dt;'#10 + '              vel.z += falloff * 320.0 * dt;'#10 +
    // Style 3 (Ripple): a tuned harmonic sine wave around the cursor -
    // wider rings (freq 0.26), faster phase (7.5 rad/s) - displaces the
    // cloud clearly but stays a wave, never a push: the impulses are
    // purely harmonic, and the spring itself yields softly inside the
    // influence (stiff -65 %, damp -35 % at the centre) so the rings
    // travel through the cloud instead of fighting the return spring.
    // touchRippleGlow rides the same wave for the brightness shimmer
    // in the splat section below.
    '            } else if (uTouchEffectStyle == 3) {'#10 + '              float wave = sin(dist * 0.26 - uTime * 7.5);'#10 + '              float ring = wave * touchInfluence;'#10 + '              stiff *= (1.0 - 0.65 * touchInfluence);'#10 + '              damp  *= (1.0 - 0.35 * touchInfluence);'#10 + '              vel.xy += touchDir * ring * 1150.0 * dt;'#10 + '              vel.z  += ring * 850.0 * dt;'#10 + '              touchRippleGlow = (0.5 + 0.5 * wave) * touchInfluence;'#10 + '            }'#10 + '          }'#10 +
    // Styles 1 (Glow) and 2 (ColorFade) deliberately leave position and
    // velocity untouched - no displacement at all; they act purely on
    // brightness / colour in the splat section below via
    // touchInfluence / touchGlow, which fade smoothly back to neutral
    // as the cursor moves away.
    '        }'#10 + '      }'#10 + '    }'#10 + '    touchGlow = (uTouchEffectStyle == 1) ? touchInfluence : 0.0;'#10 +
    '    vel += (d * stiff - vel * damp) * dt;'#10 + '    pos += vel * dt;'#10 + '    if (uState == 1) {'#10 + '      vec3 hover = vec3(sin(uTime * 1.3 + float(idx) * 0.37),'#10 + '                        cos(uTime * 1.1 + float(idx) * 0.53), 0.0) * 0.4;'#10 + '      pos += hover * dt;'#10 + '    }'#10 + '    pos += vec3(rand(float(idx) + uTime) - 0.5,'#10 +
    '                rand(float(idx) * 1.7 + uTime) - 0.5,'#10 + '                rand(float(idx) * 2.3 + uTime) - 0.5) * uJitter;'#10 + '    if (uHoloStyle == 2) {'#10 + '      pos += vec3(rand(float(idx) * 0.5 + uTime * 0.7) - 0.5,'#10 + '                  rand(float(idx) * 0.9 + uTime * 0.5) - 0.5, 0.0) * 0.9;'#10 + '    }'#10 + '  }'#10 +
    // Write back position and velocity.
    '  P[idx].px = pos.x; P[idx].py = pos.y; P[idx].pz = pos.z;'#10 + '  P[idx].vx = vel.x; P[idx].vy = vel.y; P[idx].vz = vel.z;'#10 + '  if (!visible) return;'#10 + ''#10 +
    // Project to screen and cull particles outside the viewport.
    '  vec3 normal = decodeNormal(P[idx].pad0, P[idx].pad1);'#10 +
    // Project to screen and cull particles outside the viewport. p2/center
    // were already computed above (before the spring for visible
    // particles, after the gravity step for falling ones) - no second
    // project3D call. Eye particles no longer shift separately: they
    // rotate rigidly with the head, so isEye now only drives the
    // dim-blink below.
    '  ivec2 basePx = ivec2(round(center));'#10 + '  int resX = int(uResolution.x);'#10 + '  int resY = int(uResolution.y);'#10 + '  if (basePx.x < -9 || basePx.x >= resX + 9 ||'#10 + '      basePx.y < -9 || basePx.y >= resY + 9) return;'#10 + ''#10 + '  float rawDepth = clamp(pos.z / 110.0, 0.0, 1.0);'#10 + '  float depth = rawDepth * rawDepth;'#10 + ''#10 +
    // Rim light from the surface normal; facing fades the body, rim highlights edges.
    // Rim edge factor: the exponent shapes the falloff (2.0 = squared), so
    // it doubles as the "rim power" knob; inner-core particles take their
    // exponent from uInnerAppearance.w.
    '  float rim = clamp(1.0 - abs(normal.z), 0.0, 1.0);'#10 + '  rim = pow(rim, innerCore ? uInnerAppearance.w : uRimPower) * uRimLightStrength;'#10 + '  float facing = clamp(normal.z * 0.5 + 0.5, 0.0, 1.0);'#10 + ''#10 +
    // Core/glow radius scales with particle count so coverage stays even.
    '  float density = float(uParticleCount);'#10 + '  float coreRadius, glowRadius;'#10 + '  if (density < 5000.0) {'#10 + '    float t = clamp(density / 5000.0, 0.0, 1.0);'#10 + '    coreRadius = mix(2.5, 1.6, t);'#10 + '    glowRadius = mix(9.0, 7.0, t);'#10 + '  } else if (density > 50000.0) {'#10 + '    float t = clamp((density - 50000.0) / 200000.0, 0.0, 1.0);'#10 + '    coreRadius = mix(1.2, 0.6, t);'#10 + '    glowRadius = mix(4.0, 1.0, t);'#10 + '  } else {'#10 + '    coreRadius = 1.2;'#10 + '    glowRadius = 4.0;'#10 + '  }'#10 +
    // Inner-core particles scale their kernels with uInnerAppearance.y so
    // the brain keeps a denser look independent of the shell size knob.
    '  float sizeScale = innerCore ? uInnerAppearance.y : uParticleSize;'#10 + '  coreRadius *= sizeScale;'#10 + '  glowRadius *= sizeScale;'#10 +
    // Solid style: larger kernels let neighbouring particles merge into a
    // continuous translucent surface.
    '  if (uHoloStyle == 4) { coreRadius *= 1.45; glowRadius *= 1.35; }'#10 + '  int ir = int(ceil(glowRadius));'#10 + '  if (ir < 1) ir = 1;'#10 + '  if (ir > 5) ir = 5;'#10 + ''#10 +
    // Base colour shared by every style: a $FE alpha byte marks a per-part
    // or inner-core tint written by the CPU; photo vertex colours carry
    // $FF with a non-white RGB; anything else falls back to uFaceColor.
    // Speaking mouth particles drift toward the accent colour in step with
    // the speech pulse.
    '  vec4 col = uFaceColor;'#10 + '  if (P[idx].color != 0xFFFFFFFFu) {'#10 + '    uint colMark = (P[idx].color >> 24u) & 0xFFu;'#10 + '    if (colMark == 0xFEu || colMark == 0xFFu)'#10 + '      col = unpackColor(P[idx].color);'#10 + '  }'#10 + ''#10 + '  col.rgb = mix(col.rgb, uAccentColor.rgb, 0.50 * speech);'#10 +
    // Touch effects on colour: Style 2 (ColorFade) blends the particle
    // colour softly into the chosen TouchEffectColor inside the
    // cursor's influence and fades it back out toward the base colour
    // as the distance grows - mix() over the smoothstep influence has
    // no hard edge by construction. Style 1 (Glow) tints the lifted
    // brightness toward the accent colour as well, so the glow reads
    // in the user's chosen colour instead of plain white.
    '  if (touchInfluence > 0.0) {'#10 + '    if (uTouchEffectStyle == 2)'#10 + '      col.rgb = mix(col.rgb, uTouchEffectColor, touchInfluence);'#10 + '    else if (uTouchEffectStyle == 1)'#10 + '      col.rgb = mix(col.rgb, uTouchEffectColor, 0.35 * touchInfluence);'#10 + '  }'#10 + ''#10 +
    // Flicker, inner-core pulse, style modulation, and final alpha; fade out smoothly while falling.
    // Eye particles dim smoothly with uEyeOpeness so a blink reads as a
    // holographic fade-out / fade-in instead of a geometric lid drop; the
    // 0.28 floor keeps closed eyes as a soft glow rather than dark holes.
    // The speech pulse adds the mouth-zone energy shimmer.
    '  float flick = 0.90 + 0.10 * sin(uTime * 14.0 + float(idx) * 1.31);'#10 +
    // Solid style dampens the scanline flicker so the merged kernels read
    // as one cohesive shaded form instead of a shimmering cloud.
    '  if (uHoloStyle == 4) flick = mix(flick, 1.0, 0.85);'#10 + '  float pulse = innerCore ? (0.6 + 0.4 * sin(uTime * 6.0 + float(idx) * 0.21)) : 1.0;'#10 + ''#10 + '  float baseIntensity = mix(0.14, 1.05, depth) * facing * flick * (innerCore ? uInnerAppearance.x : uGlowIntensity);'#10 + '  if (isEye) baseIntensity *= mix(0.28, 1.0, clamp(uEyeOpeness, 0.0, 1.0));'#10 + '  baseIntensity += 0.30 * speech;'#10 + ''#10 +
    // ---- style-specific surface modulation on top of the shared base ----
    // Hologram: subtle horizontal scanlines plus a soft rim-light edge.
    '  if (uHoloStyle == 0) {'#10 + '    col.rgb *= 0.82 + 0.18 * sin(tgt.y * 0.9 - uTime * 4.0);'#10 + '    baseIntensity += rim * 0.35;'#10 + '  } else if (uHoloStyle == 1 && !isEye) {'#10 +
    // Android circuit: an angular Manhattan + 45-degree trace grid with
    // via nodes etched over the skin / armor; travelling data pulses light
    // the traces up in the accent colour.
    '    vec2 gp = tgt.xy * 0.14 + vec2(tgt.z * 0.06, -tgt.z * 0.06);'#10 + '    float trace = min(abs(fract(gp.x) - 0.5), abs(fract(gp.y) - 0.5));'#10 + '    float diag = abs(fract(gp.x + gp.y) - 0.5);'#10 + '    float lineMask = 1.0 - smoothstep(0.03, 0.07, min(trace, diag));'#10 + '    float via = 1.0 - smoothstep(0.08, 0.14, length(fract(gp) - 0.5));'#10 + '    float pulseWave = smoothstep(0.65, 1.0, sin(uTime * 4.5 - (tgt.y * 0.12 + abs(tgt.x) * 0.10)));'#10 + '    float circuit = max(lineMask, via);'#10 + '    col.rgb = mix(col.rgb, uAccentColor.rgb, circuit * 0.65);'#10 + '    baseIntensity += circuit * (0.35 + 0.85 * pulseWave);'#10 + '  } else if (uHoloStyle == 2) {'#10 +
    // Cyber matrix: quantized vertical column streams, each with its own
    // speed and phase; the bright leading heads tint toward the accent
    // colour while the columns micro-jitter horizontally.
    '    float colId = floor(tgt.x * 0.35);'#10 + '    float stream = fract(tgt.y * 0.04 - uTime * (0.8 + 0.6 * fract(sin(colId * 91.7) * 43758.5)) + fract(sin(colId * 17.3) * 12345.6));'#10 + '    float head = smoothstep(0.75, 1.0, stream);'#10 + '    col.rgb = mix(col.rgb, uAccentColor.rgb, head);'#10 + '    baseIntensity += head * 0.5;'#10 + '  } else if (uHoloStyle == 3) {'#10 +
    // Blueprint: crisp topographic contour rings along Y and Z; the
    // interior fill dims to 0.35 while contour lines and strong rim edges
    // glow in the accent colour.
    '    float ringY = 1.0 - smoothstep(0.04, 0.10, abs(fract(tgt.y * 0.18) - 0.5));'#10 + '    float ringZ = 1.0 - smoothstep(0.04, 0.10, abs(fract(tgt.z * 0.18) - 0.5));'#10 + '    float grid = max(ringY, ringZ);'#10 + '    float contour = max(grid, rim * 0.9);'#10 + '    baseIntensity *= mix(0.35, 1.0, contour);'#10 + '    col.rgb = mix(col.rgb, uAccentColor.rgb, contour * 0.85);'#10 + '  } else if (uHoloStyle == 4) {'#10 +
    // Solid: directional studio shading from the mesh normal (key light
    // from above, fill from the front) plus a crisp rim highlight, so the
    // dense surface reads as a lit 3D form.
    '    float topLight = clamp(0.55 - normal.y * 0.45, 0.25, 1.25);'#10 + '    float frontLight = clamp(normal.z * 0.65 + 0.45, 0.25, 1.2);'#10 + '    baseIntensity *= topLight * frontLight;'#10 + '    baseIntensity += rim * 0.45;'#10 + '  } else {'#10 +
    // Unknown style id: plain rim edge boost only.
    '    baseIntensity += rim * 0.3;'#10 + '  }'#10 + ''#10 + '  baseIntensity *= pulse * uAlpha;'#10 +
    // Touch effects on brightness: Style 1 (Glow) lifts the luminance
    // softly inside the influence radius (1.0 + influence-scaled boost);
    // Style 3 (Ripple) adds the subtle shimmer riding its sine wave.
    // Both scale with the smoothstep influence so they fade out
    // butter-smooth with no hard rim at the touch border.
    '  baseIntensity *= 1.0 + 1.4 * touchGlow + 0.35 * touchRippleGlow;'#10 + '  if (falling) baseIntensity *= clamp(1.0 - (pos.y - 60.0) / 90.0, 0.0, 1.0);'#10 + ''#10 +
    // Splat a core+glow kernel into uOutput with premultiplied-alpha compositing.
    '  float coreR2 = coreRadius * coreRadius;'#10 + '  float glowR2 = glowRadius * glowRadius;'#10 +
    // Glow-kernel softness: the denominator fraction widens the falloff;
    // inner-core particles take theirs from uInnerAppearance.z.
    '  float glowDenom = glowR2 * (innerCore ? uInnerAppearance.z : uSoftness);'#10 + '  for (int dy = -ir; dy <= ir; ++dy) {'#10 + '    for (int dx = -ir; dx <= ir; ++dx) {'#10 + '      ivec2 px = basePx + ivec2(dx, dy);'#10 + '      if (px.x < 0 || px.x >= resX || px.y < 0 || px.y >= resY) continue;'#10 + '      vec2 d2v = vec2(px) + 0.5 - center;'#10 + '      float dist2 = dot(d2v, d2v);'#10 + '      if (dist2 > glowR2) continue;'#10 + '      float core = exp(-dist2 / coreR2);'#10 +
    '      float glow = exp(-dist2 / glowDenom) * 0.35;'#10 + '      float a = clamp((core + glow) * baseIntensity, 0.0, 1.0);'#10 + '      if (a <= 0.004) continue;'#10 + '      vec4 src = vec4(col.rgb * a, a);'#10 + '      vec4 dst = imageLoad(uOutput, px);'#10 + '      float outA = clamp(max(dst.a, src.a) + min(dst.a, src.a) * 0.25, 0.0, 1.0);'#10 + '      vec3 outRGB = clamp(max(dst.rgb, src.rgb) + min(dst.rgb, src.rgb) * 0.25, 0.0, outA);'#10 + '      imageStore(uOutput, px, vec4(outRGB, outA));'#10 + '    }'#10 + '  }'#10 + '}';


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
  { Auto-blink defaults to on; FBlinkPhase = 0 = eyes open. The first
    inter-blink pause starts at 3.5 s, then FNextBlinkDelay re-rolls
    naturally (1.8-6.2 s, ~18 % double blinks) - the old interval slider
    and its property are gone entirely; preset files still carrying the
    BlinkInterval key are silently ignored. The 0.38 s base duration
    keeps the eased phase curve resolvable even at the 15 FPS idle frame
    rate and varies by +-25 ms per blink. }
  FAutoBlink := True;
  FTouchEffectsEnabled := True;
  FTouchEffectStyle := tesForcefield;
  FTouchEffectColor := $FF00BFFF;
  FIdleLifeMotion := True;
  FBlinkTimer := 0;
  FBlinkPhase := 0;
  FNextBlinkDelay := 3.5;
  FDoubleBlinkPending := False;
  FBlinkDuration := 0.38;
  FCurrentBlinkDuration := 0.38;
  { Idle life: saccade timer starts mid-range so the first micro-jump does
    not fire on frame one; the blend starts at 0 so a forming avatar eases
    into its idle drift instead of snapping. The cursor seed is invalid, so
    the first real sample counts as fresh movement. Mouse force starts
    disabled (outside), velocity at rest. }
  FSaccadeTimer := 1.0 + Random * 1.5;
  FSaccadeOffsetX := 0;
  FSaccadeOffsetY := 0;
  FLastCursorPos := Point(-99999, -99999);
  FMouseStillTimer := 0;
  FIdleBlend := 0;
  FMouseLocalX := -9999;
  FMouseLocalY := -9999;
  FMouseVelX := 0;
  FMouseVelY := 0;
  FMouseInside := False;
  { Screen geometry cache: invalid until the first Draw / ParentChanged
    refresh; the render thread's bounds test simply reports "outside"
    for those early frames. }
  FScreenOrigin := Point(0, 0);
  FControlW := 0;
  FControlH := 0;
  { No mesh loaded yet, so there are no per-part colour overrides. }
  FPartColors := nil;
  FEmotionMode := emNeutral;
  FAccentColor := $FF00BFFF;
  FFaceColor := $FF00BFFF;
  FEyeColor := $FF00BFFF;
  FMouthColor := $FF00BFFF;
  FMouthState := msMin;
  FEyeState := esOpen;
  FHighlightActive := False;
  { Alive highlighter entity for the organic overlay; tinted from the
    accent colour and advanced / drawn by the full-desktop overlay control
    through RenderHighlighterOverlay (this control is too small to host
    it without clipping the entity at its edges). }
  FHighlighter := TAliveHighlighter.Create;
  FHighlighter.Color := FAccentColor;
  FParticleBudget := DEFAULT_PARTICLE_BUDGET;
  { uChaosLevel stays wired for the legacy depth-map shader; with no UI
    knob the drift level is fixed at 0 = none. }
  FChaosLevel := 0.0;
  FParticleCount := 0;
  FPBOIndex := 0;
  FPBOHasData := False;
  FGLReady := False;
  FGLFailed := False;
  FDepthMap := nil;
  FLastTime := 0;
  FClearProgram := 0;
  ExePath := ExtractFilePath(ParamStr(0));
  DepthFile := ExePath + 'depthmap.png';
  if FileExists(DepthFile) then
    LoadDepthMap(DepthFile);

  { Holographic style + live-control defaults. Hologram is the baseline
    look for every source; the controls panel switches styles live. }
  FHoloStyle := hsHologram;
  FSourceType := srcDepthMap;
  FStepFilter := 1;
  FParticleSize := 1.0;
  FGlowIntensity := 1.0;
  FRimLightStrength := 1.0;
  FHoloAlpha := 0.85;
  FJitterAmount := 0.4;
  { Softness 0.40 keeps the legacy glow-kernel falloff fraction and rim
    power 2.0 reproduces the squared falloff, so the outer shell starts
    visually identical to the fixed constants. The inner core starts
    dimmer and denser so the brain reads behind the eyes without
    over-glowing. }
  FSoftness := 0.40;
  FRimPower := 2.0;
  FInnerGlow := 0.55;
  FInnerParticleSize := 1.20;
  FInnerSoftness := 0.45;
  FInnerRimPower := 2.20;
  FHoloProgram := 0;
  FMeshScale := 1.0;
  FMeshFlipY := True;
  FActiveSequence := -1;
  FAnimTime := 0;
  FInnerCore := False;
  { Inner-core defaults: a 0.48-scaled core lifted 12 px toward the crown so
    a brain sits inside the cranium, capped at 40k points so the shell keeps
    the larger share of the combined budget. }
  FInnerCoreScale := 0.48;
  FInnerCoreOffsetY := -12.0;
  FInnerCoreBudget := 40000;
  FInnerCoreStartIdx := 0;
  FInnerCoreCount := 0;

  { Adaptive idle FPS: 50 FPS while the avatar speaks / animates / morphs,
    dropping to 25 FPS after three seconds of silence. Exposed on the base
    class so it can be fine-tuned at runtime. }
  AdaptiveFPS := True;
  ActiveTargetFPS := 50;
  IdleTargetFPS := 25;
  IdleTimeoutSec := 3.0;
  FNeckPivotRatio := 0.70;
  FContextBound := False;
  { Offscreen buffer starts at the default CHAOS dims; the pending pair
    only diverges once a mesh load / resize requests a different size. }
  FBufW := CHAOS_WIDTH;
  FBufH := CHAOS_HEIGHT;
  FPendingBufW := CHAOS_WIDTH;
  FPendingBufH := CHAOS_HEIGHT;
  FBufResizePending := False;
  { Dragging is off by default: the avatar sits click-through until the
      user asks for interactive placement. }
  FDragMode := False;
  FDragging := False;
  FSavedClickThrough := False;
  FLoadingPreset := False;

  { Startup restore: last.ini remembers the most recently saved or loaded
    preset, and when it still points at an existing file it replaces the
    demo-asset probe entirely, so the saved mesh loads once instead of
    being loaded only to be replaced. A corrupt preset falls back to the
    probe, keeping the app-always-starts guarantee. }
  FStartupPresetLoaded := False;
  FHasPendingStartupPlacement := False;
  { AI / voice defaults: nothing audio is created until the panel activates
    it (both toggles stay False; the pipeline is built on demand). The
    gesture springs start at rest. }
  FAIClient := nil;
  FVoicePipeline := nil;
  FVoiceTtsEnabled := False;
  FVoiceSttEnabled := False;
  FPendingVoiceActivation := False;
  FVoiceStatusText := 'Idle';
  FGestureVelX := 0;
  FGestureVelY := 0;
  FGestureOffsetX := 0;
  FGestureOffsetY := 0;
  FMouthAutoTarget := 0;
  { Eye / hover state: eyes start centred, the hover alpha multiplier starts
    fully visible, both auto-dim and highlighter mouse-follow opt in from
    the UI / presets. }
  FSaccadeSmoothX := 0;
  FSaccadeSmoothY := 0;
  FCurrentHoverAlphaMul := 1.0;
  FAutoDimOnHover := False;
  FHighlightFollowMouse := False;
  FCustomEyePartName := '';
  { Info / Debug live log: guard + ring buffer live for the whole lifetime,
    so even the earliest GL-init log lines survive; GPU detection fills the
    snapshot fields right after InitOffscreenGL (see RenderEffect). }
  FDebugLogLock := TObject.Create;
  FDebugLog := TList<string>.Create;
  FDebugLogSerial := 0;
  FGpuInfoText := '';
  FGpuRecommendedParticles := 0;
  FActiveVoskModelDir := '';
  FActivePiperVoice := '';
  AppendDebugLog('TSkChaos created - GL context + GPU detection pending');
  FDataLock := TCriticalSection.Create;
  try
    FStartupPresetLoaded := LoadLastStartupPreset;
  except
    FStartupPresetLoaded := False;
  end;
  if not FStartupPresetLoaded then
  begin
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
        { The load above auto-applied this mesh's own preset, which also
          restored the overlay placement; the flag keeps the host form
          from stamping its default corner position over that restore. }
        FStartupPresetLoaded := FileExists(GetAutoPresetPath);
      except
        FAutoMeshFile := '';
        FSourceType := srcDepthMap;
      end;
    end;
  end;
end;

destructor TSkChaos.Destroy;
begin
  { Tear the voice pipeline down before the base control dies: it owns audio
    threads whose callbacks must never touch a half-destroyed avatar. The AI
    client is a plain TComponent - freeing it here is enough. }
  FreeAndNil(FVoicePipeline);
  FreeAndNil(FAIClient);
  inherited;
  FreeAndNil(FDepthMap);
  FreeAndNil(FHighlighter);
  FreeAndNil(FDataLock);
  FreeAndNil(FDebugLog);
  FreeAndNil(FDebugLogLock);
end;

{==============================================================================
  Info / Debug live log
==============================================================================}
procedure TSkChaos.AppendDebugLog(const AMsg: string);
const
  MAX_LOG_LINES = 500;
var
  Stamp: string;
begin
  { Thread-safe append with [HH:NN:SS] wall-clock stamp; called from the
    render thread (GL init / GPU detection), the audio stack's worker
    threads (fallbacks) and the AI client's queued handlers (main thread).
    Ring buffer: oldest lines drop beyond MAX_LOG_LINES so a long session
    cannot grow the list unbounded. TMonitor guards FDebugLog + serial. }
  if (FDebugLog = nil) or (FDebugLogLock = nil) then
    Exit;
  Stamp := FormatDateTime('hh:nn:ss', Now);
  TMonitor.Enter(FDebugLogLock);
  try
    FDebugLog.Add('[' + Stamp + '] ' + AMsg);
    while FDebugLog.Count > MAX_LOG_LINES do
      FDebugLog.Delete(0);
    Inc(FDebugLogSerial);
  finally
    TMonitor.Exit(FDebugLogLock);
  end;
end;

function TSkChaos.GetDebugLogText: string;
var
  I: Integer;
  SB: TStringBuilder;
begin
  { Snapshot join of the ring buffer. The panel calls this only when
    DebugLogSerial changed, so the cost stays rare; the builder avoids the
    quadratic string-concat of a naive loop. }
  Result := '';
  if (FDebugLog = nil) or (FDebugLogLock = nil) then
    Exit;
  TMonitor.Enter(FDebugLogLock);
  try
    if FDebugLog.Count = 0 then
      Exit;
    SB := TStringBuilder.Create;
    try
      for I := 0 to FDebugLog.Count - 1 do
      begin
        SB.Append(FDebugLog[I]);
        if I < FDebugLog.Count - 1 then
          SB.Append(sLineBreak);
      end;
      Result := SB.ToString;
    finally
      SB.Free;
    end;
  finally
    TMonitor.Exit(FDebugLogLock);
  end;
end;

procedure TSkChaos.ClearDebugLog;
begin
  { Panel's Clear Log button: drop every line, bump the serial so the
    Info / Debug tab's next timer tick refreshes the memo to empty. }
  if (FDebugLog = nil) or (FDebugLogLock = nil) then
    Exit;
  TMonitor.Enter(FDebugLogLock);
  try
    FDebugLog.Clear;
    Inc(FDebugLogSerial);
  finally
    TMonitor.Exit(FDebugLogLock);
  end;
end;

{==============================================================================
  AI client + voice pipeline integration
==============================================================================}
procedure TSkChaos.EnsureAIClient(const ABaseURL, AModel, AApiKey, ASystemPrompt: string);
begin
  { On-demand creation - independent of the voice toggles: pure text chat
    must work while the whole audio stack is off, so the panel calls this
    for every config save, not only when voice is on. }
  if FAIClient = nil then
    FAIClient := TYutaniAIClient.Create(Self);
  if Trim(ABaseURL) <> '' then
    FAIClient.BaseURL := ABaseURL;
  if Trim(AModel) <> '' then
    FAIClient.Model := AModel;
  FAIClient.ApiKey := AApiKey;
  if Trim(ASystemPrompt) <> '' then
    FAIClient.SystemPrompt := ASystemPrompt;
  { (Re)wire the events: assignments are idempotent, and a client recreated
    after a shutdown needs them again. }
  FAIClient.OnThinking := HandleAIThinking;
  FAIClient.OnActionTag := HandleAIActionTag;
  FAIClient.OnResponse := HandleAIResponse;
  FAIClient.OnError := HandleAIError;
end;

procedure TSkChaos.AskAI(const AText: string);
begin
  if Trim(AText) = '' then
    Exit;
  { The AI is usable without any voice/audio stack: EnsureAIClient creates
    the client on demand with the last-saved endpoint configuration. }
  if FAIClient = nil then
    EnsureAIClient('', '', '', '');
  if FAIClient = nil then
    Exit;
  FVoiceStatusText := 'Thinking';
  AppendDebugLog('AI request: "' + Copy(Trim(AText), 1, 120) + '" (model: ' + FAIClient.Model + ')');
  FAIClient.AskAsync(AText);
  NotifyActivity;
end;

procedure TSkChaos.SpeakVoice(const AText: string);
begin
  { Every direct TTS trigger (panel Test-TTS button, tray menu) lands in the
    debug log - the pipeline's own TtsStart events only report playback, not
    WHO asked for it. }
  if Trim(AText) = '' then
    Exit;
  AppendDebugLog('SpeakVoice: "' + Copy(Trim(AText), 1, 80) + '"');
  if FVoicePipeline <> nil then
    FVoicePipeline.Say(AText);
end;

procedure TSkChaos.ActivatePendingVoice(const AVoskModelDir: string = ''; const APiperVoice: string = '');
var
  AVoskModelDirBefore, APiperVoiceBefore: string;
begin
  { Public entry point for the controls panel: mark the intent and try the
    setup right away with the given model paths (empty strings leave STT off
    and TTS on the SAPI fallback - text chat keeps working either way).
    Re-activation with CHANGED paths rebuilds the pipeline cleanly: the old
    pipeline keeps a loaded Vosk model / piper voice that Setup refuses to
    swap (Setup called twice raises), so a fresh instance is the only way a
    new model pick takes effect without an app restart. Same paths (panel
    re-sync at startup) keep the running pipeline untouched. }
  FPendingVoiceActivation := True;
  if FVoicePipeline <> nil then
  begin
    if SameText(FActiveVoskModelDir, AVoskModelDir) and SameText(FActivePiperVoice, APiperVoice) then
      Exit;
    AVoskModelDirBefore := FActiveVoskModelDir;
    APiperVoiceBefore := FActivePiperVoice;
    AppendDebugLog(Format('Voice pipeline re-activation: vosk "%s" -> "%s", piper "%s" -> "%s" (rebuilding)',
      [AVoskModelDirBefore, AVoskModelDir, APiperVoiceBefore, APiperVoice]));
    try
      FreeAndNil(FVoicePipeline);
    except
      on E: Exception do
        AppendDebugLog('Old pipeline teardown raised: ' + E.Message);
    end;
  end;
  FActiveVoskModelDir := AVoskModelDir;
  FActivePiperVoice := APiperVoice;
  if FVoiceTtsEnabled or FVoiceSttEnabled then
    SetupVoicePipeline(AVoskModelDir, APiperVoice);
end;

procedure TSkChaos.SetupVoicePipeline(const AVoskModelDir, APiperVoice: string);
var
  PiperModel, PiperTokens, PiperEspeak, PiperLexicon: string;
begin
  { Never raise out of here on missing models: a broken microphone or
    MiniAudio failure raises from Setup and is caught below, but absent
    STT / TTS files only degrade (text chat and SAPI keep working). }
  if FVoicePipeline <> nil then
    Exit;
  { Resolve the piper voice: APiperVoice may be the .onnx file itself or a
    voice folder (tokens.txt / espeak-ng-data sit beside the onnx - possibly
    one or more levels below, sherpa\vits-piper-en_US-lessac-medium\...).
    Empty strings keep TTS on the SAPI fallback. }
  PiperModel := APiperVoice;
  PiperTokens := '';
  PiperEspeak := '';
  PiperLexicon := '';
  if (PiperModel <> '') and FileExists(PiperModel) then
  begin
    { File form: resolve tokens.txt / espeak-ng-data / lexicon.txt in the
      onnx folder first, then in its parent (a single nested level covers
      the sherpa root layout where tokens sit beside the voice subfolder). }
    ResolvePiperSidecars(PiperModel, ExtractFilePath(PiperModel), PiperTokens, PiperEspeak, PiperLexicon);
  end
  else if (PiperModel <> '') and DirectoryExists(PiperModel) then
  begin
    { Folder form: find the first .onnx inside - directly or nested one
      level deeper (sherpa\vits-piper-...\voice.onnx); tokens / espeak /
      lexicon are searched beside the found onnx and up to its parent. }
    PiperModel := FindFirstOnnxNested(APiperVoice);
    if PiperModel <> '' then
      ResolvePiperSidecars(PiperModel, ExtractFilePath(PiperModel), PiperTokens, PiperEspeak, PiperLexicon)
    else
    begin
      { No onnx in the folder tree: leave TTS to the SAPI fallback. }
      PiperTokens := '';
      PiperEspeak := '';
      PiperLexicon := '';
    end;
  end;
  if AVoskModelDir <> '' then
    AppendDebugLog(Format('Voice pipeline setup: vosk model dir "%s"', [AVoskModelDir]))
  else
    AppendDebugLog('Voice pipeline setup: no Vosk model dir (STT off)');
  if PiperModel <> '' then
    AppendDebugLog(Format('Voice pipeline setup: piper voice "%s" (tokens: %d, espeak-ng-data: %d, lexicon: %d)',
      [PiperModel, Ord(PiperTokens <> ''), Ord(PiperEspeak <> ''), Ord(PiperLexicon <> '')]))
  else if APiperVoice <> '' then
    AppendDebugLog(Format('Voice pipeline setup: no .onnx found under "%s" - SAPI fallback', [APiperVoice]))
  else
    AppendDebugLog('Voice pipeline setup: no piper voice selected - SAPI fallback');
  try
    FVoicePipeline := TYutaniVoicePipeline.Create;
    FVoicePipeline.AutoReply := False;
    FVoicePipeline.OnHeard := HandleSpeechFinal;
    FVoicePipeline.OnTtsStart := HandleVoiceTtsStart;
    FVoicePipeline.OnTtsEnd := HandleVoiceTtsEnd;
    FVoicePipeline.OnError := HandleVoiceError;
    FVoicePipeline.OnFallback := HandleVoiceFallback;
    { The split toggles flow straight through: TTS-only builds engine + TTS
      (no capture device, no libvosk), STT-only builds capture + Vosk and
      answers arrive as text + gestures. }
    FVoicePipeline.Setup(AVoskModelDir, PiperModel, PiperTokens, PiperEspeak,
      FVoiceTtsEnabled, FVoiceSttEnabled);
    { Setup survived: report which engine combination went live (Vosk status
      comes from the pipeline's own events - the OnFallback handler logs a
      missing model / DLL - so here the success side is all we know). }
    if FVoicePipeline <> nil then
    begin
      if FVoiceSttEnabled and (AVoskModelDir <> '') then
        AppendDebugLog('Vosk STT active: ' + AVoskModelDir)
      else if FVoiceSttEnabled then
        AppendDebugLog('Vosk STT off (no model dir)')
      else
        AppendDebugLog('STT disabled by toggle');
      if FVoiceTtsEnabled then
      begin
        if PiperModel <> '' then
          AppendDebugLog('Piper TTS active: ' + PiperModel)
        else
          AppendDebugLog('Piper TTS on SAPI fallback (no model)');
      end
      else
        AppendDebugLog('TTS disabled by toggle (answers as text + gestures)');
    end;
  except
    { A hard audio failure (no microphone / MiniAudio broken) must not take
      the avatar down: drop the pipeline and report why through the status. }
    on E: Exception do
    begin
      FreeAndNil(FVoicePipeline);
      FVoiceStatusText := 'Fallback: ' + E.Message;
      AppendDebugLog('Voice pipeline setup FAILED: ' + E.Message);
    end;
  end;
end;

procedure TSkChaos.ResolvePiperSidecars(const AOnnxPath, AOnnxFolder: string;
  out ATokens, AEspeak, ALexicon: string);
var
  Base, Cand: string;

  { tokens.txt / espeak-ng-data / lexicon.txt in Base, else ''. }
  procedure CheckBase;
  begin
    Cand := TPath.Combine(Base, 'tokens.txt');
    if FileExists(Cand) then
      ATokens := Cand;
    Cand := TPath.Combine(Base, 'espeak-ng-data');
    if DirectoryExists(Cand) then
      AEspeak := Cand;
    Cand := TPath.Combine(Base, 'lexicon.txt');
    if FileExists(Cand) then
      ALexicon := Cand;
  end;

var
  Parent: string;
begin
  { Sidecar search: the folder that HOLDS the .onnx first, then its parent -
    piper voices unpacked into a subfolder (vits-piper-en_US-lessac-medium\)
    keep tokens.txt / espeak-ng-data either beside the onnx, beside the
    voice folder, or both. Whichever copy exists wins; lexicon.txt is an
    accepted alternative to espeak-ng-data (sherpa-onnx accepts either). }
  ATokens := '';
  AEspeak := '';
  ALexicon := '';
  Base := AOnnxFolder;
  if Base <> '' then
    CheckBase;
  Parent := ExtractFilePath(ExcludeTrailingPathDelimiter(Base));
  if Parent <> '' then
  begin
    { Second pass over the parent only fills values the onnx folder did not
      provide, so the nearest copy always wins. }
    Base := Parent;
    if (ATokens = '') or (AEspeak = '') or (ALexicon = '') then
      CheckBase;
  end;
end;

function TSkChaos.FindFirstOnnxNested(const AFolder: string): string;
var
  SR: TSearchRec;
  Sub: string;
begin
  { First .onnx DIRECTLY inside AFolder, else the first .onnx one level
    deeper in any subfolder (sherpa\vits-piper-...\voice.onnx layout).
    ('' when neither exists.) }
  Result := FindFirstOnnxInFolder(AFolder);
  if Result <> '' then
    Exit;
  if (AFolder = '') or (not DirectoryExists(AFolder)) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(AFolder) + '*', faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
      begin
        Sub := IncludeTrailingPathDelimiter(AFolder) + SR.Name;
        Result := FindFirstOnnxInFolder(Sub);
        if Result <> '' then
          Exit;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function TSkChaos.FindFirstOnnxInFolder(const AFolder: string): string;
var
  SR: TSearchRec;
begin
  { First .onnx file directly inside AFolder ('' when none exists). }
  Result := '';
  if (AFolder = '') or (not DirectoryExists(AFolder)) then
    Exit;
  if FindFirst(IncludeTrailingPathDelimiter(AFolder) + '*.onnx', faAnyFile, SR) = 0 then
  try
    Result := IncludeTrailingPathDelimiter(AFolder) + SR.Name;
  finally
    FindClose(SR);
  end;
end;

procedure TSkChaos.SetVoiceTtsEnabled(const Value: Boolean);
begin
  if FVoiceTtsEnabled = Value then
    Exit;
  FVoiceTtsEnabled := Value;
  { Enabling from the panel: the pipeline is built ONLY from
    ActivatePendingVoice, which hands the REAL model paths over (INI-saved
    or freshly picked). Building an empty ('', '') pipeline here would lock
    TTS onto SAPI before the panel could supply the actual models. The
    pending flag keeps the intent so the panel's ActivatePendingVoice call
    right after the toggle loads exactly the selected piper voice. }
  if FVoiceTtsEnabled then
  begin
    FPendingVoiceActivation := True;
    if FVoiceSttEnabled or (FVoicePipeline <> nil) then
      FVoiceStatusText := 'Listening'
    else
      FVoiceStatusText := 'Voice ready';
  end
  else
    FVoiceStatusText := 'Idle';
  NotifyActivity;
end;

procedure TSkChaos.SetVoiceSttEnabled(const Value: Boolean);
begin
  if FVoiceSttEnabled = Value then
    Exit;
  FVoiceSttEnabled := Value;
  { Same deferred wiring as the TTS side: ActivatePendingVoice supplies the
    real Vosk model dir right after the toggle; disabling alone keeps a
    running pipeline (text chat + TTS stay usable) - HandleSpeechFinal is
    additionally gated by FVoiceSttEnabled. }
  if FVoiceSttEnabled then
  begin
    FPendingVoiceActivation := True;
    FVoiceStatusText := 'Listening';
  end
  else
  begin
    if FVoiceTtsEnabled then
      FVoiceStatusText := 'Voice ready'
    else
      FVoiceStatusText := 'Idle';
  end;
  NotifyActivity;
end;

procedure TSkChaos.HandleSpeechPartial(Sender: TObject; const AText: string; AIsFinal: Boolean);
begin
  { Live partial transcription - nothing to drive yet. }
end;

procedure TSkChaos.HandleSpeechFinal(Sender: TObject; const AText: string; AIsFinal: Boolean);
begin
  { Fired from the recognizer's worker thread (marshalled through the audio
    stack); the pipeline already gates MicLipSyncOnly, so recognized text
    reaching here means the user actually talked TO the avatar. }
  if (not AIsFinal) or (Trim(AText) = '') then
    Exit;
  if (FVoicePipeline <> nil) and FVoicePipeline.MicLipSyncOnly then
    Exit;
  { STT toggle off: the recognizer may still run (pipeline alive for TTS),
    but recognized text must not reach the AI. }
  if not FVoiceSttEnabled then
    Exit;
  AppendDebugLog('Vosk recognized: "' + Copy(Trim(AText), 1, 120) + '"');
  FVoiceStatusText := 'Thinking';
  AskAI(AText);
end;

procedure TSkChaos.HandleAIThinking(Sender: TObject);
begin
  { Slight thinking tilt while the request runs. }
  EmotionMode := emThinking;
  FGestureVelY := FGestureVelY - 0.55;
  FVoiceStatusText := 'Thinking';
  AppendDebugLog('AI request sent - waiting for response');
end;

procedure TSkChaos.HandleAIActionTag(Sender: TObject; const ATag: string);
begin
  AppendDebugLog('AI action tag: ' + ATag);
  ApplyHeadGesture(ATag);
end;

procedure TSkChaos.HandleAIResponse(Sender: TObject; const ASpokenText: string);
var
  Cleaned, RemovedTags: string;
begin
  { Response arrived: strip every action-tag token ([nod], [shake], [tilt],
    [think], [alert], [neutral]) from the text - the model occasionally
    embeds them mid-sentence or at the end despite the prompt - so the TTS
    never reads bracket noise aloud. The tags are pure gesture markers: the
    AI client already fired them as action events (head gesture still runs),
    here they only would pollute the spoken text. }
  Cleaned := StripActionTags(ASpokenText, RemovedTags);
  if RemovedTags <> '' then
    AppendDebugLog('AI action tags filtered from response: ' + RemovedTags);
  { The answer ALWAYS lands in the status text, whether it is spoken or
    not - with the voice stack live the user can read along while the TTS
    talks (the label would otherwise sit at "Speaking" and hide the actual
    words); in text-only mode it is the only channel at all. }
  if Trim(Cleaned) <> '' then
    FVoiceStatusText := 'AI: ' + Trim(Cleaned);
  { Speak the cleaned text when the TTS side is live (the pipeline's
    anti-echo mutes the recognizer while it talks; STT-only setups stay
    text+gesture on purpose - no voice to play). }
  if FVoiceTtsEnabled and (FVoicePipeline <> nil) and (Trim(Cleaned) <> '') then
  begin
    FVoicePipeline.Say(Cleaned);
    AppendDebugLog('AI response (' + IntToStr(Length(Cleaned)) + ' chars) -> speaking');
  end
  else if Trim(Cleaned) <> '' then
    AppendDebugLog('AI response (text-only): ' + Copy(Cleaned, 1, 160))
  else
    FVoiceStatusText := 'Idle';
  NotifyActivity;
end;

function TSkChaos.StripActionTags(const AText: string; out ARemoved: string): string;
var
  I, Start: Integer;
  TagLower: string;
const
  TAG_NAMES: array[0..5] of string = ('neutral', 'nod', 'shake', 'tilt', 'think', 'alert');
begin
  { Remove EVERY bracketed action-tag token from anywhere in the text
    (start / middle / end), collapsing the leftover double spaces. ARemoved
    collects the tags for the debug log. Non-tag brackets ([quote], [1])
    stay untouched - only the six known gesture tags are TTS noise. }
  Result := AText;
  ARemoved := '';
  Start := 0;
  { WHILE loop instead of for-to: the body writes I := Start - 1 after a
    Delete so the scan restarts at the same spot and overlapping tags are
    caught - a for-loop variable cannot be assigned (compiler E2081). }
  I := 1;
  while I <= Length(Result) do
  begin
    if Result[I] = '[' then
      Start := I
    else if (Result[I] = ']') and (Start > 0) then
    begin
      if (I - Start) > 1 then
      begin
        TagLower := LowerCase(Copy(Result, Start + 1, I - Start - 1));
        if (TagLower = 'neutral') or (TagLower = 'nod') or (TagLower = 'shake')
          or (TagLower = 'tilt') or (TagLower = 'think') or (TagLower = 'alert') then
        begin
          if ARemoved <> '' then
            ARemoved := ARemoved + ', ';
          ARemoved := ARemoved + TagLower;
          Delete(Result, Start, I - Start + 1);
          { Deleting shifts everything left: restart the scan from the same
            position so overlapping tags ('] [nod] [nod]') are caught too. }
          I := Start - 1;
        end;
      end;
      Start := 0;
    end;
    Inc(I);
  end;
  Result := Trim(Result);
  while Pos('  ', Result) > 0 do
    Delete(Result, Pos('  ', Result), 1);
end;

procedure TSkChaos.HandleAIError(Sender: TObject; const AErrorMsg: string);
begin
  { The exact failure reason stays visible on the panel's status label. }
  FVoiceStatusText := 'Fallback: ' + AErrorMsg;
  AppendDebugLog('AI request error: ' + AErrorMsg);
end;

procedure TSkChaos.HandleVoiceTtsStart(Sender: TObject; const AMsg: string);
begin
  { Debug-log EVERY TTS start: a failure in AttachEngine or SpeakViaSherpa
    otherwise stays invisible (the "logged speaking but nothing audible"
    case - now the log shows whether playback really began). }
  AppendDebugLog('TTS started');
  FVoiceStatusText := 'Speaking';
  NotifyActivity;
end;

procedure TSkChaos.HandleVoiceTtsEnd(Sender: TObject; const AMsg: string);
begin
  AppendDebugLog('TTS finished');
  FVoiceStatusText := 'Idle';
  NotifyActivity;
end;

procedure TSkChaos.HandleVoiceError(Sender: TObject; const AMsg: string);
begin
  { EVERY TTS error goes to the debug log too (AttachEngine /
    ma_sound_start failures live here) - the status label alone rotates
    away, the log keeps the reason for diagnosis. }
  AppendDebugLog('TTS error: ' + AMsg);
  FVoiceStatusText := 'Fallback: ' + AMsg;
  NotifyActivity;
end;

procedure TSkChaos.HandleVoiceFallback(Sender: TObject; const AMsg: string);
begin
  FVoiceStatusText := 'Fallback: ' + AMsg;
  AppendDebugLog('Voice fallback: ' + AMsg);
end;

procedure TSkChaos.ApplyHeadGesture(const ATag: string);
var
  LowTag: string;
begin
  { Soft damped spring impulses on the head rotation around the neck pivot
    (FGestureOffset* chase 0, the velocities carry the impulse). Amplitudes
    stay small so the look-at tracking keeps dominating. }
  LowTag := LowerCase(ATag);
  if LowTag = 'nod' then
  begin
    FGestureVelY := FGestureVelY - 1.1;
    EmotionMode := emNeutral;
  end
  else if LowTag = 'shake' then
  begin
    FGestureVelX := FGestureVelX - 1.35;
    EmotionMode := emNeutral;
  end
  else if LowTag = 'tilt' then
  begin
    FGestureVelX := FGestureVelX + 0.7;
    EmotionMode := emNeutral;
  end
  else if LowTag = 'think' then
  begin
    FGestureVelX := FGestureVelX + 0.45;
    FGestureVelY := FGestureVelY - 0.3;
    EmotionMode := emThinking;
  end
  else if LowTag = 'alert' then
  begin
    FGestureVelY := FGestureVelY - 0.9;
    EmotionMode := emAlert;
  end;
  NotifyActivity;
end;

procedure TSkChaos.UpdateGestureSprings(ADeltaTime: Double);
begin
  { Critically-damped springs: velocity integrates the impulse, offset
    follows the velocity, both decay back to rest so the head settles. }
  FGestureVelX := FGestureVelX - FGestureOffsetX * 26.0 * ADeltaTime - FGestureVelX * 7.5 * ADeltaTime;
  FGestureVelY := FGestureVelY - FGestureOffsetY * 26.0 * ADeltaTime - FGestureVelY * 7.5 * ADeltaTime;
  FGestureOffsetX := FGestureOffsetX + FGestureVelX * ADeltaTime;
  FGestureOffsetY := FGestureOffsetY + FGestureVelY * ADeltaTime;
  FGestureOffsetX := EnsureRange(FGestureOffsetX, -0.6, 0.6);
  FGestureOffsetY := EnsureRange(FGestureOffsetY, -0.6, 0.6);
end;

procedure TSkChaos.UpdateLipSync(ADeltaTime: Double);
var
  Target: Single;
begin
  { 60-FPS mouth driver: while the TTS speaks (or MicLipSyncOnly mirrors the
    creator's live microphone), CurrentAmplitude is the smoothed RMS envelope
    and becomes the mouth target; when the voice goes silent the mouth fades
    back to 0.0 first and the manual MouthOpen track then takes over again. }
  if (FVoicePipeline <> nil) and (FVoicePipeline.IsSpeaking or FVoicePipeline.MicLipSyncOnly) then
    Target := EnsureRange(FVoicePipeline.CurrentAmplitude, 0.0, 1.0)
  else
    Target := -1;  // flag: no live amplitude, fade out and hand back control
  if Target >= 0 then
    FMouthAutoTarget := FMouthAutoTarget + (Target - FMouthAutoTarget) * EnsureRange(14.0 * ADeltaTime, 0, 1)
  else
  begin
    { Silent: decay the auto target to 0 and follow it down, so the mouth
      closes softly instead of freezing at the last spoken value. }
    FMouthAutoTarget := FMouthAutoTarget * (1.0 - EnsureRange(5.0 * ADeltaTime, 0, 1));
    if FMouthAutoTarget <= 0.015 then
    begin
      { Handover complete: the auto driver releases FMouthOpen so the manual
        trackbar owns the mouth again. }
      FMouthAutoTarget := 0.0;
      if FMouthOpen < 0.015 then
        FMouthOpen := 0.0;
    end
    else
      FMouthOpen := FMouthAutoTarget;
  end;
  if Target >= 0 then
    FMouthOpen := EnsureRange(FMouthAutoTarget, 0.0, 1.0);
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
      EnsureVisibleForSpawn;
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
  { RenderEffect runs on one dedicated render thread; the context stays bound
    there for the component's lifetime, so the per-frame wglMakeCurrent call
    is unnecessary - track it and only rebind if the thread changed. }
  FContextBound := True;
  InitShaders;
  InitGLResources;
  FGLReady := True;
  { GPU detection + 15 ms compute benchmark HERE, while the fresh 4.3
    context is current on this thread (the benchmark dispatches a real
    compute shader, so glGetString / dispatches must run inside the window
    between wglMakeCurrent and the next frame). Any failure leaves the
    snapshot empty - the Info tab then shows the detection as unavailable
    instead of crashing the first frame. }
  try
    FGpuCaps := DetectGPUCapabilities(True);
    FGpuInfoText := FormatGpuInfoText(FGpuCaps);
    FGpuRecommendedParticles := FGpuCaps.RecommendedParticles;
    AppendDebugLog(Format('GPU detected: %s (tier %s, compute score %.2f ms)',
      [FGpuCaps.Renderer, TGpuTierNames[FGpuCaps.Tier], FGpuCaps.ComputeScoreMS]));
  except
    on E: Exception do
    begin
      FGpuInfoText := 'GPU detection failed: ' + E.Message;
      FGpuRecommendedParticles := 0;
      AppendDebugLog('GPU detection FAILED: ' + E.Message);
    end;
  end;
  Result := True;
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
  FnUniform3f := GetProc('glUniform3f');
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
  FnBufferStorage := GetProc('glBufferStorage');
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
  { glBufferStorage (GL 4.4) drives the zero-copy persistent readback PBO;
     without it (or with USE_PERSISTENT_PBO_READBACK = False) the code falls
     back to the classic map/copy path. }
  FHasBufferStorage := USE_PERSISTENT_PBO_READBACK and Assigned(FnBufferStorage);
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
  PS, CS, HS: Cardinal;
begin
  PS := CompileShader(GL_COMPUTE_SHADER, PARTICLE_SRC);
  CS := CompileShader(GL_COMPUTE_SHADER, CLEAR_SRC);
  FParticleProgram := LinkProgram([PS]);
  FClearProgram := LinkProgram([CS]);
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
  FLocP_TrigY := FnGetUniformLocation(FParticleProgram, 'uTrigY');
  FLocP_TrigX := FnGetUniformLocation(FParticleProgram, 'uTrigX');
  FLocP_HighlightRect := FnGetUniformLocation(FParticleProgram, 'uHighlightRect');
  FLocP_HighlightPulse := FnGetUniformLocation(FParticleProgram, 'uHighlightPulse');
  FLocP_MinY := FnGetUniformLocation(FParticleProgram, 'uMinY');
  FLocP_MaxY := FnGetUniformLocation(FParticleProgram, 'uMaxY');
  FnUseProgram(FClearProgram);
  FLocC_Resolution := FnGetUniformLocation(FClearProgram, 'uResolution');
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
  FLocH_MouseLocal := FnGetUniformLocation(FHoloProgram, 'uMouseLocal');
  FLocH_MouseVel := FnGetUniformLocation(FHoloProgram, 'uMouseVel');
  FLocH_TouchEffectStyle := FnGetUniformLocation(FHoloProgram, 'uTouchEffectStyle');
  FLocH_TouchEffectColor := FnGetUniformLocation(FHoloProgram, 'uTouchEffectColor');
  FLocH_PivotY := FnGetUniformLocation(FHoloProgram, 'uPivotY');
  FLocH_HoloStyle := FnGetUniformLocation(FHoloProgram, 'uHoloStyle');
  FLocH_ParticleSize := FnGetUniformLocation(FHoloProgram, 'uParticleSize');
  FLocH_GlowIntensity := FnGetUniformLocation(FHoloProgram, 'uGlowIntensity');
  FLocH_RimLightStrength := FnGetUniformLocation(FHoloProgram, 'uRimLightStrength');
  FLocH_Alpha := FnGetUniformLocation(FHoloProgram, 'uAlpha');
  FLocH_Jitter := FnGetUniformLocation(FHoloProgram, 'uJitter');
  FLocH_FaceColor := FnGetUniformLocation(FHoloProgram, 'uFaceColor');
  FLocH_AccentColor := FnGetUniformLocation(FHoloProgram, 'uAccentColor');
  { Facial animation: eyelid / jaw deformation and the head-local frame. }
  FLocH_MouthOpen := FnGetUniformLocation(FHoloProgram, 'uMouthOpen');
  FLocH_EyeOpeness := FnGetUniformLocation(FHoloProgram, 'uEyeOpeness');
  FLocH_HeadCenter := FnGetUniformLocation(FHoloProgram, 'uHeadCenter');
  FLocH_HeadSize := FnGetUniformLocation(FHoloProgram, 'uHeadSize');
  FLocH_CustomInnerMesh := FnGetUniformLocation(FHoloProgram, 'uCustomInnerMesh');
  FLocH_Softness := FnGetUniformLocation(FHoloProgram, 'uSoftness');
  FLocH_RimPower := FnGetUniformLocation(FHoloProgram, 'uRimPower');
  FLocH_InnerAppearance := FnGetUniformLocation(FHoloProgram, 'uInnerAppearance');
  FLocH_TrigY := FnGetUniformLocation(FHoloProgram, 'uTrigY');
  FLocH_TrigX := FnGetUniformLocation(FHoloProgram, 'uTrigX');
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
  ImgInfo: TSkImageInfo;

  procedure SetupTex(Tex: Cardinal);
  begin
    FnBindTexture(GL_TEXTURE_2D, Tex);
    { GL_NEAREST: the texture is read 1:1 via glGetTexImage / image load-store
      and never sampled with filtering, so the filter state stays irrelevant
      and off the driver's sampled-image path. }
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    FnTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    FnTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, W, H);
  end;

begin
  { Drop the cached ISkImages first: they reference the old PBO mappings that
    are about to be (re)created, so they must not outlive their buffers. }
  FSkiaImages[0] := nil;
  FSkiaImages[1] := nil;
  FPBOMaps[0] := nil;
  FPBOMaps[1] := nil;
  if FOutputTex <> 0 then
    FnDeleteTextures(1, @FOutputTex);
  FnGenTextures(1, @FOutputTex);
  SetupTex(FOutputTex);
  { FPixelBuffer stays as the zero-initialised staging area of the classic
    readback fallback; the persistent path below does not touch it per frame. }
  SetLength(FPixelBuffer, W * H * 4);
  FillChar(FPixelBuffer[0], Length(FPixelBuffer), 0);
  FPBOSize := W * H * 4;
  ImgInfo := TSkImageInfo.Create(W, H, TSkColorType.BGRA8888, TSkAlphaType.Premul);
  for I := 0 to 1 do
    if FPBOs[I] <> 0 then
      FnDeleteBuffers(1, @FPBOs[I]);
  FnGenBuffers(2, @FPBOs[0]);
  if FHasBufferStorage then
  begin
    { Immutable, persistently mapped PBOs: glBufferStorage with READ+PERSISTENT
      +COHERENT lets the mapping live for the buffer's whole lifetime, so
      readback needs no per-frame map/unmap. Each PBO gets its own cached
      ISkImage wrapping its mapping (RasterFromPixmap only references the
      pixels, it does not copy), so the draw in RenderEffect can pick the
      image of the PBO that holds the finished frame - zero System.Move per
      frame and no wrapper allocation per frame. }
    for I := 0 to 1 do
    begin
      FnBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
      FnBufferStorage(GL_PIXEL_PACK_BUFFER, FPBOSize, nil, GL_MAP_READ_BIT or GL_MAP_PERSISTENT_BIT or GL_MAP_COHERENT_BIT);
      FPBOMaps[I] := FnMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, FPBOSize, GL_MAP_READ_BIT or GL_MAP_PERSISTENT_BIT or GL_MAP_COHERENT_BIT);
      if Assigned(FPBOMaps[I]) then
        FSkiaImages[I] := TSkImage.MakeFromRaster(ImgInfo, PByte(FPBOMaps[I]), W * 4);
    end;
    { If either mapping failed (driver quirk), the zero-copy path would run
      on a nil image - fall back to the classic path instead of showing mush.
      The PBOs already went through glBufferStorage (immutable storage), so
      they must be deleted and re-created before glBufferData can specify
      them again. }
    if (FPBOMaps[0] = nil) or (FPBOMaps[1] = nil) then
    begin
      FSkiaImages[0] := nil;
      FSkiaImages[1] := nil;
      FPBOMaps[0] := nil;
      FPBOMaps[1] := nil;
      FHasBufferStorage := False;
      for I := 0 to 1 do
        FnDeleteBuffers(1, @FPBOs[I]);
      FnGenBuffers(2, @FPBOs[0]);
      for I := 0 to 1 do
      begin
        FnBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
        FnBufferData(GL_PIXEL_PACK_BUFFER, FPBOSize, nil, GL_STREAM_READ);
      end;
    end;
  end
  else
    for I := 0 to 1 do
    begin
      FnBindBuffer(GL_PIXEL_PACK_BUFFER, FPBOs[I]);
      FnBufferData(GL_PIXEL_PACK_BUFFER, FPBOSize, nil, GL_STREAM_READ);
    end;
  FnBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
  { Classic path (FHasBufferStorage = False, the AMD driver default): cache
    one ISkImage on FPixelBuffer - the staging buffer the fallback
    System.Move fills - so RenderEffect needs no MakeFromRaster allocation
    per frame on this path either. FPixelBuffer was (re)allocated above and
    must never be SetLength'd again afterwards, or this image would point
    into freed heap. }
  if not FHasBufferStorage then
    FSkiaImages[0] := TSkImage.MakeFromRaster(ImgInfo, @FPixelBuffer[0], W * 4);
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
    { Same thread-safety as BuildMeshTargets: the face cloud writes the
      shared CPU particle buffer and count. }
    FDataLock.Enter;
    try
    DepthW := FDepthMap.Width;
    DepthH := FDepthMap.Height;
    BudgetUsed := 0;
    CenterX := DepthW / 2;
    CenterY := (DepthH - 28) / 2;
    FMinY := 10000;
    FMaxY := -10000;
    { Every depth-map face pixel is a region-1 (head) particle, so the head
      bounding box is the face's own extent - tracked below alongside FMinY /
      FMaxY and finalized before returning. }
    FHeadMinX := 10000;
    FHeadMaxX := -10000;
    FHeadMinY := 10000;
    FHeadMaxY := -10000;
    FHeadMinZ := 10000;
    FHeadMaxZ := -10000;
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
          { Face pixels ARE the head region here, so they expand the head
            bounding box on all three axes (Z is the depth-from-brightness). }
          if P.PX < FHeadMinX then
            FHeadMinX := P.PX;
          if P.PX > FHeadMaxX then
            FHeadMaxX := P.PX;
          if P.PY < FHeadMinY then
            FHeadMinY := P.PY;
          if P.PY > FHeadMaxY then
            FHeadMaxY := P.PY;
          if P.PZ < FHeadMinZ then
            FHeadMinZ := P.PZ;
          if P.PZ > FHeadMaxZ then
            FHeadMaxZ := P.PZ;
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
    { Fold the face extent into the head center / size frame before the
      ornament rings (regions 2-4) below only add non-head particles. }
    FinalizeHeadBounds;
    FParticleCount := BudgetUsed;
    finally
      FDataLock.Leave;
    end;
  finally
    FDepthMap.Unmap(BitmapData);
  end;
end;

procedure TSkChaos.UploadSSBO;
begin
  { Do NOT touch GL here: this runs on the UI thread, where FGLContext is
    not current, so glBindBuffer / glBufferSubData would silently fail.
    Just flag the buffer as dirty; RenderEffect uploads it on the render
    thread where the context is bound. }
  FDataLock.Enter;
  try
    if (FParticleCount = 0) or (Length(FParticleCPU) = 0) then
      Exit;
    FSSBODirty := True;
  finally
    FDataLock.Leave;
  end;
end;

procedure TSkChaos.ReinitParticlesForForming;
var
  I: Integer;
  P: ^TParticleCPU;
begin
  { Runs on either thread: startup loads call it from the UI thread while
    the render thread is already dispatching, Spawn / RenderEffect call it
    from the render thread itself. TCriticalSection is re-entrant on the
    same thread, so nested call chains stay safe. }
  FDataLock.Enter;
  try
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
  finally
    FDataLock.Leave;
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

{ Computes the head-rotation trig endpoint vectors and uploads them as the
  uTrigY / uTrigX uniforms. project3D in the shader mixes between these
  endpoints per particle (linear in the smoothstep weight w), which replaces
  the four per-particle sin/cos evaluations with two mix() calls:
    uTrigY = (cos ry_head, sin ry_head, cos ry_shoulder, sin ry_shoulder)
    uTrigX = (cos rx_head, sin rx_head, 1, 0)
  Head angles: ry = -uLookX * 0.4, rx = -uLookY * 0.25 (full rotation w=1);
  shoulder blend factor wy = 0.15 + 0.85 * 0 = 0.15 (w=0); rx has wx = w = 0
  at the shoulders, so the shoulder x-rotation endpoints are cos(0)=1,
  sin(0)=0. The mixed angle is not exactly the angle-weighted original, but
  the visual deviation is bounded (<1 % at mid weights) and it is exact at
  both ends. Called once per frame on the render thread. }
procedure TSkChaos.UploadTrigUniforms(ALocY, ALocX: Integer);
var
  RotY, RotX, Wy: Single;
begin
  RotY := -FLookX * 0.4;
  RotX := -FLookY * 0.25;
  Wy := 0.15; // 0.15 + 0.85 * 0 - shoulder endpoint of the wy blend
  // ry_head = rotY * 1.0 ; ry_shoulder = rotY * 0.15
  FnUniform4f(ALocY, Cos(RotY), Sin(RotY), Cos(RotY * Wy), Sin(RotY * Wy));
  // rx_head = rotX * 1.0 ; rx_shoulder = rotX * 0.0 -> (1, 0)
  FnUniform4f(ALocX, Cos(RotX), Sin(RotX), 1.0, 0.0);
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
  UploadTrigUniforms(FLocP_TrigY, FLocP_TrigX);
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
  { The clear grid follows the live buffer size: mesh resizes swap the
    buffer dimensions, and a fixed grid would leave a smearing border. }
  FnUniform2f(FLocC_Resolution, FBufW, FBufH);
  FnBindImageTexture(0, FOutputTex, 0, 0, 0, GL_WRITE_ONLY, GL_RGBA8);
  GX := (Cardinal(FBufW) + 15) div 16;
  GY := (Cardinal(FBufH) + 15) div 16;
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

procedure TSkChaos.ReadbackToPixelBuffer;
var
  ReadPBO, WritePBO: Cardinal;
  Mapped: Pointer;
begin
  if not (FHasBufferStorage and Assigned(FPBOMaps[0]) and Assigned(FPBOMaps[1])) then
  begin
    { Classic fallback (no glBufferStorage on this driver): map the PBO the
      previous glGetTexImage filled and copy its bytes into FPixelBuffer,
      which the per-frame ISkImage then wraps. }
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
  end;
  { Both paths issue the same download: glGetTexImage into the current write
    PBO. On the persistent path the PBOs stay mapped for their lifetime, and
    last frame's download lands in the read PBO (FPBOIndex already moved on),
    whose mapped bytes the cached FSkiaImages[read index] wrap directly -
    zero-copy. The index flip below must match the draw in RenderEffect. }
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
  DeltaTime: Double;
  ScanSpeed: Single;
  Cur: TPoint;
  C, TopLeft: TPointF;
  Hover: Boolean;
  TargetMul: Single;
  { Idle life / touch force locals: CurValid gates every cursor consumer
    behind one GetCursorPos sample; Local is that sample in control
    coordinates; IdleTarget / IdleHead* shape the rest-pose drift;
    NewLocal* are the buffer-space cursor coordinates for the force
    field's velocity estimate. }
  CurValid: Boolean;
  Local: TPointF;
  IdleTarget: Single;
  IdleHeadX, IdleHeadY: Single;
  NewLocalX, NewLocalY: Single;
begin
  if not Active then
  begin
    inherited RenderEffect(ACanvas, ADest, ATime);
    Exit;
  end;
  { csFinished short-circuit: the despawn animation is over and the overlay
    must stay empty, so skip the entire clear/particle/blur/readback pipeline
    (and its GL dispatches) completely - GPU load in the hidden state drops
    to exactly zero instead of dispatching an empty frame every tick. The
    control is also hidden outright: an invisible FMX control stops the
    compositor from blending its (empty) layer, so DWM cost drops to zero
    too. Visible flips through TThread.Queue because this runs on the
    render thread; Spawn re-shows it. The Sleep(120) paces this branch to
    ~8 wake-ups per second, so the render thread's CPU share sits near
    0 % while the GL context stays warm for the next Spawn. }
  if FState = csFinished then
  begin
    if Visible then
      TThread.Queue(nil,
        procedure
        begin
          { Re-check on the UI thread: Spawn may have re-started the avatar
            between queueing and delivery, and the form may already be
            tearing down (same guard the base class uses for
            ThreadSafeInvalidate). }
          if (csDestroying in ComponentState) then
            Exit;
          if FState = csFinished then
            Visible := False;
        end);
    Sleep(120);
    Exit;
  end;
  { Guard the whole GL path against a zero-sized buffer: before the first
    resize / mesh load settles, EnsureOutputTexture would try to create a
    0x0 texture and the dispatch grid computation would divide by zero. }
  if (FBufW <= 0) or (FBufH <= 0) or (FPendingBufW <= 0) or (FPendingBufH <= 0) then
    Exit;
  if not FGLReady then
  begin
    wglMakeCurrent(0, 0);
    if not InitOffscreenGL then
      Exit;
    { First frame: create the buffer at the requested size. It equals the
      default CHAOS dims unless a mesh was loaded into an already resized
      control before the GL context existed. }
    EnsureOutputTexture(FPendingBufW, FPendingBufH);
    FBufW := FPendingBufW;
    FBufH := FPendingBufH;
    FBufResizePending := False;
    if FSourceType = srcDepthMap then
      GenerateFaceTargets
    else
      BuildMeshTargets(FMeshResult.Points);
    UploadSSBO;
    { Anchor DeltaTime on the init frame: ATime is the monotonic clock the
      base thread started long before the context existed, so without this
      the first csForming step would consume a huge (or negative) delta and
      the scanline jumps, which read as the sporadic startup freeze. }
    FLastTime := ATime;
  end;
  { RenderEffect always runs on the same background render thread of
    TSkiaCustomThreadedBase and nothing else ever binds FGLContext, so the
    context stays current from InitOffscreenGL on - no per-frame
    wglMakeCurrent needed. The lazy bind below runs once, on the first
    frame after the context is created. }
  if not FContextBound then
  begin
    wglMakeCurrent(FDummyDC, FGLContext);
    FContextBound := True;
  end;
  { Deferred buffer resize (SetAvatarSize / LoadMeshFile on the UI thread):
    GL objects may only be recreated with the context current on this
    thread, so requesters just publish FPendingBuf* and flag. Depth-map
    sources stay pinned to the default dims because the legacy pipeline
    renders at a fixed resolution. }
  if FSourceType = srcDepthMap then
  begin
    FPendingBufW := CHAOS_WIDTH;
    FPendingBufH := CHAOS_HEIGHT;
  end;
  if FBufResizePending or (FPendingBufW <> FBufW) or (FPendingBufH <> FBufH) then
  begin
    EnsureOutputTexture(FPendingBufW, FPendingBufH);
    FBufW := FPendingBufW;
    FBufH := FPendingBufH;
    FBufResizePending := False;
    { The cached images now wrap freshly mapped buffers whose contents are
      undefined, so hold the draw off until the next readback fills them. }
    FPBOHasData := False;
  end;
    // Deferred SSBO upload: UploadSSBO only sets FSSBODirty on the UI thread.
    // The actual GL upload must happen here, while FGLContext is current,
    // otherwise glBufferSubData silently fails and the GPU keeps rendering
    // the initial (anime_head_base_mesh) particle cloud no matter how often the CPU
    // buffer changes.
  FDataLock.Enter;
  try
    if FSSBODirty and (FParticleSSBO <> 0) and (FParticleCount > 0) and (Length(FParticleCPU) > 0) then
    begin
      FnBindBuffer(GL_SHADER_STORAGE_BUFFER, FParticleSSBO);
      FnBufferSubData(GL_SHADER_STORAGE_BUFFER, 0, NativeInt(FParticleCount) * SSBO_PARTICLE_SIZE, @FParticleCPU[0]);
      FnBindBuffer(GL_SHADER_STORAGE_BUFFER, 0);
      FSSBODirty := False;
    end;
  finally
    FDataLock.Leave;
  end;

  // Real DeltaTime from the monotonic ATime the base thread passes in.
  if FLastTime = 0 then
    DeltaTime := 1.0 / 60.0
  else
    DeltaTime := ATime - FLastTime;
  FLastTime := ATime;
  if (DeltaTime <= 0) or (DeltaTime > 0.25) then
    DeltaTime := 1.0 / 60.0;

  { Mouse sampling: one GetCursorPos per frame feeds every cursor-driven
    feature - mouse-follow look target, idle-still detection, the saccade /
    drift idle life below and the touch force field. GetCursorPos works
    while the window is click-through (WS_EX_TRANSPARENT), unlike mouse
    messages. The screen point is converted into the control's local frame
    with pure subtraction against the UI-thread-cached origin: the FMX
    scene tree behind ScreenToLocal must not be walked from this render
    thread. }
  CurValid := GetCursorPos(Cur);
  if CurValid then
  begin
    Local.X := Cur.X - FScreenOrigin.X;
    Local.Y := Cur.Y - FScreenOrigin.Y;
  end;
  if CurValid then
  begin
    if (FLastCursorPos.X = -99999) or (Abs(Cur.X - FLastCursorPos.X) > 2) or (Abs(Cur.Y - FLastCursorPos.Y) > 2) then
      FMouseStillTimer := 0
    else
      FMouseStillTimer := FMouseStillTimer + DeltaTime;
    FLastCursorPos := Cur;
  end;
  { Idle crossfade: with mouse-follow off, or once the cursor has rested
    for over 1.4 s, the idle drift / saccade life fades in over half a
    second. Any fresh movement (or re-enabling follow) fades it back out,
    so the idle animation never fights the active tracking. }
  if (not FMouseFollow) or (FMouseStillTimer > 1.4) then
    IdleTarget := 1.0
  else
    IdleTarget := 0.0;
  FIdleBlend := FIdleBlend + (IdleTarget - FIdleBlend) * EnsureRange(2.0 * DeltaTime, 0, 1);

  { Mouse-follow: smoothly steer the look direction toward the cursor,
    or ease back to centre when the option is off. }
  if FMouseFollow then
  begin
    if CurValid and (FControlW > 0) then
    begin
      { Head centre from the cached screen rect - no LocalToScreen here,
        the scene tree is off-limits on the render thread. }
      C := PointF(FScreenOrigin.X + FControlW * 0.5, FScreenOrigin.Y + FControlH * 0.5);
      FLookTargetX := EnsureRange((Cur.X - C.X) / 300, -1.2, 1.2);
      FLookTargetY := EnsureRange((Cur.Y - C.Y) / 300, -0.9, 0.9);
    end;
  end
  else
  begin
    FLookTargetX := 0;
    FLookTargetY := 0;
  end;

  { Idle life: saccades - irregular eye jumps every 0.55-2.65 s. 70 % are
    micro-saccades (barely perceptible freshening of the fixation), 30 %
    are distinct sideways / thinking glances. The offsets persist between
    jumps and are scaled by the idle blend below, so they ebb away while
    the avatar actively tracks the cursor. IdleLifeMotion = False skips
    the re-roll entirely and zeroes the offsets, so the smoothed head
    pose glides back to the plain look target. }
  if FIdleLifeMotion then
  begin
    FSaccadeTimer := FSaccadeTimer - DeltaTime;
    if FSaccadeTimer <= 0 then
    begin
      FSaccadeTimer := 0.55 + Random * 2.1;
      if Random < 0.7 then
      begin
        FSaccadeOffsetX := (Random * 2 - 1) * 0.16;
        FSaccadeOffsetY := (Random * 2 - 1) * 0.12;
      end
      else
      begin
        FSaccadeOffsetX := (Random * 2 - 1) * 0.55;
        FSaccadeOffsetY := (Random * 2 - 1) * 0.35;
      end;
    end;
  end
  else
  begin
    FSaccadeOffsetX := 0;
    FSaccadeOffsetY := 0;
  end;

  { Idle head drift: a multi-sinus breathing / floating pattern (two
    incommensurate frequencies per axis) replaces the rigid (0, 0) rest
    pose. FIdleBlend gates it, so the drift only owns the head while the
    cursor rests or follow is off; IdleLifeMotion = False collapses it
    to zero so the rest pose is perfectly still. }
  if FIdleLifeMotion then
  begin
    IdleHeadX := (Sin(ATime * 0.43) * 0.09 + Sin(ATime * 1.13) * 0.035) * FIdleBlend;
    IdleHeadY := (Sin(ATime * 0.31) * 0.06 + Sin(ATime * 0.87) * 0.025) * FIdleBlend;
  end
  else
  begin
    IdleHeadX := 0;
    IdleHeadY := 0;
  end;

  { Saccade smoothing: the rolled offsets are targets, not instant jumps -
    FSaccadeSmooth* eases toward them at 10/s, so a new fixation glides in
    over roughly a tenth of a second instead of snapping the head within a
    single frame. }
  FSaccadeSmoothX := FSaccadeSmoothX + (FSaccadeOffsetX - FSaccadeSmoothX) * EnsureRange(10.0 * DeltaTime, 0, 1);
  FSaccadeSmoothY := FSaccadeSmoothY + (FSaccadeOffsetY - FSaccadeSmoothY) * EnsureRange(10.0 * DeltaTime, 0, 1);

  { Look model: the whole head - eyes rigidly included - rotates toward the
    look target on the 4.5/s neck-pivot filter (uLookX/uLookY), carrying the
    idle drift and the smoothed saccade offsets. There is no separate eye
    offset any more: the eye particles used to slide out of their sockets
    when pushed sideways, so they now rotate with the skull and isEye is
    purely the dim-blink flag. }
  FLookX := FLookX + ((FLookTargetX + IdleHeadX + FSaccadeSmoothX * (0.35 + 0.65 * FIdleBlend)) - FLookX) * EnsureRange(4.5 * DeltaTime, 0, 1);
  FLookY := FLookY + ((FLookTargetY + IdleHeadY + FSaccadeSmoothY * (0.35 + 0.65 * FIdleBlend)) - FLookY) * EnsureRange(4.5 * DeltaTime, 0, 1);

  { AI head gestures: the gesture springs (impulsed by the AI action tags)
    ride on top of the look model as an additive offset - they never fight
    the tracking because they decay to zero within a second. }
  UpdateGestureSprings(DeltaTime);
  FLookX := EnsureRange(FLookX + FGestureOffsetX * 0.5, -2.5, 2.5);
  FLookY := EnsureRange(FLookY + FGestureOffsetY * 0.5, -2.0, 2.0);

  { 60-FPS lip-sync: while the voice pipeline speaks (or mirrors the live
    microphone in LipSyncOnly mode) the mouth follows the amplitude envelope;
    when silent it eases back to the manual MouthOpen rest value. }
  if FVoicePipeline <> nil then
    UpdateLipSync(DeltaTime);

  { Send-to-monitor jump: the host window was moved by SendToDisplay on
    the UI thread. Park the touch state outside and zero the velocity
    here on the render thread (the fields below are owned by this
    thread once per frame), so the next cursor sample starts from a calm
    field instead of a delta spike across monitors. }
  if TInterlocked.Exchange(FTouchResetPending, 0) <> 0 then
  begin
    FMouseLocalX := -9999;
    FMouseLocalY := -9999;
    FMouseVelX := 0;
    FMouseVelY := 0;
    FMouseInside := False;
  end;

  { Touch force field: while the cursor is over the control its local
    position is scaled into buffer coordinates and the per-frame screen
    delta feeds a smoothed velocity (buffer px / s, clamped to +-800).
    Outside, the position marker goes to (-9999, -9999) so the shader's
    radius test never fires and the velocity decays exponentially, so a
    re-entering cursor starts from a calm field. TouchEffectsEnabled =
    False takes the same outside path unconditionally - no velocity
    tracking, no per-frame state updates, the shader branch never fires. }
  if FTouchEffectsEnabled and (not FDragging) and CurValid and (Local.X >= 0) and (Local.Y >= 0) and (Local.X < FControlW) and (Local.Y < FControlH) then
  begin
    NewLocalX := Local.X * (FBufW / Max(FControlW, 1));
    NewLocalY := Local.Y * (FBufH / Max(FControlH, 1));
    if FMouseInside then
    begin
      FMouseVelX := FMouseVelX * 0.85 + (NewLocalX - FMouseLocalX) / Max(DeltaTime, 0.001) * 0.15;
      FMouseVelY := FMouseVelY * 0.85 + (NewLocalY - FMouseLocalY) / Max(DeltaTime, 0.001) * 0.15;
      FMouseVelX := EnsureRange(FMouseVelX, -800, 800);
      FMouseVelY := EnsureRange(FMouseVelY, -800, 800);
    end
    else
    begin
      FMouseVelX := 0;
      FMouseVelY := 0;
    end;
    FMouseLocalX := NewLocalX;
    FMouseLocalY := NewLocalY;
    FMouseInside := True;
  end
  else
  begin
    FMouseLocalX := -9999;
    FMouseLocalY := -9999;
    FMouseInside := False;
    FMouseVelX := FMouseVelX * 0.85;
    FMouseVelY := FMouseVelY * 0.85;
  end;

  { Auto-dim on hover: the cursor test runs against the cached screen rect
    (FScreenOrigin + FControlW/H, refreshed on the UI thread), so it keeps
    working while the window is click-through (WS_EX_TRANSPARENT never
    delivers WM_MOUSEMOVE - but GetCursorPos always reports the true
    position) and costs nothing on the render thread.
    FCurrentHoverAlphaMul eases toward AUTO_DIM_ALPHA or back to 1.0 with
    AUTO_DIM_SPEED per second; ApplyHoloUniforms multiplies it onto
    uAlpha. }
  if FAutoDimOnHover then
  begin
    Hover := False;
    if CurValid and (FControlW > 0) then
    begin
      TopLeft := PointF(FScreenOrigin.X, FScreenOrigin.Y);
      Hover := (Cur.X >= TopLeft.X) and (Cur.X <= TopLeft.X + FControlW) and
               (Cur.Y >= TopLeft.Y) and (Cur.Y <= TopLeft.Y + FControlH);
    end;
    if Hover then
      TargetMul := AUTO_DIM_ALPHA
    else
      TargetMul := 1.0;
    FCurrentHoverAlphaMul := FCurrentHoverAlphaMul + (TargetMul - FCurrentHoverAlphaMul) * EnsureRange(AUTO_DIM_SPEED * DeltaTime, 0, 1);
  end
  else
    FCurrentHoverAlphaMul := 1.0;

  FGlobalTime := ATime;

  { Procedural auto-blink with a natural rhythm: FBlinkTimer counts up
    through the current pause FNextBlinkDelay, then a blink of slightly
    randomized length runs (BlinkDuration base +- 25 ms). After each blink
    the next pause is re-rolled - 18 % of blinks chain into a double
    blink after only 0.14-0.22 s, the rest pause 1.8-6.2 s with a
    power distribution biased toward shorter gaps, so the rhythm never
    reads as a metronome. FBlinkPhase follows a squared half sine
    (0 -> 1 -> 0): the square eases the fade in and out at both ends of
    the blink instead of snapping. The phase is applied as a factor onto
    FEyeOpeness at upload time (ApplyHoloUniforms), never written back
    into FEyeOpeness itself - the manual EyeState property stays
    authoritative. }
  if FAutoBlink then
  begin
    FBlinkTimer := FBlinkTimer + DeltaTime;
    if FBlinkTimer >= FNextBlinkDelay + FCurrentBlinkDuration then
    begin
      { Completed blink: roll the next pause and the next length. }
      FBlinkTimer := 0;
      if (Random < 0.18) and (not FDoubleBlinkPending) then
      begin
        FDoubleBlinkPending := True;
        FNextBlinkDelay := 0.14 + Random * 0.08;
      end
      else
      begin
        FDoubleBlinkPending := False;
        FNextBlinkDelay := 1.8 + Power(Random, 1.3) * 4.4;
      end;
      FCurrentBlinkDuration := 0.13 + Random * 0.05;
    end;
    if FBlinkTimer >= FNextBlinkDelay then
      FBlinkPhase := Sqr(Sin(Pi * (FBlinkTimer - FNextBlinkDelay) / Max(FCurrentBlinkDuration, 0.02)))
    else
      FBlinkPhase := 0;
  end
  else
    FBlinkPhase := 0;

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

  // Per-frame pipeline: clear -> particles -> readback (blur disabled).
  if FSourceType <> srcDepthMap then
    AdvanceMorphAnimation(DeltaTime);
  DispatchClear;
  if FSourceType = srcDepthMap then
    DispatchFrame(DeltaTime, ATime)
  else
    DispatchHoloFrame(DeltaTime, ATime);
  ReadbackToPixelBuffer;

  ACanvas.Clear($00000000);
  { Persistent path (USE_PERSISTENT_PBO_READBACK = True): draw the cached
    ISkImage of the PBO that holds the last finished frame.
    ReadbackToPixelBuffer flipped FPBOIndex right after its glGetTexImage, so
    FPBOIndex xor 1 is the PBO the previous download filled (frame N-1);
    drawing the write PBO's image instead would show the buffer the GPU is
    currently overwriting. Classic path (AMD driver default):
    FSkiaImages[0] wraps FPixelBuffer, the staging buffer the fallback
    System.Move filled with the finished frame - both paths draw without a
    MakeFromRaster allocation per frame. Nearest sampling: source and
    destination are the exact same size, so it is visually identical and
    skips Skia's resampling filter work. TSkSamplingOptions has no Nearest
    class function - Create(Nearest, None) is the no-filter mode. }
  { The offscreen image is drawn buffer-sized (FBufW x FBufH) onto the
    live control rect: 1:1 when the buffer tracks the control (mesh
    sources after a resize) and a stretch for sources whose buffer stays
    at the default dims. Nearest sampling keeps single-pixel particles
    crisp; the 252 / 236 aspect is preserved by construction. }
  if FPBOHasData and Assigned(FSkiaImages[FPBOIndex xor 1]) then
    ACanvas.DrawImageRect(FSkiaImages[FPBOIndex xor 1], RectF(0, 0, FBufW, FBufH), RectF(0, 0, Width, Height), TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None))
  else if FPBOHasData and Assigned(FSkiaImages[0]) then
    ACanvas.DrawImageRect(FSkiaImages[0], RectF(0, 0, FBufW, FBufH), RectF(0, 0, Width, Height), TSkSamplingOptions.Create(TSkFilterMode.Nearest, TSkMipmapMode.None));

  { The alive highlighter is no longer drawn here: TSkChaos is only a small
    avatar-sized control, which clipped the entity to its rect. The desktop
    overlay control on the host form calls RenderHighlighterOverlay every
    frame instead, so the entity can travel across the whole screen. }
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

{ True when a sub-mesh name refers to eye geometry: it contains "eye"
  (Eye_Eye_0, EyeScleraReflect, MeniscusEyeSpec, Eye_L, Eye_R, ...) but
  neither "lash" nor "brow", so eyelashes and eyebrows keep their normal
  rendering and only the eyeball / sclera meshes blink. }
function IsEyeMeshName(const AName: string): Boolean;
var
  LowName: string;
begin
  LowName := AName.ToLower;
  Result := LowName.Contains('eye') and not LowName.Contains('lash') and not LowName.Contains('brow');
end;

procedure TSkChaos.BuildMeshTargets(const APoints: TArray<TMeshParticlePoint>);
var
  I, BudgetUsed, InnerCap: Integer;
  P: ^TParticleCPU;
  Pos: TPoint3D;
  Region: Cardinal;
  IsHead, MakeInner, IsEyePart, UseCustomEye: Boolean;
begin
  UseCustomEye := (FCustomEyePartName <> '') and (FCustomEyePartName <> '(Auto)');
  { The whole build writes FParticleCPU / FParticleCount; keep it atomic
    against the render thread's SSBO upload so a startup build can never
    interleave with a dispatch reading a half-written cloud. }
  FDataLock.Enter;
  try
  BudgetUsed := 0;
  FMinY := 10000;
  FMaxY := -10000;
  { Head bounding box starts empty; only bpHead particles expand it below. }
  FHeadMinX := 10000;
  FHeadMaxX := -10000;
  FHeadMinY := 10000;
  FHeadMaxY := -10000;
  FHeadMinZ := 10000;
  FHeadMaxZ := -10000;
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
      face colour. Photo / hybrid particles carry their true RGB instead.
      A per-part override set through SetPartColor wins over both and is
      written with the $FE alpha marker the holo shader detects, so it
      survives rebuilds (InnerCore toggle, budget retune, reloads). }
    if (APoints[I].GroupTag < Cardinal(Length(FPartColors))) and (Cardinal(FPartColors[APoints[I].GroupTag]) <> $00000000) then
      P^.Color := (Cardinal(FPartColors[APoints[I].GroupTag]) and $00FFFFFF) or $FE000000
    else if APoints[I].Color = $FFFFFFFF then
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
    { Eye meshes get PARTICLE_FLAG_EYE so the holo shader can dim them on
      blink. A custom eye part (chosen in the controls panel) wins over the
      automatic name heuristic: exactly the part whose GroupTag maps to
      FCustomEyePartName carries the flag. Only the mesh source maps
      GroupTag -> MeshNames; hybrid / photo points carry no usable name
      mapping, so they stay untagged. }
    if (FSourceType = srcMesh) and (APoints[I].GroupTag < Cardinal(Length(FMeshResult.MeshNames))) then
    begin
      if UseCustomEye then
        IsEyePart := MatchesEyePartName(FMeshResult.MeshNames[APoints[I].GroupTag])
      else
        IsEyePart := IsEyeMeshName(FMeshResult.MeshNames[APoints[I].GroupTag]);
    end
    else
      IsEyePart := False;
    { Expand the head bounding box while walking the points - the mouth
      deformation in the shader needs the head-local coordinate frame. }
    if IsHead then
    begin
      if Pos.X < FHeadMinX then
        FHeadMinX := Pos.X;
      if Pos.X > FHeadMaxX then
        FHeadMaxX := Pos.X;
      if Pos.Y < FHeadMinY then
        FHeadMinY := Pos.Y;
      if Pos.Y > FHeadMaxY then
        FHeadMaxY := Pos.Y;
      if Pos.Z < FHeadMinZ then
        FHeadMinZ := Pos.Z;
      if Pos.Z > FHeadMaxZ then
        FHeadMaxZ := Pos.Z;
    end;
    { Every third head particle becomes an inner brain-core point so the
      volumetric style forms a pulsating inner layer (~33 %). }
    MakeInner := FInnerCore and IsHead and ((I mod 3) = 0);
    P^.Flags := Region;
    if MakeInner then
      P^.Flags := P^.Flags or PARTICLE_FLAG_INNER_CORE;
    if IsEyePart then
      P^.Flags := P^.Flags or PARTICLE_FLAG_EYE;
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
  { Fold the head min/max into the center / size uniforms frame before the
    inner-core emission below places its points around the head centre. }
  FinalizeHeadBounds;
  { Custom inner core / brain mesh: emitted after the outer cloud so the
    shell keeps its own budget, and capped by the remaining PARTICLE_MAX
    room. Each point is scaled around the head centre (FInnerCoreOffsetY
    lifts it toward the crown), flagged region 1 + INNER_CORE so it moves
    with the head / neck pivot, and tinted per part or with the accent
    colour through the $FE marker so the core reads in its own colour in
    every style. Inner points are interior to the head, so they never
    expand the bounds or the scanline range. }
  if FInnerCore and (Length(FInnerMeshResult.Points) > 0) then
  begin
    { Remember where the custom core slice starts and how many points it
      has: UpdateInnerCoreTargets rewrites exactly this range on scale /
      offset changes instead of rebuilding the whole cloud. }
    FInnerCoreStartIdx := BudgetUsed;
    InnerCap := Min(Integer(FInnerCoreBudget), PARTICLE_MAX - BudgetUsed);
    for I := 0 to High(FInnerMeshResult.Points) do
    begin
      if InnerCap <= 0 then
        Break;
      P := @FParticleCPU[BudgetUsed * SSBO_PARTICLE_SIZE];
      FillChar(P^, SSBO_PARTICLE_SIZE, 0);
      Pos := TPoint3D.Create(FInnerMeshResult.Points[I].Position.X * FInnerCoreScale + FHeadCenter.X, FInnerMeshResult.Points[I].Position.Y * FInnerCoreScale + FHeadCenter.Y + FInnerCoreOffsetY, FInnerMeshResult.Points[I].Position.Z * FInnerCoreScale + FHeadCenter.Z);
      P^.PX := Pos.X;
      P^.PY := Pos.Y;
      P^.PZ := Pos.Z;
      P^.TX := Pos.X;
      P^.TY := Pos.Y;
      P^.TZ := Pos.Z;
      if (FInnerMeshResult.Points[I].GroupTag < Cardinal(Length(FInnerPartColors))) and (Cardinal(FInnerPartColors[FInnerMeshResult.Points[I].GroupTag]) <> $00000000) then
        P^.Color := (Cardinal(FInnerPartColors[FInnerMeshResult.Points[I].GroupTag]) and $00FFFFFF) or $FE000000
      else
        P^.Color := (Cardinal(FAccentColor) and $00FFFFFF) or $FE000000;
      P^.Flags := 1 or PARTICLE_FLAG_INNER_CORE;
      { Pack the core surface normal so rim light and solid-style shading
        keep working on the inner layer. }
      P^.Pad0 := Cardinal(ClampNormal16(FInnerMeshResult.Points[I].Normal.X)) or (Cardinal(ClampNormal16(FInnerMeshResult.Points[I].Normal.Y)) shl 16);
      P^.Pad1 := Cardinal(ClampNormal16(FInnerMeshResult.Points[I].Normal.Z));
      Inc(BudgetUsed);
      Dec(InnerCap);
    end;
    FInnerCoreCount := BudgetUsed - FInnerCoreStartIdx;
  end
  else
    FInnerCoreCount := 0;
  FParticleCount := BudgetUsed;
  finally
    FDataLock.Leave;
  end;
end;

procedure TSkChaos.FinalizeHeadBounds;
begin
  { Degenerate case (no head points at all, e.g. a mesh without bpHead):
    keep the box empty but well-defined so the uniforms still upload. The
    Max(..., 1) clamps below stop a division by ~0 in the shader's
    rel = (tgt - uHeadCenter.xyz) / uHeadSize.xyz. }
  FHeadCenter := TPoint3D.Create((FHeadMinX + FHeadMaxX) * 0.5, (FHeadMinY + FHeadMaxY) * 0.5, (FHeadMinZ + FHeadMaxZ) * 0.5);
  FHeadSize := TPoint3D.Create(Max(1.0, FHeadMaxX - FHeadMinX), Max(1.0, FHeadMaxY - FHeadMinY), Max(1.0, FHeadMaxZ - FHeadMinZ));
end;

procedure TSkChaos.RebuildTargetCloud;
begin
  { Depth-map sources build their cloud in GenerateFaceTargets without
    inner-core support, and an empty point set has nothing to rebuild. }
  if not FGLReady or (FSourceType = srcDepthMap) or (Length(FMeshResult.Points) = 0) then
    Exit;
  BuildMeshTargets(FMeshResult.Points);
  ReinitParticlesForForming;
  FState := csForming;
  FBuildScanY := FMinY;
  FDespawnScanY := FMinY;
  EnsureVisibleForSpawn;
end;

procedure TSkChaos.SetPartColor(AIndex: Integer; AColor: TAlphaColor);
var
  I: Integer;
  Stored: Cardinal;
  P: ^TParticleCPU;
begin
  { FPartColors is parallel to MeshNames, so a valid index requires a loaded
    mesh; photo / hybrid / depth sources have no parts to tint. }
  if (AIndex < 0) or (AIndex >= Length(FPartColors)) then
    Exit;
  FPartColors[AIndex] := AColor;
  { $00000000 means "default": the part falls back to the face / style
    colour, encoded as the plain white the build path maps to FFaceColor.
    Custom colours carry the $FE alpha marker so the holo shader replaces
    uFaceColor with them while ordinary $FF colours keep the uniform. }
  if Cardinal(AColor) = $00000000 then
    Stored := $FFFFFFFF
  else
    Stored := (Cardinal(AColor) and $00FFFFFF) or $FE000000;
  { Rewrite the live particles of that part directly and flag the SSBO
    dirty: the render thread uploads it on its next pass, so the new tint
    appears without reloading the mesh. }
  FDataLock.Enter;
  try
    for I := 0 to Integer(FParticleCount) - 1 do
    begin
      if I > High(FMeshResult.Points) then
        Break;
      if FMeshResult.Points[I].GroupTag = Cardinal(AIndex) then
      begin
        P := @FParticleCPU[I * SSBO_PARTICLE_SIZE];
        P^.Color := Stored;
      end;
    end;
  finally
    FDataLock.Leave;
  end;
  UploadSSBO;
  NotifyActivity;
end;

function TSkChaos.GetPartColor(AIndex: Integer): TAlphaColor;
begin
  if (AIndex < 0) or (AIndex >= Length(FPartColors)) then
    Exit($00000000);
  Result := FPartColors[AIndex];
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
  { Live buffer size: the world-to-screen centre offset and the bounds
    checks in the shader follow the (possibly resized) buffer. }
  FnUniform2f(FLocH_Resolution, FBufW, FBufH);
  FnUniform1ui(FLocH_ParticleCount, FParticleCount);
  FnUniform1i(FLocH_State, StateInt);
  FnUniform1f(FLocH_BuildScanY, FBuildScanY);
  FnUniform1f(FLocH_DespawnScanY, FDespawnScanY);
  FnUniform1f(FLocH_LookX, FLookX);
  FnUniform1f(FLocH_LookY, FLookY);
  { Touch force field: cursor in buffer space (-9999 = outside, the shader's
    38 px radius test can never match that) plus the smoothed cursor
    velocity for the carry-along swirl. }
  FnUniform2f(FLocH_MouseLocal, FMouseLocalX, FMouseLocalY);
  FnUniform2f(FLocH_MouseVel, FMouseVelX, FMouseVelY);
  { Touch effect variant + accent colour; the colour's alpha byte is
    unused (brightness comes from touchInfluence), so only RGB goes up
    as the vec3 the shader expects. }
  FnUniform1i(FLocH_TouchEffectStyle, Ord(FTouchEffectStyle));
  ColorToVec4(FTouchEffectColor, R, G, B, A);
  FnUniform3f(FLocH_TouchEffectColor, R, G, B);
  FnUniform1f(FLocH_PivotY, FPivotY);
  UploadTrigUniforms(FLocH_TrigY, FLocH_TrigX);
  FnUniform1i(FLocH_HoloStyle, Ord(FHoloStyle));
  FnUniform1f(FLocH_ParticleSize, FParticleSize);
  FnUniform1f(FLocH_GlowIntensity, FGlowIntensity);
  FnUniform1f(FLocH_RimLightStrength, FRimLightStrength);
  { uAlpha carries the manual HoloAlpha multiplied by the hover dim factor:
    the shader has no separate uniform for the auto-dim, so the product
    keeps every style's fade behaviour working unchanged. }
  FnUniform1f(FLocH_Alpha, FHoloAlpha * FCurrentHoverAlphaMul);
  FnUniform1f(FLocH_Jitter, FJitterAmount);
  ColorToVec4(FFaceColor, R, G, B, A);
  FnUniform4f(FLocH_FaceColor, R, G, B, A);
  ColorToVec4(FAccentColor, R, G, B, A);
  FnUniform4f(FLocH_AccentColor, R, G, B, A);
  { Facial animation: jaw factor, blink-dimmed eye openness and the
    head-local frame. The head center / size already carry the >= 1 clamp
    from FinalizeHeadBounds, so the shader's rel division is safe; .w stays
    0 (vec4 uniforms, unused fourth channel). }
  FnUniform1f(FLocH_MouthOpen, FMouthOpen);
  FnUniform1f(FLocH_EyeOpeness, FEyeOpeness * (1.0 - FBlinkPhase));
  FnUniform4f(FLocH_HeadCenter, FHeadCenter.X, FHeadCenter.Y, FHeadCenter.Z, 0);
  FnUniform4f(FLocH_HeadSize, Max(1.0, FHeadSize.X), Max(1.0, FHeadSize.Y), Max(1.0, FHeadSize.Z), 0);
  { Custom inner-mesh flag: a loaded core mesh carries its own scale /
    offset placement, so the shader skips the procedural 0.55 centre
    shrink for those particles. }
  FnUniform1i(FLocH_CustomInnerMesh, Integer(Length(FInnerMeshResult.Points) > 0));
  { Appearance split: the outer shell reads uSoftness / uRimPower, the
    inner core reads the packed uInnerAppearance vector. }
  FnUniform1f(FLocH_Softness, FSoftness);
  FnUniform1f(FLocH_RimPower, FRimPower);
  FnUniform4f(FLocH_InnerAppearance, FInnerGlow, FInnerParticleSize, FInnerSoftness, FInnerRimPower);
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
  FDataLock.Enter;
  try
    { The outer cloud and the custom inner core share FParticleCPU: the
      morph sequence only animates outer mesh points, so stop at the core
      slice marker - writing further would smear outer frame data over
      the core's placement (its targets belong to UpdateInnerCoreTargets,
      not to the morph track). }
    for I := 0 to Integer(FParticleCount) - 1 do
    begin
      if (FInnerCoreCount > 0) and (I >= FInnerCoreStartIdx) then
        Break;
      if I > High(FMeshResult.Points) then
        Break;
      P := @FParticleCPU[I * SSBO_PARTICLE_SIZE];
      P^.TX := FMeshResult.Points[I].Position.X;
      P^.TY := FMeshResult.Points[I].Position.Y;
      P^.TZ := FMeshResult.Points[I].Position.Z;
    end;
  finally
    FDataLock.Leave;
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
  ExePath: string;
  SR: TSearchRec;
begin
  { Default mesh at first start: anime_head_base_mesh.glb directly next to the
    executable or in its assets/ subfolder. If neither exists, fall back
    to the first .glb / .obj found beside the exe so any demo mesh loads
    regardless of filename; an empty result leaves the avatar in the
    clean waiting state (csIdle, no crash) until the user loads a mesh
    through the panel. }
  Result := '';
  ExePath := ExtractFilePath(ParamStr(0));
  if FileExists(ExePath + 'anime_head_base_mesh.glb') then
    Exit(ExePath + 'anime_head_base_mesh.glb');
  if FileExists(ExePath + 'assets\anime_head_base_mesh.glb') or FileExists(ExePath + 'assets/anime_head_base_mesh.glb') then
    Exit(ExePath + 'assets\anime_head_base_mesh.glb');
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
  NewResult: TMeshLoadResult;
  I: Integer;
  NewMesh: Boolean;
begin
  { Only a genuinely fresh mesh open re-applies the per-mesh preset; the
    same-file retunes below (part toggles, budget / step changes, resizes)
    must keep the live state they were called to change. }
  NewMesh := not SameText(AFileName, FCurrentMeshFile);
  try
    Opt := TMeshLoadOptions.Default;
    Opt.TargetRadius := ATargetRadius;
    Opt.Step := Max(1, AStep);
    Opt.MaxParticles := AMaxParticles;
    Opt.IncludeNames := FMeshIncludeNames;
    { A custom eye part must survive the loader's auto-exclude keywords
      (cornea / sclera / iris / pupil ...): KeepName re-admits exactly that
      part in automatic mode, while a manual include list already bypasses
      the exclude keywords on its own. The same MatchesEyePartName fallback
      (exact or substring) applies, so a near-miss selection still keeps
      the intended eyeball part alive. }
    if (FCustomEyePartName <> '') and (FCustomEyePartName <> '(Auto)') then
      Opt.KeepName := FCustomEyePartName;
    { Load into a temp first so a corrupt/empty file cannot leave the avatar in
      a half-overwritten state - the old mesh stays live until the new one is
      fully parsed, then we swap atomically. }
    NewResult := TYutaniMeshLoader.LoadFromFile(AFileName, Opt);
    { Per-part colours index into MeshNames. A genuinely new file gets a
      fresh all-default table (the old GroupTag mapping is meaningless for
      it); a same-file reload - part toggle, budget or step retune - keeps
      the overrides so tints survive ReloadCurrentSource. }
    if not SameText(AFileName, FCurrentMeshFile) then
    begin
      SetLength(FPartColors, Length(NewResult.MeshNames));
      for I := 0 to High(FPartColors) do
        FPartColors[I] := $00000000;
    end;
    FCurrentMeshFile := AFileName;
    FMeshResult := NewResult;
    FMeshBase := Copy(FMeshResult.Points);
    FMeshScale := FMeshResult.Scale;
    FMeshFlipY := Opt.FlipY;
    FSourceType := srcMesh;
    { Mesh clouds are authored in control-sized world units, so the
      offscreen buffer follows the control; RenderEffect applies the swap
      with the GL context current. }
    FPendingBufW := Max(Round(Width), 32);
    FPendingBufH := Max(Round(Height), 32);
    if (FPendingBufW <> FBufW) or (FPendingBufH <> FBufH) then
      FBufResizePending := True;
    SetLength(FMorphWeights, Length(FMeshResult.MorphTargets));
    FActiveSequence := -1;
    FAnimTime := 0;
    { Wipe the morph target cache so ApplyCurrentMorph (which the render thread
      re-calls on resume) does not pull stale base/delta arrays sized for the
      previous mesh. Re-applying with the now-empty base is a no-op until the
      buffer is rebuilt below. }
    ApplyCurrentMorph;
    { Force-clear the active particle count before rebuilding so a shorter new
      mesh cannot leak the previous mesh's leftover particles (BuildMeshTargets
      only writes up to Length(Points); anything beyond stayed stale before). }
    FParticleCount := 0;
    if FGLReady then
    begin
      BuildMeshTargets(FMeshResult.Points);
      { Wipe stale positions and restart the spawn animation so the previous
        mesh/photo cloud cannot bleed through as a morphing mix. }
      ReinitParticlesForForming;
      FState := csForming;
      FBuildScanY := FMinY;
      FDespawnScanY := FMinY;
      EnsureVisibleForSpawn;
    end;
  finally
     //...
  end;
  { Automatic preset restore: a fresh mesh open re-applies the setup saved
    for this head, so re-opening a previously configured avatar brings
    back its colours, inner brain, style and placement. FLoadingPreset
    keeps a preset application itself from re-entering here. }
  if NewMesh and not FLoadingPreset then
    LoadPresetFromFile(GetAutoPresetPath);
  NotifyActivity;
end;

procedure TSkChaos.LoadPhotoFile(const AFileName: string; ATargetRadius: Single; AStep: Integer; AMaxParticles: Integer);
var
  Opt: TPhotoLoadOptions;
  Pts: TArray<TMeshParticlePoint>;
  WasActive: Boolean;
begin
  { Same Stop-Clear-Load-Restart sequence as LoadMeshFile: the render thread's
    ApplyCurrentMorph path would otherwise clobber the freshly swapped
    FMeshResult.Points with the stale FMeshBase before the new photo cloud can
    form. Pause, drain one frame, swap, then resume. }
  WasActive := Active;
  if WasActive then
  begin
    Active := False;
    Sleep(20);
  end;
  try
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
    { Photo points carry no GroupTag -> MeshNames mapping, so per-part
      overrides cannot apply; drop them so a stale entry cannot tint the
      whole photo cloud through its default GroupTag of 0. }
    FPartColors := nil;
    FMeshBase := Copy(Pts);
    FMeshScale := 1.0;
    FMeshFlipY := Opt.FlipY;
    FSourceType := srcPhoto;
    SetLength(FMorphWeights, 0);
    FActiveSequence := -1;
    FAnimTime := 0;
    FParticleCount := 0;
    if FGLReady then
    begin
      BuildMeshTargets(Pts);
      ReinitParticlesForForming;
      FState := csForming;
      FBuildScanY := FMinY;
      FDespawnScanY := FMinY;
      EnsureVisibleForSpawn;
    end;
  finally
    if WasActive then
      Active := True;
  end;
  NotifyActivity;
end;

procedure TSkChaos.LoadHybrid(const AMeshFile, APhotoFile: string);
var
  MeshOpt: TMeshLoadOptions;
  PhotoOpt: TPhotoLoadOptions;
  MeshPts, PhotoPts: TArray<TMeshParticlePoint>;
  Base, I: Integer;
  WasActive: Boolean;
begin
  { Same Stop-Clear-Load-Restart guard so the render thread cannot clobber the
    freshly stitched cloud with the previous mesh's base points. }
  WasActive := Active;
  if WasActive then
  begin
    Active := False;
    Sleep(20);
  end;
  try
    MeshOpt := TMeshLoadOptions.Default;
    MeshOpt.TargetRadius := 180.0;
    MeshOpt.Step := 1;
    MeshOpt.MaxParticles := 90000;
    MeshOpt.IncludeNames := FMeshIncludeNames;
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
    { Hybrid stitches mesh and photo points without a GroupTag -> name
      mapping, so per-part overrides cannot apply here either. }
    FPartColors := nil;
    FMeshBase := Copy(FMeshResult.Points);
    FMeshScale := 1.0;
    FMeshFlipY := True;
    FSourceType := srcHybrid;
    SetLength(FMorphWeights, 0);
    FActiveSequence := -1;
    FAnimTime := 0;
    FParticleCount := 0;
    if FGLReady then
    begin
      BuildMeshTargets(FMeshResult.Points);
      { Wipe stale positions and restart the spawn animation so the previous
        mesh/photo cloud cannot bleed through as a morphing mix. }
      ReinitParticlesForForming;
      FState := csForming;
      FBuildScanY := FMinY;
      FDespawnScanY := FMinY;
      EnsureVisibleForSpawn;
    end;
  finally
    if WasActive then
      Active := True;
  end;
  NotifyActivity;
end;

procedure TSkChaos.ReloadCurrentSource;
begin
  { Re-loads the user's most recent mesh/photo pick with the current
    StepFilter / ParticleBudget / MeshIncludeNames. Lets the controls panel
    live-toggle body parts (and re-tune the budget) without remembering the
    path itself. A depth-map source has no file-based reload path. }
  if (FSourceType = srcMesh) and (FCurrentMeshFile <> '') then
    LoadMeshFile(FCurrentMeshFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget)
  else if (FSourceType = srcPhoto) and (FCurrentPhotoFile <> '') then
    LoadPhotoFile(FCurrentPhotoFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget);
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

procedure TSkChaos.SetSoftness(const Value: Single);
begin
  if FSoftness <> Value then
    FSoftness := EnsureRange(Value, 0.10, 1.00);
end;

procedure TSkChaos.SetRimPower(const Value: Single);
begin
  if FRimPower <> Value then
    FRimPower := EnsureRange(Value, 0.50, 6.00);
end;

procedure TSkChaos.SetInnerGlow(const Value: Single);
begin
  if FInnerGlow <> Value then
    FInnerGlow := EnsureRange(Value, 0.0, 2.0);
end;

procedure TSkChaos.SetInnerParticleSize(const Value: Single);
begin
  if FInnerParticleSize <> Value then
    FInnerParticleSize := EnsureRange(Value, 0.30, 4.00);
end;

procedure TSkChaos.SetInnerSoftness(const Value: Single);
begin
  if FInnerSoftness <> Value then
    FInnerSoftness := EnsureRange(Value, 0.10, 1.00);
end;

procedure TSkChaos.SetInnerRimPower(const Value: Single);
begin
  if FInnerRimPower <> Value then
    FInnerRimPower := EnsureRange(Value, 0.50, 6.00);
end;

procedure TSkChaos.SetBlinkDuration(const Value: Single);
begin
  { The blink phase divides by the duration, so keep it off zero; the
    lower bound also keeps a blink on screen for at least a few frames. }
  FBlinkDuration := EnsureRange(Value, 0.02, 2.0);
end;

procedure TSkChaos.SetNaturalBlinking(const Value: Boolean);
begin
  { Turning natural blinking off mid-blink must leave the eyes open, not
    frozen at the current (possibly closed) phase; pin the phase right
    away so the next upload reopens them. Turning it on simply lets the
    timer continue from the current position. }
  if FAutoBlink <> Value then
  begin
    FAutoBlink := Value;
    if not Value then
    begin
      FBlinkPhase := 0;
      FBlinkTimer := 0;
    end;
  end;
end;

procedure TSkChaos.SetHighlightFollowMouse(const Value: Boolean);
begin
  { Enabling follow keeps the highlighter stalking the cursor, so the
    full-desktop overlay must render again right away: fire the wake hook
    to un-hide its sleeping control. Disabling it does not - the entity's
    exit animation still needs frames, and HighlighterBusy covers the
    wind-down. }
  if Value and (not FHighlightFollowMouse) and Assigned(FOnHighlighterWake) then
    FOnHighlighterWake(Self);
  FHighlightFollowMouse := Value;
end;

procedure TSkChaos.EnsureVisibleForSpawn;
begin
  { Called on the UI thread by every path that restarts the forming
    animation. The csFinished branch of RenderEffect hides the control
    (render thread, via TThread.Queue); without re-showing it here a
    mesh swap or Spawn would run the whole forming animation while the
    control stays invisible. }
  if not Visible then
    Visible := True;
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
  { Re-appear after the csFinished sleep; Spawn runs on the UI thread
    (tray menu), so flipping Visible directly is thread-safe. }
  EnsureVisibleForSpawn;
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
  { Persist the current head before the app goes down: position, size,
    auto-dim, neck pivot, custom eye part and FPS tiers all live in the
    per-mesh preset slot, so the next start continues this session without
    a manual "Save preset for this head". Runs here on the caller (UI)
    thread where the placement state lives, covering both exit paths -
    the immediate quit below and the despawn-then-quit route. }
  try
    SaveCurrentMeshPreset;
  except
    { A read-only preset folder must never block quitting. }
  end;
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
    RebuildTargetCloud;
    NotifyActivity;
  end;
end;

procedure TSkChaos.UpdateInnerCoreTargets;
var
  I, J: Integer;
  P: ^TParticleCPU;
begin
  { Instant retarget of the custom inner core: rewrite the TX/TY/TZ of
    the core slice recorded by BuildMeshTargets (same placement formula:
    scaled around the head centre, lifted by the offset) under the data
    lock, then flag the SSBO for the render thread's deferred upload. The
    spring physics in the shader eases the core particles toward the new
    targets, so the brain visibly morphs into place - no cloud rebuild,
    no re-run of the forming scanline animation. Guards: no custom core
    mesh points, no emitted slice, or an out-of-range marker (stale after
    a budget change rebuild) fall back to doing nothing; the regular
    rebuild paths still place the core correctly in those cases. }
  if (Length(FInnerMeshResult.Points) = 0) or (not FInnerCore) or
     (FInnerCoreCount <= 0) or (FInnerCoreStartIdx < 0) then
    Exit;
  if FInnerCoreStartIdx + FInnerCoreCount > Length(FParticleCPU) then
    Exit;
  FDataLock.Enter;
  try
    if FInnerCoreCount > Length(FInnerMeshResult.Points) then
      Exit;
    for I := 0 to FInnerCoreCount - 1 do
    begin
      J := FInnerCoreStartIdx + I;
      P := @FParticleCPU[J * SSBO_PARTICLE_SIZE];
      P^.TX := FInnerMeshResult.Points[I].Position.X * FInnerCoreScale + FHeadCenter.X;
      P^.TY := FInnerMeshResult.Points[I].Position.Y * FInnerCoreScale + FHeadCenter.Y + FInnerCoreOffsetY;
      P^.TZ := FInnerMeshResult.Points[I].Position.Z * FInnerCoreScale + FHeadCenter.Z;
    end;
  finally
    FDataLock.Leave;
  end;
  UploadSSBO;
end;

procedure TSkChaos.SetInnerCoreScale(const Value: Single);
begin
  if FInnerCoreScale <> Value then
  begin
    FInnerCoreScale := EnsureRange(Value, 0.10, 1.20);
    { Instant path: with a custom core mesh loaded the core slice is
      rewritten in place (the placement formula only depends on scale,
      offset and the head centre), so dragging the slider morphs the
      brain live. Only the procedural-core / no-mesh cases still need
      the full rebuild, and those have no core slice to retarget anyway. }
    if (Length(FInnerMeshResult.Points) > 0) and FInnerCore and (FInnerCoreCount > 0) then
      UpdateInnerCoreTargets
    else
      RebuildTargetCloud;
    NotifyActivity;
  end;
end;

procedure TSkChaos.SetInnerCoreOffsetY(const Value: Single);
begin
  if FInnerCoreOffsetY <> Value then
  begin
    FInnerCoreOffsetY := EnsureRange(Value, -80.0, 80.0);
    { Same instant path as SetInnerCoreScale: rewrite the core slice's
      targets instead of rebuilding the cloud and restarting the forming
      animation. }
    if (Length(FInnerMeshResult.Points) > 0) and FInnerCore and (FInnerCoreCount > 0) then
      UpdateInnerCoreTargets
    else
      RebuildTargetCloud;
    NotifyActivity;
  end;
end;

procedure TSkChaos.SetInnerCoreBudget(const Value: Cardinal);
begin
  if FInnerCoreBudget <> Value then
  begin
    FInnerCoreBudget := Value;
    { The loader clips the stored core points at MaxParticles on load, so
      raising the budget needs a fresh parse of the same file; without a
      file (or when lowering) a plain rebuild re-samples the stored points. }
    if FInnerMeshFile <> '' then
      LoadInnerMeshFile(FInnerMeshFile)
    else
      RebuildTargetCloud;
    NotifyActivity;
  end;
end;

procedure TSkChaos.LoadInnerMeshFile(const AFileName: string);
var
  Opt: TMeshLoadOptions;
  NewResult: TMeshLoadResult;
  I: Integer;
begin
  Opt := TMeshLoadOptions.Default;
  Opt.TargetRadius := Min(Width, Height) * 0.45;
  Opt.MaxParticles := Integer(FInnerCoreBudget);
  { Parse into a temp first so a corrupt or empty file cannot leave the
    live inner layer half-swapped; the swap below is atomic. }
  NewResult := TYutaniMeshLoader.LoadFromFile(AFileName, Opt);
  { A genuinely new file gets a fresh all-default tint table (the previous
    GroupTag mapping is meaningless for it); a same-file retune keeps the
    overrides so lobe colours survive reloads. }
  if not SameText(AFileName, FInnerMeshFile) then
  begin
    SetLength(FInnerPartColors, Length(NewResult.MeshNames));
    for I := 0 to High(FInnerPartColors) do
      FInnerPartColors[I] := $00000000;
  end;
  FInnerMeshFile := AFileName;
  FInnerMeshResult := NewResult;
  { Loading a core mesh implies the inner layer is wanted; the rebuild
    emits its points into the head right away. }
  FInnerCore := True;
  RebuildTargetCloud;
  NotifyActivity;
end;

procedure TSkChaos.ClearInnerMesh;
begin
  { Drop the custom core mesh and its tints so the inner layer falls back
    to the procedural inner head points while InnerCore stays on. }
  FInnerMeshFile := '';
  FInnerMeshResult.Points := nil;
  FInnerMeshResult.MorphTargets := nil;
  FInnerMeshResult.VertexFrames := nil;
  FInnerMeshResult.MeshNames := nil;
  FInnerPartColors := nil;
  RebuildTargetCloud;
  NotifyActivity;
end;

procedure TSkChaos.SetInnerPartColor(AIndex: Integer; AColor: TAlphaColor);
var
  I, J: Integer;
  Stored: Cardinal;
  P: ^TParticleCPU;
begin
  { FInnerPartColors is parallel to InnerMeshNames, so a valid index
    requires a loaded core mesh. }
  if (AIndex < 0) or (AIndex >= Length(FInnerPartColors)) then
    Exit;
  FInnerPartColors[AIndex] := AColor;
  { The core always carries the $FE marker; $00000000 ("default") maps back
    to the accent colour, matching the build path's fallback. }
  if Cardinal(AColor) = $00000000 then
    Stored := (Cardinal(FAccentColor) and $00FFFFFF) or $FE000000
  else
    Stored := (Cardinal(AColor) and $00FFFFFF) or $FE000000;
  { The custom core particles follow the outer cloud in the buffer, emitted
    in FInnerMeshResult.Points order: BuildMeshTargets records the exact
    slice (FInnerCoreStartIdx / FInnerCoreCount), so rewrite exactly that
    range via the markers - the old OuterCount estimate drifted whenever
    the outer budget clipped below the stored point count. }
  FDataLock.Enter;
  try
    if FInnerCoreCount > 0 then
      for I := FInnerCoreStartIdx to FInnerCoreStartIdx + FInnerCoreCount - 1 do
      begin
        J := I - FInnerCoreStartIdx;
        if FInnerMeshResult.Points[J].GroupTag = Cardinal(AIndex) then
        begin
          P := @FParticleCPU[I * SSBO_PARTICLE_SIZE];
          P^.Color := Stored;
        end;
      end;
  finally
    FDataLock.Leave;
  end;
  UploadSSBO;
  NotifyActivity;
end;

function TSkChaos.GetInnerPartColor(AIndex: Integer): TAlphaColor;
begin
  if (AIndex < 0) or (AIndex >= Length(FInnerPartColors)) then
    Exit($00000000);
  Result := FInnerPartColors[AIndex];
end;

procedure TSkChaos.HighlightPoint(AX, AY: Single);
begin
  { Forward the screen point to the alive entity; RenderEffect updates and
    draws it on the render thread. The wake hook lets the full-desktop
    overlay host un-hide itself at once - its render loop sleeps at 120 ms
    while idle and would otherwise only notice the busy flag on its next
    wake-up. }
  if Assigned(FHighlighter) then
    FHighlighter.SendToPoint(PointF(AX, AY));
  if Assigned(FOnHighlighterWake) then
    FOnHighlighterWake(Self);
end;

procedure TSkChaos.HighlightRect(const ARect: TRectF);
begin
  { The entity flies to the rectangle and orbits its centre; the wake hook
    promotes the overlay host out of its idle sleep immediately. }
  if Assigned(FHighlighter) then
    FHighlighter.SendToRect(ARect);
  if Assigned(FOnHighlighterWake) then
    FOnHighlighterWake(Self);
end;

procedure TSkChaos.DismissHighlight;
begin
  { The exit animation walks the entity off-screen, so the overlay clears
    without a hard cut. }
  if Assigned(FHighlighter) then
    FHighlighter.ExitToVoid;
end;

function TSkChaos.HighlighterBusy: Boolean;
begin
  { Busy = anything left to animate: alive, approaching / orbiting, or
    still walking out (ssExiting keeps FActive True until ResetToIdle).
    An idle entity plus inactive mouse-follow lets the overlay skip its
    per-frame work completely. }
  Result := Assigned(FHighlighter) and
    (FHighlighter.Active or FHighlightFollowMouse);
end;

procedure TSkChaos.SetHighlighterBounds(AWidth, AHeight: Single);
begin
  { The entity's wall / boundary model mirrors the caller's canvas - the
    full-desktop overlay - so walls repel at the screen edges and the exit
    animation aims off-screen, not off the small avatar rect. }
  if Assigned(FHighlighter) then
    FHighlighter.SetBounds(AWidth, AHeight);
end;

procedure TSkChaos.RenderHighlighterOverlay(const ACanvas: ISkCanvas; ADeltaTime: Single; AMouseX, AMouseY: Single; AHasMouse: Boolean);
var
  DirtyRect: TRect;
begin
  if not Assigned(FHighlighter) then
    Exit;
  { Tint from the live accent colour, then mouse-follow: the caller passes
    the cursor already converted into its own (overlay) frame; FollowPoint
    moves only the goal, so a per-frame retarget keeps the tail flowing
    instead of re-spawning. }
  FHighlighter.Color := FAccentColor;
  if FHighlightFollowMouse and AHasMouse then
  begin
    FHighlighter.UpdateMousePos(AMouseX, AMouseY);
    FHighlighter.FollowPoint(PointF(AMouseX, AMouseY));
  end;
  FHighlighter.Update(ADeltaTime, nil);
  { Clip the entity's draw to its dirty rect (current + previous frame
    footprint): Skia then rasterizes only that ~250x250 region of the
    fullscreen canvas instead of every pixel of the monitor, and the
    Save/Restore pair keeps the clip from leaking into the next frame. }
  DirtyRect := FHighlighter.GetDirtyRect;
  if not DirtyRect.IsEmpty then
  begin
    ACanvas.Save;
    ACanvas.ClipRect(TRectF.Create(DirtyRect));
    FHighlighter.Draw(ACanvas);
    ACanvas.Restore;
  end
  else
    FHighlighter.Draw(ACanvas);
end;

function TSkChaos.HighlighterDirtyRect: TRect;
begin
  { Straight pass-through: the rect is already in the host's buffer
    coordinates (SetHighlighterBounds mirrors the overlay canvas) and
    already clamped to the screen bounds. }
  if Assigned(FHighlighter) then
    Result := FHighlighter.GetDirtyRect
  else
    Result := TRect.Create(0, 0, 0, 0);
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
      EnsureVisibleForSpawn;
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

{ Monitor enumeration imports: EnumDisplayMonitors / GetMonitorInfoW
  live in Winapi.MultiMon, which the uses clause does not pull in. Same
  pattern as the GL entry points above - declared here, resolved by the
  Windows loader, no extra uses entry needed. SetWindowPos and its
  SWP_* flags come from Winapi.Windows (already in uses). }
function EnumDisplayMonitors(hdc: HDC; lprcClip: PRect;
  lpfnEnum: TMonitorEnumProc; dwData: NativeInt): LongBool; stdcall; external user32 name 'EnumDisplayMonitors';
function GetMonitorInfoW(hMonitor: THandle; lpmi: PMonitorInfoEx): LongBool; stdcall; external user32 name 'GetMonitorInfoW';

{ Fills one TChaosDisplayInfo slot from the MONITORINFOEX the callback
  received. Keeps the physical rcMonitor bounds - the very coordinates
  SetWindowPos expects, so no logical / physical conversion (and no
  double-scaling on mixed-DPI desktops) ever happens between the
  enumeration and the move. }
procedure TSkChaos.AddDisplay(const AInfo: TMonitorInfoEx);
var
  N: Integer;
begin
  N := Length(FDisplays);
  SetLength(FDisplays, N + 1);
  FDisplays[N].Bounds := AInfo.rcMonitor;
  FDisplays[N].Primary := (AInfo.dwFlags and MONITORINFOF_PRIMARY) <> 0;
end;

{ EnumDisplayMonitors callback: appends every attached monitor to
  FDisplays via dwData = Self. The WinAPI contract guarantees the
  callback only runs while EnumDisplayMonitors itself is on the stack,
  so borrowing Self without locking is safe. BOOL/stdcall signature with
  PRect (NOT LPRECT - that type name is not FMX-safe in older Delphi
  versions) matches the WinAPI MONITORENUMPROC contract exactly. }
function ChaosEnumDisplaysProc(hMonitor: THandle; hdcMonitor: HDC;
  lprcMonitor: PRect; dwData: NativeInt): BOOL; stdcall;
var
  Info: TMonitorInfoEx;
begin
  FillChar(Info, SizeOf(Info), 0);
  Info.cbSize := SizeOf(Info);
  if GetMonitorInfoW(hMonitor, @Info) then
    TSkChaos(dwData).AddDisplay(Info);
  Result := True;
end;

procedure TSkChaos.RefreshDisplays;
begin
  { Re-read the WinAPI monitor list on every call: the panel rebuilds its
    menu right before opening it, so hot-plugged displays (beamer on,
    dock off) appear immediately and stale entries are gone. The
    standalone callback matches TMonitorEnumProc exactly, so it passes
    straight into the parameter - no procedural temp variable needed. }
  FDisplays := nil;
  EnumDisplayMonitors(0, nil, @ChaosEnumDisplaysProc, LPARAM(Self));
end;

function TSkChaos.DisplayCount: Integer;
begin
  RefreshDisplays;
  Result := Length(FDisplays);
end;

function TSkChaos.DisplayInfo(AIndex: Integer): TChaosDisplayInfo;
begin
  RefreshDisplays;
  if (AIndex >= 0) and (AIndex < Length(FDisplays)) then
    Result := FDisplays[AIndex]
  else
  begin
    Result.Bounds := TRect.Empty;
    Result.Primary := False;
  end;
end;

function TSkChaos.CurrentDisplayIndex: Integer;
var
  I: Integer;
  F: TForm;
  Wnd: HWND;
  WR: TRect;
  C: TPoint;
begin
  { Locate the monitor carrying the host window by its centre point -
    robust when a window straddles two monitors (the centre decides) and
    cheaper than MonitorFromPoint after RefreshDisplays already brought
    the full list in. }
  Result := -1;
  RefreshDisplays;
  if Length(FDisplays) = 0 then
    Exit;
  F := FindOwnerForm;
  if F = nil then
    Exit;
  { Physical centre via GetWindowRect: FDisplays carries physical pixel
    bounds while FMX's F.Left / F.Width are logical (scaled by the
    current monitor DPI), so mixing them would pick the wrong monitor on
    a mixed-DPI desktop. TRect.Contains expects a TPoint. }
  Wnd := WindowHandleToPlatform(F.Handle).Wnd;
  if not GetWindowRect(Wnd, WR) then
    Exit;
  C := Point((WR.Left + WR.Right) div 2, (WR.Top + WR.Bottom) div 2);
  for I := 0 to High(FDisplays) do
    if FDisplays[I].Bounds.Contains(C) then
      Exit(I);
end;

procedure TSkChaos.SendToDisplay(AIndex: Integer);
var
  F: TForm;
  Wnd: HWND;
  R: TRect;
  FracX, FracY, NewX, NewY: Single;
begin
  RefreshDisplays;
  if (AIndex < 0) or (AIndex > High(FDisplays)) then
    Exit;
  F := FindOwnerForm;
  if F = nil then
    Exit;
  R := FDisplays[AIndex].Bounds;
  if R.IsEmpty then
    Exit;
  Wnd := WindowHandleToPlatform(F.Handle).Wnd;
  { Capture the avatar's position as fractions of the current client
    area BEFORE the move: fractions are scale-independent, so the anchor
    survives the per-monitor DPI change (a bottom-right avatar stays
    bottom-right, whatever scale the target monitor runs). }
  if F.ClientWidth > 0 then
    FracX := (Position.X + Width * 0.5) / F.ClientWidth
  else
    FracX := 1.0;
  if F.ClientHeight > 0 then
    FracY := (Position.Y + Height * 0.5) / F.ClientHeight
  else
    FracY := 1.0;
  { Per-monitor-DPI-safe order (e.g. laptop 125 % -> external 100 %):
    (1) the pure position move ships the window into the target monitor
        while its old size is still valid - Windows derives the
        WM_DPICHANGED suggested rectangle from real coordinates, so
        nothing is half-clipped at the old monitor's edge;
    (2) only then the exact target width / height follow, completing the
        exact fit onto the monitor's BoundsRect. SWP_NOZORDER keeps an
        active StayOnTop z-order untouched, SWP_NOACTIVATE leaves the
        focus with the panel the user clicked. Physical pixels flow
        untouched from MONITORINFO into SetWindowPos, so no scale factor
        is ever applied twice. }
  SetWindowPos(Wnd, 0, R.Left, R.Top, 0, 0,
    SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE);
  SetWindowPos(Wnd, 0, R.Left, R.Top, R.Width, R.Height,
    SWP_NOZORDER or SWP_NOACTIVATE);
  { SetWindowPos dispatches its WM_SIZE / WM_DPICHANGED synchronously,
    so the form metrics are already final here: re-anchor the avatar at
    the captured fractions of the new client area (bottom-right stays
    bottom-right) and clamp it fully inside, so a smaller target monitor
    can never park it half off-screen. }
  NewX := F.ClientWidth * FracX - Width * 0.5;
  NewY := F.ClientHeight * FracY - Height * 0.5;
  ClampIntoParent(NewX, NewY);
  Position.X := NewX;
  Position.Y := NewY;
  { The avatar control lives inside the now-moved host: re-measure its
    screen rect immediately so the very next render frame converts the
    cursor against the new origin (the per-Draw refresh would catch up a
    frame later at the latest). The touch reset itself runs on the
    render thread via FTouchResetPending: parking uMouseLocal outside
    until the next real cursor sample prevents any velocity spike across
    the jump, so the TouchEffects land exactly under the pointer on the
    new monitor. }
  RefreshScreenGeometry;
  TInterlocked.Exchange(FTouchResetPending, 1);
  { Short repaint of the FMX surface: Invalidate schedules a full scene
    redraw, whose Draw -> RefreshScreenGeometry pass sees the final
    DPI-adjusted form metrics. }
  F.Invalidate;
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

procedure TSkChaos.SetDragMode(const Value: Boolean);
begin
  if FDragMode = Value then
    Exit;
  if Value then
  begin
    { Dragging needs real mouse input: drop click-through for the session
      and remember the previous state so disabling restores it. }
    FSavedClickThrough := FClickThrough;
    ClickThrough := False;
    HitTest := True;
  end
  else
  begin
    { Cancel an in-flight drag before giving the window back its
      pass-through behaviour. }
    FDragging := False;
    ClickThrough := FSavedClickThrough;
  end;
  FDragMode := Value;
end;

procedure TSkChaos.RefreshScreenGeometry;
var
  Origin: TPointF;
begin
  { UI thread only. LocalToScreen walks the FMX window hierarchy, which
    is safe here (Draw / ParentChanged / drag paths all run on the UI
  thread) but must never happen on the render thread. Falls back to the
  previous cache while the control has no root yet, so early frames
  render with stale-but-safe values instead of crashing. }
  if (Parent = nil) or (Root = nil) then
    Exit;
  Origin := LocalToScreen(PointF(0, 0));
  FScreenOrigin := Point(Trunc(Origin.X), Trunc(Origin.Y));
  FControlW := Width;
  FControlH := Height;
end;

procedure TSkChaos.Draw(const ACanvas: ISkCanvas; const ADest: TRectF; const AOpacity: Single);
begin
  { Draw runs on the UI thread with the FMX scene lock held: the perfect
    anchor to refresh the cached screen geometry once per presented frame
    so the render thread's pure-arithmetic cursor conversion stays exact
    through drags, form moves and avatar resizes. }
  RefreshScreenGeometry;
  inherited Draw(ACanvas, ADest, AOpacity);
end;

procedure TSkChaos.ParentChanged;
var
  X, Y: Single;
begin
  inherited;
  { A preset restored before this control joined its host form left the
    position pending: with the parent now in place, clamp the saved point
    into view and apply it, so a preset saved on a larger or shifted
    screen cannot park the avatar off-screen at startup. }
  if FHasPendingStartupPlacement and (Parent is TControl) then
  begin
    X := FPendingStartupPos.X;
    Y := FPendingStartupPos.Y;
    ClampIntoParent(X, Y);
    Position.X := X;
    Position.Y := Y;
    FHasPendingStartupPlacement := False;
  end;
  { New parent / host form: the cached screen origin belongs to the old
    window; re-measure immediately so the first rendered frame after the
    re-parent already converts cursor samples against the real position. }
  RefreshScreenGeometry;
end;

procedure TSkChaos.ClampIntoParent(var X, Y: Single);
var
  P: TControl;
begin
  { Keep the control fully inside the parent client area so a drag or a
    resize can never strand it half off-screen. }
  if Parent is TControl then
  begin
    P := TControl(Parent);
    X := EnsureRange(X, 0, Max(P.Width - Width, 0));
    Y := EnsureRange(Y, 0, Max(P.Height - Height, 0));
  end;
end;

procedure TSkChaos.MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited MouseDown(Button, Shift, X, Y);
  { Grab anchor in parent coordinates: the cursor expressed as local point
    plus the control origin stays invariant while the control itself
    moves, so later deltas track the true cursor movement with no
    feedback loop. }
  if FDragMode and (Button = TMouseButton.mbLeft) then
  begin
    FDragging := True;
    FDragStartMouse := PointF(X + Position.X, Y + Position.Y);
    FDragStartPos := PointF(Position.X, Position.Y);
  end;
end;

procedure TSkChaos.MouseMove(Shift: TShiftState; X, Y: Single);
var
  NewX, NewY: Single;
begin
  inherited MouseMove(Shift, X, Y);
  if FDragging then
  begin
    if (GetAsyncKeyState(VK_LBUTTON) and $8000) = 0 then
    begin
      FDragging := False;
      Exit;
    end;
    NewX := FDragStartPos.X + (X + Position.X - FDragStartMouse.X);
    NewY := FDragStartPos.Y + (Y + Position.Y - FDragStartMouse.Y);
    ClampIntoParent(NewX, NewY);
    Position.X := NewX;
    Position.Y := NewY;
    { The control just moved: refresh the cached screen origin now, not
      at the next Draw, so the render thread's cursor conversion matches
      the new placement within the same frame. }
    RefreshScreenGeometry;
  end;
end;

procedure TSkChaos.MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Single);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if FDragMode and (Button = TMouseButton.mbLeft) then
    FDragging := False;
end;

procedure TSkChaos.SetAvatarSize(AWidth: Single);
var
  W, H: Integer;
  NewX, NewY: Single;
  SavedWeights: TArray<Single>;
  SavedSequence: Integer;
begin
  W := Max(Round(AWidth), 32);
  { Fixed 252 / 236 aspect: the offscreen particle world is authored at
    that ratio, so the draw never stretches the cloud out of proportion. }
  H := Round(W * (CHAOS_HEIGHT / CHAOS_WIDTH));
  if W = Round(Width) then
    Exit;
  { Anchor the bottom edge and the horizontal centre so the avatar keeps
    standing on the same spot, then clamp so growing can never push it
    off the parent area. }
  NewX := Position.X + (Width - W) * 0.5;
  NewY := Position.Y + (Height - H);
  Width := W;
  Height := H;
  ClampIntoParent(NewX, NewY);
  Position.X := NewX;
  Position.Y := NewY;
  { The control's screen rect changed with the resize: re-cache it right
    away so the render thread scales cursor samples against the new
    width instead of the stale one for a frame. }
  RefreshScreenGeometry;
  { Mesh sources re-fit the clouds to the new world size. A same-file
    reload keeps the per-part tints; morph weights and the playing vertex
    sequence are restored around it, and a custom core mesh re-loads with
    its own radius rule. Photo / depth sources simply stretch at the
    draw, their buffer keeps the default dims. }
  if (FSourceType = srcMesh) and (Length(FMeshResult.Points) > 0) and (FCurrentMeshFile <> '') then
  begin
    SavedWeights := Copy(FMorphWeights);
    SavedSequence := FActiveSequence;
    FPendingBufW := W;
    FPendingBufH := H;
    FBufResizePending := True;
    LoadMeshFile(FCurrentMeshFile, Min(W, H) * 0.45, FStepFilter, FParticleBudget);
    if Length(FMorphWeights) = Length(SavedWeights) then
      FMorphWeights := Copy(SavedWeights);
    FActiveSequence := SavedSequence;
    if (FInnerMeshFile <> '') and (Length(FInnerMeshResult.Points) > 0) then
      LoadInnerMeshFile(FInnerMeshFile);
  end;
end;

function TSkChaos.GetPresetsFolder: string;
begin
  { One shared folder keeps the per-mesh automatic slots, user-named files
    and the startup index together next to the executable. }
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'presets');
end;

function TSkChaos.GetAutoPresetPath: string;
var
  Parent, Base: string;
begin
  if FCurrentMeshFile = '' then
    Exit('');
  { Parent folder + base name: many models ship generic file names
    (scene.glb / head.obj), so the immediate folder keeps their presets
    apart. Root-level files fall back to the plain base name. }
  Parent := ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFilePath(FCurrentMeshFile)));
  Base := TPath.GetFileNameWithoutExtension(FCurrentMeshFile);
  if Parent <> '' then
    Base := Parent + '_' + Base;
  Result := TPath.Combine(GetPresetsFolder, Base + '.ini');
end;

function TSkChaos.MatchesEyePartName(const APartName: string): Boolean;
var
  Custom: string;
begin
  Custom := Trim(FCustomEyePartName);
  if (Custom = '') or (Custom = '(Auto)') or (APartName = '') then
    Exit(False);
  { Exact match first, then substring in either direction: the combo lists
    the loader's own mesh names, but a preset saved for a differently
    renamed export (Eyes vs. LeftEye_Mesh.001) should still resolve. }
  Result := SameText(APartName, Custom) or
            APartName.ToLower.Contains(Custom.ToLower) or
            Custom.ToLower.Contains(APartName.ToLower);
end;

function TSkChaos.GetLastPresetIndexPath: string;
begin
  Result := TPath.Combine(GetPresetsFolder, 'last.ini');
end;

procedure TSkChaos.UpdateLastPresetIndex(const AIniFile: string);
var
  Ini: TMemIniFile;
begin
  { Remembers the most recently saved or loaded preset so the next start
    continues that setup. ForceDirectories keeps the very first save
    working before any preset folder exists. }
  ForceDirectories(GetPresetsFolder);
  Ini := TMemIniFile.Create(GetLastPresetIndexPath);
  try
    Ini.WriteString('Startup', 'LastPreset', AIniFile);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

function TSkChaos.LoadLastStartupPreset: Boolean;
var
  Ini: TMemIniFile;
  Last: string;
begin
  { The index is written on every successful save / load; a missing or
    stale entry simply leaves the caller on its normal startup path. }
  Result := False;
  Ini := TMemIniFile.Create(GetLastPresetIndexPath);
  try
    Last := Ini.ReadString('Startup', 'LastPreset', '');
  finally
    Ini.Free;
  end;
  if (Last <> '') and FileExists(Last) then
    Result := LoadPresetFromFile(Last);
end;

function TSkChaos.IsPartAutoExcluded(const AName: string): Boolean;
var
  KW, LowName: string;
begin
  { Mirrors the loader's auto-exclude rule (keyword containment), used to
    materialize the automatic visibility state into a manual list. }
  LowName := AName.ToLower;
  for KW in TMeshLoadOptions.Default.ExcludeKeywords do
    if (KW <> '') and LowName.Contains(KW.ToLower) then
      Exit(True);
  Result := False;
end;

function TSkChaos.SetPartHidden(AIndex: Integer; AHidden: Boolean): Boolean;
var
  I: Integer;
  Name: string;
  NewList: TArray<string>;

  function InIncludeList(const AName: string): Boolean;
  var
    J: Integer;
  begin
    for J := 0 to High(FMeshIncludeNames) do
      if SameText(FMeshIncludeNames[J], AName) then
        Exit(True);
    Result := False;
  end;

begin
  Result := False;
  if (AIndex < 0) or (AIndex > High(FMeshResult.MeshNames)) then
    Exit;
  Name := FMeshResult.MeshNames[AIndex];
  if Length(FMeshIncludeNames) = 0 then
  begin
    { Automatic mode has no list to edit: materialize the currently
      visible parts (everything the exclude keywords keep) with this one
      part forced to its preset state, turning the setup into the
      equivalent manual list. An empty result means "nothing visible" and
      is turned into the match-nothing sentinel by the caller. }
    SetLength(NewList, 0);
    for I := 0 to High(FMeshResult.MeshNames) do
      if ((I = AIndex) and not AHidden) or ((I <> AIndex) and not IsPartAutoExcluded(FMeshResult.MeshNames[I])) then
      begin
        SetLength(NewList, Length(NewList) + 1);
        NewList[High(NewList)] := FMeshResult.MeshNames[I];
      end;
    FMeshIncludeNames := NewList;
    Exit(True);
  end;
  if AHidden then
  begin
    { Manual mode: drop the name when present. }
    if not InIncludeList(Name) then
      Exit(False);
    SetLength(NewList, 0);
    for I := 0 to High(FMeshIncludeNames) do
      if not SameText(FMeshIncludeNames[I], Name) then
      begin
        SetLength(NewList, Length(NewList) + 1);
        NewList[High(NewList)] := FMeshIncludeNames[I];
      end;
    FMeshIncludeNames := NewList;
    Exit(True);
  end;
  { Manual mode: append the name when missing. }
  if InIncludeList(Name) then
    Exit(False);
  NewList := Copy(FMeshIncludeNames);
  SetLength(NewList, Length(NewList) + 1);
  NewList[High(NewList)] := Name;
  FMeshIncludeNames := NewList;
  Result := True;
end;

procedure TSkChaos.SavePresetToFile(const AIniFile: string);
var
  Ini: TMemIniFile;
  I: Integer;
  HasPoints: TArray<Boolean>;

  procedure WriteColor(const ASec, AIdent: string; AColor: TAlphaColor);
  begin
    { Hex $AARRGGBB: readable in any editor and locale-independent. }
    Ini.WriteString(ASec, AIdent, '$' + IntToHex(AColor, 8));
  end;

begin
  if AIniFile = '' then
    Exit;
  if ExtractFilePath(AIniFile) <> '' then
    ForceDirectories(ExtractFilePath(AIniFile));
  Ini := TMemIniFile.Create(AIniFile);
  try
    Ini.WriteString('Mesh', 'MeshFile', FCurrentMeshFile);
    Ini.WriteString('Mesh', 'InnerMeshFile', FInnerMeshFile);
    Ini.WriteBool('Mesh', 'InnerCore', FInnerCore);
    Ini.WriteFloat('Mesh', 'InnerCoreScale', FInnerCoreScale);
    Ini.WriteFloat('Mesh', 'InnerCoreOffsetY', FInnerCoreOffsetY);
    Ini.WriteInteger('Mesh', 'InnerCoreBudget', Integer(FInnerCoreBudget));
    Ini.WriteInteger('Mesh', 'ParticleBudget', Integer(FParticleBudget));
    Ini.WriteString('Mesh', 'CustomEyePartName', FCustomEyePartName);

    Ini.WriteInteger('Style', 'HoloStyle', Ord(FHoloStyle));
    WriteColor('Style', 'FaceColor', FFaceColor);
    WriteColor('Style', 'AccentColor', FAccentColor);
    Ini.WriteFloat('Style', 'GlowIntensity', FGlowIntensity);
    Ini.WriteFloat('Style', 'ParticleSize', FParticleSize);
    Ini.WriteFloat('Style', 'Softness', FSoftness);
    Ini.WriteFloat('Style', 'RimPower', FRimPower);
    Ini.WriteFloat('Style', 'InnerGlow', FInnerGlow);
    Ini.WriteFloat('Style', 'InnerParticleSize', FInnerParticleSize);
    Ini.WriteFloat('Style', 'InnerSoftness', FInnerSoftness);
    Ini.WriteFloat('Style', 'InnerRimPower', FInnerRimPower);

    Ini.WriteFloat('Animation', 'BlinkDuration', FBlinkDuration);
    Ini.WriteFloat('Animation', 'NeckPivotRatio', FNeckPivotRatio);

    { Behavior toggles under [Face], matching the panel's BEHAVIOR group.
      TouchEffectsEnabled is the renamed MouseForceField key; old presets
      carrying the legacy key are read back as the enable flag, new
      presets write both so any older build still round-trips. }
    Ini.WriteBool('Face', 'TouchEffectsEnabled', FTouchEffectsEnabled);
    Ini.WriteBool('Face', 'MouseForceField', FTouchEffectsEnabled);
    Ini.WriteInteger('Face', 'TouchEffectStyle', Ord(FTouchEffectStyle));
    WriteColor('Face', 'TouchEffectColor', FTouchEffectColor);
    Ini.WriteBool('Face', 'IdleLifeMotion', FIdleLifeMotion);
    Ini.WriteBool('Face', 'NaturalBlinking', FAutoBlink);

    Ini.WriteFloat('Overlay', 'PosX', Position.X);
    Ini.WriteFloat('Overlay', 'PosY', Position.Y);
    Ini.WriteFloat('Overlay', 'AvatarWidth', Width);
    Ini.WriteBool('Overlay', 'DragMode', FDragMode);
    Ini.WriteBool('Overlay', 'AutoDimOnHover', FAutoDimOnHover);

    Ini.WriteBool('Performance', 'AdaptiveFPS', AdaptiveFPS);
    Ini.WriteInteger('Performance', 'ActiveTargetFPS', ActiveTargetFPS);
    Ini.WriteInteger('Performance', 'IdleTargetFPS', IdleTargetFPS);
    Ini.WriteFloat('Performance', 'IdleTimeoutSec', IdleTimeoutSec);

    { AI & voice state (the panel persists its own detailed AI section;
      this keeps the split toggles + lip-sync mode alive per preset). }
    Ini.WriteBool('AI', 'TtsEnabled', FVoiceTtsEnabled);
    Ini.WriteBool('AI', 'SttEnabled', FVoiceSttEnabled);
    { Legacy key kept for older builds: master on = both sides on. }
    Ini.WriteBool('AI', 'VoiceEnabled', FVoiceTtsEnabled or FVoiceSttEnabled);
    Ini.WriteBool('AI', 'MicLipSyncOnly', (FVoicePipeline <> nil) and FVoicePipeline.MicLipSyncOnly);

    { One scan over the live point set: a part is visible iff the loader
      kept at least one of its points, which holds for both the automatic
      and the manual include modes without guessing at keywords. }
    SetLength(HasPoints, Length(FPartColors));
    for I := 0 to High(FMeshResult.Points) do
      if FMeshResult.Points[I].GroupTag < Cardinal(Length(HasPoints)) then
        HasPoints[FMeshResult.Points[I].GroupTag] := True;
    for I := 0 to High(FPartColors) do
    begin
      WriteColor('OuterParts', 'Color_' + IntToStr(I), FPartColors[I]);
      Ini.WriteBool('OuterParts', 'Hidden_' + IntToStr(I), not HasPoints[I]);
    end;
    for I := 0 to High(FInnerPartColors) do
      WriteColor('InnerParts', 'Color_' + IntToStr(I), FInnerPartColors[I]);

    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
  { A successful save becomes the setup the next start restores. }
  UpdateLastPresetIndex(AIniFile);
end;

function TSkChaos.LoadPresetFromFile(const AIniFile: string): Boolean;
var
  Ini: TMemIniFile;
  MeshFile, InnerFile: string;
  I: Integer;
  X, Y, W: Single;
  VisibilityChanged, MeshSwitched: Boolean;
begin
  Result := False;
  if not FileExists(AIniFile) then
    Exit;
  Ini := TMemIniFile.Create(AIniFile);
  try
    Result := True;
    { The whole application runs under the recursion guard: any mesh load
      below (mesh switch, visibility reload, resize) must not fire the
      automatic per-mesh preset load and re-enter this routine. }
    FLoadingPreset := True;
    try
      MeshFile := Ini.ReadString('Mesh', 'MeshFile', FCurrentMeshFile);
      InnerFile := Ini.ReadString('Mesh', 'InnerMeshFile', FInnerMeshFile);

      { Budgets drive what the loaders parse, so they go in as plain
        fields first; their setters would reload the old source with the
        old budget before this preset's mesh is even loaded. The custom
        eye part also lands before any mesh (re)load: its KeepName must
        already be in place so the loader keeps the eyeball part alive. }
      FInnerCoreBudget := Cardinal(Ini.ReadInteger('Mesh', 'InnerCoreBudget', Integer(FInnerCoreBudget)));
      FParticleBudget := Cardinal(Ini.ReadInteger('Mesh', 'ParticleBudget', Integer(FParticleBudget)));
      FCustomEyePartName := Ini.ReadString('Mesh', 'CustomEyePartName', FCustomEyePartName);

      { Per-part visibility feeds the include list the mesh loader
        consumes, so apply the hidden flags before any (re)parse. }
      VisibilityChanged := False;
      for I := 0 to High(FMeshResult.MeshNames) do
        if Ini.ValueExists('OuterParts', 'Hidden_' + IntToStr(I)) and SetPartHidden(I, Ini.ReadBool('OuterParts', 'Hidden_' + IntToStr(I), False)) then
          VisibilityChanged := True;
      if VisibilityChanged and (Length(FMeshIncludeNames) = 0) then
        { Every part hidden: keep the "match nothing" sentinel instead of
          the empty list, which the loader reads as automatic mode. }
        FMeshIncludeNames := ['__NONE__'];

      { A different mesh file loads with the preset's filter already in
        place, so the parts visibility applies at parse time; a same-mesh
        visibility change needs one reload to take effect. }
      MeshSwitched := (MeshFile <> '') and not SameText(MeshFile, FCurrentMeshFile) and FileExists(MeshFile);
      if MeshSwitched then
        LoadMeshFile(MeshFile, Min(Width, Height) * 0.45, FStepFilter, FParticleBudget)
      else if VisibilityChanged and (FSourceType = srcMesh) and (FCurrentMeshFile <> '') then
        ReloadCurrentSource;

      { Inner layer: scale / offset first so the first rebuild after the
        inner load already uses them; a custom core mesh file wins over
        the procedural-core toggle. }
      InnerCoreScale := Ini.ReadFloat('Mesh', 'InnerCoreScale', FInnerCoreScale);
      InnerCoreOffsetY := Ini.ReadFloat('Mesh', 'InnerCoreOffsetY', FInnerCoreOffsetY);
      if (InnerFile <> '') and FileExists(InnerFile) then
        LoadInnerMeshFile(InnerFile)
      else
        InnerCore := Ini.ReadBool('Mesh', 'InnerCore', FInnerCore);

      { Style: enum index, hex colours, then the tuning floats. }
      I := Ini.ReadInteger('Style', 'HoloStyle', Ord(FHoloStyle));
      if (I >= Ord(Low(THoloStyle))) and (I <= Ord(High(THoloStyle))) then
        HoloStyle := THoloStyle(I);
      FaceColor := TAlphaColor(StrToIntDef(Ini.ReadString('Style', 'FaceColor', '$' + IntToHex(FFaceColor, 8)), Integer(FFaceColor)));
      AccentColor := TAlphaColor(StrToIntDef(Ini.ReadString('Style', 'AccentColor', '$' + IntToHex(FAccentColor, 8)), Integer(FAccentColor)));
      GlowIntensity := Ini.ReadFloat('Style', 'GlowIntensity', FGlowIntensity);
      ParticleSize := Ini.ReadFloat('Style', 'ParticleSize', FParticleSize);
      Softness := Ini.ReadFloat('Style', 'Softness', FSoftness);
      RimPower := Ini.ReadFloat('Style', 'RimPower', FRimPower);
      InnerGlow := Ini.ReadFloat('Style', 'InnerGlow', FInnerGlow);
      InnerParticleSize := Ini.ReadFloat('Style', 'InnerParticleSize', FInnerParticleSize);
      InnerSoftness := Ini.ReadFloat('Style', 'InnerSoftness', FInnerSoftness);
      InnerRimPower := Ini.ReadFloat('Style', 'InnerRimPower', FInnerRimPower);

      { Animation pacing. NeckPivotRatio routes through its property so
        FPivotY is recomputed from the loaded mesh's Y range immediately.
        Old presets carrying the removed BlinkInterval key are silently
        ignored - the natural re-roll owns the pause rhythm. }
      BlinkDuration := Ini.ReadFloat('Animation', 'BlinkDuration', FBlinkDuration);
      NeckPivotRatio := Ini.ReadFloat('Animation', 'NeckPivotRatio', FNeckPivotRatio);

      { Behavior toggles ([Face] section); the checkbox panel and the
        tray menu pick these up via SyncControlsFromChaos after load.
        TouchEffectsEnabled reads the legacy MouseForceField key when the
        new one is absent so old presets keep working. }
      TouchEffectsEnabled := Ini.ReadBool('Face', 'TouchEffectsEnabled',
        Ini.ReadBool('Face', 'MouseForceField', FTouchEffectsEnabled));
      I := Ini.ReadInteger('Face', 'TouchEffectStyle', Ord(FTouchEffectStyle));
      if (I >= Ord(Low(TChaosTouchEffectStyle))) and (I <= Ord(High(TChaosTouchEffectStyle))) then
        TouchEffectStyle := TChaosTouchEffectStyle(I);
      TouchEffectColor := TAlphaColor(StrToIntDef(Ini.ReadString('Face', 'TouchEffectColor', '$' + IntToHex(FTouchEffectColor, 8)), Integer(FTouchEffectColor)));
      IdleLifeMotion := Ini.ReadBool('Face', 'IdleLifeMotion', FIdleLifeMotion);
      NaturalBlinking := Ini.ReadBool('Face', 'NaturalBlinking', FAutoBlink);

      { Per-part tints. Both setters guard the index range, so a preset
        written for a different mesh applies only the overlapping parts. }
      for I := 0 to High(FPartColors) do
        if Ini.ValueExists('OuterParts', 'Color_' + IntToStr(I)) then
          SetPartColor(I, TAlphaColor(StrToIntDef(Ini.ReadString('OuterParts', 'Color_' + IntToStr(I), '$00000000'), 0)));
      for I := 0 to High(FInnerPartColors) do
        if Ini.ValueExists('InnerParts', 'Color_' + IntToStr(I)) then
          SetInnerPartColor(I, TAlphaColor(StrToIntDef(Ini.ReadString('InnerParts', 'Color_' + IntToStr(I), '$00000000'), 0)));

      { Overlay placement: size first (it re-fits the mesh clouds), then
        the saved position clamped back into the parent. }
      W := Ini.ReadFloat('Overlay', 'AvatarWidth', Width);
      if W >= 32 then
        SetAvatarSize(W);
      X := Ini.ReadFloat('Overlay', 'PosX', Position.X);
      Y := Ini.ReadFloat('Overlay', 'PosY', Position.Y);
      { Drag mode belongs to the placement: its only toggle lives in the
        controls panel, so the preset keeps the choice alive across
        sessions. The setter also swaps click-through, and skips the
        window-style call until a host form exists, which keeps it safe
        during startup restore. }
      DragMode := Ini.ReadBool('Overlay', 'DragMode', FDragMode);

      AutoDimOnHover := Ini.ReadBool('Overlay', 'AutoDimOnHover', FAutoDimOnHover);

      { Performance tiers: adaptive pacing and the active / idle FPS pair
        with the idle timeout, so a tuned preset reproduces its frame
        pacing exactly on the next start. }
      AdaptiveFPS := Ini.ReadBool('Performance', 'AdaptiveFPS', AdaptiveFPS);
      ActiveTargetFPS := Ini.ReadInteger('Performance', 'ActiveTargetFPS', ActiveTargetFPS);
      IdleTargetFPS := Ini.ReadInteger('Performance', 'IdleTargetFPS', IdleTargetFPS);
      IdleTimeoutSec := Ini.ReadFloat('Performance', 'IdleTimeoutSec', IdleTimeoutSec);

      { AI & voice: restore the split toggles (legacy presets carrying only
        the coupled VoiceEnabled master map to both sides); the panel applies
        the detailed paths (models / endpoint / prompt) through its own AI
        section and re-activates the pipeline via ActivatePendingVoice. }
      FVoiceTtsEnabled := Ini.ReadBool('AI', 'TtsEnabled',
        Ini.ReadBool('AI', 'VoiceEnabled', False));
      FVoiceSttEnabled := Ini.ReadBool('AI', 'SttEnabled',
        Ini.ReadBool('AI', 'VoiceEnabled', False));

      if Parent is TControl then
        ClampIntoParent(X, Y)
      else
      begin
        { Startup restore runs inside the constructor, before the host
          form assigns Parent, so no bounds exist to clamp against: keep
          the raw point pending and re-apply it from ParentChanged. }
        FPendingStartupPos := PointF(X, Y);
        FHasPendingStartupPlacement := True;
      end;
      Position.X := X;
      Position.Y := Y;
    finally
      FLoadingPreset := False;
    end;
  finally
    Ini.Free;
  end;
  { A successfully applied preset becomes the session the next start
    restores. }
  if Result then
    UpdateLastPresetIndex(AIniFile);
  NotifyActivity;
end;

procedure TSkChaos.SaveCurrentMeshPreset;
begin
  { Automatic slot next to the executable, so re-opening this head
    restores the setup on load. }
  if FCurrentMeshFile = '' then
    Exit;
  SavePresetToFile(GetAutoPresetPath);
end;

procedure TSkChaos.SetNeckPivotRatio(const Value: Single);
begin
  if not SameValue(FNeckPivotRatio, Value, 1e-4) then
  begin
    FNeckPivotRatio := EnsureRange(Value, 0.0, 1.0);
    if FNeckPivotRatio <= 0.001 then
      FPivotY := -9999.0
    else
      FPivotY := FMinY + (FMaxY - FMinY) * FNeckPivotRatio;
    NotifyActivity;
  end;
end;

end.

