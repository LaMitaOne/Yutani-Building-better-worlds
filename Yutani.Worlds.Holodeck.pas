unit Yutani.Worlds.Holodeck;

{==============================================================================*
 *  Yutani World: Holodeck - Glowing Orange Grid Room
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    The Holodeck world: a pure black void with a warm orange wireframe
 *    grid on the floor. No skybox texture, no clouds, no day/night cycle.
 *    The cleanest possible environment for testing physics and rendering
 *    without visual distractions.
 *
 *  Visual layout:
 *    - Floor: 1000x1000 black plane at Y=0
 *    - Grid: 200 slices at 5.0 spacing, warm orange (255, 130, 0)
 *    - Skybox: pure black (the cube mesh is drawn with BLACK tint)
 *    - No clouds, no atmosphere, no particle systems
 *
 *  Integration:
 *    Replace the inline Holodeck rendering in Yutani.Core.Render3DSceneCore
 *    with a call to FHolodeckWorld.Render(Camera). Same for shadows.
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Math, Raylib, RayMath, rlgl;

type
  /// <summary>
  /// Holodeck world: black floor + orange grid + black skybox.
  /// No day/night cycle, no clouds, no atmosphere. The simplest
  /// possible world for clean physics testing.
  /// </summary>
  THolodeckWorld = class
  private
    FGridSlices: Integer;
    FGridSpacing: Single;
    FGridColor: TColorB;
    FFloorSize: Single;
    FTime: Single;
    FCameraPos: TVector3;
    procedure DrawGrid3D(Slices: Integer; Spacing: Single;
      GridColor: TColorB; const Camera: TCamera3D);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Update(dt: Single; const CameraPos: TVector3;
      DayTime: Single = 0.5);
    procedure Render(const Camera: TCamera3D; const SkyboxModel: TModel);
    procedure RenderShadows;
    procedure RenderSkybox(const Camera: TCamera3D; const SkyboxModel: TModel);

    property GridSlices: Integer read FGridSlices write FGridSlices;
    property GridSpacing: Single read FGridSpacing write FGridSpacing;
    property GridColor: TColorB read FGridColor write FGridColor;
    property FloorSize: Single read FFloorSize write FFloorSize;
  end;

implementation

{ THolodeckWorld }

constructor THolodeckWorld.Create;
begin
  inherited Create;
  FGridSlices := 200;
  FGridSpacing := 5.0;
  FFloorSize := 1000.0;
  // Warm orange matching the original inline values in Yutani.Core
  FGridColor.r := 255;
  FGridColor.g := 130;
  FGridColor.b := 0;
  FGridColor.a := 255;
  FTime := 0;
  FCameraPos := Vector3Create(0, 0, 0);
end;

destructor THolodeckWorld.Destroy;
begin
  // No GPU resources owned by this world - the floor and grid are
  // drawn with immediate-mode Raylib primitives, not loaded assets.
  inherited;
end;

procedure THolodeckWorld.Update(dt: Single; const CameraPos: TVector3;
  DayTime: Single);
begin
  FTime := FTime + dt;
  FCameraPos := CameraPos;
  // No state to advance - the grid is static and the day/night
  // cycle is disabled in Holodeck mode.
end;

procedure THolodeckWorld.DrawGrid3D(Slices: Integer; Spacing: Single;
  GridColor: TColorB; const Camera: TCamera3D);
var
  I: Integer;
  HalfSize: Single;
begin
  // Only draw grid if the camera is above ground level. We pass the
  // Camera directly instead of using a cached FCameraPos field so the
  // grid draws even when Update() was never called (the Core doesn't
  // always call Update for lightweight worlds like Holodeck).
  if Camera.position.y <= 0.01 then
    Exit;
  HalfSize := (Slices * Spacing) / 2.0;
  for I := 0 to Slices do
  begin
    var Pos: Single := -HalfSize + (I * Spacing);
    // Draw X-axis lines (going into Z depth)
    DrawLine3D(Vector3Create(Pos, 0.01, -HalfSize),
               Vector3Create(Pos, 0.01, HalfSize), GridColor);
    // Draw Z-axis lines (going across X)
    DrawLine3D(Vector3Create(-HalfSize, 0.01, Pos),
               Vector3Create(HalfSize, 0.01, Pos), GridColor);
  end;
end;

procedure THolodeckWorld.RenderSkybox(const Camera: TCamera3D;
  const SkyboxModel: TModel);
var
  BlackSkyColor: TColorB;
  ViewMat, ProjMat: TMatrix;
  Shader: TShader;
  ViewLoc, ProjLoc: Integer;
begin
  if SkyboxModel.meshes = nil then
    Exit;
  BlackSkyColor := BLACK;
  rlDisableDepthMask();
  // The skybox cube mesh has a gradient shader attached to its
  // material. Without setting the view + projection uniforms the
  // shader renders nothing visible (or at the wrong position), which
  // was the cause of the "just black, nothing visible" bug. We
  // extract the shader from the model and set the uniforms here so
  // the Holodeck world is self-contained.
  Shader := SkyboxModel.materials[0].Shader;
  if Shader.id > 0 then
  begin
    ViewMat := GetCameraMatrix(Camera);
    ProjMat := MatrixPerspective(Camera.fovy * DEG2RAD,
      GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
    ViewLoc := GetShaderLocation(Shader, 'view');
    ProjLoc := GetShaderLocation(Shader, 'projection');
    if ViewLoc >= 0 then
      SetShaderValueMatrix(Shader, ViewLoc, ViewMat);
    if ProjLoc >= 0 then
      SetShaderValueMatrix(Shader, ProjLoc, ProjMat);
  end;
  DrawModel(SkyboxModel, Camera.position, 1.0, BlackSkyColor);
  rlEnableDepthMask();
end;

procedure THolodeckWorld.Render(const Camera: TCamera3D;
  const SkyboxModel: TModel);
begin
  // 1. Skybox - pure black void
  RenderSkybox(Camera, SkyboxModel);

  // 2. Floor - black plane so only the grid lines are visible
  DrawPlane(Vector3Create(0, 0, 0),
    Vector2Create(FFloorSize, FFloorSize), BLACK);

  // 3. Grid - warm orange wireframe on top of the black floor.
  //    Slightly lifted (0.01) to prevent Z-fighting with the plane.
  DrawGrid3D(FGridSlices, FGridSpacing, Fade(FGridColor, 0.85), Camera);
end;

procedure THolodeckWorld.RenderShadows;
begin
  // The floor is the only shadow-casting surface in the Holodeck.
  // Dynamic objects are drawn by the sandbox's own DrawSceneShadows loop.
  DrawPlane(Vector3Create(0, 0, 0),
    Vector2Create(FFloorSize, FFloorSize), BLACK);
end;

end.

