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
  System.SysUtils, System.Classes, System.Math, System.Types, System.UITypes,
  Skia, Raylib;

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
  if s = 0 then s := 1;
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

{ TPlanetTextureGen }

class function TPlanetTextureGen.Generate(PlanetType: Integer; Seed: Cardinal; Size: Integer): TTexture2D;
var
  ImgInfo: TSkImageInfo;
  Surface: ISkSurface;
  Canvas: ISkCanvas;
  SkImage: ISkImage;
  MemStream: TMemoryStream;
  RayImg: TImage;
begin
  Result.id := 0;
  // Generate with 2:1 aspect ratio for seamless sphere mapping
  ImgInfo := TSkImageInfo.Create(Size, Size div 2);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then Exit;
  Canvas := Surface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);

  case PlanetType of
    0: DrawRocky(Canvas, Size, Size div 2, Seed);
    1: DrawEarth(Canvas, Size, Size div 2, Seed);
    2: DrawMars(Canvas, Size, Size div 2, Seed);
    3: DrawGasGiant(Canvas, Size, Size div 2, Seed);
    4: DrawIce(Canvas, Size, Size div 2, Seed);
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
  Paint.AntiAlias := True;
  Paint.Style := TSkPaintStyle.Fill;
  Paint.Color := BaseColor;
  Paint.Alpha := Opacity;

  // Create native tileable Perlin Fractal Noise
  // Using TileSize ensures the noise pattern wraps perfectly horizontally
  TileSize.Width := W;
  TileSize.Height := H;
  Shader := TSkShader.MakePerlinNoiseFractalNoise(0.015, 0.015, 4, 0.0, TileSize);

  if Assigned(Shader) then
  begin
    Paint.Shader := Shader;
    Canvas.DrawPaint(Paint);
  end
  else
  begin
    // Fallback: Just draw random blurred dots if shader fails
    Canvas.DrawPaint(Paint);
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
  Paint.AntiAlias := True;

  Colors := TArray<TAlphaColor>.Create(SkCol(75,60,45), SkCol(130,110,85), SkCol(95,80,60));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0,0), PointF(0,H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Tileable noise for surface variation
  DrawTileableNoise(Canvas, W, H, Seed, SkCol(50,40,30), 80);

  // Craters: ensure horizontal wrapping
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 3.0);
  for i := 0 to 40 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 10 + RngNext * 35;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := SkCol(35,25,18,180);
    Canvas.DrawCircle(PointF(X,Y), R, Paint);
    // Wrap horizontally for seamless tiling
    if X < R then Canvas.DrawCircle(PointF(X+W,Y), R, Paint);
    if X > W-R then Canvas.DrawCircle(PointF(X-W,Y), R, Paint);
  end;
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
begin
  RngSeed(Seed);
  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;

  Colors := TArray<TAlphaColor>.Create(SkCol(15,50,100), SkCol(25,75,130), SkCol(10,40,85));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0,0), PointF(0,H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Continents (wrapped)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 15.0);
  for i := 0 to 10 do
  begin
    X := RngNext * W;
    Y := 80 + RngNext * (H - 160);
    for j := 0 to 12 + Trunc(RngNext * 8) do
    begin
      var CX := X + (RngNext - 0.5) * 180;
      var CY := Y + (RngNext - 0.5) * 120;
      var CR := 30 + RngNext * 60;
      // Wrap X
      if CX < 0 then CX := CX + W;
      if CX > W then CX := CX - W;
      if RngNext > 0.35 then
        Paint.Color := SkCol(40,100,45,220)
      else
        Paint.Color := SkCol(100,80,50,200);
      Canvas.DrawCircle(PointF(CX,CY), CR, Paint);
    end;
  end;

  // Clouds (wrapped)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 25.0);
  for i := 0 to 40 do
  begin
    X := RngNext * W;
    Y := 30 + RngNext * (H - 60);
    R := 35 + RngNext * 65;
    Paint.Color := SkCol(255,255,255,80);
    Canvas.DrawCircle(PointF(X,Y), R, Paint);
    if X < R then Canvas.DrawCircle(PointF(X+W,Y), R, Paint);
    if X > W-R then Canvas.DrawCircle(PointF(X-W,Y), R, Paint);
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
  Paint.AntiAlias := True;

  Colors := TArray<TAlphaColor>.Create(SkCol(130,55,25), SkCol(190,95,45), SkCol(145,65,30));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0,0), PointF(0,H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Add some tileable noise detail
  DrawTileableNoise(Canvas, W, H, Seed, SkCol(80,30,15), 100);

  // Small craters wrapped
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 3.0);
  for i := 0 to 20 do
  begin
    X := RngNext * W;
    Y := 30 + RngNext * (H - 60);
    R := 5 + RngNext * 15;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := SkCol(80,25,10,160);
    Canvas.DrawCircle(PointF(X,Y), R, Paint);
    if X < R then Canvas.DrawCircle(PointF(X+W,Y), R, Paint);
    if X > W-R then Canvas.DrawCircle(PointF(X-W,Y), R, Paint);
  end;
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
  Paint.AntiAlias := True;

  Colors := TArray<TAlphaColor>.Create(
    SkCol(190,150,90), SkCol(230,200,150), SkCol(170,120,70),
    SkCol(220,185,130), SkCol(150,100,60), SkCol(210,170,110),
    SkCol(180,140,80), SkCol(190,150,90));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0,0), PointF(0,H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Wavy lines (naturally wrap if sinusoidal)
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 4.0;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 5.0);
  for i := 0 to 8 do
  begin
    Y := (i + 1) * (H / 9.0);
    Amp := 8 + RngNext * 18;
    Phase := RngNext * 6.28;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(0, Y);
    var X: Single := 0;
    while X <= W do
    begin
      PB.LineTo(X, Y + Sin(X * 0.035 + Phase) * Amp + Sin(X * 0.11 + Phase * 2) * Amp * 0.35);
      X := X + 4;
    end;
    // Close loop horizontally for seamless wrap
    PB.LineTo(W, Y);
    PB.LineTo(0, Y);
    if RngNext > 0.5 then
      Paint.Color := SkCol(240,210,160,120)
    else
      Paint.Color := SkCol(120,80,50,120);
    Canvas.DrawPath(PB.Snapshot, Paint);
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
  Paint.AntiAlias := True;

  Colors := TArray<TAlphaColor>.Create(SkCol(220,235,250), SkCol(190,215,240), SkCol(225,240,255));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0,0), PointF(0,H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Add tileable noise for ice variation
  DrawTileableNoise(Canvas, W, H, Seed, SkCol(100,140,200), 100);

  // Cracks (wrapped)
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 2.0;
  for i := 0 to 25 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    PB := TSkPathBuilder.Create;
    PB.MoveTo(X, Y);
    var SegLen := 18 + RngNext * 40;
    var Ang := RngNext * 6.28;
    var j: Integer;
    for j := 0 to 3 + Trunc(RngNext * 4) do
    begin
      Ang := Ang + (RngNext - 0.5) * 1.5;
      X := X + Cos(Ang) * SegLen;
      Y := Y + Sin(Ang) * SegLen;
      // Wrap X
      if X > W then X := X - W;
      if X < 0 then X := X + W;
      PB.LineTo(X, Y);
    end;
    Paint.Color := SkCol(150,190,235,140);
    Canvas.DrawPath(PB.Snapshot, Paint);
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
  if not Assigned(Surface) then Exit;
  Canvas := Surface.Canvas;

  Paint := TSkPaint.Create;
  Paint.AntiAlias := True;

  // 1. Base Color: Bright White-Yellow (Fully Opaque)
  BaseColor := SkCol(255, 200, 160, 255);
  Canvas.Clear(BaseColor);

  // 2. Dark Sunspots (Fully Opaque)
  Paint.Style := TSkPaintStyle.Fill;
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 12.0);
  DarkSpot := SkCol(180, 60, 0, 255); // Darker orange-brown spots
  for i := 0 to 20 do
  begin
    X := Random * Size;
    Y := Random * (Size div 2);
    R := 15 + Random * 50;
    Paint.Color := DarkSpot;
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // 3. Bright Yellow Granulation / Plasma (Fully Opaque)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 4.0);
  BrightCrack := SkCol(255, 255, 240, 255); // Very bright yellow-white
  for i := 0 to 200 do
  begin
    X := Random * Size;
    Y := Random * (Size div 2);
    R := 4 + Random * 12;
    Paint.Color := BrightCrack;
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // 4. Fine White Lightning / Crackles (Fully Opaque)
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 3.0;
  Paint.StrokeCap := TSkStrokeCap.Round;
  for i := 0 to 60 do
  begin
    X := Random * Size;
    Y := Random * (Size div 2);
    PB := TSkPathBuilder.Create;
    PB.MoveTo(X, Y);
    var SegLen: Single := 20 + Random * 40;
    var Ang: Single := Random * 6.28;
    var j: Integer;
    for j := 0 to 3 + Trunc(Random * 4) do
    begin
      Ang := Ang + (Random - 0.5) * 1.5;
      X := X + Cos(Ang) * SegLen;
      Y := Y + Sin(Ang) * SegLen;
      if X > Size then X := X - Size; if X < 0 then X := X + Size;
      if Y > Size/2 then Y := Y - Size/2; if Y < 0 then Y := Y + Size/2;
      PB.LineTo(X, Y);
    end;
    Paint.Color := SkCol(255, 255, 255, 255); // Pure white
    Canvas.DrawPath(PB.Snapshot, Paint);
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
