unit Yutani.Worlds.YourWorld;

{==============================================================================*
 *  Yutani World: YourWorld - Empty World Template
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Skeleton unit for building your own custom world type.
 *
 *  Interface contract:
 *    Every world unit must expose Update / Render / RenderShadows so
 *    the sandbox can call them uniformly from its main loop. The
 *    constructor takes the lighting shader so worlds that need custom
 *    shaders (like Space does for planets) can assign it to their
 *    models. Worlds that don't need it can ignore the parameter.
 *
 *  Integration steps:
 *    1. Copy this file to Yutani.Worlds.YourName.pas
 *    2. Rename the unit line and the class name
 *    3. Add your world to TWorldBaseType in Yutani.Core
 *    4. Add a field FYourWorld: TYourWorld to TYutaniRaylibSandbox
 *    5. In SetWorldBase: create the world instance on first switch
 *    6. In Render3DSceneCore: call FYourWorld.Render when active
 *    7. In DrawSceneShadows: call FYourWorld.RenderShadows
 *    8. In UpdateGame: call FYourWorld.Update(dt, CameraPos, FDayTime)
 *    9. In destructor: FreeAndNil(FYourWorld)
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Math, Raylib, RayMath, rlgl;

type
  /// <summary>
  /// Skeleton world class. Override Update / Render / RenderShadows
  /// with your world's specific logic. The constructor receives the
  /// sandbox's lighting shader so you can assign it to any custom
  /// models you load - worlds that don't use models can ignore it.
  /// </summary>
  TYourWorld = class
  private
    FTime: Single;
    FCameraPos: TVector3;
    FFloorSize: Single;
  public
    constructor Create(const ALightShader: TShader);
    destructor Destroy; override;

    /// <summary>
    /// Called every frame from UpdateGame. dt is the unscaled frame
    /// delta. CameraPos is the current camera position in world space.
    /// DayTime (0..1) is the current position in the day/night cycle
    /// - ignore it if your world doesn't have a day/night rhythm.
    /// </summary>
    procedure Update(dt: Single; const CameraPos: TVector3;
      DayTime: Single = 0.5); virtual;

    /// <summary>
    /// Called from Render3DSceneCore while inside BeginMode3D. Draw
    /// your skybox, floor, terrain, background objects, etc. here.
    /// The Camera parameter gives you position/target/up/fovy for
    /// shader uniform updates or custom projection tricks.
    /// </summary>
    procedure Render(const Camera: TCamera3D); virtual;

    /// <summary>
    /// Called from DrawSceneShadows while inside BeginMode3D with the
    /// light camera. Draw solid-black silhouettes of everything that
    /// should cast shadows. This runs inside a render-texture pass so
    /// only depth matters - color is ignored.
    /// </summary>
    procedure RenderShadows; virtual;
  end;

implementation

{ TYourWorld }

constructor TYourWorld.Create(const ALightShader: TShader);
begin
  inherited Create;
  FTime := 0;
  FCameraPos := Vector3Create(0, 0, 0);
  FFloorSize := 500.0;
  // TODO: Load textures, generate meshes, init procedural systems, etc.
end;

destructor TYourWorld.Destroy;
begin
  // TODO: Unload textures, free models, release GPU resources, etc.
  inherited;
end;

procedure TYourWorld.Update(dt: Single; const CameraPos: TVector3;
  DayTime: Single);
begin
  FTime := FTime + dt;
  FCameraPos := CameraPos;
  // TODO: Advance procedural animations, update particle systems,
  // move orbiting objects, etc.
end;

procedure TYourWorld.Render(const Camera: TCamera3D);
begin
  // Basic starter world: a dark gray floor + a reference grid so the
  // void is not empty. Replace with your own rendering when you build
  // your custom world.

  // 1. Skybox: draw the skybox model if passed by the Core (optional
  //    - the constructor doesn't take one, so skip for now).

  // 2. Floor: dark gray plane so the ground is visible
  DrawPlane(Vector3Create(0, 0, 0),
    Vector2Create(FFloorSize, FFloorSize), DARKGRAY);

  // 3. Grid: Raylib's built-in grid for spatial reference
  DrawGrid(40, 10.0);

  // TODO: Add your custom objects, particles, terrain, etc. here.
end;

procedure TYourWorld.RenderShadows;
begin
  // Draw the floor as a shadow-casting surface.
  DrawPlane(Vector3Create(0, 0, 0),
    Vector2Create(FFloorSize, FFloorSize), BLACK);
  // TODO: Add shadow silhouettes for your custom objects here.
end;

end.

