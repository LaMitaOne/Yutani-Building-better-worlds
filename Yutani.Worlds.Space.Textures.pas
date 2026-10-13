unit Yutani.Worlds.Space.Textures;

{==============================================================================*
 *  Yutani Space Textures - Procedural Planet Texture Generator (Skia)
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Generates seamless 2:1 (3072×1536) textures for perfect sphere mapping.
 *    Uses Skia Perlin Noise shaders with TileSize for eliminating UV seams.
 *==============================================================================}
{$POINTERMATH ON}
{$Q-}
{$R-}
interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, Skia, Raylib;

type
  TSunTextureGen = class
  public
    class function Generate(Seed: Cardinal; Size: Integer): TTexture2D;
  end;

type
  TPlanetTextureGen = class
  private
    class procedure DrawRocky(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
    class procedure DrawEarth(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
    class procedure DrawMars(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
    class procedure DrawGasGiant(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
    class procedure DrawIce(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
  public
    class function Generate(PlanetType: Integer; Seed: Cardinal; Size: Integer = 1024): TTexture2D;
  end;

implementation

var
  FRng: Cardinal;

procedure RngSeed(s: Cardinal);
begin
  if s = 0 then
    s := 1;
  FRng := s;
end;

function RngNext: Single;
begin
  FRng := FRng * 1664525 + 1013904223;
  Result := (FRng and $00FFFFFF) / $00FFFFFF;
end;

function SkCol(r, g, b: Byte; a: Byte = 255): TAlphaColor;
begin
  Result := TAlphaColor((a shl 24) or (r shl 16) or (g shl 8) or b);
end;
{ Helper to rotate the Skia Image 90 degrees clockwise before exporting }

function RotateSkImage90(const SrcImage: ISkImage): ISkImage;
var
  SrcW, SrcH: Integer;
  NewSurface: ISkSurface;
  Canvas: ISkCanvas;
begin
  SrcW := SrcImage.Width;
  SrcH := SrcImage.Height;
  // Swap dimensions for the new image
  NewSurface := TSkSurface.MakeRaster(TSkImageInfo.Create(SrcH, SrcW));
  Canvas := NewSurface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);
  // Rotate 90 degrees clockwise
  Canvas.Translate(SrcH, 0);
  Canvas.Rotate(90);
  Canvas.DrawImage(SrcImage, 0, 0);
  Result := NewSurface.MakeImageSnapshot;
end;
{ TPlanetTextureGen }

class function TPlanetTextureGen.Generate(PlanetType: Integer; Seed: Cardinal; Size: Integer): TTexture2D;
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  SkImage, FinalImage: ISkImage;
  MemStream: TMemoryStream;
  RayImg: TImage;
begin
  Result.id := 0;
  // Generate with 2:1 aspect ratio for seamless sphere mapping
  ImgInfo := TSkImageInfo.Create(Size, Size div 2);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then
    Exit;
  Canvas := Surface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);
  // Draw original textures normally (no AntiAlias!)
  case PlanetType of
    0:
      DrawRocky(Canvas, Size, Size div 2, Seed);
    1:
      DrawEarth(Canvas, Size, Size div 2, Seed);
    2:
      DrawMars(Canvas, Size, Size div 2, Seed);
    3:
      DrawGasGiant(Canvas, Size, Size div 2, Seed);
    4:
      DrawIce(Canvas, Size, Size div 2, Seed);
  end;
  SkImage := Surface.MakeImageSnapshot;
  // Rotate the finished image 90 degrees so Raylib wraps it correctly
  FinalImage := RotateSkImage90(SkImage);
  MemStream := TMemoryStream.Create;
  try
    if FinalImage.EncodeToStream(MemStream, TSkEncodedImageFormat.PNG) then
    begin
      MemStream.Position := 0;
      RayImg := LoadImageFromMemory('.png', MemStream.Memory, Integer(MemStream.Size));
      if RayImg.data <> nil then
      begin
        Result := LoadTextureFromImage(RayImg);
        UnloadImage(RayImg);
        if Result.id > 0 then
        begin
          SetTextureFilter(Result, TEXTURE_FILTER_TRILINEAR);
          // Crucial for seamless sphere wrapping
          SetTextureWrap(Result, TEXTURE_WRAP_REPEAT);
          GenTextureMipmaps(@Result);
        end;
      end;
    end;
  finally
    MemStream.Free;
  end;
end;
{ Helper: Tileable Noise Painter using Skia Perlin Noise }

procedure DrawTileableNoise(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal; BaseColor: TAlphaColor; Opacity: Byte);
var
  Paint: ISkPaint;
  Shader: ISkShader;
  TileSize: TSize;
begin
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.Color := BaseColor;
  Paint.Alpha := Opacity;
  TileSize.Width := W;
  TileSize.Height := H;
  // Kein Scale-Parameter mehr hier, damit es nicht verfälscht wird
  Shader := TSkShader.MakePerlinNoiseFractalNoise(0.015, 0.015, 4, 0.0, TileSize);
  if Assigned(Shader) then
  begin
    Paint.Shader := Shader;
    Canvas.DrawPaint(Paint);
  end
  else
  begin
    Canvas.DrawPaint(Paint);
  end;
end;
{ Helper to draw sharp, fine veins/cracks directly on a Canvas }

procedure DrawFineVeins(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal; Color: TAlphaColor; Count: Integer);
var
  Paint: ISkPaint;
  PB: ISkPathBuilder;
  i, j: Integer;
  X, Y, SegLen, Ang: Single;
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 1.0;
  Paint.Color := Color;
  for i := 0 to Count do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(PointF(X, Y));
    SegLen := 15 + RngNext * 40;
    Ang := RngNext * 6.28;
    for j := 0 to 4 + Trunc(RngNext * 5) do
    begin
      Ang := Ang + (RngNext - 0.5) * 1.2;
      X := X + Cos(Ang) * SegLen;
      Y := Y + Sin(Ang) * SegLen;
      if X > W then
        X := X - W;
      if X < 0 then
        X := X + W;
      PB.LineTo(PointF(X, Y));
    end;
    Canvas.DrawPath(PB.Detach, Paint);
  end;
end;
{==============================================================================*
 *  ROCKY PLANET
 *==============================================================================}

class procedure TPlanetTextureGen.DrawRocky(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
var
  Paint: ISkPaint;
  i: Integer;
  X, Y, R: Single;
  Colors: TArray<TAlphaColor>;
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  Colors := TArray<TAlphaColor>.Create(SkCol(75, 60, 45), SkCol(130, 110, 85), SkCol(95, 80, 60));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;
  // Fine tileable noise
  DrawTileableNoise(Canvas, W, H, Seed, SkCol(50, 40, 30), 80);
  // Normal sized craters
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 2.0);
  for i := 0 to 60 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 8 + RngNext * 25;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := SkCol(35, 25, 18, 200);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
    if X < R then
      Canvas.DrawCircle(PointF(X + W, Y), R, Paint);
    if X > W - R then
      Canvas.DrawCircle(PointF(X - W, Y), R, Paint);
  end;
  // Sharp fine cracks
  Paint.MaskFilter := nil;
  DrawFineVeins(Canvas, W, H, Seed + 10, SkCol(40, 30, 20, 150), 40);
end;
{==============================================================================*
 *  EARTH-LIKE PLANET
 *==============================================================================}

class procedure TPlanetTextureGen.DrawEarth(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
var
  Paint: ISkPaint;
  i, j: Integer;
  X, Y, R: Single;
  Colors: TArray<TAlphaColor>;
  LandLayer: ISkSurface;
  LandCanvas: ISkCanvas;
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  // Deep ocean base
  Paint.Color := SkCol(15, 50, 100);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  // Water variation (deep currents)
  DrawTileableNoise(Canvas, W, H, Seed + 99, SkCol(10, 30, 60), 60);
  // Shallow water / coastlines (lighter blue overlay)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 15.0);
  for i := 0 to 40 do
  begin
    X := RngNext * W;
    Y := 40 + RngNext * (H - 80);
    R := 40 + RngNext * 60;
    Paint.Color := SkCol(40, 110, 160, 120);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
    if X < R then
      Canvas.DrawCircle(PointF(X + W, Y), R, Paint);
    if X > W - R then
      Canvas.DrawCircle(PointF(X - W, Y), R, Paint);
  end;
  // Create a separate transparent layer for land so veins don't bleed into water!
  LandLayer := TSkSurface.MakeRaster(TSkImageInfo.Create(W, H));
  LandCanvas := LandLayer.Canvas;
  LandCanvas.Clear(TAlphaColorRec.Null);
  // Continents on Land Layer
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 8.0);
  for i := 0 to 12 do
  begin
    X := RngNext * W;
    Y := 60 + RngNext * (H - 120);
    for j := 0 to 10 + Trunc(RngNext * 6) do
    begin
      var CX := X + (RngNext - 0.5) * 150;
      var CY := Y + (RngNext - 0.5) * 100;
      var CR := 25 + RngNext * 45;
      if CX < 0 then
        CX := CX + W;
      if CX > W then
        CX := CX - W;
      if RngNext > 0.5 then
        Paint.Color := SkCol(40, 100, 45, 220)
      else
        Paint.Color := SkCol(110, 85, 50, 220);
      LandCanvas.DrawCircle(PointF(CX, CY), CR, Paint);
    end;
  end;
  // Draw fine veins ONLY ON LAND
  Paint.MaskFilter := nil;
  DrawFineVeins(LandCanvas, W, H, Seed + 20, SkCol(150, 120, 80, 160), 80);
  DrawFineVeins(LandCanvas, W, H, Seed + 30, SkCol(20, 60, 30, 140), 60);
  // Merge Land Layer onto Main Canvas
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := nil;
  Canvas.DrawImage(LandLayer.MakeImageSnapshot, 0, 0, Paint);
  // FEINE, DEZENTE WOLKEN (Kein Weiß-Schwall mehr)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 12.0);
  Paint.Style := TSkPaintStyle.Fill;
  for i := 0 to 60 do // 60 Wolkenformationen
  begin
    X := RngNext * W;
    Y := 20 + RngNext * (H - 40);
    // Kleinere, engere Streuung für feine Züge
    for j := 0 to 5 + Trunc(RngNext * 10) do
    begin
      var CX := X + (RngNext - 0.5) * 80;
      var CY := Y + (RngNext - 0.5) * 30;
      var CR := 10 + RngNext * 25; // Deutlich kleinerer Radius!
      if CX < 0 then
        CX := CX + W;
      if CX > W then
        CX := CX - W;
      // Gedämpftes Grau-Weiß mit maximal 40% Deckkraft
      Paint.Color := SkCol(230, 230, 235, 60 + Trunc(RngNext * 40));
      Canvas.DrawCircle(PointF(CX, CY), CR, Paint);
      if CX < CR then
        Canvas.DrawCircle(PointF(CX + W, CY), CR, Paint);
      if CX > W - CR then
        Canvas.DrawCircle(PointF(CX - W, CY), CR, Paint);
    end;
  end;
end;
{==============================================================================*
 *  MARS-LIKE PLANET
 *==============================================================================}

class procedure TPlanetTextureGen.DrawMars(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
var
  Paint: ISkPaint;
  i: Integer;
  X, Y, R: Single;
  Colors: TArray<TAlphaColor>;
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  Colors := TArray<TAlphaColor>.Create(SkCol(130, 55, 25), SkCol(190, 95, 45), SkCol(145, 65, 30));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;
  // Fine terrain noise
  DrawTileableNoise(Canvas, W, H, Seed, SkCol(80, 30, 15), 100);
  DrawTileableNoise(Canvas, W, H, Seed + 2, SkCol(200, 120, 60), 60);
  // Normal craters
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 2.0);
  for i := 0 to 50 do
  begin
    X := RngNext * W;
    Y := 20 + RngNext * (H - 40);
    R := 6 + RngNext * 18;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := SkCol(80, 25, 10, 180);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
    if X < R then
      Canvas.DrawCircle(PointF(X + W, Y), R, Paint);
    if X > W - R then
      Canvas.DrawCircle(PointF(X - W, Y), R, Paint);
  end;
  // Fine cracks
  Paint.MaskFilter := nil;
  DrawFineVeins(Canvas, W, H, Seed + 40, SkCol(50, 15, 5, 150), 40);
end;
{==============================================================================*
 *  GAS GIANT
 *==============================================================================}

class procedure TPlanetTextureGen.DrawGasGiant(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
var
  Paint: ISkPaint;
  i: Integer;
  Y, Amp, Phase: Single;
  Colors: TArray<TAlphaColor>;
  PB: ISkPathBuilder;
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  Colors := TArray<TAlphaColor>.Create(SkCol(190, 150, 90), SkCol(230, 200, 150), SkCol(170, 120, 70), SkCol(220, 185, 130), SkCol(150, 100, 60), SkCol(210, 170, 110), SkCol(180, 140, 80), SkCol(190, 150, 90));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;
  // Wavy lines
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3.0;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 4.0);
  for i := 0 to 12 do
  begin
    Y := (i + 1) * (H / 13.0);
    Amp := 6 + RngNext * 15;
    Phase := RngNext * 6.28;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(PointF(0, Y));
    var X: Single := 0;
    while X <= W do
    begin
      PB.LineTo(PointF(X, Y + Sin(X * 0.035 + Phase) * Amp + Sin(X * 0.11 + Phase * 2) * Amp * 0.35));
      X := X + 4;
    end;
    PB.LineTo(PointF(W, Y));
    PB.LineTo(PointF(0, Y));
    if RngNext > 0.5 then
      Paint.Color := SkCol(240, 210, 160, 120)
    else
      Paint.Color := SkCol(120, 80, 50, 120);
    Canvas.DrawPath(PB.Detach, Paint);
  end;
end;
{==============================================================================*
 *  ICE PLANET
 *==============================================================================}

class procedure TPlanetTextureGen.DrawIce(Canvas: ISkCanvas; W, H: Integer; Seed: Cardinal);
var
  Paint: ISkPaint;
  i: Integer;
  X, Y, R: Single;
  Colors: TArray<TAlphaColor>;
  PB: ISkPathBuilder;
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  Colors := TArray<TAlphaColor>.Create(SkCol(220, 235, 250), SkCol(190, 215, 240), SkCol(225, 240, 255));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;
  // Fine tileable noise
  DrawTileableNoise(Canvas, W, H, Seed, SkCol(100, 140, 200), 100);
  DrawTileableNoise(Canvas, W, H, Seed + 1, SkCol(255, 255, 255), 60);
  // Cracks
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 2.0;
  for i := 0 to 35 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(PointF(X, Y));
    var SegLen := 15 + RngNext * 35;
    var Ang := RngNext * 6.28;
    var j: Integer;
    for j := 0 to 3 + Trunc(RngNext * 4) do
    begin
      Ang := Ang + (RngNext - 0.5) * 1.5;
      X := X + Cos(Ang) * SegLen;
      Y := Y + Sin(Ang) * SegLen;
      if X > W then
        X := X - W;
      if X < 0 then
        X := X + W;
      PB.LineTo(PointF(X, Y));
    end;
    Paint.Color := SkCol(150, 190, 235, 140);
    Canvas.DrawPath(PB.Detach, Paint);
  end;
end;
{ TSunTextureGen }

class function TSunTextureGen.Generate(Seed: Cardinal; Size: Integer): TTexture2D;
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  Paint: ISkPaint;
  SkImage: ISkImage;
  MemStream: TMemoryStream;
  RayImg: TImage;
  i: Integer;
  X, Y, R: Single;
  Colors: TArray<TAlphaColor>;
  PB: ISkPathBuilder;
  BaseColor, DarkSpot, BrightCrack: TAlphaColor;
begin
  Result.id := 0;
  ImgInfo := TSkImageInfo.Create(Size, Size div 2);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then
    Exit;
  Canvas := Surface.Canvas;
  Paint := TSkPaint.Create;
  Paint.AntiAlias := False;
  // 1. Base Color: Bright White-Yellow (Fully Opaque)
  BaseColor := SkCol(255, 180, 140, 255);
  Canvas.Clear(BaseColor);
  // 2. Dark Sunspots (Fully Opaque)
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 8.0);
  DarkSpot := SkCol(180, 60, 0, 255);
  for i := 0 to 20 do
  begin
    X := Random * Size;
    Y := Random * (Size div 2);
    R := 15 + Random * 50;
    Paint.Color := DarkSpot;
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;
  // 3. Bright Yellow Granulation / Plasma (Fully Opaque)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 2.0);
  BrightCrack := SkCol(255, 255, 240, 255);
  for i := 0 to 400 do
  begin
    X := Random * Size;
    Y := Random * (Size div 2);
    R := 3 + Random * 8;
    Paint.Color := BrightCrack;
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;
  // 4. Fine White Lightning / Crackles (Fully Opaque)
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 2.0;
  Paint.StrokeCap := TSkStrokeCap.Round;
  for i := 0 to 80 do
  begin
    X := Random * Size;
    Y := Random * (Size div 2);
    PB := TSkPathBuilder.Create;
    PB.MoveTo(PointF(X, Y));
    var SegLen: Single := 15 + Random * 30;
    var Ang: Single := Random * 6.28;
    var j: Integer;
    for j := 0 to 3 + Trunc(Random * 4) do
    begin
      Ang := Ang + (Random - 0.5) * 1.5;
      X := X + Cos(Ang) * SegLen;
      Y := Y + Sin(Ang) * SegLen;
      if X > Size then
        X := X - Size;
      if X < 0 then
        X := X + Size;
      if Y > Size / 2 then
        Y := Y - Size / 2;
      if Y < 0 then
        Y := Y + Size / 2;
      PB.LineTo(PointF(X, Y));
    end;
    Paint.Color := SkCol(255, 255, 255, 255);
    Canvas.DrawPath(PB.Detach, Paint);
  end;
  SkImage := Surface.MakeImageSnapshot;
  MemStream := TMemoryStream.Create;
  try
    if SkImage.EncodeToStream(MemStream, TSkEncodedImageFormat.PNG) then
    begin
      MemStream.Position := 0;
      RayImg := LoadImageFromMemory('.png', MemStream.Memory, Integer(MemStream.Size));
      if RayImg.data <> nil then
      begin
        Result := LoadTextureFromImage(RayImg);
        UnloadImage(RayImg);
        if Result.id > 0 then
        begin
          SetTextureFilter(Result, TEXTURE_FILTER_TRILINEAR);
          SetTextureWrap(Result, TEXTURE_WRAP_REPEAT);
        end;
      end;
    end;
  finally
    MemStream.Free;
  end;
end;

end.

