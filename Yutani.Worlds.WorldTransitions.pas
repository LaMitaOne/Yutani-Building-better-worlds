unit Yutani.Worlds.WorldTransitions;

{==============================================================================*
 *  Yutani World: Transitions - Cinematic World-Swap Effects
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Self-contained transition manager used by Yutani.Core.SetWorldBase
 *    to swap between worlds (Holodeck / Land / Space / Island / YourWorld)
 *    with a cinematic effect instead of an abrupt black cut.
 *
 *  Design:
 *    The manager is owned by the sandbox and driven from the render
 *    thread. The lifecycle is split into four phases:
 *
 *      tpIdle     - no transition in flight, normal rendering
 *      tpOutro    - the OLD world is being warped / stretched out
 *      tpLoading  - the heavy world swap happens behind a tunnel mask
 *      tpIntro    - the NEW world is being warped back in from infinity
 *      tpComplete - just finished, manager resets to tpIdle next Update
 *
 *  Visual Style:
 *    Warp      - the screen is sucked into a vanishing point with radial
 *                streaks flying past the camera, then a brief tunnel
 *                moment, then the new world materializes from infinity
 *                and settles. Inspired by classic Star Trek warp +
 *                2001 Stargate tunnel.
 *    Stretch   - the viewport is pulled vertically into a thin slit
 *                (a "rubber band" snap). Faster + cheaper than Warp.
 *    Fade      - plain alpha fade. Kept as a low-impact fallback for
 *                users who disable the cinematic transitions.
 *
 *  Self-Contained:
 *    The manager allocates its own streak particles, RNG state and
 *    timing state. It does NOT touch any Yutani.Core internals - the
 *    Core is the only caller. To make the warp effect work without
 *    restructuring the existing render pipeline, the transition is
 *    drawn as a 2D overlay ON TOP of the regular framebuffer:
 *
 *      Outro  -> the live old-world scene is overlaid with growing
 *                radial streaks + an inverted vignette that darkens
 *                the edges first, then the whole screen.
 *      Loading-> the screen is fully black with the streak tunnel.
 *      Intro  -> the live new-world scene is overlaid with receding
 *                radial streaks + a clearing vignette.
 *
 *  Integration (minimal - 4 call sites in Yutani.Core):
 *
 *    1) In TYutaniRaylibSandbox.Create:
 *         FWorldTransition := TWorldTransition.Create;
 *
 *    2) In TYutaniRaylibSandbox.Destroy:
 *         FreeAndNil(FWorldTransition);
 *
 *    3) In TYutaniRaylibSandbox.SetWorldBase, at the very top (before
 *       FIsLoadingWorld := True), start the transition:
 *         if Assigned(FWorldTransition) then
 *           FWorldTransition.Start(ttWarp);
 *
 *    4) In the FLoadWorldQueued block, right after
 *       "FIsLoadingWorld := False" near the bottom:
 *         if Assigned(FWorldTransition) then
 *           FWorldTransition.AdvanceToIntro;
 *
 *    5) In TYutaniRaylibSandbox.UpdateGame, near the top (before the
 *       heavy logic):
 *         if Assigned(FWorldTransition) then
 *           FWorldTransition.Update(GetFrameTime());
 *
 *    6) In TYutaniRaylibSandbox.RenderGame, AFTER Render3DScene and
 *       BEFORE DrawGUI (so the GUI is drawn on top of the warp):
 *         if Assigned(FWorldTransition) then
 *           FWorldTransition.Render;
 *
 *    Optional: skip the heavy loading-screen overlay in DrawGUI when
 *    the transition is active - the tunnel already covers the screen:
 *       if FIsLoadingWorld and (not (Assigned(FWorldTransition)
 *          and FWorldTransition.Active)) then
 *         DrawRectangle(0,0,...,Fade(BLACK,0.9));
 *
 *  Note on the heavy-lift freeze:
 *    The current Core blocks the render thread while Space textures
 *    are generated. The transition will therefore render its Outro
 *    up to the moment the heavy lift begins, freeze for the duration
 *    of the lift, then resume in tpLoading once the loop continues.
 *    The "frozen" frame will be the last rendered tunnel frame, so
 *    visually the user still sees the tunnel during the freeze.
 *==============================================================================}
{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Math, Raylib, RayMath, rlgl;

type
  /// <summary>
  /// Transition visual style. Multiple are provided so the host
  /// application can let the user pick one in a settings dialog and
  /// so we can A/B test them. All four share the same lifecycle
  /// (Outro -> Loading -> Intro) so they are interchangeable.
  /// </summary>
  TTransitionType = (
    ttWarp,        // Radial stretch into a vanishing point + tunnel
    ttBlinkEye,     // Vertical rubber-band snap (fast + cheap)
    ttFade         // Plain alpha fade - fallback for low-end hardware
  );

  /// <summary>
  /// Lifecycle phase of the active transition. The Core inspects
  /// this to decide when to perform the heavy world swap (only while
  /// we are in tpLoading so the swap is masked by the tunnel).
  /// </summary>
  TTransitionPhase = (
    tpIdle,       // No transition in flight. Render() is a no-op.
    tpOutro,      // Old world is being warped out. Host renders the live old scene.
    tpLoading,    // Heavy world swap happens here. We render the tunnel only.
    tpIntro,      // New world is being warped in. Host renders the live new scene.
    tpComplete    // Just finished. Update() will reset to tpIdle.
  );

  /// <summary>
  /// Single streak used by the warp / hyperspace tunnel. Streaks are
  /// generated around the screen center and accelerated outward to
  /// fake the parallax rush of lightspeed travel.
  /// </summary>
  TWarpStreak = record
    Angle: Single;       // Direction from screen center, radians
    Distance: Single;    // Current distance from center, pixels
    Speed: Single;       // Outward velocity, pixels / second
    Length: Single;      // Streak tail length, pixels
    Brightness: Single; // 0..1 multiplier
    Hue: Byte;           // Palette index - see PickStreakColor
  end;
  PStreakArray = ^TStreakArray;
  TStreakArray = array[0..0] of TWarpStreak;

  /// <summary>
  /// Main transition manager. The host application owns exactly one
  /// instance and calls Start() at the beginning of a world swap,
  /// Update()+Render() every frame while Active is True, and
  /// AdvanceToIntro() once the new world has finished loading.
  /// </summary>
  TWorldTransition = class
  private
    FActive: Boolean;
    FPhase: TTransitionPhase;
    FType: TTransitionType;
    FProgress: Single;        // 0..1 within the current phase
    FElapsed: Single;         // seconds since Start() / since phase began
    FOutroDuration: Single;
    FLoadingMinDuration: Single;
    FIntroDuration: Single;
    FReadyForIntro: Boolean;  // set by AdvanceToIntro()
    FStreaks: array of TWarpStreak;
    FStreakCount: Integer;
    FRngState: Cardinal;
    FCenterX: Single;         // cached screen center
    FCenterY: Single;
    FFlashAlpha: Single;      // one-shot white flash at the swap moment
    FInvVignetteAlpha: Single;// 0..1, darkness of the inverted vignette
    procedure SeedRand(Seed: Cardinal);
    function NextRand: Single;
    procedure Recenter;
    procedure SpawnStreaks(Count: Integer; ResetAll: Boolean = False);
    procedure UpdateStreaks(dt: Single);
    procedure DrawStreaks(Alpha: Single);
    procedure DrawInvertedVignette(Alpha: Single);
    procedure DrawCenterFlash(Alpha: Single);
    procedure DrawStretchBars(Progress: Single);
    procedure AdvancePhase;
    function PickStreakColor(Hue: Byte; Alpha: Byte): TColorB;
  public
    constructor Create;
    destructor Destroy; override;

    /// <summary>
    /// Kicks off a new transition of the given type. Safe to call
    /// while another transition is running - the old one is
    /// discarded and a fresh Outro phase starts immediately.
    /// </summary>
    procedure Start(AType: TTransitionType;
      OutroDuration: Single = 0.6;
      LoadingMinDuration: Single = 0.4;
      IntroDuration: Single = 0.6); virtual;

    /// <summary>
    /// Advances one frame. Must be called every frame while Active
    /// is True so the timing stays smooth.
    /// </summary>
    procedure Update(dt: Single);

    /// <summary>
    /// Draws the transition overlay on top of the live framebuffer.
    /// Call this INSIDE BeginDrawing / EndDrawing, AFTER the 3D
    /// scene has been rendered (and ideally before the GUI). The
    /// method is a no-op when Active is False.
    /// </summary>
    procedure Render; virtual;

    /// <summary>
    /// Tells the manager that the heavy world swap is done and the
    /// new world is ready to be revealed. The manager will leave
    /// the tpLoading phase on the next Update() - either immediately
    /// if FLoadingMinDuration has already elapsed, or as soon as the
    /// minimum tunnel time is up.
    /// </summary>
    procedure AdvanceToIntro;

    /// <summary>
    /// Hard-resets the manager to tpIdle. Use this to abort a
    /// transition in flight (e.g. if the world swap fails and the
    /// host decides to fall back to the old world).
    /// </summary>
    procedure Cancel;

    property Active: Boolean read FActive;
    property Phase: TTransitionPhase read FPhase;
    property Progress: Single read FProgress;
    property TransitionType: TTransitionType read FType;
    property OutroDuration: Single read FOutroDuration write FOutroDuration;
    property LoadingMinDuration: Single read FLoadingMinDuration write FLoadingMinDuration;
    property IntroDuration: Single read FIntroDuration write FIntroDuration;
  end;

implementation

const
  DEFAULT_OUTRO_DURATION   = 0.6;
  DEFAULT_LOADING_MIN      = 0.4;
  DEFAULT_INTRO_DURATION   = 0.6;

  // Streak palette. Hue byte indexes this table. Keep the count in
  // sync with the Hue mod below or the modulo will mask the bug.
  STREAK_PALETTE: array[0..4] of TColorB = (
    (r: 255; g: 255; b: 255; a: 255),  // 0 - pure white
    (r: 180; g: 220; b: 255; a: 255),  // 1 - cool blue
    (r: 140; g: 255; b: 240; a: 255),  // 2 - cyan
    (r: 255; g: 230; b: 180; a: 255),  // 3 - warm sun
    (r: 220; g: 180; b: 255; a: 255)   // 4 - purple
  );

  STREAK_COUNT_WARP       = 90;
  STREAK_COUNT_HYPERSPACE = 180;

{ TWorldTransition }

constructor TWorldTransition.Create;
begin
  inherited Create;
  FActive := False;
  FPhase := tpIdle;
  FType := ttBlinkEye;
  FProgress := 0.0;
  FElapsed := 0.0;
  FOutroDuration := DEFAULT_OUTRO_DURATION;
  FLoadingMinDuration := DEFAULT_LOADING_MIN;
  FIntroDuration := DEFAULT_INTRO_DURATION;
  FReadyForIntro := False;
  FStreaks := nil;
  FStreakCount := 0;
  FRngState := Cardinal($5EED1234);
  FCenterX := 0;
  FCenterY := 0;
  FFlashAlpha := 0.0;
  FInvVignetteAlpha := 0.0;
end;

destructor TWorldTransition.Destroy;
begin
  FStreaks := nil;
  inherited;
end;

procedure TWorldTransition.SeedRand(Seed: Cardinal);
begin
  // xorshift32 - good enough for visual randomness, deterministic
  // so the streak pattern is reproducible for debugging.
  if Seed = 0 then
    Seed := 1;
  FRngState := Seed;
end;

function TWorldTransition.NextRand: Single;
begin
  FRngState := FRngState xor (FRngState shl 13);
  FRngState := FRngState xor (FRngState shr 17);
  FRngState := FRngState xor (FRngState shl 5);
  Result := (FRngState and $00FFFFFF) / $00FFFFFF;
end;

procedure TWorldTransition.Recenter;
var
  W, H: Integer;
begin
  // Cache screen center once per call - cheap and avoids per-streak
  // division by 2 in the inner loop.
  W := GetScreenWidth();
  H := GetScreenHeight();
  FCenterX := W * 0.5;
  FCenterY := H * 0.5;
end;

procedure TWorldTransition.SpawnStreaks(Count: Integer; ResetAll: Boolean);
var
  I: Integer;
  Streak: ^TWarpStreak;
  MaxDim: Single;
begin
  if Count <= 0 then
  begin
    FStreaks := nil;
    FStreakCount := 0;
    Exit;
  end;
  Recenter;
  // Streaks live in a 2D space measured from the screen center, so
  // we use the larger screen dimension as the natural unit.
  MaxDim := Max(GetScreenWidth(), GetScreenHeight());
  if MaxDim <= 0 then
    MaxDim := 1080.0;
  if ResetAll or (Length(FStreaks) < Count) then
    SetLength(FStreaks, Count);
  FStreakCount := Count;
  for I := 0 to Count - 1 do
  begin
    Streak := @FStreaks[I];
    Streak^.Angle := NextRand * 2.0 * PI;
    // On a full reset we spread streaks across the whole screen so
    // the first frame doesn't show a tight cluster at the center.
    // On a soft repopulation (e.g. transition just started) we
    // start them close to the vanishing point so they emerge from it.
    if ResetAll then
      Streak^.Distance := NextRand * MaxDim * 0.5
    else
      Streak^.Distance := NextRand * 30.0;
    Streak^.Speed := 80.0 + NextRand * 220.0;
    Streak^.Length := 10.0 + NextRand * 60.0;
    Streak^.Brightness := 0.4 + NextRand * 0.6;
    Streak^.Hue := Trunc(NextRand * 5);
  end;
end;

procedure TWorldTransition.UpdateStreaks(dt: Single);
var
  I: Integer;
  Streak: ^TWarpStreak;
  MaxDim: Single;
  CullRadius: Single;
  Accel: Single;
begin
  if (FStreakCount = 0) or (Length(FStreaks) = 0) then
    Exit;
  Recenter;
  MaxDim := Max(GetScreenWidth(), GetScreenHeight());
  if MaxDim <= 0 then
    MaxDim := 1080.0;
  // Streaks get culled once they fly past the visible radius - we add
  // a 25% margin so streaks don't visually pop out at the screen edge.
  CullRadius := MaxDim * 0.75;
  // Acceleration grows with phase progress so the warp "ramps up"
  // rather than feeling linear. We also bias the speed by current
  // distance so far streaks move even faster (parallax rush).
  Accel := 1.0 + (FProgress * 1.5);
  for I := 0 to FStreakCount - 1 do
  begin
    Streak := @FStreaks[I];
    Streak^.Distance := Streak^.Distance + (Streak^.Speed * Accel * dt);
    // Tail length grows with distance so streaks look like they
    // smear out at high speed, just like real motion blur.
    Streak^.Length := 10.0 + (Streak^.Distance * 0.18);
    if Streak^.Distance > CullRadius then
    begin
      // Respawn near center with a fresh random angle + speed.
      Streak^.Angle := NextRand * 2.0 * PI;
      Streak^.Distance := NextRand * 30.0;
      Streak^.Speed := 80.0 + NextRand * 220.0;
      Streak^.Brightness := 0.4 + NextRand * 0.6;
      Streak^.Hue := Trunc(NextRand * 5);
    end;
  end;
end;

function TWorldTransition.PickStreakColor(Hue: Byte; Alpha: Byte): TColorB;
begin
  if Hue > High(STREAK_PALETTE) then
    Hue := 0;
  Result := STREAK_PALETTE[Hue];
  Result.a := Alpha;
end;

procedure TWorldTransition.DrawStreaks(Alpha: Single);
var
  I: Integer;
  Streak: ^TWarpStreak;
  CosA, SinA: Single;
  X1, Y1, X2, Y2: Single;
  Col: TColorB;
  AlphaB: Byte;
begin
  if (FStreakCount = 0) or (Alpha <= 0.0) then
    Exit;
  Recenter;
  // Use rlBegin/rlEnd so all streaks are batched into a single draw
  // call. Calling DrawLine per streak would flush the render batch
  // 180+ times per frame which is wasteful for a 2D overlay.
  rlSetBlendMode(BLEND_ADDITIVE);
  rlBegin(RL_LINES);
  try
    for I := 0 to FStreakCount - 1 do
    begin
      Streak := @FStreaks[I];
      if Streak^.Brightness <= 0 then
        Continue;
      CosA := Cos(Streak^.Angle);
      SinA := Sin(Streak^.Angle);
      // Streak head (further from center, brighter)
      X1 := FCenterX + (CosA * Streak^.Distance);
      Y1 := FCenterY + (SinA * Streak^.Distance);
      // Streak tail (closer to center, dimmer - the parallax fade)
      X2 := FCenterX + (CosA * (Streak^.Distance - Streak^.Length));
      Y2 := FCenterY + (SinA * (Streak^.Distance - Streak^.Length));
      AlphaB := Trunc(EnsureRange(
        Streak^.Brightness * Alpha * 255, 0, 255));
      Col := PickStreakColor(Streak^.Hue, AlphaB);
      // Head vertex (bright)
      rlColor4ub(Col.r, Col.g, Col.b, Col.a);
      rlVertex2f(X1, Y1);
      // Tail vertex (transparent - fades to nothing for the streak trail)
      rlColor4ub(Col.r, Col.g, Col.b, 0);
      rlVertex2f(X2, Y2);
    end;
  finally
    rlEnd;
  end;
  rlDrawRenderBatchActive;
  rlSetBlendMode(BLEND_ALPHA);
end;

procedure TWorldTransition.DrawInvertedVignette(Alpha: Single);
var
  W, H: Integer;
  CX, CY: Single;
  R: Single;
  Center: TVector2;
begin
  // The vignette darkens from the EDGES inward, simulating the
  // "everything gets sucked into a vanishing point" feel.
  // DrawCircleGradient draws a filled circle whose color goes from
  // inner (center) to outer (edge). If the radius covers the
  // diagonal, the whole screen is filled by the gradient.
  // NOTE: This Raylib binding takes (TVector2, Single, TColorB,
  // TColorB) - older bindings used (Integer, Integer, Integer,
  // TColorB, TColorB). We build the TVector2 explicitly so the
  // unit is compatible with the current Raylib.pas.
  if Alpha <= 0.0 then
    Exit;
  W := GetScreenWidth();
  H := GetScreenHeight();
  if (W <= 0) or (H <= 0) then
    Exit;
  CX := W * 0.5;
  CY := H * 0.5;
  // +2 px so the gradient extends just past the corners and we
  // don't get a one-pixel hairline of un-darkened background at
  // the very corner of the viewport.
  R := Sqrt(Sqr(W * 0.5) + Sqr(H * 0.5)) + 2.0;
  Center := Vector2Create(CX, CY);
  DrawCircleGradient(Center, R, Fade(BLACK, 0), Fade(BLACK, Alpha));
end;

procedure TWorldTransition.DrawCenterFlash(Alpha: Single);
var
  CX, CY: Integer;
begin
  if Alpha <= 0.0 then
    Exit;
  CX := GetScreenWidth() div 2;
  CY := GetScreenHeight() div 2;
  // A bright additive flash at the swap moment - hides any residual
  // frame where the new world hasn't quite settled yet.
  rlSetBlendMode(BLEND_ADDITIVE);
  DrawCircle(CX, CY, 80, Fade(WHITE, Alpha));
  DrawCircle(CX, CY, 160, Fade(WHITE, Alpha * 0.4));
  rlSetBlendMode(BLEND_ALPHA);
end;

procedure TWorldTransition.DrawStretchBars(Progress: Single);
var
  W, H: Integer;
  VisibleH: Integer;
  BlackH: Integer;
begin
  // Stretch effect: the visible viewport shrinks vertically into
  // a thin slit, then snaps back open with the new world. Cheap
  // to draw (two rectangles) but still stylish.
  W := GetScreenWidth();
  H := GetScreenHeight();
  if (W <= 0) or (H <= 0) then
    Exit;
  VisibleH := Trunc(H * (1.0 - Progress));
  if VisibleH < 4 then
    VisibleH := 4;
  BlackH := (H - VisibleH) div 2;
  DrawRectangle(0, 0, W, BlackH, BLACK);
  DrawRectangle(0, H - BlackH, W, BlackH, BLACK);
end;

procedure TWorldTransition.AdvancePhase;
begin
  case FPhase of
    tpOutro:
      begin
        FPhase := tpLoading;
        FProgress := 0.0;
        FElapsed := 0.0;
        FReadyForIntro := False;
        // DO NOT respawn streaks here. The streaks from the Outro
        // continue flying outward and naturally cycle (respawn
        // near center when they fly off screen) via UpdateStreaks.
        // Resetting them here would cause a visible "restart" jump
        // where all streaks snap back to random positions across
        // the screen, which the user sees as the transition
        // starting a second time. The initial SpawnStreaks in
        // Start() already uses full density so there is no density
        // jump when entering tpLoading.
      end;
    tpLoading:
      begin
        FPhase := tpIntro;
        FProgress := 0.0;
        FElapsed := 0.0;
        // White flash DISABLED. The user found the two additive
        // white circles at the swap moment ugly and asked for them
        // to be removed. FFlashAlpha stays 0 so DrawCenterFlash
        // is never called. The field + procedure are kept so a
        // future variant can re-enable the flash via a config flag.
        FFlashAlpha := 0.0;
      end;
    tpIntro:
      begin
        FPhase := tpComplete;
      end;
    tpComplete:
      begin
        FActive := False;
        FPhase := tpIdle;
        FStreaks := nil;
        FStreakCount := 0;
        FFlashAlpha := 0.0;
        FInvVignetteAlpha := 0.0;
        FReadyForIntro := False;
      end;
  end;
end;

procedure TWorldTransition.Start(AType: TTransitionType;
  OutroDuration: Single;
  LoadingMinDuration: Single;
  IntroDuration: Single);
begin
  // Hard reset - any in-flight transition is discarded so the new
  // one starts from a clean state. This is important because the
  // host may abort a long Space load by switching back to Holodeck.
  FActive := True;
  FPhase := tpOutro;
  FType := AType;
  FProgress := 0.0;
  FElapsed := 0.0;
  FReadyForIntro := False;
  FFlashAlpha := 0.0;
  FInvVignetteAlpha := 0.0;
  // Clamp durations to sensible minimums so a misconfigured caller
  // can't trigger a divide-by-zero or an instant snap.
  if OutroDuration < 0.05 then
    OutroDuration := 0.05;
  if LoadingMinDuration < 0.0 then
    LoadingMinDuration := 0.0;
  if IntroDuration < 0.05 then
    IntroDuration := 0.05;
  FOutroDuration := OutroDuration;
  FLoadingMinDuration := LoadingMinDuration;
  FIntroDuration := IntroDuration;
  // Seed the RNG with the current time + a random salt so each
  // transition looks slightly different even when triggered back
  // to back.
  SeedRand(Cardinal(Trunc(GetTime() * 1000)) xor Cardinal(Random(MaxInt)));
  // Seed the initial streak pool at full density. The quadratic
  // alpha curve in Render starts the streaks at alpha=0 so the
  // old scene is still readable at the beginning of the Outro
  // even with the full streak count. Using full density from the
  // start means there is no density jump when advancing to
  // tpLoading (we no longer respawn streaks there).
  case FType of
    ttFade:       SpawnStreaks(0, True);
    ttBlinkEye:   SpawnStreaks(0, True);
  else
    SpawnStreaks(STREAK_COUNT_WARP, True);
  end;
end;

procedure TWorldTransition.Update(dt: Single);
var
  Duration: Single;
begin
  if (not FActive) or (dt <= 0.0) then
    Exit;
  FElapsed := FElapsed + dt;
  // Always update streaks + flash decay even across phase
  // boundaries so the tunnel never freezes mid-frame.
  UpdateStreaks(dt);
  if FFlashAlpha > 0.0 then
  begin
    FFlashAlpha := FFlashAlpha - (dt * 2.5);
    if FFlashAlpha < 0.0 then
      FFlashAlpha := 0.0;
  end;
  case FPhase of
    tpOutro:
      begin
        Duration := FOutroDuration;
        FProgress := EnsureRange(FElapsed / Duration, 0.0, 1.0);
        // Vignette uses a CUBIC ease-in so it starts very slow -
        // the old world stays clearly visible for the first ~40%
        // of the Outro, then the vignette ramps up and darkens
        // the edges inward. This produces the "old world fades
        // out" feel the user asked for instead of the previous
        // "snap to black" jump. The *1.5 multiplier ensures we
        // reach full darkness (alpha=1) before the end of the
        // Outro so the transition into tpLoading (solid black)
        // is seamless.
        FInvVignetteAlpha := EnsureRange(
          FProgress * FProgress * FProgress * 1.5, 0.0, 1.0);
        if FElapsed >= Duration then
          AdvancePhase;
      end;
    tpLoading:
      begin
        Duration := FLoadingMinDuration;
        FProgress := EnsureRange(FElapsed / Duration, 0.0, 1.0);
        FInvVignetteAlpha := 1.0;
        // The host calls AdvanceToIntro() when the heavy swap is
        // done. We still enforce a minimum tunnel duration so very
        // fast swaps don't end with a jarring snap.
        if FReadyForIntro and (FElapsed >= Duration) then
          AdvancePhase;
      end;
    tpIntro:
      begin
        Duration := FIntroDuration;
        FProgress := EnsureRange(FElapsed / Duration, 0.0, 1.0);
        // Vignette clears back out so the new world becomes visible.
        FInvVignetteAlpha := EnsureRange(1.0 - FProgress, 0.0, 1.0);
        if FElapsed >= Duration then
          AdvancePhase;
      end;
    tpComplete:
      AdvancePhase;
  end;
end;

procedure TWorldTransition.Render;
var
  W, H: Integer;
  StreakAlpha: Single;
begin
  if not FActive then
    Exit;
  W := GetScreenWidth();
  H := GetScreenHeight();
  if (W <= 0) or (H <= 0) then
    Exit;
  case FPhase of
    tpOutro:
      begin
        // Outro: old world is still drawn underneath by the host.
        // We draw streaks FIRST (so they appear over the live old
        // world) then the inverted vignette on top. Streaks use a
        // QUADRATIC ease-in so they appear BEFORE the vignette
        // darkens - the user sees streaks building up over the
        // visible old world, THEN the world fades to black, THEN
        // the pure tunnel takes over in tpLoading.
        case FType of
          ttWarp:
            begin
              StreakAlpha := EnsureRange(
                FProgress * FProgress, 0.0, 1.0);
              DrawStreaks(StreakAlpha);
              DrawInvertedVignette(FInvVignetteAlpha);
            end;
          ttBlinkEye:
            begin
              // The bars grow over the screen, eating the live old
              // world from top + bottom.
              DrawStretchBars(FProgress);
            end;
          ttFade:
            begin
              DrawRectangle(0, 0, W, H, Fade(BLACK, FProgress));
            end;
        end;
      end;
    tpLoading:
      begin
        // Loading: pure tunnel. Host renders nothing meaningful
        // underneath (or renders into a hidden target) - we cover
        // the whole screen with black + streaks.
        DrawRectangle(0, 0, W, H, BLACK);
        case FType of
          ttWarp:
            DrawStreaks(1.0);
          ttBlinkEye:
            DrawStretchBars(1.0);
          ttFade:
            ; // Already drawn as solid black above.
        end;
      end;
    tpIntro:
      begin
        // Intro: new world is already drawn underneath by the host.
        // We overlay the same warp in reverse: streaks recede,
        // vignette clears, flash fades.
        case FType of
          ttWarp:
            begin
              StreakAlpha := EnsureRange((1.0 - FProgress) * 1.5, 0.0, 1.0);
              DrawStreaks(StreakAlpha);
              DrawInvertedVignette(FInvVignetteAlpha);
            end;
          ttBlinkEye:
            DrawStretchBars(1.0 - FProgress);
          ttFade:
            DrawRectangle(0, 0, W, H, Fade(BLACK, 1.0 - FProgress));
        end;
        // White flash at the swap moment was removed per user
        // request - the two additive white circles looked bad.
        // FFlashAlpha is always 0 now so DrawCenterFlash is a
        // no-op even if called, but we skip the call entirely
        // for cleanliness.
      end;
  end;
end;

procedure TWorldTransition.AdvanceToIntro;
begin
  // Called by the host once the new world has finished loading.
  // We don't immediately leave tpLoading - Update() enforces the
  // minimum tunnel duration before advancing to tpIntro.
  FReadyForIntro := True;
end;

procedure TWorldTransition.Cancel;
begin
  // Hard reset to idle. Used if the host aborts a world swap.
  FActive := False;
  FPhase := tpIdle;
  FProgress := 0.0;
  FElapsed := 0.0;
  FReadyForIntro := False;
  FFlashAlpha := 0.0;
  FInvVignetteAlpha := 0.0;
  FStreaks := nil;
  FStreakCount := 0;
end;

end.

