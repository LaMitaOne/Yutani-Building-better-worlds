unit Yutani.SkiaIntro;

interface

uses
  Winapi.Windows, Winapi.MMSystem, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Math, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections, System.Generics.Defaults,
  Vcl.Forms, Vcl.Graphics, Vcl.Imaging.pngimage,
  Skia;

type
  { Defines the current phase of the intro animation }
  TIntroState = (isFadeIn, isParticlesForm, isTextGlow, isFadeOut, isFinished);

  { High Precision Timer based on TStopwatch (QPC on Windows) }
  THighResTimer = record
    Frequency: Int64;
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

  { Represents a single particle used to form the hologram text }
  TParticle = record
    Pos, Vel, Target: TPointF;
    LifeTime: Double;
    ReachedTarget: Boolean;
  end;

  { TYutaniSkiaIntro }
  { A threaded, high-performance Skia-based intro renderer.
    Displays an image, spawns a stream of particles to form text,
    triggers a holographic glow, and fades out smoothly. }
  TYutaniSkiaIntro = class
  private
    FForm: TForm;
    FBuffer: TBitmap;
    FLogoImage: ISkImage;
    FState: TIntroState;
    FStateTimer: Double;
    FAlpha: Single;
    FGlowStrength: Single;

    FThread: TThread;
    FLock: TCriticalSection;
    FThreadActive: Boolean;

    FParticles: array of TParticle;
    FTargetPoints: array of TPointF;
    FSpawnTimer: Double;
    FNextTargetIdx: Integer;

    procedure MakeClickThroughFullScreen;
    procedure UpdateIntroWindow;
    procedure GenerateParticleTargets;
    procedure InitParticles;
    procedure UpdateParticles(const DeltaTime: Double);
    procedure RenderParticles(const ACanvas: ISkCanvas);
    procedure StartThread;
    procedure StopThread;
    procedure RenderFrame;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    function IntroFinished: Boolean;
  end;

implementation

const
  { Busy-spin window: while less than this remains until the frame deadline,
    we spin instead of sleeping. }
  SPIN_THRESHOLD_NS = 2000000; // 2 ms

{==============================================================================
  THighResTimer Implementation
==============================================================================}

procedure THighResTimer.Init;
begin
  Frequency := TStopwatch.Frequency;
end;

function THighResTimer.GetTicks: Int64;
begin
  Result := TStopwatch.GetTimestamp;
end;

{ HybridWaitUntil
  Waits until the counter reaches ATargetTicks using a two-phase strategy:
    Phase 1: Sleep(1) while far from the deadline.
    Phase 2: Busy-spin the remaining microseconds for frame-exact timing. }
procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  SpinTicks, Remaining: Int64;
begin
  if Frequency = 0 then Exit;
  SpinTicks := (ASpinNanoseconds * Frequency) div 1000000000;

  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    Sleep(1);
    Remaining := ATargetTicks - GetTicks;
  end;
  while GetTicks < ATargetTicks do ;
end;

{==============================================================================
  TYutaniSkiaIntro Implementation
==============================================================================}

constructor TYutaniSkiaIntro.Create;
var
  ExePath, LogoFile: string;
  LogoSize: Integer;
begin
  LogoSize := 350;

  { Setup the transparent, click-through overlay form }
  FForm := TForm.Create(nil);
  FForm.FormStyle := fsStayOnTop;
  FForm.BorderStyle := bsNone;
  FForm.Color := clBlack;
  FForm.ClientWidth := LogoSize;
  FForm.ClientHeight := LogoSize;
  FForm.Left := (Screen.Width - LogoSize) div 2;
  FForm.Top := (Screen.Height - LogoSize) div 2;
  MakeClickThroughFullScreen;

  { Setup the internal 32-bit bitmap buffer used for LayeredWindow updates }
  FBuffer := TBitmap.Create;
  FBuffer.PixelFormat := pf32bit;
  FBuffer.AlphaFormat := afDefined;
  FBuffer.SetSize(LogoSize, LogoSize);

  { Load the main logo image directly into ISkImage }
  ExePath := ExtractFilePath(ParamStr(0));
  LogoFile := ExePath + 'ressources\yutani_logo.png';
  if FileExists(LogoFile) then
    FLogoImage := TSkImage.MakeFromEncodedFile(LogoFile)
  else
    FLogoImage := nil;

  FLock := TCriticalSection.Create;
  GenerateParticleTargets;
end;

destructor TYutaniSkiaIntro.Destroy;
begin
  StopThread;
  FBuffer.Free;
  FForm.Free;
  FLock.Free;
  inherited;
end;

procedure TYutaniSkiaIntro.MakeClickThroughFullScreen;
begin
  SetWindowLong(FForm.Handle, GWL_EXSTYLE, GetWindowLong(FForm.Handle, GWL_EXSTYLE) or WS_EX_LAYERED or WS_EX_TRANSPARENT);
end;

procedure TYutaniSkiaIntro.GenerateParticleTargets;
var
  TempBmp: TBitmap;
  x, y: Integer;
  TxtWidth, TxtHeight: Integer;
  TextStr: string;
  FTextBounds: TRectF;
  PtCount: Integer;
begin
  TextStr := 'YUTANI';
  TempBmp := TBitmap.Create;
  try
    TempBmp.SetSize(300, 100);
    TempBmp.Canvas.Brush.Color := clBlack;
    TempBmp.Canvas.FillRect(Rect(0, 0, TempBmp.Width, TempBmp.Height));

    { Configure font for the hologram text }
    TempBmp.Canvas.Font.Name := 'Impact';
    TempBmp.Canvas.Font.Size := 40;
    TempBmp.Canvas.Font.Style := [fsBold];
    TempBmp.Canvas.Font.Color := clWhite;

    TxtWidth := TempBmp.Canvas.TextWidth(TextStr);
    TxtHeight := TempBmp.Canvas.TextHeight(TextStr);

    { Calculate the target area for the text at the bottom of the window }
    FTextBounds := TRectF.Create(
      (FBuffer.Width - TxtWidth) / 2,
      FBuffer.Height - TxtHeight - 30,
      (FBuffer.Width + TxtWidth) / 2,
      FBuffer.Height - 30
    );

    TempBmp.Canvas.TextOut((TempBmp.Width - TxtWidth) div 2, 0, TextStr);

    SetLength(FTargetPoints, 500);
    PtCount := 0;

    { Rasterize the text into points. Using modulo 3 creates gaps,
      giving it a dotted hologram appearance. }
    for y := 0 to TempBmp.Height - 1 do
    begin
      for x := 0 to TempBmp.Width - 1 do
      begin
        if (TempBmp.Canvas.Pixels[x, y] = clWhite) and ((x mod 3 = 0) and (y mod 3 = 0)) then
        begin
          if PtCount < Length(FTargetPoints) then
          begin
            FTargetPoints[PtCount] := TPointF.Create(
              FTextBounds.Left + x - ((TempBmp.Width - TxtWidth) / 2),
              FTextBounds.Top + y
            );
            Inc(PtCount);
          end;
        end;
      end;
    end;

    SetLength(FTargetPoints, PtCount);
    SetLength(FParticles, PtCount);
  finally
    TempBmp.Free;
  end;
end;

procedure TYutaniSkiaIntro.InitParticles;
var
  I: Integer;
begin
  { Reset all particles to an inactive state }
  for I := 0 to High(FParticles) do
  begin
    FParticles[I].LifeTime := -1;
    FParticles[I].ReachedTarget := False;
  end;
  FSpawnTimer := 0;
  FNextTargetIdx := 0;
  FGlowStrength := 0;
end;

procedure TYutaniSkiaIntro.UpdateParticles(const DeltaTime: Double);
const
  SPAWN_INTERVAL = 0.005; // Spawn a new particle every 5ms
var
  I: Integer;
  LogoCenter: TPointF;
  ToTarget, Dir, Tangent, Accel: TPointF;
  Dist, Force: Single;
begin
  LogoCenter := TPointF.Create(FBuffer.Width / 2, 145);

  { Spawn particles continuously from the center of the logo }
  FSpawnTimer := FSpawnTimer + DeltaTime;
  while (FSpawnTimer >= SPAWN_INTERVAL) and (FNextTargetIdx < Length(FParticles)) do
  begin
    FSpawnTimer := FSpawnTimer - SPAWN_INTERVAL;

    FParticles[FNextTargetIdx].LifeTime := 0;
    FParticles[FNextTargetIdx].Pos := LogoCenter + TPointF.Create(Random(10) - 5, Random(10) - 5);
    FParticles[FNextTargetIdx].Vel := TPointF.Create(Random(20) - 10, Random(20) + 10);
    FParticles[FNextTargetIdx].Target := FTargetPoints[FNextTargetIdx];
    FParticles[FNextTargetIdx].ReachedTarget := False;

    Inc(FNextTargetIdx);
  end;

  { Update active particles }
  for I := 0 to FNextTargetIdx - 1 do
  begin
    if FParticles[I].ReachedTarget then Continue;

    FParticles[I].LifeTime := FParticles[I].LifeTime + DeltaTime;

    { Safety mechanism: Force particles to their target after 2 seconds
      to guarantee the animation can proceed to the glow state. }
    if FParticles[I].LifeTime > 2.0 then
    begin
      FParticles[I].ReachedTarget := True;
      FParticles[I].Pos := FParticles[I].Target;
      Continue;
    end;

    ToTarget := FParticles[I].Target - FParticles[I].Pos;
    Dist := ToTarget.Length;

    if Dist < 2.0 then
    begin
      FParticles[I].ReachedTarget := True;
      FParticles[I].Pos := FParticles[I].Target;
    end
    else
    begin
      Dir := ToTarget.Normalize;
      Tangent := TPointF.Create(-Dir.Y, Dir.X); // Tangential force for a swirling motion

      Force := Min(2500, Dist * 10);
      Accel := Dir * Force + Tangent * (Force * 0.15);

      FParticles[I].Vel := FParticles[I].Vel + Accel * DeltaTime;
      FParticles[I].Vel := FParticles[I].Vel * (1.0 - (2.5 * DeltaTime)); // Friction
      FParticles[I].Pos := FParticles[I].Pos + (FParticles[I].Vel * DeltaTime);
    end;
  end;
end;

procedure TYutaniSkiaIntro.RenderParticles(const ACanvas: ISkCanvas);
var
  I: Integer;
  Paint, GlowPaint: ISkPaint;
  PAlpha, LifeFactor: Single;
  BaseColor, GlowColor: TAlphaColor;
  BlurRadius: Single;
  FinalAlpha: Integer;
  Size: Single;
begin
  { Base Paint for the solid particle core }
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Fill;

  { Glow Paint for the blurred aura }
  GlowPaint := TSkPaint.Create;
  GlowPaint.AntiAlias := True;
  GlowPaint.Style := TSkPaintStyle.Fill;

  BaseColor := $FF00BFFF; // Dark Sci-Fi Cyan
  GlowColor := $FF66FFFF; // Bright Cyan/White for the glow aura

  for I := 0 to FNextTargetIdx - 1 do
  begin
    if FParticles[I].LifeTime < 0 then Continue;

    LifeFactor := FParticles[I].LifeTime / 0.3;
    if LifeFactor > 1.0 then LifeFactor := 1.0;

    if FParticles[I].ReachedTarget then
      PAlpha := 0.8
    else
      PAlpha := 0.4 * LifeFactor;

    { Calculate dynamic glow and size }
    BlurRadius := 4.0;
    Size := 1.2;

    if (FState = isTextGlow) and FParticles[I].ReachedTarget then
    begin
      BlurRadius := 4.0 + (8.0 * FGlowStrength);
      Size := 1.2 + (1.0 * FGlowStrength);
      GlowPaint.Color := GlowColor;
      Paint.Color := $FFFFFFFF; // Core flashes white during glow
      FinalAlpha := Round(255 * FAlpha * (PAlpha + (0.6 * FGlowStrength)));
      GlowPaint.Alpha := EnsureRange(FinalAlpha, 0, 255);
      Paint.Alpha := EnsureRange(FinalAlpha, 0, 255);
    end
    else
    begin
      GlowPaint.Color := GlowColor;
      Paint.Color := BaseColor;
      FinalAlpha := Round(255 * FAlpha * PAlpha);
      GlowPaint.Alpha := EnsureRange(Round(FinalAlpha * 0.6), 0, 255); // Glow is slightly more transparent
      Paint.Alpha := EnsureRange(FinalAlpha, 0, 255);
    end;

    { Draw the blurred glow aura first }
    if BlurRadius > 0.1 then
    begin
      GlowPaint.ImageFilter := TSkImageFilter.MakeBlur(BlurRadius, BlurRadius);
      ACanvas.DrawCircle(FParticles[I].Pos, Size * 1.5, GlowPaint);
    end;

    { Draw the solid bright core on top }
    Paint.ImageFilter := nil;
    ACanvas.DrawCircle(FParticles[I].Pos, Size, Paint);
  end;

  { Reset filters to avoid affecting other drawings }
  Paint.ImageFilter := nil;
  GlowPaint.ImageFilter := nil;
end;

procedure TYutaniSkiaIntro.Start;
begin
  InitParticles;
  FState := isFadeIn;
  FStateTimer := 0;
  FAlpha := 0.0;
  FForm.Show;
  StartThread;
end;

procedure TYutaniSkiaIntro.Stop;
begin
  StopThread;
  if Assigned(FForm) then
    FForm.Hide;
end;

procedure TYutaniSkiaIntro.StartThread;
begin
  if FThreadActive then Exit;
  FThreadActive := True;

  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      Timer: THighResTimer;
      Freq, FrameTicks, NextFrame, NowTicks, LastFrameTicks: Int64;
      DeltaSec: Double;
      I: Integer;
      AllReached: Boolean;
    begin
      {$IFDEF MSWINDOWS}
      timeBeginPeriod(1);
      {$ENDIF}
      try
        Timer.Init;
        Freq := Timer.Frequency;
        if Freq <= 0 then Freq := 10000000;

        NowTicks := Timer.GetTicks;
        LastFrameTicks := NowTicks;
        NextFrame := NowTicks;

        while not TThread.CheckTerminated and (FState <> isFinished) do
        begin
          NowTicks := Timer.GetTicks;
          DeltaSec := (NowTicks - LastFrameTicks) / Freq;
          LastFrameTicks := NowTicks;
          if (DeltaSec <= 0) or (DeltaSec > 0.25) then DeltaSec := 1 / 60;

          FStateTimer := FStateTimer + DeltaSec;

          { 1. LOGIC STATE MACHINE }
          case FState of
            isFadeIn:
              begin
                { Fade in the logo over 2.5 seconds }
                FAlpha := FStateTimer / 2.5;
                if FAlpha >= 1.0 then
                begin
                  FAlpha := 1.0;
                  FState := isParticlesForm;
                  FStateTimer := 0;
                end;
              end;
            isParticlesForm:
              begin
                UpdateParticles(DeltaSec);

                { Proceed to glow only when all particles have reached their target }
                AllReached := True;
                if FNextTargetIdx < Length(FParticles) then
                  AllReached := False
                else
                begin
                  for I := 0 to High(FParticles) do
                  begin
                    if not FParticles[I].ReachedTarget then
                    begin
                      AllReached := False;
                      Break;
                    end;
                  end;
                end;

                if AllReached then
                begin
                  FState := isTextGlow;
                  FStateTimer := 0;
                end;
              end;
            isTextGlow:
              begin
                { Execute the glow pulse over 0.8 seconds using a sine wave }
                if FStateTimer <= 0.8 then
                begin
                  FGlowStrength := Sin(FStateTimer / 0.8 * Pi);
                end
                else
                begin
                  FGlowStrength := 0;
                  FState := isFadeOut;
                  FStateTimer := 0;
                end;
              end;
            isFadeOut:
              begin
                { Fade out everything over 1.5 seconds }
                FAlpha := 1.0 - (FStateTimer / 1.5);
                if FAlpha <= 0.0 then
                begin
                  FAlpha := 0.0;
                  FState := isFinished;
                  Break;
                end;
              end;
          end;

          { 2. RENDERING (Queue to Main Thread) }
          TThread.Queue(nil,
            procedure
            begin
              if Assigned(FForm) and FForm.Visible then
                RenderFrame;
            end);

          { 3. FRAME PACING }
          FrameTicks := Round(Freq / 60);
          NextFrame := NextFrame + FrameTicks;
          NowTicks := Timer.GetTicks;
          if NextFrame <= NowTicks then NextFrame := NowTicks + FrameTicks;
          Timer.HybridWaitUntil(NextFrame, SPIN_THRESHOLD_NS);
        end;
      finally
        FThreadActive := False;
        {$IFDEF MSWINDOWS}
        timeEndPeriod(1);
        {$ENDIF}
      end;
    end);

  FThread.FreeOnTerminate := False;
  FThread.Start;
end;

procedure TYutaniSkiaIntro.StopThread;
begin
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

procedure TYutaniSkiaIntro.RenderFrame;
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  SkImage: ISkImage;
  MemStream: TMemoryStream;
  PngImage: TPngImage;
  Paint: ISkPaint;
  SrcRect, DestRect: TRectF;
  LogoSize: Single;
begin
  { Create an offscreen Skia surface for drawing }
  ImgInfo := TSkImageInfo.Create(FBuffer.Width, FBuffer.Height);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then Exit;

  Canvas := Surface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);

  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Alpha := Round(255 * FAlpha);

  { Draw the logo unscaled and centered horizontally }
  if Assigned(FLogoImage) then
  begin
    SrcRect := TRectF.Create(0, 0, FLogoImage.Width, FLogoImage.Height);
    LogoSize := 250;
    DestRect := TRectF.Create(
      (FBuffer.Width - LogoSize) / 2,
      20,
      (FBuffer.Width + LogoSize) / 2,
      20 + LogoSize
    );
    Canvas.DrawImageRect(FLogoImage, SrcRect, DestRect, Paint);
  end;

  { Draw the particle system }
  RenderParticles(Canvas);

  { Export the Skia surface to a PNG stream and draw it onto the Windows bitmap }
  SkImage := Surface.MakeImageSnapshot;
  if Assigned(SkImage) then
  begin
    MemStream := TMemoryStream.Create;
    try
      if SkImage.EncodeToStream(MemStream, TSkEncodedImageFormat.PNG) then
      begin
        if MemStream.Size > 0 then
        begin
          MemStream.Position := 0;
          PngImage := TPngImage.Create;
          try
            PngImage.LoadFromStream(MemStream);
            FBuffer.Canvas.Lock;
            try
              FBuffer.Canvas.Brush.Color := clBlack;
              FBuffer.Canvas.FillRect(Rect(0, 0, FBuffer.Width, FBuffer.Height));
              FBuffer.Canvas.Draw(0, 0, PngImage);
            finally
              FBuffer.Canvas.Unlock;
            end;
          finally
            PngImage.Free;
          end;
        end;
      end;
    finally
      MemStream.Free;
    end;
    UpdateIntroWindow;
  end;
end;

procedure TYutaniSkiaIntro.UpdateIntroWindow;
var
  ScreenDC, MemDC: HDC;
  BlendFunc: TBlendFunction;
  PtSrc, PtDest: TPoint;
  Size: TSize;
  OldBitmap: HBITMAP;
  crKey: COLORREF;
begin
  { Push the updated bitmap buffer to the Windows Layered Window }
  ScreenDC := GetDC(0);
  try
    MemDC := CreateCompatibleDC(ScreenDC);
    try
      OldBitmap := SelectObject(MemDC, FBuffer.Handle);
      PtDest := Point(FForm.Left, FForm.Top);
      Size.cx := FBuffer.Width;
      Size.cy := FBuffer.Height;
      PtSrc := Point(0, 0);
      crKey := 0;
      BlendFunc.BlendOp := AC_SRC_OVER;
      BlendFunc.BlendFlags := 0;
      BlendFunc.SourceConstantAlpha := 255;
      BlendFunc.AlphaFormat := AC_SRC_ALPHA;
      Winapi.Windows.UpdateLayeredWindow(FForm.Handle, ScreenDC, @PtDest, @Size, MemDC, @PtSrc, crKey, @BlendFunc, ULW_ALPHA);
      SelectObject(MemDC, OldBitmap);
    finally
      DeleteDC(MemDC);
    end;
  finally
    ReleaseDC(0, ScreenDC);
  end;
end;

function TYutaniSkiaIntro.IntroFinished: Boolean;
begin
  Result := (FState = isFinished);
end;

end.
