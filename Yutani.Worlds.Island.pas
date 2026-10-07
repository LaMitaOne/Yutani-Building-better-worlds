unit Yutani.Worlds.Island;

{==============================================================================*
 *  Yutani World: Island
 *==============================================================================}
{$POINTERMATH ON}
{$Q-}
{$R-}
interface
uses
  Winapi.Windows, System.SysUtils, System.Classes, System.Math, System.Types,
  Raylib, RayMath, rlgl;
type
  TGradientType = (gtSquare, gtCircle, gtDiamond, gtStar);
  THeightAndGradient = record
    height: single;
    gradientX: single;
    gradientY: single;
  end;
  TErosionMaker = class
  private
    FBrushOffX: array of TArray<integer>;
    FBrushOffY: array of TArray<integer>;
    FBrushWeights: array of TArray<single>;
    FCurrentErosionRadius: integer;
    FCurrentMapSize: integer;
    FCurrentSeed: integer;
    procedure Initialize(mapSize: integer; resetSeed: boolean);
    function CalculateHeightAndGradient(const mapData: TArray<single>; mapSize: integer; posX, posY: single): THeightAndGradient;
    procedure InitializeBrushIndices(mapSize, radius: integer);
    function RemapValue(value: single): single;
  public
    erosionRadius: integer;
    inertia: single;
    sedimentCapacityFactor: single;
    minSedimentCapacity: single;
    erodeSpeed: single;
    depositSpeed: single;
    evaporateSpeed: single;
    gravity: single;
    maxDropletLifetime: integer;
    initialWaterVolume: single;
    initialSpeed: single;
    constructor Create;
    procedure Erode(var mapData: TArray<single>; mapSize: integer; dropletAmount: integer = 1; resetSeed: boolean = False);
    procedure Gradient(var mapData: TArray<single>; mapSize: integer; normalizedOffset: single; gradientType: TGradientType);
    procedure Remap(var mapData: TArray<single>; mapSize: integer);
  end;
  TIslandWorld = class
  private
    FErosion: TErosionMaker;
    FMap: TArray<single>;
    FHeightmapTex: TTexture2D;
    FTerrainModel: TModel;
    FWaterModel: TModel;
    FTerrainShader: TShader;
    FWaterShader: TShader;
    FWaterDUDV: TTexture2D;
    FTerrainGradient: TTexture2D;
    FRockNormalMap: TTexture2D;
    FWaterMoveFactor: Single;
    FWaterMoveFactorLoc: Integer;
    FIsInitialized: Boolean;
    procedure GenerateHeightmapData;
    procedure BindSamplerUniforms(shader: TShader; count: integer);
  public
    constructor Create(const ResourcesPath: string; const DefaultWhiteTex: TTexture2D);
    destructor Destroy; override;
    procedure Draw(const Camera: TCamera3D);
  end;
implementation
const
  MAP_RESOLUTION = 512;
{ Perlin Noise }
var
  Permutation: array[0..511] of Byte;
const
  GRAD_X: array[0..7] of single = (1, -1, 1, -1, 1, -1, 0, 0);
  GRAD_Y: array[0..7] of single = (1, 1, -1, -1, 0, 0, 1, -1);
procedure InitPerlin(seed: integer);
var
  i, j, t: integer;
  state: Cardinal;
begin
  state := (Cardinal(seed) * 2654435761) xor $9E3779B9;
  for i := 0 to 255 do Permutation[i] := i;
  for i := 255 downto 1 do
  begin
    state := state * 1664525 + 1013904223;
    j := (state shr 16) mod Cardinal(i + 1);
    t := Permutation[i]; Permutation[i] := Permutation[j]; Permutation[j] := t;
  end;
  for i := 0 to 255 do Permutation[256 + i] := Permutation[i];
end;
function Perlin2D(x, y: single): single;
var
  xi, yi: integer; fx, fy, u, v: single; g00, g10, g01, g11: integer;
begin
  xi := Floor(x); yi := Floor(y); fx := x - xi; fy := y - yi;
  u := fx * fx * fx * (fx * (fx * 6 - 15) + 10);
  v := fy * fy * fy * (fy * (fy * 6 - 15) + 10);
  xi := xi and 255; yi := yi and 255;
  g00 := Permutation[Permutation[xi] + yi] and 7;
  g10 := Permutation[Permutation[xi + 1] + yi] and 7;
  g01 := Permutation[Permutation[xi] + yi + 1] and 7;
  g11 := Permutation[Permutation[xi + 1] + yi + 1] and 7;
  Result := u * (v * (GRAD_X[g11] * (fx - 1) + GRAD_Y[g11] * (fy - 1)) + (1 - v) * (GRAD_X[g10] * (fx - 1) + GRAD_Y[g10] * fy)) +
            (1 - u) * (v * (GRAD_X[g01] * fx + GRAD_Y[g01] * (fy - 1)) + (1 - v) * (GRAD_X[g00] * fx + GRAD_Y[g00] * fy));
end;
{ TErosionMaker }
constructor TErosionMaker.Create;
begin
  inherited Create;
  erosionRadius := 6; inertia := 0.05; sedimentCapacityFactor := 6.0;
  minSedimentCapacity := 0.01; erodeSpeed := 0.3; depositSpeed := 0.3;
  evaporateSpeed := 0.01; gravity := 4.0; maxDropletLifetime := 60;
  initialWaterVolume := 1.0; initialSpeed := 1.0;
  FCurrentErosionRadius := -1; FCurrentMapSize := -1;
end;
procedure TErosionMaker.Initialize(mapSize: integer; resetSeed: boolean);
begin
  if resetSeed then begin Randomize; FCurrentSeed := RandSeed; end;
  if (FCurrentErosionRadius <> erosionRadius) or (FCurrentMapSize <> mapSize) then
  begin
    InitializeBrushIndices(mapSize, erosionRadius);
    FCurrentErosionRadius := erosionRadius; FCurrentMapSize := mapSize;
  end;
end;
procedure TErosionMaker.Erode(var mapData: TArray<single>; mapSize, dropletAmount: integer; resetSeed: boolean);
var
  iteration, lifetime: integer; posX, posY, dirX, dirY, speed, water, sediment: single;
  nodeX, nodeY, dropletIndex: integer; cellOffsetX, cellOffsetY: single;
  hg: THeightAndGradient; len, newHeight, deltaHeight: single;
  sedimentCapacity, amountToDeposit, amountToErode, speedSq: single;
  offX, offY: TArray<integer>; wArr: TArray<single>; j, nodeIndex: integer;
  weighedErodeAmount, deltaSediment: single;
begin
  Initialize(mapSize, resetSeed);
  for iteration := 1 to dropletAmount do
  begin
    posX := Random(mapSize - 1); posY := Random(mapSize - 1); dirX := 0; dirY := 0;
    speed := initialSpeed; water := initialWaterVolume; sediment := 0;
    for lifetime := 0 to maxDropletLifetime - 1 do
    begin
      nodeX := Trunc(posX); nodeY := Trunc(posY); dropletIndex := nodeY * mapSize + nodeX;
      cellOffsetX := posX - nodeX; cellOffsetY := posY - nodeY;
      hg := CalculateHeightAndGradient(mapData, mapSize, posX, posY);
      dirX := dirX * inertia - hg.gradientX * (1 - inertia);
      dirY := dirY * inertia - hg.gradientY * (1 - inertia);
      len := Sqrt(dirX * dirX + dirY * dirY);
      if len > 0.0001 then begin dirX := dirX / len; dirY := dirY / len; end;
      posX := posX + dirX; posY := posY + dirY;
      if ((dirX = 0) and (dirY = 0)) or (posX < 0) or (posX >= mapSize - 1) or (posY < 0) or (posY >= mapSize - 1) then Break;
      newHeight := CalculateHeightAndGradient(mapData, mapSize, posX, posY).height;
      deltaHeight := newHeight - hg.height;
      sedimentCapacity := Max(-deltaHeight * speed * water * sedimentCapacityFactor, minSedimentCapacity);
      if (sediment > sedimentCapacity) or (deltaHeight > 0) then
      begin
        if deltaHeight > 0 then amountToDeposit := Min(deltaHeight, sediment)
        else amountToDeposit := (sediment - sedimentCapacity) * depositSpeed;
        sediment := sediment - amountToDeposit;
        mapData[dropletIndex] := mapData[dropletIndex] + amountToDeposit * (1 - cellOffsetX) * (1 - cellOffsetY);
        mapData[dropletIndex + 1] := mapData[dropletIndex + 1] + amountToDeposit * cellOffsetX * (1 - cellOffsetY);
        mapData[dropletIndex + mapSize] := mapData[dropletIndex + mapSize] + amountToDeposit * (1 - cellOffsetX) * cellOffsetY;
        mapData[dropletIndex + mapSize + 1] := mapData[dropletIndex + mapSize + 1] + amountToDeposit * cellOffsetX * cellOffsetY;
      end
      else
      begin
        amountToErode := Min((sedimentCapacity - sediment) * erodeSpeed, -deltaHeight);
        offX := FBrushOffX[dropletIndex]; offY := FBrushOffY[dropletIndex]; wArr := FBrushWeights[dropletIndex];
        for j := 0 to High(offX) do
        begin
          nodeIndex := (nodeY + offY[j]) * mapSize + nodeX + offX[j];
          weighedErodeAmount := amountToErode * wArr[j];
          deltaSediment := mapData[nodeIndex];
          if deltaSediment > weighedErodeAmount then deltaSediment := weighedErodeAmount;
          mapData[nodeIndex] := mapData[nodeIndex] - deltaSediment;
          sediment := sediment + deltaSediment;
        end;
      end;
      speedSq := speed * speed + deltaHeight * gravity;
      if speedSq < 0 then speed := 0 else speed := Sqrt(speedSq);
      water := water * (1 - evaporateSpeed);
    end;
  end;
end;
procedure TErosionMaker.Gradient(var mapData: TArray<single>; mapSize: integer; normalizedOffset: single; gradientType: TGradientType);
var x, y, index: integer; radius, gradient, g1, g2: single;
begin
  radius := mapSize / 2.0;
  for y := 0 to mapSize - 1 do
    for x := 0 to mapSize - 1 do
    begin
      index := y * mapSize + x;
      case gradientType of
        gtSquare: gradient := Max(Abs(x - radius), Abs(y - radius)) / radius;
        gtCircle: gradient := Min(((x - radius) * (x - radius) + (y - radius) * (y - radius)) / (radius * radius), 1.0);
        gtDiamond: gradient := Min((Abs(x - radius) + Abs(y - radius)) / radius, 1.0);
        gtStar: begin g1 := Min((Abs(x - radius) + Abs(y - radius)) / radius, 1.0); g2 := Max(Abs(x - radius), Abs(y - radius)) / radius; gradient := g1 + (g2 - g1) * 0.7; end;
      else gradient := Min(((x - radius) * (x - radius) + (y - radius) * (y - radius)) / (radius * radius), 1.0); end;
      gradient := 1 - gradient;
      mapData[index] := mapData[index] * gradient;
    end;
end;
function TErosionMaker.CalculateHeightAndGradient(const mapData: TArray<single>; mapSize: integer; posX, posY: single): THeightAndGradient;
var coordX, coordY: integer; x, y: single; nodeIndexNW: integer; heightNW, heightNE, heightSW, heightSE: single;
begin
  coordX := Trunc(posX); coordY := Trunc(posY); x := posX - coordX; y := posY - coordY;
  nodeIndexNW := coordY * mapSize + coordX;
  heightNW := mapData[nodeIndexNW]; heightNE := mapData[nodeIndexNW + 1];
  heightSW := mapData[nodeIndexNW + mapSize]; heightSE := mapData[nodeIndexNW + mapSize + 1];
  Result.gradientX := (heightNE - heightNW) * (1 - y) + (heightSE - heightSW) * y;
  Result.gradientY := (heightSW - heightNW) * (1 - x) + (heightSE - heightNE) * x;
  Result.height := heightNW * (1 - x) * (1 - y) + heightNE * x * (1 - y) + heightSW * (1 - x) * y + heightSE * x * y;
end;
procedure TErosionMaker.InitializeBrushIndices(mapSize, radius: integer);
var discX, discY: TArray<integer>; discW: TArray<single>; discCount, k, i, x, y: integer; centreX, centreY, coordX, coordY: integer; weightSum: single; fullX, fullY: TArray<integer>; fullW: TArray<single>; cx, cy: TArray<integer>; cw: TArray<single>; addIndex: integer; clipped: boolean;
begin
  SetLength(discX, radius * radius * 4); SetLength(discY, radius * radius * 4); SetLength(discW, radius * radius * 4);
  discCount := 0;
  for y := -radius to radius do
    for x := -radius to radius do
      if (x * x + y * y) < (radius * radius) then
      begin discX[discCount] := x; discY[discCount] := y; discW[discCount] := 1 - Sqrt(x * x + y * y) / radius; Inc(discCount); end;
  SetLength(fullX, discCount); SetLength(fullY, discCount); SetLength(fullW, discCount); weightSum := 0;
  for k := 0 to discCount - 1 do weightSum := weightSum + discW[k];
  for k := 0 to discCount - 1 do begin fullX[k] := discX[k]; fullY[k] := discY[k]; fullW[k] := discW[k] / weightSum; end;
  SetLength(FBrushOffX, mapSize * mapSize); SetLength(FBrushOffY, mapSize * mapSize); SetLength(FBrushWeights, mapSize * mapSize);
  SetLength(cx, discCount); SetLength(cy, discCount); SetLength(cw, discCount);
  for i := 0 to mapSize * mapSize - 1 do
  begin
    centreX := i mod mapSize; centreY := i div mapSize; clipped := False; addIndex := 0; weightSum := 0;
    for k := 0 to discCount - 1 do
    begin
      coordX := centreX + discX[k]; coordY := centreY + discY[k];
      if (coordX >= 0) and (coordX < mapSize) and (coordY >= 0) and (coordY < mapSize) then
      begin cx[addIndex] := discX[k]; cy[addIndex] := discY[k]; cw[addIndex] := discW[k]; weightSum := weightSum + cw[addIndex]; Inc(addIndex); end
      else clipped := True;
    end;
    if not clipped then begin FBrushOffX[i] := fullX; FBrushOffY[i] := fullY; FBrushWeights[i] := fullW; end
    else
    begin
      SetLength(FBrushOffX[i], addIndex); SetLength(FBrushOffY[i], addIndex); SetLength(FBrushWeights[i], addIndex);
      if weightSum > 0 then
        for k := 0 to addIndex - 1 do begin FBrushOffX[i][k] := cx[k]; FBrushOffY[i][k] := cy[k]; FBrushWeights[i][k] := cw[k] / weightSum; end;
    end;
  end;
end;
function TErosionMaker.RemapValue(value: single): single;
const
  PX: array[0..3] of single = (0.0, 0.15, 0.2, 1.0);
  PY: array[0..3] of single = (0.0, 0.16, 0.16, 1.0);
var
  i: integer;
begin
  if value < 0 then
    Exit(value);
  for i := 1 to 3 do
    if value < PX[i] then
      Exit(PY[i - 1] + (PY[i] - PY[i - 1]) * (value - PX[i - 1]) / (PX[i] - PX[i - 1]));
  Result := value;
end;
procedure TErosionMaker.Remap(var mapData: TArray<single>; mapSize: integer);
var i: integer;
begin
  for i := 0 to mapSize * mapSize - 1 do mapData[i] := RemapValue(mapData[i]);
end;
{ TIslandWorld }
constructor TIslandWorld.Create(const ResourcesPath: string; const DefaultWhiteTex: TTexture2D);
var
  Img: TImage;
  TerrainMesh, WaterMesh: TMesh;
  i, v: Integer;
  FHeightmapPixels: TArray<TColorB>;
begin
  FErosion := TErosionMaker.Create;
  SetLength(FMap, MAP_RESOLUTION * MAP_RESOLUTION);
  SetLength(FHeightmapPixels, MAP_RESOLUTION * MAP_RESOLUTION);
  GenerateHeightmapData;
  for i := 0 to High(FMap) do
  begin
    v := Trunc(FMap[i] * 255);
    if v < 0 then v := 0; if v > 255 then v := 255;
    FHeightmapPixels[i].r := v; FHeightmapPixels[i].g := v; FHeightmapPixels[i].b := v; FHeightmapPixels[i].a := 255;
  end;
  Img := GenImageColor(MAP_RESOLUTION, MAP_RESOLUTION, BLACK);
  MoveMemory(Img.data, @FHeightmapPixels[0], MAP_RESOLUTION * MAP_RESOLUTION * SizeOf(TColorB));
  FHeightmapTex := LoadTextureFromImage(Img);
  UnloadImage(Img);
  SetTextureFilter(FHeightmapTex, TEXTURE_FILTER_TRILINEAR);
  GenTextureMipmaps(@FHeightmapTex);
  // Load Textures
  FTerrainGradient := LoadTexture(PAnsiChar(AnsiString(ResourcesPath + 'terrainGradient.png')));
  SetTextureWrap(FTerrainGradient, TEXTURE_WRAP_CLAMP);
  GenTextureMipmaps(@FTerrainGradient);
  FWaterDUDV := LoadTexture(PAnsiChar(AnsiString(ResourcesPath + 'waterDUDV.png')));
  SetTextureFilter(FWaterDUDV, TEXTURE_FILTER_TRILINEAR);
  GenTextureMipmaps(@FWaterDUDV);
  FRockNormalMap := LoadTexture(PAnsiChar(AnsiString(ResourcesPath + 'rockNormalMap.png')));
  SetTextureFilter(FRockNormalMap, TEXTURE_FILTER_TRILINEAR);
  GenTextureMipmaps(@FRockNormalMap);
  // 1. TERRAIN SETUP
    TerrainMesh := GenMeshPlane(256, 256, 256, 256);
  FTerrainModel := LoadModelFromMesh(TerrainMesh);
  FTerrainModel.transform := MatrixTranslate(0, -1.2, 0);
  FTerrainModel.materials[0].maps[0].texture := FTerrainGradient;
  FTerrainModel.materials[0].maps[2].texture := FHeightmapTex;
  FTerrainModel.materials[0].maps[3].texture := FRockNormalMap;

  FTerrainShader := LoadShader(PAnsiChar(AnsiString(ResourcesPath + 'shaders/terrain.vert')), PAnsiChar(AnsiString(ResourcesPath + 'shaders/terrain.frag')));
  FTerrainModel.materials[0].shader := FTerrainShader;
  BindSamplerUniforms(FTerrainShader, 3);

  // 2. WATER SETUP
  WaterMesh := GenMeshPlane(5120, 5120, 10, 10);
  FWaterModel := LoadModelFromMesh(WaterMesh);
  FWaterModel.transform := MatrixTranslate(0, 0, 0);
  FWaterModel.materials[0].maps[0].texture := LoadTexture(PAnsiChar(AnsiString(ResourcesPath + 'skyGradient.png')));
  FWaterModel.materials[0].maps[2].texture := FWaterDUDV;

  FWaterShader := LoadShader(PAnsiChar(AnsiString(ResourcesPath + 'shaders/water.vert')), PAnsiChar(AnsiString(ResourcesPath + 'shaders/water.frag')));
  FWaterModel.materials[0].shader := FWaterShader;
  FWaterMoveFactorLoc := GetShaderLocation(FWaterShader, 'moveFactor');
  BindSamplerUniforms(FWaterShader, 3);

  FIsInitialized := True;
end;
destructor TIslandWorld.Destroy;
begin
  if Assigned(FErosion) then FreeAndNil(FErosion);
  if FHeightmapTex.id > 0 then UnloadTexture(FHeightmapTex);
  if FTerrainModel.meshes <> nil then UnloadModel(FTerrainModel);
  if FWaterModel.meshes <> nil then UnloadModel(FWaterModel);
  if FTerrainShader.id > 0 then UnloadShader(FTerrainShader);
  if FWaterShader.id > 0 then UnloadShader(FWaterShader);
  if FTerrainGradient.id > 0 then UnloadTexture(FTerrainGradient);
  if FWaterDUDV.id > 0 then UnloadTexture(FWaterDUDV);
  if FRockNormalMap.id > 0 then UnloadTexture(FRockNormalMap);
  inherited;
end;
procedure TIslandWorld.GenerateHeightmapData;
var
  x, y: integer;
  n: single;
begin
  Randomize;
  InitPerlin(Random(MaxInt));
  for y := 0 to MAP_RESOLUTION - 1 do
  begin
    for x := 0 to MAP_RESOLUTION - 1 do
    begin
      n := Perlin2D(x / MAP_RESOLUTION * 4.0 + 50, y / MAP_RESOLUTION * 4.0 + 50)
         + 0.5 * Perlin2D(x / MAP_RESOLUTION * 8.0 + 50, y / MAP_RESOLUTION * 8.0 + 50)
         + 0.25 * Perlin2D(x / MAP_RESOLUTION * 16.0 + 50, y / MAP_RESOLUTION * 16.0 + 50)
         + 0.125 * Perlin2D(x / MAP_RESOLUTION * 32.0 + 50, y / MAP_RESOLUTION * 32.0 + 50);
      n := n / 1.875;
      if n < -1 then n := -1;
      if n > 1 then n := 1;
      FMap[y * MAP_RESOLUTION + x] := (n + 1.0) / 2.0;
    end;
  end;
  FErosion.Gradient(FMap, MAP_RESOLUTION, 0.5, gtSquare);
  FErosion.Remap(FMap, MAP_RESOLUTION);
  FErosion.Erode(FMap, MAP_RESOLUTION, 0, True);
end;
procedure TIslandWorld.BindSamplerUniforms(shader: TShader; count: integer);
var
  i, v, loc: integer;
  Txt: AnsiString;
begin
  for i := 0 to count - 1 do
  begin
    v := i;
    Txt := AnsiString(Format('texture%d', [i]));
    loc := GetShaderLocation(shader, PAnsiChar(Txt));
    if loc >= 0 then SetShaderValue(shader, loc, @v, SHADER_UNIFORM_INT);
  end;
end;
procedure TIslandWorld.Draw(const Camera: TCamera3D);
var
  dt: Single;
  nDaytime: Single;
  AmbientColor: array[0..3] of Single;
  CameraPos: array[0..2] of Single;
  LightPos: array[0..2] of Single;
begin
  if not FIsInitialized then Exit;
  // Update Water Move Factor
  dt := GetFrameTime();
  FWaterMoveFactor := FWaterMoveFactor + 0.03 * dt;
  if FWaterMoveFactor > 1.0 then FWaterMoveFactor := FWaterMoveFactor - 1.0;
  SetShaderValue(FWaterShader, FWaterMoveFactorLoc, @FWaterMoveFactor, SHADER_UNIFORM_FLOAT);
  // Send Lighting Uniforms to the Terrain Shader!
  nDaytime := 1.0; // Bright midday sun
  AmbientColor[0] := 0.5; AmbientColor[1] := 0.5; AmbientColor[2] := 0.5; AmbientColor[3] := 1.0;
  SetShaderValue(FTerrainShader, GetShaderLocation(FTerrainShader, 'daytime'), @nDaytime, SHADER_UNIFORM_FLOAT);
  SetShaderValue(FTerrainShader, GetShaderLocation(FTerrainShader, 'ambient'), @AmbientColor, SHADER_UNIFORM_VEC4);
  CameraPos[0] := Camera.position.x; CameraPos[1] := Camera.position.y; CameraPos[2] := Camera.position.z;
  SetShaderValue(FTerrainShader, GetShaderLocation(FTerrainShader, 'viewPos'), @CameraPos, SHADER_UNIFORM_VEC3);
  LightPos[0] := 50.0; LightPos[1] := 80.0; LightPos[2] := 30.0;
  // Calculate scale factor (new size / old size) and send to shader
  var MeshSize: Single := 512.0; // Must match the size in GenMeshPlane!
  var ScaleFactor: Single := MeshSize / 32.0;
  SetShaderValue(FTerrainShader, GetShaderLocation(FTerrainShader, 'scaleFactor'), @ScaleFactor, SHADER_UNIFORM_FLOAT);
  SetShaderValue(FTerrainShader, GetShaderLocation(FTerrainShader, 'lightPos'), @LightPos, SHADER_UNIFORM_VEC3);
  // Draw Terrain (The Shader handles the 3D displacement via texture2!)
  DrawModel(FTerrainModel, Vector3Create(0, 0, 0), 1.0, WHITE);
  // Draw Water
  DrawModel(FWaterModel, Vector3Create(0, 0, 0), 1.0, WHITE);
end;
end.
