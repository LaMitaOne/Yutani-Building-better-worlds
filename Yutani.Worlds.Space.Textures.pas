unit Yutani.Worlds.Space.Textures;

{==============================================================================*
 *  Yutani Space Textures - Procedural Planet Texture Generator (Skia)
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Uses Skia4Delphi to generate unique, procedural planet surface textures
 *    at runtime. Each planet type (Rocky, Earth, Mars, Gas Giant, Ice) gets
 *    a custom rendering routine with gradients, noise, craters, bands, etc.
 *    The finished Skia surface is encoded to PNG in memory and loaded as a
 *    Raylib TTexture2D with trilinear filtering and mipmaps.
 *
 *  License: Apache-2.0
 *==============================================================================}

{$POINTERMATH ON}
{$Q-}
{$R-}

interface

uses
  System.SysUtils, System.Classes, System.Math, System.Types, System.UITypes,
  Skia, Raylib;

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
  ImgInfo := TSkImageInfo.Create(Size, Size);
  Surface := TSkSurface.MakeRaster(ImgInfo);
  if not Assigned(Surface) then
    Exit;
  Canvas := Surface.Canvas;
  Canvas.Clear(TAlphaColorRec.Null);
  case PlanetType of
    0:
      DrawRocky(Canvas, Size, Size, Seed);
    1:
      DrawEarth(Canvas, Size, Size, Seed);
    2:
      DrawMars(Canvas, Size, Size, Seed);
    3:
      DrawGasGiant(Canvas, Size, Size, Seed);
    4:
      DrawIce(Canvas, Size, Size, Seed);
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
          SetTextureWrap(Result, TEXTURE_WRAP_CLAMP);
          GenTextureMipmaps(@Result);
        end;
      end;
    end;
  finally
    MemStream.Free;
  end;
end;

{==============================================================================*
 *  ROCKY PLANET — Brown/gray base, craters, maria, highlands.
 *  No polar caps. Random rocky surface.
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

  // Base gradient: random brown/gray tones
  Colors := TArray<TAlphaColor>.Create(SkCol(60 + Round(RngNext * 40), 50 + Round(RngNext * 30), 40 + Round(RngNext * 20)), SkCol(120 + Round(RngNext * 40), 100 + Round(RngNext * 30), 75 + Round(RngNext * 25)), SkCol(80 + Round(RngNext * 30), 65 + Round(RngNext * 25), 50 + Round(RngNext * 20)));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Dark maria (large blurred patches)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 30.0);
  for i := 0 to 18 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 60 + RngNext * 120;
    Paint.Color := SkCol(40, 30, 20, 160);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Lighter highland patches
  for i := 0 to 30 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 25 + RngNext * 70;
    Paint.Color := SkCol(170, 150, 120, 100);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Craters: dark center + lighter rim
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 3.0);
  for i := 0 to 35 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 8 + RngNext * 30;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := SkCol(35, 25, 18, 180);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
    Paint.Style := TSkPaintStyle.Stroke;
    Paint.StrokeWidth := 3.0;
    Paint.Color := SkCol(185, 165, 130, 200);
    Canvas.DrawCircle(PointF(X, Y), R + 2, Paint);
  end;

  // Fine noise speckles
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Fill;
  for i := 0 to 400 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    if RngNext > 0.5 then
      Paint.Color := SkCol(160, 140, 110, 60)
    else
      Paint.Color := SkCol(50, 40, 30, 60);
    Canvas.DrawCircle(PointF(X, Y), 2.0, Paint);
  end;
end;

{==============================================================================*
 *  EARTH-LIKE PLANET — Blue oceans, green/brown continents, white clouds.
 *  No polar caps. Bigger and rarer than other types (for landing later).
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

  // Deep blue ocean gradient
  Colors := TArray<TAlphaColor>.Create(SkCol(10 + Round(RngNext * 15), 40 + Round(RngNext * 20), 90 + Round(RngNext * 30)), SkCol(20 + Round(RngNext * 15), 60 + Round(RngNext * 25), 120 + Round(RngNext * 30)), SkCol(8 + Round(RngNext * 10), 35 + Round(RngNext * 15), 75 + Round(RngNext * 20)));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Continents: clusters of overlapping green/brown circles
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 15.0);
  for i := 0 to 10 do
  begin
    X := 60 + RngNext * (W - 120);
    Y := 80 + RngNext * (H - 160);
    for j := 0 to 12 + Trunc(RngNext * 8) do
    begin
      var CX := X + (RngNext - 0.5) * 180;
      var CY := Y + (RngNext - 0.5) * 120;
      var CR := 30 + RngNext * 60;
      if RngNext > 0.35 then
        Paint.Color := SkCol(40 + Round(RngNext * 30), 90 + Round(RngNext * 40), 40 + Round(RngNext * 30), 220)
      else
        Paint.Color := SkCol(90 + Round(RngNext * 30), 70 + Round(RngNext * 30), 45 + Round(RngNext * 20), 200);
      Canvas.DrawCircle(PointF(CX, CY), CR, Paint);
    end;
  end;

  // Small islands
  for i := 0 to 25 do
  begin
    X := RngNext * W;
    Y := 60 + RngNext * (H - 120);
    R := 10 + RngNext * 25;
    Paint.Color := SkCol(50 + Round(RngNext * 20), 100 + Round(RngNext * 30), 45 + Round(RngNext * 20), 180);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Cloud swirls
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 25.0);
  for i := 0 to 40 do
  begin
    X := RngNext * W;
    Y := 30 + RngNext * (H - 60);
    R := 35 + RngNext * 65;
    Paint.Color := SkCol(255, 255, 255, 80);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;
end;

{==============================================================================*
 *  MARS-LIKE PLANET — Red base, dark regions, dust storms.
 *  No polar caps. Random rusty surface.
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

  // Reddish-orange gradient
  Colors := TArray<TAlphaColor>.Create(SkCol(110 + Round(RngNext * 30), 45 + Round(RngNext * 20), 20 + Round(RngNext * 15)), SkCol(170 + Round(RngNext * 30), 80 + Round(RngNext * 25), 35 + Round(RngNext * 20)), SkCol(125 + Round(RngNext * 25), 55 + Round(RngNext * 20), 25 + Round(RngNext * 15)));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Dark regions
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 22.0);
  for i := 0 to 25 do
  begin
    X := RngNext * W;
    Y := 30 + RngNext * (H - 60);
    R := 35 + RngNext * 80;
    Paint.Color := SkCol(85, 35, 15, 140);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Lighter dust storm patches
  for i := 0 to 20 do
  begin
    X := RngNext * W;
    Y := 30 + RngNext * (H - 60);
    R := 20 + RngNext * 50;
    Paint.Color := SkCol(220, 150, 80, 80);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Craters
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 3.0);
  for i := 0 to 22 do
  begin
    X := RngNext * W;
    Y := 30 + RngNext * (H - 60);
    R := 8 + RngNext * 25;
    Paint.Style := TSkPaintStyle.Fill;
    Paint.Color := SkCol(70, 25, 12, 180);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
    Paint.Style := TSkPaintStyle.Stroke;
    Paint.StrokeWidth := 2.0;
    Paint.Color := SkCol(210, 140, 70, 160);
    Canvas.DrawCircle(PointF(X, Y), R + 1, Paint);
  end;

  // Fine noise
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Fill;
  for i := 0 to 250 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    if RngNext > 0.5 then
      Paint.Color := SkCol(200, 120, 60, 40)
    else
      Paint.Color := SkCol(80, 35, 18, 40);
    Canvas.DrawCircle(PointF(X, Y), 2.0, Paint);
  end;
end;

{==============================================================================*
 *  GAS GIANT — Horizontal bands, turbulence, great spot.
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

  // Banded gradient (varied tan/cream/orange tones)
  Colors := TArray<TAlphaColor>.Create(SkCol(170 + Round(RngNext * 30), 130 + Round(RngNext * 25), 75 + Round(RngNext * 20)), SkCol(215 + Round(RngNext * 25), 185 + Round(RngNext * 25), 135 + Round(RngNext * 20)), SkCol(155 + Round(RngNext * 25), 105 + Round(RngNext * 25), 60 + Round(RngNext * 15)), SkCol(210 + Round(RngNext * 25), 175 + Round(RngNext * 25), 120 + Round(RngNext * 20)), SkCol(135 + Round(RngNext * 25), 85 + Round(RngNext * 20), 50 + Round(RngNext * 15)), SkCol(200 + Round(RngNext * 25), 160 + Round(RngNext * 25), 100 + Round(RngNext * 20)), SkCol(170 + Round(RngNext * 25), 130 + Round(RngNext * 25), 70 + Round(RngNext * 20)), SkCol(170 + Round(RngNext * 30), 130 + Round(RngNext * 25), 75 + Round(RngNext * 20)));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Wavy turbulence lines at band boundaries
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
    if RngNext > 0.5 then
      Paint.Color := SkCol(240, 210, 160, 120)
    else
      Paint.Color := SkCol(120, 80, 50, 120);
    Canvas.DrawPath(PB.Snapshot, Paint);
  end;

  // Great spot (oval storm)
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 18.0);
  Paint.Style := TSkPaintStyle.Fill;
  var SpotX := W * (0.3 + RngNext * 0.4);
  var SpotY := H * (0.4 + RngNext * 0.2);
  Paint.Color := SkCol(175, 65, 40, 200);
  Canvas.DrawOval(TRectF.Create(SpotX - 75, SpotY - 38, SpotX + 75, SpotY + 38), Paint);
  Paint.Color := SkCol(220, 100, 60, 150);
  Canvas.DrawOval(TRectF.Create(SpotX - 45, SpotY - 22, SpotX + 45, SpotY + 22), Paint);

  // Small turbulent swirls
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 10.0);
  for i := 0 to 22 do
  begin
    var SX := RngNext * W;
    var SY := RngNext * H;
    var SR := 12 + RngNext * 35;
    if RngNext > 0.5 then
      Paint.Color := SkCol(240, 215, 165, 80)
    else
      Paint.Color := SkCol(125, 85, 50, 80);
    Canvas.DrawOval(TRectF.Create(SX - SR, SY - SR * 0.5, SX + SR, SY + SR * 0.5), Paint);
  end;
end;

{==============================================================================*
 *  ICE PLANET — White/blue base, crystalline cracks, shine.
 *  No polar caps. Random icy surface.
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

  // White to icy blue gradient
  Colors := TArray<TAlphaColor>.Create(SkCol(215 + Round(RngNext * 20), 230 + Round(RngNext * 15), 245 + Round(RngNext * 10)), SkCol(180 + Round(RngNext * 25), 210 + Round(RngNext * 20), 235 + Round(RngNext * 15)), SkCol(220 + Round(RngNext * 15), 235 + Round(RngNext * 10), 250 + Round(RngNext * 5)));
  Paint.Shader := TSkShader.MakeGradientLinear(PointF(0, 0), PointF(0, H), Colors);
  Paint.Style := TSkPaintStyle.Fill;
  Canvas.DrawPaint(Paint);
  Paint.Shader := nil;

  // Blue ice patches
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 18.0);
  for i := 0 to 25 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 30 + RngNext * 80;
    Paint.Color := SkCol(90 + Round(RngNext * 30), 130 + Round(RngNext * 30), 190 + Round(RngNext * 30), 120);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Crystalline cracks (angular paths)
  Paint.MaskFilter := nil;
  Paint.Style := TSkPaintStyle.Stroke;
  Paint.StrokeWidth := 2.0;
  Paint.StrokeCap := TSkStrokeCap.Round;
  for i := 0 to 28 do
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
      PB.LineTo(X, Y);
    end;
    Paint.Color := SkCol(140 + Round(RngNext * 20), 185 + Round(RngNext * 25), 230 + Round(RngNext * 15), 140);
    Canvas.DrawPath(PB.Snapshot, Paint);
  end;

  // Shine spots
  Paint.MaskFilter := TSkMaskFilter.MakeBlur(TSkBlurStyle.Normal, 8.0);
  Paint.Style := TSkPaintStyle.Fill;
  for i := 0 to 18 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    R := 10 + RngNext * 30;
    Paint.Color := SkCol(255, 255, 255, 100);
    Canvas.DrawCircle(PointF(X, Y), R, Paint);
  end;

  // Fine blue noise
  Paint.MaskFilter := nil;
  for i := 0 to 180 do
  begin
    X := RngNext * W;
    Y := RngNext * H;
    Paint.Color := SkCol(110 + Round(RngNext * 20), 155 + Round(RngNext * 20), 205 + Round(RngNext * 20), 30);
    Canvas.DrawCircle(PointF(X, Y), 2.0, Paint);
  end;
end;

end.

