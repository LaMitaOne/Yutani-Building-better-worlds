unit Yutani.Render.LoadingScreen;

{==============================================================================*
 *  Yutani - Holographic Loading Screen (Skia)
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Provides a fully threaded, non-blocking loading screen overlay. Uses a
 *    separate transparent Windows window rendered via Skia4Delphi. Displays
 *    a sci-fi "LOADING" particle hologram that forms, micro-hovers, and
 *    scatters like fog. Automatically handles its own asynchronous fade-out
 *    and self-destruction when loading is complete, ensuring the main Raylib
 *    render loop never blocks during heavy world generation.
 *==============================================================================}

interface

uses
  Winapi.Windows, Winapi.MMSystem, System.SysUtils, System.Classes, System.Types,
  System.UITypes, System.Math, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections, System.Generics.Defaults, Vcl.Forms, Vcl.Graphics,
  Vcl.Imaging.pngimage, Skia;

type
  TParticle = record
    Pos, Vel, Target: TPointF;
    LifeTime: Double;
    ReachedTarget: Boolean;
  end;

  TYutaniLoadingScreen = class
  private
    FForm: TForm;
    FBuffer: TBitmap;
    FThread: TThread;
    FLock: TCriticalSection;
    FThreadActive: Boolean;
    FParticles: array of TParticle;
    FTargetPoints: array of TPointF;
    FSpawnTimer: Double;
    FNextTargetIdx: Integer;
    FGlobalTime: Double;
    FScanY: Single;
    FMinY: Single;
    FMaxY: Single;
    FGlowStrength: Single;
    FLogoCenter: TPointF;

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
    // Made public so RaylibSandbox can easily control the state externally
    FCycleState: Integer; // 0 = Forming, 1 = Hovering, 2 = Scattering, 3 = FadeOut
    FStateTimer: Double;
    FAlpha: Single;

    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop; // This now handles the fade-out gracefully
    procedure AsyncStop;
  end;

implementation

const
  SPIN_THRESHOLD_NS = 2000000;

type
  THighResTimer = record
    Frequency: Int64;
    procedure Init;
    function GetTicks: Int64; inline;
    procedure HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
  end;

procedure THighResTimer.Init;
begin
  Frequency := TStopwatch.Frequency;
end;

function THighResTimer.GetTicks: Int64;
begin
  Result := TStopwatch.GetTimestamp;
end;

procedure THighResTimer.HybridWaitUntil(const ATargetTicks, ASpinNanoseconds: Int64);
var
  SpinTicks, Remaining: Int64;
begin
  if Frequency = 0 then
    Exit;
  SpinTicks := (ASpinNanoseconds * Frequency) div 1000000000;
  Remaining := ATargetTicks - GetTicks;
  while Remaining > SpinTicks do
  begin
    Sleep(1);
    Remaining := ATargetTicks - GetTicks;
  end;
  while GetTicks < ATargetTicks do
    ;
end;

{ TYutaniLoadingScreen }

constructor TYutaniLoadingScreen.Create;
var
  ScreenW, ScreenH, Size: Integer;
begin
  ScreenW := GetSystemMetrics(SM_CXSCREEN);
  ScreenH := GetSystemMetrics(SM_CYSCREEN);
  Size := 400;

  FForm := TForm.Create(nil);
  FForm.FormStyle := fsStayOnTop;
  FForm.BorderStyle := bsNone;
  FForm.Color := clBlack;
  FForm.ClientWidth := Size;
  FForm.ClientHeight := Size;
  FForm.Left := (ScreenW - Size) div 2;
  FForm.Top := (ScreenH - Size) div 2;
  MakeClickThroughFullScreen;

  FBuffer := TBitmap.Create;
  FBuffer.PixelFormat := pf32bit;
  FBuffer.AlphaFormat := afDefined;
  FBuffer.SetSize(Size, Size);

  FLock := TCriticalSection.Create;
  GenerateParticleTargets;
end;

destructor TYutaniLoadingScreen.Destroy;
begin
  StopThread;
  FBuffer.Free;
  if Assigned(FForm) then
    FForm.Free;
  FLock.Free;
  inherited;
end;

procedure TYutaniLoadingScreen.MakeClickThroughFullScreen;
begin
  SetWindowLong(FForm.Handle, GWL_EXSTYLE, GetWindowLong(FForm.Handle, GWL_EXSTYLE) or WS_EX_LAYERED or WS_EX_TRANSPARENT);
end;

procedure TYutaniLoadingScreen.GenerateParticleTargets;
var
  TempBmp: TBitmap;
  x, y: Integer;
  TxtWidth, TxtHeight: Integer;
  TextStr: string;
  TmpTargetList: TList<TPointF>;
begin
  TextStr := 'LOADING';
  TmpTargetList := TList<TPointF>.Create;
  TempBmp := TBitmap.Create;
  try
    TempBmp.SetSize(350, 120);
    TempBmp.Canvas.Brush.Color := clBlack;
    TempBmp.Canvas.FillRect(Rect(0, 0, TempBmp.Width, TempBmp.Height));
    TempBmp.Canvas.Font.Name := 'Impact';
    TempBmp.Canvas.Font.Size := 56;
    TempBmp.Canvas.Font.Style := [fsBold];
    TempBmp.Canvas.Font.Color := clWhite;

    TxtWidth := TempBmp.Canvas.TextWidth(TextStr);
    TxtHeight := TempBmp.Canvas.TextHeight(TextStr);

    TempBmp.Canvas.TextOut((TempBmp.Width - TxtWidth) div 2, (TempBmp.Height - TxtHeight) div 2, TextStr);

    var FTextBounds := TRectF.Create((FBuffer.Width - TxtWidth) / 2, (FBuffer.Height - TxtHeight) / 2, (FBuffer.Width + TxtWidth) / 2, (FBuffer.Height + TxtHeight) / 2);

    for y := 0 to TempBmp.Height - 1 do
    begin
      for x := 0 to TempBmp.Width - 1 do
      begin
        if (TempBmp.Canvas.Pixels[x, y] = clWhite) and ((x mod 3 = 0) and (y mod 3 = 0)) then
        begin
          TmpTargetList.Add(TPointF.Create(FTextBounds.Left + x - ((TempBmp.Width - TxtWidth) / 2), FTextBounds.Top + y - ((TempBmp.Height - TxtHeight) / 2)));
        end;
      end;
    end;

    TmpTargetList.Sort(TComparer<TPointF>.Construct(
      function(const Left, Right: TPointF): Integer
      begin
        if Abs(Left.Y - Right.Y) < 0.1 then
          Result := Round(Left.X - Right.X)
        else if Left.Y < Right.Y then
          Result := -1
        else
          Result := 1;
      end));

    FMinY := 10000;
    FMaxY := 0;
    for x := 0 to TmpTargetList.Count - 1 do
    begin
      if TmpTargetList[x].y < FMinY then
        FMinY := TmpTargetList[x].y;
      if TmpTargetList[x].y > FMaxY then
        FMaxY := TmpTargetList[x].y;
    end;

    SetLength(FTargetPoints, TmpTargetList.Count);
    SetLength(FParticles, TmpTargetList.Count);
    for x := 0 to TmpTargetList.Count - 1 do
      FTargetPoints[x] := TmpTargetList[x];
  finally
    TmpTargetList.Free;
    TempBmp.Free;
  end;
end;

procedure TYutaniLoadingScreen.InitParticles;
var
  I: Integer;
begin
  for I := 0 to High(FParticles) do
  begin
    FParticles[I].LifeTime := -1;
    FParticles[I].ReachedTarget := False;
  end;
  FSpawnTimer := 0;
  FNextTargetIdx := 0;
  FGlowStrength := 0;
  FGlobalTime := 0;
  FScanY := FMinY;
  FCycleState := 0;
  FStateTimer := 0;
  FAlpha := 1.0;
  FLogoCenter := TPointF.Create(FBuffer.Width / 2, FBuffer.Height / 2);
end;

procedure TYutaniLoadingScreen.UpdateParticles(const DeltaTime: Double);
const
  BUILD_TIME = 1.5;
var
  I: Integer;
  ScanSpeed: Single;
  ToTarget, Dir, Tangent, Accel: TPointF;
  Dist, Force: Single;
begin
  FGlobalTime := FGlobalTime + DeltaTime;
  FStateTimer := FStateTimer + DeltaTime;

  // CYCLE 3: SOFT FADE OUT (Triggered by Stop)
  if FCycleState = 3 then
  begin
    FAlpha := Max(0, 1.0 - (FStateTimer / 0.5));
    Exit;
  end;

  // Normal Endless Loop
  if FCycleState = 0 then // Forming
  begin
    ScanSpeed := (FMaxY - FMinY + 50) / BUILD_TIME;
    FScanY := FScanY + ScanSpeed * DeltaTime;

    while (FNextTargetIdx < Length(FParticles)) and (FTargetPoints[FNextTargetIdx].y <= FScanY) do
    begin
      FParticles[FNextTargetIdx].LifeTime := 0;
      FParticles[FNextTargetIdx].Pos := FLogoCenter + TPointF.Create(Random(10) - 5, Random(10) - 5 - 100);
      FParticles[FNextTargetIdx].Vel := TPointF.Create(Random(20) - 10, Random(20) + 10);
      FParticles[FNextTargetIdx].Target := FTargetPoints[FNextTargetIdx];
      FParticles[FNextTargetIdx].ReachedTarget := False;
      Inc(FNextTargetIdx);
    end;

    if FNextTargetIdx >= Length(FParticles) then
    begin
      FCycleState := 1;
      FStateTimer := 0;
    end;
  end
  else if FCycleState = 1 then // Hovering
  begin
    if FStateTimer > 2.0 then
    begin
      FCycleState := 2;
      FStateTimer := 0;
      FGlowStrength := 1.0;
    end;
  end
  else if FCycleState = 2 then // Scattering
  begin
    if FStateTimer > 2.5 then
    begin
      FCycleState := 1; // Pull back together
      FStateTimer := 0;
      FGlowStrength := 0;
    end;
  end;

  for I := 0 to FNextTargetIdx - 1 do
  begin
    if FParticles[I].LifeTime < 0 then
      Continue;

    if FCycleState = 2 then // Scatter
    begin
      Accel := TPointF.Create((Random - 0.5) * 800.0, (Random - 0.5) * 800.0);
      FParticles[I].Vel := FParticles[I].Vel + Accel * DeltaTime;
      FParticles[I].Vel := FParticles[I].Vel * (1.0 - (1.5 * DeltaTime));
      FParticles[I].Pos := FParticles[I].Pos + (FParticles[I].Vel * DeltaTime);
      Continue;
    end;

    if FParticles[I].ReachedTarget then
    begin
      ToTarget := FParticles[I].Target - FParticles[I].Pos;
      Accel := ToTarget * 2500.0;
      Accel := Accel + TPointF.Create((Random - 0.5) * 5000.0, (Random - 0.5) * 5000.0);
      FParticles[I].Vel := FParticles[I].Vel + Accel * DeltaTime;
      FParticles[I].Vel := FParticles[I].Vel * (1.0 - (20.0 * DeltaTime));
      FParticles[I].Pos := FParticles[I].Pos + (FParticles[I].Vel * DeltaTime);
      Continue;
    end;

    FParticles[I].LifeTime := FParticles[I].LifeTime + DeltaTime;
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
      Tangent := TPointF.Create(-Dir.Y, Dir.X);
      Force := Min(2500, Dist * 10);
      Accel := Dir * Force + Tangent * (Force * 0.15);
      FParticles[I].Vel := FParticles[I].Vel + Accel * DeltaTime;
      FParticles[I].Vel := FParticles[I].Vel * (1.0 - (2.5 * DeltaTime));
      FParticles[I].Pos := FParticles[I].Pos + (FParticles[I].Vel * DeltaTime);
    end;
  end;
end;

procedure TYutaniLoadingScreen.RenderParticles(const ACanvas: ISkCanvas);
var
  I: Integer;
  Paint, GlowPaint: ISkPaint;
  PAlpha, LifeFactor: Single;
  BaseColor, GlowColor: TAlphaColor;
  BlurRadius, FinalAlpha, Size: Single;
  Flicker, PhaseOffset: Single;
begin
  if FAlpha <= 0 then
    Exit;

  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Fill;

  GlowPaint := TSkPaint.Create;
  GlowPaint.AntiAlias := True;
  GlowPaint.Style := TSkPaintStyle.Fill;

  BaseColor := $FF00BFFF;
  GlowColor := $FF66FFFF;

  for I := 0 to High(FParticles) do
  begin
    if FParticles[I].LifeTime < 0 then
      Continue;
    if FCycleState <> 3 then
      if I >= FNextTargetIdx then
        Continue;

    LifeFactor := FParticles[I].LifeTime / 0.3;
    if LifeFactor > 1.0 then
      LifeFactor := 1.0;

    if FParticles[I].ReachedTarget then
      PAlpha := 0.8
    else
      PAlpha := 0.4 * LifeFactor;

    PhaseOffset := FGlobalTime * 4.0 + (I * 0.05);
    Flicker := 0.85 + (Sin(FGlobalTime * 15.0 + I * 1.3) * 0.1);
    Flicker := Flicker + (Sin(FGlobalTime * 33.0 + I * 2.7) * 0.05);
    Flicker := EnsureRange(Flicker, 0.6, 1.1);

    BlurRadius := (5.0 + (Sin(PhaseOffset) * 2.0)) * Flicker;
    Size := 1.5 + (Sin(PhaseOffset) * 0.2);

    if FCycleState = 2 then
    begin
      BlurRadius := 10.0;
      Size := 2.0;
      GlowPaint.Color := GlowColor;
      Paint.Color := $FFFFFFFF;
      FinalAlpha := 255 * FAlpha * PAlpha * Flicker;
    end
    else if FCycleState = 3 then
    begin
      BlurRadius := 15.0;
      Size := 2.5;
      GlowPaint.Color := GlowColor;
      Paint.Color := $FFFFFFFF;
      FinalAlpha := 255 * FAlpha * PAlpha * Flicker;
    end
    else
    begin
      GlowPaint.Color := GlowColor;
      Paint.Color := BaseColor;
      FinalAlpha := 255 * FAlpha * PAlpha * Flicker;
    end;

    GlowPaint.Alpha := EnsureRange(Round(FinalAlpha * 0.9), 0, 255);
    Paint.Alpha := EnsureRange(Round(FinalAlpha), 0, 255);

    if BlurRadius > 0.1 then
    begin
      GlowPaint.ImageFilter := TSkImageFilter.MakeBlur(BlurRadius, BlurRadius);
      ACanvas.DrawCircle(FParticles[I].Pos, Size * 1.5, GlowPaint);
    end;

    Paint.ImageFilter := nil;
    ACanvas.DrawCircle(FParticles[I].Pos, Size, Paint);
  end;

  Paint.ImageFilter := nil;
  GlowPaint.ImageFilter := nil;
end;

procedure TYutaniLoadingScreen.Start;
begin
  InitParticles;
  FAlpha := 1.0;
  FForm.Show;
  StartThread;
end;

procedure TYutaniLoadingScreen.Stop;
begin
  // Do not block! We just queue the AsyncStop to the loading screen's own thread.
  // This allows Raylib to immediately continue rendering the newly loaded world.
  if Assigned(FThread) then
    TThread.Queue(nil,
      procedure
      begin
        Self.AsyncStop;
      end);
end;

procedure TYutaniLoadingScreen.AsyncStop;
begin
  // 1. Trigger the fade out state
  FCycleState := 3;
  FStateTimer := 0;
  FAlpha := 1.0;

  // The main thread loop will now detect FCycleState = 3,
  // fade out automatically, and then destroy itself when FAlpha reaches 0.
end;

procedure TYutaniLoadingScreen.StartThread;
begin
  if FThreadActive then
    Exit;
  FThreadActive := True;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      Timer: THighResTimer;
      Freq, FrameTicks, NextFrame, NowTicks, LastFrameTicks: Int64;
      DeltaSec: Double;
    begin
      {$IFDEF MSWINDOWS}
      timeBeginPeriod(1);
      {$ENDIF}
      try
        Timer.Init;
        Freq := Timer.Frequency;
        if Freq <= 0 then
          Freq := 10000000;
        NowTicks := Timer.GetTicks;
        LastFrameTicks := NowTicks;
        NextFrame := NowTicks;
        while not TThread.CheckTerminated do
        begin
          NowTicks := Timer.GetTicks;
          DeltaSec := (NowTicks - LastFrameTicks) / Freq;
          LastFrameTicks := NowTicks;
          if (DeltaSec <= 0) or (DeltaSec > 0.25) then
            DeltaSec := 1 / 60;

          UpdateParticles(DeltaSec);

          if Assigned(FForm) and FForm.Visible then
            RenderFrame;

          // AUTO-DESTRUCT: If we are in FadeOut state and fully invisible,
          // we can safely terminate our own thread!
              if (FCycleState = 3) and (FAlpha <= 0) then
            Break;

          FrameTicks := Round(Freq / 60);
          NextFrame := NextFrame + FrameTicks;
          NowTicks := Timer.GetTicks;
          if NextFrame <= NowTicks then
            NextFrame := NowTicks + FrameTicks;
          Timer.HybridWaitUntil(NextFrame, SPIN_THRESHOLD_NS);
        end;
      finally
        FThreadActive := False;
        {$IFDEF MSWINDOWS}
        timeEndPeriod(1);
        {$ENDIF}
        // Hide form and let the object destroy itself safely from memory
        if Assigned(FForm) then
          FForm.Hide;
        Self.Free;
      end;
    end);
  FThread.FreeOnTerminate := True; // Crucial for self-destruction
  FThread.Start;
end;

procedure TYutaniLoadingScreen.StopThread;
begin
  if Assigned(FThread) then
  begin
    FThread.Terminate;
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

procedure TYutaniLoadingScreen.RenderFrame;
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  SkImage: ISkImage;
  MemStream: TMemoryStream;
  PngImage: TPngImage;
begin
  ImgInfo := TSkImageInfo.Create(FBuffer.Width, FBuffer.Height);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then
    Exit;
  Canvas := Surface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);

  RenderParticles(Canvas);

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

procedure TYutaniLoadingScreen.UpdateIntroWindow;
var
  ScreenDC, MemDC: HDC;
  BlendFunc: TBlendFunction;
  PtSrc, PtDest: TPoint;
  Size: TSize;
  OldBitmap: HBITMAP;
  crKey: COLORREF;
begin
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

end.

