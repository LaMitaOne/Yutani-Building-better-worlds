unit Yutani.Video.MPV;

interface

uses
  Winapi.Windows, System.SysUtils, Winapi.OpenGL, Raylib;

const
  LIBMPV_DLL = 'mpv-2.dll';
  MPV_RENDER_API_TYPE_OPENGL: PAnsiChar = 'opengl';
  MPV_RENDER_UPDATE_FRAME = 1;

type
  mpv_handle = Pointer;

  Pmpv_handle = ^mpv_handle;

  mpv_render_context = Pointer;

  Pmpv_render_context = ^mpv_render_context;

  mpv_format = (MPV_FORMAT_NONE = 0, MPV_FORMAT_STRING = 1, MPV_FORMAT_OSD_STRING = 2, MPV_FORMAT_FLAG = 3, MPV_FORMAT_INT64 = 4, MPV_FORMAT_DOUBLE = 5, MPV_FORMAT_NODE = 6, MPV_FORMAT_NODE_ARRAY = 7, MPV_FORMAT_NODE_MAP = 8, MPV_FORMAT_BYTE_ARRAY = 9);

  mpv_render_param_type = (MPV_RENDER_PARAM_INVALID = 0, MPV_RENDER_PARAM_API_TYPE = 1, MPV_RENDER_PARAM_OPENGL_INIT_PARAMS = 2, MPV_RENDER_PARAM_OPENGL_FBO = 3, MPV_RENDER_PARAM_FLIP_Y = 4, MPV_RENDER_PARAM_DEPTH = 5, MPV_RENDER_PARAM_ICC_PROFILE = 6, MPV_RENDER_PARAM_AMBIENT_LIGHT = 7, MPV_RENDER_PARAM_X11_DISPLAY = 8, MPV_RENDER_PARAM_WL_DISPLAY = 9, MPV_RENDER_PARAM_ADVANCED_CONTROL = 10, MPV_RENDER_PARAM_NEXT_FRAME_INFO = 11, MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME = 12, MPV_RENDER_PARAM_SKIP_RENDERING = 13);

  mpv_opengl_init_params = record
    get_proc_address: function(ctx: Pointer; name: PAnsiChar): Pointer; cdecl;
    get_proc_address_ctx: Pointer;
  end;

  Pmpv_opengl_init_params = ^mpv_opengl_init_params;

  mpv_opengl_fbo = record
    fbo: Integer;
    w: Integer;
    h: Integer;
    internal_format: Integer;
  end;

  Pmpv_opengl_fbo = ^mpv_opengl_fbo;

  mpv_render_param = record
    _type: mpv_render_param_type;
    data: Pointer;
  end;

  Pmpv_render_param = ^mpv_render_param;

  mpv_render_update_fn = procedure(cb_ctx: Pointer); cdecl;

  TMPVPlayer = class
  private
    FMPV: mpv_handle;
    FRenderCtx: mpv_render_context;
    FTarget: TRenderTexture2D;
    FInitParams: mpv_opengl_init_params;
    FParams: array[0..2] of mpv_render_param;
    FFBO: mpv_opengl_fbo;
    FFlipY: Integer;
    FFBOParams: array[0..2] of mpv_render_param;
    FHasRenderContext: Boolean;
    FPendingFile: string;
    procedure HandleMPVEvents;
  public
    constructor Create(W, H: Integer);
    destructor Destroy; override;
    procedure LoadFile(const AFileName: string);
    procedure Update;
    procedure Render;
    property Target: TRenderTexture2D read FTarget;
    property PendingFile: string read FPendingFile write FPendingFile;
  end;

var
  mpv_create: function: Pmpv_handle; cdecl;
  mpv_initialize: function(ctx: mpv_handle): Integer; cdecl;
  mpv_terminate_destroy: procedure(ctx: mpv_handle); cdecl;
  mpv_set_option_string: function(ctx: mpv_handle; name: PAnsiChar; data: PAnsiChar): Integer; cdecl;
  mpv_command: function(ctx: mpv_handle; args: PPAnsiChar): Integer; cdecl;
  mpv_wait_event: function(ctx: mpv_handle; timeout: Double): Pointer; cdecl;
  mpv_render_context_create: function(res: Pmpv_render_context; mpv: mpv_handle; params: Pmpv_render_param): Integer; cdecl;
  mpv_render_context_set_update_callback: procedure(ctx: mpv_render_context; callback: mpv_render_update_fn; callback_ctx: Pointer); cdecl;
  mpv_render_context_update: function(ctx: mpv_render_context): UInt64; cdecl;
  mpv_render_context_render: function(ctx: mpv_render_context; params: Pmpv_render_param): Integer; cdecl;
  mpv_render_context_free: procedure(ctx: mpv_render_context); cdecl;

var
  MPVLibHandle: THandle = 0;

function LoadMPV: Boolean;

procedure UnloadMPV;

implementation

procedure mpv_update_callback(cb_ctx: pointer); cdecl;
begin
  // Empty, we poll manually in Update
end;

function get_proc_address(ctx: pointer; name: PAnsiChar): pointer; cdecl;
begin
  Result := wglGetProcAddress(name);
  if Result = nil then
    Result := Winapi.Windows.GetProcAddress(GetModuleHandle('opengl32.dll'), name);
end;

function GetProcAddr(Lib: THandle; const Name: string): Pointer;
begin
  Result := GetProcAddress(Lib, PChar(Name));
  if not Assigned(Result) then
    raise Exception.CreateFmt('MPV function %s not found', [Name]);
end;

function LoadMPV: Boolean;
begin
  Result := False;
  if MPVLibHandle <> 0 then
    Exit(True);
  MPVLibHandle := LoadLibrary(LIBMPV_DLL);
  if MPVLibHandle = 0 then
    Exit;
  try
    mpv_create := GetProcAddr(MPVLibHandle, 'mpv_create');
    mpv_initialize := GetProcAddr(MPVLibHandle, 'mpv_initialize');
    mpv_terminate_destroy := GetProcAddr(MPVLibHandle, 'mpv_terminate_destroy');
    mpv_set_option_string := GetProcAddr(MPVLibHandle, 'mpv_set_option_string');
    mpv_command := GetProcAddr(MPVLibHandle, 'mpv_command');
    mpv_wait_event := GetProcAddr(MPVLibHandle, 'mpv_wait_event');
    mpv_render_context_create := GetProcAddr(MPVLibHandle, 'mpv_render_context_create');
    mpv_render_context_set_update_callback := GetProcAddr(MPVLibHandle, 'mpv_render_context_set_update_callback');
    mpv_render_context_update := GetProcAddr(MPVLibHandle, 'mpv_render_context_update');
    mpv_render_context_render := GetProcAddr(MPVLibHandle, 'mpv_render_context_render');
    mpv_render_context_free := GetProcAddr(MPVLibHandle, 'mpv_render_context_free');
    Result := True;
  except
    on E: Exception do
    begin
      FreeLibrary(MPVLibHandle);
      MPVLibHandle := 0;
      raise;
    end;
  end;
end;

procedure UnloadMPV;
begin
  if MPVLibHandle <> 0 then
  begin
    FreeLibrary(MPVLibHandle);
    MPVLibHandle := 0;
  end;
end;
{ TMPVPlayer }

constructor TMPVPlayer.Create(W, H: Integer);
begin
  if not LoadMPV then
    raise Exception.Create('mpv-2.dll not found or failed to load');
  FTarget := LoadRenderTexture(W, H);
  SetTextureFilter(FTarget.texture, TEXTURE_FILTER_TRILINEAR);
  FMPV := mpv_create();
  if FMPV = nil then
    raise Exception.Create('Failed to create mpv handle');
  mpv_set_option_string(FMPV, 'vo', 'libmpv');
  mpv_set_option_string(FMPV, 'hwdec', 'auto');
  mpv_set_option_string(FMPV, 'opengl', 'yes');
  mpv_set_option_string(FMPV, 'opengl-debug', 'yes');
  mpv_set_option_string(FMPV, 'ao', 'auto');
  mpv_set_option_string(FMPV, 'audio-display', 'no');
  mpv_set_option_string(FMPV, 'vid', '1');
  mpv_set_option_string(FMPV, 'video-sync', 'audio');
  mpv_set_option_string(FMPV, 'audio-buffer', '0.2');
  if mpv_initialize(FMPV) < 0 then
    raise Exception.Create('Failed to initialize mpv');
  FInitParams.get_proc_address := @get_proc_address;
  FInitParams.get_proc_address_ctx := nil;
  FParams[0]._type := MPV_RENDER_PARAM_OPENGL_INIT_PARAMS;
  FParams[0].data := @FInitParams;
  FParams[1]._type := MPV_RENDER_PARAM_API_TYPE;
  FParams[1].data := MPV_RENDER_API_TYPE_OPENGL;
  FParams[2]._type := MPV_RENDER_PARAM_INVALID;
  FParams[2].data := nil;
  FRenderCtx := nil;
  if mpv_render_context_create(@FRenderCtx, FMPV, @FParams[0]) < 0 then
    raise Exception.Create('Failed to create mpv render context');
  mpv_render_context_set_update_callback(FRenderCtx, mpv_update_callback, nil);
  FHasRenderContext := True;
  if FPendingFile <> '' then
    LoadFile(FPendingFile);
end;

destructor TMPVPlayer.Destroy;
begin
  if FRenderCtx <> nil then
    mpv_render_context_free(FRenderCtx);
  if FMPV <> nil then
    mpv_terminate_destroy(FMPV);
  UnloadRenderTexture(FTarget);
  inherited;
end;

procedure TMPVPlayer.HandleMPVEvents;
var
  Event: Pointer;
  EventID: Integer;
begin
  if FMPV <> nil then
  begin
    while True do
    begin
      Event := mpv_wait_event(FMPV, 0);
      if Event = nil then
        Break;
      EventID := PInteger(Event)^;
      if EventID = 0 then
        Break;
    end;
  end;
end;

procedure TMPVPlayer.Update;
begin
  HandleMPVEvents;
end;

procedure TMPVPlayer.LoadFile(const AFileName: string);
var
  Args: array[0..1] of PAnsiChar;
begin
  Args[0] := 'loadfile';
  Args[1] := PAnsiChar(AnsiString(AFileName));
  mpv_command(FMPV, @Args[0]);
end;

procedure TMPVPlayer.Render;
var
  UpdateFlags: UInt64;
begin
  if FRenderCtx = nil then
    Exit;
  UpdateFlags := mpv_render_context_update(FRenderCtx);
  if (UpdateFlags and MPV_RENDER_UPDATE_FRAME) = 0 then
    Exit;
  FFBO.fbo := FTarget.id;
  FFBO.w := FTarget.texture.width;
  FFBO.h := FTarget.texture.height;
  FFBO.internal_format := 0;
  FFlipY := 0;
  FFBOParams[0]._type := MPV_RENDER_PARAM_OPENGL_FBO;
  FFBOParams[0].data := @FFBO;
  FFBOParams[1]._type := MPV_RENDER_PARAM_FLIP_Y;
  FFBOParams[1].data := @FFlipY;
  FFBOParams[2]._type := MPV_RENDER_PARAM_INVALID;
  FFBOParams[2].data := nil;
  mpv_render_context_render(FRenderCtx, @FFBOParams[0]);
end;

end.

