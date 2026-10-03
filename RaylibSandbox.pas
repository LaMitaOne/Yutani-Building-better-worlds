unit RaylibSandbox;

{==============================================================================*
 *  Yutani RaylibSandbox v0.641 - Multi-threaded Raylib + Jolt 3D Editor
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    This component embeds a Raylib rendering window inside a standard Delphi
 *    VCL application. It runs the Raylib main loop and physics simulation
 *    (via JoltPhysics) in a separate background thread to prevent blocking
 *    the VCL UI thread. It implements a full 3D scene editor core with
 *    advanced rendering, physics interactions, and integrated multimedia.
 *
 *  Architecture:
 *    - TRaylibSandbox inherits from TWinControl to provide a HWND parent
 *      for the Raylib window.
 *    - A TThread is used to run InitWindow, the main Update/Render loop, and
 *      shutdown procedures.
 *    - The component intercepts desktop mouse inputs globally to allow
 *      dragging objects in the 3D space, manipulating the camera, and
 *      interacting with 3D Gizmos.
 *    - Thread-safe communication between VCL and the Raylib thread is handled
 *      via Critical Sections and queued execution methods.
 *
 *  Core Editor Features:
 *    - Spawning dynamic objects (Cubes, Spheres, Pyramids, Capsules, Prisms)
 *      that interact with a static floor and walls using Jolt Physics.
 *    - Orbit camera (Middle Mouse Button), Zoom (Mouse Wheel), and WASD/Arrow
 *      key panning with world boundaries.
 *    - Shooting mechanic: Fire persistent blue cannonball projectiles.
 *    - Custom GLSL Lighting System implementing basic ambient and diffuse
 *      shading, including dynamic real-time Shadow Mapping.
 *    - Context Menu & Selection: Right-click context menus, TreeView sync,
 *      and Object Inspector property editing via RTTI.
 *    - Scene Save/Load: Serialize and deserialize dynamic actors to binary
 *      files, preserving transforms, colors, and model references.
 *
 *  Editor Gizmo System:
 *    - Full Translate, Rotate, and Scale Gizmos (toggled via CTRL).
 *    - Gizmos align perfectly to the object's local rotation.
 *    - Per-Axis Scaling: Gizmo arrows dynamically resize to match the
 *      object's scale on each specific axis, ensuring they are always
 *      grabbable regardless of object dimensions.
 *    - Safe Editing: When a Gizmo is dragged, the target object is detached
 *      from Jolt Physics. Upon mouse release, the object is cleanly re-attached
 *      to the physics world with its new transform.
 *
 *  Interactive 3D Piano System:
 *    - Standalone TPiano component spawning a solid wooden base and perfectly
 *      aligned white/black keys.
 *    - Keys are rendered as pure 3D objects (stBox) without physics jitter.
 *    - Mouse raycasting accurately detects key presses even at steep camera
 *      angles. Keys animate downwards on press.
 *    - Quick-parenting logic ensures keys move together with the base when
 *      the base is moved via Gizmos.
 *
 *  Integrated Audio & Multimedia:
 *    - Yutani.Audio Engine: Dynamically loads TinySoundFont DLL. Features an
 *      on-demand audio thread that wakes up on MIDI input and pauses after 2s
 *      of idle time to save CPU.
 *    - 3D Piano keys trigger live MIDI notes to the audio engine.
 *    - MPV Embedded Video Player: Allows spawning 3D screens that play video
 *      files mapped directly to mesh textures.
 *    - MiniAudio integration for standard sound effects (impacts, explosions).
 *
 *  Environment & World Building:
 *    - Custom World Bases: Switch between Land (day/night cycle, clouds),
 *      Space (pure black void), and Holodeck (glowing orange grid) environments.
 *    - Dynamic Skybox Shaders: Horizon and zenith colors blend based on the
 *      time of day.
 *    - Spawn Effects: Enterprise transporter beam and simple fade effects.
 *    - Bomb System: Spawning destructible walls and triggering physics-based
 *      explosions with radial impulse forces.
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 * Apache-2.0 license
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  Winapi.Windows, Winapi.MultiMon, Winapi.MMSystem, System.SysUtils,
  System.Classes, System.Math, System.SyncObjs, Vcl.Controls, Vcl.Forms,
  Vcl.Graphics, Raylib, RayMath, rlgl, ModelEngine, JoltPhysics,
  MiniAudio4Delphi, MPVManager, MPVEmbedded, Yutani.Audio;

type
  PItemData = ^TItemData;

  TObjectSelectedEvent = procedure(Sender: TObject; Actor: TA3DComponent) of object;

  TItemData = record
    SpawnTime: Double;
    LastHitTime: Double;
    IsProjectile: Boolean;
    Name: string;
    OldVelocity: TVector3;
  end;
  // Custom Spawn Request record for external tools like VCL3D.pas

  TSpawnRequest = record
    Shape: TShapeType;
    Pos: TVector3;
    Size: TVector3;
    IsStatic: Boolean;
    IsDestructable: Boolean;
    Name: string;
    Color: TColorB;
    Caption: string;
    BaseColor: TColorB;
    HoverColor: TColorB;
    OnClick: TNotifyEvent;
    GenerateTestTexture: Boolean;
  end;

  TWorldBaseType = (wbLand, wbSpace, wbHolodeck, wbIsland);

  // Spawn effect types for manual and scripted spawns
  TSpawnEffectType = (spefNone, spefBeam, spefFade);

  // Record to track an active spawn effect
  TSpawnEffect = record
    Position: TVector3;
    StartTime: Double;
    Duration: Single;
    EffectType: TSpawnEffectType;
    TargetActor: TA3DComponent;
  end;

  // Spawn effect types for manual and scripted spawns
  TSpawnEffectType = (spefNone, spefBeam, spefFade);

  // Record to track an active spawn effect
  TSpawnEffect = record
    Position: TVector3;
    StartTime: Double;
    Duration: Single;
    EffectType: TSpawnEffectType;
    TargetActor: TA3DComponent;
  end;

  TRaylibSandbox = class;

  TActorEventArgs = record
    Actor: TA3DComponent;
    Index: Integer;
  end;

  TEngineExceptionEventArgs = record
    Message: string;
    Context: string;
    Timestamp: TDateTime;
  end;

  TActorEvent = procedure(Sender: TObject; const Args: TActorEventArgs) of object;

  TNotifyEngineEvent = procedure(Sender: TObject) of object;

  TEngineExceptionEvent = procedure(Sender: TObject; const Args: TEngineExceptionEventArgs) of object;

  TGizmoMode = (gmNone, gmTranslate, gmRotate, gmScale, gmDragAndThrow);

  // Independent Piano Component
  // Encapsulates the piano base and all keys as a single logical unit
  TPiano = class
  private
    FSandbox: TRaylibSandbox;
    FBase: TA3DComponent;
    FKeys: TArray<TA3DComponent>;
  public
    constructor Create(ASandbox: TRaylibSandbox);
    destructor Destroy; override;
    procedure PressKey(Index: Integer);
    procedure ReleaseKey(Index: Integer);
    function GetKey(Index: Integer): TA3DComponent;
    function KeyCount: Integer;
    property Base: TA3DComponent read FBase;
  end;

  TRaylibSandbox = class(TWinControl)
  private
    FThread: TThread;
    FLock: TCriticalSection;
    FTargetFPS: Integer;
    FThreadActive: Boolean;
    FPaused: Boolean;
    FActive: Boolean;
    FRaylibWnd: HWND;
    FInitialized: Boolean;
    FEngine: TModelEngine;
    FFloorActor: TA3DComponent;
    FItemSelected: TA3DComponent;
    FDragging: Boolean;
    FDragTargetPos: TVector3;
    FMousePos: TVector2;
    FCamera: TCamera3D;
    FCamYaw, FCamPitch, FCamDist: single;
    FLastMouse: TPoint;
    FDraggingRMB: boolean;
    FHUDAnimY: single;
    FSceneStartTime: Double;
    FSpawnQueue: Integer;
    FSpawnTimer: Single;
    FSpawnShape: TShapeType;
    FClearItemsQueued: Boolean;
    FUnitCylinder: TMesh;
    FUnitCone: TMesh;
    FUnitPrism: TMesh;
    FBoxModel: TModel;
    FSphereModel: TModel;
    FCapsuleModel: TModel;
    FPyramidModel: TModel;
    FPrismModel: TModel;

    // Lighting & Shadow Map
    FLightShader: TShader;
    FLightPos: TVector3;
    FLightPosLoc: Integer;
    FViewPosLoc: Integer;
    FAmbientLoc: Integer;
    FDiffuseLoc: Integer;
    FShadowMap: TRenderTexture2D;
    FShadowMapDirty: Boolean;
    FDefaultMat: TMaterial;
    FWhiteTex: TTexture2D;
    FDefaultWhiteTex: TTexture2D; // Safe base texture for standard models
    FLightCam: TCamera3D;
    FShadowMapLoc: Integer;
    FLightViewLoc: Integer;
    FLightProjLoc: Integer;
    FShadowBias: Single;
    FUnitBox: TMesh;
    FUnitSphere: TMesh;
    FCameraMoved: Boolean;

    // Optimization: Cached default shader for shadow map rendering
    FDefaultShader: TShader;

    // Skybox & Environment
    FSkyboxModel: TModel;
    FSkyboxShader: TShader;
    FSkyboxDaytimeLoc: Integer;
    FSkyboxViewLoc: Integer;
    FSkyboxProjLoc: Integer;
    FSkyboxTex: TTexture2D;

    FCloudModel: TModel;
    FCloudShader: TShader;
    FCloudTex: TTexture2D;
    FCloudMoveFactor: Single;
    FCloudMoveFactorLoc: Integer;
    FCloudDaytimeLoc: Integer;

    FAmbientGradientTex: TTexture2D;
    FDayTime: Single;
    FDaySpeed: Single;
    FSunPos: TVector3;
    FSunColor: TVector4;
    FAmbientColor: TVector4;

    FProjectiles: TArray<TA3DComponent>;
    FShootCooldown: Single;
    FRightClickWasPressed: Boolean;
    FOnViewportReady: TNotifyEngineEvent;
    FOnActorSpawned: TActorEvent;
    FOnActorDestroyed: TActorEvent;
    FOnSceneCleared: TNotifyEngineEvent;
    FOnEngineException: TEngineExceptionEvent;
    FOnObjectSelected: TObjectSelectedEvent;
    FOnViewportRightClick: TNotifyEngineEvent;
    FBrushShape: TShapeType;
    FSimulationRunning: Boolean;
    FGhostPos: TVector3;
    FGizmoMode: TGizmoMode;
    FGizmoAxis: Integer;
    FGizmoHoverAxis: Integer;
    FGizmoDragging: Boolean;
    FGizmoStartMouse: TVector2;
    FGizmoStartVal: TVector3;
    FGizmoStartPos: TVector3; // Needed for Y-Lift calculation in Scale Mode!
    FGizmoStartQuat: TQuaternion;
    FCtrlWasPressed: Boolean;
    FMouseLeftPressed: Boolean;
    FHighlightCollision: Boolean;
    FActiveBodies: Integer;
    FLastPhysicsTime: Single;
    FSpawnButton1WasDown: Boolean;
    FSpawnButton2WasDown: Boolean;
    FSpawnButton3WasDown: Boolean;
    FSpawnButton4WasDown: Boolean;
    FSpawnButton5WasDown: Boolean;
    FFrustumCulling: Boolean;
    FDistanceCulling: Boolean;
    FPopupOpen: Boolean;
    FPopupPos: TVector2;
    FPopupSegments: array of string;
    FPopupHoverIndex: Integer;
    FPopupCloseLock: Boolean;
    FLoadModelQueued: Boolean;
    FQueuedModelPath: string;
    FNavIndex: Integer;

    // Manual Day/Night Properties
    FDayNightRhythmActive: Boolean;

    // Distance Culling customizable property
    FMaxRenderDistance: Single;

    // Thread-safe Custom Spawn Queue
    FCustomSpawnQueue: TArray<TSpawnRequest>;
    FCustomSpawnTimer: Single;

    // Bomb System Variables
    FBombActor: TA3DComponent;
    FBombTimer: Single;
    FBombExploded: Boolean;

    // Slow Motion System Variables
    FTimeScale: Single;
    FSlowMotionActive: Boolean;

    // Scene Save/Load Queues
    FSaveSceneQueued: Boolean;
    FQueuedSavePath: string;
    FLoadSceneQueued: Boolean;
    FQueuedLoadPath: string;

    // AV System
    FMPVPlayer: TMPVPlayer;

    //base world
    FCurrentWorldBase: TWorldBaseType;

    // Spawn Effect System
    FSpawnEffectType: TSpawnEffectType;
    FActiveSpawnEffects: TArray<TSpawnEffect>;
    FAntiAliasing: Boolean;
    FGravity: Single;

    // Independent Piano Component
    FPiano: TPiano;

    // Spawn Effect System
    FSpawnEffectType: TSpawnEffectType;
    FActiveSpawnEffects: TArray<TSpawnEffect>;
    FAntiAliasing: Boolean;
    FGravity: Single;

    procedure UpdateBomb(dt: Single);
    procedure ExplodeBomb;

    procedure ProcessCustomSpawnQueue(dt: Single);

    procedure SetDayNightTime(const Value: Single);
    procedure SetDayNightRhythmActive(const Value: Boolean);
    procedure SetDayNightSpeed(const Value: Single);
    procedure SetWorldBase(const Value: TWorldBaseType);

    procedure LoadModelInThread(const FilePath: string);
    procedure ShootBall;
    procedure UpdateProjectiles(dt: Single);
    procedure InitScene;
    procedure InitLightingAndEnvironment;
    procedure ProcessSpawnQueue(dt: Single);
    procedure HandleCameraInput;
    procedure HandleDesktopInput;
    procedure UpdateGame;
    procedure RenderGame;
    procedure Render3DScene;
    procedure RenderShadowMap;
    procedure DrawSceneShadows;
    procedure DrawGUI;
    procedure DrawGizmo;
    procedure DrawThickRingAt(Center, NormalAxis: TVector3; Radius, Thickness: Single; Color: TColorB);
    procedure UpdateGizmoInteraction;
    function CheckGizmoAxisHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    function CheckGizmoRingHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    function CheckGizmoScaleHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    function CheckButton(x, y, w, h: Integer): Boolean;
    procedure SetActive(const Value: Boolean);
    procedure SetTargetFPS(const Value: Integer);
    procedure SetHighlightCollision(const Value: Boolean);
    procedure StartThread;
    procedure StopThread;
    procedure DoViewportReady;
    procedure DoActorSpawned(Actor: TA3DComponent; Index: Integer);
    procedure DoActorDestroyed(Actor: TA3DComponent; Index: Integer);
    procedure DoSceneCleared;
    procedure DoEngineException(const Msg, Context: string);
    procedure DoObjectSelected(Actor: TA3DComponent);
    procedure DrawNativePopup;
    procedure HandlePopupInput;
    procedure ExecutePopupAction(Index: Integer);
    procedure SetFrustumCulling(const Value: Boolean);
    procedure SetDistanceCulling(const Value: Boolean);
    procedure SetMaxRenderDistance(const Value: Single);
    procedure PlayImpactSound;
    procedure PlaySpawnSound;

    // Internal execution in the main thread
    procedure ExecuteSceneSave(const FileName: string);
    procedure ExecuteSceneLoad(const FileName: string);

<<<<<<< HEAD
    procedure DrawHolodeckGrid(Slices: Integer; Spacing: Single; GridColor: TColorB);
   // Spawn Effect Methods
    procedure TriggerSpawnEffect(const Pos: TVector3; Actor: TA3DComponent);
=======
    procedure DrawHolodeckGrid(Slices: Integer; Spacing: Single; GridColor: TColorB);
   // Spawn Effect Methods
    procedure TriggerSpawnEffect(const Pos: TVector3; Actor: TA3DComponent);
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
    procedure DrawSpawnEffects;

    procedure SetAntiAliasing(const Value: Boolean);
    procedure SetGravity(const Value: Single);
  protected
    procedure Resize; override;
    procedure CreateWindowHandle(const Params: TCreateParams); override;
    procedure DestroyWindowHandle; override;
  public
    FCustomModel: TModel;
    FItems: TArray<TA3DComponent>;
    FMouseLeftHandled: Boolean;
    FSandboxSpawned: Boolean;
    FSpawnStatic: Boolean;
    FSpawnDestructable: Boolean;
    FGhostVisible: Boolean;
    FIsBrushActive: Boolean;
    FAudioEngine: ma_engine;
    FYutaniAudio: TYutaniAudioEngine;
    function ItemCount: Integer;
    procedure ClearItems;
    procedure DeleteSelectedActor;
    procedure SpawnObjects(Count: Integer; ShapeType: TShapeType);
    procedure SetBrush(AShape: TShapeType);
    procedure SetSimulationRunning(AValue: Boolean);
    procedure LoadCustomModel(const FilePath: string);
    function GetSimulationRunning: Boolean;
    function GetActorBoundingBoxWS(Actor: TA3DComponent): TBoundingBox;
    procedure SpawnAtMouse(Pos: TVector3);
    procedure SpawnPiano;
    procedure SelectNextObject;
    procedure SelectPrevObject;

    // Exposes the custom spawn queue to external threads/UI
    procedure QueueCustomSpawn(const Request: TSpawnRequest);

    // External method to toggle slow motion externally
    procedure SetSlowMotion(Active: Boolean);

    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    property OnViewportReady: TNotifyEngineEvent read FOnViewportReady write FOnViewportReady;
    property OnActorSpawned: TActorEvent read FOnActorSpawned write FOnActorSpawned;
    property OnActorDestroyed: TActorEvent read FOnActorDestroyed write FOnActorDestroyed;
    property OnSceneCleared: TNotifyEngineEvent read FOnSceneCleared write FOnSceneCleared;
    property OnEngineException: TEngineExceptionEvent read FOnEngineException write FOnEngineException;
    property OnObjectSelected: TObjectSelectedEvent read FOnObjectSelected write FOnObjectSelected;
    property OnViewportRightClick: TNotifyEngineEvent read FOnViewportRightClick write FOnViewportRightClick;
    procedure SetSelectedActor(AActor: TA3DComponent);
    procedure SetGizmoMode(AMode: TGizmoMode);
    procedure PublicShootBall;
    procedure PlayTestSound;
    property Engine: TModelEngine read FEngine;
    property FrustumCulling: Boolean read FFrustumCulling write SetFrustumCulling;
    property DistanceCulling: Boolean read FDistanceCulling write SetDistanceCulling;
    // Exposed setter to control how far away objects get culled
    property MaxRenderDistance: Single read FMaxRenderDistance write SetMaxRenderDistance;
    procedure ReattachLoadedActor(Actor: TA3DComponent);
    procedure ClearDynamicItemsOnly;

    // Called from VCL to safely queue save/load in the render thread
    procedure SaveSceneToFile(const FileName: string);
    procedure LoadSceneFromFile(const FileName: string);
  published
    property Align;
    property Anchors;
    property Visible;
    property Active: Boolean read FActive write SetActive default False;
    property TargetFPS: Integer read FTargetFPS write SetTargetFPS default 60;
    property HighlightCollision: Boolean read FHighlightCollision write SetHighlightCollision;
    property ActiveBodies: Integer read FActiveBodies;
    property LastPhysicsTime: Single read FLastPhysicsTime;
    // Exposed for Object Inspector to allow manual day/night override
    property DayNightRhythmActive: Boolean read FDayNightRhythmActive write SetDayNightRhythmActive default True;
    property DayNightTime: Single read FDayTime write SetDayNightTime;
    property DayNightSpeed: Single read FDaySpeed write SetDayNightSpeed;
    property CurrentWorldBase: TWorldBaseType read FCurrentWorldBase write SetWorldBase;
    property SpawnEffectType: TSpawnEffectType read FSpawnEffectType write FSpawnEffectType default spefNone;
    property AntiAliasing: Boolean read FAntiAliasing write SetAntiAliasing default True;
    property Gravity: Single read FGravity write SetGravity;
  end;

implementation

const
  COL_PRISM: TColorB = (
    r: 102;
    g: 205;
    b: 170;
    A: 255
  );
// Helper function to render text into a texture so it can be applied to 3D meshes

function DrawTextToTexture(const AText: string; FontSize: Integer; TextColor, BGColor: TColorB): TTexture2D;
var
  Img: TImage;
  W, H: Integer;
  Txt: AnsiString;
begin
  Txt := AnsiString(' ' + AText + ' ');
  if Length(Txt) = 0 then
    Txt := ' ';

  // Calculate width and height for the image canvas
  W := MeasureText(PAnsiChar(Txt), FontSize) + 4;
  H := FontSize + 4;

  // Generate an image filled with the BUTTON COLOR (not transparent!)
  Img := GenImageColor(W, H, BGColor);

  // Draw the text onto the image
  ImageDrawText(@Img, PAnsiChar(Txt), 2, 2, FontSize, TextColor);

  ImageFlipVertical(@Img);

  // Convert the image to a GPU texture
  Result := LoadTextureFromImage(Img);

  // Set trilinear filter so the text doesn't look pixelated up close
  SetTextureFilter(Result, TEXTURE_FILTER_TRILINEAR);

  // Free the CPU-side image data
  UnloadImage(Img);
end;

function GetCollisionHighlightingColor(intensity: Single): TColorB;
begin
  if intensity < 0 then
    intensity := 0;
  if intensity > 1 then
    intensity := 1;
  Result.r := Round(64 * intensity);
  Result.g := Round(224 * intensity);
  Result.b := Round(208 * intensity);
  Result.a := 255;
end;
{ TRaylibSandbox }

constructor TRaylibSandbox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  FThreadActive := False;
  FPaused := True;
  FActive := False;
  FTargetFPS := 60;
  FHighlightCollision := False;
  Width := 800;
  Height := 600;
  FInitialized := False;
  FShadowMap.id := 0;
  FCustomModel.meshes := nil;
  FHUDAnimY := -150.0;
  FSceneStartTime := 0.0;
  FSpawnQueue := 0;
  FSpawnTimer := 0.0;
  FSpawnShape := stBox;
  FSpawnStatic := False;
  FSpawnDestructable := False;
  FClearItemsQueued := False;
  FShootCooldown := 0.0;
  FIsBrushActive := false;
  FSimulationRunning := True;
  FGhostVisible := False;
  FGizmoMode := gmTranslate;
  FGizmoAxis := 0;
  FGizmoHoverAxis := 0;
  FGizmoDragging := False;
  FRightClickWasPressed := False;
  FCtrlWasPressed := False;
  FMouseLeftPressed := False;
  FMouseLeftHandled := False;
  FPopupOpen := False;
  FFrustumCulling := True;
  FDistanceCulling := True;
  FLoadModelQueued := False;
  FQueuedModelPath := '';
  FAudioEngine := nil;
  FShadowBias := 0.003;
  FDayTime := 0.3; // Start at morning
  FDaySpeed := 0.01; // Day cycle speed
  FDayNightRhythmActive := True; // Enable automatic cycle by default
  FNavIndex := -1;

  // Optimization: Initialize default shader ID to 0
  FDefaultShader.id := 0;

  // Default render culling distance
  FMaxRenderDistance := 160.0;

  // Initialize Custom Spawn Queue
  FCustomSpawnQueue := nil;
  FCustomSpawnTimer := 0.0;

  // Initialize Slow Motion System
  FTimeScale := 1.0; // Default to normal speed
  FSlowMotionActive := False;

  // Init Scene Load/Save flags
  FSaveSceneQueued := False;
  FLoadSceneQueued := False;
  FQueuedSavePath := '';
  FQueuedLoadPath := '';

  // BASE WORLD INITIALIZATION: Default to wbHolodeck
  FCurrentWorldBase := wbHolodeck;
<<<<<<< HEAD

  // Initialize Spawn Effect System
  FSpawnEffectType := spefFade;
  FActiveSpawnEffects := nil;
  FAntiAliasing := True;
  FGravity := -9.81;

  // Piano Component init
  FPiano := nil;

  //init audio engines
  FYutaniAudio := TYutaniAudioEngine.Create;
  FYutaniAudio.InitAudio;
  FYutaniAudio.LoadSoundfont(ExtractFilePath(ParamStr(0)) + 'ressources\audio\8bitsf.sf2');
=======

  // Initialize Spawn Effect System
  FSpawnEffectType := spefFade;
  FActiveSpawnEffects := nil;
  FAntiAliasing := True;
  FGravity := -9.81;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
end;

destructor TRaylibSandbox.Destroy;
begin
  StopThread;
  FreeAndNil(FPiano);
  FreeAndNil(FLock);
  FreeAndNil(FYutaniAudio);
  inherited;
end;

procedure TRaylibSandbox.CreateWindowHandle(const Params: TCreateParams);
begin
  inherited;
end;

procedure TRaylibSandbox.DestroyWindowHandle;
begin
  StopThread;
  inherited;
end;

procedure TRaylibSandbox.Resize;
begin
  inherited;
  if FInitialized and (FRaylibWnd <> 0) then
    SetWindowPos(FRaylibWnd, 0, 0, 0, ClientWidth, ClientHeight, SWP_NOZORDER);
end;

procedure TRaylibSandbox.SetActive(const Value: Boolean);
begin
  if FActive <> Value then
  begin
    FActive := Value;
    if FActive then
    begin
      if not FThreadActive then
        StartThread;
      FPaused := False;
    end
    else
      FPaused := True;
  end;
end;

procedure TRaylibSandbox.SetTargetFPS(const Value: Integer);
begin
  if FTargetFPS <> Value then
    FTargetFPS := Value;
end;

procedure TRaylibSandbox.SetHighlightCollision(const Value: Boolean);
var
  i: Integer;
begin
  if FHighlightCollision <> Value then
  begin
    FHighlightCollision := Value;
    if not FHighlightCollision then
    begin
      for i := 0 to High(FItems) do
      begin
        if Assigned(FItems[i]) and (FItems[i] <> FItemSelected) then
          FItems[i].CollisionHighlighting := False;
      end;
    end;
  end;
end;

procedure TRaylibSandbox.SetDayNightRhythmActive(const Value: Boolean);
begin
  if FDayNightRhythmActive <> Value then
    FDayNightRhythmActive := Value;
end;

procedure TRaylibSandbox.SetDayNightTime(const Value: Single);
begin
  // Clamp the value between 0.0 and 1.0 to represent a full 24h cycle
  FDayTime := EnsureRange(Value, 0.0, 1.0);
end;

procedure TRaylibSandbox.SetDayNightSpeed(const Value: Single);
begin
  // Clamp the value to a reasonable range (e.g., 0.0 to pause, up to 1.0 for very fast)
  // Ensure the speed cannot be negative to prevent time going backwards unintentionally
  FDaySpeed := EnsureRange(Value, 0.0, 1.0);
end;

procedure TRaylibSandbox.SetWorldBase(const Value: TWorldBaseType);
begin
  // Prevent cross-thread exceptions by queueing the state change
  // safely into the Raylib render thread.
  if FCurrentWorldBase <> Value then
  begin
    TThread.Queue(nil,
      procedure
      begin
        FCurrentWorldBase := Value;

        // BASE WORLD LOGIC: Apply specific settings per world
        case FCurrentWorldBase of
          wbLand:
            begin
              // Standard environment: Day/night active, clouds visible
              FDayNightRhythmActive := True;
            end;
          wbSpace:
            begin
              // Space environment: Freeze time to night, disable clouds
              FDayNightRhythmActive := False;
              FDayTime := 0.0; // 0.0 represents midnight/deep space
            end;
          wbHolodeck:
            begin
              // Holodeck environment: Freeze time to midday for bright light
              FDayNightRhythmActive := False;
              FDayTime := 0.5; // 0.5 represents midday
            end;
          wbIsland:
            begin
              // Placeholder for later island environment setup
              FDayNightRhythmActive := True;
            end;
        end;

        // Force shadow map to update immediately after a world change
        FShadowMapDirty := True;
      end);
  end;
end;

procedure TRaylibSandbox.SetAntiAliasing(const Value: Boolean);
<<<<<<< HEAD
begin
  if FAntiAliasing <> Value then
  begin
    FAntiAliasing := Value;

    // Anti-Aliasing requires re-creating the Raylib window,
    // so we restart the thread if the engine is already running.
    if FInitialized then
    begin
      StopThread;
      // Give the OS a tiny moment to clean up the HWND
      Sleep(50);
      StartThread;
    end;
  end;
end;

procedure TRaylibSandbox.SetGravity(const Value: Single);
var
  GravVec: JPH_Vec3;
begin
  if FGravity <> Value then
  begin
    FGravity := Value;

    // Apply gravity live to Jolt Physics if engine is running
    if Assigned(FEngine) then
    begin
      GravVec.x := 0;
      GravVec.y := FGravity;
      GravVec.z := 0;
      JPH_PhysicsSystem_SetGravity(FEngine.PhysicsSystem, @GravVec);
    end;
  end;
=======
begin
  if FAntiAliasing <> Value then
  begin
    FAntiAliasing := Value;

    // Anti-Aliasing requires re-creating the Raylib window,
    // so we restart the thread if the engine is already running.
    if FInitialized then
    begin
      StopThread;
      // Give the OS a tiny moment to clean up the HWND
      Sleep(50);
      StartThread;
    end;
  end;
end;

procedure TRaylibSandbox.SetGravity(const Value: Single);
var
  GravVec: JPH_Vec3;
begin
  if FGravity <> Value then
  begin
    FGravity := Value;

    // Apply gravity live to Jolt Physics if engine is running
    if Assigned(FEngine) then
    begin
      GravVec.x := 0;
      GravVec.y := FGravity;
      GravVec.z := 0;
      JPH_PhysicsSystem_SetGravity(FEngine.PhysicsSystem, @GravVec);
    end;
  end;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
end;

procedure TRaylibSandbox.SetBrush(AShape: TShapeType);
begin
  FBrushShape := AShape;
  FIsBrushActive := True;
end;

procedure TRaylibSandbox.SetSimulationRunning(AValue: Boolean);
begin
  FSimulationRunning := AValue;
end;

function TRaylibSandbox.GetSimulationRunning: Boolean;
begin
  Result := FSimulationRunning;
end;

procedure TRaylibSandbox.SetGizmoMode(AMode: TGizmoMode);
begin
  FGizmoMode := AMode;
end;

procedure TRaylibSandbox.SetFrustumCulling(const Value: Boolean);
begin
  FFrustumCulling := Value;
end;

procedure TRaylibSandbox.SetDistanceCulling(const Value: Boolean);
begin
  FDistanceCulling := Value;
end;

procedure TRaylibSandbox.SetMaxRenderDistance(const Value: Single);
begin
  // Allow custom distance culling ranges, enforcing a sane minimum
  if Value > 10.0 then
    FMaxRenderDistance := Value
  else
    FMaxRenderDistance := 10.0;
end;

procedure TRaylibSandbox.InitLightingAndEnvironment;
const
  VERT: AnsiString = '#version 330' + #10 + 'in vec3 vertexPosition;' + #10 + 'in vec3 vertexNormal;' + #10 + 'in vec2 vertexTexCoord;' + #10 + 'in vec4 vertexColor;' + #10 + 'uniform mat4 mvp;' + #10 + 'uniform mat4 matModel;' + #10 + 'uniform mat4 lightView;' + #10 + 'uniform mat4 lightProj;' + #10 + 'out vec3 vNormal;' + #10 + 'out vec2 vTexCoord;' + #10 + 'out vec4 vColor;' + #10 + 'out vec4 vWorldPos;' + #10 + 'out vec4 vLightSpacePos;' + #10 + 'void main()' + #10 + '{' + #10 +
    '  vWorldPos = matModel * vec4(vertexPosition, 1.0);' + #10 + '  vNormal = normalize(mat3(matModel) * vertexNormal);' + #10 + '  vTexCoord = vertexTexCoord;' + #10 + '  vColor = vertexColor;' + #10 + '  vLightSpacePos = lightProj * lightView * vWorldPos;' + #10 + '  gl_Position = mvp * vec4(vertexPosition, 1.0);' + #10 + '}';
<<<<<<< HEAD
  FRAG: AnsiString = '#version 330' + #10 + 'in vec3 vNormal;' + #10 + 'in vec2 vTexCoord;' + #10 + 'in vec4 vColor;' + #10 + 'in vec4 vWorldPos;' + #10 + 'in vec4 vLightSpacePos;' + #10 + 'uniform vec3 lightPos;' + #10 + 'uniform vec3 viewPos;' + #10 + 'uniform vec4 ambient;' + #10 + 'uniform vec4 diffuse;' + #10 + 'uniform sampler2D texture0;' + #10 + 'uniform sampler2D shadowMap;' + #10 + 'uniform float shadowBias;' + #10 + 'out vec4 finalColor;' + #10 + 'void main()' + #10 + '{' + #10 + '  vec3 lightDir = normalize(lightPos - vWorldPos.xyz);' + #10 + '  vec3 normal = normalize(vNormal);' + #10 +
    // Berechne wie viel Licht auf der Seite lag (0 bis 1)
    '  float diff = max(dot(normal, lightDir), 0.0);' + #10 + '  vec4 texColor = texture(texture0, vTexCoord);' + #10 + '  vec4 baseColor = vec4(vColor.rgb, vColor.a) * vec4(texColor.rgb, 1.0);' + #10 +
    // Schatten berechnen
    '  vec3 projCoords = vLightSpacePos.xyz / vLightSpacePos.w;' + #10 + '  projCoords = projCoords * 0.5 + 0.5;' + #10 + '  float shadow = 0.0;' + #10 + '  if(projCoords.z <= 1.0 && projCoords.x >= 0.0 && projCoords.x <= 1.0 && projCoords.y >= 0.0 && projCoords.y <= 1.0) {' + #10 + '    float closestDepth = texture(shadowMap, projCoords.xy).r;' + #10 + '    float currentDepth = projCoords.z;' + #10 + '    shadow = currentDepth - shadowBias > closestDepth ? 1.0 : 0.0;' + #10 + '  }' + #10 +
    // NEUE BELEUCHTUNGSFORMEL: Ambient + Diffuse * (1.0 - Shadow)
    // Das Licht wird limitiert, sodass es nie heller als 1.0 wird!
    '  float lightIntensity = ambient.r + (1.0 - ambient.r) * diff * (1.0 - shadow);' + #10 + '  vec3 finalLight = diffuse.rgb * lightIntensity;' + #10 +
    // Textur/Farbe mit Licht multiplizieren (Schwarz bleibt Schwarz, Farben verblassen nicht)
    '  finalColor = vec4(baseColor.rgb * finalLight, baseColor.a * vColor.a);' + #10 + '}';
  SKYBOX_VERT: AnsiString = '#version 330' + #10 + 'in vec3 vertexPosition;' + #10 + 'out vec3 fragPosition;' + #10 + 'uniform mat4 projection;' + #10 + 'uniform mat4 view;' + #10 + 'void main()' + #10 + '{' + #10 + '  fragPosition = vertexPosition;' + #10 + '  mat4 rotView = mat4(mat3(view));' + #10 + '  vec4 clipPos = projection * rotView * vec4(vertexPosition, 1.0);' + #10 + '  gl_Position = clipPos.xyww;' + #10 + // Force depth to 1.0 (background)
=======
  FRAG: AnsiString = '#version 330' + #10 + 'in vec3 vNormal;' + #10 + 'in vec2 vTexCoord;' + #10 + 'in vec4 vColor;' + #10 + 'in vec4 vWorldPos;' + #10 + 'in vec4 vLightSpacePos;' + #10 + 'uniform vec3 lightPos;' + #10 + 'uniform vec3 viewPos;' + #10 + 'uniform vec4 ambient;' + #10 + 'uniform vec4 diffuse;' + #10 + 'uniform sampler2D texture0;' + #10 + 'uniform sampler2D shadowMap;' + #10 + 'uniform float shadowBias;' + #10 + 'out vec4 finalColor;' + #10 + 'void main()' + #10 + '{' + #10 +
    '  vec3 lightDir = normalize(lightPos - vWorldPos.xyz);' + #10 + '  vec3 normal = normalize(vNormal);' + #10 +
    // Berechne wie viel Licht auf der Seite liegt (0 bis 1)
    '  float diff = max(dot(normal, lightDir), 0.0);' + #10 +
    '  vec4 texColor = texture(texture0, vTexCoord);' + #10 +
    '  vec4 baseColor = vec4(vColor.rgb, vColor.a) * vec4(texColor.rgb, 1.0);' + #10 +
    // Schatten berechnen
    '  vec3 projCoords = vLightSpacePos.xyz / vLightSpacePos.w;' + #10 +
    '  projCoords = projCoords * 0.5 + 0.5;' + #10 + '  float shadow = 0.0;' + #10 + '  if(projCoords.z <= 1.0 && projCoords.x >= 0.0 && projCoords.x <= 1.0 && projCoords.y >= 0.0 && projCoords.y <= 1.0) {' + #10 + '    float closestDepth = texture(shadowMap, projCoords.xy).r;' + #10 + '    float currentDepth = projCoords.z;' + #10 + '    shadow = currentDepth - shadowBias > closestDepth ? 1.0 : 0.0;' + #10 + '  }' + #10 +
    // NEUE BELEUCHTUNGSFORMEL: Ambient + Diffuse * (1.0 - Shadow)
    // Das Licht wird limitiert, sodass es nie heller als 1.0 wird!
    '  float lightIntensity = ambient.r + (1.0 - ambient.r) * diff * (1.0 - shadow);' + #10 +
    '  vec3 finalLight = diffuse.rgb * lightIntensity;' + #10 +
    // Textur/Farbe mit Licht multiplizieren (Schwarz bleibt Schwarz, Farben verblassen nicht)
    '  finalColor = vec4(baseColor.rgb * finalLight, baseColor.a * vColor.a);' + #10 + '}';    SKYBOX_VERT: AnsiString = '#version 330' + #10 + 'in vec3 vertexPosition;' + #10 + 'out vec3 fragPosition;' + #10 + 'uniform mat4 projection;' + #10 + 'uniform mat4 view;' + #10 + 'void main()' + #10 + '{' + #10 + '  fragPosition = vertexPosition;' + #10 + '  mat4 rotView = mat4(mat3(view));' + #10 +
    '  vec4 clipPos = projection * rotView * vec4(vertexPosition, 1.0);' + #10 + '  gl_Position = clipPos.xyww;' + #10 + // Force depth to 1.0 (background)
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
    '}';
  SKYBOX_FRAG: AnsiString = '#version 330' + #10 + 'in vec3 fragPosition;' + #10 + 'uniform float daytime;' + #10 + 'out vec4 finalColor;' + #10 + 'void main()' + #10 + '{' + #10 + '  vec3 dir = normalize(fragPosition);' + #10 + '  float t = dir.y * 0.5 + 0.5;' + #10 +
    // Mix horizon and zenith colors based on day/night
    '  vec3 horizonColor = mix(vec3(0.8, 0.4, 0.1), vec3(0.2, 0.4, 0.8), smoothstep(0.0, 0.3, daytime));' + #10 + '  vec3 zenithColor = mix(vec3(0.05, 0.05, 0.1), vec3(0.0, 0.4, 0.9), smoothstep(0.0, 0.5, daytime));' + #10 + '  vec3 skyColor = mix(horizonColor, zenithColor, smoothstep(0.0, 0.4, t));' + #10 + '  finalColor = vec4(skyColor, 1.0);' + #10 + '}';
  // Cloud Shader
  CLOUD_VERT: AnsiString = '#version 330' + #10 + 'in vec3 vertexPosition;' + #10 + 'in vec2 vertexTexCoord;' + #10 + 'out vec2 vTexCoord;' + #10 + 'uniform mat4 mvp;' + #10 + 'void main()' + #10 + '{' + #10 + '  vTexCoord = vertexTexCoord;' + #10 + '  gl_Position = mvp * vec4(vertexPosition, 1.0);' + #10 + '}';
  CLOUD_FRAG: AnsiString = '#version 330' + #10 + 'in vec2 vTexCoord;' + #10 + 'out vec4 finalColor;' + #10 + 'uniform sampler2D texture0;' + #10 + 'uniform float moveFactor;' + #10 + 'uniform float daytime;' + #10 + 'void main()' + #10 + '{' + #10 + '  vec2 uv = vTexCoord + vec2(moveFactor, moveFactor * 0.5);' + #10 + '  vec4 cloudTex = texture(texture0, uv);' + #10 + '  vec3 cloudColor = mix(vec3(0.2, 0.2, 0.2), vec3(1.0, 1.0, 1.0), daytime);' + #10 + '  finalColor = vec4(cloudColor, cloudTex.a * 0.8);' + #10 + '}';
var
  SkyMesh, CloudMesh: TMesh;
  FilePath: string;
begin
  // Sichere 1x1 weiße Textur generieren, damit Shader nie ins Leere laufen (Schwarz)
  var WhiteImg := GenImageColor(1, 1, WHITE);
  FDefaultWhiteTex := LoadTextureFromImage(WhiteImg);
  UnloadImage(WhiteImg);

  // Initialize Main Lighting Shader
  FLightShader := LoadShaderFromMemory(PAnsiChar(VERT), PAnsiChar(FRAG));
  FLightPosLoc := GetShaderLocation(FLightShader, 'lightPos');
  FViewPosLoc := GetShaderLocation(FLightShader, 'viewPos');
  FAmbientLoc := GetShaderLocation(FLightShader, 'ambient');
  FDiffuseLoc := GetShaderLocation(FLightShader, 'diffuse');
  FShadowMapLoc := GetShaderLocation(FLightShader, 'shadowMap');
  FLightViewLoc := GetShaderLocation(FLightShader, 'lightView');
  FLightProjLoc := GetShaderLocation(FLightShader, 'lightProj');

  // Optimization: Create the default shader once to prevent loading/unloading it every frame in RenderShadowMap
  FDefaultShader := LoadShader(nil, nil);

  FShadowMap := LoadRenderTexture(2048, 2048);
  SetTextureFilter(FShadowMap.texture, TEXTURE_FILTER_TRILINEAR);

  FLightPos := Vector3Create(50, 80, 30);
  FCameraMoved := True;

  FLightCam.position := Vector3Create(0, 80, 0);
  FLightCam.target := Vector3Create(0, 0, 0);
  FLightCam.up := Vector3Create(0, 1, 0);
  FLightCam.fovy := 20.0;
  FLightCam.projection := CAMERA_ORTHOGRAPHIC;

  SetTextureFilter(FWhiteTex, TEXTURE_FILTER_TRILINEAR);
  FDefaultMat := LoadMaterialDefault();
  FDefaultMat.shader := FLightShader;
  FDefaultMat.maps[MATERIAL_MAP_ALBEDO].Color := WHITE;

  FUnitBox := GenMeshCube(1.0, 1.0, 1.0);
  UploadMesh(@FUnitBox, False);
  FUnitSphere := GenMeshSphere(1.0, 16, 16);
  UploadMesh(@FUnitSphere, False);

  // Generate standard meshes for solid drawing
  FUnitCylinder := GenMeshCylinder(0.5, 1.0, 24);
  UploadMesh(@FUnitCylinder, False);
  FUnitCone := GenMeshCone(0.5, 1.0, 4);
  UploadMesh(@FUnitCone, False);
  FUnitPrism := GenMeshCylinder(0.5, 1.0, 3);
  UploadMesh(@FUnitPrism, False);

  // Generate models for all primitive shapes to ensure consistent shader handling
  FBoxModel := LoadModelFromMesh(GenMeshCube(1.0, 1.0, 1.0));
  FSphereModel := LoadModelFromMesh(GenMeshSphere(1.0, 16, 16));
  FCapsuleModel := LoadModelFromMesh(GenMeshCylinder(0.5, 1.0, 24));
  FPyramidModel := LoadModelFromMesh(GenMeshCone(0.5, 1.0, 4));
  FPrismModel := LoadModelFromMesh(GenMeshCylinder(0.5, 1.0, 3));

  // We assign a rotation quaternion so the shader knows the normals rotate with the object
  FPrismModel.transform := MatrixRotateY(120.0 * DEG2RAD);
  FBoxModel.materials[0].shader := FLightShader;
  FSphereModel.materials[0].shader := FLightShader;
  FCapsuleModel.materials[0].shader := FLightShader;
  FPyramidModel.materials[0].shader := FLightShader;
  FPyramidModel.transform := MatrixRotateY(45.0 * DEG2RAD);
  FPrismModel.transform := MatrixRotateY(120.0 * DEG2RAD);
  FPrismModel.materials[0].shader := FLightShader;

  // Sichere weiße Standard-Textur für alle Modelle setzen!
  FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  FSphereModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  FCapsuleModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

  // Initialize Skybox
  FSkyboxShader := LoadShaderFromMemory(PAnsiChar(SKYBOX_VERT), PAnsiChar(SKYBOX_FRAG));
  FSkyboxDaytimeLoc := GetShaderLocation(FSkyboxShader, 'daytime');
  FSkyboxViewLoc := GetShaderLocation(FSkyboxShader, 'view');
  FSkyboxProjLoc := GetShaderLocation(FSkyboxShader, 'projection');

  SkyMesh := GenMeshCube(1.0, 1.0, 1.0);
  FSkyboxModel := LoadModelFromMesh(SkyMesh);
  FSkyboxModel.materials[0].shader := FSkyboxShader;

  // Load Skybox textures
  FilePath := ExtractFilePath(ParamStr(0)) + 'resources/';
  if FileExists(PAnsiChar(AnsiString(FilePath + 'skyGradient.png'))) then
  begin
    FSkyboxTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'skyGradient.png')));
    SetTextureFilter(FSkyboxTex, TEXTURE_FILTER_TRILINEAR);
    // Procedural shader is used for simplicity here.
  end;

  // Initialize Clouds
  FCloudShader := LoadShaderFromMemory(PAnsiChar(CLOUD_VERT), PAnsiChar(CLOUD_FRAG));
  FCloudMoveFactorLoc := GetShaderLocation(FCloudShader, 'moveFactor');
  FCloudDaytimeLoc := GetShaderLocation(FCloudShader, 'daytime');

  CloudMesh := GenMeshPlane(2000, 2000, 1, 1);
  FCloudModel := LoadModelFromMesh(CloudMesh);
  FCloudModel.transform := MatrixTranslate(0, 150, 0);
  FCloudModel.materials[0].shader := FCloudShader;

  if FileExists(PAnsiChar(AnsiString(FilePath + 'clouds.png'))) then
  begin
    FCloudTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'clouds.png')));
    SetTextureFilter(FCloudTex, TEXTURE_FILTER_TRILINEAR);
    SetTextureWrap(FCloudTex, TEXTURE_WRAP_REPEAT);
    FCloudModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FCloudTex;
  end;

  // Load Ambient Gradient
  if FileExists(PAnsiChar(AnsiString(FilePath + 'ambientGradient.png'))) then
  begin
    FAmbientGradientTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'ambientGradient.png')));
    SetTextureFilter(FAmbientGradientTex, TEXTURE_FILTER_TRILINEAR);
  end;
end;

procedure TRaylibSandbox.PlayTestSound;
var
  Res: Integer;
begin
  if FAudioEngine <> nil then
  begin
    Res := ma_engine_play_sound(FAudioEngine, 'ressources\audio\test.wav', nil);
    if Res <> MA_SUCCESS then
      DoEngineException('Failed to play test.wav', 'AudioEngine');
  end;
end;

procedure TRaylibSandbox.PlaySpawnSound;
var
  Res: Integer;
begin
  if FAudioEngine <> nil then
  begin
    Res := ma_engine_play_sound(FAudioEngine, 'ressources\audio\impactPlank_medium_000.wav', nil);
    if Res <> MA_SUCCESS then
      DoEngineException('Failed to play impactPlank_medium_000.wav', 'AudioEngine');
  end;
end;

procedure TRaylibSandbox.PlayImpactSound;
var
  Res: Integer;
begin
  if FAudioEngine <> nil then
  begin
    Res := ma_engine_play_sound(FAudioEngine, 'ressources\audio\explosionCrunch_004.wav', nil);
    if Res <> MA_SUCCESS then
      DoEngineException('Failed to play explosionCrunch_004.wav', 'AudioEngine');
  end;
end;

procedure TRaylibSandbox.StartThread;
var
  AudioRes: Integer;
begin
  if FThreadActive then
    Exit;
  FThreadActive := True;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      Freq: Int64;
      FrameStart, FrameEnd, FrameTicks: Int64;
      RestMs: Double;
    begin
      try
        try
          if FAntiAliasing then
<<<<<<< HEAD
            SetConfigFlags(FLAG_MSAA_4X_HINT or FLAG_WINDOW_RESIZABLE)
          else
=======
            SetConfigFlags(FLAG_MSAA_4X_HINT or FLAG_WINDOW_RESIZABLE)
          else
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
            SetConfigFlags(FLAG_WINDOW_RESIZABLE);
          InitWindow(1280, 720, 'Raylib Sandbox');
          FRaylibWnd := FindWindow(nil, 'Raylib Sandbox');
          if FRaylibWnd <> 0 then
          begin
            Winapi.Windows.SetParent(FRaylibWnd, Self.Handle);
            SetWindowLong(FRaylibWnd, GWL_STYLE, WS_CHILD or WS_VISIBLE);
            SetWindowPos(FRaylibWnd, 0, 0, 0, Self.ClientWidth, Self.ClientHeight, SWP_NOZORDER);
          end;
          GetMem(FAudioEngine, ma_engine_sizeof());
          AudioRes := ma_engine_init(nil, FAudioEngine);
          if AudioRes <> MA_SUCCESS then
            DoEngineException('Audio Engine Init failed: ' + IntToStr(AudioRes), 'AudioInit');

<<<<<<< HEAD
          FEngine := TModelEngine.Create;
          // Apply initial Gravity
          var InitGravVec: JPH_Vec3;
          InitGravVec.x := 0;
          InitGravVec.y := FGravity;
          InitGravVec.z := 0;
=======
          FEngine := TModelEngine.Create;
          // Apply initial Gravity
          var InitGravVec: JPH_Vec3;
          InitGravVec.x := 0;
          InitGravVec.y := FGravity;
          InitGravVec.z := 0;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
          JPH_PhysicsSystem_SetGravity(FEngine.PhysicsSystem, @InitGravVec);
          FCamYaw := -0.5;
          FCamPitch := 0.8;
          FCamDist := 60.0;
          FCamera.target := Vector3Create(0, 0, 0);
          FCamera.position := Vector3Create(20, 20, 20);
          FCamera.up := Vector3Create(0, 1, 0);
          FCamera.fovy := 45.0;
          FCamera.projection := CAMERA_PERSPECTIVE;
          FDraggingRMB := False;
          FDragging := False;
          FItemSelected := nil;
          FHUDAnimY := -150.0;
          InitScene;
          JPH_PhysicsSystem_OptimizeBroadPhase(FEngine.PhysicsSystem);

          InitLightingAndEnvironment;
          FInitialized := True;
          FSceneStartTime := GetTime();
          DoViewportReady;
          QueryPerformanceFrequency(Freq);
          timeBeginPeriod(1);
          while not TThread.CheckTerminated do
          begin
            try
              QueryPerformanceCounter(FrameStart);
              if WindowShouldClose() then
                Break;
              UpdateGame;
              RenderGame;
              if FTargetFPS > 0 then
              begin
                FrameTicks := Freq div FTargetFPS;
                QueryPerformanceCounter(FrameEnd);
                RestMs := (FrameTicks - (FrameEnd - FrameStart)) * 1000 / Freq;
                if RestMs > 0 then
                begin
                  if RestMs > 2 then
                    Sleep(Trunc(RestMs) - 2);
                  repeat
                    QueryPerformanceCounter(FrameEnd);
                  until (FrameEnd - FrameStart) >= FrameTicks;
                end;
              end
              else
                Sleep(1);
            except
              on E: Exception do
                DoEngineException(E.Message, 'RenderLoop');
            end;
          end;
        except
          on E: Exception do
          begin
            DoEngineException(E.Message, 'EngineInit');
            // Fallback to ensure we don't freeze if InitWindow fails catastrophically
            FInitialized := True;
          end;
        end;
      finally
        try
          timeEndPeriod(1);
          FInitialized := False;
          ClearItems;
          FreeAndNil(FFloorActor);
          FreeAndNil(FEngine);
          if FShadowMap.id > 0 then
            UnloadRenderTexture(FShadowMap);
          if FCustomModel.meshes <> nil then
            UnloadModel(FCustomModel);
          if FLightShader.id > 0 then
            UnloadShader(FLightShader);

          // Optimization: Unload cached default shader used for shadow mapping
              if FDefaultShader.id > 0 then
            UnloadShader(FDefaultShader);

          if FSkyboxShader.id > 0 then
          begin
            UnloadShader(FSkyboxShader);
            UnloadModel(FSkyboxModel);
            if FSkyboxTex.id > 0 then
              UnloadTexture(FSkyboxTex);
          end;
          if FCloudShader.id > 0 then
          begin
            UnloadShader(FCloudShader);
            UnloadModel(FCloudModel);
            if FCloudTex.id > 0 then
              UnloadTexture(FCloudTex);
          end;
          if FAmbientGradientTex.id > 0 then
            UnloadTexture(FAmbientGradientTex);
          if FWhiteTex.id > 0 then
            UnloadTexture(FWhiteTex);
          if FDefaultWhiteTex.id > 0 then
            UnloadTexture(FDefaultWhiteTex);
          UnloadMesh(FUnitBox);
          UnloadMesh(FUnitSphere);
          if FAudioEngine <> nil then
          begin
            ma_engine_uninit(FAudioEngine);
            FreeMem(FAudioEngine);
            FAudioEngine := nil;
          end;
          if Assigned(FMPVPlayer) then
            FreeAndNil(FMPVPlayer);
          CloseWindow();
        except
          on E: Exception do
            DoEngineException(E.Message, 'EngineCleanup');
        end;
      end;
      FThreadActive := False;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TRaylibSandbox.StopThread;
begin
  if not FThreadActive then
    Exit;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(100);
  end;
end;

procedure TRaylibSandbox.InitScene;
begin
  // No walls are generated to keep the skybox horizon fully visible
  FFloorActor := TA3DComponent.Create('', FEngine, stBox, Vector3Create(1000, 1, 1000), True);
  FFloorActor.SetPosition(Vector3Create(0, -0.5, 0));
  FFloorActor.Visible := False;
  FFloorActor.Friction := 0.5;

  // Initialize items array
  FItems := nil;
end;

function TRaylibSandbox.ItemCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TRaylibSandbox.ClearItems;
begin
  FLock.Enter;
  try
    FGizmoMode := gmNone;
    FClearItemsQueued := True;
    // Clear custom spawn queue to prevent further scripted spawns after clearing
    FCustomSpawnQueue := nil;
    FBombActor := nil;
    FBombExploded := False;
    SetBrush(TShapeType(-1));
    FActiveSpawnEffects := nil;
<<<<<<< HEAD
    FreeAndNil(FPiano); // Free independent Piano component
=======
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.SpawnObjects(Count: Integer; ShapeType: TShapeType);
begin
  FLock.Enter;
  try
    FSpawnQueue := FSpawnQueue + Count;
    FSpawnShape := ShapeType;
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.QueueCustomSpawn(const Request: TSpawnRequest);
begin
  // Thread-safe addition to the custom spawn queue
  FLock.Enter;
  try
    SetLength(FCustomSpawnQueue, Length(FCustomSpawnQueue) + 1);
    FCustomSpawnQueue[High(FCustomSpawnQueue)] := Request;
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.ProcessSpawnQueue(dt: Single);
var
  Obj: TA3DComponent;
  oldLen: Integer;
  Data: PItemData;
  Size: TVector3;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  RandQuat: TQuaternion;
  RX, RY, RZ: Single;
begin
  if FSpawnQueue <= 0 then
    Exit;
  if FSpawnTimer > 0 then
  begin
    FSpawnTimer := FSpawnTimer - dt;
    Exit;
  end;
  FSpawnQueue := FSpawnQueue - 1;
  FSpawnTimer := 0.04;
  oldLen := Length(FItems);
  SetLength(FItems, oldLen + 1);
  New(Data);
  FillChar(Data^, SizeOf(TItemData), 0);
  Data^.SpawnTime := GetTime();
  Data^.IsProjectile := False;
  case FSpawnShape of
    stBox:
      Data^.Name := 'Cube_' + IntToStr(oldLen);
    stSphere:
      Data^.Name := 'Sphere_' + IntToStr(oldLen);
    stPyramid:
      Data^.Name := 'Pyramid_' + IntToStr(oldLen);
    stCapsule:
      Data^.Name := 'Capsule_' + IntToStr(oldLen);
    stPrism:
      Data^.Name := 'Prism_' + IntToStr(oldLen);
  end;
  Size := Vector3Create(1, 1, 1);
  if FSpawnShape = stPrism then
    Size := Vector3Create(1, 1.5, 1)
  else if FSpawnShape = stPyramid then
    Size := Vector3Create(1, 1.5, 1);
  JPos.x := -20.0 + (Random * 40.0);
  JPos.y := 25.0 + (Random * 10.0);
  JPos.z := -20.0 + (Random * 40.0);
  RX := DegToRad(-45 + (Random * 90.0));
  RY := DegToRad(-180 + (Random * 360.0));
  RZ := DegToRad(-0.2 + (Random * 0.4));
  RandQuat := QuaternionFromEuler(RX, RY, RZ);
  JRot.x := RandQuat.x;
  JRot.y := RandQuat.y;
  JRot.z := RandQuat.z;
  JRot.w := RandQuat.w;
  Obj := TA3DComponent.Create('', FEngine, FSpawnShape, Size, FSpawnStatic, FSpawnDestructable, @JPos, @JRot);
  Obj.Name := Data^.Name;
  Obj.Friction := 0.2;
  Obj.Restitution := 0.2;
  Obj.UserData := Data;
  Obj.Visible := True;

  FItems[oldLen] := Obj;
  DoActorSpawned(Obj, oldLen);
end;

procedure TRaylibSandbox.HandleCameraInput;
var
  p: TPoint;
  dt, panSpeed: Single;
  fwdX, fwdZ, rightX, rightZ: Single;
begin
  dt := GetFrameTime();
  if dt <= 0 then
    dt := 1 / 60;
  GetCursorPos(p);
  if (GetAsyncKeyState(VK_MBUTTON) and $8000) <> 0 then
  begin
    if FDraggingRMB then
    begin
      FCamYaw := FCamYaw - (p.x - FLastMouse.x) * 0.006;
      FCamPitch := EnsureRange(FCamPitch + (p.y - FLastMouse.y) * 0.006, 0.05, 1.53);
      FCameraMoved := True;
    end
    else
      FDraggingRMB := True;
  end
  else
    FDraggingRMB := False;
  FLastMouse := p;
  fwdX := -Sin(FCamYaw);
  fwdZ := -Cos(FCamYaw);
  rightX := Cos(FCamYaw);
  rightZ := -Sin(FCamYaw);
  panSpeed := 25.0 * dt;
  if ((GetAsyncKeyState(Ord('W')) and $8000) <> 0) or ((GetAsyncKeyState(VK_UP) and $8000) <> 0) then
  begin
    FCamera.target.x := FCamera.target.x + fwdX * panSpeed;
    FCamera.target.z := FCamera.target.z + fwdZ * panSpeed;
    FCameraMoved := True;
  end;
  if ((GetAsyncKeyState(Ord('S')) and $8000) <> 0) or ((GetAsyncKeyState(VK_DOWN) and $8000) <> 0) then
  begin
    FCamera.target.x := FCamera.target.x - fwdX * panSpeed;
    FCamera.target.z := FCamera.target.z - fwdZ * panSpeed;
    FCameraMoved := True;
  end;
  if ((GetAsyncKeyState(Ord('A')) and $8000) <> 0) or ((GetAsyncKeyState(VK_LEFT) and $8000) <> 0) then
  begin
    FCamera.target.x := FCamera.target.x - rightX * panSpeed;
    FCamera.target.z := FCamera.target.z - rightZ * panSpeed;
    FCameraMoved := True;
  end;
  if ((GetAsyncKeyState(Ord('D')) and $8000) <> 0) or ((GetAsyncKeyState(VK_RIGHT) and $8000) <> 0) then
  begin
    FCamera.target.x := FCamera.target.x + rightX * panSpeed;
    FCamera.target.z := FCamera.target.z + rightZ * panSpeed;
    FCameraMoved := True;
  end;
  FCamera.target.x := EnsureRange(FCamera.target.x, -450.0, 450.0);
  FCamera.target.z := EnsureRange(FCamera.target.z, -450.0, 450.0);
  if GetMouseWheelMove() <> 0 then
  begin
    FCamDist := EnsureRange(FCamDist - GetMouseWheelMove() * 3.0, 10, 250);
    FCameraMoved := True;
  end;
  FCamera.position := Vector3Create(FCamera.target.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FCamera.target.y + Sin(FCamPitch) * FCamDist, FCamera.target.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
end;

function TRaylibSandbox.CheckButton(x, y, w, h: Integer): Boolean;
var
  p: TPoint;
  RealY: Integer;
begin
  Result := False;
  if FHUDAnimY > -1 then
  begin
    GetCursorPos(p);
    Winapi.Windows.ScreenToClient(FRaylibWnd, p);
    FMousePos := Vector2Create(p.x, p.y);
    RealY := y + Trunc(FHUDAnimY);
    if (FMousePos.x >= x) and (FMousePos.x <= x + w) and (FMousePos.y >= RealY) and (FMousePos.y <= RealY + h) then
    begin
      if FMouseLeftPressed then
        Result := True;
    end;
  end;
end;

procedure TRaylibSandbox.PublicShootBall;
begin
  PlayTestSound;
  ShootBall;
end;

procedure TRaylibSandbox.ShootBall;
var
  Obj: TA3DComponent;
  oldLen: Integer;
  Data: PItemData;
  Size: TVector3;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  CamForward, ThrowVel: TVector3;
begin
  oldLen := Length(FProjectiles);
  SetLength(FProjectiles, oldLen + 1);
  Size := Vector3Create(0.5, 0.5, 0.5);
  CamForward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));
  JPos.x := FCamera.position.x + (CamForward.x * 2.0);
  JPos.y := FCamera.position.y - 1.0 + (CamForward.y * 2.0);
  JPos.z := FCamera.position.z + (CamForward.z * 2.0);
  JRot.x := 0;
  JRot.y := 0;
  JRot.z := 0;
  JRot.w := 1;
  Obj := TA3DComponent.Create('', FEngine, stSphere, Size, False, false, @JPos, @JRot);
  Obj.Mass := 1.0;
  Obj.Friction := 0.2;
  Obj.Restitution := 0.2;
  Obj.ActivateBody;
  Obj.Visible := True;
  New(Data);
  FillChar(Data^, SizeOf(TItemData), 0);
  Data^.SpawnTime := GetTime();
  Data^.IsProjectile := True;
  Obj.UserData := Data;
  ThrowVel.x := CamForward.x * 80.0;
  ThrowVel.y := CamForward.y * 80.0;
  ThrowVel.z := CamForward.z * 80.0;
  Obj.SetLinearVelocity(ThrowVel);
  FProjectiles[oldLen] := Obj;
end;

procedure TRaylibSandbox.UpdateProjectiles(dt: Single);
var
  i: Integer;
  Actor: TA3DComponent;
  CurrVel: TVector3;
  SpeedSq: Single;
begin
  for i := High(FProjectiles) downto 0 do
  begin
    if FProjectiles[i] = nil then
      Continue;

    Actor := FProjectiles[i];

    // If the projectile is already marked as dead, free its memory and nil the pointer
    if Actor.FIsDead then
    begin
      if Actor.UserData <> nil then
        Dispose(PItemData(Actor.UserData));
      Actor.Free;
      FProjectiles[i] := nil;
      Continue;
    end;

    if Actor.UserData <> nil then
    begin
      // Lifespan check: Destroy the projectile after 5 seconds
      if GetTime() - PItemData(Actor.UserData)^.SpawnTime > 5.0 then
      begin
        Actor.FIsDead := True;
        Continue;
      end;

      // Velocity check: Destroy the projectile if it slows down too much
      CurrVel := Actor.GetLinearVelocity;

      // We calculate the squared length of the velocity vector (Speed * Speed).
      // This is much faster than using Vector3Length as it avoids a square root operation.
      // We compare it against 25.0, which means the projectile dies if its speed drops below 5.0 units/sec.
      SpeedSq := (CurrVel.x * CurrVel.x) + (CurrVel.y * CurrVel.y) + (CurrVel.z * CurrVel.z);

      if SpeedSq < 25.0 then
      begin
        Actor.FIsDead := True;
        Continue;
      end;

      // Store the current velocity for the next frame (useful for debugging or future logic)
      PItemData(Actor.UserData)^.OldVelocity := CurrVel;
    end;
  end;

  // Compress the array: Remove all nil pointers so the array doesn't grow infinitely
  if Length(FProjectiles) > 0 then
  begin
    var CurrIdx: Integer := 0;
    for i := 0 to High(FProjectiles) do
    begin
      if FProjectiles[i] <> nil then
      begin
        FProjectiles[CurrIdx] := FProjectiles[i];
        Inc(CurrIdx);
      end;
    end;
    // Resize the array to fit only the surviving projectiles
    SetLength(FProjectiles, CurrIdx);
  end;
end;

procedure TRaylibSandbox.HandleDesktopInput;
var
  ray: TRay;
  itemBox: TBoundingBox;
  hitInfo: TRayCollision;
  i: Integer;
  dt: Single;
  groundBox: TBoundingBox;
  p: TPoint;
  downRay: TRay;
  downHit: TRayCollision;
  topY: Single;
  HalfH, HalfX, HalfY, HalfZ: Single;
  GScaleX, GScaleY, GScaleZ: Single;
  TargetY, t: Single;
  bIsModelBrush: Boolean;
  bLeftMouseDown: Boolean;
  bLeftMouseClicked: Boolean;
  R: TRect;
begin
  // PREVENT BACKGROUND CLICKS: Only process input if the mouse cursor
  // is actually hovering over the Raylib window area!
  GetWindowRect(FRaylibWnd, R);
  GetCursorPos(p);
  if not PtInRect(R, p) then
  begin
    FMouseLeftPressed := False;
    FDragging := False;
    Exit;
  end;

  // ==========================================
  // HUD SPAWN BUTTONS (Rain Spawns)
  // ==========================================
  var LocalMouseY: Integer := Trunc(FMousePos.y);

  if CheckButton(0, 10, 40, 40) then
  begin
    if not FSpawnButton1WasDown then
    begin
      SpawnObjects(30, stBox);
      FSpawnButton1WasDown := True;
    end;
    FMouseLeftHandled := True;
    Exit;
  end
  else
    FSpawnButton1WasDown := False;
  if CheckButton(40, 10, 40, 40) then
  begin
    if not FSpawnButton2WasDown then
    begin
      SpawnObjects(30, stSphere);
      FSpawnButton2WasDown := True;
    end;
    FMouseLeftHandled := True;
    Exit;
  end
  else
    FSpawnButton2WasDown := False;
  if CheckButton(80, 10, 40, 40) then
  begin
    if not FSpawnButton3WasDown then
    begin
      SpawnObjects(30, stCapsule);
      FSpawnButton3WasDown := True;
    end;
    FMouseLeftHandled := True;
    Exit;
  end
  else
    FSpawnButton3WasDown := False;
  if CheckButton(120, 10, 40, 40) then
  begin
    if not FSpawnButton4WasDown then
    begin
      SpawnObjects(30, stPyramid);
      FSpawnButton4WasDown := True;
    end;
    FMouseLeftHandled := True;
    Exit;
  end
  else
    FSpawnButton4WasDown := False;
  if CheckButton(160, 10, 40, 40) then
  begin
    if not FSpawnButton5WasDown then
    begin
      SpawnObjects(30, stPrism);
      FSpawnButton5WasDown := True;
    end;
    FMouseLeftHandled := True;
    Exit;
  end
  else
    FSpawnButton5WasDown := False;
<<<<<<< HEAD

=======

>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
  // Handle Delete Key directly inside the sandbox thread
  if (GetAsyncKeyState(VK_DELETE) and $1) <> 0 then
  begin
    if Assigned(FItemSelected) then
    begin
      // Disable brush to prevent instant respawn of a standard cube
      FIsBrushActive := False;
      FGhostVisible := False;
      DeleteSelectedActor;
      Exit;
    end;
  end;

  // Prevent background clicks and accidental brushing when the popup menu is open
  if FPopupOpen then
  begin
    HandlePopupInput;
    Exit;
  end;

  // Select next/prev object
  if (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0 then
  begin
    if (GetAsyncKeyState(Ord('Q')) and $1) <> 0 then
    begin
      SelectPrevObject;
      Exit;
    end
    else if (GetAsyncKeyState(Ord('E')) and $1) <> 0 then
    begin
      SelectNextObject;
      Exit;
    end;
  end;

  dt := GetFrameTime();
  if FShootCooldown > 0 then
    FShootCooldown := FShootCooldown - dt;
  if Self.Tag = 1 then
  begin
    if ((GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0) or ((GetAsyncKeyState(VK_RBUTTON) and $8000) <> 0) then
      Exit
    else
      Self.Tag := 0;
  end;
  GetCursorPos(p);
  Winapi.Windows.ScreenToClient(FRaylibWnd, p);
  FMousePos := Vector2Create(p.x, p.y);
  bLeftMouseDown := (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0;
  bLeftMouseClicked := bLeftMouseDown and not FMouseLeftPressed;
  FMouseLeftPressed := bLeftMouseDown;

  if (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0 then
  begin
    if not FCtrlWasPressed then
    begin
      // Cycle through tools including the new explicit Drag & Throw tool
      if FGizmoMode = gmTranslate then
        FGizmoMode := gmRotate
      else if FGizmoMode = gmRotate then
        FGizmoMode := gmScale
      else if FGizmoMode = gmScale then
        FGizmoMode := gmDragAndThrow
      else if FGizmoMode = gmDragAndThrow then
        FGizmoMode := gmNone
      else if FGizmoMode = gmNone then
        FGizmoMode := gmTranslate;
      FCtrlWasPressed := True;
    end;
  end
  else
    FCtrlWasPressed := False;

  ray := GetScreenToWorldRay(FMousePos, FCamera);

  // ====================================================================
  // 3D BUTTON INTERACTION LOGIC (Hover & Click)
  // Handles UI clicks independent from physics tools
  // ====================================================================
  var ClosestButtonDist: Single := 1e9;
  var HoveredButton: TA3DComponent := nil;

  // Reset hover states for all buttons
  for i := 0 to High(FItems) do
    if Assigned(FItems[i]) and ((FItems[i].ShapeType = stButton) or (FItems[i].IsPianoKey)) then
      FItems[i].IsHovered := False;

  // Find the closest button under the mouse cursor
  for i := 0 to High(FItems) do
  begin
    if Assigned(FItems[i]) and ((FItems[i].ShapeType = stButton) or (FItems[i].IsPianoKey)) then
    begin
      // FIXED: Use FULL Scale for Piano Keys so the click box matches the visual size!
      if FItems[i].IsPianoKey then
      begin
        HalfX := FItems[i].Scale.x * 0.5;
        HalfY := FItems[i].Scale.y * 0.5;
        HalfZ := FItems[i].Scale.z * 0.5;
      end
      else
      begin
        HalfX := FItems[i].Scale.x * 0.5;
        HalfY := FItems[i].Scale.y * 0.5;
        HalfZ := FItems[i].Scale.z * 0.5;
      end;

      itemBox.min := Vector3Create(FItems[i].position.x - HalfX, FItems[i].position.y - HalfY, FItems[i].position.z - HalfZ);
      itemBox.max := Vector3Create(FItems[i].position.x + HalfX, FItems[i].position.y + HalfY, FItems[i].position.z + HalfZ);

      hitInfo := GetRayCollisionBox(ray, itemBox);
      if hitInfo.hit and (hitInfo.distance < ClosestButtonDist) then
      begin
        ClosestButtonDist := hitInfo.distance;
        HoveredButton := FItems[i];
      end;
    end;
  end;

  if Assigned(HoveredButton) then
  begin
    HoveredButton.IsHovered := True;

    if bLeftMouseClicked then
    begin
      HoveredButton.IsPressed := True;
      FMouseLeftHandled := True;
      if HoveredButton.IsPianoKey and Assigned(FYutaniAudio) then
        FYutaniAudio.PlayLiveNote(HoveredButton.MidiNote);
    end
    else if (not FMouseLeftPressed) and HoveredButton.IsPressed then
    begin
      // Mouse released -> Trigger OnClick!
      HoveredButton.IsPressed := False;
      FMouseLeftHandled := True;

      // Fire Event thread-safe to avoid VCL cross-thread exceptions
      if Assigned(HoveredButton.OnClick) then
      begin
        var Callback := HoveredButton.OnClick;
        var BtnRef := HoveredButton;

        // CRITICAL: Set to nil to prevent spam firing in the next frames!
        HoveredButton.OnClick := nil;

        TThread.Queue(nil,
          procedure
          begin
            Callback(BtnRef);
            // Restore the OnClick event for the next time
            BtnRef.OnClick := Callback;
          end);
      end;
    end;

    Exit; // Prevent selecting 3D objects behind the button
  end
  else
  begin
    // If mouse is released outside any button, unpress all buttons
    if not FMouseLeftPressed then
    begin
      for i := 0 to High(FItems) do
        if Assigned(FItems[i]) and ((FItems[i].ShapeType = stButton) or (FItems[i].IsPianoKey)) then
          FItems[i].IsPressed := False;
    end;
  end;

  if (GetAsyncKeyState(VK_RBUTTON) and $8000) <> 0 then
  begin
    if not FRightClickWasPressed then
    begin
      if not FIsBrushActive then
      begin
        FPopupOpen := True;
        FPopupPos := FMousePos;

        // If gmNone is active, we do strictly nothing else (no object dragging)
        if FGizmoMode = gmNone then
          Exit;

        groundBox.min := Vector3Create(-1000, -0.1, -1000);
        groundBox.max := Vector3Create(1000, 0.1, 1000);
        hitInfo := GetRayCollisionBox(ray, groundBox);
        if hitInfo.hit then
        begin
          FGhostPos.x := hitInfo.point.x;
          FGhostPos.y := 0;
          FGhostPos.z := hitInfo.point.z;
        end;

        if Assigned(FItemSelected) then
        begin
          SetLength(FPopupSegments, 2);
          FPopupSegments[0] := 'Delete';
          FPopupSegments[1] := 'Duplicate';
        end
        else
        begin
          SetLength(FPopupSegments, 0);
        end;
        FPopupHoverIndex := -1;
        FPopupCloseLock := True;
      end;
      FRightClickWasPressed := True;
    end;
  end
  else
    FRightClickWasPressed := False;

  if (GetAsyncKeyState(VK_MBUTTON) and $8000) <> 0 then
  begin
    FGhostVisible := False;
    Exit;
  end;

  ray := GetScreenToWorldRay(FMousePos, FCamera);

  if FGizmoMode = gmDragAndThrow then
  begin
    if FDragging and Assigned(FItemSelected) then
    begin
      if bLeftMouseDown then
      begin
        if Abs(ray.direction.y) > 0.0001 then
        begin
          TargetY := FItemSelected.Position.y + 0.5;
          t := (TargetY - ray.position.y) / ray.direction.y;
          if t > 0 then
          begin
            FDragTargetPos.x := ray.position.x + ray.direction.x * t;
            FDragTargetPos.z := ray.position.z + ray.direction.z * t;
          end;
        end;
      end
      else
        FDragging := False;
    end
    else if bLeftMouseDown then
    begin
      for i := 0 to High(FItems) do
      begin
        if FItems[i] = nil then
          Continue;
        HalfX := FItems[i].Scale.x * 0.5;
        HalfY := FItems[i].Scale.y * 0.5;
        HalfZ := FItems[i].Scale.z * 0.5;
        itemBox.min := Vector3Create(FItems[i].position.x - HalfX, FItems[i].position.y - HalfY, FItems[i].position.z - HalfZ);
        itemBox.max := Vector3Create(FItems[i].position.x + HalfX, FItems[i].position.y + HalfY, FItems[i].position.z + HalfZ);
        hitInfo := GetRayCollisionBox(ray, itemBox);
        if hitInfo.hit then
        begin
          if FItemSelected <> FItems[i] then
          begin
            FItemSelected := FItems[i];
            DoObjectSelected(FItemSelected);
          end;
          FItemSelected.ActivateBody;
          FDragging := True;
          Break;
        end;
      end;
    end;
    Exit;
  end;

  if FGizmoDragging then
  begin
    UpdateGizmoInteraction;
    if not bLeftMouseDown then
    begin
      FGizmoDragging := False;
      FGizmoAxis := 0;
      if Assigned(FItemSelected) then
      begin
        // CRITICAL FIX: Force the physics engine to accept the new shape size immediately!
        // Otherwise Jolt will reject the reattach and slowly push the object out of the ground.
        FItemSelected.Scale := FItemSelected.Scale;
        FItemSelected.SetPosition(FItemSelected.Position);
        FItemSelected.ReattachToPhysics;
      end;
    end;
    // CRITICAL: DO NOT update FGizmoStartMouse here!
    Exit;
  end;

  if Assigned(FItemSelected) and not FIsBrushActive then
  begin
    if bLeftMouseDown then
    begin
      // Calculate default gizmo bounds for primitives
      GScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 1.0, 1.0, 100.0);
      GScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 1.0, 1.0, 100.0);
      GScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 1.0, 1.0, 100.0);

      // Increase the thickness of the invisible click-box for primitives
      var ClickRadius: Single := 0.4;

      if FItemSelected.ShapeType = stModel then
      begin
        var BBox := GetModelBoundingBox(FItemSelected.FModel);
        var PhysRadius := Max(BBox.max.x - BBox.min.x, Max(BBox.max.y - BBox.min.y, BBox.max.z - BBox.min.z)) * Max(FItemSelected.Scale.x, Max(FItemSelected.Scale.y, FItemSelected.Scale.z)) * 0.5;

        // Make arms reach outside the mesh
        GScaleX := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
        GScaleY := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
        GScaleZ := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);

        // Make the invisible click-box thicker so the mouse ray definitely hits the arrow before the mesh!
        ClickRadius := 1.0;
      end;

      if FGizmoMode = gmTranslate then
      begin
        if CheckGizmoAxisHit(FItemSelected.Position, Vector3Create(GScaleX, GScaleY, GScaleZ), ClickRadius, ray, FGizmoAxis) then
        begin
          FGizmoDragging := True;
          FGizmoStartMouse := FMousePos;
          FGizmoStartVal := FItemSelected.Position;
          FGizmoStartPos := FItemSelected.Position; // Save position for Scale mode
          FGizmoStartQuat := FItemSelected.Quaternion;
          FMouseLeftHandled := True;
          FItemSelected.DetachFromPhysics;
          Exit;
        end;
      end
      else if FGizmoMode = gmRotate then
      begin
        if CheckGizmoRingHit(FItemSelected.Position, Vector3Create(GScaleX, GScaleY, GScaleZ), ClickRadius, ray, FGizmoAxis) then
        begin
          FGizmoDragging := True;
          FGizmoStartMouse := FMousePos;
          FGizmoStartVal := FItemSelected.Position;
          FGizmoStartPos := FItemSelected.Position; // Save position for Scale mode
          FGizmoStartQuat := FItemSelected.Quaternion;
          FMouseLeftHandled := True;
          FItemSelected.DetachFromPhysics;
          Exit;
        end;
      end
      else if FGizmoMode = gmScale then
      begin
        if CheckGizmoScaleHit(FItemSelected.Position, Vector3Create(GScaleX, GScaleY, GScaleZ), ClickRadius, ray, FGizmoAxis) then
        begin
          FGizmoDragging := True;
          FGizmoStartMouse := FMousePos;
          FGizmoStartVal := FItemSelected.Scale;
          FGizmoStartPos := FItemSelected.Position; // Save position to calculate Y-Lift
          FGizmoStartQuat := FItemSelected.Quaternion;
          FMouseLeftHandled := True;
          FItemSelected.DetachFromPhysics;
          Exit;
        end;
      end;
    end;
  end;

  bIsModelBrush := FIsBrushActive and (FBrushShape = stModel);
  if FIsBrushActive then
  begin
    groundBox.min := Vector3Create(-1000, -0.1, -1000);
    groundBox.max := Vector3Create(1000, 0.1, 1000);
    hitInfo := GetRayCollisionBox(ray, groundBox);
    if hitInfo.hit then
    begin
      downRay.position := Vector3Create(hitInfo.point.x, 100.0, hitInfo.point.z);
      downRay.direction := Vector3Create(0, -1, 0);
      topY := 0;
      for i := 0 to High(FItems) do
      begin
        if FItems[i] = nil then
          Continue;
        HalfX := FItems[i].Scale.x * 0.5;
        HalfY := FItems[i].Scale.y * 0.5;
        HalfZ := FItems[i].Scale.z * 0.5;
        itemBox.min := Vector3Create(FItems[i].position.x - HalfX, FItems[i].position.y - HalfY, FItems[i].position.z - HalfZ);
        itemBox.max := Vector3Create(FItems[i].position.x + HalfX, FItems[i].position.y + HalfY, FItems[i].position.z + HalfZ);
        downHit := GetRayCollisionBox(downRay, itemBox);
        if downHit.hit and (itemBox.max.y > topY) then
          topY := itemBox.max.y;
      end;
      FGhostPos.x := hitInfo.point.x;
      if not bIsModelBrush then
        FGhostPos.y := topY
      else
        FGhostPos.y := hitInfo.point.y;
      FGhostPos.z := hitInfo.point.z;
      FGhostVisible := True;
      if bLeftMouseClicked and (FShootCooldown <= 0) then
      begin
        SpawnAtMouse(FGhostPos);
        FShootCooldown := 0.15;
        FIsBrushActive := False;
        FGhostVisible := False;
        FMouseLeftHandled := True;
      end;
    end
    else
      FGhostVisible := False;
    Exit;
  end
  else
    FGhostVisible := False;

  if FShootCooldown > 0 then
    Exit;

  // CRITICAL OBJECT SELECTION BLOCK
  if bLeftMouseDown then
  begin
    if not FDragging then
    begin
      // Find the CLOSEST object to the camera under the mouse cursor
      var ClosestActor: TA3DComponent := nil;
      var ClosestDist: Single := 1e9;
      var TempHit: TRayCollision;

      for i := 0 to High(FItems) do
      begin
        if FItems[i] = nil then
          Continue;

        HalfX := FItems[i].Scale.x * 0.5;
        HalfY := FItems[i].Scale.y * 0.5;
        HalfZ := FItems[i].Scale.z * 0.5;

        itemBox.min := Vector3Create(FItems[i].Position.x - HalfX, FItems[i].Position.y - HalfY, FItems[i].Position.z - HalfZ);
        itemBox.max := Vector3Create(FItems[i].Position.x + HalfX, FItems[i].Position.y + HalfY, FItems[i].Position.z + HalfZ);

        TempHit := GetRayCollisionBox(ray, itemBox);
        if TempHit.hit then
        begin
          if TempHit.distance < ClosestDist then
          begin
            ClosestDist := TempHit.distance;
            ClosestActor := FItems[i];
          end;
        end;
      end;

      // After checking all objects, select the closest one
      if Assigned(ClosestActor) then
      begin
        if FItemSelected <> ClosestActor then
        begin
          FItemSelected := ClosestActor;
          DoObjectSelected(FItemSelected);
        end;
        FDragging := True; // JUST MARK IT, DO NOT DETACH FROM PHYSICS HERE!
      end
      else
      begin
        // Clicked into empty space -> deselect
        if Assigned(FItemSelected) then
        begin
          FItemSelected := nil;
          DoObjectSelected(nil);
        end;
      end;
    end;
  end
  else
    FDragging := False;
end;

procedure TRaylibSandbox.HandlePopupInput;
var
  I: Integer;
  Rect: TRectangle;
  NewHover: Integer;
  IconRect: TRectangle;
begin
  FMousePos := GetMousePosition();
  NewHover := -1;

  for I := 0 to 4 do
  begin
    IconRect.x := FPopupPos.x + 4 + (I * 34);
    IconRect.y := FPopupPos.y + 4;
    IconRect.width := 30;
    IconRect.height := 30;
    if CheckCollisionPointRec(FMousePos, IconRect) then
    begin
      NewHover := I;
      Break;
    end;
  end;
  if NewHover = -1 then
  begin
    for I := 0 to High(FPopupSegments) do
    begin
      Rect.x := FPopupPos.x;
      Rect.y := FPopupPos.y + 45 + (I * 40);
      Rect.width := 150;
      Rect.height := 38;
      if CheckCollisionPointRec(FMousePos, Rect) then
      begin
        NewHover := I + 100;
        Break;
      end;
    end;
  end;

  if FPopupHoverIndex <> NewHover then
    FPopupHoverIndex := NewHover;

  if FPopupCloseLock then
  begin
    if (GetAsyncKeyState(VK_RBUTTON) and $8000) = 0 then
      FPopupCloseLock := False;
    Exit;
  end;

  if (GetAsyncKeyState(VK_LBUTTON) and $8000) <> 0 then
  begin
    if FPopupHoverIndex >= 0 then
    begin
      if FPopupHoverIndex < 100 then
        ExecutePopupAction(FPopupHoverIndex)
      else
        ExecutePopupAction(FPopupHoverIndex - 100);
    end;

    FPopupOpen := False;
    // Prevents the click that closed the popup from selecting/deselecting 3D objects in the background!
    FMouseLeftHandled := True;
  end;
end;

procedure TRaylibSandbox.ExecutePopupAction(Index: Integer);
var
  NewActor: TA3DComponent;
  NewPos: TVector3;
  NewRot: JPH_Quat;
  NewSize: TVector3;
  NewData: PItemData;
  OldLen: Integer;
begin
  if (Index >= 0) and (Index <= High(FPopupSegments)) then
  begin
    if FPopupSegments[Index] = 'Delete' then
    begin
      FIsBrushActive := False;
      FGhostVisible := False;
      DeleteSelectedActor;
      Exit;
    end
    else if FPopupSegments[Index] = 'Duplicate' then
    begin
      if not Assigned(FItemSelected) then
        Exit;

      OldLen := Length(FItems);
      SetLength(FItems, OldLen + 1);

      NewPos.x := FItemSelected.Position.x + 1.0;
      NewPos.y := FItemSelected.Position.y + (FItemSelected.Scale.y * 0.5);
      NewPos.z := FItemSelected.Position.z;

      NewRot.x := FItemSelected.Quaternion.x;
      NewRot.y := FItemSelected.Quaternion.y;
      NewRot.z := FItemSelected.Quaternion.z;
      NewRot.w := FItemSelected.Quaternion.w;
      NewSize := FItemSelected.Scale;

      NewActor := TA3DComponent.Create('', FEngine, FItemSelected.ShapeType, NewSize, FSpawnStatic, FSpawnDestructable, @NewPos, @NewRot);
      NewActor.Friction := FItemSelected.Friction;
      NewActor.Restitution := FItemSelected.Restitution;
      NewActor.TargetColor := FItemSelected.TargetColor;
      NewActor.ActColor := FItemSelected.ActColor;

      New(NewData);
      FillChar(NewData^, SizeOf(TItemData), 0);
      NewData^.SpawnTime := GetTime();
      NewData^.IsProjectile := False;
      case NewActor.ShapeType of
        stBox:
          NewData^.Name := 'Cube_' + IntToStr(OldLen);
        stSphere:
          NewData^.Name := 'Sphere_' + IntToStr(OldLen);
        stPyramid:
          NewData^.Name := 'Pyramid_' + IntToStr(OldLen);
        stPrism:
          NewData^.Name := 'Prism_' + IntToStr(OldLen);
        stCapsule:
          NewData^.Name := 'Capsule_' + IntToStr(OldLen);
      end;
      NewActor.UserData := NewData;
      NewActor.Visible := True;

      FItems[OldLen] := NewActor;
      PlaySpawnSound;
      DoActorSpawned(NewActor, OldLen);
      DoObjectSelected(NewActor);
      FItemSelected := NewActor;

      Exit;
    end;
  end;

  if (Index >= 0) and (Index <= 4) then
  begin
    case Index of
      0:
        begin
          SetBrush(stBox);
          SpawnAtMouse(FGhostPos);
          FIsBrushActive := False;
        end;
      1:
        begin
          SetBrush(stSphere);
          SpawnAtMouse(FGhostPos);
          FIsBrushActive := False;
        end;
      2:
        begin
          SetBrush(stCapsule);
          SpawnAtMouse(FGhostPos);
          FIsBrushActive := False;
        end;
      3:
        begin
          SetBrush(stPyramid);
          SpawnAtMouse(FGhostPos);
          FIsBrushActive := False;
        end;
      4:
        begin
          SetBrush(stPrism);
          SpawnAtMouse(FGhostPos);
          FIsBrushActive := False;
        end;
    end;
  end;

  FMouseLeftPressed := True;
  FMouseLeftHandled := True;
end;

procedure TRaylibSandbox.DeleteSelectedActor;
var
  SelectedIdx, I: Integer;
begin
  if not Assigned(FItemSelected) then
    Exit;
  SelectedIdx := -1;
  for I := 0 to High(FItems) do
    if FItems[I] = FItemSelected then
    begin
      SelectedIdx := I;
      Break;
    end;
  if SelectedIdx >= 0 then
  begin
    if FItemSelected.FBodyID <> 0 then
    begin
      JPH_BodyInterface_RemoveAndDestroyBody(FEngine.BodyInterface, FItemSelected.FBodyID);
      FItemSelected.FBodyID := 0;
    end;
    FItemSelected.Visible := False;
    FItemSelected.Free;
    for I := SelectedIdx to High(FItems) - 1 do
      FItems[I] := FItems[I + 1];
    SetLength(FItems, Length(FItems) - 1);
    FItemSelected := nil;
    DoObjectSelected(nil);
  end;
end;

procedure TRaylibSandbox.UpdateGizmoInteraction;
var
  MouseDeltaX, MouseDeltaY: Single;
  ScaleChange: Single;
  NewPos, EndScale: TVector3;
  RotDelta: TQuaternion;
  RotAngle: Single;
  RotAxis, WorldAxis, CamForward, MoveDir: TVector3;
  LocalMove: TVector3;
  CamDot: Single;
  // Variables for Y-Lift ground stabilization
  OldScaleY, NewScaleY, YLift: Single;
  // Variables for Piano movement
  OldBasePos, DeltaPos: TVector3;
  i: Integer;
begin
  MouseDeltaX := FMousePos.x - FGizmoStartMouse.x;
  MouseDeltaY := FMousePos.y - FGizmoStartMouse.y;

  if Abs(MouseDeltaX) < 0.5 then
    MouseDeltaX := 0;
  if Abs(MouseDeltaY) < 0.5 then
    MouseDeltaY := 0;

  CamForward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));

  if FGizmoMode = gmTranslate then
  begin
    WorldAxis := Vector3Create(0, 0, 0);
    if FGizmoAxis = 1 then
      WorldAxis := Vector3Create(1, 0, 0)
    else if FGizmoAxis = 2 then
      WorldAxis := Vector3Create(0, 1, 0)
    else if FGizmoAxis = 3 then
      WorldAxis := Vector3Create(0, 0, 1);

    WorldAxis := Vector3RotateByQuaternion(WorldAxis, FItemSelected.Quaternion);

    var ScreenRight := Vector3Create(1, 0, 0);
    var ScreenUp := Vector3Create(0, 1, 0);

    MoveDir := Vector3Add(Vector3Scale(ScreenRight, MouseDeltaX * 0.1), Vector3Scale(ScreenUp, -MouseDeltaY * 0.1));

    CamDot := Vector3DotProduct(WorldAxis, MoveDir);
    LocalMove := Vector3Scale(WorldAxis, CamDot);

    // Store old position before applying the new one
    OldBasePos := FItemSelected.Position;

    NewPos := Vector3Add(FGizmoStartVal, LocalMove);
    FItemSelected.SetPosition(NewPos);

    // ====================================================================
    // QUICK & DIRTY PIANO LINKING:
    // If we are moving the Piano Base, move all keys with it!
    // ====================================================================
    if Assigned(FPiano) and (FItemSelected = FPiano.FBase) then
    begin
      DeltaPos := Vector3Subtract(NewPos, OldBasePos);
      for i := 0 to High(FPiano.FKeys) do
      begin
        if Assigned(FPiano.FKeys[i]) then
        begin
          FPiano.FKeys[i].SetPosition(Vector3Add(FPiano.FKeys[i].Position, DeltaPos));
        end;
      end;
    end;

  end
  else if FGizmoMode = gmRotate then
  begin
    RotAxis := Vector3Create(0, 0, 0);
    if FGizmoAxis = 1 then
      RotAxis := Vector3RotateByQuaternion(Vector3Create(1, 0, 0), FItemSelected.Quaternion)
    else if FGizmoAxis = 2 then
      RotAxis := Vector3RotateByQuaternion(Vector3Create(0, 1, 0), FItemSelected.Quaternion)
    else if FGizmoAxis = 3 then
      RotAxis := Vector3RotateByQuaternion(Vector3Create(0, 0, 1), FItemSelected.Quaternion);

    if FGizmoAxis = 2 then
      RotAngle := (MouseDeltaX * 0.25) + (MouseDeltaY * 0.25)
    else
      RotAngle := (-MouseDeltaY * 0.5) + (MouseDeltaX * 0.25);

    if Abs(RotAngle) > 0.1 then
    begin
      RotDelta := QuaternionFromAxisAngle(RotAxis, DegToRad(RotAngle));
      FItemSelected.SetRotation(QuaternionMultiply(RotDelta, FGizmoStartQuat));
      if (Abs(FMousePos.x - FGizmoStartMouse.x) > 0.5) or (Abs(FMousePos.y - FGizmoStartMouse.y) > 0.5) then
      begin
        FGizmoStartMouse := FMousePos;
        FGizmoStartQuat := FItemSelected.Quaternion;
      end;
    end;
  end
  else if FGizmoMode = gmScale then
  begin
    ScaleChange := (MouseDeltaX * 0.01) + (-MouseDeltaY * 0.01);
    EndScale := FGizmoStartVal;

    if FGizmoAxis = 1 then
    begin
      EndScale.x := EnsureRange(EndScale.x + ScaleChange, 0.05, 100);
    end
    else if FGizmoAxis = 2 then
    begin
      EndScale.y := EnsureRange(EndScale.y + ScaleChange, 0.05, 100);
    end
    else if FGizmoAxis = 3 then
    begin
      EndScale.z := EnsureRange(EndScale.z + ScaleChange, 0.05, 100);
    end;

    FItemSelected.Scale := EndScale;

    // Y-LIFT STABILIZATION
    if FGizmoAxis = 2 then
    begin
      OldScaleY := FGizmoStartVal.y;
      NewScaleY := EndScale.y;
      YLift := (NewScaleY - OldScaleY) * 0.5;

      FItemSelected.SetPosition(Vector3Create(FGizmoStartPos.x, FGizmoStartPos.y + YLift, FGizmoStartPos.z));
    end;
  end;
end;

function TRaylibSandbox.CheckGizmoAxisHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
var
  Box: TBoundingBox;
  Hit: TRayCollision;
  InvRot: TQuaternion;
  LocalRay: TRay;
  LocalDir: TVector3;
begin
  Result := False;
  Axis := 0;
  InvRot := QuaternionInvert(FItemSelected.Quaternion);
  LocalRay.position := Vector3RotateByQuaternion(Vector3Subtract(Ray.position, Pos), InvRot);
  LocalDir := Vector3RotateByQuaternion(Ray.direction, InvRot);
  LocalRay.direction := Vector3Normalize(LocalDir);
  Box.min := Vector3Create(-Scale.x - RayRadius, -RayRadius, -RayRadius);
  Box.max := Vector3Create(Scale.x + RayRadius, RayRadius, RayRadius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 1;
    Exit;
  end;
  Box.min := Vector3Create(-RayRadius, -Scale.y - RayRadius, -RayRadius);
  Box.max := Vector3Create(RayRadius, Scale.y + RayRadius, RayRadius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 2;
    Exit;
  end;
  Box.min := Vector3Create(-RayRadius, -RayRadius, -Scale.z - RayRadius);
  Box.max := Vector3Create(RayRadius, RayRadius, Scale.z + RayRadius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 3;
    Exit;
  end;
end;

function TRaylibSandbox.CheckGizmoRingHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
var
  Box: TBoundingBox;
  Hit: TRayCollision;
  InvRot: TQuaternion;
  LocalRay: TRay;
  LocalDir: TVector3;
begin
  Result := False;
  Axis := 0;
  InvRot := QuaternionInvert(FItemSelected.Quaternion);
  LocalRay.position := Vector3RotateByQuaternion(Vector3Subtract(Ray.position, Pos), InvRot);
  LocalDir := Vector3RotateByQuaternion(Ray.direction, InvRot);
  LocalRay.direction := Vector3Normalize(LocalDir);
  Box.min := Vector3Create(-RayRadius, -Scale.y, -Scale.z);
  Box.max := Vector3Create(RayRadius, Scale.y, Scale.z);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 1;
    Exit;
  end;
  Box.min := Vector3Create(-Scale.x, -RayRadius, -Scale.z);
  Box.max := Vector3Create(Scale.x, RayRadius, Scale.z);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 2;
    Exit;
  end;
  Box.min := Vector3Create(-Scale.x, -Scale.y, -RayRadius);
  Box.max := Vector3Create(Scale.x, Scale.y, RayRadius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 3;
    Exit;
  end;
end;

function TRaylibSandbox.CheckGizmoScaleHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
var
  Box: TBoundingBox;
  Hit: TRayCollision;
  InvRot: TQuaternion;
  LocalRay: TRay;
  LocalDir: TVector3;
  Radius: Single;
begin
  Result := False;
  Axis := 0;

  // Make the radius thicker by default to make it easily grabbable
  Radius := RayRadius + 0.2;

  InvRot := QuaternionInvert(FItemSelected.Quaternion);
  LocalRay.position := Vector3RotateByQuaternion(Vector3Subtract(Ray.position, Pos), InvRot);
  LocalDir := Vector3RotateByQuaternion(Ray.direction, InvRot);
  LocalRay.direction := Vector3Normalize(LocalDir);

  // X Axis: Full thick line on BOTH sides (negative and positive) including handle cubes
  Box.min := Vector3Create(-Scale.x - Radius, -Radius, -Radius);
  Box.max := Vector3Create(Scale.x + Radius, Radius, Radius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 1;
    Exit;
  end;

  // Y Axis: Full thick line on BOTH sides
  Box.min := Vector3Create(-Radius, -Scale.y - Radius, -Radius);
  Box.max := Vector3Create(Radius, Scale.y + Radius, Radius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 2;
    Exit;
  end;

  // Z Axis: Full thick line on BOTH sides
  Box.min := Vector3Create(-Radius, -Radius, -Scale.z - Radius);
  Box.max := Vector3Create(Radius, Radius, Scale.z + Radius);
  Hit := GetRayCollisionBox(LocalRay, Box);
  if Hit.hit then
  begin
    Result := True;
    Axis := 3;
    Exit;
  end;
end;

procedure TRaylibSandbox.SetSelectedActor(AActor: TA3DComponent);
begin
  FItemSelected := AActor;
end;

function TRaylibSandbox.GetActorBoundingBoxWS(Actor: TA3DComponent): TBoundingBox;
var
  LocalBBox: TBoundingBox;
  Corners: array[0..7] of TVector3;
  RotatedCorners: array[0..7] of TVector3;
  RotQuat: TQuaternion;
  InvScale: TVector3;
  i: Integer;
  MinV, MaxV: TVector3;
  Sx, Sy, Sz: Single;
  HasSize: Boolean;
begin
  Result.min := Vector3Create(0, 0, 0);
  Result.max := Vector3Create(0, 0, 0);

  if not Assigned(Actor) then
    Exit;
  if Actor.ShapeType = stModel then
  begin
    if Actor.FModel.meshes = nil then
      Exit;
    LocalBBox := GetModelBoundingBox(Actor.FModel);
  end
  else
  begin
    LocalBBox.min := Vector3Create(-0.5, -0.5, -0.5);
    LocalBBox.max := Vector3Create(0.5, 0.5, 0.5);
  end;

  Sx := Actor.Scale.x;
  Sy := Actor.Scale.y;
  Sz := Actor.Scale.z;
  if Sx <= 0 then
    Sx := 0.0001;
  if Sy <= 0 then
    Sy := 0.0001;
  if Sz <= 0 then
    Sz := 0.0001;

  InvScale := Vector3Create(1.0 / Sx, 1.0 / Sy, 1.0 / Sz);
  LocalBBox.min := Vector3Multiply(LocalBBox.min, InvScale);
  LocalBBox.max := Vector3Multiply(LocalBBox.max, InvScale);

  Corners[0] := Vector3Create(LocalBBox.min.x, LocalBBox.min.y, LocalBBox.min.z);
  Corners[1] := Vector3Create(LocalBBox.max.x, LocalBBox.min.y, LocalBBox.min.z);
  Corners[2] := Vector3Create(LocalBBox.min.x, LocalBBox.max.y, LocalBBox.min.z);
  Corners[3] := Vector3Create(LocalBBox.max.x, LocalBBox.max.y, LocalBBox.min.z);
  Corners[4] := Vector3Create(LocalBBox.min.x, LocalBBox.min.y, LocalBBox.max.z);
  Corners[5] := Vector3Create(LocalBBox.max.x, LocalBBox.min.y, LocalBBox.max.z);
  Corners[6] := Vector3Create(LocalBBox.min.x, LocalBBox.max.y, LocalBBox.max.z);
  Corners[7] := Vector3Create(LocalBBox.max.x, LocalBBox.max.y, LocalBBox.max.z);

  RotQuat := Actor.Quaternion;

  HasSize := False;
  for i := 0 to 7 do
  begin
    RotatedCorners[i] := Vector3RotateByQuaternion(Corners[i], RotQuat);
    if not HasSize then
    begin
      MinV := RotatedCorners[i];
      MaxV := RotatedCorners[i];
      HasSize := True;
    end
    else
    begin
      if RotatedCorners[i].x < MinV.x then
        MinV.x := RotatedCorners[i].x;
      if RotatedCorners[i].y < MinV.y then
        MinV.y := RotatedCorners[i].y;
      if RotatedCorners[i].z < MinV.z then
        MinV.z := RotatedCorners[i].z;
      if RotatedCorners[i].x > MaxV.x then
        MaxV.x := RotatedCorners[i].x;
      if RotatedCorners[i].y > MaxV.y then
        MaxV.y := RotatedCorners[i].y;
      if RotatedCorners[i].z > MaxV.z then
        MaxV.z := RotatedCorners[i].z;
    end;
  end;

  Result.min := Vector3Add(MinV, Actor.Position);
  Result.max := Vector3Add(MaxV, Actor.Position);
end;

procedure TRaylibSandbox.SpawnAtMouse(Pos: TVector3);
var
  Obj: TA3DComponent;
  oldLen: Integer;
  Data: PItemData;
  Size: TVector3;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  YOffset: Single;
  BBox: TBoundingBox;
  MeshSize: TVector3;
  MaxDim, MeshH, UniformScale: Single;
begin
  oldLen := Length(FItems);
  SetLength(FItems, oldLen + 1);
  New(Data);
  FillChar(Data^, SizeOf(TItemData), 0);
  Data^.SpawnTime := GetTime();
  Data^.IsProjectile := False;
  if FBrushShape = stModel then
    Data^.Name := 'Model_' + IntToStr(oldLen)
  else
  begin
    case FBrushShape of
      stBox:
        Data^.Name := 'Cube_' + IntToStr(oldLen);
      stSphere:
        Data^.Name := 'Sphere_' + IntToStr(oldLen);
      stPyramid:
        Data^.Name := 'Pyramid_' + IntToStr(oldLen);
      stCapsule:
        Data^.Name := 'Capsule_' + IntToStr(oldLen);
      stPrism:
        Data^.Name := 'Prism_' + IntToStr(oldLen);
      stBomb:
        Data^.Name := 'Placed_Bomb_' + IntToStr(oldLen);
    end;
  end;

  Size := Vector3Create(1, 1, 1);
  if FBrushShape = stPrism then
    Size := Vector3Create(1, 1.5, 1)
  else if FBrushShape = stPyramid then
    Size := Vector3Create(1, 1.5, 1);

  if FBrushShape = stModel then
  begin
    BBox := GetModelBoundingBox(FCustomModel);
    MeshSize := Vector3Create(BBox.max.x - BBox.min.x, BBox.max.y - BBox.min.y, BBox.max.z - BBox.min.z);

    MaxDim := Max(MeshSize.x, Max(MeshSize.y, MeshSize.z));
    if MaxDim <= 0 then
      MaxDim := 1.0;
    UniformScale := 1.0 / MaxDim;

    // Pass size to Jolt Physics and add 0.1 to force Jolt to lift the object higher
    Size := Vector3Create((MeshSize.x * UniformScale) + 0.1, (MeshSize.y * UniformScale) + 0.1, (MeshSize.z * UniformScale) + 0.1);
  end;

  JPos.x := Pos.x;

  // Default Y-Offset for primitives (Cube etc. has height 1, so 0.5)
  YOffset := 0.5;

  // FOR CAPSULES: Because the engine code (Scale.y * 0.5 + 0.5) results in a 1.0 height
  // for a base scale of 1.0, we need to lift it by 1.0 to sit perfectly on the ground!
  if FBrushShape = stCapsule then
    YOffset := 1.0;

  if FBrushShape = stPrism then
    YOffset := 0.0;

  // FOR MODELS: Calculate exactly half the height of the scaled model!
  if FBrushShape = stModel then
  begin
    MeshH := (MeshSize.y * UniformScale);
    // Half height of the model + half padding (0.05)
    YOffset := (MeshH * 0.5) + 0.05;
  end;

  JPos.y := Pos.y + YOffset;
  JPos.z := Pos.z;
  JRot.x := 0;
  JRot.y := 0;
  JRot.z := 0;
  JRot.w := 1;

  Obj := TA3DComponent.Create('', FEngine, FBrushShape, Size, FSpawnStatic, FSpawnDestructable, @JPos, @JRot);
  Obj.Name := Data^.Name;

  if FBrushShape = stModel then
  begin
    Obj.FModel := FCustomModel;
    Obj.FMeshSize := MeshSize;

    MeshH := BBox.max.y - BBox.min.y;
    MaxDim := Max(BBox.max.x - BBox.min.x, Max(MeshH, BBox.max.z - BBox.min.z));
    if MaxDim <= 0 then
      MaxDim := 1.0;
    UniformScale := 1.0 / MaxDim;

    // Shift the mesh so its origin sits perfectly in the center of the Jolt collider
    var NormMinY := BBox.min.y * UniformScale;
    var CenterX := ((BBox.max.x + BBox.min.x) / 2) * UniformScale;
    var CenterZ := ((BBox.max.z + BBox.min.z) / 2) * UniformScale;
    // Push Y from bottom to center (Jolt standard goes from -0.5 to +0.5)
    Obj.FModelOffset := Vector3Create(-CenterX, -NormMinY - (MeshH * UniformScale * 0.5) + 0.5, -CenterZ);

    FCustomModel.meshes := nil;
  end;

  Obj.Friction := 1.0;
  Obj.Restitution := 0.0;
  Obj.UserData := Data;
  Obj.Visible := True;

  if FBrushShape = stBomb then
  begin
    Obj.Friction := 0.5;
    Obj.Restitution := 0.2;
    Obj.TargetColor := RED;
    Obj.ActColor := RED;
    Obj.FModel := FSphereModel;
    FBombActor := Obj;
    FBombTimer := 2.0;
    FBombExploded := False;
    if Assigned(FItemSelected) then
    begin
      FItemSelected := nil;
      DoObjectSelected(nil);
    end;
  end;

  Obj.SetPosition(Vector3Create(JPos.x, JPos.y, JPos.z));
  Obj.SetRotation(QuaternionFromEuler(0, 0, 0));
  FItems[oldLen] := Obj;
  PlaySpawnSound;
  TriggerSpawnEffect(Vector3Create(JPos.x, JPos.y, JPos.z), Obj);
  DoActorSpawned(Obj, oldLen);
end;

procedure TRaylibSandbox.LoadCustomModel(const FilePath: string);
begin
  FLock.Enter;
  try
    FQueuedModelPath := FilePath;
    FLoadModelQueued := True;
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.LoadModelInThread(const FilePath: string);
var
  PathBuf: array[0..1023] of AnsiChar;
  Ext: string;
begin
  if FCustomModel.meshes <> nil then
    UnloadModel(FCustomModel);
  if not System.SysUtils.FileExists(FilePath) then
  begin
    DoEngineException('Model file not found: ' + FilePath, 'LoadModelInThread');
    FIsBrushActive := False;
    FGhostVisible := False;
    Exit;
  end;
  FillChar(PathBuf, SizeOf(PathBuf), 0);
  StrPCopy(PathBuf, AnsiString(FilePath));
  OutputDebugString(PChar('Loading model safely in Raylib-Thread: ' + FilePath));
  FCustomModel := LoadModel(PathBuf);
  if FCustomModel.meshes <> nil then
  begin
    OutputDebugString('Model loaded successfully. Meshes assigned.');
    if (FCustomModel.materialCount > 0) and (FCustomModel.materials <> nil) then
    begin
      // Apply lighting shader to all materials of the model
      var matIdx: Integer;
      for matIdx := 0 to FCustomModel.materialCount - 1 do
        FCustomModel.materials[matIdx].shader := FLightShader;
    end;
    FBrushShape := stModel;
    FIsBrushActive := True;
    FGhostVisible := True;
  end
  else
  begin
    Ext := LowerCase(ExtractFileExt(FilePath));
    if (Ext = '.glb') or (Ext = '.gltf') then
      DoEngineException('Model loading FAILED. Meshes are nil. (GLB/GLTF requires libstdc++-6.dll or 64-bit)', 'LoadModelInThread')
    else if (Ext = '.obj') or (Ext = '.iqe') or (Ext = '.m3d') then
      DoEngineException('Model loading FAILED. Meshes are nil. Check for missing texture paths or corrupt mesh data.', 'LoadModelInThread')
    else
      DoEngineException('Model loading FAILED. Meshes are nil. Unsupported format?', 'LoadModelInThread');
    FIsBrushActive := False;
    FGhostVisible := False;
  end;
end;

procedure TRaylibSandbox.UpdateGame;
var
  dt: single;
  ItemVel: TVector3;
  i: Integer;
  IsTeal: Boolean;
  CamPosArr: array[0..2] of Single;
  LightPosArr: array[0..2] of Single;
  HoverRay: TRay;
  HoverScaleX, HoverScaleY, HoverScaleZ: Single;
  HoverAxis: Integer;
  Dir: TVector3;
  Dist: single;
  NewVel: TVector3;
  StartTime, EndTime, Freq: Int64;
  ShadowNeedsUpdate: Boolean;
  SunAngle, nDaytime: Single;
begin
  // Handle Scene Save
  if FSaveSceneQueued then
  begin
    FLock.Enter;
    try
      FSaveSceneQueued := False;
      ExecuteSceneSave(FQueuedSavePath);
      FQueuedSavePath := '';
    finally
      FLock.Leave;
    end;
  end;

  // Handle Scene Load
  if FLoadSceneQueued then
  begin
    FLock.Enter;
    try
      FLoadSceneQueued := False;
      ExecuteSceneLoad(FQueuedLoadPath);
      FQueuedLoadPath := '';
    finally
      FLock.Leave;
    end;
  end;

  if FLoadModelQueued then
  begin
    FLock.Enter;
    try
      FLoadModelQueued := False;
      LoadModelInThread(FQueuedModelPath);
    finally
      FLock.Leave;
    end;
  end;
  if FClearItemsQueued then
  begin
    FLock.Enter;
    try
      FDragging := False;
      FItemSelected := nil;
      FSpawnQueue := 0;
      for i := High(FItems) downto 0 do
      begin
        if Assigned(FItems[i]) then
        begin
          // Unload the button text texture if it exists
          if FItems[i].FButtonTexture.id > 0 then
            UnloadTexture(FItems[i].FButtonTexture);
          FItems[i].Visible := False;
          FItems[i].Free;
          FItems[i] := nil;
        end;
      end;
      for i := High(FProjectiles) downto 0 do
      begin
        if Assigned(FProjectiles[i]) then
        begin
          if FProjectiles[i].UserData <> nil then
            Dispose(PItemData(FProjectiles[i].UserData));
          FProjectiles[i].Free;
          FProjectiles[i] := nil;
        end;
      end;
      SetLength(FProjectiles, 0);
      SetLength(FItems, 0);
      FSandboxSpawned := False;
      FClearItemsQueued := False;
      DoSceneCleared;
    finally
      FLock.Leave;
    end;
  end;
  dt := GetFrameTime();

  if Assigned(FMPVPlayer) then
    FMPVPlayer.Update;

  // Slow Motion calculation: Scale time if active, otherwise normal speed
  if FSlowMotionActive then
    FTimeScale := 0.2 // 20% speed
  else
    FTimeScale := 1.0; // Normal speed

  // Calculate physics delta time based on slow motion scale
  var PhysDt: Single := dt * FTimeScale;

  HandleCameraInput;
  HandleDesktopInput;
  ProcessSpawnQueue(dt);
  ProcessCustomSpawnQueue(dt); // Process custom external spawns
  UpdateBomb(PhysDt); // Pass slowed down time to bomb timer
  if FSimulationRunning then
  begin
    try
      QueryPerformanceCounter(StartTime);
      FEngine.Update(PhysDt); // Pass slowed down time to Jolt Physics
      QueryPerformanceCounter(EndTime);
      QueryPerformanceFrequency(Freq);
      FLastPhysicsTime := (EndTime - StartTime) * 1000.0 / Freq;
      FActiveBodies := 0;
      for i := 0 to High(FItems) do
      begin
        if Assigned(FItems[i]) then
        begin
          var Vel := FItems[i].GetLinearVelocity;
          if (Abs(Vel.x) > 0.1) or (Abs(Vel.y) > 0.1) or (Abs(Vel.z) > 0.1) then
            Inc(FActiveBodies);
        end;
      end;
    except
      on E: Exception do
        DoEngineException(E.Message, 'PhysicsUpdate');
    end;
  end
  else
  begin
    FActiveBodies := 0;
    FLastPhysicsTime := 0;
  end;
  if (FSceneStartTime > 0) and (GetTime() - FSceneStartTime > 1.0) then
    FSceneStartTime := 0;
  if (FSceneStartTime = 0) and (FHUDAnimY < 0) then
  begin
    FHUDAnimY := FHUDAnimY * (1.0 - dt * 6.0);
    if FHUDAnimY > -0.5 then
      FHUDAnimY := 0;
  end;
  FGizmoHoverAxis := 0;
  if FInitialized and Assigned(FItemSelected) and not FGizmoDragging and not FDragging and not FPopupOpen and (FGizmoMode <> gmNone) then
  begin
    HoverRay := GetScreenToWorldRay(FMousePos, FCamera);

    // Calculate default hover scale
    HoverScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 1.0, 1.0, 100.0);
    HoverScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 1.0, 1.0, 100.0);
    HoverScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 1.0, 1.0, 100.0);

    // FOR MODELS: Scale the hover boxes to match the new giant gizmo arms!
    if FItemSelected.ShapeType = stModel then
    begin
      var BBox := GetModelBoundingBox(FItemSelected.FModel);
      var PhysRadius := Max(BBox.max.x - BBox.min.x, Max(BBox.max.y - BBox.min.y, BBox.max.z - BBox.min.z)) * Max(FItemSelected.Scale.x, Max(FItemSelected.Scale.y, FItemSelected.Scale.z)) * 0.5;

      HoverScaleX := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
      HoverScaleY := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
      HoverScaleZ := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
    end;

    if FGizmoMode = gmTranslate then
    begin
      if CheckGizmoAxisHit(FItemSelected.Position, Vector3Create(HoverScaleX, HoverScaleY, HoverScaleZ), 0.4, HoverRay, HoverAxis) then
        FGizmoHoverAxis := HoverAxis;
    end
    else if FGizmoMode = gmRotate then
    begin
      if CheckGizmoRingHit(FItemSelected.Position, Vector3Create(HoverScaleX, HoverScaleY, HoverScaleZ), 0.2, HoverRay, HoverAxis) then
        FGizmoHoverAxis := HoverAxis;
    end
    else if FGizmoMode = gmScale then
    begin
      if CheckGizmoScaleHit(FItemSelected.Position, Vector3Create(HoverScaleX, HoverScaleY, HoverScaleZ), 0.4, HoverRay, HoverAxis) then
        FGizmoHoverAxis := HoverAxis;
    end;
  end;
  if FHighlightCollision then
  begin
    for i := 0 to High(FItems) do
    begin
      if Assigned(FItems[i]) and (FItems[i].UserData <> nil) then
      begin
        if PItemData(FItems[i].UserData)^.IsProjectile then
          Continue;
        ItemVel := FItems[i].GetLinearVelocity;
        if (Abs(ItemVel.x) > 2.0) or (Abs(ItemVel.y) > 2.0) or (Abs(ItemVel.z) > 2.0) then
          PItemData(FItems[i].UserData)^.LastHitTime := GetTime();
        IsTeal := (GetTime() - PItemData(FItems[i].UserData)^.LastHitTime) < 0.3;
        FItems[i].CollisionHighlighting := IsTeal or (FItems[i] = FItemSelected);
      end;
    end;
  end
  else
  begin
    for i := 0 to High(FItems) do
    begin
      if Assigned(FItems[i]) then
        FItems[i].CollisionHighlighting := (FItems[i] = FItemSelected);
    end;
  end;
  if FDragging and Assigned(FItemSelected) and (FGizmoMode = gmDragAndThrow) then
  begin
    Dir.x := FDragTargetPos.x - FItemSelected.Position.x;
    Dir.y := 0;
    Dir.z := FDragTargetPos.z - FItemSelected.Position.z;
    Dist := Sqrt(Dir.x * Dir.x + Dir.z * Dir.z);
    if Dist > 0.05 then
    begin
      FItemSelected.ActivateBody;
      NewVel.x := Dir.x * 10.0;
      NewVel.y := FItemSelected.GetLinearVelocity.y;
      NewVel.z := Dir.z * 10.0;
      FItemSelected.SetLinearVelocity(NewVel);
      NewVel := FItemSelected.GetAngularVelocity;
      NewVel.x := NewVel.x * 0.9;
      NewVel.y := NewVel.y * 0.9;
      NewVel.z := NewVel.z * 0.9;
      FItemSelected.SetAngularVelocity(NewVel);
    end
    else
    begin
      NewVel := FItemSelected.GetLinearVelocity;
      NewVel.x := 0;
      NewVel.z := 0;
      FItemSelected.SetLinearVelocity(NewVel);
    end;
  end;

  // Only advance day/night cycle if the rhythm is active
  ShadowNeedsUpdate := False;

  if FDayNightRhythmActive then
  begin
    FDayTime := FDayTime + (FDaySpeed * dt);
    if FDayTime > 1.0 then
      FDayTime := FDayTime - 1.0;
    if FDayTime < 0.0 then
      FDayTime := FDayTime + 1.0;
    ShadowNeedsUpdate := True; // Sonne bewegt sich!
  end;

  SunAngle := Lerp(-90, 270, FDayTime) * DEG2RAD;
  nDaytime := Sin(SunAngle);

  FSunPos := Vector3Create(Cos(SunAngle) * 100.0, Sin(SunAngle) * 100.0, 50.0);

  // Wenn ein Objekt verschoben wurde (Gizmo), Schatten updaten!
  if FGizmoDragging or FDragging then
    ShadowNeedsUpdate := True;

  // 2. Das Dirty-Flag an RenderShadowMap übergeben
  FShadowMapDirty := ShadowNeedsUpdate;

  // Center the shadow camera between all active objects
  FLightCam.target := FCamera.target; // Fallback: Look where the camera looks
  if Length(FItems) > 0 then
  begin
    FLightCam.target := Vector3Create(0, 0, 0);
    for i := 0 to High(FItems) do
      if Assigned(FItems[i]) then
        FLightCam.target := Vector3Add(FLightCam.target, FItems[i].Position);
    FLightCam.target := Vector3Scale(FLightCam.target, 1.0 / Length(FItems));
  end;

  // Position the light camera high up along the sun ray
  FLightCam.position := Vector3Add(FLightCam.target, Vector3Scale(FLightPos, 50.0));

  if nDaytime < 0 then
  begin
    FSunColor := Vector4Create(0.1, 0.1, 0.2, 1.0);
    FAmbientColor := Vector4Create(0.1, 0.1, 0.15, 1.0);
  end
  else
  begin
    FSunColor := Vector4Create(1.0, EnsureRange(nDaytime * 1.5, 0, 1), EnsureRange(nDaytime * 0.8, 0, 1), 1.0);
    FAmbientColor := Vector4Create(0.2 + nDaytime * 0.3, 0.2 + nDaytime * 0.3, 0.2 + nDaytime * 0.4, 1.0);
  end;

  if FSkyboxShader.id > 0 then
    SetShaderValue(FSkyboxShader, FSkyboxDaytimeLoc, @nDaytime, SHADER_UNIFORM_FLOAT);

  // Update Clouds
  FCloudMoveFactor := FCloudMoveFactor + 0.002 * dt;
  if FCloudMoveFactor > 1.0 then
    FCloudMoveFactor := FCloudMoveFactor - 1.0;
  if FCloudShader.id > 0 then
  begin
    SetShaderValue(FCloudShader, FCloudMoveFactorLoc, @FCloudMoveFactor, SHADER_UNIFORM_FLOAT);
    SetShaderValue(FCloudShader, FCloudDaytimeLoc, @nDaytime, SHADER_UNIFORM_FLOAT);
  end;

  // Update Lighting Uniforms EVERY FRAME
  CamPosArr[0] := FCamera.position.x;
  CamPosArr[1] := FCamera.position.y;
  CamPosArr[2] := FCamera.position.z;
  SetShaderValue(FLightShader, FViewPosLoc, @CamPosArr, SHADER_UNIFORM_VEC3);

  LightPosArr[0] := FLightPos.x;
  LightPosArr[1] := FLightPos.y;
  LightPosArr[2] := FLightPos.z;
  SetShaderValue(FLightShader, FLightPosLoc, @LightPosArr, SHADER_UNIFORM_VEC3);

  SetShaderValue(FLightShader, FAmbientLoc, @FAmbientColor, SHADER_UNIFORM_VEC4);
  SetShaderValue(FLightShader, FDiffuseLoc, @FSunColor, SHADER_UNIFORM_VEC4);

  var LightViewMat := GetCameraMatrix(FLightCam);
  // Increase the orthographic shadow view area to cover the map
  var LightProjMat := MatrixOrtho(-400, 400, -400, 400, 0.1, 2000.0);

  SetShaderValueMatrix(FLightShader, FLightViewLoc, LightViewMat);
  SetShaderValueMatrix(FLightShader, FLightProjLoc, LightProjMat);

  SetShaderValueTexture(FLightShader, FShadowMapLoc, FShadowMap.texture);

  // Bias to prevent shadow acne
  var TempBias: Single := 0.05;
  SetShaderValue(FLightShader, GetShaderLocation(FLightShader, 'shadowBias'), @TempBias, SHADER_UNIFORM_FLOAT);
end;

procedure TRaylibSandbox.RenderGame;
begin
  // Render the Shadow Map from the light's perspective
  if FShadowMapDirty then
  begin
    RenderShadowMap;
    FShadowMapDirty := False;
  end;

  // Render the main scene
  BeginDrawing();
  ClearBackground(BLACK);
  if Assigned(FMPVPlayer) then
    FMPVPlayer.Render;
  Render3DScene;
  DrawGUI;
  DrawNativePopup;
  EndDrawing();

  if FRaylibWnd <> 0 then
    RedrawWindow(FRaylibWnd, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
end;

procedure TRaylibSandbox.RenderShadowMap;
begin
  if FShadowMap.id = 0 then
    Exit;

  BeginTextureMode(FShadowMap);

  // Optimization: Re-use the pre-allocated default shader instead of loading/unloading every frame
  BeginShaderMode(FDefaultShader);

  rlDrawRenderBatchActive();

  BeginMode3D(FLightCam);
  DrawSceneShadows;
  EndMode3D();

  // Disable default shader
  EndShaderMode();

  EndTextureMode();
<<<<<<< HEAD
end;
=======
end;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
// Custom procedure to draw a Holodeck-style grid with a specific color

procedure TRaylibSandbox.DrawHolodeckGrid(Slices: Integer; Spacing: Single; GridColor: TColorB);
var
  I: Integer;
  HalfSize: Single;
begin
  // Only draw grid if we are inside a 3D mode (camera is set)
  if FCamera.position.y = 0 then
    Exit;

  // Calculate the total size of the grid
  HalfSize := (Slices * Spacing) / 2.0;

  // Draw vertical and horizontal lines, slightly lifted (0.01) to prevent Z-Fighting
  for I := 0 to Slices do
  begin
    var Pos: Single := -HalfSize + (I * Spacing);

    // Draw X-axis lines (going into Z depth)
    DrawLine3D(Vector3Create(Pos, 0.01, -HalfSize), Vector3Create(Pos, 0.01, HalfSize), GridColor);

    // Draw Z-axis lines (going across X)
    DrawLine3D(Vector3Create(-HalfSize, 0.01, Pos), Vector3Create(HalfSize, 0.01, Pos), GridColor);
  end;
end;

procedure TRaylibSandbox.DrawSceneShadows;
var
  i: Integer;
  Actor: TA3DComponent;
  Pos: TVector3;
  Axis: TVector3;
  Angle: Single;
begin
  // Draw static floor to the shadow map
  DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), BLACK);

  // Draw all items to the shadow map
  for i := 0 to FEngine.Count - 1 do
  begin
    Actor := FEngine.Items[i];
    if Assigned(Actor) and Actor.Visible then
    begin
      rlPushMatrix();
      Pos := Actor.Position;
      rlTranslatef(Pos.x, Pos.y, Pos.z);

      Axis := Vector3Create(1, 1, 1);
      Angle := 0;
      if Actor.Quaternion.w < 1.0 then
        QuaternionToAxisAngle(Actor.Quaternion, @Axis, @Angle);
      rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

      rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);

      if Actor.ShapeType = stBox then
        DrawCube(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK)
      else if Actor.ShapeType = stSphere then
        DrawSphere(Vector3Create(0, 0, 0), 0.5, BLACK)
      else if Actor.ShapeType = stCapsule then
        DrawCylinderEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, BLACK)
      else if Actor.ShapeType = stModel then
        DrawCube(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK) // Approximation for custom models
      else if (Actor.ShapeType = stPyramid) or (Actor.ShapeType = stPrism) then
      begin
        var TopR: Single := 0.0;
        if Actor.ShapeType = stPrism then
          TopR := 0.5;
        var Segs: Integer := 4;
        if Actor.ShapeType = stPrism then
          Segs := 3;

        // Offset in Y to align with Jolt physics center of mass
        if Actor.ShapeType = stPyramid then
          rlTranslatef(0.0, -0.25, 0.0)
        else if Actor.ShapeType = stPrism then
          rlTranslatef(0.0, -0.5, 0.0);

        DrawCylinderEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), TopR, 0.5, Segs, BLACK);
      end;

      rlPopMatrix();
    end;
  end;
end;

procedure TRaylibSandbox.Render3DScene;
<<<<<<< HEAD
var
  i: Integer;
  Actor: TA3DComponent;
  Dist, MaxDist: Single;
  CamForward, ToActor, ToActorNorm: TVector3;
  DotP: Single;
  Pos: TVector3;
  Axis: TVector3;
  Angle: Single;
  dt: Single;
  ViewMat, ProjMat: TMatrix;
  ModelMat: TMatrix;
  ModelMatLoc: Integer;
  ActorColorLoc: Integer;
  ColorShaderVec: array[0..3] of Single;

  function GetActorColor(A: TA3DComponent): TColorB;
  const
    COL_CUBE: TColorB = (R: 230; g: 41; b: 55; A: 255);
    COL_PYRAMID: TColorB = (R: 255; g: 161; b: 0; A: 255);
    COL_SPHERE: TColorB = (R: 179; g: 71; b: 217; A: 255);
    COL_CAPSULE: TColorB = (R: 0; g: 168; b: 150; A: 255);
    COL_TEAL: TColorB = (R: 64; g: 224; b: 208; A: 255);
  begin
    Result.a := Round(255 * A.ActAlpha);
    if A.CollisionHighlighting then
      Exit(COL_TEAL);

    // If the Actor has a custom color assigned (like spawned walls), use it!
    if (A.ActColor.r <> WHITE.r) or (A.ActColor.g <> WHITE.g) or (A.ActColor.b <> WHITE.b) or (A.ActColor.a <> WHITE.a) then
      Exit(A.ActColor);

    case A.ShapeType of
      stBox: Exit(COL_CUBE);
      stPyramid: Exit(COL_PYRAMID);
      stSphere: Exit(COL_SPHERE);
      stCapsule: Exit(COL_CAPSULE);
      stPrism: Exit(COL_PRISM);
      stBomb: Exit(RED);
    else
      Exit(WHITE);
    end;
  end;

begin
  ActorColorLoc := GetShaderLocation(FLightShader, 'diffuse');

  BeginMode3D(FCamera);

  // 1. Draw Skybox (Infinite background)
  if FSkyboxModel.meshes <> nil then
  begin
    rlDisableDepthMask();
    ViewMat := GetCameraMatrix(FCamera);
    ProjMat := MatrixPerspective(FCamera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
    SetShaderValueMatrix(FSkyboxShader, FSkyboxViewLoc, ViewMat);
    SetShaderValueMatrix(FSkyboxShader, FSkyboxProjLoc, ProjMat);

    if (FCurrentWorldBase = wbSpace) or (FCurrentWorldBase = wbHolodeck) then
    begin
      var BlackSkyColor: TColorB := BLACK;
      DrawModel(FSkyboxModel, FCamera.position, 1.0, BlackSkyColor);
    end
    else
    begin
      rlDisableBackfaceCulling();
      DrawModel(FSkyboxModel, FCamera.position, 1.0, WHITE);
      rlEnableBackfaceCulling();
    end;

    rlEnableDepthMask();
  end;

  // 2. Draw Floor with Lighting Shader
  BeginShaderMode(FLightShader);

  if FCurrentWorldBase = wbLand then
    DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), DARKGREEN)
  else if FCurrentWorldBase = wbSpace then
    DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), BLACK)
  else if FCurrentWorldBase = wbHolodeck then
    DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), BLACK);

  EndShaderMode();

  if FCurrentWorldBase = wbHolodeck then
  begin
    var WarmOrange: TColorB;
    WarmOrange.r := 255; WarmOrange.g := 130; WarmOrange.b := 0; WarmOrange.a := 255;
    DrawHolodeckGrid(200, 5.0, Fade(WarmOrange, 0.85));
  end;

  // 3. Draw Clouds
  if (FCloudModel.meshes <> nil) and ((FCurrentWorldBase = wbLand) or (FCurrentWorldBase = wbIsland)) then
  begin
    BeginShaderMode(FCloudShader);
    DrawModel(FCloudModel, Vector3Create(FCamera.position.x, 150, FCamera.position.z), 1.0, WHITE);
    EndShaderMode();
  end;

  // 4. Draw Actors
  MaxDist := FMaxRenderDistance;
  CamForward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));
  ModelMatLoc := GetShaderLocation(FLightShader, 'matModel');
  rlSetBlendMode(BLEND_ALPHA);

  for i := 0 to FEngine.Count - 1 do
  begin
    Actor := FEngine.Items[i];
    if Assigned(Actor) and Actor.Visible then
    begin
      if (Actor.UserData <> nil) and PItemData(Actor.UserData)^.IsProjectile then
        Continue;

      Dist := Vector3Distance(Actor.Position, FCamera.position);
      if FDistanceCulling and (Dist > MaxDist) then Continue;

      ToActor := Vector3Subtract(Actor.Position, FCamera.position);
      ToActorNorm := Vector3Normalize(ToActor);
      DotP := Vector3DotProduct(ToActorNorm, CamForward);
      if FFrustumCulling and (DotP < 0.5) then Continue;

      rlPushMatrix();
      Pos := Actor.Position;
      rlTranslatef(Pos.x, Pos.y, Pos.z);

      Axis := Vector3Create(1, 1, 1);
      Angle := 0;
      if Actor.Quaternion.w < 1.0 then
        QuaternionToAxisAngle(Actor.Quaternion, @Axis, @Angle);
      rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

      rlDrawRenderBatchActive();
      BeginShaderMode(FLightShader);

      ModelMat := rlGetMatrixTransform();
      SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

      if Actor.ShapeType = stModel then
      begin
        rlTranslatef(Actor.FModelOffset.x, Actor.FModelOffset.y, Actor.FModelOffset.z);
        rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
        var TintCol: TColorB := GetActorColor(Actor);
        DrawModel(Actor.FModel, Vector3Create(0, 0, 0), 1.0, Fade(TintCol, Actor.ActAlpha));
      end
      else
      begin
        var C: TColorB := GetActorColor(Actor);
        ColorShaderVec[0] := C.r / 255.0;
        ColorShaderVec[1] := C.g / 255.0;
        ColorShaderVec[2] := C.b / 255.0;
        ColorShaderVec[3] := Actor.ActAlpha;
        SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);

        // ====================================================================
        // PIANO KEY LOGIC: CHECK THIS FIRST SO IT NEVER GETS OVERRIDDEN!
        // ====================================================================
        if Actor.IsPianoKey then
        begin
          // 1. Move key DOWN BEFORE scaling! 0.15 is exactly 0.15 units.
          if Actor.IsPressed then
            rlTranslatef(0, -0.08, 0);

          // 2. Apply Scale ONCE
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);

          // 3. Render the key
          FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          C := Actor.ActColor;
          ColorShaderVec[0] := C.r / 255.0;
          ColorShaderVec[1] := C.g / 255.0;
          ColorShaderVec[2] := C.b / 255.0;
          ColorShaderVec[3] := 1.0;
          SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);

          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, Actor.ActColor);
          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
        end
        else if Actor.ShapeType = stSphere then
        begin
          var SphereScale: Single := Max(Actor.Scale.x, Max(Actor.Scale.y, Actor.Scale.z)) * 0.5;
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawModel(FSphereModel, Vector3Create(0, 0, 0), SphereScale, GetActorColor(Actor));
        end
        else if Actor.ShapeType = stBox then
        begin
          // NORMAL PHYSICS BOX (Cubes, Walls, etc.)
          if Actor.FVideoTexture.id > 0 then
          begin
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FVideoTexture;
            ColorShaderVec[0] := 1.0; ColorShaderVec[1] := 1.0; ColorShaderVec[2] := 1.0; ColorShaderVec[3] := 1.0;
=======
var
  i: Integer;
  Actor: TA3DComponent;
  Dist, MaxDist: Single;
  CamForward, ToActor, ToActorNorm: TVector3;
  DotP: Single;
  Pos: TVector3;
  Axis: TVector3;
  Angle: Single;
  dt: Single;
  ViewMat, ProjMat: TMatrix;
  ModelMat: TMatrix;
  ModelMatLoc: Integer;
  ActorColorLoc: Integer;
  ColorShaderVec: array[0..3] of Single;

  function GetActorColor(A: TA3DComponent): TColorB;
  const
    COL_CUBE: TColorB = (
    R: 230;
    g: 41;
    b: 55;
    A: 255
  );
    COL_PYRAMID: TColorB = (
    R: 255;
    g: 161;
    b: 0;
    A: 255
  );
    COL_SPHERE: TColorB = (
    R: 179;
    g: 71;
    b: 217;
    A: 255
  );
    COL_CAPSULE: TColorB = (
    R: 0;
    g: 168;
    b: 150;
    A: 255
  );
    COL_TEAL: TColorB = (
    R: 64;
    g: 224;
    b: 208;
    A: 255
  );
  begin
    Result.a := Round(255 * A.ActAlpha);
    if A.CollisionHighlighting then
      Exit(COL_TEAL);

    // If the Actor has a custom color assigned (like spawned walls), use it!
    if (A.ActColor.r <> WHITE.r) or (A.ActColor.g <> WHITE.g) or (A.ActColor.b <> WHITE.b) or (A.ActColor.a <> WHITE.a) then
      Exit(A.ActColor);

    case A.ShapeType of
      stBox:
        Exit(COL_CUBE);
      stPyramid:
        Exit(COL_PYRAMID);
      stSphere:
        Exit(COL_SPHERE);
      stCapsule:
        Exit(COL_CAPSULE);
      stPrism:
        Exit(COL_PRISM);
      stBomb:
        Exit(RED);
    else
      Exit(WHITE);
    end;
  end;

begin
  ActorColorLoc := GetShaderLocation(FLightShader, 'diffuse');

  BeginMode3D(FCamera);

  // 1. Draw Skybox (Infinite background)
  if FSkyboxModel.meshes <> nil then
  begin
    rlDisableDepthMask();
    ViewMat := GetCameraMatrix(FCamera);
    ProjMat := MatrixPerspective(FCamera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
    SetShaderValueMatrix(FSkyboxShader, FSkyboxViewLoc, ViewMat);
    SetShaderValueMatrix(FSkyboxShader, FSkyboxProjLoc, ProjMat);

    // BASE WORLD SKYBOX OVERRIDE: Force deep black for Space and Holodeck
    if (FCurrentWorldBase = wbSpace) or (FCurrentWorldBase = wbHolodeck) then
    begin
      var BlackSkyColor: TColorB := BLACK;
      DrawModel(FSkyboxModel, FCamera.position, 1.0, BlackSkyColor);
    end
    else
    begin
      rlDisableBackfaceCulling();
      DrawModel(FSkyboxModel, FCamera.position, 1.0, WHITE);
      rlEnableBackfaceCulling();
    end;

    rlEnableDepthMask();
  end;

  // 2. Draw Floor with Lighting Shader
  BeginShaderMode(FLightShader);

  // BASE WORLD FLOOR RENDERING
  if FCurrentWorldBase = wbLand then
  begin
    DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), DARKGREEN);
  end
  else if FCurrentWorldBase = wbSpace then
  begin
    // Space: Pure black floor to blend with the void
    DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), BLACK);
  end
  else if FCurrentWorldBase = wbHolodeck then
  begin
    // Holodeck: Black floor with glowing Teal grid lines
    DrawPlane(Vector3Create(0, 0, 0), Vector2Create(1000, 1000), BLACK);
  end;

  EndShaderMode();

  // BASE WORLD GRID RENDERING (Must be drawn outside the lighting shader to glow)
  if FCurrentWorldBase = wbHolodeck then
  begin
    var WarmOrange: TColorB;
    WarmOrange.r := 255;
    WarmOrange.g := 130;
    WarmOrange.b := 0;
    WarmOrange.a := 255;

    DrawHolodeckGrid(200, 5.0, Fade(WarmOrange, 0.85));
  end;

  // 3. Draw Clouds (Transparency)
  // Only draw clouds if we are in Land mode!
  if (FCloudModel.meshes <> nil) and ((FCurrentWorldBase = wbLand) or (FCurrentWorldBase = wbIsland)) then
  begin
    BeginShaderMode(FCloudShader);
    DrawModel(FCloudModel, Vector3Create(FCamera.position.x, 150, FCamera.position.z), 1.0, WHITE);
    EndShaderMode();
  end;

  // 4. Draw Actors
  // Optimization: Use the customizable MaxRenderDistance property instead of a hardcoded value
  MaxDist := FMaxRenderDistance;
  CamForward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));

  ModelMatLoc := GetShaderLocation(FLightShader, 'matModel');
  rlSetBlendMode(BLEND_ALPHA);

  for i := 0 to FEngine.Count - 1 do
  begin
    Actor := FEngine.Items[i];
    if Assigned(Actor) and Actor.Visible then
    begin
      if (Actor.UserData <> nil) and PItemData(Actor.UserData)^.IsProjectile then
        Continue;
      Dist := Vector3Distance(Actor.Position, FCamera.position);
      if FDistanceCulling and (Dist > MaxDist) then
        Continue;
      ToActor := Vector3Subtract(Actor.Position, FCamera.position);
      ToActorNorm := Vector3Normalize(ToActor);
      DotP := Vector3DotProduct(ToActorNorm, CamForward);
      if FFrustumCulling and (DotP < 0.5) then
        Continue;

      rlPushMatrix();
      Pos := Actor.Position;
      rlTranslatef(Pos.x, Pos.y, Pos.z);
      Axis := Vector3Create(1, 1, 1);
      Angle := 0;
      if Actor.Quaternion.w < 1.0 then
        QuaternionToAxisAngle(Actor.Quaternion, @Axis, @Angle);
      rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

      rlDrawRenderBatchActive();
      BeginShaderMode(FLightShader);

      ModelMat := rlGetMatrixTransform();
      SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

      if Actor.ShapeType = stModel then
      begin
        rlTranslatef(Actor.FModelOffset.x, Actor.FModelOffset.y, Actor.FModelOffset.z);
        rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
        var TintCol: TColorB := GetActorColor(Actor);
        DrawModel(Actor.FModel, Vector3Create(0, 0, 0), 1.0, Fade(TintCol, Actor.ActAlpha));

      end
      else
      begin
        // Enable the lighting shader
        BeginShaderMode(FLightShader);

        // Create the color array from the actor's color
        var C: TColorB := GetActorColor(Actor);

        ColorShaderVec[0] := C.r / 255.0; // Red (0.0 to 1.0)
        ColorShaderVec[1] := C.g / 255.0; // Green (0.0 to 1.0)
        ColorShaderVec[2] := C.b / 255.0; // Blue (0.0 to 1.0)
        ColorShaderVec[3] := Actor.ActAlpha;

        // Send the color directly to the shader uniform
        SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);

        if Actor.ShapeType = stSphere then
        begin
          var SphereScale: Single := Max(Actor.Scale.x, Max(Actor.Scale.y, Actor.Scale.z)) * 0.5;

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawModel(FSphereModel, Vector3Create(0, 0, 0), SphereScale, GetActorColor(Actor));
        end
        else if Actor.ShapeType = stBox then
        begin
          // If this box has a video texture, assign it.
          if Actor.FVideoTexture.id > 0 then
          begin
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FVideoTexture;

            ColorShaderVec[0] := 1.0;
            ColorShaderVec[1] := 1.0;
            ColorShaderVec[2] := 1.0;
            ColorShaderVec[3] := 1.0;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
            SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          end
          else
          begin
<<<<<<< HEAD
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
            C:= GetActorColor(Actor);
            ColorShaderVec[0] := C.r / 255.0; ColorShaderVec[1] := C.g / 255.0; ColorShaderVec[2] := C.b / 255.0; ColorShaderVec[3] := C.A / 255.0;
=======
            // Assign a pure 1x1 WHITE texture to prevent Raylib's default 200,200,200 gray!
            // We use FDefaultWhiteTex, but we need to make sure it is PURE white.
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

            // We set the tint color via the shader uniform (vColor)
            C:= GetActorColor(Actor);
            ColorShaderVec[0] := C.r / 255.0;
            ColorShaderVec[1] := C.g / 255.0;
            ColorShaderVec[2] := C.b / 255.0;
            ColorShaderVec[3] := C.A / 255.0;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
            SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          end;

          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
<<<<<<< HEAD
=======

>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          if Actor.FVideoTexture.id > 0 then
            DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, WHITE)
          else
            DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(Actor));

          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
<<<<<<< HEAD
        end
        else if Actor.ShapeType = stBomb then
        begin
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawModel(FSphereModel, Vector3Create(0, 0, 0), 0.5, GetActorColor(Actor));
        end
        else if Actor.ShapeType = stCapsule then
        begin
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          rlPushMatrix();
          rlTranslatef(0.0, -0.5, 0.0);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawModel(FCapsuleModel, Vector3Create(0, -0.5, 0), 1.0, GetActorColor(Actor));
          DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, BLACK);
          rlPopMatrix();
        end
        else if Actor.ShapeType = stPyramid then
        begin
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          rlTranslatef(0.0, -0.25, 0.0);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawModel(FPyramidModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(Actor));
          rlPushMatrix();
          rlRotatef(45.0, 0.0, 1.0, 0.0);
          DrawCylinderWiresEx(Vector3Create(0, 1, 0), Vector3Create(0, 0, 0), 0.0, 0.5, 4, BLACK);
          rlPopMatrix();
        end
        else if Actor.ShapeType = stPrism then
        begin
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          rlPushMatrix();
          rlTranslatef(0.0, -0.5, 0.0);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawModel(FPrismModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(Actor));
          rlPopMatrix;

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          rlPushMatrix;
          rlRotatef(90.0, 0.0, 1.0, 0.0);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 3, BLACK);
          rlPopMatrix;
        end
        // ====================================================================
        // 3D UI BUTTON (100% RESTORED AND UNTOUCHED)
        // ====================================================================
        else if Actor.ShapeType = stButton then
        begin
          // Button movement: Only move inward when pressed
          var BtnOffset: Single := 0.0;
          if Actor.IsPressed then
            BtnOffset := -0.03; // Move slightly inward on click

          // 1. Draw the outer frame (darker color)
          rlPushMatrix();
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          var FrameCol: TColorB;
          FrameCol.r := Max(0, Round(Actor.BaseColor.r * 0.5));
          FrameCol.g := Max(0, Round(Actor.BaseColor.g * 0.5));
          FrameCol.b := Max(0, Round(Actor.BaseColor.b * 0.5));
          FrameCol.a := 255;

          DrawCube(Vector3Create(0, 0, -0.1), 1.0, 1.0, 1.0, FrameCol);
          rlPopMatrix();

          rlPushMatrix();
          rlTranslatef(0, 0, BtnOffset);
          rlScalef(Actor.Scale.x * 0.85, Actor.Scale.y * 0.85, Actor.Scale.z);

          if Actor.FVideoTexture.id > 0 then
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FVideoTexture
          else if Actor.FButtonTexture.id > 0 then
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FButtonTexture
          else
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          rlEnableBackfaceCulling();

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, Actor.ActColor);

          rlDisableBackfaceCulling();

          FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
          rlPopMatrix();
        end;

        EndShaderMode();
      end;

      EndShaderMode();
      rlPopMatrix();
    end;
  end;

  rlSetBlendMode(BLEND_ALPHA);

  // Selected Object
  if Assigned(FItemSelected) and FItemSelected.Visible then
  begin
    rlPushMatrix();
    Pos := FItemSelected.Position;
    rlTranslatef(Pos.x, Pos.y, Pos.z);

    Axis := Vector3Create(1, 1, 1);
    Angle := 0;
    if FItemSelected.Quaternion.w < 1.0 then
      QuaternionToAxisAngle(FItemSelected.Quaternion, @Axis, @Angle);
    rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

    rlDrawRenderBatchActive();
    BeginShaderMode(FLightShader);

    ModelMat := rlGetMatrixTransform();
    SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

    if FItemSelected.ShapeType = stModel then
    begin
      rlTranslatef(FItemSelected.FModelOffset.x, FItemSelected.FModelOffset.y, FItemSelected.FModelOffset.z);
      rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);
      ModelMat := rlGetMatrixTransform();
      SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
      DrawModel(FItemSelected.FModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
      DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, YELLOW);
    end
    else
    begin
      if FItemSelected.ShapeType = stSphere then
      begin
        var SelSphereScale: Single := Max(FItemSelected.Scale.x, Max(FItemSelected.Scale.y, FItemSelected.Scale.z)) * 0.5;
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        DrawModel(FSphereModel, Vector3Create(0, 0, 0), SelSphereScale, GetActorColor(FItemSelected));
        DrawSphereWires(Vector3Create(0, 0, 0), SelSphereScale, 16, 16, YELLOW);
      end
      else if FItemSelected.ShapeType = stBox then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
        DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, YELLOW);
      end
      else if FItemSelected.ShapeType = stCapsule then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);
        rlPushMatrix;
        rlTranslatef(0.0, -0.5, 0.0);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        DrawModel(FCapsuleModel, Vector3Create(0, -0.5, 0), 1.0, GetActorColor(FItemSelected));
        DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, YELLOW);
        rlPopMatrix;
      end
      else if FItemSelected.ShapeType = stPyramid then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);
        rlPushMatrix;
        rlTranslatef(0.0, -0.25, 0.0);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        rlPushMatrix;
        rlRotatef(45.0, 0.0, 1.0, 0.0);
        DrawCylinderWiresEx(Vector3Create(0, 1, 0), Vector3Create(0, 0, 0), 0.0, 0.5, 4, YELLOW);
        rlPopMatrix;
        DrawModel(FPyramidModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
        rlPopMatrix;
      end
      else if FItemSelected.ShapeType = stPrism then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);
        rlPushMatrix;
        rlTranslatef(0.0, -0.5, 0.0);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        DrawModel(FPrismModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
        rlPopMatrix;
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        rlPushMatrix;
        rlRotatef(90.0, 0.0, 1.0, 0.0);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 3, YELLOW);
        rlPopMatrix;
      end;
    end;

    EndShaderMode();
    rlPopMatrix();
  end;

  // --- GHOST PREVIEW ---
  if FIsBrushActive and FGhostVisible then
  begin
    rlPushMatrix;
    var SurfaceY: Single := FGhostPos.y;
    if (FBrushShape = stCapsule) or (FBrushShape = stPyramid) or (FBrushShape = stPrism) then
    begin
      if (FBrushShape = stPyramid) or (FBrushShape = stPrism) then
        SurfaceY := FGhostPos.y + (1.5 * 0.5)
      else
        SurfaceY := FGhostPos.y + (1.0 * 0.5);
    end
    else if FBrushShape = stModel then
    begin
      var GBBOX := GetModelBoundingBox(FCustomModel);
      var GMeshH: Single := GBBOX.max.y - GBBOX.min.y;
      var GMaxDim: Single := Max(GBBOX.max.x - GBBOX.min.x, Max(GMeshH, GBBOX.max.z - GBBOX.min.z));
      if GMaxDim <= 0 then GMaxDim := 1.0;
      var GUniformScale: Single := 1.0 / GMaxDim;
      SurfaceY := FGhostPos.y + ((GMeshH * GUniformScale) * 0.5) + 0.05;
    end;

    if FBrushShape = stBox then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      DrawCube(Vector3Create(0, 0.5, 0), 1, 1, 1, Fade(WHITE, 0.4));
      DrawCubeWires(Vector3Create(0, 0.5, 0), 1, 1, 1, YELLOW);
    end
    else if FBrushShape = stSphere then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      DrawSphere(Vector3Create(0, 0.5, 0), 0.5, Fade(WHITE, 0.4));
      DrawSphereWires(Vector3Create(0, 0.5, 0), 0.5, 16, 16, YELLOW);
    end
    else if FBrushShape = stCapsule then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      DrawCylinderEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, Fade(WHITE, 0.4));
      DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, YELLOW);
    end
    else if FBrushShape = stPyramid then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      rlRotatef(45.0, 0.0, 1.0, 0.0);
      DrawCylinderEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.0, 0.5, 4, Fade(WHITE, 0.4));
      DrawCylinderWiresEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.0, 0.5, 4, YELLOW);
    end
    else if FBrushShape = stPrism then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      rlRotatef(90.0, 0.0, 1.0, 0.0);
      DrawCylinderEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.5, 0.5, 3, Fade(WHITE, 0.4));
      DrawCylinderWiresEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.5, 0.5, 3, YELLOW);
    end
    else if FBrushShape = stModel then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      if FCustomModel.meshes <> nil then
      begin
        var GBBOX := GetModelBoundingBox(FCustomModel);
        var GMeshSize := Vector3Create(GBBOX.max.x - GBBOX.min.x, GBBOX.max.y - GBBOX.min.y, GBBOX.max.z - GBBOX.min.z);
        var GMaxDim: Single := Max(GMeshSize.x, Max(GMeshSize.y, GMeshSize.z));
        if GMaxDim <= 0 then GMaxDim := 1.0;
        var GUniformScale: Single := 1.0 / GMaxDim;
        var GCenterX := ((GBBOX.max.x + GBBOX.min.x) / 2) * GUniformScale;
        var GCenterZ := ((GBBOX.max.z + GBBOX.min.z) / 2) * GUniformScale;
        var GMeshH: Single := GMeshSize.y * GUniformScale;
        rlTranslatef(-GCenterX, -GMeshH * 0.5, -GCenterZ);
        var OldTransform: TMatrix := FCustomModel.transform;
        FCustomModel.transform := MatrixIdentity();
        DrawModel(FCustomModel, Vector3Create(0, 0, 0), 1.0, Fade(WHITE, 0.4));
        FCustomModel.transform := OldTransform;
      end;
      DrawCubeWires(Vector3Create(0, 0, 0), 1, 1, 1, YELLOW);
    end
    else if FBrushShape = stBomb then
    begin
      rlTranslatef(FGhostPos.x, FGhostPos.y + 0.5, FGhostPos.z);
      DrawSphere(Vector3Create(0, 0, 0), 0.5, Fade(RED, 0.5));
      DrawSphereWires(Vector3Create(0, 0, 0), 0.5, 16, 16, YELLOW);
    end;

    rlPopMatrix;
  end;

  if Assigned(FItemSelected) and not FIsBrushActive and (FGizmoMode <> gmNone) then
    DrawGizmo;

  // Draw projectiles
  for i := 0 to High(FProjectiles) do
  begin
    if FProjectiles[i] = nil then Continue;

    BeginShaderMode(FLightShader);
    rlPushMatrix;

    Pos := FProjectiles[i].Position;
    rlTranslatef(Pos.x, Pos.y + 0.3, Pos.z);

    var Quat := FProjectiles[i].Quaternion;
    Axis := Vector3Create(1, 1, 1);
    Angle := 0;
    if Quat.w < 1.0 then
      QuaternionToAxisAngle(Quat, @Axis, @Angle);
    rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

    rlScalef(0.3, 0.3, 0.3);

    ModelMat := rlGetMatrixTransform();
    SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

    DrawModel(FSphereModel, Vector3Create(0, 0, 0), 1.0, SKYBLUE);

    rlPopMatrix;
    EndShaderMode();
  end;

  dt := GetFrameTime();
  UpdateProjectiles(dt * FTimeScale);

  DrawSpawnEffects;

  EndMode3D();
=======
        end
        // ====================================================================
        // BOMB
        // ====================================================================
        else if Actor.ShapeType = stBomb then
        begin
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawModel(FSphereModel, Vector3Create(0, 0, 0), 0.5, GetActorColor(Actor));
        end
        // ====================================================================
        // CAPSULE / CYLINDER
        // ====================================================================
        else if Actor.ShapeType = stCapsule then
        begin
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);

          rlPushMatrix();

          // Shift down to align mesh bottom with physics bottom
          rlTranslatef(0.0, -0.5, 0.0);

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          // Offset Y position to lower mesh by half its height
          DrawModel(FCapsuleModel, Vector3Create(0, -0.5, 0), 1.0, GetActorColor(Actor));

          DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, BLACK);

          rlPopMatrix();
        end

        // ====================================================================
        // PYRAMID
        // ====================================================================
        else if Actor.ShapeType = stPyramid then
        begin
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);

          // Offset to align physics center of mass with visual mesh
          rlTranslatef(0.0, -0.25, 0.0);

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawModel(FPyramidModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(Actor));

          rlPushMatrix();
          rlRotatef(45.0, 0.0, 1.0, 0.0);
          DrawCylinderWiresEx(Vector3Create(0, 1, 0), Vector3Create(0, 0, 0), 0.0, 0.5, 4, BLACK);
          rlPopMatrix();
        end

        // ====================================================================
        // PRISM
        // ====================================================================
        else if Actor.ShapeType = stPrism then
        begin
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);

          rlPushMatrix();
          rlTranslatef(0.0, -0.5, 0.0);

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawModel(FPrismModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(Actor));
          rlPopMatrix();

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          // Rotate the wireframe on the Y axis to match the mesh
          rlPushMatrix();
          rlRotatef(90.0, 0.0, 1.0, 0.0);

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 3, BLACK);
          rlPopMatrix();
        end
        // ====================================================================
        // 3D BUTTON
        // ====================================================================
        else if Actor.ShapeType = stButton then
        begin
          // Button movement: Only move inward when pressed
          var BtnOffset: Single := 0.0;
          if Actor.IsPressed then
            BtnOffset := -0.03; // Move slightly inward on click

          // 1. Draw the outer frame (darker color)
          rlPushMatrix();
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          var FrameCol: TColorB;
          FrameCol.r := Max(0, Round(Actor.BaseColor.r * 0.5));
          FrameCol.g := Max(0, Round(Actor.BaseColor.g * 0.5));
          FrameCol.b := Max(0, Round(Actor.BaseColor.b * 0.5));
          FrameCol.a := 255;

          DrawCube(Vector3Create(0, 0, -0.1), 1.0, 1.0, 1.0, FrameCol);
          rlPopMatrix();

          rlPushMatrix();
          rlTranslatef(0, 0, BtnOffset);
          rlScalef(Actor.Scale.x * 0.85, Actor.Scale.y * 0.85, Actor.Scale.z);

          if Actor.FVideoTexture.id > 0 then
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FVideoTexture
          else if Actor.FButtonTexture.id > 0 then
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FButtonTexture
          else
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          rlEnableBackfaceCulling();

          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, Actor.ActColor);

          rlDisableBackfaceCulling();

          FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
          rlPopMatrix();
        end;

        EndShaderMode();
      end;

      EndShaderMode();
      rlPopMatrix();
    end;
  end;

  rlSetBlendMode(BLEND_ALPHA);

  // Selected Object
  if Assigned(FItemSelected) and FItemSelected.Visible then
  begin
    rlPushMatrix();

    // Translate to object position
    Pos := FItemSelected.Position;
    rlTranslatef(Pos.x, Pos.y, Pos.z);

    // Apply object rotation
    Axis := Vector3Create(1, 1, 1);
    Angle := 0;
    if FItemSelected.Quaternion.w < 1.0 then
      QuaternionToAxisAngle(FItemSelected.Quaternion, @Axis, @Angle);
    rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

    rlDrawRenderBatchActive();
    BeginShaderMode(FLightShader);

    // Fetch the model matrix and send it to the shader
    ModelMat := rlGetMatrixTransform();
    SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

    if FItemSelected.ShapeType = stModel then
    begin
      rlTranslatef(FItemSelected.FModelOffset.x, FItemSelected.FModelOffset.y, FItemSelected.FModelOffset.z);
      rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);

      // Update model matrix for the model offset
      ModelMat := rlGetMatrixTransform();
      SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

      DrawModel(FItemSelected.FModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
      DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, YELLOW);
    end
    else
    begin
      // Apply scale and fetch matrix per shape to ensure correct normal calculations
      if FItemSelected.ShapeType = stSphere then
      begin
        var SelSphereScale: Single := Max(FItemSelected.Scale.x, Max(FItemSelected.Scale.y, FItemSelected.Scale.z)) * 0.5;

        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

        DrawModel(FSphereModel, Vector3Create(0, 0, 0), SelSphereScale, GetActorColor(FItemSelected));
        DrawSphereWires(Vector3Create(0, 0, 0), SelSphereScale, 16, 16, YELLOW);
      end
      else if FItemSelected.ShapeType = stBox then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);

        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

        DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
        DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, YELLOW);
      end
      else if FItemSelected.ShapeType = stCapsule then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);

        rlPushMatrix();

        // Shift down to align mesh bottom with physics bottom
        rlTranslatef(0.0, -0.5, 0.0);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

        // Offset Y position to lower mesh by half its height
        DrawModel(FCapsuleModel, Vector3Create(0, -0.5, 0), 1.0, GetActorColor(FItemSelected));

        DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, YELLOW);

        rlPopMatrix();
      end
      else if FItemSelected.ShapeType = stPyramid then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);

        rlPushMatrix();

        // Offset to align physics center of mass with visual mesh
        rlTranslatef(0.0, -0.25, 0.0);
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        rlPushMatrix();
        rlRotatef(45.0, 0.0, 1.0, 0.0);
        DrawCylinderWiresEx(Vector3Create(0, 1, 0), Vector3Create(0, 0, 0), 0.0, 0.5, 4, YELLOW);
        rlPopMatrix();

        DrawModel(FPyramidModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));

        rlPopMatrix();
      end
      else if FItemSelected.ShapeType = stPrism then
      begin
        rlScalef(FItemSelected.Scale.x, FItemSelected.Scale.y, FItemSelected.Scale.z);

        rlPushMatrix();
        rlTranslatef(0.0, -0.5, 0.0);

      // Update ModelMat for the mesh offset
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

        DrawModel(FPrismModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(FItemSelected));
        rlPopMatrix();

      // Re-update ModelMat for the wireframe
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

      // Rotate the wireframe by 90 degrees on the Y axis to match the mesh
        rlPushMatrix();
        rlRotatef(90.0, 0.0, 1.0, 0.0);

      // Update ModelMat for the wireframe rotation
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

        DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 3, YELLOW);
        rlPopMatrix();
      end;
    end;

    EndShaderMode();
    rlPopMatrix();
  end;

  // --- GHOST PREVIEW ---
  if FIsBrushActive and FGhostVisible then
  begin
    rlPushMatrix();
    var SurfaceY: Single := FGhostPos.y;
    if (FBrushShape = stCapsule) or (FBrushShape = stPyramid) or (FBrushShape = stPrism) then
    begin
      if (FBrushShape = stPyramid) or (FBrushShape = stPrism) then
        SurfaceY := FGhostPos.y + (1.5 * 0.5)
      else
        SurfaceY := FGhostPos.y + (1.0 * 0.5);
    end
    else if FBrushShape = stModel then
    begin
      // Calculate exact Y-Offset for models based on their true bounding box height
      var GBBOX := GetModelBoundingBox(FCustomModel);
      var GMeshH: Single := GBBOX.max.y - GBBOX.min.y;
      var GMaxDim: Single := Max(GBBOX.max.x - GBBOX.min.x, Max(GMeshH, GBBOX.max.z - GBBOX.min.z));
      if GMaxDim <= 0 then
        GMaxDim := 1.0;
      var GUniformScale: Single := 1.0 / GMaxDim;

      // Half height of the model + half padding (0.05)
      SurfaceY := FGhostPos.y + ((GMeshH * GUniformScale) * 0.5) + 0.05;
    end;

    if FBrushShape = stBox then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      DrawCube(Vector3Create(0, 0.5, 0), 1, 1, 1, Fade(WHITE, 0.4));
      DrawCubeWires(Vector3Create(0, 0.5, 0), 1, 1, 1, YELLOW);
    end
    else if FBrushShape = stSphere then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      DrawSphere(Vector3Create(0, 0.5, 0), 0.5, Fade(WHITE, 0.4));
      DrawSphereWires(Vector3Create(0, 0.5, 0), 0.5, 16, 16, YELLOW);
    end
    else if FBrushShape = stCapsule then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      DrawCylinderEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, Fade(WHITE, 0.4));
      DrawCylinderWiresEx(Vector3Create(0, 0.5, 0), Vector3Create(0, -0.5, 0), 0.5, 0.5, 24, YELLOW);
    end
    else if FBrushShape = stPyramid then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      // Rotate 45 degrees so a flat face points forward, matching the spawned mesh!
      rlRotatef(45.0, 0.0, 1.0, 0.0);
      DrawCylinderEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.0, 0.5, 4, Fade(WHITE, 0.4));
      DrawCylinderWiresEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.0, 0.5, 4, YELLOW);
    end
    else if FBrushShape = stPrism then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      // Rotate 90 degrees for a 3-sided prism so it matches the spawned visual mesh
      rlRotatef(90.0, 0.0, 1.0, 0.0);
      DrawCylinderEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.5, 0.5, 3, Fade(WHITE, 0.4));
      DrawCylinderWiresEx(Vector3Create(0, 0.75, 0), Vector3Create(0, -0.75, 0), 0.5, 0.5, 3, YELLOW);
    end
    else if FBrushShape = stModel then
    begin
      rlTranslatef(FGhostPos.x, SurfaceY, FGhostPos.z);
      if FCustomModel.meshes <> nil then
      begin
        var GBBOX := GetModelBoundingBox(FCustomModel);
        var GMeshSize := Vector3Create(GBBOX.max.x - GBBOX.min.x, GBBOX.max.y - GBBOX.min.y, GBBOX.max.z - GBBOX.min.z);
        var GMaxDim: Single := Max(GMeshSize.x, Max(GMeshSize.y, GMeshSize.z));
        if GMaxDim <= 0 then
          GMaxDim := 1.0;
        var GUniformScale: Single := 1.0 / GMaxDim;

        // Calculate the center of the scaled mesh
        var GCenterX := ((GBBOX.max.x + GBBOX.min.x) / 2) * GUniformScale;
        var GCenterZ := ((GBBOX.max.z + GBBOX.min.z) / 2) * GUniformScale;
        var GMeshH: Single := GMeshSize.y * GUniformScale;

        rlTranslatef(-GCenterX, -GMeshH * 0.5, -GCenterZ);

        // CRITICAL: Temporarily reset the model's transform to identity (1.0 scale)
        // because the vertices are ALREADY scaled, and DrawModel would scale them again!
        var OldTransform: TMatrix := FCustomModel.transform;
        FCustomModel.transform := MatrixIdentity();
        DrawModel(FCustomModel, Vector3Create(0, 0, 0), 1.0, Fade(WHITE, 0.4));
        // Restore the original transform so we don't break the model for the actual spawn
        FCustomModel.transform := OldTransform;
      end;
      DrawCubeWires(Vector3Create(0, 0, 0), 1, 1, 1, YELLOW);
    end
    else if FBrushShape = stBomb then
    begin
      rlTranslatef(FGhostPos.x, FGhostPos.y + 0.5, FGhostPos.z);
      DrawSphere(Vector3Create(0, 0, 0), 0.5, Fade(RED, 0.5));
      DrawSphereWires(Vector3Create(0, 0, 0), 0.5, 16, 16, YELLOW);
    end;

    rlPopMatrix();
  end;

  if Assigned(FItemSelected) and not FIsBrushActive and (FGizmoMode <> gmNone) then
    DrawGizmo;

  // Draw projectiles
  for i := 0 to High(FProjectiles) do
  begin
    if FProjectiles[i] = nil then
      Continue;

    BeginShaderMode(FLightShader);

    rlPushMatrix();

    // Translate to the projectile's position with a small Y offset
    Pos := FProjectiles[i].Position;
    rlTranslatef(Pos.x, Pos.y + 0.3, Pos.z);

    // Apply the projectile's rotation for visual rolling
    var Quat := FProjectiles[i].Quaternion;
    Axis := Vector3Create(1, 1, 1);
    Angle := 0;
    if Quat.w < 1.0 then
      QuaternionToAxisAngle(Quat, @Axis, @Angle);
    rlRotatef(Angle * RAD2DEG, Axis.x, Axis.y, Axis.z);

    // Scale down to a small cannonball
    rlScalef(0.3, 0.3, 0.3);

    // Fetch the combined matrix and send it to the shader
    ModelMat := rlGetMatrixTransform();
    SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

    // Draw the projectile sphere at local origin
    DrawModel(FSphereModel, Vector3Create(0, 0, 0), 1.0, SKYBLUE);

    rlPopMatrix();
    EndShaderMode();
  end;

  dt := GetFrameTime();
  // Pass scaled time to projectiles so their lifespan checks sync with slow motion
  UpdateProjectiles(dt * FTimeScale);

  DrawSpawnEffects;

  EndMode3D();
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
end;

procedure TRaylibSandbox.DrawGizmo;
var
  Pos: TVector3;
  ScaleX, ScaleY, ScaleZ: Single;
  ColX, ColY, ColZ: TColorB;
  AxisX, AxisY, AxisZ: TVector3;
  EndX, EndY, EndZ: TVector3;
  NegEndX, NegEndY, NegEndZ: TVector3;
  TipX, TipY, TipZ: TVector3;
  NegTipX, NegTipY, NegTipZ: TVector3;
  ArrowRadius, HandleSize: Single;
  BBox: TBoundingBox;
  PhysRadius: Single;
begin
  Pos := FItemSelected.Position;

  // Default gizmo length for primitives
  ScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 1.0, 1.0, 100.0);
  ScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 1.0, 1.0, 100.0);
  ScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 1.0, 1.0, 100.0);

  // FOR MODELS: Calculate the actual physical radius so the gizmo arms reach outside the mesh!
  if FItemSelected.ShapeType = stModel then
  begin
    BBox := GetModelBoundingBox(FItemSelected.FModel);

    // Calculate how big the model is after applying the model's internal transform and the Actor's scale
    PhysRadius := Max(BBox.max.x - BBox.min.x, Max(BBox.max.y - BBox.min.y, BBox.max.z - BBox.min.z)) * Max(FItemSelected.Scale.x, Max(FItemSelected.Scale.y, FItemSelected.Scale.z)) * 0.5;

    // Make the gizmo arms slightly larger than the object's physical radius
    ScaleX := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
    ScaleY := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
    ScaleZ := EnsureRange(PhysRadius + 1.5, 1.5, 150.0);
  end;

  ArrowRadius := 0.08;
  HandleSize := ArrowRadius * 2.5;
  ColX := RED;
  ColY := GREEN;
  ColZ := BLUE;

  if FGizmoDragging then
  begin
    if FGizmoAxis = 1 then
      ColX := YELLOW
    else if FGizmoAxis = 2 then
      ColY := YELLOW
    else if FGizmoAxis = 3 then
      ColZ := YELLOW;
  end
  else if FGizmoHoverAxis > 0 then
  begin
    if FGizmoHoverAxis = 1 then
      ColX := YELLOW
    else if FGizmoHoverAxis = 2 then
      ColY := YELLOW
    else if FGizmoHoverAxis = 3 then
      ColZ := YELLOW;
  end;

  AxisX := Vector3RotateByQuaternion(Vector3Create(1, 0, 0), FItemSelected.Quaternion);
  AxisY := Vector3RotateByQuaternion(Vector3Create(0, 1, 0), FItemSelected.Quaternion);
  AxisZ := Vector3RotateByQuaternion(Vector3Create(0, 0, 1), FItemSelected.Quaternion);

  EndX := Vector3Add(Pos, Vector3Scale(AxisX, ScaleX));
  EndY := Vector3Add(Pos, Vector3Scale(AxisY, ScaleY));
  EndZ := Vector3Add(Pos, Vector3Scale(AxisZ, ScaleZ));
  NegEndX := Vector3Subtract(Pos, Vector3Scale(AxisX, ScaleX));
  NegEndY := Vector3Subtract(Pos, Vector3Scale(AxisY, ScaleY));
  NegEndZ := Vector3Subtract(Pos, Vector3Scale(AxisZ, ScaleZ));

  TipX := Vector3Add(Pos, Vector3Scale(AxisX, ScaleX + (ArrowRadius * 3)));
  TipY := Vector3Add(Pos, Vector3Scale(AxisY, ScaleY + (ArrowRadius * 3)));
  TipZ := Vector3Add(Pos, Vector3Scale(AxisZ, ScaleZ + (ArrowRadius * 3)));
  NegTipX := Vector3Subtract(Pos, Vector3Scale(AxisX, ScaleX + (ArrowRadius * 3)));
  NegTipY := Vector3Subtract(Pos, Vector3Scale(AxisY, ScaleY + (ArrowRadius * 3)));
  NegTipZ := Vector3Subtract(Pos, Vector3Scale(AxisZ, ScaleZ + (ArrowRadius * 3)));

  if FGizmoMode = gmTranslate then
  begin
    DrawCylinderEx(Pos, EndX, ArrowRadius, ArrowRadius, 8, ColX);
    DrawCylinderEx(Pos, NegEndX, ArrowRadius, ArrowRadius, 8, ColX);
    DrawCylinderEx(Pos, EndY, ArrowRadius, ArrowRadius, 8, ColY);
    DrawCylinderEx(Pos, NegEndY, ArrowRadius, ArrowRadius, 8, ColY);
    DrawCylinderEx(Pos, EndZ, ArrowRadius, ArrowRadius, 8, ColZ);
    DrawCylinderEx(Pos, NegEndZ, ArrowRadius, ArrowRadius, 8, ColZ);
    DrawCylinderEx(EndX, TipX, ArrowRadius * 2, 0.0, 8, ColX);
    DrawCylinderEx(NegEndX, NegTipX, ArrowRadius * 2, 0.0, 8, ColX);
    DrawCylinderEx(EndY, TipY, ArrowRadius * 2, 0.0, 8, ColY);
    DrawCylinderEx(NegEndY, NegTipY, ArrowRadius * 2, 0.0, 8, ColY);
    DrawCylinderEx(EndZ, TipZ, ArrowRadius * 2, 0.0, 8, ColZ);
    DrawCylinderEx(NegEndZ, NegTipZ, ArrowRadius * 2, 0.0, 8, ColZ);
  end
  else if FGizmoMode = gmRotate then
  begin
    DrawThickRingAt(Pos, AxisX, ScaleX, ArrowRadius * 0.8, ColX);
    DrawThickRingAt(Pos, AxisY, ScaleY, ArrowRadius * 0.8, ColY);
    DrawThickRingAt(Pos, AxisZ, ScaleZ, ArrowRadius * 0.8, ColZ);
  end
  else if FGizmoMode = gmScale then
  begin
    DrawCylinderEx(Pos, EndX, ArrowRadius, ArrowRadius, 8, ColX);
    DrawCylinderEx(Pos, NegEndX, ArrowRadius, ArrowRadius, 8, ColX);
    DrawCylinderEx(Pos, EndY, ArrowRadius, ArrowRadius, 8, ColY);
    DrawCylinderEx(Pos, NegEndY, ArrowRadius, ArrowRadius, 8, ColY);
    DrawCylinderEx(Pos, EndZ, ArrowRadius, ArrowRadius, 8, ColZ);
    DrawCylinderEx(Pos, NegEndZ, ArrowRadius, ArrowRadius, 8, ColZ);
    DrawCube(EndX, HandleSize, HandleSize, HandleSize, ColX);
    DrawCube(NegEndX, HandleSize, HandleSize, HandleSize, ColX);
    DrawCube(EndY, HandleSize, HandleSize, HandleSize, ColY);
    DrawCube(NegEndY, HandleSize, HandleSize, HandleSize, ColY);
    DrawCube(EndZ, HandleSize, HandleSize, HandleSize, ColZ);
    DrawCube(NegEndZ, HandleSize, HandleSize, HandleSize, ColZ);
    DrawCube(Pos, HandleSize, HandleSize, HandleSize, WHITE);
  end;
end;

procedure TRaylibSandbox.DrawThickRingAt(Center, NormalAxis: TVector3; Radius, Thickness: Single; Color: TColorB);
var
  I: Integer;
  Segments: Integer;
  Angle: Single;
  LocalV, V1, V2: TVector3;
  OrthoAxis: TVector3;
begin
  Segments := 32;
  if Abs(NormalAxis.y) < 0.9 then
    OrthoAxis := Vector3Normalize(Vector3CrossProduct(NormalAxis, Vector3Create(0, 1, 0)))
  else
    OrthoAxis := Vector3Normalize(Vector3CrossProduct(NormalAxis, Vector3Create(1, 0, 0)));
  for I := 0 to Segments - 1 do
  begin
    Angle := (I / Segments) * 2.0 * PI;
    LocalV := Vector3Add(Vector3Scale(OrthoAxis, Cos(Angle) * Radius), Vector3Scale(Vector3CrossProduct(NormalAxis, OrthoAxis), Sin(Angle) * Radius));
    V1 := Vector3Add(Center, LocalV);
    Angle := ((I + 1) / Segments) * 2.0 * PI;
    LocalV := Vector3Add(Vector3Scale(OrthoAxis, Cos(Angle) * Radius), Vector3Scale(Vector3CrossProduct(NormalAxis, OrthoAxis), Sin(Angle) * Radius));
    V2 := Vector3Add(Center, LocalV);
    DrawCylinderEx(V1, V2, Thickness, Thickness, 6, Color);
  end;
end;

procedure TRaylibSandbox.DrawNativePopup;
var
  I: Integer;
  Rect: TRectangle;
  BgColor, BorderColor, TextColor: TColorB;
  IconRect: TRectangle;
begin
  if not FPopupOpen then
    Exit;
  DrawRectangleRec(RectangleCreate(FPopupPos.x, FPopupPos.y, 174, 38), Fade(BLACK, 0.9));
  DrawRectangleLinesEx(RectangleCreate(FPopupPos.x, FPopupPos.y, 174, 38), 2, GRAY);
  for I := 0 to 4 do
  begin
    IconRect.x := FPopupPos.x + 4 + (I * 34);
    IconRect.y := FPopupPos.y + 4;
    IconRect.width := 30;
    IconRect.height := 30;
    if FPopupHoverIndex = I then
    begin
      DrawRectangleRec(IconRect, Fade(SKYBLUE, 0.8));
      DrawRectangleLinesEx(IconRect, 1, YELLOW);
    end
    else
    begin
      DrawRectangleRec(IconRect, BLACK);
      DrawRectangleLinesEx(IconRect, 1, RAYWHITE);
    end;
    if I = 0 then
      DrawRectangle(Round(IconRect.x + 8), Round(IconRect.y + 8), 14, 14, RED)
    else if I = 1 then
      DrawCircle(Round(IconRect.x + 15), Round(IconRect.y + 15), 7, PURPLE)
    else if I = 2 then
    begin
      DrawRectangle(Round(IconRect.x + 11), Round(IconRect.y + 6), 8, 18, GREEN);
      DrawCircle(Round(IconRect.x + 15), Round(IconRect.y + 6), 4, GREEN);
      DrawCircle(Round(IconRect.x + 15), Round(IconRect.y + 24), 4, GREEN);
    end
    else if I = 3 then
    begin
      DrawRectangle(Round(IconRect.x + 5), Round(IconRect.y + 5), 20, 20, ORANGE);
      DrawLine(Round(IconRect.x + 5), Round(IconRect.y + 5), Round(IconRect.x + 25), Round(IconRect.y + 25), BLACK);
      DrawLine(Round(IconRect.x + 25), Round(IconRect.y + 5), Round(IconRect.x + 5), Round(IconRect.y + 25), BLACK);
    end
    else if I = 4 then
    begin
      DrawTriangle(Vector2Create(IconRect.x + 5, IconRect.y + 25), Vector2Create(IconRect.x + 25, IconRect.y + 25), Vector2Create(IconRect.x + 15, IconRect.y + 5), COL_PRISM);
    end;
  end;
  for I := 0 to High(FPopupSegments) do
  begin
    Rect.x := FPopupPos.x;
    Rect.y := FPopupPos.y + 45 + (I * 40);
    Rect.width := 150;
    Rect.height := 38;
    if (FPopupHoverIndex - 100) = I then
    begin
      BgColor := Fade(BLUE, 0.8);
      BorderColor := SKYBLUE;
      TextColor := WHITE;
    end
    else
    begin
      BgColor := Fade(BLACK, 0.8);
      BorderColor := GRAY;
      TextColor := RAYWHITE;
    end;
    DrawRectangleRec(Rect, BgColor);
    DrawRectangleLinesEx(Rect, 2, BorderColor);
    DrawText(PAnsiChar(AnsiString(FPopupSegments[I])), Round(Rect.x + 15), Round(Rect.y + 10), 20, TextColor);
  end;
end;

procedure TRaylibSandbox.DrawGUI;
var
  fpsBuf: AnsiString;
  YOffset: Integer;
  ModeStr: AnsiString;
  IconRect: TRectangle;
  I: Integer;
begin
  YOffset := Trunc(FHUDAnimY);
  DrawRectangle(10, 10 + YOffset, 214, 50, Fade(BLACK, 0.8));
  DrawRectangleLines(10, 10 + YOffset, 214, 50, RAYWHITE);
  for I := 0 to 4 do
  begin
    IconRect.x := 15 + (I * 40);
    IconRect.y := 15 + YOffset;
    IconRect.width := 30;
    IconRect.height := 30;
    DrawRectangleLines(Round(IconRect.x), Round(IconRect.y), 30, 30, RAYWHITE);
    if I = 0 then
      DrawRectangle(Round(IconRect.x + 8), Round(IconRect.y + 8), 14, 14, Fade(BLUE, 0.8))
    else if I = 1 then
      DrawCircle(Round(IconRect.x + 15), Round(IconRect.y + 15), 10, Fade(GREEN, 0.8))
    else if I = 2 then
    begin
      DrawRectangle(Round(IconRect.x + 11), Round(IconRect.y + 6), 8, 18, Fade(GREEN, 0.8));
      DrawCircle(Round(IconRect.x + 15), Round(IconRect.y + 6), 4, Fade(GREEN, 0.8));
      DrawCircle(Round(IconRect.x + 15), Round(IconRect.y + 24), 4, Fade(GREEN, 0.8));
    end
    else if I = 3 then
    begin
      DrawRectangle(Round(IconRect.x + 5), Round(IconRect.y + 5), 20, 20, Fade(PURPLE, 0.8));
      DrawLine(Round(IconRect.x + 5), Round(IconRect.y + 5), Round(IconRect.x + 25), Round(IconRect.y + 25), RAYWHITE);
      DrawLine(Round(IconRect.x + 25), Round(IconRect.y + 5), Round(IconRect.x + 5), Round(IconRect.y + 25), RAYWHITE);
    end
    else if I = 4 then
    begin
      DrawTriangle(Vector2Create(IconRect.x + 5, IconRect.y + 25), Vector2Create(IconRect.x + 25, IconRect.y + 25), Vector2Create(IconRect.x + 15, IconRect.y + 5), Fade(COL_PRISM, 0.8));
    end;
  end;
  fpsBuf := AnsiString(Format('FPS: %d', [GetFPS()]));
  DrawText(PAnsiChar(fpsBuf), 10, GetScreenHeight() - 30, 20, GREEN);
  if FSimulationRunning then
    DrawText('SIMULATION RUNNING', 10, GetScreenHeight() - 60, 20, GREEN)
  else
    DrawText('SIMULATION PAUSED', 10, GetScreenHeight() - 60, 20, YELLOW);
  case FGizmoMode of
    gmTranslate:
      ModeStr := 'Mode: Translate (Move)';
    gmRotate:
      ModeStr := 'Mode: Rotate (Turn)';
    gmScale:
      ModeStr := 'Mode: Scale (Resize)';
    gmDragAndThrow:
      ModeStr := 'Mode: Drag & Throw';
  else
    ModeStr := 'Mode: None (UI Interaction)';
  end;
  DrawText(PAnsiChar(ModeStr), 10, GetScreenHeight() - 90, 20, RAYWHITE);
end;

procedure TRaylibSandbox.DoViewportReady;
begin
  if Assigned(FOnViewportReady) then
    TThread.Queue(nil,
      procedure
      begin
        FOnViewportReady(Self);
      end);
end;

procedure TRaylibSandbox.DoActorSpawned(Actor: TA3DComponent; Index: Integer);
var
  Args: TActorEventArgs;
begin
  if Assigned(FOnActorSpawned) then
  begin
    Args.Actor := Actor;
    Args.Index := Index;
    TThread.Queue(nil,
      procedure
      begin
        FOnActorSpawned(Self, Args);
      end);
  end;
end;

procedure TRaylibSandbox.DoActorDestroyed(Actor: TA3DComponent; Index: Integer);
var
  Args: TActorEventArgs;
begin
  if Assigned(FOnActorDestroyed) then
  begin
    Args.Actor := Actor;
    Args.Index := Index;
    TThread.Queue(nil,
      procedure
      begin
        FOnActorDestroyed(Self, Args);
      end);
  end;
end;

procedure TRaylibSandbox.DoSceneCleared;
begin
  if Assigned(FOnSceneCleared) then
    TThread.Queue(nil,
      procedure
      begin
        FOnSceneCleared(Self);
      end);
end;

procedure TRaylibSandbox.DoEngineException(const Msg, Context: string);
var
  Args: TEngineExceptionEventArgs;
begin
  if Assigned(FOnEngineException) then
  begin
    Args.Message := Msg;
    Args.Context := Context;
    Args.Timestamp := Now;
    TThread.Queue(nil,
      procedure
      begin
        FOnEngineException(Self, Args);
      end);
  end
  else
    OutputDebugString(PChar('[' + Context + '] ' + Msg));
end;

procedure TRaylibSandbox.DoObjectSelected(Actor: TA3DComponent);
begin
  if Assigned(FOnObjectSelected) then
  begin
    TThread.Queue(nil,
      procedure
      begin
        FOnObjectSelected(Self, Actor);
      end);
  end;
end;
// ============================================================================
// NAVIGATION LOGIC
// Uses an internal absolute counter to cycle strictly through the FItems array.
// ============================================================================

procedure TRaylibSandbox.SelectNextObject;
var
  i: Integer;
  Actor: TA3DComponent;
begin
  // Abort if the scene is empty
  if Length(FItems) = 0 then
    Exit;

  // Strictly increment the internal navigation index and wrap around
  FNavIndex := FNavIndex + 1;
  if FNavIndex >= Length(FItems) then
    FNavIndex := 0;

  Actor := FItems[FNavIndex];
  if Assigned(Actor) then
  begin
    // Clear previous glow states
    for i := 0 to High(FItems) do
      if Assigned(FItems[i]) then
        FItems[i].CollisionHighlighting := False;

    // Apply new selection state
    Actor.CollisionHighlighting := True;
    FItemSelected := Actor; // Update engine state

    // Notify the VCL Form to update TreeView and Inspector
    DoObjectSelected(Actor);
  end;
end;

procedure TRaylibSandbox.SelectPrevObject;
var
  i: Integer;
  Actor: TA3DComponent;
begin
  // Abort if the scene is empty
  if Length(FItems) = 0 then
    Exit;

  // Strictly decrement the internal navigation index and wrap around
  FNavIndex := FNavIndex - 1;
  if FNavIndex < 0 then
    FNavIndex := High(FItems);

  Actor := FItems[FNavIndex];
  if Assigned(Actor) then
  begin
    // Clear previous glow states
    for i := 0 to High(FItems) do
      if Assigned(FItems[i]) then
        FItems[i].CollisionHighlighting := False;

    // Apply new selection state
    Actor.CollisionHighlighting := True;
    FItemSelected := Actor; // Update engine state

    // Notify the VCL Form to update TreeView and Inspector
    DoObjectSelected(Actor);
  end;
end;

procedure TRaylibSandbox.ProcessCustomSpawnQueue(dt: Single);
var
  Req: TSpawnRequest;
  oldLen: Integer;
  i: Integer;
  Data: PItemData;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  Obj: TA3DComponent;
  BombReq: TSpawnRequest;
  IsKey: Boolean;
begin
  if Length(FCustomSpawnQueue) = 0 then
    Exit;

  if FCustomSpawnTimer > 0 then
  begin
    FCustomSpawnTimer := FCustomSpawnTimer - dt;
    Exit;
  end;

  FLock.Enter;
  try
    Req := FCustomSpawnQueue[0];
    if Length(FCustomSpawnQueue) > 1 then
    begin
      for i := 0 to High(FCustomSpawnQueue) - 1 do
        FCustomSpawnQueue[i] := FCustomSpawnQueue[i + 1];
    end;
    SetLength(FCustomSpawnQueue, Length(FCustomSpawnQueue) - 1);
  finally
    FLock.Leave;
  end;

<<<<<<< HEAD
  FCustomSpawnTimer := 0.05;

  if Req.Name = 'BOMB_TRIGGER' then
  begin
    Req.Name := 'WallBlock_Final';

=======
  // Faster spawn rate (0.05s) so the wall finishes before the bomb goes off!
  FCustomSpawnTimer := 0.05;

  // Check if this is the special Bomb Trigger
  if Req.Name = 'BOMB_TRIGGER' then
  begin
    // Spawn the last wall block first
    Req.Name := 'WallBlock_Final';
    // (We just let it fall through to the normal spawn code below for the last brick)

    // Now queue the actual bomb behind the wall
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
    BombReq.Shape := stSphere;
    BombReq.Size := Vector3Create(1, 1, 1);
    BombReq.IsStatic := False;
    BombReq.Color := RED;
    BombReq.Pos := Vector3Create(0, 2.0, -4.0);
    BombReq.Name := 'THE_BOMB';

<<<<<<< HEAD
=======
    // Insert bomb at the front of the queue so it spawns immediately after the last brick
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
    FLock.Enter;
    try
      SetLength(FCustomSpawnQueue, Length(FCustomSpawnQueue) + 1);
      for i := High(FCustomSpawnQueue) downto 1 do
        FCustomSpawnQueue[i] := FCustomSpawnQueue[i - 1];
      FCustomSpawnQueue[0] := BombReq;
    finally
      FLock.Leave;
    end;
  end;

  oldLen := Length(FItems);
  SetLength(FItems, oldLen + 1);

  New(Data);
  FillChar(Data^, SizeOf(TItemData), 0);
  Data^.SpawnTime := GetTime();
  Data^.IsProjectile := False;
  Data^.Name := Req.Name;

  IsKey := (Pos('Key_White_', Req.Name) = 1) or (Pos('Key_Black_', Req.Name) = 1);

  JPos.x := Req.Pos.x;
  JPos.y := Req.Pos.y;
  JPos.z := Req.Pos.z;
  JRot.x := 0;
  JRot.y := 0;
  JRot.z := 0;
  JRot.w := 1;
<<<<<<< HEAD

  // NOW WE PASS Req.IsStatic DIRECTLY! IF IT IS A KEY, IT IS STATIC FROM THE START!
=======

>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
  Obj := TA3DComponent.Create('', FEngine, Req.Shape, Req.Size, Req.IsStatic, Req.IsDestructable, @JPos, @JRot);
  Obj.Name := Req.Name;
  Obj.Friction := 0.6;
  Obj.Restitution := 0.1;

  if IsKey then
  begin
    Obj.IsPianoKey := True;
    try
      Obj.MidiNote := StrToInt(Copy(Req.Name, 11, Length(Req.Name) - 10));
    except
      Obj.MidiNote := 60;
    end;
  end;

  Obj.UserData := Data;
  Obj.Visible := True;

  if Req.Shape = stButton then
  begin
    Obj.Caption := Req.Caption;
    Obj.BaseColor := Req.BaseColor;
    Obj.HoverColor := Req.HoverColor;
    Obj.OnClick := Req.OnClick;

    var TxtSize: Integer := Round(Req.Size.x * 20.0);
    if TxtSize < 10 then
      TxtSize := 10;

    if Req.Caption <> '' then
      Obj.FButtonTexture := DrawTextToTexture(Req.Caption, TxtSize, BLACK, Req.BaseColor);
  end;

  Obj.TargetColor := Req.Color;
  Obj.ActColor := Req.Color;
<<<<<<< HEAD

  // Force position just in case, though it shouldn't be needed anymore
  Obj.SetPosition(Vector3Create(JPos.x, JPos.y, JPos.z));

=======

  // If it's the bomb, set up the explosion timer
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
  if Req.Name = 'THE_BOMB' then
  begin
    FBombActor := Obj;
    FBombTimer := 2.0;
    FBombExploded := False;
  end
<<<<<<< HEAD
  else if Req.GenerateTestTexture then
  begin
    if (Req.Name = 'Screen_1') then
    begin
=======
  else
  // If requested, generate a unique test texture safely within the Raylib thread
    if Req.GenerateTestTexture then
  begin
    if (Req.Name = 'Screen_1') then
    begin
      // Initialize MPV Player on the fly when Screen 1 is spawned
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
      if not Assigned(FMPVPlayer) then
      begin
        try
          FMPVPlayer := TMPVPlayer.Create(640, 360);
<<<<<<< HEAD
          FMPVPlayer.LoadFile(ExtractFilePath(ParamStr(0)) + 'ressources\video\test.mp4');
=======

          FMPVPlayer.LoadFile(ExtractFilePath(ParamStr(0)) + 'ressources\video\test.mp4');
          //FMPVPlayer.LoadFile( 'D:\test2.mp4');
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
        except
          on E: Exception do
          begin
            DoEngineException(E.Message, 'MPVInit');
            FMPVPlayer := nil;
          end;
        end;
      end;

      if Assigned(FMPVPlayer) then
        Obj.FVideoTexture := FMPVPlayer.Target.texture
      else
<<<<<<< HEAD
=======
        // Fallback if MPV failed to load
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
        Obj.FVideoTexture := LoadTextureFromImage(GenImageColor(640, 360, RED));
    end;
  end;

  // Register Piano Keys to the standalone component
  if Assigned(FPiano) and Obj.IsPianoKey then
  begin
    SetLength(FPiano.FKeys, Length(FPiano.FKeys) + 1);
    FPiano.FKeys[High(FPiano.FKeys)] := Obj;
  end;

  FItems[oldLen] := Obj;
  DoActorSpawned(Obj, oldLen);
end;

procedure TRaylibSandbox.UpdateBomb(dt: Single);
begin
  if not Assigned(FBombActor) or FBombExploded then
    Exit;

  FBombTimer := FBombTimer - dt;

  // Flashing effect: Blink faster as time runs out
  if FBombTimer < 0.5 then
  begin
    if Trunc(FBombTimer * 20) mod 2 = 0 then
      FBombActor.ActColor := RED
    else
      FBombActor.ActColor := WHITE;
  end;

  if FBombTimer <= 0 then
  begin
    ExplodeBomb;
  end;
end;

procedure TRaylibSandbox.ExplodeBomb;
var
  i: Integer;
  Actor: TA3DComponent;
  Dist: Single;
  Dir: TVector3;
  ForceMag: Single;
  BombIdx: Integer;
begin
  if not Assigned(FBombActor) then
    Exit;
  FBombExploded := True;
  PlayImpactSound;
  // Loop through all items and apply massive explosion force
  for i := 0 to High(FItems) do
  begin
    Actor := FItems[i];
    if Assigned(Actor) and (Actor <> FBombActor) and not Actor.FIsDead then
    begin
      // Only affect dynamic objects (our wall blocks)
      if not Actor.IsStatic then
      begin
        Dist := Vector3Distance(Actor.Position, FBombActor.Position);
        // Affect blocks within a 25 unit radius
        if Dist < 25.0 then
        begin
          Dir := Vector3Subtract(Actor.Position, FBombActor.Position);
          if Vector3Length(Dir) > 0.001 then
            Dir := Vector3Normalize(Dir)
          else
            Dir := Vector3Create(0, 1, 0); // Fallback if exactly inside
          // Force is stronger closer to the bomb (Massive magnitude!)
          ForceMag := (25.0 - Dist) * 5000.0;
          // CRITICAL: Wake up the body from Sleep Mode before applying force!
          Actor.ActivateBody;
          // Apply the explosive impulse
          Actor.ApplyImpulse(Vector3Scale(Dir, ForceMag));
          // Add a strong upward kick for dramatic effect
          Actor.ApplyImpulse(Vector3Create(0, ForceMag * 0.3, 0));
        end;
      end;
    end;
  end;
  // ====================================================================
  // HARD DELETE BOMB
  // ====================================================================
  // 1. Find the bomb's index in the FItems array
  BombIdx := -1;
  for i := 0 to High(FItems) do
  begin
    if FItems[i] = FBombActor then
    begin
      BombIdx := i;
      Break;
    end;
  end;
  // 2. If found, remove from Physics Engine and memory
  if BombIdx >= 0 then
  begin
    // Notify the VCL Form to remove the node from the TreeView!
    DoActorDestroyed(FBombActor, BombIdx);
    // Remove and destroy from Jolt Physics
    if FBombActor.FBodyID <> 0 then
    begin
      JPH_BodyInterface_RemoveAndDestroyBody(FEngine.BodyInterface, FBombActor.FBodyID);
      FBombActor.FBodyID := 0;
    end;
    // Free UserData if it exists
    if FBombActor.UserData <> nil then
      Dispose(PItemData(FBombActor.UserData));
    // Free the class instance
    FBombActor.Visible := False;
    FBombActor.Free;
    // Close the gap in the array
    for i := BombIdx to High(FItems) - 1 do
      FItems[i] := FItems[i + 1];
    // Resize array
    SetLength(FItems, Length(FItems) - 1);
  end;
  // Clear the reference
  FBombActor := nil;
<<<<<<< HEAD
end;
=======
end;
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
// External accessor to toggle slow motion from VCL/UI

procedure TRaylibSandbox.SetSlowMotion(Active: Boolean);
begin
  FSlowMotionActive := Active;
end;

procedure TRaylibSandbox.ClearDynamicItemsOnly;
begin
  FLock.Enter;
  try
    FGizmoMode := gmNone;
    FDragging := False;
    FItemSelected := nil;
    FSpawnQueue := 0;
    // Stop and free MPV player when the scene is cleared!
    if Assigned(FMPVPlayer) then
<<<<<<< HEAD
      FreeAndNil(FMPVPlayer);
    // Free independent Piano Component
    FreeAndNil(FPiano);
=======
      FreeAndNil(FMPVPlayer);
>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
    // Only clear dynamic items, keep FFloorActor and Engine alive!
    var i: Integer;
    for i := High(FItems) downto 0 do
    begin
      if Assigned(FItems[i]) then
      begin
        if FItems[i].FButtonTexture.id > 0 then
          UnloadTexture(FItems[i].FButtonTexture);
        if (FItems[i].FVideoTexture.id > 0) and (not Assigned(FMPVPlayer) or (FItems[i].FVideoTexture.id <> FMPVPlayer.Target.texture.id)) then
          UnloadTexture(FItems[i].FVideoTexture);
        FItems[i].Visible := False;
        FItems[i].Free;
        FItems[i] := nil;
      end;
    end;
    for i := High(FProjectiles) downto 0 do
    begin
      if Assigned(FProjectiles[i]) then
      begin
        if FProjectiles[i].UserData <> nil then
          Dispose(PItemData(FProjectiles[i].UserData));
        FProjectiles[i].Free;
        FProjectiles[i] := nil;
      end;
    end;
    SetLength(FProjectiles, 0);
    SetLength(FItems, 0);
    FBombActor := nil;
    FBombExploded := False;
    FActiveSpawnEffects := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.ReattachLoadedActor(Actor: TA3DComponent);
var
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
begin
  if not Assigned(Actor) or not Assigned(FEngine) then
    Exit;
  // Reassign the engine pointer in case it was lost during serialization
  Actor.FEngine := FEngine;
  // Recreate the physics body based on loaded transform and scale
  JPos.x := Actor.Position.x;
  JPos.y := Actor.Position.y;
  JPos.z := Actor.Position.z;
  JRot.x := Actor.Quaternion.x;
  JRot.y := Actor.Quaternion.y;
  JRot.z := Actor.Quaternion.z;
  JRot.w := Actor.Quaternion.w;
  // Create the body in Jolt
  Actor.FBodyID := JPH_BodyInterface_CreateAndAddBody(FEngine.BodyInterface, JPH_BodyCreationSettings_Create3(Actor.FShape, @JPos, @JRot, JPH_MotionType_Dynamic, 0 // Default ObjectLayer, adjust if you save/load layers
  ), JPH_Activation_Activate);
  Actor.Visible := True;
end;
// ============================================================================
// SCENE SAVING & LOADING (Executed in main thread)
// ============================================================================

procedure TRaylibSandbox.SaveSceneToFile(const FileName: string);
begin
  FLock.Enter;
  try
    FQueuedSavePath := FileName;
    FSaveSceneQueued := True;
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.LoadSceneFromFile(const FileName: string);
begin
  FLock.Enter;
  try
    FQueuedLoadPath := FileName;
    FLoadSceneQueued := True;
  finally
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.ExecuteSceneSave(const FileName: string);
var
  Stream: TFileStream;
  Writer: TWriter;
  i: Integer;
  Actor: TA3DComponent;
begin
  if not Assigned(FEngine) then
    Exit;

  Stream := TFileStream.Create(FileName, fmCreate);
  FLock.Enter;
  try
    Writer := TWriter.Create(Stream, 4096);
    try
      Writer.WriteInteger(Length(FItems));

      for i := 0 to High(FItems) do
      begin
        Actor := FItems[i];
        if Assigned(Actor) then
        begin
          if Actor.ShapeType = stModel then
            Continue;

          Writer.WriteStr(Actor.Name);
          Writer.WriteInteger(Integer(Actor.ShapeType));

          Writer.WriteFloat(Actor.Position.x);
          Writer.WriteFloat(Actor.Position.y);
          Writer.WriteFloat(Actor.Position.z);

          Writer.WriteFloat(Actor.Quaternion.x);
          Writer.WriteFloat(Actor.Quaternion.y);
          Writer.WriteFloat(Actor.Quaternion.z);
          Writer.WriteFloat(Actor.Quaternion.w);

          Writer.WriteFloat(Actor.Scale.x);
          Writer.WriteFloat(Actor.Scale.y);
          Writer.WriteFloat(Actor.Scale.z);

          Writer.WriteFloat(Actor.Friction);
          Writer.WriteFloat(Actor.Restitution);

          Writer.WriteInteger(Actor.ActColor.r);
          Writer.WriteInteger(Actor.ActColor.g);
          Writer.WriteInteger(Actor.ActColor.b);
          Writer.WriteInteger(Actor.ActColor.a);

          // Save ModelPath if the actor is a model, otherwise -
          if Actor.ShapeType = stModel then
            Writer.WriteStr(Actor.ModelPath)
          else
            Writer.WriteStr('-');
        end;
      end;
      Writer.FlushBuffer;
    finally
      Writer.Free;
    end;
  finally
    Stream.Free;
    FLock.Leave;
  end;
end;

procedure TRaylibSandbox.ExecuteSceneLoad(const FileName: string);
var
  Stream: TFileStream;
  Reader: TReader;
  i, Count: Integer;
  Actor: TA3DComponent;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  ShapeType: TShapeType;
  Size: TVector3;
  Friction, Restitution: Single;
  LoadColor: TColorB;
  AName, ModelPath: string;
begin
  if not Assigned(FEngine) then
    Exit;

  if not System.SysUtils.FileExists(FileName) then
    Exit;

  // Soft reset the scene
  ClearDynamicItemsOnly;

  try
    Stream := TFileStream.Create(FileName, fmOpenRead);
    try
      Reader := TReader.Create(Stream, 4096);
      try
        Count := Reader.ReadInteger;

        for i := 0 to Count - 1 do
        begin
          AName := Reader.ReadStr;
          ShapeType := TShapeType(Reader.ReadInteger);

          JPos.x := Reader.ReadFloat;
          JPos.y := Reader.ReadFloat;
          JPos.z := Reader.ReadFloat;

          JRot.x := Reader.ReadFloat;
          JRot.y := Reader.ReadFloat;
          JRot.z := Reader.ReadFloat;
          JRot.w := Reader.ReadFloat;

          Size.x := Reader.ReadFloat;
          Size.y := Reader.ReadFloat;
          Size.z := Reader.ReadFloat;

          Friction := Reader.ReadFloat;
          Restitution := Reader.ReadFloat;

          LoadColor.r := Reader.ReadInteger;
          LoadColor.g := Reader.ReadInteger;
          LoadColor.b := Reader.ReadInteger;
          LoadColor.a := Reader.ReadInteger;

          // Read ModelPath ('-' if not a model)
          ModelPath := Reader.ReadStr;

          // Create the Actor natively
          Actor := TA3DComponent.Create('', FEngine, ShapeType, Size, False, false, @JPos, @JRot);
          Actor.Name := AName;
          Actor.Friction := Friction;
          Actor.Restitution := Restitution;
          Actor.ActColor := LoadColor;
          Actor.TargetColor := LoadColor;
          Actor.Visible := True;

          // Load model mesh if it's a model
          if (ShapeType = stModel) and (ModelPath <> '-') then
          begin
            Actor.ModelPath := ModelPath;
            var LoadedModel := LoadModel(PAnsiChar(AnsiString(ModelPath)));
            if LoadedModel.meshes <> nil then
            begin
              if (LoadedModel.materialCount > 0) and (LoadedModel.materials <> nil) then
              begin
                for var matIdx := 0 to LoadedModel.materialCount - 1 do
                  LoadedModel.materials[matIdx].shader := FLightShader;
              end;
              Actor.FModel := LoadedModel;
              var BBox := GetModelBoundingBox(LoadedModel);
              var MeshSize := Vector3Create(BBox.max.x - BBox.min.x, BBox.max.y - BBox.min.y, BBox.max.z - BBox.min.z);
              Actor.FMeshSize := MeshSize;
              Actor.FModelOffset := Vector3Create(-BBox.min.x * Size.x, -BBox.min.y * Size.y - 0.5, -BBox.min.z * Size.z);
            end;
          end
          else
            Actor.ModelPath := '';

          SetLength(FItems, Length(FItems) + 1);
          FItems[High(FItems)] := Actor;

          // Notify VCL Form about the spawned actor so it gets added to the TreeView
          DoActorSpawned(Actor, High(FItems));

          // Give Jolt Physics a tiny breather so Broadphase can catch up
          // This prevents bodies from spawning at 0,0,0
          Sleep(1);
        end;
      finally
        Reader.Free;
      end;
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      DoEngineException(E.Message, 'LoadSceneFromFile');
  end;
end;

procedure TRaylibSandbox.TriggerSpawnEffect(const Pos: TVector3; Actor: TA3DComponent);
<<<<<<< HEAD
var
  Effect: TSpawnEffect;
begin
  // Abort if no effect is selected
  if FSpawnEffectType = spefNone then
    Exit;

  Effect.Position := Pos;
  Effect.StartTime := GetTime();
  Effect.Duration := 1.5; // 1.5 seconds visual effect duration
  Effect.EffectType := FSpawnEffectType;
  Effect.TargetActor := Actor;

  // Make the actor invisible at the start of the effect
  if Assigned(Actor) then
  begin
    Actor.ActAlpha := 0.0;
    Actor.TargetAlpha := 1.0; // Let ModelEngine Lerp it to fully visible
  end;

  // Add to active effects array
  SetLength(FActiveSpawnEffects, Length(FActiveSpawnEffects) + 1);
  FActiveSpawnEffects[High(FActiveSpawnEffects)] := Effect;
end;

procedure TRaylibSandbox.DrawSpawnEffects;
var
  i: Integer;
  Elapsed, Progress, Alpha, Flicker: Single;
  BasePos, TopPos: TVector3;
  OuterRadius, InnerRadius: Single;
begin
  for i := 0 to High(FActiveSpawnEffects) do
  begin
    Elapsed := GetTime() - FActiveSpawnEffects[i].StartTime;

    // Skip expired effects
    if Elapsed >= FActiveSpawnEffects[i].Duration then
      Continue;

    Progress := Elapsed / FActiveSpawnEffects[i].Duration;
    Alpha := 1.0 - Progress;

    // Flicker effect to simulate the classic Enterprise transporter shimmer
    Flicker := 0.8 + (Random * 0.2);

    BasePos := FActiveSpawnEffects[i].Position;
    TopPos := Vector3Create(BasePos.x, BasePos.y + 150.0, BasePos.z);

    // Draw Visuals
    if FActiveSpawnEffects[i].EffectType = spefBeam then
    begin
      // ==============================================================
      // ENTERPRISE BEAM EFFECT
      // ==============================================================
      OuterRadius := 1.5 + (Sin(GetTime() * 20.0) * 0.2);
      InnerRadius := 0.5 + (Sin(GetTime() * 30.0) * 0.1);

      // 1. Outer Glow Cone (narrow at top, wide at bottom)
      DrawCylinderEx(TopPos, BasePos, OuterRadius * 0.3, OuterRadius, 16, Fade(GOLD, Alpha * 0.4 * Flicker));

      // 2. Inner Core (solid bright light)
      DrawCylinderEx(TopPos, BasePos, InnerRadius * 0.3, InnerRadius, 16, Fade(WHITE, Alpha * 0.9 * Flicker));

      // 3. Base glow disc (illuminating the floor)
      DrawCircle3D(BasePos, 2.5 + (Sin(GetTime() * 10.0) * 0.5), Vector3Create(1, 0, 0), 90.0, Fade(GOLD, Alpha * 0.7 * Flicker));
    end
    else if FActiveSpawnEffects[i].EffectType = spefFade then
    begin
      // ==============================================================
      // SIMPLE FADE EFFECT
      // ==============================================================
      DrawSphere(BasePos, 0.5 + (Progress * 2.0), Fade(SKYBLUE, Alpha * 0.4));
      DrawSphereWires(BasePos, 0.5 + (Progress * 2.0), 8, 8, Fade(WHITE, Alpha * 0.8));
    end;
  end;

  // Cleanup expired effects to prevent memory leaks and array bloat
  for i := High(FActiveSpawnEffects) downto 0 do
  begin
    if (GetTime() - FActiveSpawnEffects[i].StartTime) >= FActiveSpawnEffects[i].Duration then
    begin
      // Ensure the object is fully opaque when the effect ends!
      if Assigned(FActiveSpawnEffects[i].TargetActor) then
      begin
        FActiveSpawnEffects[i].TargetActor.TargetAlpha := 1.0;
        FActiveSpawnEffects[i].TargetActor.ActAlpha := 1.0;
      end;

      // Shift elements down if not the last element
      if i < High(FActiveSpawnEffects) then
        FActiveSpawnEffects[i] := FActiveSpawnEffects[High(FActiveSpawnEffects)];

      // Resize array
      SetLength(FActiveSpawnEffects, Length(FActiveSpawnEffects) - 1);
    end;
  end;
end;

{ TPiano }

constructor TPiano.Create(ASandbox: TRaylibSandbox);
var
  i: Integer;
  Pos: TVector3;
  Request: TSpawnRequest;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  WhiteKeyCount, Note: Integer;
  WhiteKeyW, WhiteKeyH, WhiteKeyD: Single;
  BlackKeyW, BlackKeyH, BlackKeyD: Single;
  HasBlack: Boolean;
  BlackOffset: Single;
  WoodColor: TColorB;
  WhiteBaseColor, WhiteHoverColor, BlackBaseColor, BlackHoverColor: TColorB;
  BaseCube: TA3DComponent;
begin
  FSandbox := ASandbox;
  FKeys := nil;

  // Dimensions
  WhiteKeyW := 1.0;
  WhiteKeyH := 0.2;
  WhiteKeyD := 3.0;
  BlackKeyW := 0.6;
  BlackKeyH := 0.3;
  BlackKeyD := 1.5;

  // 1. Spawn the Piano Base
  // Base height is 0.6. Center at Y=0.3 -> bottom is 0.0, top is 0.6
  JPos.x := 0;
  JPos.y := 0.3;
  JPos.z := 0;
  JRot.x := 0;
  JRot.y := 0;
  JRot.z := 0;
  JRot.w := 1;

  // Width is 14.0 to perfectly match 14 white keys
  BaseCube := TA3DComponent.Create('', FSandbox.FEngine, stBox, Vector3Create(14.0, 0.6, WhiteKeyD + 1.0), True, False, @JPos, @JRot);
  BaseCube.Name := 'PianoBody';

  WoodColor.r := 101;
  WoodColor.g := 67;
  WoodColor.b := 33;
  WoodColor.a := 255;
  BaseCube.ActColor := WoodColor;
  BaseCube.TargetColor := WoodColor;
  BaseCube.Visible := True;

  FBase := BaseCube;
  SetLength(FSandbox.FItems, Length(FSandbox.FItems) + 1);
  FSandbox.FItems[High(FSandbox.FItems)] := BaseCube;

  // Setup Colors
  WhiteBaseColor.r := 255;
  WhiteBaseColor.g := 255;
  WhiteBaseColor.b := 255;
  WhiteBaseColor.a := 255;
  WhiteHoverColor.r := 255;
  WhiteHoverColor.g := 255;
  WhiteHoverColor.b := 0;
  WhiteHoverColor.a := 255;

  BlackBaseColor.r := 0;
  BlackBaseColor.g := 0;
  BlackBaseColor.b := 0;
  BlackBaseColor.a := 255;
  BlackHoverColor.r := 255;
  BlackHoverColor.g := 165;
  BlackHoverColor.b := 0;
  BlackHoverColor.a := 255;

  // 2. Spawn the White and Black Keys
  WhiteKeyCount := 14; // 2 Octaves
  Note := 60; // Start at Middle C (MIDI Note 60)

  for i := 0 to WhiteKeyCount - 1 do
  begin
    HasBlack := not ((i mod 7 = 2) or (i mod 7 = 6)); // No black key after E and B

    // --- Spawn White Key ---
    // Base top is Y=0.6. Key is 0.2 high. Center at Y=0.7 means it goes from 0.6 to 0.8 exactly.
    Pos := Vector3Create((i * WhiteKeyW) - (WhiteKeyCount * WhiteKeyW * 0.5) + (WhiteKeyW * 0.5), 0.7, 0);

    Request.Shape := stBox; // HARD FIX: Use stBox to bypass stButton physics offsets!
    Request.Pos := Pos;
    Request.Size := Vector3Create(WhiteKeyW, WhiteKeyH, WhiteKeyD);
    Request.IsStatic := True;
    Request.IsDestructable := False;
    Request.Name := 'Key_White_' + IntToStr(Note);
    Request.Color := WhiteBaseColor;
    Request.BaseColor := WhiteBaseColor;
    Request.HoverColor := WhiteHoverColor;
    Request.Caption := '';
    Request.GenerateTestTexture := False;
    Request.OnClick := nil;

    FSandbox.QueueCustomSpawn(Request);

    // --- Spawn Black Key (if applicable) ---
    if HasBlack then
    begin
      BlackOffset := Pos.x + (WhiteKeyW * 0.5);

      // Base top is Y=0.6. Key is 0.3 high. Center at Y=0.75 means it goes from 0.6 to 0.9 exactly.
      Request.Pos := Vector3Create(BlackOffset, 0.75, -0.76);
      Request.Size := Vector3Create(BlackKeyW, BlackKeyH, BlackKeyD);
      Request.Name := 'Key_Black_' + IntToStr(Note + 1);
      Request.Color := BlackBaseColor;
      Request.BaseColor := BlackBaseColor;
      Request.HoverColor := BlackHoverColor;

      FSandbox.QueueCustomSpawn(Request);
      Inc(Note, 2);
    end
    else
      Inc(Note);
  end;
end;

destructor TPiano.Destroy;
begin
  FKeys := nil;
  FBase := nil;
  inherited;
end;

procedure TPiano.PressKey(Index: Integer);
begin
  if (Index >= 0) and (Index < Length(FKeys)) and Assigned(FKeys[Index]) then
    FKeys[Index].IsPressed := True;
end;

procedure TPiano.ReleaseKey(Index: Integer);
begin
  if (Index >= 0) and (Index < Length(FKeys)) and Assigned(FKeys[Index]) then
    FKeys[Index].IsPressed := False;
end;

function TPiano.GetKey(Index: Integer): TA3DComponent;
begin
  if (Index >= 0) and (Index < Length(FKeys)) then
    Result := FKeys[Index]
  else
    Result := nil;
end;

function TPiano.KeyCount: Integer;
begin
  Result := Length(FKeys);
end;

procedure TRaylibSandbox.SpawnPiano;
begin
  // Destroy existing piano if we spawn a new one to prevent duplicates
  if Assigned(FPiano) then
    FreeAndNil(FPiano);

  // Create the standalone Piano component
  FPiano := TPiano.Create(Self);
end;

=======
var
  Effect: TSpawnEffect;
begin
  // Abort if no effect is selected
  if FSpawnEffectType = spefNone then
    Exit;

  Effect.Position := Pos;
  Effect.StartTime := GetTime();
  Effect.Duration := 1.5; // 1.5 seconds visual effect duration
  Effect.EffectType := FSpawnEffectType;
  Effect.TargetActor := Actor;

  // Make the actor invisible at the start of the effect
  if Assigned(Actor) then
  begin
    Actor.ActAlpha := 0.0;
    Actor.TargetAlpha := 1.0; // Let ModelEngine Lerp it to fully visible
  end;

  // Add to active effects array
  SetLength(FActiveSpawnEffects, Length(FActiveSpawnEffects) + 1);
  FActiveSpawnEffects[High(FActiveSpawnEffects)] := Effect;
end;

procedure TRaylibSandbox.DrawSpawnEffects;
var
  i: Integer;
  Elapsed, Progress, Alpha, Flicker: Single;
  BasePos, TopPos: TVector3;
  OuterRadius, InnerRadius: Single;
begin
  for i := 0 to High(FActiveSpawnEffects) do
  begin
    Elapsed := GetTime() - FActiveSpawnEffects[i].StartTime;

    // Skip expired effects
    if Elapsed >= FActiveSpawnEffects[i].Duration then
      Continue;

    Progress := Elapsed / FActiveSpawnEffects[i].Duration;
    Alpha := 1.0 - Progress;

    // Flicker effect to simulate the classic Enterprise transporter shimmer
    Flicker := 0.8 + (Random * 0.2);

    BasePos := FActiveSpawnEffects[i].Position;
    TopPos := Vector3Create(BasePos.x, BasePos.y + 150.0, BasePos.z);

    // Draw Visuals
    if FActiveSpawnEffects[i].EffectType = spefBeam then
    begin
      // ==============================================================
      // ENTERPRISE BEAM EFFECT
      // ==============================================================
      OuterRadius := 1.5 + (Sin(GetTime() * 20.0) * 0.2);
      InnerRadius := 0.5 + (Sin(GetTime() * 30.0) * 0.1);

      // 1. Outer Glow Cone (narrow at top, wide at bottom)
      DrawCylinderEx(TopPos, BasePos, OuterRadius * 0.3, OuterRadius, 16, Fade(GOLD, Alpha * 0.4 * Flicker));

      // 2. Inner Core (solid bright light)
      DrawCylinderEx(TopPos, BasePos, InnerRadius * 0.3, InnerRadius, 16, Fade(WHITE, Alpha * 0.9 * Flicker));

      // 3. Base glow disc (illuminating the floor)
      DrawCircle3D(BasePos, 2.5 + (Sin(GetTime() * 10.0) * 0.5), Vector3Create(1, 0, 0), 90.0, Fade(GOLD, Alpha * 0.7 * Flicker));
    end
    else if FActiveSpawnEffects[i].EffectType = spefFade then
    begin
      // ==============================================================
      // SIMPLE FADE EFFECT
      // ==============================================================
      DrawSphere(BasePos, 0.5 + (Progress * 2.0), Fade(SKYBLUE, Alpha * 0.4));
      DrawSphereWires(BasePos, 0.5 + (Progress * 2.0), 8, 8, Fade(WHITE, Alpha * 0.8));
    end;
  end;

  // Cleanup expired effects to prevent memory leaks and array bloat
  for i := High(FActiveSpawnEffects) downto 0 do
  begin
    if (GetTime() - FActiveSpawnEffects[i].StartTime) >= FActiveSpawnEffects[i].Duration then
    begin
      // Ensure the object is fully opaque when the effect ends!
      if Assigned(FActiveSpawnEffects[i].TargetActor) then
      begin
        FActiveSpawnEffects[i].TargetActor.TargetAlpha := 1.0;
        FActiveSpawnEffects[i].TargetActor.ActAlpha := 1.0;
      end;

      // Shift elements down if not the last element
      if i < High(FActiveSpawnEffects) then
        FActiveSpawnEffects[i] := FActiveSpawnEffects[High(FActiveSpawnEffects)];

      // Resize array
      SetLength(FActiveSpawnEffects, Length(FActiveSpawnEffects) - 1);
    end;
  end;
end;

>>>>>>> 86ece52ad5be919e2e47d9d985edd4e01414d81d
end.

