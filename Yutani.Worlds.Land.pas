unit Yutani.Worlds.Land;

{==============================================================================*
 *  Yutani World: Land - Day/Night Cycle with Clouds and Skybox
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    The Land world: a green grass floor with a procedural skybox shader
 *    that blends horizon and zenith colors based on time of day. A large
 *    cloud plane sits at Y=150 with a scrolling cloud texture. The
 *    day/night cycle advances automatically when enabled.
 *
 *  Visual layout:
 *    - Floor: 1000x1000 green plane (DARKGREEN) at Y=0
 *    - Skybox: inverted cube with gradient shader, day/night colors
 *    - Clouds: 2000x2000 plane at Y=150, scrolling cloud texture
 *    - Sun: computed from DayTime (0..1), drives lighting uniforms
 *
 *  Assets owned by this world:
 *    - Skybox shader + model + texture (loaded in constructor)
 *    - Cloud shader + model + texture (loaded in constructor)
 *    - Ambient gradient texture (for lighting color lookup)
 *
 *  Integration:
 *    Replace the inline Land rendering in Yutani.Core.Render3DSceneCore
 *    with FLandWorld.Render(Camera). Pass the lighting shader to the
 *    constructor so this world can set up its own skybox/cloud shaders.
 *==============================================================================}
{$POINTERMATH ON}
{$Q-}
{$R-}
interface
uses
  System.SysUtils, System.Math, Raylib, RayMath, rlgl;
type
  /// <summary>
  /// Land world: green floor + day/night skybox + scrolling clouds.
  /// Owns its own skybox and cloud shaders/models/textures. The
  /// constructor loads these from the ressources/ folder next to the
  /// executable.
  /// </summary>
  TLandWorld = class
  private
    // Skybox assets
    FSkyboxModel: TModel;
    FSkyboxShader: TShader;
    FSkyboxTex: TTexture2D;
    FSkyboxDaytimeLoc: Integer;
    FSkyboxViewLoc: Integer;
    FSkyboxProjLoc: Integer;
    FLightShader: TShader;
    // Cloud assets
    FCloudModel: TModel;
    FCloudShader: TShader;
    FCloudTex: TTexture2D;
    FCloudMoveFactorLoc: Integer;
    FCloudDaytimeLoc: Integer;
    FCloudMoveFactor: Single;
    // Ambient gradient texture for lighting color lookup
    FAmbientGradientTex: TTexture2D;
    // Floor
    FFloorSize: Single;
    FTime: Single;
    FCameraPos: TVector3;
    FHasAssets: Boolean;
    procedure LoadAssets(const ResourcePath: string);
    procedure UnloadAssets;
  public
constructor Create(const ResourcePath: string;
      const SkyboxVertShader, SkyboxFragShader: PAnsiChar;
      const CloudVertShader, CloudFragShader: PAnsiChar;
      const ALightShader: TShader);
    destructor Destroy; override;
    procedure Update(dt: Single; const CameraPos: TVector3;
      DayTime: Single; DaySpeed: Single; RhythmActive: Boolean);
    procedure Render(const Camera: TCamera3D; DayTime: Single);
    procedure RenderShadows;
    procedure RenderSkybox(const Camera: TCamera3D; DayTime: Single);
    procedure RenderClouds(const Camera: TCamera3D; DayTime: Single);
    property SkyboxShader: TShader read FSkyboxShader;
    property CloudShader: TShader read FCloudShader;
    property AmbientGradientTex: TTexture2D read FAmbientGradientTex;
    property HasAssets: Boolean read FHasAssets;
    property FloorSize: Single read FFloorSize write FFloorSize;
  end;
implementation
{ TLandWorld }
constructor TLandWorld.Create(const ResourcePath: string;
      const SkyboxVertShader, SkyboxFragShader: PAnsiChar;
      const CloudVertShader, CloudFragShader: PAnsiChar;
      const ALightShader: TShader);
var
  SkyMesh, CloudMesh: TMesh;
  FilePath: string;
begin
  inherited Create;
  FLightShader := ALightShader;
  FTime := 0;
  FCameraPos := Vector3Create(0, 0, 0);
  FFloorSize := 1000.0;
  FCloudMoveFactor := 0;
  FHasAssets := False;
  FSkyboxTex.id := 0;
  FCloudTex.id := 0;
  FAmbientGradientTex.id := 0;
  // Load skybox shader from memory strings
  FSkyboxShader := LoadShaderFromMemory(SkyboxVertShader, SkyboxFragShader);
  FSkyboxDaytimeLoc := GetShaderLocation(FSkyboxShader, 'daytime');
  FSkyboxViewLoc := GetShaderLocation(FSkyboxShader, 'view');
  FSkyboxProjLoc := GetShaderLocation(FSkyboxShader, 'projection');
  // Create inverted cube mesh for skybox interior
  SkyMesh := GenMeshCube(1.0, 1.0, 1.0);
  FSkyboxModel := LoadModelFromMesh(SkyMesh);
  FSkyboxModel.materials[0].shader := FSkyboxShader;
  // Load cloud shader from memory strings
  FCloudShader := LoadShaderFromMemory(CloudVertShader, CloudFragShader);
  FCloudMoveFactorLoc := GetShaderLocation(FCloudShader, 'moveFactor');
  FCloudDaytimeLoc := GetShaderLocation(FCloudShader, 'daytime');
  // Generate large cloud plane at Y=150
  CloudMesh := GenMeshPlane(2000, 2000, 1, 1);
  FCloudModel := LoadModelFromMesh(CloudMesh);
  FCloudModel.transform := MatrixTranslate(0, 150, 0);
  FCloudModel.materials[0].shader := FCloudShader;
  // Load textures from disk if they exist
  LoadAssets(ResourcePath);
end;
procedure TLandWorld.LoadAssets(const ResourcePath: string);
var
  FilePath: string;
begin
  FilePath := ResourcePath;
  if not DirectoryExists(PAnsiChar(FilePath)) then
    Exit;
  // Skybox gradient texture
  if FileExists(PAnsiChar(AnsiString(FilePath + 'skyGradient.png'))) then
  begin
    FSkyboxTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'skyGradient.png')));
    SetTextureFilter(FSkyboxTex, TEXTURE_FILTER_TRILINEAR);
  end;
  // Cloud texture
  if FileExists(PAnsiChar(AnsiString(FilePath + 'clouds.png'))) then
  begin
    FCloudTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'clouds.png')));
    SetTextureFilter(FCloudTex, TEXTURE_FILTER_TRILINEAR);
    SetTextureWrap(FCloudTex, TEXTURE_WRAP_REPEAT);
    FCloudModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FCloudTex;
  end;
  // Ambient gradient for lighting color lookup
  if FileExists(PAnsiChar(AnsiString(FilePath + 'ambientGradient.png'))) then
  begin
    FAmbientGradientTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'ambientGradient.png')));
    SetTextureFilter(FAmbientGradientTex, TEXTURE_FILTER_TRILINEAR);
  end;
  FHasAssets := True;
end;
procedure TLandWorld.UnloadAssets;
begin
  if FSkyboxShader.id > 0 then
  begin
    UnloadShader(FSkyboxShader);
    if FSkyboxModel.meshes <> nil then
      UnloadModel(FSkyboxModel);
  end;
  if FSkyboxTex.id > 0 then
    UnloadTexture(FSkyboxTex);
  if FCloudShader.id > 0 then
  begin
    UnloadShader(FCloudShader);
    if FCloudModel.meshes <> nil then
      UnloadModel(FCloudModel);
  end;
  if FCloudTex.id > 0 then
    UnloadTexture(FCloudTex);
  if FAmbientGradientTex.id > 0 then
    UnloadTexture(FAmbientGradientTex);
end;
destructor TLandWorld.Destroy;
begin
  UnloadAssets;
  inherited;
end;
procedure TLandWorld.Update(dt: Single; const CameraPos: TVector3;
  DayTime: Single; DaySpeed: Single; RhythmActive: Boolean);
begin
  FTime := FTime + dt;
  FCameraPos := CameraPos;
  // Scroll cloud texture
  FCloudMoveFactor := FCloudMoveFactor + 0.002 * dt;
  if FCloudMoveFactor > 1.0 then
    FCloudMoveFactor := FCloudMoveFactor - 1.0;
end;
procedure TLandWorld.RenderSkybox(const Camera: TCamera3D; DayTime: Single);
var
  ViewMat, ProjMat: TMatrix;
begin
  if FSkyboxModel.meshes = nil then
    Exit;
  rlDisableDepthMask();
  ViewMat := GetCameraMatrix(Camera);
  ProjMat := MatrixPerspective(Camera.fovy * DEG2RAD,
    GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
  SetShaderValueMatrix(FSkyboxShader, FSkyboxViewLoc, ViewMat);
  SetShaderValueMatrix(FSkyboxShader, FSkyboxProjLoc, ProjMat);
  // Set the daytime uniform so the skybox shader blends horizon and
  // zenith colors correctly. Without this the shader defaults to
  // daytime=0 (midnight) and renders pure black - which was the cause
  // of the "Land skybox is just black" bug.
  SetShaderValue(FSkyboxShader, FSkyboxDaytimeLoc, @DayTime,
    SHADER_UNIFORM_FLOAT);
  // Assign skybox texture if loaded
  if FSkyboxTex.id > 0 then
    FSkyboxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FSkyboxTex;
  rlDisableBackfaceCulling();
  DrawModel(FSkyboxModel, Camera.position, 1.0, WHITE);
  rlEnableBackfaceCulling();
  rlEnableDepthMask();
end;
procedure TLandWorld.RenderClouds(const Camera: TCamera3D; DayTime: Single);
begin
  if FCloudModel.meshes = nil then
    Exit;
  BeginShaderMode(FCloudShader);
  SetShaderValue(FCloudShader, FCloudMoveFactorLoc, @FCloudMoveFactor,
    SHADER_UNIFORM_FLOAT);
  SetShaderValue(FCloudShader, FCloudDaytimeLoc, @DayTime,
    SHADER_UNIFORM_FLOAT);
  DrawModel(FCloudModel,
    Vector3Create(Camera.position.x, 150, Camera.position.z), 1.0, WHITE);
  EndShaderMode();
end;
procedure TLandWorld.Render(const Camera: TCamera3D; DayTime: Single);
begin
  // 1. Skybox with day/night gradient
  RenderSkybox(Camera, DayTime);
  // 2. Green grass floor
  if FLightShader.id > 0 then
    BeginShaderMode(FLightShader);
  DrawPlane(Vector3Create(0, 0, 0),
    Vector2Create(FFloorSize, FFloorSize), DARKGREEN);
  if FLightShader.id > 0 then
    EndShaderMode();
  // 3. Scrolling clouds
  RenderClouds(Camera, DayTime);
end;
procedure TLandWorld.RenderShadows;
begin
  // The floor is the only shadow-casting surface.
  DrawPlane(Vector3Create(0, 0, 0),
    Vector2Create(FFloorSize, FFloorSize), BLACK);
end;
end.

