{==============================================================================*
 *  Yutani C.H.A.O.S. GPU - Photo-to-3D Particle Pipeline
 *------------------------------------------------------------------------------
 *  Module : Yutani.PhotoTo3D
 *  Type   : PNG/JPG -> 3D point cloud with real per-pixel RGB + depth
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *------------------------------------------------------------------------------
 *  Description:
 *  Turns any portrait / object photo (PNG with alpha or JPG) into a particle
 *  point cloud carrying the real RGB colour of every pixel plus a Z depth,
 *  ready for the Style 4 "Dense Solid / 3D-Photo-Hologram" renderer.
 *
 *  Colour extraction mirrors AddParticlePNG from the Skia-GPU alive-particle
 *  components: pixels with alpha above AlphaThreshold emit one particle at
 *  (tx, ty) carrying their true RGB colour.
 *
 *  Depth extraction (Z):
 *  - Option 1, fast / offline (default): Luma-to-Depth. Brightness blended
 *    with the radial distance to the face centre yields a plausible Z for
 *    nose, forehead and cheeks without any model.
 *  - Option 2, AI-supported: assign a DepthProvider callback that returns a
 *    grayscale depth bitmap (e.g. Depth Anything / MiDaS via ONNX). The
 *    pipeline then reads the provider's depth per pixel instead of luma.
 *
 *  Per-pixel normals are derived from the depth gradient (Sobel-style) so
 *  the rim-light shader gets a real surface gradient even on a flat photo.
 *
 *  Output is a TArray<TMeshParticlePoint> sharing the mesh loader's record
 *  so the GPU unit treats meshes and photos through one upload path.
 *==============================================================================}
unit Yutani.PhotoTo3D;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.UITypes, System.Math,
  System.Math.Vectors, FMX.Graphics, Yutani.MeshLoader;

type
  { Optional AI depth estimator. Given the photo path, return a grayscale
    bitmap whose luma encodes depth (bright = closer, by convention; set
    InvertDepth when the model emits the opposite). Assign to
    TPhotoLoadOptions.DepthProvider to use the AI path. }
  TDepthMapProvider = reference to function(const AFileName: string): FMX.Graphics.TBitmap;

  TPhotoLoadOptions = record
    TargetRadius: Single;       // final uniform radius (e.g. 130 for a face)
    Step: Integer;              // pixel step, 1 = every pixel, 2 = every 2nd
    MaxParticles: Integer;      // 0 = unlimited, else auto widens Step
    AlphaThreshold: Byte;       // minimum alpha to emit a particle
    DepthStrength: Single;      // Z range in particle units
    FlipY: Boolean;             // true for screen coords (Y down)
    NormalStrength: Single;     // amplification of the depth-gradient normal
    InvertDepth: Boolean;       // flip provider depth polarity
    DepthProvider: TDepthMapProvider;  // nil = luma-to-depth
    class function Default: TPhotoLoadOptions; static;
  end;

  TYutaniPhotoTo3D = class
  private
    class procedure NormalizeAndCenter(var APoints: TArray<TMeshParticlePoint>; const AOptions: TPhotoLoadOptions; AW, AH: Integer);
  public
    class function LoadFromFile(const AFileName: string; const AOptions: TPhotoLoadOptions): TArray<TMeshParticlePoint>;
  end;

implementation

{ TPhotoLoadOptions }

class function TPhotoLoadOptions.Default: TPhotoLoadOptions;
begin
  Result.TargetRadius := 130.0;
  Result.Step := 2;
  Result.MaxParticles := 80000;
  Result.AlphaThreshold := 8;
  Result.DepthStrength := 60.0;
  Result.FlipY := True;
  Result.NormalStrength := 1.0;
  Result.InvertDepth := False;
  Result.DepthProvider := nil;
end;

function PixelAt(const AData: FMX.Graphics.TBitmapData; X, Y: Integer): TAlphaColor;
begin
  Result := PCardinal(PByte(AData.Data) + (Y * AData.Pitch) + (X * 4))^;
end;

function LumaOf(C: TAlphaColor): Single;
begin
  Result := (0.299 * ((C shr 16) and $FF) + 0.587 * ((C shr 8) and $FF) + 0.114 * (C and $FF)) / 255.0;
end;

function Vec3Len(const V: TPoint3D): Single;
begin
  Result := Sqrt(V.X * V.X + V.Y * V.Y + V.Z * V.Z);
end;

{ TYutaniPhotoTo3D }

class procedure TYutaniPhotoTo3D.NormalizeAndCenter(var APoints: TArray<TMeshParticlePoint>; const AOptions: TPhotoLoadOptions; AW, AH: Integer);
var
  I, StepVal, OutIdx: Integer;
  MinV, MaxV, Center: TPoint3D;
  MaxExtent, Scale: Single;
  Filtered: TArray<TMeshParticlePoint>;
begin
  if Length(APoints) = 0 then
    Exit;

  { Widen the pixel step when MaxParticles is exceeded so the budget holds. }
  StepVal := Max(1, AOptions.Step);
  if (AOptions.MaxParticles > 0) and ((Length(APoints) div StepVal) > AOptions.MaxParticles) then
    StepVal := Ceil(Length(APoints) / AOptions.MaxParticles);

  if StepVal > 1 then
  begin
    SetLength(Filtered, (Length(APoints) + StepVal - 1) div StepVal);
    OutIdx := 0;
    I := 0;
    while I < Length(APoints) do
    begin
      Filtered[OutIdx] := APoints[I];
      Inc(OutIdx);
      Inc(I, StepVal);
    end;
    SetLength(Filtered, OutIdx);
    APoints := Filtered;
  end;

  if Length(APoints) = 0 then
    Exit;

  { Centre on the bounding box and apply a uniform scale to TargetRadius. }
  MinV := APoints[0].Position;
  MaxV := MinV;
  for I := 1 to High(APoints) do
  begin
    MinV.X := Min(MinV.X, APoints[I].Position.X);
    MinV.Y := Min(MinV.Y, APoints[I].Position.Y);
    MinV.Z := Min(MinV.Z, APoints[I].Position.Z);
    MaxV.X := Max(MaxV.X, APoints[I].Position.X);
    MaxV.Y := Max(MaxV.Y, APoints[I].Position.Y);
    MaxV.Z := Max(MaxV.Z, APoints[I].Position.Z);
  end;

  Center := TPoint3D.Create((MinV.X + MaxV.X) * 0.5, (MinV.Y + MaxV.Y) * 0.5, (MinV.Z + MaxV.Z) * 0.5);

  { Use the larger of the photo footprint and the Z range so the cloud keeps
    a sensible aspect rather than collapsing flat. }
  MaxExtent := Max(MaxV.X - MinV.X, Max(MaxV.Y - MinV.Y, MaxV.Z - MinV.Z));
  if MaxExtent <= 0.00001 then
    MaxExtent := 1.0;
  Scale := (AOptions.TargetRadius * 2.0) / MaxExtent;

  for I := 0 to High(APoints) do
  begin
    APoints[I].Position.X := (APoints[I].Position.X - Center.X) * Scale;
    APoints[I].Position.Y := (APoints[I].Position.Y - Center.Y) * Scale;
    APoints[I].Position.Z := (APoints[I].Position.Z - Center.Z) * Scale;
    if AOptions.FlipY then
    begin
      APoints[I].Position.Y := -APoints[I].Position.Y;
      APoints[I].Normal.Y := -APoints[I].Normal.Y;
    end;
  end;
end;

class function TYutaniPhotoTo3D.LoadFromFile(const AFileName: string; const AOptions: TPhotoLoadOptions): TArray<TMeshParticlePoint>;
var
  Bmp, DepthBmp: FMX.Graphics.TBitmap;
  Data, DepthData: FMX.Graphics.TBitmapData;
  W, H, X, Y, Step, Idx: Integer;
  C: TAlphaColor;
  A, R, G, B: Byte;
  Luma, Radial, ZFactor, Z, CX, CY, MaxR, Dx, Dy, Amp: Single;
  HasDepth: Boolean;
  ZField: TArray<Single>;
  Pt: TMeshParticlePoint;
  N: TPoint3D;
  L: Single;
begin
  Result := nil;
  if not FileExists(AFileName) then
    Exit;

  Bmp := FMX.Graphics.TBitmap.Create;
  try
    Bmp.LoadFromFile(AFileName);
    W := Bmp.Width;
    H := Bmp.Height;
    if (W <= 0) or (H <= 0) then
      Exit;
    if not Bmp.Map(TMapAccess.Read, Data) then
      Exit;
    try
      Step := Max(1, AOptions.Step);

      { Face centre heuristic: horizontal middle, slightly above vertical
        middle (eyes/forehead sit in the upper third of most portraits). }
      CX := W * 0.5;
      CY := H * 0.45;
      MaxR := Min(W, H) * 0.5;
      if MaxR <= 0 then
        MaxR := 1;

      { Optional AI depth map: map it once and read luma per pixel. }
      DepthBmp := nil;
      HasDepth := False;
      if Assigned(AOptions.DepthProvider) then
      begin
        DepthBmp := AOptions.DepthProvider(AFileName);
        if (DepthBmp <> nil) and (DepthBmp.Width > 0) and (DepthBmp.Height > 0) then
          HasDepth := DepthBmp.Map(TMapAccess.Read, DepthData);
      end;
      try
        { Precompute the Z field for the whole image so depth-gradient normals
          can be evaluated in a second pass without re-reading pixels. }
        SetLength(ZField, W * H);
        for Y := 0 to H - 1 do
        begin
          for X := 0 to W - 1 do
          begin
            if HasDepth then
            begin
              { Sample the depth bitmap with nearest-neighbour resampling so a
                provider map of any resolution maps onto the photo. }
              ZFactor := LumaOf(PixelAt(DepthData, (X * DepthData.Width) div W, (Y * DepthData.Height) div H));
              if AOptions.InvertDepth then
                ZFactor := 1.0 - ZFactor;
            end
            else
            begin
              { Luma-to-depth: brightness blended with radial distance to the
                face centre. Centre + bright = closest (nose, forehead). }
              C := PixelAt(Data, X, Y);
              Luma := LumaOf(C);
              Radial := Sqrt(Sqr(X - CX) + Sqr(Y - CY)) / MaxR;
              if Radial > 1 then
                Radial := 1;
              ZFactor := Luma * 0.55 + (1.0 - Radial) * 0.45;
            end;
            ZField[Y * W + X] := ZFactor * AOptions.DepthStrength;
          end;
        end;

        { Emit one particle per kept pixel with its true RGB colour and a
          normal derived from the local depth gradient. }
        Amp := AOptions.NormalStrength * 6.0;
        for Y := 0 to H - 1 do
        begin
          if (Y mod Step) <> 0 then
            Continue;
          for X := 0 to W - 1 do
          begin
            if (X mod Step) <> 0 then
              Continue;
            C := PixelAt(Data, X, Y);
            A := (C shr 24) and $FF;
            if A < AOptions.AlphaThreshold then
              Continue;
            R := (C shr 16) and $FF;
            G := (C shr 8) and $FF;
            B := C and $FF;

            Z := ZField[Y * W + X];

            { Sobel-style depth gradient -> surface normal. Flat regions
              yield (0, 0, 1) facing the camera; edges tilt outward, giving
              the rim-light shader a real gradient to emphasise. }
            if (X > 0) and (X < W - 1) then
              Dx := ZField[Y * W + (X + 1)] - ZField[Y * W + (X - 1)]
            else
              Dx := 0;
            if (Y > 0) and (Y < H - 1) then
              Dy := ZField[(Y + 1) * W + X] - ZField[(Y - 1) * W + X]
            else
              Dy := 0;
            N := TPoint3D.Create(-Dx * Amp, -Dy * Amp, 1.0);
            L := Vec3Len(N);
            if L > 0.00001 then
              N := TPoint3D.Create(N.X / L, N.Y / L, N.Z / L)
            else
              N := TPoint3D.Create(0, 0, 1);

            Pt.Position := TPoint3D.Create(X, Y, Z);
            Pt.Normal := N;
            Pt.Color := ($FF shl 24) or (R shl 16) or (G shl 8) or B;
            Pt.GroupTag := 0;
            Pt.BodyPart := bpHead;
            SetLength(Result, Length(Result) + 1);
            Result[High(Result)] := Pt;
          end;
        end;
      finally
        if HasDepth then
          DepthBmp.Unmap(DepthData);
        DepthBmp.Free;
      end;
    finally
      Bmp.Unmap(Data);
    end;
  finally
    Bmp.Free;
  end;

  NormalizeAndCenter(Result, AOptions, W, H);
end;

end.

