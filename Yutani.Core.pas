unit Yutani.Core;

{==============================================================================*
 *  Yutani.Core v0.649 - Multi-threaded Raylib + Jolt 3D Editor
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
 *    - TYutaniRaylibSandbox inherits from TWinControl to provide a HWND parent
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
 *      from Jolt physics. Upon mouse release, the object is cleanly re-attached
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
 *      Space, and Holodeck (glowing orange grid) environments.
 *    - Dynamic Skybox Shaders: Horizon and zenith colors blend based on the
 *      time of day.
 *    - Spawn Effects: Enterprise transporter beam and simple fade effects.
 *    - Bomb System: Spawning destructible walls and triggering physics-based
 *      explosions with radial impulse forces.
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 * Apache-2.0 license
 *
 Latest Changes:

v0.649

 - Refactored TPiano class out of Yutani.Core into Yutani.VCL3D
 - Sandbox no longer owns a FPiano reference; TPiano is now instantiated
   and owned by the caller via TVCL3D.SpawnPiano
 - Piano gizmo linking now uses Name='PianoBody' + IsPianoKey scan
   instead of the FPiano pointer, so the feature keeps working
   without the sandbox knowing about TPiano
 - Added TVCL3D.SpawnTrackbar and TVCL3D.SpawnProgressBar std
   controls alongside the existing SpawnButton
 - Added new shape types stTrackbar and stProgressBar to TShapeType.
   Both render as a composite actor (dark base block + protruding
   front part) styled like the existing stButton.
 - Added generic published Integer property 'ItemPosition' on
   TA3DComponent. For stTrackbar / stProgressBar this holds the
   current value as a 0..1000 promille (caller maps to Min..Max).
   For other actors the field is unused and free for any future
   integer state the caller wants to attach to an actor.
 - 3D Trackbar is now fully interactive: click+drag the knob to
   change ItemPosition live (mouse X maps to 0..1000 promille).
 - 3D Progress Bar is driven externally via ItemPosition (use
   TVCL3D.SetProgressBarValue or the Object Inspector).
 - F12 now leaves posessed object, split screen moved to F2
 - Moved holodeck & Land in single units Yutani.Worlds.Land, Yutani.Worlds.Holodeck
 - Added world bones unit Yutani.Worlds.YourWorld
 - Added unit Yutani.Worlds.WorldTransitions
 - New world Transition effects: Warp, BlinkEye, Fade
 - New Engine tab Combobox for transition effect setting
 - Space reset/load/save functions added
 - Space radar minimap now real 3d & added zoom btns
 - Alt + Q/E now for select object
 - Ctrl while in vehicle/avatar shows/hides mouse cursor
 - Added checkbox beside Wall spawn btn for bomb on/off

 *==============================================================================}
{$POINTERMATH ON}
{$Q-}
{$R-}
interface

uses
  Winapi.Windows, Winapi.MMSystem, System.SysUtils, System.Classes, System.Math,
  System.SyncObjs, Vcl.Controls, Raylib, RayMath, rlgl, Yutani.Core.ModelEngine,
  JoltPhysics, MiniAudio4Delphi, Yutani.Audio, Yutani.Render.VoronoiFracture,
  Yutani.AliveHighlighter3D, Yutani.Worlds.Island, Yutani.Worlds.Space,
  Yutani.Worlds.Holodeck, Yutani.Worlds.Land, Yutani.Worlds.YourWorld,
  Yutani.Worlds.WorldTransitions, Yutani.Render.Shaders, Yutani.Render.Particles,
  Yutani.Render.NanoFog, Yutani.Render.LoadingScreen, GameNetworkingSockets,
  VerySimple.Lua, Yutani.Avatar.Controls, Yutani.Video.MPV, Yutani.Chaos.Skia,
  Yutani.Render.PathTracing;
  //RN_InputGeom, RN_Recast, RN_SampleInterfaces, RN_Sample, RN_SampleSoloMesh, RN_SampleTileMesh,
  //dglOpenGL, KromOGLUtils;

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
  // Custom Spawn Request record for external tools like Yutani.VCL3D.pas

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
    // Generic integer slot forwarded to TA3DComponent.ItemPosition on spawn.
    // Yutani.VCL3D uses this to seed stTrackbar / stProgressBar with an
    // initial 0..1000 promille value (caller maps to [Min..Max]).
    ItemPosition: Integer;
    // Knob / fill REST color for stTrackbar / stProgressBar. The knob /
    // fill lerps back to this color when neither hovered nor pressed.
    // Ignored for stButton (button face cycles between BaseColor and
    // HoverColor). Default to WHITE so unset records are still visible.
    FillColor: TColorB;
    // Generic "value changed" callback. Forwarded to TA3DComponent.OnChange
    // on spawn. For stTrackbar this fires (via TThread.Queue, safe to call
    // from VCL) every time ItemPosition changes during a drag. Sender is the
    // actor. Ignored for shape types that don't trigger OnChange.
    OnChange: TNotifyEvent;
  end;

  TParticleSpawnRequest = record
    Pos: TVector3;
    Count: Integer;
    Color: TColorB;
    IsSmoke: Boolean; // True = Smoke, False = Explosion
  end;
  // Thread-safe Dematerialize Request record - queued from VCL threads
  // and processed inside the render thread to avoid touching Jolt from
  // outside.

  TDematerializeRequest = record
    Actor: TA3DComponent;
  end;

  TWorldBaseType = (wbLand, wbSpace, wbHolodeck, wbIsland, wbYourWorld);
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

  TYutaniRaylibSandbox = class;

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

  TGizmoMode = (gmNone, gmTranslate, gmRotate, gmScale, gmUniformScale, gmDragAndThrow);

  // Note: TPiano has been moved to Yutani.VCL3D. The sandbox no longer owns
  // an FPiano reference; callers create TPiano instances via TVCL3D.SpawnPiano
  // and own their lifetime themselves. The sandbox still recognises piano
  // keys through the IsPianoKey flag on TA3DComponent and the 'PianoBody'
  // name on the base, so rendering / clicking / gizmo linking keep working
  // without any direct TPiano reference.

  TYutaniRaylibSandbox = class(TWinControl)
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
    FSpaceSpawnPad: TA3DComponent;
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
    // ====================================================================
    // NEW: Shadow-receiving floor plane.
    // --------------------------------------------------------------------
    // A transparent plane that sits 10cm above the world floor and only
    // renders shadow pixels (semi-transparent black) where the shadow
    // map says a shadow exists. The world floor shows through everywhere
    // else - so this is purely additive: it only ADDS shadows of spawned
    // objects onto the existing floor, never replaces the floor itself.
    // ====================================================================
    FShadowFloorShader: TShader;
    FShadowFloorModel: TModel;
    FShadowFloorMesh: TMesh;
    FShadowFloorMvpLoc: Integer;
    FShadowFloorModelLoc: Integer;
    FShadowFloorLightViewLoc: Integer;
    FShadowFloorLightProjLoc: Integer;
    FShadowFloorShadowMapLoc: Integer;
    FShadowFloorShadowBiasLoc: Integer;
    FShadowFloorEnabled: Boolean;
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
    FFrustumCulling: Boolean;
    FDistanceCulling: Boolean;
    FPopupOpen: Boolean;
    FPopupPos: TVector2;
    FPopupSegments: array of string;
    FPopupHoverIndex: Integer;
    FPopupCloseLock: Boolean;
    FLoadModelQueued: Boolean;
    FQueuedModelPath: string;
    FLastLoadedModelPath: string;
    FNavIndex: Integer;
    // Manual Day/Night Properties
    FDayNightRhythmActive: Boolean;
    // Distance Culling customizable property
    FMaxRenderDistance: Single;
    // Thread-safe Custom Spawn Queue
    FCustomSpawnQueue: TArray<TSpawnRequest>;
    FCustomSpawnTimer: Single;
    FIsMaterializingActor: Boolean;
    // Active 3D Trackbar drag target. Set when the user clicks an
    // stTrackbar actor with the left mouse button; cleared on release.
    // While non-nil, HandleDesktopInput maps the mouse X position onto
    // the actor's ItemPosition (0..1000 promille) so the knob follows
    // the cursor even if the cursor leaves the actor's hit box.
    FDraggingTrackbar: TA3DComponent;
    // Bomb System Variables
    FBombActor: TA3DComponent;
    FBombTimer: Single;
    FBombExploded: Boolean;
    // Particle Engine
    FParticleEngine: TYutaniParticleEngine;
    FParticleSpawnQueue: TArray<TParticleSpawnRequest>;
  // NanoFog Engine
    FNanoFog: TNanoFogEngine;
    FNanoFogAvatarID: Integer;
    // Slow Motion System Variables
    FTimeScale: Single;
    FSavedTimeScale: Single;  // 1.0 = Normal speed, 0.2 = 20% speed (Slow Motion)
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
    FIslandWorld: TIslandWorld;
    FSpaceWorld: TSpaceWorld;
    FHolodeckWorld: THolodeckWorld;
    FLandWorld: TLandWorld;
    FYourWorld: TYourWorld;
    // Space Landing & Cam Modes
    FSpaceLandingState: Integer; // 0 = Free Fly, 1 = Approach, 2 = Landed, 3 = Takeoff
    FSpaceLandingTargetPos: TVector3;
    FSpaceLandingTargetUp: TVector3;
    FSpaceLandingProgress: Single;
    FSpaceCamStartPos: TVector3;
    FSpaceCamStartTarget: TVector3;
    FSpacePlanetaryCam: Boolean;
    FSpaceLandingCamTargetCenter: TVector3;
    FSpaceLandingTargetIndex: Integer;
    // Spawn Effect System
    FSpawnEffectType: TSpawnEffectType;
    FActiveSpawnEffects: TArray<TSpawnEffect>;
    FAntiAliasing: Boolean;
    FGravity: Single;
    // Voronoi Fracture System
    FFractureQueue: TArray<TFragment>;
    FFractureTimer: Single;
    // AliveHighlighter3D
    FAliveHighlighter3D: TAliveHighlighter3D;
    FMouseWorldPos: TVector3;
    // Async Loading State
    FIsLoadingWorld: Boolean;
    FPendingWorldBase: TWorldBaseType;
    FPendingSpaceShader: TShader;
    FLoadWorldQueued: Boolean;
    FLoadingScreen: TYutaniLoadingScreen;
    // Cinematic world-swap transition manager. Owned by the sandbox
    // and driven from the render thread. See Yutani.Worlds.WorldTransitions
    // for the lifecycle (Outro -> Loading -> Intro).
    FWorldTransition: TWorldTransition;
    // Selected transition style for the next SetWorldBase call.
    // Set from the VCL (e.g. combobox in YutaniWindow) to change
    // which effect the next world swap uses. Does NOT affect an
    // in-flight transition - the new type only takes effect on
    // the next swap.
    FWorldTransitionType: TTransitionType;
    // Second Life style Camera Focus tracking variables
    FFocusTrackingActor: TA3DComponent;
    FAltWasPressed: Boolean;
   // ====================================================================
    // Centralized Avatar Controls & Input Manager
    // Bridges keyboard, SDL3 gamepad and mouselook input to the active
    // controller instance. The selected controller type lives in
    // FAvatarControllerType and is swapped at runtime via Shift+F11.
    // ====================================================================
    FAvatarController: TYutaniAvatarController;
    FPlayerVehicle: TA3DComponent;
    FIsDriving: Boolean;
    // Currently selected controller type. F11 uses this when possessing.
    // Shift+F11 cycles it. Defaults to actVehicle so the existing
    // behaviour is preserved without any user action.
    FAvatarControllerType: TYutaniAvatarControllerType;
    // Split-screen manager for 2-player local couch-coop. When Active,
    // this takes over driving duties from FAvatarController. Mutually
    // exclusive with the single-player F11 possess flow.
    FMultiPlayer: TYutaniMultiPlayerManager;
    // Per-player camera records used only when split-screen is active.
    // Each player's controller is wired to one of these; the sandbox
    // swaps FCamera with the relevant slot's pointer during the
    // split-screen render passes.
    FCam1: TCamera3D;
    FCam2: TCamera3D;
    // Active split-screen viewport dimensions. Set by Render3DScene
    // before calling Render3DSceneCore so the core pass knows what
    // aspect ratio to feed into the perspective matrix. Zero when
    // split-screen is not active - the core pass then leaves the
    // projection alone and BeginMode3D uses the full-window aspect.
    FSplitScreenVPW: Integer;
    FSplitScreenVPH: Integer;
    // --- Camera blend state ---
    // Smooth lerp back to the editor orbit view after the user exits
    // avatar driving mode. Without this the camera snaps in one frame
    // from the avatar controller's chase-cam math to the editor's
    // orbit-cam math, which are different formulas even when fed the
    // same CamYaw/Pitch/Dist values.
    FCamBlendActive: Boolean;
    FCamBlendStartPos: TVector3;
    FCamBlendStartTarget: TVector3;
    FCamBlendStartUp: TVector3;
    FCamBlendStartFOV: Single;
    FCamBlendProgress: Single;
    FCamBlendDuration: Single;
    // Dematerialize Queue
    FDematerializeQueue: TArray<TDematerializeRequest>;
    procedure ExecuteDematerializeActor(Actor: TA3DComponent);
    // Voronoi Fracture System
    procedure ProcessFractureQueue(dt: Single);
    procedure TriggerFracture(Actor: TA3DComponent; ImpactForce: Single);
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
    // Starts a smooth camera blend from the current FCamera state to
    // the editor orbit position. Call from any code path that releases
    // an avatar controller (F11 exit, F12 split-screen teardown, etc.).
    procedure StartCameraBlendToEditor(Duration: Single = 0.8);
    // Advances the active camera blend by dt. No-op when inactive.
    procedure UpdateCameraBlend(dt: Single);
    // Handles the F12 split-screen toggle. Extracted into its own
    // method so we get a clean var block (no inline vars) and can wrap
    // the whole thing in try/except to keep the render thread alive
    // even if anything goes wrong during split-screen setup.
    procedure HandleF12SplitScreenToggle;
    procedure HandleDesktopInput;
    // Maps the current mouse position onto the given stTrackbar actor's
    // ItemPosition (0..1000 promille). Called from HandleDesktopInput
    // both on initial click and every frame while the drag is held.
    procedure UpdateTrackbarFromMouse(Actor: TA3DComponent);
    procedure UpdateGame;
    procedure RenderGame;
    procedure Render3DScene;
    // Internal core pass that does the actual 3D rendering. Render3DScene
    // wraps this so the split-screen path can run it twice with swapped
    // viewport + camera without duplicating the entire scene pipeline.
    procedure Render3DSceneCore;
    procedure RenderShadowMap;
    procedure DrawSceneShadows;
    // NEW: Draw a transparent plane that receives shadows from the
    // shadow map. Renders on top of the world floor (10cm above) and
    // only darkens pixels where the shadow map says a shadow exists.
    procedure DrawShadowFloor;
    procedure DrawGUI;
    procedure DrawGizmo;
    procedure DrawThickRingAt(Center, NormalAxis: TVector3; Radius, Thickness: Single; Color: TColorB);
    procedure UpdateGizmoInteraction;
    function CheckGizmoAxisHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    function CheckGizmoRingHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    function CheckGizmoScaleHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    function CheckGizmoCornerHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
    procedure UpdateGizmoCornerInteraction;
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
    // Internal execution in the main thread
    procedure ExecuteSceneSave(const FileName: string);
    procedure ExecuteSceneLoad(const FileName: string);
    procedure TriggerSpawnEffect(const Pos: TVector3; Actor: TA3DComponent);
    procedure DrawSpawnEffects;
    procedure SetAntiAliasing(const Value: Boolean);
    procedure SetGravity(const Value: Single);
    procedure SetTimeScale(const Value: Single);
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
    FYutaniAudio: TYutaniAudioEngine;
    FShowInfosGUi: Boolean;
    FInputManager: TYutaniInputManager;
    function ItemCount: Integer;
    procedure ClearItems;
    procedure DeleteSelectedActor;
    procedure SpawnObjects(Count: Integer; ShapeType: TShapeType);
    procedure SetBrush(AShape: TShapeType);
    procedure SetSimulationRunning(AValue: Boolean);
    procedure SetSlowMotionActive(const Value: Boolean);
    procedure LoadCustomModel(const FilePath: string);
    function GetSimulationRunning: Boolean;
    function GetActorBoundingBoxWS(Actor: TA3DComponent): TBoundingBox;
    procedure SpawnAtMouse(Pos: TVector3);
    // Note: SpawnPiano has been moved to TVCL3D.SpawnPiano (Yutani.VCL3D unit).
    procedure SelectNextObject;
    procedure SelectPrevObject;
    // Exposes the custom spawn queue to external threads/UI
    procedure QueueCustomSpawn(const Request: TSpawnRequest);
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
   // Control the 3D Alive Highlighter
    procedure SetHighlighterActive(Active: Boolean);
    procedure SendHighlighterToActor(Actor: TA3DComponent);
    // External Particle Triggers
    procedure TriggerFogEffect;
    procedure TriggerExplosionEffect;
    // Nanofog
    procedure TriggerNanoFogDuplicate;
    procedure MorphSelectedToFog;
    procedure KillNanoFog;
    // External Dematerialize Triggers - safe to call from VCL/UI thread;
    // they queue a request that the render thread drains inside UpdateGame.
    procedure DematerializeSelectedObject;
    procedure DematerializeActor(Actor: TA3DComponent);
    procedure ExecuteMaterializeActor(Actor: TA3DComponent);
    // ===== Galaxy control (forwarded to FSpaceWorld) =====
    // These let the VCL control the galaxy persistence from buttons /
    // menu items. All are safe to call from the VCL thread. They are
    // no-ops when the current world is not wbSpace (FSpaceWorld = nil).
    procedure ResetUniverse;
    procedure SaveGalaxy;
    procedure LoadGalaxy;
    function GetGalaxyDBPath: string;
    // ===== Minimap marker forwarding (to FSpaceWorld) =====
    // External entities (enemies, NPCs, waypoints) call these to
    // register markers that appear in the 3D system minimap. The
    // caller manages the lifecycle - call ClearMinimapMarkers at the
    // start of each frame for per-frame markers, or manage entries
    // individually for persistent markers.
    procedure ClearMinimapMarkers;
    procedure AddMinimapMarker(const Pos: TVector3; const Col: TColorB; Size: Single = 3.0);
    // Radar zoom control (forwarded to FSpaceWorld). Connect to VCL
    // buttons (+ / -) so the user can zoom the 3D radar in/out.
    procedure RadarZoomIn;
    procedure RadarZoomOut;
    // Factory that maps TYutaniAvatarControllerType to the matching
    // controller class. Used by the F11 possess path and the Shift+F11
    // controller-swap path so the spawn logic lives in exactly one place.
    function CreateAvatarControllerOfType(AType: TYutaniAvatarControllerType; Avatar: TA3DComponent): TYutaniAvatarController;
    // Split-screen lifecycle. EnableSplitScreen spawns two controllers
    // (one per avatar/camera pair) and switches the sandbox from
    // single-player mode into 2-player mode. DisableSplitScreen tears
    // everything down and returns to single-player.
    procedure EnableSplitScreen(Avatar1, Avatar2: TA3DComponent; ControllerType1: TYutaniAvatarControllerType = actThirdPerson; ControllerType2: TYutaniAvatarControllerType = actThirdPerson);
    procedure DisableSplitScreen;
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
    // Cinematic transition style for world swaps. Set this from a
    // VCL combobox to let the user pick between Warp / BlinkEye /
    // Hyperspace / Fade. The chosen type is used by the next
    // SetWorldBase call; an in-flight transition is NOT affected.
    property WorldTransitionType: TTransitionType read FWorldTransitionType write FWorldTransitionType default ttBlinkEye;
    property AntiAliasing: Boolean read FAntiAliasing write SetAntiAliasing default True;
    property Gravity: Single read FGravity write SetGravity;
    property TimeScale: Single read FTimeScale write SetTimeScale;
    property IsLoadingWorld: Boolean read FIsLoadingWorld write FIsLoadingWorld;
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
{ TYutaniRaylibSandbox }
// Factory that maps the TYutaniAvatarControllerType enum to the matching
// controller class. Spawns the controller with @FCamera so the new
// instance is immediately wired to the sandbox camera. Caller is
// responsible for freeing the returned instance (typically by assigning
// it to FAvatarController and letting FreeAndNil clean it up).

function TYutaniRaylibSandbox.CreateAvatarControllerOfType(AType: TYutaniAvatarControllerType; Avatar: TA3DComponent): TYutaniAvatarController;
begin
  case AType of
    actVehicle:
      Result := TYutaniVehicleController.Create(Avatar, @FCamera);
    actThirdPerson:
      Result := TYutaniThirdPersonController.Create(Avatar, @FCamera);
    actFirstPerson:
      Result := TYutaniFirstPersonController.Create(Avatar, @FCamera);
    actFlight:
      Result := TYutaniFlightController.Create(Avatar, @FCamera);
    actSpectator:
      Result := TYutaniSpectatorController.Create(Avatar, @FCamera);
    actOrbit:
      Result := TYutaniOrbitController.Create(Avatar, @FCamera);
    actRigidBody:
      Result := TYutaniRigidBodyController.Create(Avatar, @FCamera);
  else
    Result := TYutaniVehicleController.Create(Avatar, @FCamera);
  end;
end;

procedure TYutaniRaylibSandbox.EnableSplitScreen(Avatar1, Avatar2: TA3DComponent; ControllerType1: TYutaniAvatarControllerType = actThirdPerson; ControllerType2: TYutaniAvatarControllerType = actThirdPerson);
var
  Cam1, Cam2: TCamera3D;
begin
  // Refuse to start split-screen while the single-player possess flow is
  // still active - the two modes would fight over the FCamera pointer.
  if FIsDriving then
  begin
    if Assigned(FInputManager) then
      FInputManager.StopMouseLook;
    FIsDriving := False;
    FPlayerVehicle := nil;
    FreeAndNil(FAvatarController);
  end;
  // Each player gets their own camera record. We initialise them with
  // sane defaults; the controllers will overwrite position/target/up
  // every frame anyway, so the initial values only matter for the very
  // first rendered frame.
  Cam1 := FCamera;
  Cam2 := FCamera;
  // We hand the manager pointers to the camera records. The sandbox
  // owns FCamera1 / FCamera2 (added as fields below) so the pointer
  // stays valid for the controller's lifetime.
  FCam1 := Cam1;
  FCam2 := Cam2;
  FMultiPlayer.EnableSplitScreen(Avatar1, Avatar2, @FCam1, @FCam2, ControllerType1, ControllerType2);
end;

procedure TYutaniRaylibSandbox.DisableSplitScreen;
begin
  FMultiPlayer.DisableSplitScreen;
end;

constructor TYutaniRaylibSandbox.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FLock := TCriticalSection.Create;
  FThreadActive := False;
  FIsMaterializingActor := False;
  FDraggingTrackbar := nil;
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
  FShadowBias := 0.003;
  FDayTime := 0.3; // Start at morning
  FDaySpeed := 0.01; // Day cycle speed
  FDayNightRhythmActive := True; // Enable automatic cycle by default
  FNavIndex := -1;
  SetLength(FParticleSpawnQueue, 0);
  FFocusTrackingActor := nil;
  FAltWasPressed := False;
  FShowInfosGUi := False;
  // Optimization: Initialize default shader ID to 0
  FDefaultShader.id := 0;
  // Default render culling distance
  FMaxRenderDistance := 300.0;
  // Initialize Custom Spawn Queue
  FCustomSpawnQueue := nil;
  FCustomSpawnTimer := 0.0;
  // Initialize Slow Motion System
  FTimeScale := 1.0; // Default to normal speed
  FSavedTimeScale := 0.2;
  FSlowMotionActive := False;
  // Init Scene Load/Save flags
  FSaveSceneQueued := False;
  FLoadSceneQueued := False;
  FQueuedSavePath := '';
  FQueuedLoadPath := '';
  // BASE WORLD INITIALIZATION: Default to wbHolodeck
  FCurrentWorldBase := wbHolodeck;
  // Initialize Spawn Effect System
  FSpawnEffectType := spefBeam;
  FActiveSpawnEffects := nil;
  FAntiAliasing := True;
  FGravity := -9.81;
   // ====================================================================
    // Initialize Avatar Controls
    // ====================================================================
  FInputManager := TYutaniInputManager.Create;
  FInputManager.InitializeGamepad;
  FPlayerVehicle := nil;
  FIsDriving := False;
  FAvatarController := nil;
  // Default to vehicle so the existing F11 behaviour is unchanged.
  FAvatarControllerType := actVehicle;
  // Split-screen manager is created lazily-idle; EnableSplitScreen must be
  // called explicitly before it does any work.
  FMultiPlayer := TYutaniMultiPlayerManager.Create;
  //init audio engines
  FYutaniAudio := TYutaniAudioEngine.Create;
  FYutaniAudio.InitAudio;
  FYutaniAudio.LoadSoundfont(ExtractFilePath(ParamStr(0)) + 'ressources\audio\8bitsf.sf2');
  // Cinematic world-swap transition manager. Created up-front so it
  // is ready the moment the first SetWorldBase is invoked. The manager
  // is a no-op (Active = False) until Start() is called, so creating
  // it here costs nothing per frame.
  FWorldTransition := TWorldTransition.Create;
  // Default transition style. The VCL form (YutaniWindow) overrides
  // this via the WorldTransitionType property when the user picks a
  // different effect in the combobox.
  FWorldTransitionType := ttBlinkEye;
end;

destructor TYutaniRaylibSandbox.Destroy;
begin
  StopThread;
  // Restore the OS cursor in case the sandbox is destroyed while
  // mouselook is still active - otherwise the user is left with an
  // invisible cursor after the window closes.
  if Assigned(FInputManager) then
    FInputManager.StopMouseLook;
  // Note: TPiano instances are now owned by the caller (Yutani.VCL3D),
  // so the sandbox destructor no longer frees a piano here.
  FreeAndNil(FAvatarController);
  // Tear down split-screen explicitly so the controllers are freed and
  // the avatars get their gravity factor reset to 1.0.
  FreeAndNil(FMultiPlayer);
  FreeAndNil(FLock);
  if Assigned(FYutaniAudio) then
    FreeAndNil(FYutaniAudio);
  if Assigned(FParticleEngine) then
    FreeAndNil(FParticleEngine);
  if Assigned(FAliveHighlighter3D) then
    FreeAndNil(FAliveHighlighter3D);
  // Tear down the cinematic transition manager. Safe to free even if
  // a transition is mid-flight because StopThread above has already
  // stopped the render loop, so no one is reading from it anymore.
  FreeAndNil(FWorldTransition);
  inherited;
end;

procedure TYutaniRaylibSandbox.CreateWindowHandle(const Params: TCreateParams);
begin
  inherited;
end;

procedure TYutaniRaylibSandbox.DestroyWindowHandle;
begin
  StopThread;
  inherited;
end;

procedure TYutaniRaylibSandbox.Resize;
begin
  inherited;
  if FInitialized and (FRaylibWnd <> 0) then
    SetWindowPos(FRaylibWnd, 0, 0, 0, ClientWidth, ClientHeight, SWP_NOZORDER);
end;

procedure TYutaniRaylibSandbox.SetActive(const Value: Boolean);
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

procedure TYutaniRaylibSandbox.SetTargetFPS(const Value: Integer);
begin
  if FTargetFPS <> Value then
    FTargetFPS := Value;
end;

procedure TYutaniRaylibSandbox.SetHighlightCollision(const Value: Boolean);
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

procedure TYutaniRaylibSandbox.SetDayNightRhythmActive(const Value: Boolean);
begin
  if FDayNightRhythmActive <> Value then
    FDayNightRhythmActive := Value;
end;

procedure TYutaniRaylibSandbox.SetDayNightTime(const Value: Single);
begin
  // Clamp the value between 0.0 and 1.0 to represent a full 24h cycle
  FDayTime := EnsureRange(Value, 0.0, 1.0);
end;

procedure TYutaniRaylibSandbox.SetDayNightSpeed(const Value: Single);
begin
  // Clamp the value to a reasonable range (e.g., 0.0 to pause, up to 1.0 for very fast)
  // Ensure the speed cannot be negative to prevent time going backwards unintentionally
  FDaySpeed := EnsureRange(Value, 0.0, 1.0);
end;

procedure TYutaniRaylibSandbox.SetSlowMotionActive(const Value: Boolean);
begin
  if FSlowMotionActive <> Value then
  begin
    FSlowMotionActive := Value;
    if FSlowMotionActive then
      FTimeScale := FSavedTimeScale
    else
      FTimeScale := 1.0;
    // Adjust audio pitch to match the slow motion / fast forward state
    if Assigned(FYutaniAudio) then
    begin
      FYutaniAudio.SetSFXPitch(FTimeScale);   // MiniAudio SFX
      FYutaniAudio.SetTSFPitch(FTimeScale);   // TinySoundFont Piano
    end;
  end;
end;

procedure TYutaniRaylibSandbox.SetTimeScale(const Value: Single);
begin
  FSavedTimeScale := EnsureRange(Value, 0.05, 2.0);
  if FSlowMotionActive then
    FTimeScale := FSavedTimeScale
  else
    FTimeScale := 1.0;
  // Live-update audio pitch when the trackbar value changes
  if Assigned(FYutaniAudio) then
  begin
    FYutaniAudio.SetSFXPitch(FTimeScale);     // MiniAudio SFX
    FYutaniAudio.SetTSFPitch(FTimeScale);     // TinySoundFont Piano
  end;
end;

procedure TYutaniRaylibSandbox.SetWorldBase(const Value: TWorldBaseType);
var
  NeedsHeavyLoad: Boolean;
begin
  if FCurrentWorldBase = Value then
    Exit;
  if FIsLoadingWorld then
    Exit;
  // Determine if this swap requires a heavy texture creation
  // (first-time Space load). If so, skip the cinematic
  // transition and fall back to the old loading screen behavior
  // (solid black + loading screen) because the render thread will
  // be blocked for seconds during the heavy lift and the transition
  // would just freeze behind the loading screen. For lightweight
  // swaps (Holodeck / Land / YourWorld, or Space / Island when
  // already loaded) the render thread keeps running, so the
  // transition can play smoothly on top of the live old world.
  NeedsHeavyLoad := ((Value = wbSpace) and (not Assigned(FSpaceWorld)));
               //  or ((Value = wbIsland) and (not Assigned(FIslandWorld)));
  if (not NeedsHeavyLoad) and Assigned(FWorldTransition) then
    FWorldTransition.Start(FWorldTransitionType);
  FIsLoadingWorld := True;
  if (Value = wbSpace) and (not Assigned(FSpaceWorld)) then
  begin
    if not Assigned(FLoadingScreen) then
      FLoadingScreen := TYutaniLoadingScreen.Create;
    FLoadingScreen.Start;
  end;
  // Resize the floor in Jolt immediately when switching worlds!
  if Assigned(FFloorActor) then
  begin
    // 1. Detach from Jolt so we can safely change the shape size
    FFloorActor.DetachFromPhysics;
    // 2. Change the size and visibility
    if Value = wbSpace then
    begin
      FFloorActor.Scale := Vector3Create(4, 0.9, 4); // Shrink to tiny 4x4 platform  - 0.9 so we not see it while world transitions
      FFloorActor.Visible := True;                 // Make it visible as a landing pad
      FFloorActor.Friction := 0.8;                 // High friction so things don't slide off
    end
    else
    begin
      FFloorActor.Scale := Vector3Create(1000, 1, 1000); // Restore giant floor
      FFloorActor.Visible := False;                      // Hide it for Holodeck/Land
      FFloorActor.Friction := 0.5;
    end;
    Sleep(1);
    // 3. Reattach to Jolt with the new size!
    FFloorActor.ReattachToPhysics;
  end;
  if Assigned(FEngine) then
  begin
    var GravVec: JPH_Vec3;
    if Value = wbSpace then
    begin
      GravVec.x := 0;
      GravVec.y := 0; // NO GRAVITY in space!
      GravVec.z := 0;
    end
    else
    begin
      GravVec.x := 0;
      GravVec.y := FGravity; // Normal gravity
      GravVec.z := 0;
    end;
    JPH_PhysicsSystem_SetGravity(FEngine.PhysicsSystem, @GravVec);
  end;
  FPendingWorldBase := Value;
  FPendingSpaceShader := FLightShader;
  FLoadWorldQueued := True;
end;

procedure TYutaniRaylibSandbox.SetAntiAliasing(const Value: Boolean);
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

procedure TYutaniRaylibSandbox.SetGravity(const Value: Single);
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
end;

procedure TYutaniRaylibSandbox.SetBrush(AShape: TShapeType);
begin
  FBrushShape := AShape;
  FIsBrushActive := True;
end;

procedure TYutaniRaylibSandbox.SetSimulationRunning(AValue: Boolean);
begin
  FSimulationRunning := AValue;
end;

function TYutaniRaylibSandbox.GetSimulationRunning: Boolean;
begin
  Result := FSimulationRunning;
end;

procedure TYutaniRaylibSandbox.SetGizmoMode(AMode: TGizmoMode);
begin
  FGizmoMode := AMode;
end;

procedure TYutaniRaylibSandbox.SetFrustumCulling(const Value: Boolean);
begin
  FFrustumCulling := Value;
end;

procedure TYutaniRaylibSandbox.SetDistanceCulling(const Value: Boolean);
begin
  FDistanceCulling := Value;
end;

procedure TYutaniRaylibSandbox.SetMaxRenderDistance(const Value: Single);
begin
  // Allow custom distance culling ranges, enforcing a sane minimum
  if Value > 10.0 then
    FMaxRenderDistance := Value
  else
    FMaxRenderDistance := 10.0;
end;

procedure TYutaniRaylibSandbox.InitLightingAndEnvironment;
var
  SkyMesh, CloudMesh: TMesh;
  FilePath: string;
begin
  // Generate a safe 1x1 white texture so the shader never samples empty memory (which would result in black)
  var WhiteImg := GenImageColor(1, 1, WHITE);
  FDefaultWhiteTex := LoadTextureFromImage(WhiteImg);
  UnloadImage(WhiteImg);
  // Initialize Main Lighting Shader (Uses constants from Yutani.Render.Shaders unit)
  FLightShader := LoadShaderFromMemory(PAnsiChar(VERT), PAnsiChar(FRAG));
  // Get uniform variable locations from the shader for later updates per frame
  FLightPosLoc := GetShaderLocation(FLightShader, 'lightPos');
  FViewPosLoc := GetShaderLocation(FLightShader, 'viewPos');
  FAmbientLoc := GetShaderLocation(FLightShader, 'ambient');
  FDiffuseLoc := GetShaderLocation(FLightShader, 'diffuse');
  FShadowMapLoc := GetShaderLocation(FLightShader, 'shadowMap');
  FLightViewLoc := GetShaderLocation(FLightShader, 'lightView');
  FLightProjLoc := GetShaderLocation(FLightShader, 'lightProj');
  // Optimization: Create the default shader once to prevent loading/unloading it every frame in RenderShadowMap
  FDefaultShader := LoadShader(nil, nil);
  // Create a 2048x2048 render texture to store the shadow map depth buffer
  FShadowMap := LoadRenderTexture(2048, 2048);
  SetTextureFilter(FShadowMap.texture, TEXTURE_FILTER_TRILINEAR);
  // Initialize main light position and mark camera as moved to force first update
  FLightPos := Vector3Create(50, 80, 30);
  FCameraMoved := True;
  // Setup the orthographic camera looking down from the light's perspective for shadow mapping
  FLightCam.position := Vector3Create(0, 80, 0);
  FLightCam.target := Vector3Create(0, 0, 0);
  FLightCam.up := Vector3Create(0, 1, 0);
  FLightCam.fovy := 20.0;
  FLightCam.projection := CAMERA_ORTHOGRAPHIC;
  // Apply trilinear filter to the generated default white texture
  SetTextureFilter(FDefaultWhiteTex, TEXTURE_FILTER_TRILINEAR);
  // Create a default material and assign our custom lighting shader to it
  FDefaultMat := LoadMaterialDefault();
  FDefaultMat.shader := FLightShader;
  FDefaultMat.maps[MATERIAL_MAP_ALBEDO].Color := WHITE;
  // Generate standard unit meshes for solid drawing (cached for performance)
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
  // Assign the lighting shader to all generated primitive models
  FBoxModel.materials[0].shader := FLightShader;
  FSphereModel.materials[0].shader := FLightShader;
  FCapsuleModel.materials[0].shader := FLightShader;
  FPyramidModel.materials[0].shader := FLightShader;
  FPrismModel.materials[0].shader := FLightShader;
  // Apply rotation transforms so the shader knows the normals rotate with the object
  FPyramidModel.transform := MatrixRotateY(45.0 * DEG2RAD);
  FPrismModel.transform := MatrixRotateY(120.0 * DEG2RAD);
  // Set the safe default white texture for ALL models so they don't render black without a custom texture
  FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  FSphereModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  FCapsuleModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  FPyramidModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  FPrismModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
  // Initialize Skybox (Uses constants from Yutani.Render.Shaders unit)
  FSkyboxShader := LoadShaderFromMemory(PAnsiChar(SKYBOX_VERT), PAnsiChar(SKYBOX_FRAG));
  FSkyboxDaytimeLoc := GetShaderLocation(FSkyboxShader, 'daytime');
  FSkyboxViewLoc := GetShaderLocation(FSkyboxShader, 'view');
  FSkyboxProjLoc := GetShaderLocation(FSkyboxShader, 'projection');
  // Create a cube mesh and invert it to act as the skybox interior
  SkyMesh := GenMeshCube(1.0, 1.0, 1.0);
  FSkyboxModel := LoadModelFromMesh(SkyMesh);
  FSkyboxModel.materials[0].shader := FSkyboxShader;
  // Load Skybox textures
  FilePath := ExtractFilePath(ParamStr(0)) + 'ressources/';
  if FileExists(PAnsiChar(AnsiString(FilePath + 'skyGradient.png'))) then
  begin
    FSkyboxTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'skyGradient.png')));
    SetTextureFilter(FSkyboxTex, TEXTURE_FILTER_TRILINEAR);
    // The procedural shader handles the actual rendering, this texture might be used for lookup if needed
  end;
  // Initialize Clouds (Uses constants from Yutani.Render.Shaders unit)
  FCloudShader := LoadShaderFromMemory(PAnsiChar(CLOUD_VERT), PAnsiChar(CLOUD_FRAG));
  FCloudMoveFactorLoc := GetShaderLocation(FCloudShader, 'moveFactor');
  FCloudDaytimeLoc := GetShaderLocation(FCloudShader, 'daytime');
  // Generate a large 2000x2000 plane for the clouds and place it high up
  CloudMesh := GenMeshPlane(2000, 2000, 1, 1);
  FCloudModel := LoadModelFromMesh(CloudMesh);
  FCloudModel.transform := MatrixTranslate(0, 150, 0);
  FCloudModel.materials[0].shader := FCloudShader;
  // Load cloud texture if it exists, set it to repeat for seamless scrolling
  if FileExists(PAnsiChar(AnsiString(FilePath + 'clouds.png'))) then
  begin
    FCloudTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'clouds.png')));
    SetTextureFilter(FCloudTex, TEXTURE_FILTER_TRILINEAR);
    SetTextureWrap(FCloudTex, TEXTURE_WRAP_REPEAT);
    FCloudModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FCloudTex;
  end;
  // Load Ambient Gradient texture for dynamic lighting color lookup
  if FileExists(PAnsiChar(AnsiString(FilePath + 'ambientGradient.png'))) then
  begin
    FAmbientGradientTex := LoadTexture(PAnsiChar(AnsiString(FilePath + 'ambientGradient.png')));
    SetTextureFilter(FAmbientGradientTex, TEXTURE_FILTER_TRILINEAR);
  end;

  // ========================================================================
  // NEW: Initialize the shadow-receiving floor plane.
  // ------------------------------------------------------------------------
  // This plane sits 10cm above the world floor and only renders shadow
  // pixels - transparent everywhere else. It uses the existing shadow
  // map that the lighting system already generates, so it does not need
  // any additional render pass. It only adds shadows of spawned objects
  // onto the existing world floor.
  // ========================================================================
  FShadowFloorShader := LoadShaderFromMemory(PAnsiChar(REFLECTIVE_FLOOR_VERT), PAnsiChar(REFLECTIVE_FLOOR_FRAG));
  FShadowFloorMvpLoc := GetShaderLocation(FShadowFloorShader, 'mvp');
  FShadowFloorModelLoc := GetShaderLocation(FShadowFloorShader, 'matModel');
  FShadowFloorLightViewLoc := GetShaderLocation(FShadowFloorShader, 'lightView');
  FShadowFloorLightProjLoc := GetShaderLocation(FShadowFloorShader, 'lightProj');
  FShadowFloorShadowMapLoc := GetShaderLocation(FShadowFloorShader, 'shadowMap');
  FShadowFloorShadowBiasLoc := GetShaderLocation(FShadowFloorShader, 'shadowBias');

  // 2000x2000 plane. Sits 10cm above world floor (y=0.1) to avoid z-fighting.
  FShadowFloorMesh := GenMeshPlane(2000, 2000, 1, 1);
  UploadMesh(@FShadowFloorMesh, False);
  FShadowFloorModel := LoadModelFromMesh(FShadowFloorMesh);
  FShadowFloorModel.materials[0].shader := FShadowFloorShader;

  // Enabled everywhere except Space (no floor there).
  FShadowFloorEnabled := (FCurrentWorldBase <> wbSpace);
end;

procedure TYutaniRaylibSandbox.StartThread;
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
            SetConfigFlags(FLAG_MSAA_4X_HINT or FLAG_WINDOW_RESIZABLE or FLAG_WINDOW_UNDECORATED)
          else
            SetConfigFlags(FLAG_WINDOW_RESIZABLE or FLAG_WINDOW_UNDECORATED);
          // 1. Initialize the Raylib window.
          // FLAG_WINDOW_UNDECORATED removes the standard Windows border, preventing
          // any border flicker during the reparenting process.
          InitWindow(1360, 768, 'Raylib Sandbox');
          // 2. Grab the window handle immediately after creation
          FRaylibWnd := FindWindow(nil, 'Raylib Sandbox');
          if FRaylibWnd <> 0 then
          begin
            // 3. Teleport the window instantly out of the visible screen area.
            // This happens so fast that Windows doesn't even get a chance to draw
            // a background frame on the screen, completely eliminating the startup flash.
            Winapi.Windows.SetWindowPos(FRaylibWnd, 0, -10000, -10000, 0, 0, SWP_NOZORDER or SWP_NOSIZE);
            // 4. Embed the window into our VCL control and adjust styles
            Winapi.Windows.SetParent(FRaylibWnd, Self.Handle);
            SetWindowLong(FRaylibWnd, GWL_STYLE, WS_CHILD or WS_VISIBLE);
            // 5. Finally, position and size it perfectly inside our VCL parent
            SetWindowPos(FRaylibWnd, 0, 0, 0, Self.ClientWidth, Self.ClientHeight, SWP_NOZORDER);
          end;
          FEngine := TModelEngine.Create;
          // Apply initial Gravity
          var InitGravVec: JPH_Vec3;
          InitGravVec.x := 0;
          InitGravVec.y := FGravity;
          InitGravVec.z := 0;
          JPH_PhysicsSystem_SetGravity(FEngine.PhysicsSystem, @InitGravVec);
          FCamYaw := -0.5;
          FCamPitch := 0.8;
          FCamDist := 60.0;
          // In Space, start high up so we don't fall into the void!
          if FCurrentWorldBase = wbSpace then
          begin
            FCamera.target := Vector3Create(0, 50, 0);
            FCamera.position := Vector3Create(20, 70, 20);
          end
          else
          begin
            FCamera.target := Vector3Create(0, 0, 0);
            FCamera.position := Vector3Create(20, 20, 20);
          end;
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
          // Create the extracted world instances. Holodeck is lightweight
          // (no GPU assets) so we always create it. Land loads skybox +
          // cloud shaders + textures from the ressources/ folder.
          // YourWorld is a skeleton template for user-built worlds.
          FHolodeckWorld := THolodeckWorld.Create;
          FLandWorld := TLandWorld.Create(ExtractFilePath(ParamStr(0)) + 'ressources/', PAnsiChar(SKYBOX_VERT), PAnsiChar(SKYBOX_FRAG), PAnsiChar(CLOUD_VERT), PAnsiChar(CLOUD_FRAG), FLightShader);
          FYourWorld := TYourWorld.Create(FLightShader);
          FParticleEngine := TYutaniParticleEngine.Create;
          // Init NanoFog Engine
          FNanoFog := TNanoFogEngine.Create;
          FNanoFogAvatarID := 1;
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
              // ==========================================
              // WORLD LOADING (RAYLIB STAYS VISIBLE BUT BLACK)
              // ==========================================
              // Two-stage gating: when a world swap is queued AND a
              // cinematic transition is in tpOutro, we let the Outro
              // play on the OLD world (still alive + animating) before
              // we touch anything. Only once the transition has reached
              // tpLoading (the tunnel mask now covers the screen) do we
              // perform the heavy lift. This produces the "freeze old
              // world -> warp out -> tunnel -> warp in -> new world"
              // sequence the user expects, instead of "new world -> warp".
              if FLoadWorldQueued then
              begin
                if Assigned(FWorldTransition) and FWorldTransition.Active and (FWorldTransition.Phase = tpOutro) then
                begin
                  // Outro is still playing on the OLD world. Run a
                  // normal frame so the warp can advance. We DO NOT
                  // clear FLoadWorldQueued here so the next iteration
                  // re-enters this branch and checks the phase again.
                  // Once tpOutro advances to tpLoading, the else branch
                  // below will finally pick up the heavy lift.
                  UpdateGame;
                  RenderGame;
                end
                else
                begin
                  // No transition in flight, OR transition has moved
                  // past tpOutro (tpLoading / tpIntro / tpComplete).
                  // Now is the safe moment to do the heavy swap: the
                  // tunnel mask is already covering the screen so the
                  // user can't see the swap happen.
                  FLoadWorldQueued := False;
                  FIsLoadingWorld := True;
                  // 1. Start the loading screen (only the very first
                  //    time we load Space - subsequent swaps reuse the
                  //    already-created instance and the screen is a
                  //    no-op during the transition anyway).
                  if (FPendingWorldBase = wbSpace) and (not Assigned(FSpaceWorld)) then
                  begin
                    if (not Assigned(FLoadingScreen)) then
                      FLoadingScreen := TYutaniLoadingScreen.Create;
                    FLoadingScreen.Start;
                  end;
                  // 2. Render one frame so the tunnel is the last
                  //    visible image while the heavy lift blocks the
                  //    render thread for several seconds. Without this
                  //    the last rendered frame would be the Outro peak
                  //    (just before tunnel) which is acceptable but the
                  //    explicit tunnel frame is cleaner.
                  RenderGame;
                  // 3. Perform the heavy lifting (this blocks the thread)
                  try
                    if FPendingWorldBase = wbSpace then
                    begin
                      if not Assigned(FSpaceWorld) then
                        FSpaceWorld := TSpaceWorld.Create(FPendingSpaceShader);
                    end
                    else if FPendingWorldBase = wbIsland then
                    begin
                      if not Assigned(FIslandWorld) then
                        FIslandWorld := TIslandWorld.Create(ExtractFilePath(ParamStr(0)) + 'ressources/', FDefaultWhiteTex);
                    end;
                  except
                    on E: Exception do
                      DoEngineException(E.Message, 'AsyncWorldLoad');
                  end;
                  // 4. Apply world settings
                  FCurrentWorldBase := FPendingWorldBase;
                  case FCurrentWorldBase of
                    wbLand:
                      begin
                        FDayNightRhythmActive := True;
                        FDayTime := 0.5;
                      end;
                    wbSpace:
                      begin
                        FDayNightRhythmActive := False;
                        FDayTime := 0.0;
                      end;
                    wbHolodeck:
                      begin
                        FDayNightRhythmActive := False;
                        FDayTime := 0.5;
                      end;
                    wbIsland:
                      FDayNightRhythmActive := True;
                  end;
                  FShadowMapDirty := True;
                  // NEW: Disable shadow floor in Space (no floor there),
                  // enable everywhere else.
                  FShadowFloorEnabled := (FCurrentWorldBase <> wbSpace);
                  // 5. Tell the loading screen to stop.
                  // It will gracefully fade out itself!
                  if Assigned(FLoadingScreen) then
                  begin
                    FLoadingScreen.AsyncStop;
                    FLoadingScreen := nil;
                  end;
                  FIsLoadingWorld := False;
                  // Tell the transition manager that the heavy swap is
                  // done so it can leave tpLoading on the next Update()
                  // and play the Intro warp on the NEW world. The
                  // manager still enforces its minimum tunnel duration,
                  // so very fast swaps get a brief extra tunnel moment
                  // instead of a jarring snap.
                  if Assigned(FWorldTransition) then
                    FWorldTransition.AdvanceToIntro;
                end;
              end
              else
              begin
                UpdateGame;
                RenderGame;
              end;
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
          if Assigned(FLoadingScreen) then
          begin
            FLoadingScreen.StopThread;
            FLoadingScreen := nil;
          end;
          FreeAndNil(FParticleEngine);
          FreeAndNil(FFloorActor);
          FreeAndNil(FSpaceSpawnPad);
          FreeAndNil(FNanoFog);
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
          // NEW: Free shadow-receiving floor resources.
          if FShadowFloorShader.id > 0 then
          begin
            UnloadShader(FShadowFloorShader);
            if FShadowFloorModel.meshes <> nil then
              UnloadModel(FShadowFloorModel);
          end;
          UnloadMesh(FUnitBox);
          UnloadMesh(FUnitSphere);
          if Assigned(FIslandWorld) then
            FreeAndNil(FIslandWorld);
          if Assigned(FSpaceWorld) then
            FreeAndNil(FSpaceWorld);
          if Assigned(FHolodeckWorld) then
            FreeAndNil(FHolodeckWorld);
          if Assigned(FLandWorld) then
            FreeAndNil(FLandWorld);
          if Assigned(FYourWorld) then
            FreeAndNil(FYourWorld);
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

procedure TYutaniRaylibSandbox.StopThread;
begin
  if not FThreadActive then
    Exit;
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(100);
  end;
end;

procedure TYutaniRaylibSandbox.InitScene;
begin
  // Standard giant floor for the first start
  FFloorActor := TA3DComponent.Create('', FEngine, stBox, Vector3Create(1000, 1, 1000), True);
  FFloorActor.SetPosition(Vector3Create(0, -0.5, 0));
  FFloorActor.Visible := False;
  FFloorActor.Friction := 0.5;
  FItems := nil;
end;

function TYutaniRaylibSandbox.ItemCount: Integer;
begin
  Result := Length(FItems);
end;

procedure TYutaniRaylibSandbox.ClearItems;
begin
  FLock.Enter;
  try
    FGizmoMode := gmNone;
    FClearItemsQueued := True;
    // Clear custom spawn queue to prevent further scripted spawns after clearing
    FCustomSpawnQueue := nil;
    FBombActor := nil;
    FBombExploded := False;
    // Cancel any in-flight trackbar drag so the next frame doesn't try to
    // write ItemPosition on a freed actor.
    FDraggingTrackbar := nil;
    SetBrush(TShapeType(-1));
    FActiveSpawnEffects := nil;
    // Note: TPiano is now owned by the caller (Yutani.VCL3D). The caller
    // is responsible for freeing its TPiano instance when the scene is
    // cleared. The piano base + keys themselves live in FItems and are
    // freed by the generic FItems cleanup below.
    FFocusTrackingActor := nil; // Clear focus tracking on scene clear
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.SpawnObjects(Count: Integer; ShapeType: TShapeType);
begin
  FLock.Enter;
  try
    FSpawnQueue := FSpawnQueue + Count;
    FSpawnShape := ShapeType;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.QueueCustomSpawn(const Request: TSpawnRequest);
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

procedure TYutaniRaylibSandbox.ProcessSpawnQueue(dt: Single);
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
  Obj.Friction := 0.4;
  Obj.Restitution := 0.2;
  Obj.UserData := Data;
  Obj.Visible := True;
  FItems[oldLen] := Obj;
  DoActorSpawned(Obj, oldLen);
end;

procedure TYutaniRaylibSandbox.StartCameraBlendToEditor(Duration: Single);
begin
  // Capture the avatar controller's last camera state so we can smoothly
  // lerp from there to the editor orbit position. We read FCamera as-is
  // (the controller has just written it via WriteCameraTransform with
  // its own smoothing still partially in flight).
  FCamBlendStartPos := FCamera.position;
  FCamBlendStartTarget := FCamera.target;
  FCamBlendStartUp := FCamera.up;
  FCamBlendStartFOV := FCamera.fovy;
  // Reset the blend progress. Duration is clamped to a tiny minimum so
  // external callers can pass user-configurable values without risking
  // a divide-by-zero in UpdateCameraBlend.
  if Duration < 0.001 then
    Duration := 0.001;
  FCamBlendDuration := Duration;
  FCamBlendProgress := 0.0;
  FCamBlendActive := True;
end;

procedure TYutaniRaylibSandbox.UpdateCameraBlend(dt: Single);
const
  EDITOR_DEFAULT_FOV: Single = 45.0;
var
  Alpha: Single;
  DesiredPos: TVector3;
begin
  if not FCamBlendActive then
    Exit;
  // Advance the blend. We use the same smoothstep curve as the avatar
  // controller's one-shot transitions so the feel is consistent.
  FCamBlendProgress := FCamBlendProgress + (dt / FCamBlendDuration);
  if FCamBlendProgress >= 1.0 then
  begin
    FCamBlendProgress := 1.0;
    FCamBlendActive := False;
  end;
  Alpha := FCamBlendProgress * FCamBlendProgress * (3.0 - 2.0 * FCamBlendProgress);
  // Compute the editor's orbit position for the current FCamera.target
  // + FCamYaw/Pitch/Dist. This is exactly what HandleCameraInput would
  // set on the next frame, so we lerp FCamera.position towards that
  // value to make the handoff seamless.
  DesiredPos := Vector3Create(FCamera.target.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FCamera.target.y + Sin(FCamPitch) * FCamDist, FCamera.target.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
  FCamera.position := Vector3Lerp(FCamBlendStartPos, DesiredPos, Alpha);
  // Lerp the FOV back to the editor default. The First Person controller
  // may have left it at 60 (walk) or 30 (ADS); restoring to 45 here
  // prevents a visible FOV snap when the blend ends.
  FCamera.fovy := Lerp(FCamBlendStartFOV, EDITOR_DEFAULT_FOV, Alpha);
end;

procedure TYutaniRaylibSandbox.HandleCameraInput;
var
  p: TPoint;
  dt, panSpeed: Single;
  fwdX, fwdZ, rightX, rightZ: Single;
begin
  // If a camera blend is running we let it drive FCamera exclusively so
  // the editor's regular orbit logic does not snap the camera mid-blend.
  if FCamBlendActive then
    Exit;
  // If we are landed or in planetary cam, we handle the camera entirely in SpaceLandingCamUpdate.
  // CRITICAL: Skip ALL of this if we are driving our own vehicle!
  if FIsDriving and Assigned(FPlayerVehicle) then
    Exit;
  if (FCurrentWorldBase = wbSpace) and Assigned(FSpaceWorld) and ((FSpaceLandingState > 0) or FSpaceWorld.IsLanded) then
    Exit;
  // CRITICAL: Skip normal camera logic entirely while driving a vehicle!
  if FIsDriving and Assigned(FPlayerVehicle) and (not FPlayerVehicle.FIsDead) then
  begin
    Exit;
  end;
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
  // Extend camera limits for infinite space exploration
  if FCurrentWorldBase = wbSpace then
  begin
    FCamera.target.x := EnsureRange(FCamera.target.x, -100000.0, 100000.0);
    FCamera.target.z := EnsureRange(FCamera.target.z, -100000.0, 100000.0);
  end
  else
  begin
    FCamera.target.x := EnsureRange(FCamera.target.x, -450.0, 450.0);
    FCamera.target.z := EnsureRange(FCamera.target.z, -450.0, 450.0);
  end;
  if GetMouseWheelMove() <> 0 then
  begin
    FCamDist := EnsureRange(FCamDist - GetMouseWheelMove() * 3.0, 10, 250);
    FCameraMoved := True;
  end;
  FCamera.position := Vector3Create(FCamera.target.x + Cos(FCamPitch) * Sin(FCamYaw) * FCamDist, FCamera.target.y + Sin(FCamPitch) * FCamDist, FCamera.target.z + Cos(FCamPitch) * Cos(FCamYaw) * FCamDist);
end;

procedure TYutaniRaylibSandbox.PublicShootBall;
begin
  ShootBall;
end;

procedure TYutaniRaylibSandbox.ShootBall;
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
  Obj.Friction := 0.4;
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

procedure TYutaniRaylibSandbox.UpdateProjectiles(dt: Single);
var
  i: Integer;
  Actor: TA3DComponent;
  CurrVel: TVector3;
  SpeedSq: Single;
begin
  // FREEZE ENGINE WHILE LOADING - but NOT during the transition's
  // tpOutro phase, because then the old world is still being shown
  // and should keep animating (physics, projectiles, day/night) so
  // the warp fades out a LIVE scene, not a frozen one.
  if FIsLoadingWorld and (not (Assigned(FWorldTransition) and FWorldTransition.Active and (FWorldTransition.Phase = tpOutro))) then
  begin
    Exit;
  end;
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

procedure TYutaniRaylibSandbox.HandleF12SplitScreenToggle;
var
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  Idx: Integer;
  CubeSize: TVector3;
  Cube: TA3DComponent;
  NewData: PItemData;
begin
  OutputDebugString('F12 detected - entering HandleF12SplitScreenToggle.');
  // Defensive: if the manager was never created (e.g. constructor failed
  // silently), bail out so we do not dereference a nil pointer below.
  if not Assigned(FMultiPlayer) then
  begin
    OutputDebugString('F12: FMultiPlayer is nil, aborting.');
    Exit;
  end;
  try
    if FMultiPlayer.Active then
    begin
      DisableSplitScreen;
      OutputDebugString('F12: Split-screen disabled.');
      Exit;
    end;
    // Make sure we have at least 2 avatars to drive. If the scene is
    // empty or only has one dynamic item, spawn fresh test cubes at
    // distinct positions so the user immediately sees the split.
    while Length(FItems) < 2 do
    begin
      Idx := Length(FItems);
      // Place them next to each other along the X axis so each player
      // starts with a clearly different view.
      JPos.x := (Idx - 0.5) * 6.0;
      JPos.y := 5.0;
      JPos.z := 0.0;
      JRot.x := 0;
      JRot.y := 0;
      JRot.z := 0;
      JRot.w := 1;
      CubeSize := Vector3Create(1, 1, 1);
      Cube := TA3DComponent.Create('', FEngine, stBox, CubeSize, False, False, @JPos, @JRot);
      Cube.Name := 'SplitScreen_Avatar_' + IntToStr(Idx);
      Cube.Friction := 0.4;
      Cube.Restitution := 0.2;
      Cube.Visible := True;
      New(NewData);
      FillChar(NewData^, SizeOf(TItemData), 0);
      NewData^.SpawnTime := GetTime();
      NewData^.IsProjectile := False;
      NewData^.Name := Cube.Name;
      Cube.UserData := NewData;
      SetLength(FItems, Length(FItems) + 1);
      FItems[High(FItems)] := Cube;
      DoActorSpawned(Cube, High(FItems));
    end;
    OutputDebugString(PChar(Format('F12: Enabling split-screen (%d items in scene).', [Length(FItems)])));
    EnableSplitScreen(FItems[0], FItems[1], FAvatarControllerType, FAvatarControllerType);
    // Activate both avatars so Jolt does not keep them asleep on the
    // very first frame after spawning.
    FItems[0].ActivateBody;
    FItems[1].ActivateBody;
    OutputDebugString('F12: Split-screen enabled successfully.');
  except
    on E: Exception do
    begin
      OutputDebugString(PChar('F12 EXCEPTION: ' + E.Message));
      // If anything went wrong during setup, force the manager inactive
      // so subsequent frames do not try to drive a half-set-up state.
      if Assigned(FMultiPlayer) then
        FMultiPlayer.DisableSplitScreen;
    end;
  end;
end;

procedure TYutaniRaylibSandbox.HandleDesktopInput;
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
  HalfX, HalfY, HalfZ: Single;
  GScaleX, GScaleY, GScaleZ: Single;
  TargetY, t: Single;
  bIsModelBrush: Boolean;
  bLeftMouseDown: Boolean;
  bLeftMouseClicked: Boolean;
  R: TRect;
  bAltIsDown: Boolean;
  ClosestFocusActor: TA3DComponent;
  ClosestFocusDist: Single;
  TempHit: TRayCollision;
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
  // SPACE LANDING & PLANETARY CAM (F8 / F9)
  // ==========================================
  if FCurrentWorldBase = wbSpace then
  begin
    // --- SPACE LANDING ANIMATION (Runs every frame) ---
    if FSpaceLandingState > 0 then
    begin
      FSpaceLandingProgress := FSpaceLandingProgress + (GetFrameTime() * 0.8);
      if FSpaceLandingProgress > 1.0 then
        FSpaceLandingProgress := 1.0;
      t := FSpaceLandingProgress;
      t := t * t * (3 - 2 * t); // Smooth Ease-In-Out
      if FSpaceLandingState = 1 then // Approaching
      begin
        // Smoothly fly to the position 10 units above the surface
        FCamera.position := Vector3Add(FSpaceCamStartPos, Vector3Scale(Vector3Subtract(FSpaceLandingTargetPos, FSpaceCamStartPos), t));
        // Smoothly transition looking at the surface point in front of us
        FCamera.target := Vector3Add(FSpaceCamStartTarget, Vector3Scale(Vector3Subtract(FSpaceLandingCamTargetCenter, FSpaceCamStartTarget), t));
        // Smoothly align Up-Vector to surface normal (SurfDir)
        FCamera.up := Vector3Add(Vector3Create(0, 1, 0), Vector3Scale(Vector3Subtract(FSpaceLandingTargetUp, Vector3Create(0, 1, 0)), t));
        if FSpaceLandingProgress >= 1.0 then
        begin
          FSpaceLandingState := 2; // Landed
          if FSpaceLandingTargetIndex >= 0 then
            FSpaceWorld.InitiateLanding(FSpaceLandingTargetIndex, FCamera.target, FCamera.position);
          // Snap to ensure the camera is perfectly aligned with the surface
          FCamera.position := FSpaceLandingTargetPos;
          FCamera.target := FSpaceLandingCamTargetCenter;
          FCamera.up := FSpaceLandingTargetUp;
        end;
      end
      else if FSpaceLandingState = 3 then // Taking off
      begin
        FCamera.position := Vector3Add(FSpaceCamStartPos, Vector3Scale(Vector3Subtract(FSpaceLandingTargetPos, FSpaceCamStartPos), t));
        FCamera.target := Vector3Add(FSpaceCamStartTarget, Vector3Scale(Vector3Subtract(FSpaceLandingTargetPos, FSpaceCamStartTarget), t));
        FCamera.up := Vector3Add(FSpaceLandingTargetUp, Vector3Scale(Vector3Subtract(Vector3Create(0, 1, 0), FSpaceLandingTargetUp), t));
        if FSpaceLandingProgress >= 1.0 then
        begin
          FSpaceLandingState := 0; // Free Fly
          FSpaceWorld.ReleaseLanding;
        end;
      end;
    end;
    // --- INPUT HANDLING ---
    if (GetAsyncKeyState(VK_F8) and $1) <> 0 then
    begin
      if not FSpaceWorld.IsLanded then
      begin
        FSpacePlanetaryCam := not FSpacePlanetaryCam;
        if FSpacePlanetaryCam then
        begin
          var Idx: Integer;
          var Dist: Single;
          if FSpaceWorld.FindNearestPlanet(FCamera.position, Idx, Dist) then
            FSpaceWorld.InitiateLanding(Idx, FCamera.target, FCamera.position);
        end
        else
          FSpaceWorld.ReleaseLanding;
      end;
    end;
    if (GetAsyncKeyState(VK_F9) and $1) <> 0 then
    begin
      if FSpaceLandingState = 0 then
      begin
        // Start Approach
        var Idx: Integer;
        var Dist: Single;
        if FSpaceWorld.FindNearestPlanet(FCamera.position, Idx, Dist) and (Dist < 5000.0) then
        begin
          FSpaceLandingTargetIndex := Idx;
          FSpacePlanetaryCam := False;
          var PlanetPos: TVector3;
          var PlanetRadius: Single;
          FSpaceWorld.GetPlanetInfo(Idx, PlanetPos, PlanetRadius);
          // 1. SurfDir: The vector from the center to our position
          var SurfDir := Vector3Normalize(Vector3Subtract(FCamera.position, PlanetPos));
          if (IsNan(SurfDir.x)) or (IsNan(SurfDir.y)) or (IsNan(SurfDir.z)) then
            SurfDir := Vector3Create(0, 1, 0);
          // 2. CamPos: 10 units above the surface
          FSpaceLandingTargetPos := Vector3Add(PlanetPos, Vector3Scale(SurfDir, PlanetRadius + 10.0));
          // 3. CamTarget: A point 15 units in front of us on the surface (looking slightly downwards)
          // We move a bit "forward" on the sphere and set the target point 2 units above the ground.
          var LookAtPos := Vector3Add(PlanetPos, Vector3Scale(SurfDir, PlanetRadius + 2.0));
          FSpaceLandingCamTargetCenter := LookAtPos;
          // Up-Vector = SurfDir, so the horizon is straight
          FSpaceLandingTargetUp := SurfDir;
          FSpaceCamStartPos := FCamera.position;
          FSpaceCamStartTarget := FCamera.target;
          FSpaceLandingState := 1; // Approaching
          FSpaceLandingProgress := 0.0;
        end;
      end
      else if FSpaceLandingState = 2 then
      begin
        // Start Takeoff
        FSpaceCamStartPos := FCamera.position;
        FSpaceCamStartTarget := FCamera.target;
        // Fly straight forward and upwards (in view direction)
        var forward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));
        FSpaceLandingTargetPos := Vector3Add(FCamera.position, Vector3Scale(forward, 300.0));
        FSpaceLandingTargetUp := Vector3Create(0, 1, 0);
        FSpaceLandingState := 3; // Taking off
        FSpaceLandingProgress := 0.0;
      end;
    end;
  end;
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
  // F10: Toggle the 3D Alive Highlighter
  if (GetAsyncKeyState(VK_F10) and $1) <> 0 then
  begin
    if Assigned(FItemSelected) then
    begin
      if not Assigned(FAliveHighlighter3D) then
      begin
        FAliveHighlighter3D := TAliveHighlighter3D.Create;
        FAliveHighlighter3D.SetStartPosition(Vector3Create(0, 10, 0));
      end;
      FAliveHighlighter3D.Active := True;
      FAliveHighlighter3D.SendToTarget(FItemSelected.Position);
    end
    else
    begin
      if Assigned(FAliveHighlighter3D) then
      begin
        FAliveHighlighter3D.Active := False;
        FreeAndNil(FAliveHighlighter3D);
      end;
    end;
    FMouseLeftHandled := True;
  end;
  // ====================================================================
  // ALT + Q/E : Select previous/next object
  // --------------------------------------------------------------------
  // Moved here from Ctrl+Q/E so CTRL is free for the Black-Desert-style
  // cursor toggle while driving (see further below). Uses VK_MENU
  // (Alt) instead of VK_CONTROL. Edges on Q/E (one-shot via $1 mask)
  // so a single tap selects exactly one item. Exits the procedure
  // because selection also rewrites FItemSelected / CollisionHighlighting
  // and we don't want any further click handlers to fight over that
  // this frame.
  // ====================================================================
  if (GetAsyncKeyState(VK_MENU) and $8000) <> 0 then
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
  // ====================================================================
  // CTRL-EDGE HANDLING (Cursor Toggle while driving, Gizmo Cycle otherwise)
  // --------------------------------------------------------------------
  // Two responsibilities sharing the existing FCtrlWasPressed edge
  // detector so we don't need a new field:
  //
  //   * FIsDriving = True  -> Toggle OS cursor (Black Desert style).
  //                          Suppresses the gizmo cycle because gizmos
  //                          are not drawn while driving anyway.
  //   * FIsDriving = False -> Original editor gizmo-mode cycle
  //                          (Translate / Rotate / Scale / ...).
  //
  // NOTE: TYutaniFirstPersonController uses CTRL as a HELD key for
  // crouching, and TYutaniFlightController / TYutaniSpectatorController
  // use it for descending. A quick tap of CTRL will therefore also
  // flip the cursor once in those modes - the edge detector prevents
  // continuous toggling while the key is held. If you want a stricter
  // separation, gate the toggle on a controller-type allowlist
  // (Vehicle / ThirdPerson / RigidBody / Orbit).
  // ====================================================================
  if (GetAsyncKeyState(VK_CONTROL) and $8000) <> 0 then
  begin
    if not FCtrlWasPressed then
    begin
      FCtrlWasPressed := True;
      if FIsDriving and Assigned(FInputManager) then
      begin
        // Driving: toggle OS cursor (Black Desert style)
        if FInputManager.MouseLookActive then
          FInputManager.StopMouseLook               // Reveal OS cursor for UI clicks
        else
          FInputManager.StartMouseLook(FRaylibWnd); // Hide cursor, resume mouselook
      end
      else
      begin
        // Editor mode: original gizmo cycle behaviour
        if FGizmoMode = gmTranslate then
          FGizmoMode := gmRotate
        else if FGizmoMode = gmRotate then
          FGizmoMode := gmScale
        else if FGizmoMode = gmScale then
          FGizmoMode := gmUniformScale
        else if FGizmoMode = gmUniformScale then
          FGizmoMode := gmDragAndThrow
        else if FGizmoMode = gmDragAndThrow then
          FGizmoMode := gmNone
        else if FGizmoMode = gmNone then
          FGizmoMode := gmTranslate;
      end;
    end;
  end
  else
    FCtrlWasPressed := False;
  // ====================================================================
  // Split-Screen Toggle (F2)
  // --------------------------------------------------------------------
  // Toggles 2-player local couch-coop. When enabling, the first two
  // items in the scene become the avatars - useful for quick testing.
  // For production use, call EnableSplitScreen explicitly from your
  // VCL with the specific avatars you want.
  // ====================================================================
  if (GetAsyncKeyState(VK_F2) and $1) <> 0 then
  begin
    HandleF12SplitScreenToggle;
    FMouseLeftHandled := True;
  end;
  // ====================================================================
  // Exit Driving Mode (F12)
  // --------------------------------------------------------------------
  // F12 is the dedicated "leave vehicle / exit driving" key. It
  // releases the currently possessed avatar, restores the editor
  // cursor and smoothly blends the camera back to the editor orbit
  // view. Safe to call when not driving - it is a no-op in that case.
  // ====================================================================
  if (GetAsyncKeyState(VK_F12) and $1) <> 0 then
  begin
    if FIsDriving then
    begin
      if Assigned(FInputManager) then
        FInputManager.StopMouseLook;
      // Smooth blend from the avatar chase cam back to the editor
      // orbit view before we tear down the controller, otherwise the
      // camera snaps in a single frame.
      StartCameraBlendToEditor(0.8);
      FIsDriving := False;
      FPlayerVehicle := nil;
      FreeAndNil(FAvatarController);
    end;
    FMouseLeftHandled := True;
  end;
  // ====================================================================
  // Avatar Control (F11)
  // --------------------------------------------------------------------
  //   1. When NOT driving and an object is selected -> possess it using
  //      the controller type stored in FAvatarControllerType.
  //   2. When ALREADY driving a Vehicle controller -> rotate the chase
  //      cam by 45 degrees around the avatar.
  // ====================================================================
  // Shift+F11: cycle the selected controller type. Always allowed, even
  // while driving - the current controller is rebuilt in place so yaw
  // and pitch are preserved and the camera transition feels seamless.
  if ((GetAsyncKeyState(VK_SHIFT) and $8000) <> 0) and ((GetAsyncKeyState(VK_F11) and $1) <> 0) then
  begin
    case FAvatarControllerType of
      actVehicle:
        FAvatarControllerType := actThirdPerson;
      actThirdPerson:
        FAvatarControllerType := actFirstPerson;
      actFirstPerson:
        FAvatarControllerType := actFlight;
      actFlight:
        FAvatarControllerType := actSpectator;
      actSpectator:
        FAvatarControllerType := actOrbit;
      actOrbit:
        FAvatarControllerType := actRigidBody;
      actRigidBody:
        FAvatarControllerType := actVehicle;
    end;
    // Rebuild the controller in place if we are already driving so the
    // new type takes effect immediately without forcing a re-possess.
    if FIsDriving and Assigned(FAvatarController) and Assigned(FPlayerVehicle) then
    begin
      var SavedYaw := FAvatarController.CamYaw;
      var SavedPitch := FAvatarController.CamPitch;
      var SavedDist := FAvatarController.CamDist;
      FreeAndNil(FAvatarController);
      FAvatarController := CreateAvatarControllerOfType(FAvatarControllerType, FPlayerVehicle);
      FAvatarController.CamYaw := SavedYaw;
      FAvatarController.CamPitch := SavedPitch;
      FAvatarController.CamDist := SavedDist;
      // Trigger a smooth cinematic transition so the camera flies from
      // the old controller's view to the new controller's view instead
      // of snapping in a single frame.
      FAvatarController.BeginCameraTransition(0.6);
    end;
    FMouseLeftHandled := True;
  end
  else if (GetAsyncKeyState(VK_F11) and $1) <> 0 then
  begin
    // Refuse to start the single-player possess flow while split-screen
    // is active - the two modes share the FCamera pointer and would
    // fight over it. The user must call DisableSplitScreen (F2) first.
    if Assigned(FMultiPlayer) and FMultiPlayer.Active then
    begin
      FMouseLeftHandled := True;
    end
    else if Assigned(FItemSelected) then
    begin
      FGizmoMode := gmNone;
      if not FIsDriving then
      begin
        // MODE 1: Not driving yet -> possess the selected object using
        // the currently selected controller type.
        FIsDriving := True;
        FPlayerVehicle := FItemSelected;
        FPlayerVehicle.ActivateBody;
        FAvatarController := CreateAvatarControllerOfType(FAvatarControllerType, FPlayerVehicle);
        // Smooth cinematic fly-in from the editor orbit position to
        // the avatar chase position. Slightly longer than the swap
        // transition because the camera typically has further to go.
        FAvatarController.BeginCameraTransition(0.8);
        // Start mouselook so cursor deltas are converted to look input
        // for the freshly spawned controller.
        FInputManager.StartMouseLook(FRaylibWnd);
      end
      else if (FAvatarController is TYutaniVehicleController) then
      begin
        // MODE 2: Already driving a Vehicle controller -> rotate the
        // chase cam by 45 degrees around the avatar. The model offset
        // is adjusted by -45 degrees so the model itself stays put in
        // world space while only the camera swings.
        FAvatarController.CamYaw := FAvatarController.CamYaw + (Pi / 4.0);
        TYutaniVehicleController(FAvatarController).FVehicleModelOffset := TYutaniVehicleController(FAvatarController).FVehicleModelOffset - (Pi / 4.0);
        // Stop the vehicle immediately so it doesn't drift into the
        // old direction while the camera swings around.
        FPlayerVehicle.SetAngularVelocity(Vector3Create(0, 0, 0));
        FPlayerVehicle.SetLinearVelocity(Vector3Create(0, 0, 0));
      end;
      // For non-vehicle controllers while driving, F11 is a no-op now.
      // Use F12 to exit driving mode instead.
      // When nothing is selected, F11 is also a no-op - use F12 to exit.
      FMouseLeftHandled := True;
    end;
  end;
  ray := GetScreenToWorldRay(FMousePos, FCamera);
  // ====================================================================
  // SECOND LIFE STYLE CAMERA FOCUS (ALT + Left Click)
  // --------------------------------------------------------------------
  // Holding ALT and clicking an object sets the camera target to it.
  // If the object is dynamic, the camera target keeps following it.
  //
  // NOTE: Alt+Q/E (object selection) is handled earlier in this proc
  // and exits before we get here, so the two ALT bindings don't fight.
  // Plain ALT + LMB still triggers focus tracking.
  // ====================================================================
  bAltIsDown := (GetAsyncKeyState(VK_MENU) and $8000) <> 0;
  if bAltIsDown then
  begin
    if not FAltWasPressed then
      FAltWasPressed := True;
    if bLeftMouseClicked then
    begin
      // Find the closest object under the mouse to focus on
      ClosestFocusActor := nil;
      ClosestFocusDist := 1e9;
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
        if TempHit.hit and (TempHit.distance < ClosestFocusDist) then
        begin
          ClosestFocusDist := TempHit.distance;
          ClosestFocusActor := FItems[i];
        end;
      end;
      if Assigned(ClosestFocusActor) then
        FFocusTrackingActor := ClosestFocusActor
      else
      begin
        // Clicked empty space -> Focus on the ground point
        FFocusTrackingActor := nil;
        groundBox.min := Vector3Create(-10000, -0.1, -10000);
        groundBox.max := Vector3Create(10000, 0.1, 10000);
        hitInfo := GetRayCollisionBox(ray, groundBox);
        if hitInfo.hit then
          FCamera.target := hitInfo.point;
      end;
      FMouseLeftHandled := True;
    end;
    Exit; // Prevent other interactions while focusing
  end
  else
  begin
    if FAltWasPressed then
    begin
      FAltWasPressed := False;
      // Stop tracking the actor when ALT is released
      FFocusTrackingActor := nil;
    end;
  end;
  // AliveHighlighter3d
  var GroundRayBox: TBoundingBox;
  GroundRayBox.min := Vector3Create(-1000, -0.1, -1000);
  GroundRayBox.max := Vector3Create(1000, 0.1, 1000);
  var GroundHit := GetRayCollisionBox(ray, GroundRayBox);
  if GroundHit.hit then
    FMouseWorldPos := Vector3Create(GroundHit.point.x, 2.0, GroundHit.point.z);
  // ====================================================================
  // 3D TRACKBAR DRAGGING (must run before button hover logic so a held
  // drag keeps driving ItemPosition even if the cursor leaves the
  // actor's hit box)
  // --------------------------------------------------------------------
  // When FDraggingTrackbar is set, the user is currently holding LMB on
  // a stTrackbar actor. Every frame we recompute the mouse X position
  // on the actor's local plane and map it to a 0..1000 promille value
  // written to Actor.ItemPosition. The render block picks that up and
  // moves the knob.
  // ====================================================================
  if Assigned(FDraggingTrackbar) then
  begin
    if bLeftMouseDown then
    begin
      UpdateTrackbarFromMouse(FDraggingTrackbar);
      FMouseLeftHandled := True;
      // Suppress further interaction while dragging
      Exit;
    end
    else
    begin
      // Mouse released - end drag
      FDraggingTrackbar.IsPressed := False;
      FDraggingTrackbar := nil;
      FMouseLeftHandled := True;
    end;
  end;
  // ====================================================================
  // 3D BUTTON / TRACKBAR / PROGRESSBAR INTERACTION LOGIC (Hover & Click)
  // Handles UI clicks independent from physics tools. The hover scan
  // below now also picks up stTrackbar and stProgressBar so the hover
  // color lerp works for those too.
  // ====================================================================
  var ClosestButtonDist: Single := 1e9;
  var HoveredButton: TA3DComponent := nil;
  // Reset hover states for all interactive UI actors
  for i := 0 to High(FItems) do
    if Assigned(FItems[i]) and ((FItems[i].ShapeType in [stButton, stTrackbar, stProgressBar]) or FItems[i].IsPianoKey) then
      FItems[i].IsHovered := False;
  // Find the closest interactive UI actor under the mouse cursor
  for i := 0 to High(FItems) do
  begin
    if Assigned(FItems[i]) and ((FItems[i].ShapeType in [stButton, stTrackbar, stProgressBar]) or FItems[i].IsPianoKey) then
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
      // ----------------------------------------------------------------
      // TRACKBAR: Start a drag instead of firing OnClick. The drag is
      // driven by FDraggingTrackbar at the top of this procedure, so
      // we set the flag, immediately update ItemPosition from the
      // current mouse position, and bail out for this frame.
      // ----------------------------------------------------------------
      if HoveredButton.ShapeType = stTrackbar then
      begin
        FDraggingTrackbar := HoveredButton;
        HoveredButton.IsPressed := True;
        UpdateTrackbarFromMouse(HoveredButton);
        FMouseLeftHandled := True;
        Exit;
      end;
      // ----------------------------------------------------------------
      // BUTTON / PIANO KEY / PROGRESS BAR: Original click behaviour
      // (progress bars just light up; they have no OnClick).
      // ----------------------------------------------------------------
      HoveredButton.IsPressed := True;
      FMouseLeftHandled := True;
      if HoveredButton.IsPianoKey and Assigned(FYutaniAudio) then
        FYutaniAudio.PlayLiveNote(HoveredButton.MidiNote);
    end
    else if (not FMouseLeftPressed) and HoveredButton.IsPressed then
    begin
      // Mouse released -> Trigger OnClick (only for actual buttons;
      // trackbars / progress bars have no OnClick handler)
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
        if Assigned(FItems[i]) and ((FItems[i].ShapeType in [stButton, stTrackbar, stProgressBar]) or FItems[i].IsPianoKey) then
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
        // Force the physics engine to accept the new shape size immediately!
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
        // Use Actor.Scale directly so the gizmo arms match the visual mesh size perfectly
        GScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 5.0, 1.0, 100.0);
        GScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 5.0, 1.0, 100.0);
        GScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 5.0, 1.0, 100.0);
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
      end
      else if FGizmoMode = gmUniformScale then
      begin
        if CheckGizmoCornerHit(FItemSelected.Position, Vector3Create(GScaleX, GScaleY, GScaleZ), ClickRadius, ray, FGizmoAxis) then
        begin
          FGizmoDragging := True;
          FGizmoStartMouse := FMousePos;
          FGizmoStartVal := FItemSelected.Scale; // Save the initial Scale
          FGizmoStartPos := FItemSelected.Position; // Save position for Y-Lift
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

// ============================================================================
// UpdateTrackbarFromMouse
// ----------------------------------------------------------------------------
// Raycasts the current mouse position onto a thin slab that sits on the
// trackbar actor's local X axis (at the actor's Y and Z). The hit point's
// X is then mapped from [left edge .. right edge] of the base block to
// [0 .. 1000] promille and written to Actor.ItemPosition. The render
// block reads ItemPosition every frame to move the knob.
//
// This is called from HandleDesktopInput both on the initial click and
// every frame while the drag is held (via FDraggingTrackbar), so the
// knob tracks the cursor smoothly even if the cursor leaves the actor's
// hit box.
// ============================================================================
procedure TYutaniRaylibSandbox.UpdateTrackbarFromMouse(Actor: TA3DComponent);
var
  LocalRay: TRay;
  Slab: TBoundingBox;
  Hit: TRayCollision;
  T: Single;
  NewPromille: Integer;
  Callback: TNotifyEvent;
  ActorRef: TA3DComponent;
begin
  if not Assigned(Actor) then
    Exit;

  // Build a thin slab on the actor's X axis. We extend it a bit in X so
  // the user can drag past either edge without losing the grab, and
  // make it 2 units thick in Y and Z so the ray reliably hits it from
  // any reasonable camera angle.
  Slab.min := Vector3Create(Actor.Position.x - Actor.Scale.x * 0.5 - 1.0, Actor.Position.y - 1.0, Actor.Position.z - 1.0);
  Slab.max := Vector3Create(Actor.Position.x + Actor.Scale.x * 0.5 + 1.0, Actor.Position.y + 1.0, Actor.Position.z + 1.0);

  LocalRay := GetScreenToWorldRay(FMousePos, FCamera);
  Hit := GetRayCollisionBox(LocalRay, Slab);
  if not Hit.hit then
    Exit;

  // Map Hit.point.x from [leftEdge .. rightEdge] to [0 .. 1]
  T := (Hit.point.x - (Actor.Position.x - Actor.Scale.x * 0.5)) / Actor.Scale.x;
  // Clamp to [0..1] so the knob never escapes the base block
  if T < 0 then
    T := 0;
  if T > 1 then
    T := 1;

  NewPromille := Round(T * 1000.0);

  // Only fire the OnChange callback when the promille value actually
  // changed this frame. This avoids flooding the VCL message queue
  // when the user holds the mouse still on the knob without moving.
  if NewPromille = Actor.ItemPosition then
    Exit;

  // SetItemPosition clamps to 0..1000 internally for stTrackbar.
  Actor.ItemPosition := NewPromille;

  // Fire the value-changed callback if the caller registered one.
  // We marshal it to the VCL thread via TThread.Queue so the user's
  // callback can safely touch VCL controls (Labels, other actors, etc).
  // Sender is the actor itself - the callback can read Actor.ItemPosition
  // and convert to its own [Min..Max] range via TVCL3D.GetTrackbarValue.
  if not Assigned(Actor.OnChange) then
    Exit;

  Callback := Actor.OnChange;
  ActorRef := Actor;
  TThread.Queue(nil,
    procedure
    begin
      Callback(ActorRef);
    end);
end;

procedure TYutaniRaylibSandbox.HandlePopupInput;
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

procedure TYutaniRaylibSandbox.ExecutePopupAction(Index: Integer);
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
      FYutaniAudio.PlaySoundEffect('ressources\audio\impactPlank_medium_000.wav', 1.0);
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

procedure TYutaniRaylibSandbox.DeleteSelectedActor;
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

function TYutaniRaylibSandbox.CheckGizmoCornerHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
var
  BBox: TBoundingBox;
  Hit: TRayCollision;
  InvRot: TQuaternion;
  LocalRay: TRay;
  LocalDir: TVector3;
  R: Single;
begin
  Result := False;
  Axis := 0;
  // Radius for the corner click-box
  R := RayRadius + 0.3;
  InvRot := QuaternionInvert(FItemSelected.Quaternion);
  LocalRay.position := Vector3RotateByQuaternion(Vector3Subtract(Ray.position, Pos), InvRot);
  LocalDir := Vector3RotateByQuaternion(Ray.direction, InvRot);
  LocalRay.direction := Vector3Normalize(LocalDir);
  // Check all 8 corners of the bounding box
  BBox.min := Vector3Create(-Scale.x - R, -Scale.y - R, -Scale.z - R);
  BBox.max := Vector3Create(Scale.x + R, Scale.y + R, Scale.z + R);
  Hit := GetRayCollisionBox(LocalRay, BBox);
  if Hit.hit then
  begin
    Result := True;
    // We only need to know it hit ANY corner, so we just return Axis 1 (Active state)
    Axis := 1;
    Exit;
  end;
end;

procedure TYutaniRaylibSandbox.UpdateGizmoCornerInteraction;
var
  MouseDeltaX, MouseDeltaY: Single;
  ScaleChange: Single;
  EndScale: TVector3;
  OldScaleY, NewScaleY, YLift: Single;
  CamForward, CamRight, CamUp, MoveDir: TVector3;
begin
  MouseDeltaX := FMousePos.x - FGizmoStartMouse.x;
  MouseDeltaY := FMousePos.y - FGizmoStartMouse.y;
  if Abs(MouseDeltaX) < 0.5 then
    MouseDeltaX := 0;
  if Abs(MouseDeltaY) < 0.5 then
    MouseDeltaY := 0;
  // Calculate proper 3D screen projection regardless of camera angle
  CamForward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));
  CamRight := Vector3Normalize(Vector3CrossProduct(CamForward, FCamera.up));
  CamUp := Vector3Normalize(Vector3CrossProduct(CamRight, CamForward));
  // Project mouse movement onto screen space directions
  MoveDir := Vector3Add(Vector3Scale(CamRight, MouseDeltaX * 0.1), Vector3Scale(CamUp, -MouseDeltaY * 0.1));
  // We want to scale outwards when pulling to the right/up, and inwards when pulling left/down
  // The magnitude of the movement defines the scale change
  ScaleChange := (MoveDir.x + MoveDir.y) * 0.05;
  // Fallback if movement is weird
  if ScaleChange = 0 then
    ScaleChange := (MouseDeltaX * 0.01) + (-MouseDeltaY * 0.01);
  EndScale := FGizmoStartVal;
  // Apply uniform scale equally to X, Y, and Z
  var NewSize := EnsureRange(EndScale.x + ScaleChange, 0.05, 100);
  EndScale.x := NewSize;
  EndScale.y := NewSize;
  EndScale.z := NewSize;
  FItemSelected.Scale := EndScale;
  // Y-LIFT STABILIZATION (Same logic as normal Scale)
  OldScaleY := FGizmoStartVal.y;
  NewScaleY := EndScale.y;
  YLift := (NewScaleY - OldScaleY) * 0.5;
  FItemSelected.SetPosition(Vector3Create(FGizmoStartPos.x, FGizmoStartPos.y + YLift, FGizmoStartPos.z));
end;

procedure TYutaniRaylibSandbox.UpdateGizmoInteraction;
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
  // Variables for proper 3D Mouse Projection
  CamRight, CamUp: TVector3;
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
    // --- Correct 3D projection for every axis ---
    CamRight := Vector3Normalize(Vector3CrossProduct(CamForward, FCamera.up));
    CamUp := Vector3Normalize(Vector3CrossProduct(CamRight, CamForward));
    MoveDir := Vector3Add(Vector3Scale(CamRight, MouseDeltaX * 0.1), Vector3Scale(CamUp, -MouseDeltaY * 0.1));
    CamDot := Vector3DotProduct(WorldAxis, MoveDir);
    LocalMove := Vector3Scale(WorldAxis, CamDot);
    // Store old position before applying the new one
    OldBasePos := FItemSelected.Position;
    NewPos := Vector3Add(FGizmoStartVal, LocalMove);
    FItemSelected.SetPosition(NewPos);
    // ====================================================================
    // QUICK & DIRTY PIANO LINKING:
    // If we are moving the Piano Base, move all keys with it!
    // --------------------------------------------------------------------
    // TPiano is no longer owned by the sandbox, so we identify the piano
    // base by its Name ('PianoBody') and find the keys via the IsPianoKey
    // flag. This keeps the feature working regardless of who owns the
    // TPiano instance.
    // ====================================================================
    if Assigned(FItemSelected) and (FItemSelected.Name = 'PianoBody') then
    begin
      DeltaPos := Vector3Subtract(NewPos, OldBasePos);
      for i := 0 to High(FItems) do
      begin
        if Assigned(FItems[i]) and FItems[i].IsPianoKey then
          FItems[i].SetPosition(Vector3Add(FItems[i].Position, DeltaPos));
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
    // Now that models are perfectly centered, they behave like primitives.
    // We lift the Y-Position by half the height change to keep the bottom on the ground.
    if FGizmoAxis = 2 then
    begin
      OldScaleY := FGizmoStartVal.y;
      NewScaleY := EndScale.y;
      YLift := (NewScaleY - OldScaleY) * 0.5;
      FItemSelected.SetPosition(Vector3Create(FGizmoStartPos.x, FGizmoStartPos.y + YLift, FGizmoStartPos.z));
    end;
  end
  else if FGizmoMode = gmUniformScale then
  begin
    UpdateGizmoCornerInteraction;
  end;
end;

function TYutaniRaylibSandbox.CheckGizmoAxisHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
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

function TYutaniRaylibSandbox.CheckGizmoRingHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
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

function TYutaniRaylibSandbox.CheckGizmoScaleHit(Pos, Scale: TVector3; RayRadius: Single; Ray: TRay; out Axis: Integer): Boolean;
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

procedure TYutaniRaylibSandbox.SetSelectedActor(AActor: TA3DComponent);
begin
  FItemSelected := AActor;
end;

function TYutaniRaylibSandbox.GetActorBoundingBoxWS(Actor: TA3DComponent): TBoundingBox;
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

procedure TYutaniRaylibSandbox.SpawnAtMouse(Pos: TVector3);
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
    Obj.ModelPath := FLastLoadedModelPath;
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
  Obj.Friction := 0.4;
  Obj.Restitution := 0.2;
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
  // If Beam effect is active, force the object to be invisible from frame 1!
  // This prevents the object from flashing visible before the materialize effect triggers.
  if FSpawnEffectType = spefBeam then
  begin
    Obj.Visible := False;
    Obj.ActAlpha := 0.0;
    Obj.TargetAlpha := 0.0;
  end;
  FItems[oldLen] := Obj;
  FYutaniAudio.PlaySoundEffect('ressources\audio\impactPlank_medium_000.wav', 1.0);
  TriggerSpawnEffect(Vector3Create(JPos.x, JPos.y, JPos.z), Obj);
  DoActorSpawned(Obj, oldLen);
end;

procedure TYutaniRaylibSandbox.LoadCustomModel(const FilePath: string);
begin
  FLock.Enter;
  try
    FQueuedModelPath := FilePath;
    FLoadModelQueued := True;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.LoadModelInThread(const FilePath: string);
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
    FLastLoadedModelPath := FilePath;
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
    FLastLoadedModelPath := '';
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

procedure TYutaniRaylibSandbox.UpdateGame;
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
  // Poll mouselook every frame so cursor deltas are converted into look
  // input for whichever avatar controller is currently active. The call
  // is a no-op when mouselook has not been started via StartMouseLook.
  if Assigned(FInputManager) then
    FInputManager.PollMouseLook;
  // Process Thread-safe Dematerialize Queue
  if Length(FDematerializeQueue) > 0 then
  begin
    var LocalQueue: TArray<TDematerializeRequest>;
    FLock.Enter;
    try
      LocalQueue := Copy(FDematerializeQueue, 0, Length(FDematerializeQueue));
      FDematerializeQueue := nil;
    finally
      FLock.Leave;
    end;
    for var Req in LocalQueue do
      if Assigned(Req.Actor) then
        ExecuteDematerializeActor(Req.Actor);
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
  // Drive the cinematic world-swap transition. No-op when no
  // transition is active. Must be called every frame so the timing
  // stays smooth - skipping it during paused simulation would freeze
  // the warp mid-flight and break the user's sense of progress.
  if Assigned(FWorldTransition) then
    FWorldTransition.Update(dt);
  if Assigned(FMPVPlayer) then
    FMPVPlayer.Update;
  // Slow Motion calculation: Scale time if active, otherwise normal speed
  if FSlowMotionActive then
    FTimeScale := FSavedTimeScale  //slowmotion
  else
    FTimeScale := 1.0; // Normal speed
  // Calculate physics delta time based on slow motion scale
  var PhysDt: Single := dt * FTimeScale;
  if Assigned(FNanoFog) then
    FNanoFog.Update(PhysDt);
  if FSimulationRunning then
  begin
    if Assigned(FSpaceWorld) and (FCurrentWorldBase = wbSpace) then
      FSpaceWorld.Update(dt, FCamera.position, FTimeScale);
    if Assigned(FHolodeckWorld) and (FCurrentWorldBase = wbHolodeck) then
      FHolodeckWorld.Update(dt, FCamera.position, FDayTime);
    if Assigned(FLandWorld) and (FCurrentWorldBase = wbLand) then
      FLandWorld.Update(dt, FCamera.position, FDayTime, FDaySpeed, FDayNightRhythmActive);
    if Assigned(FYourWorld) and (FCurrentWorldBase = wbYourWorld) then
      FYourWorld.Update(dt, FCamera.position, FDayTime, FDaySpeed, FDayNightRhythmActive);
    if Assigned(FParticleEngine) then
      FParticleEngine.Update(PhysDt);
  end;
  if Assigned(FParticleEngine) and (Length(FParticleSpawnQueue) > 0) then
  begin
    FLock.Enter;
    try
      while Length(FParticleSpawnQueue) > 0 do
      begin
        var Req := FParticleSpawnQueue[High(FParticleSpawnQueue)];
        SetLength(FParticleSpawnQueue, Length(FParticleSpawnQueue) - 1);
        if Req.IsSmoke then
          FParticleEngine.EmitSmoke(Req.Pos, Req.Count, Req.Color)
        else
          FParticleEngine.EmitExplosion(Req.Pos, Req.Count, Req.Color);
      end;
    finally
      FLock.Leave;
    end;
  end;
  // ==========================================
  // SPACE LANDING & PLANETARY CAM (F8 / F9)
  // ==========================================
  if FCurrentWorldBase = wbSpace then
  begin
    // --- SPACE LANDING ANIMATION (Runs every frame) ---
    if FSpaceLandingState > 0 then
    begin
      FSpaceLandingProgress := FSpaceLandingProgress + (GetFrameTime() * 0.8);
      if FSpaceLandingProgress > 1.0 then
        FSpaceLandingProgress := 1.0;
      var T: Single := FSpaceLandingProgress;
      T := T * T * (3 - 2 * T); // Smooth Ease-In-Out
      if FSpaceLandingState = 1 then // Approaching
      begin
        // Fly to the pre-calculated surface position
        FCamera.position := Vector3Add(Vector3Scale(FSpaceCamStartPos, 1.0 - T), Vector3Scale(FSpaceLandingTargetPos, T));
        FCamera.target := Vector3Add(Vector3Scale(FSpaceCamStartTarget, 1.0 - T), Vector3Scale(FSpaceLandingCamTargetCenter, T));
        FCamera.up := Vector3Add(Vector3Scale(Vector3Create(0, 1, 0), 1.0 - T), Vector3Scale(FSpaceLandingTargetUp, T));
        if FSpaceLandingProgress >= 1.0 then
        begin
          FSpaceLandingState := 2; // Landed
          // NOW we freeze the universe! The camera is already at the target position.
          if FSpaceLandingTargetIndex >= 0 then
            FSpaceWorld.InitiateLanding(FSpaceLandingTargetIndex, FCamera.target, FCamera.position);
        end;
      end
      else if FSpaceLandingState = 3 then // Taking off
      begin
        // We are already locked, so fly backwards from the current position
        FCamera.position := Vector3Add(Vector3Scale(FSpaceCamStartPos, 1.0 - T), Vector3Scale(FSpaceLandingTargetPos, T));
        FCamera.target := Vector3Add(Vector3Scale(FSpaceCamStartTarget, 1.0 - T), Vector3Scale(FCamera.position, T));
        FCamera.up := Vector3Add(Vector3Scale(FSpaceLandingTargetUp, 1.0 - T), Vector3Scale(Vector3Create(0, 1, 0), T));
        if FSpaceLandingProgress >= 1.0 then
        begin
          FSpaceLandingState := 0; // Free Fly
          FSpaceWorld.ReleaseLanding; // Unlock the planet
        end;
      end;
    end;
    // --- INPUT HANDLING ---
    // F8: Toggle Planetary Orbit Cam (instant orbit around planet)
    if (GetAsyncKeyState(VK_F8) and $1) <> 0 then
    begin
      if not FSpaceWorld.IsLanded then
      begin
        FSpacePlanetaryCam := not FSpacePlanetaryCam;
        if FSpacePlanetaryCam then
        begin
          var Idx: Integer;
          if FSpaceWorld.FindNearestPlanet(FCamera.position, Idx, Dist) then
            FSpaceWorld.InitiateLanding(Idx, FCamera.target, FCamera.position);
        end
        else
          FSpaceWorld.ReleaseLanding;
      end;
    end;
    // F9: Real Smooth Landing Approach / Takeoff
    if (GetAsyncKeyState(VK_F9) and $1) <> 0 then
    begin
      if FSpaceLandingState = 0 then
      begin
        // Start Approach
        var Idx: Integer;
        if FSpaceWorld.FindNearestPlanet(FCamera.position, Idx, Dist) and (Dist < 5000.0) then
        begin
          // DO NOT shift the universe yet! We fly to the planet's current position first.
          FSpaceLandingTargetIndex := Idx;
          FSpacePlanetaryCam := False;
          // Calculate target landing position (5 units above surface)
          var PlanetPos: TVector3;
          var PlanetRadius: Single;
          FSpaceWorld.GetPlanetInfo(Idx, PlanetPos, PlanetRadius);
          var SurfDir := Vector3Normalize(Vector3Subtract(FCamera.position, PlanetPos));
          if (IsNan(SurfDir.x)) or (IsNan(SurfDir.y)) or (IsNan(SurfDir.z)) then
            SurfDir := Vector3Create(0, 1, 0);
          FSpaceLandingTargetPos := Vector3Add(PlanetPos, Vector3Scale(SurfDir, PlanetRadius + 5.0));
          FSpaceLandingCamTargetCenter := PlanetPos; // Look at the center while flying there
          FSpaceLandingTargetUp := SurfDir;
          FSpaceCamStartPos := FCamera.position;
          FSpaceCamStartTarget := FCamera.target;
          FSpaceLandingState := 1; // Approaching
          FSpaceLandingProgress := 0.0;
        end;
      end
      else if FSpaceLandingState = 2 then
      begin
        // Start Takeoff
        FSpaceCamStartPos := FCamera.position;
        FSpaceCamStartTarget := FCamera.target;
        FSpaceLandingTargetPos := Vector3Add(FCamera.position, Vector3Scale(FCamera.up, 300.0));
        FSpaceLandingTargetUp := FCamera.up;
        FSpaceLandingState := 3; // Taking off
        FSpaceLandingProgress := 0.0;
      end;
    end;
  end;
  // ==========================================
  // PLANETARY SURFACE CAMERA (Active while landed)
  // ==========================================
  if (FCurrentWorldBase = wbSpace) and (FSpaceLandingState = 2) then
  begin
    var p: TPoint;
    GetCursorPos(p);
    var PlanetPos := FSpaceWorld.GetLandedPlanetPos();
    var PlanetRad: Single;
    FSpaceWorld.GetPlanetInfo(FSpaceWorld.FLandingTargetIndex, PlanetPos, PlanetRad);
    PlanetPos := FSpaceWorld.GetLandedPlanetPos(); //Frozen position
    // 1. Orbit Rotation with Middle Mouse Button
    if (GetAsyncKeyState(VK_MBUTTON) and $8000) <> 0 then
    begin
      if FDraggingRMB then
      begin
        var YawDelta := (p.x - FLastMouse.x) * 0.005;
        var PitchDelta := (p.y - FLastMouse.y) * 0.005;
        var ToCam := Vector3Subtract(FCamera.position, PlanetPos);
        Dist := Vector3Length(ToCam);
        Dir := Vector3Normalize(ToCam);
        // Yaw rotation (around global Y axis)
        var CosY := Cos(YawDelta);
        var SinY := Sin(YawDelta);
        Dir := Vector3Create(Dir.x * CosY - Dir.z * SinY, Dir.y, Dir.x * SinY + Dir.z * CosY);
        // Pitch rotation (tilt up/down)
        Dir.y := EnsureRange(Dir.y + PitchDelta, -0.95, 0.95);
        Dir := Vector3Normalize(Dir);
        FCamera.position := Vector3Add(PlanetPos, Vector3Scale(Dir, Dist));
        FCamera.up := Dir; // UP is always the surface normal
      end
      else
        FDraggingRMB := True;
    end
    else
      FDraggingRMB := False;
    FLastMouse := p;
    // 2. Zoom with Mouse Wheel
    var Wheel := GetMouseWheelMove();
    if Wheel <> 0 then
    begin
      var ToCam := Vector3Subtract(FCamera.position, PlanetPos);
      Dist := Vector3Length(ToCam);
      var MinDist := FSpaceWorld.GetLandedPlanetRadius() + 2.0;
      Dist := EnsureRange(Dist - Wheel * 10.0, MinDist, MinDist + 500.0);
      FCamera.position := Vector3Add(PlanetPos, Vector3Scale(Vector3Normalize(ToCam), Dist));
    end;
    // 3. Force Camera Target: always look at a point slightly ahead of
    //    us on the sphere surface so the horizon stays level while we
    //    walk along the planet.
    var SurfDir := Vector3Normalize(Vector3Subtract(FCamera.position, PlanetPos));
    if not IsNan(SurfDir.x) then
    begin
      FCamera.up := SurfDir;
      // Compute a forward vector based on the current view direction so
      // the camera keeps facing where the player was already looking.
      var CurrentForward := Vector3Normalize(Vector3Subtract(FCamera.target, FCamera.position));
      var DotP := Vector3DotProduct(CurrentForward, SurfDir);
      var ForwardOnTangent := Vector3Subtract(CurrentForward, Vector3Scale(SurfDir, DotP));
      if Vector3Length(ForwardOnTangent) < 0.1 then
      begin
        var TempUp := Vector3Create(0, 1, 0);
        if Abs(Vector3DotProduct(SurfDir, TempUp)) > 0.9 then
          TempUp := Vector3Create(1, 0, 0);
        ForwardOnTangent := Vector3CrossProduct(SurfDir, TempUp);
      end;
      ForwardOnTangent := Vector3Normalize(ForwardOnTangent);
      var TargetSurfDir := Vector3Normalize(Vector3Add(SurfDir, Vector3Scale(ForwardOnTangent, 0.3)));
      FCamera.target := Vector3Add(PlanetPos, Vector3Scale(TargetSurfDir, FSpaceWorld.GetLandedPlanetRadius() + 1.0));
    end;
  end;
  // Update Camera Target if we are tracking an actor (Second Life ALT focus)
  if Assigned(FFocusTrackingActor) then
  begin
    if not FFocusTrackingActor.FIsDead then
      FCamera.target := FFocusTrackingActor.Position
    else
      FFocusTrackingActor := nil;
    FCameraMoved := True;
  end;
  // ====================================================================
  // Update Avatar Controller
  // Drives the currently active controller if we are possessing an
  // object; otherwise releases it so the sandbox falls back to the
  // editor camera. The controller type is selected externally via
  // Shift+F11 and applied on the next F11 possess.
  // ====================================================================
  if FIsDriving and Assigned(FPlayerVehicle) and (not FPlayerVehicle.FIsDead) then
  begin
    FPlayerVehicle.ActivateBody;
    FAvatarController.Update(dt, FInputManager);
    FCameraMoved := True;
  end
  else if Assigned(FAvatarController) then
  begin
    // Clean up if the vehicle died or was deleted
    FIsDriving := False;
    FPlayerVehicle := nil;
    FreeAndNil(FAvatarController);
  end;
  // ====================================================================
  // Update Split-Screen Manager
  // Drives both player slots when split-screen is active. Mutually
  // exclusive with the single-player FAvatarController path above -
  // EnableSplitScreen refuses to start while FIsDriving, and the
  // single-player path is skipped here while split-screen is active
  // so the two never fight over the camera.
  // ====================================================================
  if Assigned(FMultiPlayer) and FMultiPlayer.Active then
  begin
    try
      FMultiPlayer.Update(dt, FInputManager);
      // Mirror player 0's camera onto FCamera so the rest of UpdateGame
      // (shadow camera centering, distance culling, etc) sees a sensible
      // view position even though we are not in the single-player flow.
      FCamera := FCam1;
      FCameraMoved := True;
    except
      on E: Exception do
      begin
        OutputDebugString(PChar('Split-screen UPDATE exception: ' + E.Message));
        // Tear down split-screen so subsequent frames do not keep
        // hitting the same exception.
        FMultiPlayer.DisableSplitScreen;
      end;
    end;
  end;
  // Advance the camera blend if it is active. This lerps FCamera from
  // a captured start state to the editor orbit position over a fixed
  // duration so the exit from avatar driving mode feels cinematic.
  UpdateCameraBlend(dt);
  HandleCameraInput;
  HandleDesktopInput;
  ProcessSpawnQueue(dt);
  ProcessCustomSpawnQueue(dt); // Process custom external spawns
  ProcessFractureQueue(dt);
  if Assigned(FAliveHighlighter3D) and FAliveHighlighter3D.Active then
    FAliveHighlighter3D.Update(dt, FMouseWorldPos);
  UpdateBomb(PhysDt); // Pass slowed down time to bomb timer
  if FSimulationRunning then
  begin
    try
      // ====================================================================
      // Handle Gravity for the active Avatar Controller
      // ====================================================================
      if Assigned(FAvatarController) then
        FAvatarController.Avatar.SetGravityFactor(0.0); // Handled internally by controllers now!
      QueryPerformanceCounter(StartTime);
      FEngine.Update(PhysDt); // Pass slowed down time to Jolt Physics
      QueryPerformanceCounter(EndTime);
      QueryPerformanceFrequency(Freq);
      FLastPhysicsTime := (EndTime - StartTime) * 1000.0 / Freq;
      FActiveBodies := 0;
      for i := 0 to High(FItems) do
      begin
        if Assigned(FItems[i]) and not FItems[i].FIsDead then
        begin
          var Vel := FItems[i].GetLinearVelocity;
          var SpeedSq := (Vel.x * Vel.x) + (Vel.y * Vel.y) + (Vel.z * Vel.z);
          if SpeedSq > 1.0 then
            Inc(FActiveBodies);
          // DESTRUCTION CHECK: Only fracture manually placed destructables!
          if FItems[i].IsDestructable and (FItems[i].Name <> 'Fragment') then
          begin
            // Only trigger fracture if it hits the ground really hard
            var HitGroundHard := (Vel.y < -15.0) and (FItems[i].Position.y <= 1.5);
            if HitGroundHard then
            begin
              TriggerFracture(FItems[i], Sqrt(SpeedSq));
              // Safely remove the old actor from Jolt Physics
              if FItems[i].FBodyID <> 0 then
              begin
                JPH_BodyInterface_RemoveAndDestroyBody(FEngine.BodyInterface, FItems[i].FBodyID);
                FItems[i].FBodyID := 0;
              end;
              FItems[i].FIsDead := True;
              Continue;
            end;
          end;
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
{  if (FSceneStartTime = 0) and (FHUDAnimY < 0) then
  begin
    FHUDAnimY := FHUDAnimY * (1.0 - dt * 6.0);
    if FHUDAnimY > -0.5 then
      FHUDAnimY := 0;
  end;     }
  FGizmoHoverAxis := 0;
  if FInitialized and Assigned(FItemSelected) and not FGizmoDragging and not FDragging and not FPopupOpen and (FGizmoMode <> gmNone) then
  begin
    HoverRay := GetScreenToWorldRay(FMousePos, FCamera);
    // Calculate default hover scale
    HoverScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 1.0, 1.0, 100.0);
    HoverScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 1.0, 1.0, 100.0);
    HoverScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 1.0, 1.0, 100.0);
    if FItemSelected.ShapeType = stModel then
    begin
      HoverScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 5.0, 1.0, 150.0);
      HoverScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 5.0, 1.0, 150.0);
      HoverScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 5.0, 1.0, 150.0);
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
    end
    else if FGizmoMode = gmUniformScale then
    begin
      if CheckGizmoCornerHit(FItemSelected.Position, Vector3Create(HoverScaleX, HoverScaleY, HoverScaleZ), 0.4, HoverRay, HoverAxis) then
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
        FItems[i].CollisionHighlighting := IsTeal or (FItems[i] = FItemSelected) and (not FIsDriving) and (FGizmoMode <> gmNone);
      end;
    end;
  end
  else
  begin
    for i := 0 to High(FItems) do
      if Assigned(FItems[i]) then
        FItems[i].CollisionHighlighting := (FItems[i] = FItemSelected) and (not FIsDriving) and (FGizmoMode <> gmNone);
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
  // If an object was moved via a gizmo this frame, the shadow map must
  // be re-rendered so the shadow stays in sync with the new transform.
  if FGizmoDragging or FDragging then
    ShadowNeedsUpdate := True;
  // Hand the dirty flag down to RenderShadowMap so it can skip the
  // expensive depth pass when nothing relevant changed this frame.
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
  // NEW: Push the same shadow view/proj matrices + shadow map into
  // FShadowFloorShader so the shadow plane samples the same shadow map
  // as the main lighting pass.
  if FShadowFloorEnabled and (FShadowFloorShader.id > 0) then
  begin
    SetShaderValueMatrix(FShadowFloorShader, FShadowFloorLightViewLoc, LightViewMat);
    SetShaderValueMatrix(FShadowFloorShader, FShadowFloorLightProjLoc, LightProjMat);
    SetShaderValueTexture(FShadowFloorShader, FShadowFloorShadowMapLoc, FShadowMap.texture);
    SetShaderValue(FShadowFloorShader, FShadowFloorShadowBiasLoc, @TempBias, SHADER_UNIFORM_FLOAT);
  end;
  // CRITICAL: Remove dead actors from the list to prevent them
  // from clogging up Jolt's body count and freezing in mid-air!
  for i := High(FItems) downto 0 do
  begin
    if Assigned(FItems[i]) and FItems[i].FIsDead then
    begin
      if FItems[i] = FItemSelected then
      begin
        FItemSelected := nil;
        DoObjectSelected(nil);
      end;
      // Free user data
      if FItems[i].UserData <> nil then
        Dispose(PItemData(FItems[i].UserData));
      FItems[i].Free;
      // Remove from array without leaving a gap
      for var j := i to High(FItems) - 1 do
        FItems[j] := FItems[j + 1];
      SetLength(FItems, Length(FItems) - 1);
    end;
  end;
end;

procedure TYutaniRaylibSandbox.RenderGame;
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
  // Draw the cinematic world-swap overlay on top of the 3D scene but
  // BELOW the GUI / split-screen divider / popup. The transition is a
  // pure 2D overlay - it does not need a depth buffer and it must not
  // cover the popup menu (otherwise the user can't cancel a switch by
  // right-clicking). When no transition is active, Render() is a no-op.
  if Assigned(FWorldTransition) then
    FWorldTransition.Render;
  // Draw a vertical divider line down the middle when split-screen is
  // active so the user can immediately see that the screen is split,
  // even if both halves happen to show a similar view.
  if Assigned(FMultiPlayer) and FMultiPlayer.Active then
  begin
    var MidX: Single := GetScreenWidth() / 2.0;
    var ScrH: Integer := GetScreenHeight();
    // A bright 2px-wide line so it stands out against any background.
    DrawRectangle(Trunc(MidX) - 1, 0, 3, ScrH, Fade(WHITE, 0.85));
    DrawText('P1', Trunc(MidX) - 30, ScrH - 30, 20, WHITE);
    DrawText('P2', Trunc(MidX) + 10, ScrH - 30, 20, WHITE);
  end;
  DrawGUI;
  DrawNativePopup;
  EndDrawing();
  if FRaylibWnd <> 0 then
    RedrawWindow(FRaylibWnd, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW);
end;

procedure TYutaniRaylibSandbox.RenderShadowMap;
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
end;

procedure TYutaniRaylibSandbox.DrawSceneShadows;
var
  i: Integer;
  Actor: TA3DComponent;
  Pos: TVector3;
  Axis: TVector3;
  Angle: Single;
begin
  // World-specific floor shadow. Each extracted world draws its own
  // floor plane in solid black for the shadow depth pass. Space has
  // no floor so it skips this step.
  if FCurrentWorldBase = wbHolodeck then
    FHolodeckWorld.RenderShadows
  else if FCurrentWorldBase = wbLand then
    FLandWorld.RenderShadows
  else if FCurrentWorldBase = wbYourWorld then
    FYourWorld.RenderShadows
  else if FCurrentWorldBase <> wbSpace then
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
  if (FCurrentWorldBase = wbSpace) and Assigned(FSpaceWorld) then
    FSpaceWorld.RenderShadows;
end;

procedure TYutaniRaylibSandbox.Render3DScene;
var
  SavedCam: TCamera3D;
  FullW, HalfW, FullH: Integer;
begin
  // If split-screen is active, render the scene twice - once for each
  // player's camera, clipped to the left/right half of the window via
  // rlViewport. The viewport is restored to full screen afterwards so
  // subsequent 2D passes (DrawGUI, DrawNativePopup) cover the whole
  // window.
  if (not Assigned(FMultiPlayer)) or (not FMultiPlayer.Active) then
  begin
    // Single-player mode - clear the override flags so the core pass
    // uses the full-window aspect (BeginMode3D's default).
    FSplitScreenVPW := 0;
    FSplitScreenVPH := 0;
    Render3DSceneCore;
    Exit;
  end;
  SavedCam := FCamera;
  try
    try
      FullW := GetScreenWidth();
      HalfW := FullW div 2;
      FullH := GetScreenHeight();
      // --- Player 0: left half of the screen ---
      // Set the viewport dims so Render3DSceneCore can override the
      // perspective projection with the correct half-width aspect.
      // Without this override, BeginMode3D uses the full-window
      // aspect and the scene looks horizontally compressed in the
      // half-width viewport.
      FSplitScreenVPW := HalfW;
      FSplitScreenVPH := FullH;
      rlViewport(0, 0, HalfW, FullH);
      FCamera := FCam1;
      Render3DSceneCore;
      // --- Player 1: right half of the screen ---
      rlViewport(HalfW, 0, FullW - HalfW, FullH);
      FCamera := FCam2;
      Render3DSceneCore;
    except
      on E: Exception do
      begin
        OutputDebugString(PChar('Split-screen RENDER exception: ' + E.Message));
        // Tear down so we do not keep crashing on subsequent frames.
        FMultiPlayer.DisableSplitScreen;
      end;
    end;
    // Restore full-screen viewport for the 2D UI passes that follow.
    rlViewport(0, 0, FullW, FullH);
    // Clear the override flags so the rest of the frame uses the
    // full-window aspect again.
    FSplitScreenVPW := 0;
    FSplitScreenVPH := 0;
  finally
    FCamera := SavedCam;
  end;
end;

procedure TYutaniRaylibSandbox.Render3DSceneCore;
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
  // Split-screen projection override. BeginMode3D always uses the
  // full-window aspect (CORE.Window.screen.width / height) for its
  // perspective matrix, so when we've clipped the viewport to half
  // width via rlViewport the scene looks horizontally compressed
  // (everything reads as "too tall / stretched"). When the
  // FSplitScreenVP* fields are non-zero we replace the top of the
  // projection stack with a matrix computed from the correct aspect.
  // EndMode3D's popMatrix later cleans up our replacement cleanly.
  if FSplitScreenVPW > 0 then
  begin
    var OverrideProj: TMatrix := MatrixPerspective(FCamera.fovy * DEG2RAD, FSplitScreenVPW / FSplitScreenVPH, 0.01, 10000.0);
    rlSetMatrixProjection(OverrideProj);
  end;
  if FIsLoadingWorld and (not (Assigned(FWorldTransition) and FWorldTransition.Active and (FWorldTransition.Phase = tpOutro))) then
  begin
    // Loading state - just render the skybox so we don't see a void.
    // EXCEPT when the cinematic transition is in tpOutro: then we
    // need the OLD world to render normally so the warp effect can
    // fade it out gradually. Without this exception the old world
    // vanishes the moment SetWorldBase is called (FIsLoadingWorld
    // becomes True instantly) and the user sees black + warp overlay
    // instead of "old world fading into warp".
    if FSkyboxModel.meshes <> nil then
    begin
      rlDisableDepthMask();
      var BlackSkyColor: TColorB := BLACK;
      DrawModel(FSkyboxModel, FCamera.position, 1.0, BlackSkyColor);
      rlEnableDepthMask();
    end;
  end
  else
  begin
    // World-specific rendering (skybox + floor + clouds + grid).
    // Each extracted world owns its own depth-mask / shader-state
    // management, so the Core just dispatches to the active world and
    // lets it handle everything.
    if FCurrentWorldBase = wbSpace then
    begin
      if Assigned(FSpaceWorld) then
        FSpaceWorld.Render(FCamera);
    end
    else if FCurrentWorldBase = wbHolodeck then
    begin
      FHolodeckWorld.Render(FCamera, FSkyboxModel);
    end
    else if FCurrentWorldBase = wbLand then
    begin
      var SunAngle: Single := Lerp(-90, 270, FDayTime) * DEG2RAD;
      var nDaytime: Single := Sin(SunAngle);
      FLandWorld.Render(FCamera, nDaytime);
    end
    else if FCurrentWorldBase = wbYourWorld then
    begin
      FYourWorld.Render(FCamera);
    end
    else if FCurrentWorldBase = wbIsland then
    begin
      // Island still uses inline rendering + Core-owned skybox/cloud
      // assets. Extract into Yutani.Worlds.Island later.
      if FSkyboxModel.meshes <> nil then
      begin
        rlDisableDepthMask();
        ViewMat := GetCameraMatrix(FCamera);
        ProjMat := MatrixPerspective(FCamera.fovy * DEG2RAD, GetScreenWidth() / GetScreenHeight(), 0.01, 1000.0);
        SetShaderValueMatrix(FSkyboxShader, FSkyboxViewLoc, ViewMat);
        SetShaderValueMatrix(FSkyboxShader, FSkyboxProjLoc, ProjMat);
        if FSkyboxTex.id > 0 then
          FSkyboxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FSkyboxTex;
        rlDisableBackfaceCulling();
        DrawModel(FSkyboxModel, FCamera.position, 1.0, WHITE);
        rlEnableBackfaceCulling();
        rlEnableDepthMask();
      end;
      if Assigned(FIslandWorld) then
        FIslandWorld.Draw(FCamera, FDayTime);
      if (FCloudModel.meshes <> nil) then
      begin
        BeginShaderMode(FCloudShader);
        DrawModel(FCloudModel, Vector3Create(FCamera.position.x, 150, FCamera.position.z), 1.0, WHITE);
        EndShaderMode();
      end;
    end;
  end;
  // 4. Draw Actors (Your physics objects)
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
        // 1. Determine the exact mesh size using the original model matrix
        var BBox := GetModelBoundingBox(Actor.FModel);
        var MeshW := BBox.max.x - BBox.min.x;
        var MeshH := BBox.max.y - BBox.min.y;
        var MeshD := BBox.max.z - BBox.min.z;
        var MaxDim := Max(MeshW, Max(MeshH, MeshD));
        if MaxDim <= 0 then
          MaxDim := 1.0;
        // 2. Calculate the base scale that the Ghost preview uses
        var BaseDrawScale := 1.0 / MaxDim;
        // 3. Calculate the offset so it sits perfectly centered in the Jolt collider
        var CenterX := ((BBox.max.x + BBox.min.x) / 2) * BaseDrawScale;
        var CenterZ := ((BBox.max.z + BBox.min.z) / 2) * BaseDrawScale;
        var NormMinY := BBox.min.y * BaseDrawScale;
        var OffsetY := -NormMinY - (MeshH * BaseDrawScale * 1.0) + 0.5;
        // 4. Apply translations
        rlTranslatef(-CenterX, OffsetY, -CenterZ);
        // 5. Update shader matrix (required for correct shadow mapping)
        ModelMat := rlGetMatrixTransform();
        SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
        // 6. Pass the diffuse color to the shader
        var TintCol: TColorB := GetActorColor(Actor);
        ColorShaderVec[0] := TintCol.r / 255.0;
        ColorShaderVec[1] := TintCol.g / 255.0;
        ColorShaderVec[2] := TintCol.b / 255.0;
        ColorShaderVec[3] := Actor.ActAlpha;
        SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
        // 7. EXACT GHOST LOGIC: Save matrix, set to Identity, draw, restore!
        var OldTransform: TMatrix := Actor.FModel.transform;
        Actor.FModel.transform := MatrixIdentity();
        // 8. Draw the model with DrawModelEx.
        var FinalScaleX := (BaseDrawScale * Actor.Scale.x) + 1;
        var FinalScaleY := (BaseDrawScale * Actor.Scale.y) + 1;
        var FinalScaleZ := (BaseDrawScale * Actor.Scale.z) + 1;
        DrawModelEx(Actor.FModel, Vector3Create(0, 0, 0), Vector3Create(0, 0, 0), 0, Vector3Create(FinalScaleX, FinalScaleY, FinalScaleZ), Fade(TintCol, Actor.ActAlpha));
        // 9. Restore original matrix so the model keeps its internal scale for the next frame
        Actor.FModel.transform := OldTransform;
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
          if Actor.IsPressed then
            rlTranslatef(0, -0.08, 0);
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
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
          // other forms -------------
        else if (Actor.ShapeType = stSphere) then
        begin
          var SphereScale: Single := Max(Actor.Scale.x, Max(Actor.Scale.y, Actor.Scale.z)) * 0.5;
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          DrawModel(FSphereModel, Vector3Create(0, 0, 0), SphereScale, GetActorColor(Actor));
        end
        else if Actor.ShapeType = stBox then
        begin
          if Actor.FVideoTexture.id > 0 then
          begin
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := Actor.FVideoTexture;
            ColorShaderVec[0] := 1.0;
            ColorShaderVec[1] := 1.0;
            ColorShaderVec[2] := 1.0;
            ColorShaderVec[3] := 1.0;
            SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          end
          else
          begin
            FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;
            C := GetActorColor(Actor);
            ColorShaderVec[0] := C.r / 255.0;
            ColorShaderVec[1] := C.g / 255.0;
            ColorShaderVec[2] := C.b / 255.0;
            ColorShaderVec[3] := C.A / 255.0;
            SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          end;
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          if Actor.FVideoTexture.id > 0 then
            DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, WHITE)
          else
            DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, GetActorColor(Actor));
          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
        end
        else if Actor.ShapeType = stBomb then
        begin
            // Prevent Access Violation if the bomb was deleted this frame
          if Assigned(FBombActor) and (Actor = FBombActor) and (not Actor.FIsDead) and (FSphereModel.meshes <> nil) and (FSphereModel.meshCount > 0) then
          begin
            ModelMat := rlGetMatrixTransform();
            SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
            DrawModel(FSphereModel, Vector3Create(0, 0, 0), 0.5, GetActorColor(Actor));
          end;
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
        // 3D UI BUTTON
        // ====================================================================
        else if Actor.ShapeType = stButton then
        begin
          var BtnOffset: Single := 0.0;
          if Actor.IsPressed then
            BtnOffset := -0.03;
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
        end
        // ====================================================================
        // 3D TRACKBAR
        // --------------------------------------------------------------------
        // Single composite actor styled like the 3D button: a dark base
        // block sits at the actor's position, and a smaller knob sticks
        // out the front (Z+ face). The knob's X position is driven by
        // ItemPosition (0..1000 promille, 0 = left edge, 1000 = right edge).
        // The user drags the knob with the left mouse button - see
        // HandleDesktopInput / UpdateTrackbarFromMouse.
        //
        // IMPORTANT: The knob is positioned in LOCAL actor space (relative
        // to the actor's center) - do NOT add Actor.Position here. The
        // outer rlTranslatef(Actor.Position) at the top of the loop has
        // already moved the model matrix to the actor's world position,
        // so any further translation we do here is relative to that.
        // ====================================================================
        else if Actor.ShapeType = stTrackbar then
        begin
          // 1. Base block (dark frame, full size, at actor origin).
          //    Color is sourced from Actor.BaseColor so the user can change
          //    it in the Object Inspector (default DARKGRAY from VCL3D).
          rlPushMatrix();
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          var BaseCol: TColorB := Actor.BaseColor;
          C := BaseCol;
          ColorShaderVec[0] := C.r / 255.0;
          ColorShaderVec[1] := C.g / 255.0;
          ColorShaderVec[2] := C.b / 255.0;
          ColorShaderVec[3] := C.A / 255.0;
          SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, BaseCol);
          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
          rlPopMatrix();

          // 2. Knob (small, sits INSIDE the base block but sticks out the
          //    front face in Z+ so it is easy to grab with the mouse ray).
          //    All coordinates here are LOCAL to the actor (no Actor.Position
          //    added) - the outer rlTranslatef at the top of the actor loop
          //    has already placed us at the actor's world position.
          var T: Single := EnsureRange(Actor.ItemPosition / 1000.0, 0.0, 1.0);
          var KnobW: Single := Actor.Scale.x * 0.12;
          if KnobW < 0.2 then
            KnobW := 0.2;
          // Knob taller than the base so it stands out top+bottom like a
          // real slider cap that you can grab.
          var KnobH: Single := Actor.Scale.y * 1.4;
          // Knob sticks out the front face in Z+ by half its own depth,
          // the other half sits inside the base block.
          var KnobD: Single := Actor.Scale.z * 0.8 + 0.2;
          // Local X: ranges from left edge of base (with knob width offset)
          // to right edge of base. Knob center sits at:
          //   -Scale.x/2 + KnobW/2 + T * (Scale.x - KnobW)
          var KnobX: Single := -Actor.Scale.x * 0.5 + KnobW * 0.5 + T * (Actor.Scale.x - KnobW);
          // Local Y: 0 = centered vertically on the base block. Because
          // KnobH > Scale.y the knob pokes out top + bottom.
          var KnobY: Single := 0.0;
          // Local Z: half of the knob depth pokes out the front face of
          // the base block. Base front face is at +Scale.z/2, so the knob
          // center is at Scale.z/2 (knob extends from there +/- KnobD/2,
          // so the inner half is inside the base, the outer half sticks out).
          var KnobZ: Single := Actor.Scale.z * 0.5;

          rlPushMatrix();
          rlTranslatef(KnobX, KnobY, KnobZ);
          rlScalef(KnobW, KnobH, KnobD);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          // Knob color: Actor.ActColor carries the lerped value
          // (Update() in Yutani.Core.ModelEngine lerps ActColor toward
          // BaseColor at rest, toward HoverColor on hover, and toward a
          // darkened BaseColor when pressed). We just draw ActColor here
          // so the smooth transition is visible.
          var KnobCol: TColorB := Actor.ActColor;
          C := KnobCol;
          ColorShaderVec[0] := C.r / 255.0;
          ColorShaderVec[1] := C.g / 255.0;
          ColorShaderVec[2] := C.b / 255.0;
          ColorShaderVec[3] := C.A / 255.0;
          SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, KnobCol);
          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
          rlPopMatrix();
        end
        // ====================================================================
        // 3D PROGRESS BAR
        // --------------------------------------------------------------------
        // Same composite design as the trackbar: dark base block (the
        // "frame") plus a green fill that pokes out the front face (Z+).
        // The fill width grows from the left edge based on ItemPosition.
        // Progress bars are NOT interactive - their ItemPosition is set
        // externally via TVCL3D.SetProgressBarValue / the published
        // ItemPosition property in the Object Inspector.
        //
        // IMPORTANT: Same as the trackbar, all knob/fill coordinates here
        // are LOCAL to the actor (no Actor.Position added).
        // ====================================================================
        else if Actor.ShapeType = stProgressBar then
        begin
          // 1. Base block (dark frame, full size, at actor origin).
          //    Color is sourced from Actor.BaseColor so the user can change
          //    it in the Object Inspector (default DARKGRAY from VCL3D).
          rlPushMatrix();
          rlScalef(Actor.Scale.x, Actor.Scale.y, Actor.Scale.z);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);
          FBoxModel.materials[0].maps[MATERIAL_MAP_ALBEDO].texture := FDefaultWhiteTex;

          var BaseCol: TColorB := Actor.BaseColor;
          C := BaseCol;
          ColorShaderVec[0] := C.r / 255.0;
          ColorShaderVec[1] := C.g / 255.0;
          ColorShaderVec[2] := C.b / 255.0;
          ColorShaderVec[3] := C.A / 255.0;
          SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, BaseCol);
          DrawCubeWires(Vector3Create(0, 0, 0), 1.0, 1.0, 1.0, BLACK);
          rlPopMatrix();

          // 2. Fill (anchored left, width from ItemPosition, pokes out
          //    the front face in Z+ so the green fill is clearly visible
          //    from the camera's point of view, like a progress bar in a
          //    frame).
          var T: Single := EnsureRange(Actor.ItemPosition / 1000.0, 0.0, 1.0);
          var MinFillW: Single := Actor.Scale.x * 0.02;  // Sliver at 0% scaled to actor
          if MinFillW < 0.05 then
            MinFillW := 0.05;
          var FillW: Single := Max(Actor.Scale.x * T, MinFillW);
          // Fill is slightly shorter than the base in Y so it looks like a
          // bar sitting inside a frame (with a dark border top + bottom).
          var FillH: Single := Actor.Scale.y * 0.7;
          // Fill pokes out the front face by half its depth; the other
          // half sits inside the base block.
          var FillD: Single := Actor.Scale.z * 0.6 + 0.2;
          // Local X: anchored to the left edge of the base block.
          //   Base left edge = -Scale.x/2. Fill center = Base left + FillW/2.
          var FillX: Single := -Actor.Scale.x * 0.5 + FillW * 0.5;
          // Local Y: 0 = centered vertically (FillH < Scale.y so we get a
          // dark border top + bottom of the base).
          var FillY: Single := 0.0;
          // Local Z: half the fill depth pokes out the front face. Base
          // front face is at +Scale.z/2, fill center at Scale.z/2 means
          // the inner half is inside the base, outer half sticks out.
          var FillZ: Single := Actor.Scale.z * 0.5;

          rlPushMatrix();
          rlTranslatef(FillX, FillY, FillZ);
          rlScalef(FillW, FillH, FillD);
          ModelMat := rlGetMatrixTransform();
          SetShaderValueMatrix(FLightShader, ModelMatLoc, ModelMat);

          C := Actor.ActColor;
          ColorShaderVec[0] := C.r / 255.0;
          ColorShaderVec[1] := C.g / 255.0;
          ColorShaderVec[2] := C.b / 255.0;
          ColorShaderVec[3] := C.A / 255.0;
          SetShaderValue(FLightShader, ActorColorLoc, @ColorShaderVec, SHADER_UNIFORM_VEC4);
          DrawModel(FBoxModel, Vector3Create(0, 0, 0), 1.0, Actor.ActColor);
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
      if GMaxDim <= 0 then
        GMaxDim := 1.0;
      var GUniformScale: Single := 1.0 / GMaxDim;
      SurfaceY := FGhostPos.y + ((GMeshH * GUniformScale) * 0.5) + 0.75;
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
        if GMaxDim <= 0 then
          GMaxDim := 1.0;
        var GUniformScale: Single := 1.0 / GMaxDim;
        var GCenterX := ((GBBOX.max.x + GBBOX.min.x) / 2) * GUniformScale;
        var GCenterZ := ((GBBOX.max.z + GBBOX.min.z) / 2) * GUniformScale + 0.1;
        var GMeshH: Single := GMeshSize.y * GUniformScale;
        rlTranslatef(-GCenterX, -GMeshH * 0.5, -GCenterZ);
        var OldTransform: TMatrix := FCustomModel.transform;
        FCustomModel.transform := MatrixIdentity();
        DrawModel(FCustomModel, Vector3Create(0, 0, 0), 1.1, Fade(WHITE, 0.4));
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
    if FProjectiles[i] = nil then
      Continue;
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
  if Assigned(FParticleEngine) then
  begin
    FParticleEngine.Render;
  end;
  if Assigned(FNanoFog) then
  begin
    FNanoFog.Render;
  end;
  dt := GetFrameTime();
  UpdateProjectiles(dt * FTimeScale);
  DrawSpawnEffects;
  if Assigned(FAliveHighlighter3D) and FAliveHighlighter3D.Active then
    FAliveHighlighter3D.Draw;

  // Draw the shadow-receiving floor plane on top of the world floor.
  // It is transparent everywhere except where shadows exist, so it
  // only ADDS shadow pixels - the world floor shows through unchanged.
  if FShadowFloorEnabled and (not FIsLoadingWorld) then
    DrawShadowFloor;

  EndMode3D();
end;

// ============================================================================
// Draw the shadow-receiving floor plane.
// ----------------------------------------------------------------------------
// Draws a 2000x2000 plane at y=0.1 using FShadowFloorShader. The shader
// samples the shadow map and outputs transparent pixels everywhere except
// where a shadow exists - there it outputs semi-transparent black. This
// means the plane only ADDS shadows of spawned objects onto the world
// floor; the world floor itself shows through unchanged.
// ============================================================================
procedure TYutaniRaylibSandbox.DrawShadowFloor;
var
  FloorPos: TVector3;
begin
  if (FShadowFloorShader.id = 0) or (FShadowFloorModel.meshes = nil) then
    Exit;

  // Position the plane at the camera position so it follows the viewer.
  // Y = 0.1 (10cm above world floor) to avoid Z-fighting.
  FloorPos := Vector3Create(FCamera.position.x, 0.1, FCamera.position.z);

  // Use BLEND_ALPHA so transparent pixels (alpha=0) let the world floor
  // show through, and shadow pixels (alpha=0.55) darken the world floor.
  rlSetBlendMode(BLEND_ALPHA);
  BeginShaderMode(FShadowFloorShader);
  try
    rlDisableBackfaceCulling();
    rlDisableDepthMask();

    DrawModelEx(FShadowFloorModel, FloorPos, Vector3Create(0, 0, 0), 0, Vector3Create(1, 1, 1), WHITE);

    rlEnableDepthMask();
    rlEnableBackfaceCulling();
  finally
    EndShaderMode();
    rlSetBlendMode(BLEND_ALPHA);
  end;
end;

procedure TYutaniRaylibSandbox.DrawGizmo;
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
begin
  Pos := FItemSelected.Position;
  // Default gizmo length for primitives
  ScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 1.0, 1.0, 100.0);
  ScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 1.0, 1.0, 100.0);
  ScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 1.0, 1.0, 100.0);
  // FOR MODELS: Calculate the actual visual size so the gizmo arms match the mesh!
  if FItemSelected.ShapeType = stModel then
  begin
    ScaleX := EnsureRange((FItemSelected.Scale.x * 0.5) + 5.0, 1.5, 150.0);
    ScaleY := EnsureRange((FItemSelected.Scale.y * 0.5) + 5.0, 1.5, 150.0);
    ScaleZ := EnsureRange((FItemSelected.Scale.z * 0.5) + 5.0, 1.5, 150.0);
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
  end
  else if FGizmoMode = gmUniformScale then
  begin
    // Draw the main axes faintly so the user sees the orientation
    DrawCylinderEx(Pos, EndX, ArrowRadius * 0.5, ArrowRadius * 0.5, 8, Fade(ColX, 0.5));
    DrawCylinderEx(Pos, EndY, ArrowRadius * 0.5, ArrowRadius * 0.5, 8, Fade(ColY, 0.5));
    DrawCylinderEx(Pos, EndZ, ArrowRadius * 0.5, ArrowRadius * 0.5, 8, Fade(ColZ, 0.5));
    // Determine handle color (Yellow if dragging/hovering, White otherwise)
    var CornerCol: TColorB := WHITE;
    if FGizmoDragging or (FGizmoHoverAxis > 0) then
      CornerCol := YELLOW;
    HandleSize := HandleSize * 1.2; // Make them slightly larger
    // Draw 8 cubes at the corners of the bounding box
    DrawCube(Vector3Create(EndX.x, EndY.y, EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(-EndX.x, EndY.y, EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(EndX.x, -EndY.y, EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(-EndX.x, -EndY.y, EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(EndX.x, EndY.y, -EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(-EndX.x, EndY.y, -EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(EndX.x, -EndY.y, -EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
    DrawCube(Vector3Create(-EndX.x, -EndY.y, -EndZ.z), HandleSize, HandleSize, HandleSize, CornerCol);
  end;
end;

procedure TYutaniRaylibSandbox.DrawThickRingAt(Center, NormalAxis: TVector3; Radius, Thickness: Single; Color: TColorB);
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

procedure TYutaniRaylibSandbox.DrawNativePopup;
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

procedure TYutaniRaylibSandbox.DrawGUI;
var
  fpsBuf: AnsiString;
  ModeStr: AnsiString;
begin
  // --- LOADING SCREEN OVERLAY ---
  // Skip the dark rectangle when the cinematic transition is running -
  // the transition's own tunnel already covers the screen and adding
  // another dark layer on top would dull the streaks.
  if FIsLoadingWorld and (not (Assigned(FWorldTransition) and FWorldTransition.Active)) then
  begin
    DrawRectangle(0, 0, GetScreenWidth(), GetScreenHeight(), Fade(BLACK, 0.9));
  end
  else
  begin
    if FShowInfosGUi then
    begin
      fpsBuf := AnsiString(Format('FPS: %d', [GetFPS()]));
      DrawText(PAnsiChar(fpsBuf), 10, GetScreenHeight() - 30, 20, GREEN);
  // --- PARTICLE COUNTER ---
      if Assigned(FParticleEngine) then
      begin
        var PartBuf := AnsiString(Format('PARTICLES: %d', [FParticleEngine.ParticleCount]));
        DrawText(PAnsiChar(PartBuf), 10, GetScreenHeight() - 60, 20, YELLOW);
      end
      else
        DrawText('PARTICLES: 0', 10, GetScreenHeight() - 60, 20, YELLOW);
  // -----------------------------
      if FSimulationRunning then
        DrawText('SIMULATION RUNNING', 10, GetScreenHeight() - 90, 20, GREEN)
      else
        DrawText('SIMULATION PAUSED', 10, GetScreenHeight() - 90, 20, YELLOW);
      case FGizmoMode of
        gmTranslate:
          ModeStr := 'Mode: Translate (Move)';
        gmRotate:
          ModeStr := 'Mode: Rotate (Turn)';
        gmScale:
          ModeStr := 'Mode: Scale (Resize)';
        gmDragAndThrow:
          ModeStr := 'Mode: Drag & Throw';
        gmUniformScale:
          ModeStr := 'Mode: Uniform Scale (Corner Resize)';
      else
        ModeStr := 'Mode: None (UI Interaction)';
      end;
      DrawText(PAnsiChar(ModeStr), 10, GetScreenHeight() - 120, 20, RAYWHITE);
      // Show the currently selected avatar controller type so the user
      // knows what F11 will possess. Highlight it green while driving.
      var CtrlStr: AnsiString;
      case FAvatarControllerType of
        actVehicle:
          CtrlStr := AnsiString('Avatar: Vehicle (F11=possess/rotate, Shift+F11=cycle, F12=exit)');
        actThirdPerson:
          CtrlStr := AnsiString('Avatar: ThirdPerson (F11=possess, Shift+F11=cycle, F12=exit)');
        actFirstPerson:
          CtrlStr := AnsiString('Avatar: FirstPerson (F11=possess, Shift+F11=cycle, F12=exit)');
        actFlight:
          CtrlStr := AnsiString('Avatar: Flight (F11=possess, Shift+F11=cycle, F12=exit)');
        actSpectator:
          CtrlStr := AnsiString('Avatar: Spectator (F11=possess, Shift+F11=cycle, F12=exit)');
        actOrbit:
          CtrlStr := AnsiString('Avatar: Orbit (F11=possess, Shift+F11=cycle, F12=exit)');
        actRigidBody:
          CtrlStr := AnsiString('Avatar: RigidBody (F11=possess, Shift+F11=cycle, F12=exit)');
      end;
      if FIsDriving then
        DrawText(PAnsiChar(CtrlStr), 10, GetScreenHeight() - 150, 20, GREEN)
      else
        DrawText(PAnsiChar(CtrlStr), 10, GetScreenHeight() - 150, 20, GRAY);
      // Split-screen status indicator. Bright purple so it stands out
      // from the regular controller-type line.
      if Assigned(FMultiPlayer) and FMultiPlayer.Active then
        DrawText('SPLIT SCREEN: 2 players (F2 to exit)', 10, GetScreenHeight() - 180, 20, MAGENTA)
      else
        DrawText('Single-player mode (F2 to start 2-player split)', 10, GetScreenHeight() - 180, 20, DARKGRAY);
    end;
  end;
  // Galaxy minimap overlay - drawn last so it sits on top of every
  // other 2D element. Only shown in space mode where the galaxy
  // manager is actually running. Drawn with Raylib's 2D primitives
  // so the call must happen here in DrawGUI (after EndMode3D) rather
  // than from inside TSpaceWorld.Render which is still in 3D mode.
  if (FCurrentWorldBase = wbSpace) and Assigned(FSpaceWorld) then
    FSpaceWorld.RenderMinimap(FCamera);
end;

procedure TYutaniRaylibSandbox.DoViewportReady;
begin
  if Assigned(FOnViewportReady) then
    TThread.Queue(nil,
      procedure
      begin
        FOnViewportReady(Self);
      end);
end;

procedure TYutaniRaylibSandbox.DoActorSpawned(Actor: TA3DComponent; Index: Integer);
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

procedure TYutaniRaylibSandbox.DoActorDestroyed(Actor: TA3DComponent; Index: Integer);
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

procedure TYutaniRaylibSandbox.DoSceneCleared;
begin
  if Assigned(FOnSceneCleared) then
    TThread.Queue(nil,
      procedure
      begin
        FOnSceneCleared(Self);
      end);
end;

procedure TYutaniRaylibSandbox.DoEngineException(const Msg, Context: string);
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

procedure TYutaniRaylibSandbox.DoObjectSelected(Actor: TA3DComponent);
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

procedure TYutaniRaylibSandbox.SelectNextObject;
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

procedure TYutaniRaylibSandbox.SelectPrevObject;
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

procedure TYutaniRaylibSandbox.ProcessCustomSpawnQueue(dt: Single);
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
  FCustomSpawnTimer := 0.05;
  if Req.Name = 'BOMB_TRIGGER' then
  begin
    Req.Name := 'WallBlock_Final';
    BombReq.Shape := stSphere;
    BombReq.Size := Vector3Create(1, 1, 1);
    BombReq.IsStatic := False;
    BombReq.Color := RED;
    BombReq.Pos := Vector3Create(0, 2.0, -4.0);
    BombReq.Name := 'THE_BOMB';
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
  // NOW WE PASS Req.IsStatic DIRECTLY! IF IT IS A KEY, IT IS STATIC FROM THE START!
  Obj := TA3DComponent.Create('', FEngine, Req.Shape, Req.Size, Req.IsStatic, Req.IsDestructable, @JPos, @JRot);
  Obj.Name := Req.Name;
  Obj.Friction := 0.4;
  Obj.Restitution := 0.2;
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
  end
  else if Req.Shape in [stTrackbar, stProgressBar] then
  begin
    // For stTrackbar / stProgressBar the colors are split into three roles:
    //   BaseColor  = the dark base block color (default DARKGRAY)
    //   HoverColor = the knob / fill HOVER highlight color
    //   FillColor  = the knob / fill REST color (lerp target in normal state)
    //   Color      = the initial ActColor (so frame 0 looks right before the
    //                first Update() tick runs the color lerp)
    // If the caller did not set them explicitly, we fall back to safe
    // defaults here so the actor is always visible.
    Obj.BaseColor := Req.BaseColor;
    Obj.HoverColor := Req.HoverColor;
    Obj.FillColor := Req.FillColor;
    // Forward the value-changed callback. For stTrackbar this fires
    // from UpdateTrackbarFromMouse (render thread) via TThread.Queue
    // whenever ItemPosition changes during a drag.
    Obj.OnChange := Req.OnChange;
  end;
  Obj.TargetColor := Req.Color;
  Obj.ActColor := Req.Color;
  // Forward the generic integer slot. For stTrackbar / stProgressBar this
  // is the initial 0..1000 promille value computed by Yutani.VCL3D from
  // the caller's [Min..Max] range.
  Obj.ItemPosition := Req.ItemPosition;
  // Force position just in case, though it shouldn't be needed anymore
  Obj.SetPosition(Vector3Create(JPos.x, JPos.y, JPos.z));
  if Req.Name = 'THE_BOMB' then
  begin
    // DO NOT assign FModel. The stBomb render block draws it
    // automatically using FSphereModel. Assigning it causes primitive
    // fallback blocks to attempt drawing dead bombs, leading to AVs.
    FBombActor := Obj;
    FBombTimer := 2.0;
    FBombExploded := False;
  end
  else if Req.GenerateTestTexture then
  begin
    if (Req.Name = 'Screen_1') then
    begin
      if not Assigned(FMPVPlayer) then
      begin
        try
          FMPVPlayer := TMPVPlayer.Create(640, 360);
          FMPVPlayer.LoadFile(ExtractFilePath(ParamStr(0)) + 'ressources\video\test.mp4');
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
        Obj.FVideoTexture := LoadTextureFromImage(GenImageColor(640, 360, RED));
    end;
  end;
  // Note: Piano keys used to be registered to FPiano.FKeys here. Since
  // TPiano moved to Yutani.VCL3D and is no longer owned by the sandbox,
  // we skip that registration. The TPiano instance finds its keys on
  // demand by scanning Sandbox.FItems for IsPianoKey=True actors.
  FItems[oldLen] := Obj;
  DoActorSpawned(Obj, oldLen);
end;

procedure TYutaniRaylibSandbox.TriggerFracture(Actor: TA3DComponent; ImpactForce: Single);
var
  BaseMesh: TPolyMesh;
  Seeds: array of TVec3;
  Fragments: TFragmentArray;
  I, J: Integer;
  Centroid: TVec3;
  Dir: TVec3;
begin
  if not Assigned(Actor) or not Actor.IsDestructable then
    Exit;
  // 1. Generate a BaseMesh EXACTLY matching the Actor's Size
  var HX: Single := Actor.Scale.x * 0.5;
  var HY: Single := Actor.Scale.y * 0.5;
  var HZ: Single := Actor.Scale.z * 0.5;
  SetLength(BaseMesh, 6);
  SetLength(BaseMesh[0], 4);
  BaseMesh[0][0].x := -HX;
  BaseMesh[0][0].y := -HY;
  BaseMesh[0][0].Z := HZ;
  BaseMesh[0][1].x := HX;
  BaseMesh[0][1].y := -HY;
  BaseMesh[0][1].Z := HZ;
  BaseMesh[0][2].x := HX;
  BaseMesh[0][2].y := HY;
  BaseMesh[0][2].Z := HZ;
  BaseMesh[0][3].x := -HX;
  BaseMesh[0][3].y := HY;
  BaseMesh[0][3].Z := HZ;
  SetLength(BaseMesh[1], 4);
  BaseMesh[1][0].x := HX;
  BaseMesh[1][0].y := -HY;
  BaseMesh[1][0].Z := -HZ;
  BaseMesh[1][1].x := -HX;
  BaseMesh[1][1].y := -HY;
  BaseMesh[1][1].Z := -HZ;
  BaseMesh[1][2].x := -HX;
  BaseMesh[1][2].y := HY;
  BaseMesh[1][2].Z := -HZ;
  BaseMesh[1][3].x := HX;
  BaseMesh[1][3].y := HY;
  BaseMesh[1][3].Z := -HZ;
  SetLength(BaseMesh[2], 4);
  BaseMesh[2][0].x := -HX;
  BaseMesh[2][0].y := -HY;
  BaseMesh[2][0].Z := -HZ;
  BaseMesh[2][1].x := -HX;
  BaseMesh[2][1].y := -HY;
  BaseMesh[2][1].Z := HZ;
  BaseMesh[2][2].x := -HX;
  BaseMesh[2][2].y := HY;
  BaseMesh[2][2].Z := HZ;
  BaseMesh[2][3].x := -HX;
  BaseMesh[2][3].y := HY;
  BaseMesh[2][3].Z := -HZ;
  SetLength(BaseMesh[3], 4);
  BaseMesh[3][0].x := HX;
  BaseMesh[3][0].y := -HY;
  BaseMesh[3][0].Z := HZ;
  BaseMesh[3][1].x := HX;
  BaseMesh[3][1].y := -HY;
  BaseMesh[3][1].Z := -HZ;
  BaseMesh[3][2].x := HX;
  BaseMesh[3][2].y := HY;
  BaseMesh[3][2].Z := -HZ;
  BaseMesh[3][3].x := HX;
  BaseMesh[3][3].y := HY;
  BaseMesh[3][3].Z := HZ;
  SetLength(BaseMesh[4], 4);
  BaseMesh[4][0].x := -HX;
  BaseMesh[4][0].y := HY;
  BaseMesh[4][0].Z := HZ;
  BaseMesh[4][1].x := HX;
  BaseMesh[4][1].y := HY;
  BaseMesh[4][1].Z := HZ;
  BaseMesh[4][2].x := HX;
  BaseMesh[4][2].y := HY;
  BaseMesh[4][2].Z := -HZ;
  BaseMesh[4][3].x := -HX;
  BaseMesh[4][3].y := HY;
  BaseMesh[4][3].Z := -HZ;
  SetLength(BaseMesh[5], 4);
  BaseMesh[5][0].x := -HX;
  BaseMesh[5][0].y := -HY;
  BaseMesh[5][0].Z := -HZ;
  BaseMesh[5][1].x := HX;
  BaseMesh[5][1].y := -HY;
  BaseMesh[5][1].Z := -HZ;
  BaseMesh[5][2].x := HX;
  BaseMesh[5][2].y := -HY;
  BaseMesh[5][2].Z := HZ;
  BaseMesh[5][3].x := -HX;
  BaseMesh[5][3].y := -HY;
  BaseMesh[5][3].Z := HZ;
  // 2. Generate random Voronoi seeds INSIDE the real size of the actor
  // We map the 0..1 random values to the -HX..HX bounds
  SetLength(Seeds, 10 + Random(5));
  for I := 0 to High(Seeds) do
  begin
    Seeds[I].x := -HX + (Random * Actor.Scale.x);
    Seeds[I].y := -HY + (Random * Actor.Scale.y);
    Seeds[I].Z := -HZ + (Random * Actor.Scale.z);
  end;
  // 3. Fracture the mesh
  Fragments := FractureMesh(BaseMesh, Seeds);
  // 4. Distribute fragments into the queue with physics properties
  for I := 0 to High(Fragments) do
  begin
    if Length(Fragments[I].Mesh) > 0 then
    begin
      // Calculate centroid
      Centroid := Default(TVec3);
      for J := 0 to High(Fragments[I].Mesh[0]) do
        Centroid := Centroid + Fragments[I].Mesh[0][J];
      if Length(Fragments[I].Mesh[0]) > 0 then
        Centroid := Centroid * (1.0 / Length(Fragments[I].Mesh[0]));
      // Position = Actor Position + Centroid offset
      Fragments[I].Position.X := Actor.Position.x + Centroid.X;
      Fragments[I].Position.Y := Actor.Position.y + Centroid.Y;
      Fragments[I].Position.Z := Actor.Position.z + Centroid.Z;
      // Outward direction
      Dir := Centroid.Normalize;
      Dir.Y := Dir.Y + 0.2; // Slight bias upwards
      // Drastically limit the explosion force!
      // Even if it falls at speed 20, the fragments only pop out at max 2.0 speed.
      var DampenedForce := EnsureRange(ImpactForce * 0.05, 0.5, 2.0);
      Fragments[I].Velocity := Dir * DampenedForce;
      // Limit angular velocity so they don't spin like crazy
      Fragments[I].AngularVelocity := (Random * 1.5) - 0.75;
      SetLength(FFractureQueue, Length(FFractureQueue) + 1);
      FFractureQueue[High(FFractureQueue)] := Fragments[I];
    end;
  end;
  // Mark the original actor for deletion
  Actor.FIsDead := True;
end;

procedure TYutaniRaylibSandbox.ProcessFractureQueue(dt: Single);
var
  Frag: TFragment;
  oldLen: Integer;
  Data: PItemData;
  JPos: JPH_RVec3;
  JRot: JPH_Quat;
  Obj: TA3DComponent;
  RandomColor: TColorB;
  LocalMesh: TMesh;
  BBox: TBoundingBox;
  FragSize: TVector3;
  OutwardDir: TVector3;
  FRandID: Integer;
begin
  if Length(FFractureQueue) = 0 then
    Exit;
  if FFractureTimer > 0 then
  begin
    FFractureTimer := FFractureTimer - dt;
    Exit;
  end;
  FFractureTimer := 0;
  while Length(FFractureQueue) > 0 do
  begin
    FLock.Enter;
    try
      Frag := FFractureQueue[0];
      if Length(FFractureQueue) > 1 then
      begin
        for var i := 0 to High(FFractureQueue) - 1 do
          FFractureQueue[i] := FFractureQueue[i + 1];
      end;
      SetLength(FFractureQueue, Length(FFractureQueue) - 1);
    finally
      FLock.Leave;
    end;
    // 1. Build the perfectly centered Raylib mesh
    LocalMesh := BuildRaylibMeshFromFragment(Frag);
    BBox := GetMeshBoundingBox(LocalMesh);
    FragSize := Vector3Create(BBox.max.x - BBox.min.x, BBox.max.y - BBox.min.y, BBox.max.z - BBox.min.z);
    if Max(FragSize.x, Max(FragSize.y, FragSize.z)) < 0.1 then
      FragSize := Vector3Create(0.2, 0.2, 0.2);
    // 2. Push fragment outwards slightly
    OutwardDir := Vector3Normalize(Vector3Create(Frag.Position.X, Frag.Position.Y, Frag.Position.Z));
    if Vector3Length(OutwardDir) < 0.1 then
      OutwardDir := Vector3Create(0, 1, 0);
    OutwardDir := Vector3Scale(OutwardDir, 0.15);
    // 3. Set Position (Mesh is centered, so Position is exact)
    JPos.x := Frag.Position.X + OutwardDir.x;
    JPos.y := Frag.Position.Y + OutwardDir.y;
    JPos.z := Frag.Position.Z + OutwardDir.z;
    if JPos.y < 0.5 then
      JPos.y := 0.5;
    JRot.x := 0;
    JRot.y := 0;
    JRot.z := 0;
    JRot.w := 1;
    // 4. Create Actor using a slightly SHRUNK size (85%) to prevent micro-jitter!
    // SetScale will force ConvexRadius to 0.0 in ModelEngine (because Name='Fragment')
    var ShrinkFactor: Single := 0.85;
    var PhysSize: TVector3 := Vector3Create(FragSize.x * ShrinkFactor, FragSize.y * ShrinkFactor, FragSize.z * ShrinkFactor);
    Obj := TA3DComponent.Create('', FEngine, stBox, PhysSize, False, False, @JPos, @JRot);
    Obj.Name := 'Fragment';
    Obj.Friction := 0.6;
    Obj.Restitution := 0.1;
    Obj.ActivateBody;
    Obj.Visible := True;
    // 5. Assign Mesh & Shader
    Obj.ShapeType := stModel;
    Obj.FModel := LoadModelFromMesh(LocalMesh);
    if (Obj.FModel.materialCount > 0) and (Obj.FModel.materials <> nil) then
      Obj.FModel.materials[0].shader := FLightShader;
    // Mesh is centered, so no offset needed!
    Obj.FModelOffset := Vector3Create(0, 0, 0);
    RandomColor.r := Random(255);
    RandomColor.g := Random(255);
    RandomColor.b := Random(255);
    RandomColor.a := 255;
    Obj.ActColor := RandomColor;
    Obj.TargetColor := RandomColor;
    Obj.SetLinearVelocity(Vector3Create(Frag.Velocity.X, Frag.Velocity.Y, Frag.Velocity.Z));
    Obj.SetAngularVelocity(Vector3Create(Frag.AngularVelocity, Frag.AngularVelocity, Frag.AngularVelocity));
    // 6. Unique Name & Array Registration
    FRandID := Random(1000000) + 100000;
    oldLen := Length(FItems);
    SetLength(FItems, oldLen + 1);
    New(Data);
    FillChar(Data^, SizeOf(TItemData), 0);
    Data^.SpawnTime := GetTime();
    Data^.IsProjectile := False; // MUST BE FALSE! If True, they vanish!
    Data^.Name := 'Frag_' + IntToStr(FRandID) + '_' + IntToStr(oldLen);
    Obj.UserData := Data;
    FItems[oldLen] := Obj;
    DoActorSpawned(Obj, oldLen);
  end;
end;

procedure TYutaniRaylibSandbox.UpdateBomb(dt: Single);
begin
  // Prevent access violation if bomb was already cleared/deleted
  if not Assigned(FBombActor) or FBombExploded or FBombActor.FIsDead then
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

procedure TYutaniRaylibSandbox.ExplodeBomb;
var
  i: Integer;
  Actor: TA3DComponent;
  Dist: Single;
  Dir: TVector3;
  ForceMag: Single;
  BombIdx: Integer;
begin
  if not Assigned(FBombActor) or FBombExploded then
    Exit;
  // Set flag immediately to prevent multiple triggers in the same frame
  FBombExploded := True;
  FYutaniAudio.PlaySoundEffect('ressources\audio\explosionCrunch_004.wav', 1.0);
  if Assigned(FParticleEngine) then
  begin
    FParticleEngine.EmitExplosion(FBombActor.Position, 2000, RED);
   // FParticleEngine.EmitSparks(FBombActor.Position, 2000, GOLD);
   // FParticleEngine.EmitSmoke(FBombActor.Position, 1000, DARKGRAY);
  end;
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
  // SAFE DESTRUCTION: Mark for deletion instead of hard deleting here
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
  // 2. If found, notify UI and mark for deletion
  if BombIdx >= 0 then
  begin
    // Notify the VCL Form to remove the node from the TreeView!
    DoActorDestroyed(FBombActor, BombIdx);
    // Deselect bomb if it was selected to prevent Gizmo crashes
    if FItemSelected = FBombActor then
    begin
      FItemSelected := nil;
      DoObjectSelected(nil);
    end;
    // Remove and destroy from Jolt Physics immediately so it stops colliding
    if FBombActor.FBodyID <> 0 then
    begin
      JPH_BodyInterface_RemoveAndDestroyBody(FEngine.BodyInterface, FBombActor.FBodyID);
      FBombActor.FBodyID := 0;
    end;
    // Free UserData if it exists
    if FBombActor.UserData <> nil then
    begin
      Dispose(PItemData(FBombActor.UserData));
      FBombActor.UserData := nil;
    end;
    // Clear the Model reference so the primitive render block
    // doesn't attempt to draw the dead, invisible bomb before garbage collection!
    FBombActor.FModel := Default(TModel);
    // Instead of FreeAndNil here (which causes Access Violations
    // if the RenderThread tries to draw it at the same time), we mark it as Dead.
    // The garbage collector at the end of UpdateGame will safely free the memory.
    FBombActor.FIsDead := True;
    FBombActor.Visible := False;
  end;
  // Clear the reference so UpdateBomb doesn't fire it again
  FBombActor := nil;
end;

procedure TYutaniRaylibSandbox.ClearDynamicItemsOnly;
begin
  FLock.Enter;
  try
    FGizmoMode := gmNone;
    FDragging := False;
    FItemSelected := nil;
    FSpawnQueue := 0;
    // Stop and free MPV player when the scene is cleared!
    if Assigned(FMPVPlayer) then
      FreeAndNil(FMPVPlayer);
    // Note: TPiano is now owned by the caller (Yutani.VCL3D). The caller
    // must free its TPiano instance manually when the scene is cleared.
    // Only clear dynamic items, keep FFloorActor and Engine alive!
    var i: Integer;
    for i := High(FItems) downto 0 do
    begin
      if Assigned(FItems[i]) then
      begin
        if FItems[i].Name = 'FLOOR' then
          Continue;
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
    FDraggingTrackbar := nil;
    FActiveSpawnEffects := nil;
    FFocusTrackingActor := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.ReattachLoadedActor(Actor: TA3DComponent);
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

procedure TYutaniRaylibSandbox.SaveSceneToFile(const FileName: string);
begin
  FLock.Enter;
  try
    FQueuedSavePath := FileName;
    FSaveSceneQueued := True;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.LoadSceneFromFile(const FileName: string);
begin
  FLock.Enter;
  try
    FQueuedLoadPath := FileName;
    FLoadSceneQueued := True;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.ExecuteSceneSave(const FileName: string);
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
         // if Actor.ShapeType = stModel then
         //   Continue;
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
          if Actor.IsStatic then
            Writer.WriteInteger(1)
          else
            Writer.WriteInteger(0);
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

procedure TYutaniRaylibSandbox.ExecuteSceneLoad(const FileName: string);
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
          var LoadIsStatic: Boolean := (Reader.ReadInteger = 1);
          LoadColor.r := Reader.ReadInteger;
          LoadColor.g := Reader.ReadInteger;
          LoadColor.b := Reader.ReadInteger;
          LoadColor.a := Reader.ReadInteger;
          // Read ModelPath ('-' if not a model)
          ModelPath := Reader.ReadStr;
          // Create the Actor natively and pass the loaded IsStatic state!
          Actor := TA3DComponent.Create('', FEngine, ShapeType, Size, LoadIsStatic, False, @JPos, @JRot);
          Actor.Name := AName;
          Actor.Friction := Friction;
          Actor.Restitution := Restitution;
          Actor.ActColor := LoadColor;
          Actor.TargetColor := LoadColor;
          Actor.Visible := True;
          Actor.SetPosition(Vector3Create(JPos.x, JPos.y, JPos.z));
          Actor.SetRotation(QuaternionCreate(JRot.x, JRot.y, JRot.z, JRot.w));
          // Load model mesh if it's a model
          if (ShapeType = stModel) and (ModelPath <> '-') and (ModelPath <> '') then
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
            Actor.ModelPath := '-';
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

procedure TYutaniRaylibSandbox.TriggerSpawnEffect(const Pos: TVector3; Actor: TA3DComponent);
var
  Effect: TSpawnEffect;
begin
  // Abort if no effect is selected
  if FSpawnEffectType = spefNone then
    Exit;
  Effect.Position := Pos;
  Effect.StartTime := GetTime();
  Effect.Duration := 4.0;
  Effect.EffectType := FSpawnEffectType;
  Effect.TargetActor := Actor;
  // CRITICAL: Force the actor to be completely invisible at the start!
  // This ensures DrawSpawnEffects will trigger the materialization process.
  if Assigned(Actor) then
  begin
    Actor.Visible := False;
    Actor.ActAlpha := 0.0;
    Actor.TargetAlpha := 0.0; // Keep it 0 until particles are done
  end;
  // Add to active effects array
  SetLength(FActiveSpawnEffects, Length(FActiveSpawnEffects) + 1);
  FActiveSpawnEffects[High(FActiveSpawnEffects)] := Effect;
end;

procedure TYutaniRaylibSandbox.DrawSpawnEffects;
var
  i: Integer;
  Elapsed, Progress, Alpha: Single;
  BasePos: TVector3;
  bRemove: Boolean;
begin
  for i := 0 to High(FActiveSpawnEffects) do
  begin
    bRemove := False;
    // ==============================================================
    // FADE EFFECT (Uses Duration / Time)
    // ==============================================================
    if FActiveSpawnEffects[i].EffectType = spefFade then
    begin
      Elapsed := GetTime() - FActiveSpawnEffects[i].StartTime;
      if Elapsed >= FActiveSpawnEffects[i].Duration then
      begin
        bRemove := True;
      end
      else
      begin
        Progress := Elapsed / FActiveSpawnEffects[i].Duration;
        Alpha := 1.0 - Progress;
        BasePos := FActiveSpawnEffects[i].Position;
        if Assigned(FActiveSpawnEffects[i].TargetActor) and (not FActiveSpawnEffects[i].TargetActor.Visible) then
        begin
          FActiveSpawnEffects[i].TargetActor.Visible := True;
          FActiveSpawnEffects[i].TargetActor.ActAlpha := 1.0;
          FActiveSpawnEffects[i].TargetActor.TargetAlpha := 1.0;
        end;
        DrawSphere(BasePos, 0.5 + (Progress * 2.0), Fade(SKYBLUE, Alpha * 0.4));
        DrawSphereWires(BasePos, 0.5 + (Progress * 2.0), 8, 8, Fade(WHITE, Alpha * 0.8));
      end;
    end
    // ==============================================================
    // BEAM MATERIALIZATION
    // ==============================================================
    else if FActiveSpawnEffects[i].EffectType = spefBeam then
    begin
      if not FSimulationRunning then
      begin
        if Assigned(FActiveSpawnEffects[i].TargetActor) then
        begin
          FActiveSpawnEffects[i].TargetActor.Visible := True;
          FActiveSpawnEffects[i].TargetActor.ActAlpha := 1.0;
          FActiveSpawnEffects[i].TargetActor.TargetAlpha := 1.0;
        end;
        bRemove := True;
      end
      else
      begin
        // 1. Trigger exactly once if the Actor is still invisible
        if Assigned(FActiveSpawnEffects[i].TargetActor) and (not FActiveSpawnEffects[i].TargetActor.Visible) and (not FIsMaterializingActor) then
        begin
          FIsMaterializingActor := True;
          ExecuteMaterializeActor(FActiveSpawnEffects[i].TargetActor);
        end;
        // 2. WAIT FOR THE TOP LAYER!
        // The model is only shown when the Particle Engine signals: "All arrived!"
        if Assigned(FParticleEngine) and FParticleEngine.SolidCubeReady then
        begin
          if Assigned(FActiveSpawnEffects[i].TargetActor) and (not FActiveSpawnEffects[i].TargetActor.Visible) then
          begin
            FActiveSpawnEffects[i].TargetActor.Visible := True;
            FActiveSpawnEffects[i].TargetActor.ActAlpha := 1.0;
            FActiveSpawnEffects[i].TargetActor.TargetAlpha := 1.0;
            FParticleEngine.SolidCubeReady := False;
            FIsMaterializingActor := False;
            bRemove := True; // End effect because the top layer has been reached!
          end;
        end;
        // Safety: Abort if the object is deleted before it could materialize
        if not Assigned(FActiveSpawnEffects[i].TargetActor) then
        begin
          bRemove := True;
          FIsMaterializingActor := False;
        end;
      end;
    end;
    // Mark the effect for removal if it is finished
    if bRemove then
      FActiveSpawnEffects[i].StartTime := -99999.0;
  end;
  // --- CLEANUP: Remove finished effects from the array ---
  for i := High(FActiveSpawnEffects) downto 0 do
  begin
    if FActiveSpawnEffects[i].StartTime = -99999.0 then
    begin
      if Assigned(FActiveSpawnEffects[i].TargetActor) then
      begin
        FActiveSpawnEffects[i].TargetActor.TargetAlpha := 1.0;
        FActiveSpawnEffects[i].TargetActor.ActAlpha := 1.0;
        FActiveSpawnEffects[i].TargetActor.Visible := True;
      end;
      if i < High(FActiveSpawnEffects) then
        FActiveSpawnEffects[i] := FActiveSpawnEffects[High(FActiveSpawnEffects)];
      SetLength(FActiveSpawnEffects, Length(FActiveSpawnEffects) - 1);
    end;
  end;
end;
// ============================================================================
// Note: TPiano and TYutaniRaylibSandbox.SpawnPiano have been moved to the
// Yutani.VCL3D unit. The sandbox keeps the piano-key rendering, click and
// gizmo-linking logic because those operate purely on TA3DComponent flags
// (IsPianoKey, IsPressed, Name='PianoBody') without needing a TPiano
// reference. Spawn a piano from the VCL via TVCL3D.SpawnPiano(Sandbox) and
// hold the returned TPiano instance yourself.
// ============================================================================

procedure TYutaniRaylibSandbox.SetHighlighterActive(Active: Boolean);
begin
  if Assigned(FAliveHighlighter3D) then
  begin
    FAliveHighlighter3D.Active := Active;
  end;
end;

procedure TYutaniRaylibSandbox.SendHighlighterToActor(Actor: TA3DComponent);
begin
  if Assigned(FAliveHighlighter3D) and Assigned(Actor) then
  begin
    FAliveHighlighter3D.SendToTarget(Actor.Position);
    FAliveHighlighter3D.Active := True;
  end;
end;

procedure TYutaniRaylibSandbox.TriggerFogEffect;
var
  Req: TParticleSpawnRequest;
begin
  if Assigned(FItemSelected) then
    Req.Pos := FItemSelected.Position
  else
    Req.Pos := FCamera.target;
  Req.Pos.y := Req.Pos.y + 0.5;
  Req.Count := 10000;
  Req.Color := WHITE;
  Req.IsSmoke := True;
  FLock.Enter;
  try
    SetLength(FParticleSpawnQueue, Length(FParticleSpawnQueue) + 1);
    FParticleSpawnQueue[High(FParticleSpawnQueue)] := Req;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.TriggerExplosionEffect;
var
  Req: TParticleSpawnRequest;
begin
  if Assigned(FItemSelected) then
    Req.Pos := FItemSelected.Position
  else
    Req.Pos := FCamera.target;
  Req.Count := 1500;
  Req.Color := RED;
  Req.IsSmoke := False;
  FLock.Enter;
  try
    SetLength(FParticleSpawnQueue, Length(FParticleSpawnQueue) + 1);
    FParticleSpawnQueue[High(FParticleSpawnQueue)] := Req;
  finally
    FLock.Leave;
  end;
end;
// ============================================================================
// EXTERNAL MATERIALIZATION TRIGGERS (Safe to call from VCL/UI Thread)
// ============================================================================

procedure TYutaniRaylibSandbox.DematerializeSelectedObject;
begin
  if Assigned(FItemSelected) then
    DematerializeActor(FItemSelected);
end;

procedure TYutaniRaylibSandbox.DematerializeActor(Actor: TA3DComponent);
var
  Req: TDematerializeRequest;
begin
  if not Assigned(Actor) then
    Exit;
  Req.Actor := Actor;
  // Thread-safe queueing. The actual Raylib & Particle logic happens in UpdateGame.
  FLock.Enter;
  try
    SetLength(FDematerializeQueue, Length(FDematerializeQueue) + 1);
    FDematerializeQueue[High(FDematerializeQueue)] := Req;
  finally
    FLock.Leave;
  end;
end;

procedure TYutaniRaylibSandbox.ExecuteDematerializeActor(Actor: TA3DComponent);
var
  BaseMesh: TMesh;
  FinalVerts: array of Single;
  vCount: Integer;
  i, j, k: Integer;
  OffsetX, OffsetY, OffsetZ: Single;
  GridSize: Integer;
  LenX, LenY, LenZ: Single;
  DistSq, RadSq: Single;
  CapY: Single;
  t, Angle, MaxR: Single;
  TempVerts: array of Single;
  Mesh: TMesh;
  vx, vy, vz: Single;
begin
  if not Assigned(Actor) or not Assigned(FParticleEngine) then
    Exit;
  // HIDE ORIGINAL IMMEDIATELY: The particles take over the visual representation.
  Actor.Visible := False;
  // ========================================================================
  // FALL 1: CUSTOM 3D MODEL
  // We extract the real mesh shell from the loaded model file.
  // ========================================================================
  if Actor.ShapeType = stModel then
  begin
    if (Actor.FModel.meshes <> nil) and (Actor.FModel.meshes[0].vertices <> nil) then
      Mesh := Actor.FModel.meshes[0]
    else
      Exit; // Safety abort
    if (Mesh.vertexCount > 0) and (Mesh.vertices <> nil) then
    begin
      // Cap to 3000 to prevent massive memory leaks on huge models!
      if Mesh.vertexCount > 10000 then
        BaseMesh.vertexCount := 10000
      else
        BaseMesh.vertexCount := Mesh.vertexCount;
      SetLength(TempVerts, BaseMesh.vertexCount * 3);
      for i := 0 to BaseMesh.vertexCount - 1 do
      begin
        vx := Mesh.vertices[i * 3];
        vy := Mesh.vertices[i * 3 + 1];
        vz := Mesh.vertices[i * 3 + 2];
        vx := vx * Actor.Scale.x;
        vy := vy * Actor.Scale.y;
        vz := vz * Actor.Scale.z;
        vx := vx + Actor.FModelOffset.x;
        vy := vy + Actor.FModelOffset.y;
        vz := vz + Actor.FModelOffset.z;
        TempVerts[i * 3] := vx;
        TempVerts[i * 3 + 1] := vy;
        TempVerts[i * 3 + 2] := vz;
      end;
      BaseMesh.vertices := @TempVerts[0];
      BaseMesh.indices := nil;
      BaseMesh.texcoords := nil;
      BaseMesh.normals := nil;
      BaseMesh.tangents := nil;
      BaseMesh.colors := nil;
      BaseMesh.animVertices := nil;
      BaseMesh.animNormals := nil;
      BaseMesh.boneIndices := nil;
      BaseMesh.boneWeights := nil;
      BaseMesh.vaoId := 0;
      BaseMesh.vboId := nil;
      FParticleEngine.EmitMaterializeMesh(Actor.Position, BaseMesh);
    end;
    Exit;
  end;
  // ========================================================================
  // FALL 2: PRIMITIVES (Voxel Generation)
  // We generate a dense, solid voxel cloud matching the exact shape.
  // ========================================================================
  GridSize := 10;
  SetLength(FinalVerts, GridSize * GridSize * GridSize * 3);
  vCount := 0;
  // Calculate exact half-dimensions
  LenX := Actor.Scale.x * 0.5;
  LenY := Actor.Scale.y * 0.5;
  LenZ := Actor.Scale.z * 0.5;
  case Actor.ShapeType of
    stSphere:
      begin
        // SOLID SPHERE
        RadSq := Sqr(Max(LenX, Max(LenY, LenZ)));
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              DistSq := Sqr(OffsetX) + Sqr(OffsetY) + Sqr(OffsetZ);
              if DistSq <= RadSq then
              begin
                FinalVerts[vCount] := OffsetX;
                FinalVerts[vCount + 1] := OffsetY;
                FinalVerts[vCount + 2] := OffsetZ;
                Inc(vCount, 3);
              end;
            end;
      end;
    stCapsule:
      begin
        // SOLID CAPSULE
        RadSq := Sqr(Max(LenX, LenZ));
        CapY := LenY - Max(LenX, LenZ);
        if CapY < 0 then
          CapY := 0;
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              DistSq := Sqr(OffsetX) + Sqr(OffsetZ);
              if DistSq <= RadSq then
              begin
                if (OffsetY >= -CapY) and (OffsetY <= CapY) then
                begin
                  FinalVerts[vCount] := OffsetX;
                  FinalVerts[vCount + 1] := OffsetY;
                  FinalVerts[vCount + 2] := OffsetZ;
                  Inc(vCount, 3);
                end
                else
                begin
                  if OffsetY > CapY then
                    DistSq := DistSq + Sqr(OffsetY - CapY)
                  else
                    DistSq := DistSq + Sqr(OffsetY + CapY);
                  if DistSq <= RadSq then
                  begin
                    FinalVerts[vCount] := OffsetX;
                    FinalVerts[vCount + 1] := OffsetY;
                    FinalVerts[vCount + 2] := OffsetZ;
                    Inc(vCount, 3);
                  end;
                end;
              end;
            end;
      end;
    stPyramid:
      begin
        // SOLID PYRAMID (4-sided cone)
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              t := 1.0 - ((OffsetY + LenY) / Actor.Scale.y);
              if t < 0 then
                t := 0;
              if (Abs(OffsetX) <= LenX * t) and (Abs(OffsetZ) <= LenZ * t) then
              begin
                FinalVerts[vCount] := OffsetX;
                FinalVerts[vCount + 1] := OffsetY;
                FinalVerts[vCount + 2] := OffsetZ;
                Inc(vCount, 3);
              end;
            end;
      end;
    stPrism:
      begin
        // SOLID PRISM (3-sided cylinder standing)
        // We use the inscribed circle radius of the triangle to make it perfectly round
        MaxR := Min(LenX, LenZ) * 0.866; // sqrt(3)/2 approx
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              // Calculate angle and check if the point is inside the triangle
              if (Abs(OffsetX) <= MaxR) and (Abs(OffsetZ) <= MaxR) then
              begin
                Angle := ArcTan2(OffsetZ, OffsetX);
                // Triangle points to the right (0, 120, 240 degrees)
                while Angle < 0 do
                  Angle := Angle + 2 * PI;
                while Angle >= 2 * PI do
                  Angle := Angle - 2 * PI;
                // Modulo 120 degrees (2*PI/3)
                if Angle > 2 * PI / 3 then
                  Angle := Angle - 2 * PI / 3;
                if Angle > 2 * PI / 3 then
                  Angle := Angle - 2 * PI / 3;
                // Angle is now between -60 and +60 degrees relative to the triangle edge
                // Max distance from center to edge is cos(Angle - 60deg) * MaxR
                if Sqr(OffsetX) + Sqr(OffsetZ) <= Sqr(MaxR / Cos(Angle - PI / 3)) then
                begin
                  FinalVerts[vCount] := OffsetX;
                  FinalVerts[vCount + 1] := OffsetY;
                  FinalVerts[vCount + 2] := OffsetZ;
                  Inc(vCount, 3);
                end;
              end;
            end;
      end
  else
    begin
        // SOLID BOX (Default for stBox, stButton, etc.)
      for i := 0 to GridSize - 1 do
        for j := 0 to GridSize - 1 do
          for k := 0 to GridSize - 1 do
          begin
            FinalVerts[vCount] := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
            FinalVerts[vCount + 1] := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
            FinalVerts[vCount + 2] := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
            Inc(vCount, 3);
          end;
    end;
  end;
  // Configure the temporary mesh struct
  BaseMesh.vertexCount := vCount div 3; // Only count the points we actually generated
  BaseMesh.vertices := @FinalVerts[0];
  BaseMesh.indices := nil;
  BaseMesh.texcoords := nil;
  BaseMesh.normals := nil;
  BaseMesh.tangents := nil;
  BaseMesh.colors := nil;
  BaseMesh.animVertices := nil;
  BaseMesh.animNormals := nil;
  BaseMesh.boneIndices := nil;
  BaseMesh.boneWeights := nil;
  BaseMesh.vaoId := 0;
  BaseMesh.vboId := nil;
  // Pass the real, exact-size voxel cloud to the particle engine
  FParticleEngine.EmitDematerializeMesh(Actor.Position, BaseMesh);
  // Mark as dead. The engine's garbage collector will safely dispose of it.
  Actor.FIsDead := True;
end;

procedure TYutaniRaylibSandbox.ExecuteMaterializeActor(Actor: TA3DComponent);
var
  BaseMesh: TMesh;
  FinalVerts: array of Single;
  vCount: Integer;
  i, j, k: Integer;
  OffsetX, OffsetY, OffsetZ: Single;
  GridSize: Integer;
  LenX, LenY, LenZ: Single;
  DistSq, RadSq: Single;
  CapY: Single;
  t, Angle, MaxR: Single;
  TempVerts: array of Single;
  Mesh: TMesh;
  vx, vy, vz: Single;
begin
  if not Assigned(Actor) or not Assigned(FParticleEngine) then
    Exit;
  // HIDE ORIGINAL IMMEDIATELY
  Actor.Visible := False;
  Actor.ActAlpha := 0.0;
  Actor.TargetAlpha := 0.0;
  // ========================================================================
  // FALL 1: CUSTOM 3D MODEL (Use real vertices, but cap to max 5000)
  // ========================================================================
  if Actor.ShapeType = stModel then
  begin
    if (Actor.FModel.meshes <> nil) and (Actor.FModel.meshes[0].vertices <> nil) then
      Mesh := Actor.FModel.meshes[0]
    else
      Exit;
    if (Mesh.vertexCount > 0) and (Mesh.vertices <> nil) then
    begin
      // Cap to 3000 to prevent massive memory leaks on huge models!
      if Mesh.vertexCount > 3000 then
        BaseMesh.vertexCount := 3000
      else
        BaseMesh.vertexCount := Mesh.vertexCount;
      SetLength(TempVerts, BaseMesh.vertexCount * 3);
      for i := 0 to BaseMesh.vertexCount - 1 do
      begin
        vx := Mesh.vertices[i * 3];
        vy := Mesh.vertices[i * 3 + 1];
        vz := Mesh.vertices[i * 3 + 2];
        TempVerts[i * 3] := vx * Actor.Scale.x;
        TempVerts[i * 3 + 1] := vy * Actor.Scale.y;
        TempVerts[i * 3 + 2] := vz * Actor.Scale.z;
      end;
      BaseMesh.vertices := @TempVerts[0];
      BaseMesh.indices := nil;
      BaseMesh.texcoords := nil;
      BaseMesh.normals := nil;
      BaseMesh.tangents := nil;
      BaseMesh.colors := nil;
      BaseMesh.animVertices := nil;
      BaseMesh.animNormals := nil;
      BaseMesh.boneIndices := nil;
      BaseMesh.boneWeights := nil;
      BaseMesh.vaoId := 0;
      BaseMesh.vboId := nil;
      FParticleEngine.EmitMaterializeMesh(Actor.Position, BaseMesh);
    end;
    Exit;
  end;
  // ========================================================================
  // FALL 2: PRIMITIVES (Reduced Voxel Grid to save memory!)
  // ========================================================================
  GridSize := 6;
  SetLength(FinalVerts, GridSize * GridSize * GridSize * 3);
  vCount := 0;
  LenX := Actor.Scale.x * 0.5;
  LenY := Actor.Scale.y * 0.5;
  LenZ := Actor.Scale.z * 0.5;
  case Actor.ShapeType of
    stSphere:
      begin
        RadSq := Sqr(Max(LenX, Max(LenY, LenZ)));
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              DistSq := Sqr(OffsetX) + Sqr(OffsetY) + Sqr(OffsetZ);
              if DistSq <= RadSq then
              begin
                FinalVerts[vCount] := OffsetX;
                FinalVerts[vCount + 1] := OffsetY;
                FinalVerts[vCount + 2] := OffsetZ;
                Inc(vCount, 3);
              end;
            end;
      end;
    stCapsule:
      begin
        RadSq := Sqr(Max(LenX, LenZ));
        CapY := LenY - Max(LenX, LenZ);
        if CapY < 0 then
          CapY := 0;
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              DistSq := Sqr(OffsetX) + Sqr(OffsetZ);
              if DistSq <= RadSq then
              begin
                if (OffsetY >= -CapY) and (OffsetY <= CapY) then
                begin
                  FinalVerts[vCount] := OffsetX;
                  FinalVerts[vCount + 1] := OffsetY;
                  FinalVerts[vCount + 2] := OffsetZ;
                  Inc(vCount, 3);
                end
                else
                begin
                  if OffsetY > CapY then
                    DistSq := DistSq + Sqr(OffsetY - CapY)
                  else
                    DistSq := DistSq + Sqr(OffsetY + CapY);
                  if DistSq <= RadSq then
                  begin
                    FinalVerts[vCount] := OffsetX;
                    FinalVerts[vCount + 1] := OffsetY;
                    FinalVerts[vCount + 2] := OffsetZ;
                    Inc(vCount, 3);
                  end;
                end;
              end;
            end;
      end;
    stPyramid:
      begin
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              t := 1.0 - ((OffsetY + LenY) / Actor.Scale.y);
              if t < 0 then
                t := 0;
              if (Abs(OffsetX) <= LenX * t) and (Abs(OffsetZ) <= LenZ * t) then
              begin
                FinalVerts[vCount] := OffsetX;
                FinalVerts[vCount + 1] := OffsetY;
                FinalVerts[vCount + 2] := OffsetZ;
                Inc(vCount, 3);
              end;
            end;
      end;
    stPrism:
      begin
        MaxR := Min(LenX, LenZ) * 0.866;
        for i := 0 to GridSize - 1 do
          for j := 0 to GridSize - 1 do
            for k := 0 to GridSize - 1 do
            begin
              OffsetX := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
              OffsetY := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
              OffsetZ := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
              if (Abs(OffsetX) <= MaxR) and (Abs(OffsetZ) <= MaxR) then
              begin
                Angle := ArcTan2(OffsetZ, OffsetX);
                while Angle < 0 do
                  Angle := Angle + 2 * PI;
                while Angle >= 2 * PI do
                  Angle := Angle - 2 * PI;
                if Angle > 2 * PI / 3 then
                  Angle := Angle - 2 * PI / 3;
                if Angle > 2 * PI / 3 then
                  Angle := Angle - 2 * PI / 3;
                if Sqr(OffsetX) + Sqr(OffsetZ) <= Sqr(MaxR / Cos(Angle - PI / 3)) then
                begin
                  FinalVerts[vCount] := OffsetX;
                  FinalVerts[vCount + 1] := OffsetY;
                  FinalVerts[vCount + 2] := OffsetZ;
                  Inc(vCount, 3);
                end;
              end;
            end;
      end
  else
    begin
      // SOLID BOX (Default)
      for i := 0 to GridSize - 1 do
        for j := 0 to GridSize - 1 do
          for k := 0 to GridSize - 1 do
          begin
            FinalVerts[vCount] := ((i / (GridSize - 1)) - 0.5) * Actor.Scale.x;
            FinalVerts[vCount + 1] := ((j / (GridSize - 1)) - 0.5) * Actor.Scale.y;
            FinalVerts[vCount + 2] := ((k / (GridSize - 1)) - 0.5) * Actor.Scale.z;
            Inc(vCount, 3);
          end;
    end;
  end;
  BaseMesh.vertexCount := vCount div 3;
  BaseMesh.vertices := @FinalVerts[0];
  BaseMesh.indices := nil;
  BaseMesh.texcoords := nil;
  BaseMesh.normals := nil;
  BaseMesh.tangents := nil;
  BaseMesh.colors := nil;
  BaseMesh.animVertices := nil;
  BaseMesh.animNormals := nil;
  BaseMesh.boneIndices := nil;
  BaseMesh.boneWeights := nil;
  BaseMesh.vaoId := 0;
  BaseMesh.vboId := nil;
  FParticleEngine.EmitMaterializeMesh(Actor.Position, BaseMesh);
end;

procedure TYutaniRaylibSandbox.TriggerNanoFogDuplicate;
var
  TargetPos: TVector3;
  BaseMesh: TMesh;
  TempVerts: array of Single;
  Mesh: TMesh;
  i: Integer;
  vx, vy, vz: Single;
  NanoShape: TNanoShapeType;
  PrevAvatarID: Integer;
begin
  if not Assigned(FItemSelected) or not Assigned(FNanoFog) then
    Exit;
  // 1. IMMEDIATELY DISSOLVE THE PREVIOUS FORM: The current shape breaks apart
  // and turns back into a roaming swarm before heading to the new target.
  PrevAvatarID := FNanoFogAvatarID - 1;
  if PrevAvatarID > 0 then
    FNanoFog.MorphToFog(PrevAvatarID);
  // Calculate offset position so the duplicate doesn't overlap the original
  TargetPos.x := FItemSelected.Position.x + (FItemSelected.Scale.x * 1.5) + 2.0;
  TargetPos.y := FItemSelected.Position.y;
  TargetPos.z := FItemSelected.Position.z + (FItemSelected.Scale.z * 1.5) + 2.0;
  if FItemSelected.ShapeType = stModel then
  begin
    // CUSTOM 3D MODEL
    if (FItemSelected.FModel.meshes <> nil) and (FItemSelected.FModel.meshes[0].vertices <> nil) then
      Mesh := FItemSelected.FModel.meshes[0]
    else
      Exit;
    if (Mesh.vertexCount > 0) and (Mesh.vertices <> nil) then
    begin
      // Cap to 8000 to prevent memory overload on huge models
      if Mesh.vertexCount > 8000 then
        BaseMesh.vertexCount := 8000
      else
        BaseMesh.vertexCount := Mesh.vertexCount;
      SetLength(TempVerts, BaseMesh.vertexCount * 3);
      for i := 0 to BaseMesh.vertexCount - 1 do
      begin
        vx := Mesh.vertices[i * 3];
        vy := Mesh.vertices[i * 3 + 1];
        vz := Mesh.vertices[i * 3 + 2];
        // Engine handles the uniform scaling internally now
        TempVerts[i * 3] := vx;
        TempVerts[i * 3 + 1] := vy;
        TempVerts[i * 3 + 2] := vz;
      end;
      BaseMesh.vertices := @TempVerts[0];
      BaseMesh.indices := nil;
      BaseMesh.texcoords := nil;
      BaseMesh.normals := nil;
      BaseMesh.tangents := nil;
      BaseMesh.colors := nil;
      BaseMesh.animVertices := nil;
      BaseMesh.animNormals := nil;
      BaseMesh.boneIndices := nil;
      BaseMesh.boneWeights := nil;
      BaseMesh.vaoId := 0;
      BaseMesh.vboId := nil;
      // Send the swarm to form the new mesh
      FNanoFog.EmitMaterializeMesh(TargetPos, BaseMesh, FNanoFogAvatarID);
      Inc(FNanoFogAvatarID);
    end;
  end
  else
  begin
    // PRIMITIVES
    case FItemSelected.ShapeType of
      stBox:
        NanoShape := nstBox;
      stSphere:
        NanoShape := nstSphere;
      stCapsule:
        NanoShape := nstCapsule;
      stPyramid:
        NanoShape := nstPyramid;
      stPrism:
        NanoShape := nstPrism;
    else
      NanoShape := nstBox;
    end;
    // Send the swarm to form the primitive
    FNanoFog.EmitMaterializePrimitive(TargetPos, NanoShape, FItemSelected.Scale, FNanoFogAvatarID);
    Inc(FNanoFogAvatarID);
  end;
end;

procedure TYutaniRaylibSandbox.MorphSelectedToFog;
begin
  // Dissolve the current avatar back into ambient roaming fog
  if Assigned(FNanoFog) and (FNanoFogAvatarID > 1) then
  begin
    FNanoFog.MorphToFog(FNanoFogAvatarID - 1);
    Inc(FNanoFogAvatarID); // Increment so the next build uses a fresh ID
  end;
end;

procedure TYutaniRaylibSandbox.KillNanoFog;
begin
  if Assigned(FNanoFog) then
  begin
    FNanoFog.ExplodeAndKill;
  end;
end;
// ====================================================================
// Galaxy control - forwarded to FSpaceWorld
// ====================================================================
// All four methods are safe to call from the VCL thread. They are
// no-ops when FSpaceWorld is nil (i.e. the user hasn't loaded the
// Space world yet). The VCL should guard the UI buttons with
// (FSandbox.CurrentWorldBase = wbSpace) so they're only enabled
// when relevant, but even without that guard the calls don't crash.

procedure TYutaniRaylibSandbox.ResetUniverse;
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.ResetUniverse;
end;

procedure TYutaniRaylibSandbox.SaveGalaxy;
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.SaveGalaxy;
end;

procedure TYutaniRaylibSandbox.LoadGalaxy;
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.LoadGalaxy;
end;

function TYutaniRaylibSandbox.GetGalaxyDBPath: string;
begin
  if Assigned(FSpaceWorld) then
    Result := FSpaceWorld.GetGalaxyDBPath
  else
    Result := '';
end;
// ====================================================================
// Minimap marker forwarding - to FSpaceWorld
// ====================================================================
// These let the game logic (or VCL for testing) register entities
// that should appear as colored dots in the 3D system minimap. The
// render is nil-guarded so callers don't need to check CurrentWorldBase.

procedure TYutaniRaylibSandbox.ClearMinimapMarkers;
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.ClearMinimapMarkers;
end;

procedure TYutaniRaylibSandbox.AddMinimapMarker(const Pos: TVector3; const Col: TColorB; Size: Single);
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.AddMinimapMarker(Pos, Col, Size);
end;

procedure TYutaniRaylibSandbox.RadarZoomIn;
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.RadarZoomIn;
end;

procedure TYutaniRaylibSandbox.RadarZoomOut;
begin
  if Assigned(FSpaceWorld) then
    FSpaceWorld.RadarZoomOut;
end;

end.

