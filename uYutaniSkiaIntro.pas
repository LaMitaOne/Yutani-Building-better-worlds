unit uYutaniSkiaIntro;

interface
uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Types, System.UITypes,
  System.Math, Vcl.Forms, Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.Dialogs,
  Skia;
type
  // Defines the current phase of the intro animation
  TIntroState = (isFadeIn, isHold, isFadeOut, isFinished);
  { TYutaniSkiaIntro }
  { A lightweight, synchronous Skia intro renderer. Fades the logo in and out. }
  TYutaniSkiaIntro = class
  private
    FForm: TForm;
    FBuffer: TBitmap;
    FLogoImage: ISkImage;
    FState: TIntroState;
    FStateTimer: Double;
    FAlpha: Single;
    procedure MakeClickThroughFullScreen;
    procedure UpdateIntroWindow;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    // Driven by the main application loop
    procedure UpdateAndRender(DeltaTime: Double);
    function IntroFinished: Boolean;
  end;
implementation
{ TYutaniSkiaIntro }
constructor TYutaniSkiaIntro.Create;
var
  ExePath, LogoFile: string;
  LogoSize: Integer;
begin
  // Fixed size for the window and the buffer
  LogoSize := 250;
  // Setup the small, transparent, click-through overlay form
  FForm := TForm.Create(nil);
  FForm.FormStyle := fsStayOnTop;
  FForm.BorderStyle := bsNone;
  FForm.Color := clBlack;
  FForm.ClientWidth := LogoSize;  // Only 250 pixels wide
  FForm.ClientHeight := LogoSize; // Only 250 pixels high
  // Center it on the screen
  FForm.Left := (Screen.Width - LogoSize) div 2;
  FForm.Top := (Screen.Height - LogoSize) div 2;
  MakeClickThroughFullScreen;
  // Setup the internal 32-bit bitmap buffer (same small size)
  FBuffer := TBitmap.Create;
  FBuffer.PixelFormat := pf32bit;
  FBuffer.AlphaFormat := afDefined;
  FBuffer.SetSize(LogoSize, LogoSize);
  // Load the single logo image directly into ISkImage
  ExePath := ExtractFilePath(ParamStr(0));
  LogoFile := ExePath + 'ressources\yutani_logo.png';
  if FileExists(LogoFile) then
    FLogoImage := TSkImage.MakeFromEncodedFile(LogoFile)
  else
    FLogoImage := nil;
end;
destructor TYutaniSkiaIntro.Destroy;
begin
  FBuffer.Free;
  FForm.Free;
  inherited;
end;
procedure TYutaniSkiaIntro.MakeClickThroughFullScreen;
begin
  // Make the form transparent to mouse clicks
  SetWindowLong(FForm.Handle, GWL_EXSTYLE, GetWindowLong(FForm.Handle, GWL_EXSTYLE) or WS_EX_LAYERED or WS_EX_TRANSPARENT);
end;
procedure TYutaniSkiaIntro.Start;
begin
  FForm.Show;
  FState := isFadeIn;
  FStateTimer := 0;
  FAlpha := 0.0;
  // Initial clear of the buffer
  FBuffer.Canvas.Lock;
  try
    FBuffer.Canvas.Brush.Color := clBlack;
    FBuffer.Canvas.FillRect(Rect(0, 0, FBuffer.Width, FBuffer.Height));
  finally
    FBuffer.Canvas.Unlock;
  end;
  UpdateIntroWindow;
end;
procedure TYutaniSkiaIntro.Stop;
begin
  if Assigned(FForm) then
    FForm.Hide;
end;
procedure TYutaniSkiaIntro.UpdateAndRender(DeltaTime: Double);
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  Paint: ISkPaint;
  SrcRect, DestRect: TRectF;
  MemStream: TMemoryStream;
  SkImage: ISkImage;
  Png: TPngImage;
begin
  if IntroFinished or not Assigned(FLogoImage) then
    Exit;
  FStateTimer := FStateTimer + DeltaTime;
  // State Machine for Fading
  case FState of
    isFadeIn:
      begin
        // Fade in over 1.5 seconds
        FAlpha := FStateTimer / 1.5;
        if FAlpha >= 1.0 then
        begin
          FAlpha := 1.0;
          FState := isHold;
          FStateTimer := 0;
        end;
      end;
    isHold:
      begin
        // Keep it fully visible for 1.5 seconds
        FAlpha := 1.0;
        if FStateTimer >= 1.5 then
        begin
          FState := isFadeOut;
          FStateTimer := 0;
        end;
      end;
    isFadeOut:
      begin
        // Fade out over 1.5 seconds
        FAlpha := 1.0 - (FStateTimer / 1.5);
        if FAlpha <= 0.0 then
        begin
          FAlpha := 0.0;
          FState := isFinished;
          Stop;
          Exit;
        end;
      end;
  end;
  // 1. Render the frame using Skia in the small 250x250 size
  ImgInfo := TSkImageInfo.Create(FBuffer.Width, FBuffer.Height);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then Exit;
  Canvas := Surface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;
  Paint.Alpha := Round(255 * FAlpha);
  SrcRect := TRectF.Create(0, 0, FLogoImage.Width, FLogoImage.Height);
  DestRect := TRectF.Create(0, 0, FBuffer.Width, FBuffer.Height);
  // Draw the main logo
  Canvas.DrawImageRect(FLogoImage, SrcRect, DestRect, Paint);
  // 2. Blit Skia Surface to Windows Bitmap
  FBuffer.Canvas.Lock;
  try
    FBuffer.Canvas.Brush.Color := clBlack;
    FBuffer.Canvas.FillRect(Rect(0, 0, FBuffer.Width, FBuffer.Height));
    MemStream := TMemoryStream.Create;
    try
      SkImage := Surface.MakeImageSnapshot;
      if SkImage.EncodeToStream(MemStream, TSkEncodedImageFormat.PNG) then
      begin
        MemStream.Position := 0;
        Png := TPngImage.Create;
        try
          Png.LoadFromStream(MemStream);
          FBuffer.Canvas.Draw(0, 0, Png);
        finally
          Png.Free;
        end;
      end;
    finally
      MemStream.Free;
    end;
  finally
    FBuffer.Canvas.Unlock;
  end;
  // 3. Push to Windows
  UpdateIntroWindow;
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
  ScreenDC := GetDC(0);
  try
    MemDC := CreateCompatibleDC(ScreenDC);
    try
      OldBitmap := SelectObject(MemDC, FBuffer.Handle);
      // Pass the absolute screen coordinates so Windows draws it centered
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
