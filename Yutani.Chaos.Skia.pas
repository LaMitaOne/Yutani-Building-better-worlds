unit Yutani.Chaos.Skia;

{==============================================================================*
 *  Yutani C.H.A.O.S. Skia Version v0.1 - Complete Holographic AI Operating System

 *------------------------------------------------------------------------------
 *  Module : Yutani.Chaos.Skia
 *  Type   : Complete Holographic AI Operating System - Interface
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *------------------------------------------------------------------------------
 *  Description:
 *  This unit renders a dynamic, holographic AI face ("Chaos") using a custom
 *  particle system. Instead of standard Skia VCL controls, it manually creates
 *  an off-screen ISkSurface, draws complex 3D-projected particles, glow effects,
 *  and circuit lines. The rendered frame is encoded to a PNG stream, loaded into
 *  a 32-bit VCL bitmap, and finally pushed to a transparent, click-through
 *  Windows layered window via the UpdateLayeredWindow API.
 *  It features full build-up (formation) and tear-down (gravity fade) animations.
 *==============================================================================}

interface

uses
  Winapi.Windows, Winapi.MMSystem, System.SysUtils, System.Classes, System.Types,
  System.UITypes, System.Math, System.Math.Vectors, System.SyncObjs,
  System.Diagnostics, System.Generics.Collections, System.Generics.Defaults,
  Vcl.Forms, Vcl.Graphics, Vcl.Imaging.pngimage, Skia;

type
  TMouthState = (msClosed, msMin, msMid, msFull);

  TEyeState = (esOpen, esMid, esClosed);

  TChaosState = (csIdle, csForming, csActive, csFading, csFinished);

  TParticleType = (ptOutline, ptFill, ptEyeL, ptEyeR, ptMouth);

  TParticle = record
    Pos3D, Target3D, Base3D: TPoint3D;
    Vel: TPointF;
    BaseAngle: Single;
    PType: TParticleType;
    LayerIndex: Integer;
    LifeTime: Double;
    ReachedTarget: Boolean;
    IsFading: Boolean; // NEW: Used for the tear-down / fade-out animation
  end;

  { TSkChaos }
  TSkChaos = class
  private
    FForm: TForm;
    FBuffer: TBitmap;
    FState: TChaosState;
    FStateTimer: Double;
    FAlpha: Single;
    FThread: TThread;
    FLock: TCriticalSection;
    FThreadActive: Boolean;
    FParticles: array of TParticle;
    FNextTargetIdx: Integer;
    FGlobalTime: Double;
    FScanY: Single;
    FMinY: Single;
    FMaxY: Single;
    FFormWidth: Integer;
    FFormHeight: Integer;
    FDespawnY: Single; // NEW: Scanline for the tear-down animation

    FDepthMap: TPngImage;

    FMouthState: TMouthState;
    FEyeOverride: TEyeState;
    FFaceColor: TAlphaColor;
    FEyeColor: TAlphaColor;
    FMouthColor: TAlphaColor;

    FBlinkTimer: Double;
    FIsBlinking: Boolean;
    FCurrentEyeRY: Single;
    FLookX, FLookY: Single;
    FCenterOffset: TPointF;

    // Skia manual rendering surface and canvas
    FSkSurface: ISkSurface;
    FSkCanvas: ISkCanvas;

    procedure MakeClickThrough;
    procedure UpdateWindow;
    procedure GenerateFaceTargets;
    procedure InitParticles;
    procedure UpdateTargets;
    procedure UpdateParticles(const DeltaTime: Double);
    procedure RenderFrame;
    procedure StartThread;
    procedure StopThread;
    procedure SetMouthState(const Value: TMouthState);
    function Project3DTo2D(const P: TPoint3D): TPointF;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;

    property MouthState: TMouthState read FMouthState write SetMouthState;
    property EyeOverride: TEyeState read FEyeOverride write FEyeOverride;
    property FaceColor: TAlphaColor read FFaceColor write FFaceColor;
    property EyeColor: TAlphaColor read FEyeColor write FEyeColor;
    property MouthColor: TAlphaColor read FMouthColor write FMouthColor;
  end;

implementation

{ TSkChaos }

constructor TSkChaos.Create;
var
  ExePath, DepthMapFile: string;
begin
  FFormWidth := 236;
  FFormHeight := 252;

  // Initialize the transparent borderless form
  FForm := TForm.Create(nil);
  FForm.FormStyle := fsStayOnTop;
  FForm.BorderStyle := bsNone;
  FForm.Color := clBlack;
  FForm.ClientWidth := FFormWidth;
  FForm.ClientHeight := FFormHeight;
  FForm.Left := Screen.WorkAreaRect.Right - FFormWidth - 20;
  FForm.Top := Screen.WorkAreaRect.Bottom - FFormHeight - 50;
  MakeClickThrough;

  // VCL Bitmap buffer used to bridge Skia graphics to the Windows API
  FBuffer := TBitmap.Create;
  FBuffer.PixelFormat := pf32bit;
  FBuffer.AlphaFormat := afDefined;
  FBuffer.SetSize(FFormWidth, FFormHeight);

  FFaceColor := $FF00BFFF;
  FEyeColor := $FF00BFFF;
  FMouthColor := $FF00BFFF;

  FMouthState := msMin;
  FEyeOverride := esOpen;
  FCenterOffset := TPointF.Create(FFormWidth / 2, FFormHeight / 2);

  // Load the depth map for procedural particle generation
  ExePath := ExtractFilePath(ParamStr(0));
  DepthMapFile := ExePath + 'depthmap.png';
  if FileExists(DepthMapFile) then
  begin
    FDepthMap := TPngImage.Create;
    try
      FDepthMap.LoadFromFile(DepthMapFile);
    except
      FreeAndNil(FDepthMap);
    end;
  end
  else
    FDepthMap := nil;

  FLock := TCriticalSection.Create;

  // Manual Skia setup: Create an off-screen raster surface and get its canvas
  FSkSurface := TSkSurface.MakeRaster(TSkImageInfo.Create(FFormWidth, FFormHeight));
  FSkCanvas := FSkSurface.Canvas;

  GenerateFaceTargets;
end;

destructor TSkChaos.Destroy;
begin
  StopThread;
  FBuffer.Free;
  FDepthMap.Free;
  FForm.Free;
  FLock.Free;
  inherited;
end;

procedure TSkChaos.MakeClickThrough;
begin
  // Make the window layered and click-through
  SetWindowLong(FForm.Handle, GWL_EXSTYLE, GetWindowLong(FForm.Handle, GWL_EXSTYLE) or WS_EX_LAYERED or WS_EX_TRANSPARENT);
end;

procedure TSkChaos.SetMouthState(const Value: TMouthState);
begin
  FLock.Enter;
  try
    FMouthState := Value;
  finally
    FLock.Leave;
  end;
end;

procedure TSkChaos.GenerateFaceTargets;
var
  TmpList: TList<TParticle>;
  X, Y, Step, OffsetY: Integer;
  PixelColor: TColor;
  R: Byte;
  Helligkeit, ScaleFactor: Single; // Helligkeit = Brightness/Depth
  P: TParticle;
  Angle, Radius: Single;
  I: Integer;
begin
  TmpList := TList<TParticle>.Create;
  try
    ScaleFactor := 0.75;

    if Assigned(FDepthMap) then
    begin
      Step := 10;
      OffsetY := 28;

      // Sample the depth map to generate the fill particles
      for Y := OffsetY to FDepthMap.Height - 1 do
      begin
        if (Y - OffsetY) mod Step <> 0 then
          Continue;

        for X := 0 to FDepthMap.Width - 1 do
        begin
          if X mod Step <> 0 then
            Continue;

          PixelColor := FDepthMap.Pixels[X, Y];
          R := GetRValue(PixelColor);

          if R > 5 then
          begin
            Helligkeit := R / 255.0;

            P.PType := ptFill;
            P.LayerIndex := X div Step;
            P.BaseAngle := 0;
            P.IsFading := False;

            // Map 2D coordinates to 3D space using brightness as Z-depth
            P.Base3D := TPoint3D.Create((X - (FDepthMap.Width / 2)) * ScaleFactor, ((Y - OffsetY) - ((FDepthMap.Height - OffsetY) / 2)) * ScaleFactor, Helligkeit * 112.5);
            P.Target3D := P.Base3D;
            TmpList.Add(P);
          end;
        end;
      end;
    end
    else
    begin
      // Fallback: Procedural ring if no depth map is found
      for I := 0 to 299 do
      begin
        Angle := (I / 300) * 2 * Pi;
        Radius := 90;
        P.PType := ptFill;
        P.LayerIndex := I mod 15;
        P.Base3D := TPoint3D.Create(Cos(Angle) * Radius, Sin(Angle) * Radius, 33.75);
        P.Target3D := P.Base3D;
        P.IsFading := False;
        TmpList.Add(P);
      end;
    end;

    // Left Eye generation
    for I := 0 to 49 do
    begin
      Angle := (I / 50) * 2 * Pi;
      P.BaseAngle := Angle;
      P.PType := ptEyeL;
      P.LayerIndex := 200;
      P.Base3D := TPoint3D.Create((-45 + Cos(Angle) * 22) * ScaleFactor, (-50 + Sin(Angle) * 8) * ScaleFactor, 40.0);
      P.Target3D := P.Base3D;
      P.IsFading := False;
      TmpList.Add(P);
    end;

    // Right Eye generation
    for I := 0 to 49 do
    begin
      Angle := (I / 50) * 2 * Pi;
      P.BaseAngle := Angle;
      P.PType := ptEyeR;
      P.LayerIndex := 201;
      P.Base3D := TPoint3D.Create((45 + Cos(Angle) * 22) * ScaleFactor, (-50 + Sin(Angle) * 8) * ScaleFactor, 40.0);
      P.Target3D := P.Base3D;
      P.IsFading := False;
      TmpList.Add(P);
    end;

    // Mouth generation
    for I := 0 to 39 do
    begin
      Angle := (I / 40) * 2 * Pi;
      P.BaseAngle := Angle;
      P.PType := ptMouth;
      P.LayerIndex := 300;
      P.Base3D := TPoint3D.Create((Cos(Angle) * 35) * ScaleFactor, (65 + Sin(Angle) * 4) * ScaleFactor, 35.0);
      P.Target3D := P.Base3D;
      P.IsFading := False;
      TmpList.Add(P);
    end;

    // Sort particles top-to-bottom, left-to-right for the scanning animation
    TmpList.Sort(TComparer<TParticle>.Construct(
      function(const Left, Right: TParticle): Integer
      begin
        if Abs(Left.Target3D.Y - Right.Target3D.Y) < 1.5 then
          Result := Round(Left.Target3D.X - Right.Target3D.X)
        else if Left.Target3D.Y < Right.Target3D.Y then
          Result := -1
        else
          Result := 1;
      end));

    SetLength(FParticles, TmpList.Count);
    FMinY := 10000;
    FMaxY := 0;
    for I := 0 to TmpList.Count - 1 do
    begin
      FParticles[I] := TmpList[I];
      if FParticles[I].Target3D.Y < FMinY then
        FMinY := FParticles[I].Target3D.Y;
      if FParticles[I].Target3D.Y > FMaxY then
        FMaxY := FParticles[I].Target3D.Y;
    end;
  finally
    TmpList.Free;
  end;
end;

procedure TSkChaos.InitParticles;
var
  I: Integer;
begin
  for I := 0 to High(FParticles) do
  begin
    FParticles[I].LifeTime := -1;
    FParticles[I].ReachedTarget := False;
    FParticles[I].IsFading := False;
  end;
  FNextTargetIdx := 0;
  FGlobalTime := 0;
  FScanY := FMinY;
  FDespawnY := FMinY; // Initialize for tear-down
end;

function TSkChaos.Project3DTo2D(const P: TPoint3D): TPointF;
var
  RotX, RotY: Single;
  X, Y, Z: Single;
begin
  // Simple 3D to 2D projection based on mouse look offsets
  RotY := -FLookX * 0.4;
  X := P.X * Cos(RotY) - P.Z * Sin(RotY);
  Z := P.X * Sin(RotY) + P.Z * Cos(RotY);

  RotX := -FLookY * 0.18;
  Y := P.Y * Cos(RotX) - Z * Sin(RotX);
  Z := P.Y * Sin(RotX) + Z * Cos(RotX);

  Result := TPointF.Create(X, Y + 15.0);
end;

procedure TSkChaos.UpdateTargets;
var
  I: Integer;
  MouthRY, EyeRY: Single;
  X, Y, Z: Single;
  ScaleFactor: Single;
  LookOffset: TPoint3D;
begin
  ScaleFactor := 0.75;

  // Calculate mouth opening radius
  case FMouthState of
    msClosed:
      MouthRY := 1.0;
    msMin:
      MouthRY := 5.0;
    msMid:
      MouthRY := 12.0;
    msFull:
      MouthRY := 20.0;
  else
    MouthRY := 1.0;
  end;

  // Calculate eye opening radius
  if (FEyeOverride = esClosed) or (FIsBlinking) then
    EyeRY := 0.5
  else if (FEyeOverride = esMid) then
    EyeRY := 4.0
  else
    EyeRY := 8.0;

  // Smooth transition for eye blinking
  FCurrentEyeRY := FCurrentEyeRY + (EyeRY - FCurrentEyeRY) * 0.2;

  // Parallax offset based on mouse position
  LookOffset := TPoint3D.Create(FLookX * 25.0, FLookY * 12.0, 0);

  for I := 0 to High(FParticles) do
  begin
    // Skip particles that are currently falling/fading out
    if FParticles[I].IsFading then
      Continue;

    case FParticles[I].PType of
      ptFill, ptOutline:
        FParticles[I].Target3D := FParticles[I].Base3D;
      ptEyeL:
        begin
          X := (-45 + Cos(FParticles[I].BaseAngle) * 22) * ScaleFactor;
          Y := (-50 + Sin(FParticles[I].BaseAngle) * FCurrentEyeRY) * ScaleFactor;
          Z := 20.0;
          FParticles[I].Target3D := TPoint3D.Create(X, Y, Z) + LookOffset;
        end;
      ptEyeR:
        begin
          X := (45 + Cos(FParticles[I].BaseAngle) * 22) * ScaleFactor;
          Y := (-50 + Sin(FParticles[I].BaseAngle) * FCurrentEyeRY) * ScaleFactor;
          Z := 20.0;
          FParticles[I].Target3D := TPoint3D.Create(X, Y, Z) + LookOffset;
        end;
      ptMouth:
        begin
          X := (Cos(FParticles[I].BaseAngle) * 35) * ScaleFactor;
          Y := (65 + Sin(FParticles[I].BaseAngle) * MouthRY) * ScaleFactor;
          Z := 15.0;
          FParticles[I].Target3D := TPoint3D.Create(X, Y, Z) + LookOffset;
        end;
    end;
  end;
end;

procedure TSkChaos.UpdateParticles(const DeltaTime: Double);
const
  BUILD_TIME = 1.5;
  FADE_TIME = 1.5;
var
  I: Integer;
  ScanSpeed, DespawnSpeed: Single;
  MousePos: TPoint;
  LocalMouthState: TMouthState;
  LocalEyeOverride: TEyeState;
  HoverOffset: TPoint3D;
  AllFaded: Boolean;
begin
  // Track mouse for eye/face parallax tracking
  GetCursorPos(MousePos);
  FLookX := ((MousePos.X - FForm.Left - FForm.Width / 2) / (Screen.Width / 2));
  FLookY := ((MousePos.Y - FForm.Top - FForm.Height / 2) / (Screen.Height / 2));
  FLookX := EnsureRange(FLookX, -1.0, 1.0);
  FLookY := EnsureRange(FLookY, -1.0, 1.0);

  // Safely fetch mouth/eye state
  FLock.Enter;
  try
    LocalMouthState := FMouthState;
    LocalEyeOverride := FEyeOverride;
  finally
    FLock.Leave;
  end;

  // Blinking logic
  if not FIsBlinking then
  begin
    FBlinkTimer := FBlinkTimer - DeltaTime;
    if FBlinkTimer <= 0 then
    begin
      FIsBlinking := True;
      FBlinkTimer := 0.1;
    end;
  end
  else
  begin
    FBlinkTimer := FBlinkTimer - DeltaTime;
    if FBlinkTimer <= 0 then
    begin
      FIsBlinking := False;
      FBlinkTimer := 2.0 + Random(4);
    end;
  end;

  FMouthState := LocalMouthState;
  FEyeOverride := LocalEyeOverride;
  UpdateTargets;

  // --- BUILD-UP ANIMATION (Forming) ---
  if FState = csForming then
  begin
    // Calculate scanline speed so the whole face forms in BUILD_TIME seconds
    ScanSpeed := (FMaxY - FMinY + 50) / BUILD_TIME;
    if ScanSpeed > 0 then
      FScanY := FScanY + (ScanSpeed * DeltaTime);

    // Activate particles as the scanline passes their Y position
    while (FNextTargetIdx < Length(FParticles)) and (FParticles[FNextTargetIdx].Target3D.Y <= FScanY) do
    begin
      FParticles[FNextTargetIdx].LifeTime := 0;
      // Start particle slightly offset from target for a nice zoom-in effect
      FParticles[FNextTargetIdx].Pos3D := TPoint3D.Create(FParticles[FNextTargetIdx].Target3D.X + Random(30) - 15, -15 + Random(15), FParticles[FNextTargetIdx].Target3D.Z);
      FParticles[FNextTargetIdx].ReachedTarget := False;
      Inc(FNextTargetIdx);
    end;
  end
  // --- TEAR-DOWN ANIMATION (Fading) ---
  else if FState = csFading then
  begin
    // Move a despawn scanline downwards
    DespawnSpeed := (FMaxY - FMinY + 50) / FADE_TIME;
    FDespawnY := FDespawnY + (DespawnSpeed * DeltaTime);

    // Turn particles into falling debris when the scanline hits them
    for I := 0 to FNextTargetIdx - 1 do
    begin
      if not FParticles[I].IsFading and (FParticles[I].Pos3D.Y <= FDespawnY) then
      begin
        FParticles[I].IsFading := True;
        // Give them a downward push so they fall out of the screen
        FParticles[I].Vel := TPointF.Create(0, 150 + Random(100));
      end;
    end;
  end;

  // --- MOVEMENT & PHYSICS ---
  for I := 0 to FNextTargetIdx - 1 do
  begin
    if FParticles[I].IsFading then
    begin
      // Apply gravity to fading particles
      FParticles[I].Vel.Y := FParticles[I].Vel.Y + 500.0 * DeltaTime;
      FParticles[I].Pos3D := TPoint3D.Create(FParticles[I].Pos3D.X + FParticles[I].Vel.X * DeltaTime, FParticles[I].Pos3D.Y + FParticles[I].Vel.Y * DeltaTime, FParticles[I].Pos3D.Z);
    end
    else if FParticles[I].ReachedTarget then
    begin
      // Apply a subtle floating hover effect to idle particles
      HoverOffset := TPoint3D.Create((Random - 0.5) * 1.2, (Random - 0.5) * 1.2, (Random - 0.5) * 1.2);
      FParticles[I].Pos3D := FParticles[I].Target3D + HoverOffset;
      FParticles[I].LifeTime := 10.0;
    end
    else
    begin
      // Lerp particles towards their target position
      FParticles[I].LifeTime := FParticles[I].LifeTime + DeltaTime;
      if FParticles[I].LifeTime > 1.0 then
      begin
        FParticles[I].ReachedTarget := True;
        FParticles[I].LifeTime := 10.0;
        FParticles[I].Pos3D := FParticles[I].Target3D;
      end
      else
      begin
        var LerpFactor := EnsureRange(FParticles[I].LifeTime * 2.0, 0.0, 1.0);
        FParticles[I].Pos3D := TPoint3D.Create(FParticles[I].Pos3D.X + (FParticles[I].Target3D.X - FParticles[I].Pos3D.X) * LerpFactor * DeltaTime * 10.0, FParticles[I].Pos3D.Y + (FParticles[I].Target3D.Y - FParticles[I].Pos3D.Y) * LerpFactor * DeltaTime * 10.0, FParticles[I].Pos3D.Z + (FParticles[I].Target3D.Z - FParticles[I].Pos3D.Z) * LerpFactor * DeltaTime * 10.0);
      end;
    end;
  end;

  // Check if all particles have fallen off-screen during tear-down
  if FState = csFading then
  begin
    AllFaded := True;
    for I := 0 to FNextTargetIdx - 1 do
    begin
      if not FParticles[I].IsFading or (FParticles[I].Pos3D.Y < FFormHeight + 50) then
      begin
        AllFaded := False;
        Break;
      end;
    end;
    if AllFaded then
      FState := csFinished;
  end;
end;

procedure TSkChaos.RenderFrame;
var
  Paint, GlowPaint, LinePaint: ISkPaint;
  I, J: Integer;
  FinalAlpha, PAlpha, Flicker, DepthFactor, LineDepth: Single;
  BaseColor: TAlphaColor;
  CenterTarget: TPointF;
  P1, P2: TPointF;
  SkImage: ISkImage;
  MemStream: TMemoryStream;
  PngImage: TPngImage;
  Size, BlurRadius: Single;
  Pos2D: TPointF;
  DeltaX, DeltaY: Single;
begin
  // Clear the manual Skia canvas
  FSkCanvas.Clear(TAlphaColorRec.Null);

  // Setup Paints
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Fill;

  GlowPaint := TSkPaint.Create;
  GlowPaint.AntiAlias := True;
  GlowPaint.Style := TSkPaintStyle.Fill;

  LinePaint := TSkPaint.Create;
  LinePaint.AntiAlias := True;
  LinePaint.Style := TSkPaintStyle.Stroke;
  LinePaint.StrokeWidth := 1.0;

  // Slight vertical breathing animation for the whole face
  CenterTarget := TPointF.Create(FCenterOffset.X, FCenterOffset.Y + Sin(FGlobalTime * 1.5) * 2.0);

  // 1. DRAW CIRCUIT BOARD LINES (Only for active, non-fading Fill particles)
  for I := 0 to FNextTargetIdx - 1 do
  begin
    if (FParticles[I].LifeTime < 0) or (FParticles[I].PType <> ptFill) or FParticles[I].IsFading then
      Continue;

    // Check nearby particles to draw connecting lines
    for J := I + 1 to Min(FNextTargetIdx - 1, I + 5) do
    begin
      if (FParticles[J].LifeTime < 0) or (FParticles[J].PType <> ptFill) or FParticles[J].IsFading then
        Continue;

      DeltaX := FParticles[I].Target3D.X - FParticles[J].Target3D.X;
      DeltaY := FParticles[I].Target3D.Y - FParticles[J].Target3D.Y;

      // Draw lines if they are close enough to form grid/diagonal connections
      if ((Abs(DeltaX) < 2.0) and (Abs(DeltaY) < 12.0)) or ((Abs(Abs(DeltaX) - Abs(DeltaY)) < 2.5) and (Abs(DeltaY) < 12.0)) then
      begin
        P1 := CenterTarget + Project3DTo2D(FParticles[I].Pos3D);
        P2 := CenterTarget + Project3DTo2D(FParticles[J].Pos3D);

        LineDepth := (FParticles[I].Pos3D.Z + FParticles[J].Pos3D.Z) / 140.0;
        LineDepth := EnsureRange(LineDepth, 0.3, 1.0);

        FinalAlpha := 255 * FAlpha * 0.9 * LineDepth;
        LinePaint.Color := FFaceColor;
        LinePaint.Alpha := EnsureRange(Round(FinalAlpha), 0, 255);
        LinePaint.StrokeWidth := 0.8 + (LineDepth * 1.2);
        FSkCanvas.DrawLine(P1, P2, LinePaint);
      end;
    end;
  end;

  // 2. RENDER NODE PARTICLES (Eyes, Mouth, and Fill Nodes)
  for I := 0 to FNextTargetIdx - 1 do
  begin
    if FParticles[I].LifeTime < 0 then
      Continue;

    // Subtle flickering effect for the AI hologram look
    Flicker := 0.9 + (Sin(FGlobalTime * 15.0 + I * 1.3) * 0.1);
    Flicker := EnsureRange(Flicker, 0.6, 1.1);

    Pos2D := CenterTarget + Project3DTo2D(FParticles[I].Pos3D);

    // Determine properties based on particle type
    if FParticles[I].PType in [ptFill, ptOutline] then
      DepthFactor := EnsureRange((FParticles[I].Pos3D.Z * 2.0 + 40.0) / 90.0, 0.5, 1.0)
    else
      DepthFactor := 0.75;

    case FParticles[I].PType of
      ptEyeL, ptEyeR:
        begin
          BaseColor := FEyeColor;
          PAlpha := 0.1;
          Size := 1.5;
          BlurRadius := 5.0;
        end;
      ptMouth:
        begin
          BaseColor := FMouthColor;
          PAlpha := 0.1;
          Size := 1.5;
          BlurRadius := 5.0;
        end;
      ptOutline:
        begin
          BaseColor := FFaceColor;
          PAlpha := 1.0;
          Size := 1.2;
          BlurRadius := 6.0;
        end;
      ptFill:
        begin
          BaseColor := FFaceColor;
          PAlpha := 1.0;
          Size := 0.9;
          BlurRadius := 4.0;
        end;
    else
      BaseColor := FFaceColor;
      PAlpha := 0.5;
      Size := 1.0;
      BlurRadius := 4.0;
    end;

    // Fade-in particles that haven't reached their target yet
    if not FParticles[I].ReachedTarget and not FParticles[I].IsFading then
      PAlpha := PAlpha * EnsureRange(FParticles[I].LifeTime / 0.5, 0, 1.0);

    PAlpha := PAlpha * DepthFactor;

    // 2.1 AURA / GLOW LAYER (Heavy blur)
    GlowPaint.Color := BaseColor;
    FinalAlpha := 255 * FAlpha * PAlpha * Flicker * 1.5;
    GlowPaint.Alpha := EnsureRange(Round(FinalAlpha), 0, 255);
    if BlurRadius > 0.1 then
    begin
      GlowPaint.ImageFilter := TSkImageFilter.MakeBlur(BlurRadius * 2, BlurRadius * 2);
      FSkCanvas.DrawCircle(Pos2D, Size * 2.5, GlowPaint);
    end;

    // 2.2 CORE LAYER (Slight blur for smooth edges)
    Paint.Color := BaseColor;
    FinalAlpha := 255 * FAlpha * PAlpha * Flicker * 2.0;
    Paint.Alpha := EnsureRange(Round(FinalAlpha), 0, 255);
    Paint.ImageFilter := TSkImageFilter.MakeBlur(1.5, 1.5);
    FSkCanvas.DrawCircle(Pos2D, Size * 1.2, Paint);
  end;

  // 3. EXPORT SKIA SURFACE TO WINDOWS BITMAP BUFFER
  // Create an image snapshot from the Skia surface
  SkImage := FSkSurface.MakeImageSnapshot;
  if Assigned(SkImage) then
  begin
    MemStream := TMemoryStream.Create;
    try
      // Encode the Skia image to a PNG stream
      if SkImage.EncodeToStream(MemStream, TSkEncodedImageFormat.PNG) then
      begin
        if MemStream.Size > 0 then
        begin
          MemStream.Position := 0;
          PngImage := TPngImage.Create;
          try
            // Load the PNG stream into a VCL PNG object
            PngImage.LoadFromStream(MemStream);

            // Draw it onto our transparent Windows bitmap buffer
            FBuffer.Canvas.Lock;
            try
              FBuffer.Canvas.Brush.Color := clBlack;
              FBuffer.Canvas.FillRect(Rect(0, 0, FFormWidth, FFormHeight));
              FBuffer.Canvas.Draw(0, 0, PngImage);
            finally
              FBuffer.Canvas.Unlock;
            end;

            // Push the bitmap to the UI thread to update the layered window
            TThread.Queue(nil,
              procedure
              begin
                if Assigned(FForm) and FForm.Visible then
                  UpdateWindow;
              end);

          finally
            PngImage.Free;
          end;
        end;
      end;
    finally
      MemStream.Free;
    end;
  end;
end;

procedure TSkChaos.Start;
begin
  if FState = csForming then Exit; // Already starting

  // WICHTIG: Form wieder anzeigen, da sie beim Stop versteckt wurde!
  if Assigned(FForm) then
    FForm.Show;

  InitParticles;
  FState := csForming;
  FStateTimer := 0;
  FAlpha := 1.0;

  StartThread;
end;

procedure TSkChaos.Stop;
begin
  // Allow tear-down from both Active and Forming states
  if (FState = csActive) or (FState = csForming) then
  begin
    // Start the tear-down animation
    FState := csFading;
    FStateTimer := 0;
    FDespawnY := FMinY;
  end
  else
  begin
    // Hard stop if already fading or finished
    StopThread;
    if Assigned(FForm) then FForm.Hide;
    FState := csIdle;
  end;
end;



procedure TSkChaos.StartThread;
begin
  // If the thread is somehow still active from a previous run,
  // we don't need to start a new one, it will pick up the csForming state.
  if FThreadActive then Exit;

  FThreadActive := True;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LastTime, NowTime, DeltaMS: Cardinal;
    begin
      LastTime := TThread.GetTickCount;
      while not TThread.CheckTerminated and (FState <> csFinished) do
      begin
        NowTime := TThread.GetTickCount;
        DeltaMS := NowTime - LastTime;
        if DeltaMS = 0 then DeltaMS := 1;
        LastTime := NowTime;

        FStateTimer := FStateTimer + (DeltaMS / 1000);
        FGlobalTime := FGlobalTime + (DeltaMS / 1000);

        case FState of
          csForming:
            begin
              UpdateParticles(DeltaMS / 1000);
              // Check if all particles have been activated and reached their target
              var AllReached := True;
              if FNextTargetIdx < Length(FParticles) then
                AllReached := False
              else
              begin
                for var I := 0 to High(FParticles) do
                  if not FParticles[I].ReachedTarget then begin AllReached := False; Break; end;
              end;
              if AllReached then FState := csActive;
            end;
          csActive, csFading:
            begin
              UpdateParticles(DeltaMS / 1000);
            end;
          csIdle, csFinished:
            Break;
        end;

        // Render the current frame
        if Assigned(FForm) and FForm.Visible then
          RenderFrame;

        Sleep(16); // Roughly 60 FPS cap
      end;

      // Once tear-down is completely finished, hide the form
      if FState = csFinished then
      begin
        TThread.Queue(nil,
          procedure
          begin
            if Assigned(FForm) then FForm.Hide;
            FState := csIdle;
            // WICHTIG: Thread als inaktiv markieren, damit er beim nächsten Start neu erstellt wird!
            FThreadActive := False;
          end);
      end;
    end);
  FThread.FreeOnTerminate := True;
  FThread.Start;
end;

procedure TSkChaos.StopThread;
begin
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    Sleep(50);
  end;
end;

procedure TSkChaos.UpdateWindow;
var
  ScreenDC, MemDC: HDC;
  BlendFunc: TBlendFunction;
  PtSrc, PtDest: TPoint;
  Size: TSize;
  OldBitmap: HBITMAP;
begin
  // Draw the VCL Bitmap to the screen using Windows Layered Window API
  ScreenDC := GetDC(0);
  try
    MemDC := CreateCompatibleDC(ScreenDC);
    try
      OldBitmap := SelectObject(MemDC, FBuffer.Handle);
      PtDest := Point(FForm.Left, FForm.Top);
      Size.cx := FBuffer.Width;
      Size.cy := FBuffer.Height;
      PtSrc := Point(0, 0);
      BlendFunc.BlendOp := AC_SRC_OVER;
      BlendFunc.BlendFlags := 0;
      BlendFunc.SourceConstantAlpha := 255;
      BlendFunc.AlphaFormat := AC_SRC_ALPHA;
      Winapi.Windows.UpdateLayeredWindow(FForm.Handle, ScreenDC, @PtDest, @Size, MemDC, @PtSrc, 0, @BlendFunc, ULW_ALPHA);
      SelectObject(MemDC, OldBitmap);
    finally
      DeleteDC(MemDC);
    end;
  finally
    ReleaseDC(0, ScreenDC);
  end;
end;

end.

