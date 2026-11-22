{==============================================================================*
 *  Yutani C.H.A.O.S. GPU - Universal 3D Mesh Loader (.GLB & .OBJ)
 *------------------------------------------------------------------------------
 *  Module : Yutani.MeshLoader
 *  Type   : Zero-Dependency Binary glTF 2.0 (.glb) & Wavefront (.obj) Parser
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *------------------------------------------------------------------------------
 *  Description:
 *  Loads 3D vertices and normals directly from .glb or .obj files into a
 *  normalized particle point cloud ready for OpenGL 4.3 SSBO upload.
 *
 *  Capabilities:
 *  - Binary glTF 2.0 (.glb): reads the JSON chunk + BIN chunk, extracts
 *    POSITION and NORMAL float32 accessors only (textures/materials are
 *    ignored, a 1k texture pack is therefore plenty). Supports mesh/node
 *    name filtering to drop hair/fur strips.
 *  - Wavefront (.obj): parses v / vn / f / g / o / usemtl, supports group
 *    and material filtering, and recomputes per-vertex normals from faces
 *    when the file does not ship usable normals (needed for rim light).
 *  - AStep subsampling (1 = 100 %, 2 = every 2nd, 3 = every 3rd) and a hard
 *    MaxParticles cap with automatic step widening.
 *  - Automatic bounding-box centering, uniform scaling and optional Y flip
 *    for screen-style coordinates.
 *  - Automatic body-part detection (head, neck, torso, upper/lower arms,
 *    upper/lower legs, hands, feet) by mesh name keywords with a vertical
 *    bounding-box band fallback, plus the original mesh-name index map.
 *  - Morph targets / blend shapes (head_neutral, mouth_open, smile, blink,
 *    ...) read from glTF primitives.targets + extras.targetNames, stored as
 *    position-delta arrays parallel to the point cloud.
 *  - Vertex frame sequences for body movement, sampled from glTF morph
 *    weight animation channels (keyframed blend-shape weights over time).
 *==============================================================================}
unit Yutani.MeshLoader;

interface

uses
  System.SysUtils, System.Classes, System.Types, System.Math,
  System.Math.Vectors, System.JSON, System.Generics.Collections;

type
  { Detected body region for a point. Used by the renderer to drive contour
    emphasis, circuit placement and per-region tinting. }
  TMeshBodyPart = (bpUnknown, bpHead, bpNeck, bpTorso, bpUpperArmLeft, bpUpperArmRight, bpLowerArmLeft, bpLowerArmRight, bpHandLeft, bpHandRight, bpUpperLegLeft, bpUpperLegRight, bpLowerLegLeft, bpLowerLegRight, bpFootLeft, bpFootRight);

  { A single particle source point. Position/Normal are in normalized,
    centered, scaled space. GroupTag is the originating mesh index and maps
    into TMeshLoadResult.MeshNames. }
  TMeshParticlePoint = record
    Position: TPoint3D;
    Normal: TPoint3D;
    Color: Cardinal;       // optional RGBA tint, $FFFFFFFF when none
    GroupTag: Cardinal;    // mesh index -> MeshNames[GroupTag]
    BodyPart: TMeshBodyPart;
  end;

  { Blend-shape / morph-target stored as a position-delta array parallel to
    the flattened point cloud. Final position = base + sum(weight * delta). }
  TMorphTarget = record
    Name: string;                      // head_neutral, mouth_open, smile, blink, ...
    PositionDeltas: TArray<TPoint3D>;  // length = point count, zero where N/A
    NormalDeltas: TArray<TPoint3D>;    // optional, parallel to PositionDeltas
  end;

  { Keyframed blend-shape weights over time, sampled from a glTF morph-weight
    animation channel. Each frame carries one weight per target. }
  TVertexFrameSequence = record
    Name: string;                       // glTF animation name
    TargetNames: TArray<string>;        // morph target names in order
    FrameTimes: TArray<Single>;         // keyframe times in seconds
    FrameWeights: TArray<TArray<Single>>; // [frame][target] weight
  end;

  TMeshLoadOptions = record
    TargetRadius: Single;            // final uniform radius, e.g. 130 head / 180 body
    Step: Integer;                   // 1 = 100 %, 2 = every 2nd, 3 = every 3rd
    MaxParticles: Integer;           // 0 = unlimited, else auto widens Step
    FlipY: Boolean;                  // true for screen coords (Y down)
    ExcludeKeywords: TArray<string>; // drop meshes/groups matching hair/fur/...
    RecomputeNormals: Boolean;       // rebuild per-vertex normals from faces
    DetectBodyParts: Boolean;        // run body-part classification
    LoadMorphTargets: Boolean;       // parse glTF blend shapes
    LoadVertexFrames: Boolean;       // parse glTF morph-weight animations
    VoxelDedup: Boolean;              // cap particles per 64^3 voxel so dense interior geometry cannot burn out
    class function Default: TMeshLoadOptions; static;
  end;

  { Full load result. Points is the flat particle cloud; the morph/frame
    structures let the renderer animate the same cloud without reloading. }
  TMeshLoadResult = record
    Points: TArray<TMeshParticlePoint>;
    MorphTargets: TArray<TMorphTarget>;
    VertexFrames: TArray<TVertexFrameSequence>;
    MeshNames: TArray<string>;       // indexed by TMeshParticlePoint.GroupTag
    Center: TPoint3D;                // pre-normalize bounding-box center
    Extent: Single;                  // pre-normalize max axis extent
    Scale: Single;                   // applied uniform scale factor
  end;

  TYutaniMeshLoader = class
  private
    class function IsExcluded(const AName: string; const AKeywords: TArray<string>): Boolean;
    class function IsLeftToken(const AName: string): Boolean;
    class function BodyPartFromName(const AName: string): TMeshBodyPart;
    class procedure DetectBodyParts(var APoints: TArray<TMeshParticlePoint>; const AMeshNames: TArray<string>);
    class procedure NormalizeAndFilter(var APoints: TArray<TMeshParticlePoint>; const AOptions: TMeshLoadOptions; out ACenter: TPoint3D; out AExtent, AScale: Single);
    class function LoadOBJ(const AFileName: string; const AOptions: TMeshLoadOptions; out AMeshNames: TArray<string>; out AMorphTargets: TArray<TMorphTarget>; out AVertexFrames: TArray<TVertexFrameSequence>): TArray<TMeshParticlePoint>;
    class function LoadGLB(const AFileName: string; const AOptions: TMeshLoadOptions; out AMeshNames: TArray<string>; out AMorphTargets: TArray<TMorphTarget>; out AVertexFrames: TArray<TVertexFrameSequence>): TArray<TMeshParticlePoint>;
  public
    class function LoadFromFile(const AFileName: string; const AOptions: TMeshLoadOptions): TMeshLoadResult; overload;
    class function LoadFromFile(const AFileName: string; ATargetRadius: Single = 140.0; AStep: Integer = 1; AMaxParticles: Integer = 150000): TArray<TMeshParticlePoint>; overload;

    { Combines base positions with morph-target deltas using the supplied
      weights (one per target, index-aligned). Returns the moved positions. }
    class function ApplyMorphTargets(const APoints: TArray<TMeshParticlePoint>; const ATargets: TArray<TMorphTarget>; const AWeights: TArray<Single>): TArray<TPoint3D>;

    { Linearly samples a vertex frame sequence at ATime seconds, returning one
      weight per target. Clamps to the first/last keyframe outside the range. }
    class function SampleFrameWeights(const ASequence: TVertexFrameSequence; ATime: Single): TArray<Single>;

    { Finds a morph target by name (case-insensitive), returns -1 if absent. }
    class function FindMorphTarget(const ATargets: TArray<TMorphTarget>; const AName: string): Integer;
  end;

implementation

type
  { Bookkeeping for a single glTF primitive so morph-target deltas can be
    scattered into the global parallel arrays after all meshes are loaded. }
  TPrimRecord = record
    BaseStart: Integer;
    Count: Integer;
    TargetDeltas: TArray<TArray<TPoint3D>>;     // [target] position deltas
    TargetNormDeltas: TArray<TArray<TPoint3D>>; // [target] normal deltas
  end;

{ TMeshLoadOptions }

class function TMeshLoadOptions.Default: TMeshLoadOptions;
begin
  Result.TargetRadius := 140.0;
  Result.Step := 1;
  Result.MaxParticles := 150000;
  Result.FlipY := True;
  Result.ExcludeKeywords := ['hair', 'fur', 'eyelash', 'lash', 'brow', 'brow_card', 'hair_card', 'teeth', 'tooth', 'tongue', 'gum', 'caruncle', 'mouth', 'mouth_bag', 'mouthinside', 'innermouth', 'mouthcavity', 'oral', 'oralcavity', 'jaw', 'head_inside', 'headinside', 'cornea', 'sclera', 'meniscus', 'iris', 'pupil', 'tear', 'tearduct'];
  Result.RecomputeNormals := False;
  Result.DetectBodyParts := True;
  Result.LoadMorphTargets := True;
  Result.LoadVertexFrames := True;
  Result.VoxelDedup := False;
end;

{ JSON helpers - keep glTF parsing tolerant of missing / mistyped fields. }

function JObj(V: TJSONValue): TJSONObject;
begin
  if V is TJSONObject then
    Result := V as TJSONObject
  else
    Result := nil;
end;

function JArr(V: TJSONValue): TJSONArray;
begin
  if V is TJSONArray then
    Result := V as TJSONArray
  else
    Result := nil;
end;

function JInt(O: TJSONObject; const Key: string; Def: Integer): Integer;
var
  V: TJSONValue;
begin
  if O = nil then
    Exit(Def);
  V := O.FindValue(Key);
  if V is TJSONNumber then
    Result := (V as TJSONNumber).AsInt
  else
    Result := Def;
end;

function JFlt(O: TJSONObject; const Key: string; Def: Single): Single;
var
  V: TJSONValue;
begin
  if O = nil then
    Exit(Def);
  V := O.FindValue(Key);
  if V is TJSONNumber then
    Result := (V as TJSONNumber).AsDouble
  else
    Result := Def;
end;

function JStr(O: TJSONObject; const Key: string; const Def: string): string;
var
  V: TJSONValue;
begin
  if O = nil then
    Exit(Def);
  V := O.FindValue(Key);
  if V is TJSONString then
    Result := (V as TJSONString).Value
  else
    Result := Def;
end;

function Vec3Len(const V: TPoint3D): Single;
begin
  Result := Sqrt(V.X * V.X + V.Y * V.Y + V.Z * V.Z);
end;

{ 4x4 column-major matrix helpers for glTF node transforms. glTF stores both
  the baked "matrix" (16 floats, column-major) and the decomposed TRS channels
  in the same layout, so one pipeline serves both. }

type
  TMat4 = array[0..15] of Single;   // column-major: element[col*4 + row]

function Mat4Identity: TMat4;
var
  I: Integer;
begin
  for I := 0 to 15 do
    Result[I] := 0;
  Result[0] := 1;
  Result[5] := 1;
  Result[10] := 1;
  Result[15] := 1;
end;

procedure Mat4Multiply(const A, B: TMat4; out C: TMat4);
var
  Col, Row, K: Integer;
  S: Single;
begin
  for Col := 0 to 3 do
    for Row := 0 to 3 do
    begin
      S := 0;
      for K := 0 to 3 do
        S := S + A[K * 4 + Row] * B[Col * 4 + K];
      C[Col * 4 + Row] := S;
    end;
end;

{ Compose a local matrix from Translation * Rotation(quaternion) * Scale, the
  glTF default when no baked "matrix" is present. Quaternion (qx,qy,qz,qw). }
function Mat4FromTRS(const T: TPoint3D; QX, QY, QZ, QW: Single; const S: TPoint3D): TMat4;
begin
  Result := Mat4Identity;
  Result[0] := (1 - 2 * (QY * QY + QZ * QZ)) * S.X;
  Result[1] := (2 * (QX * QY + QZ * QW)) * S.X;
  Result[2] := (2 * (QX * QZ - QY * QW)) * S.X;
  Result[4] := (2 * (QX * QY - QZ * QW)) * S.Y;
  Result[5] := (1 - 2 * (QX * QX + QZ * QZ)) * S.Y;
  Result[6] := (2 * (QY * QZ + QX * QW)) * S.Y;
  Result[8] := (2 * (QX * QZ + QY * QW)) * S.Z;
  Result[9] := (2 * (QY * QZ - QX * QW)) * S.Z;
  Result[10] := (1 - 2 * (QX * QX + QY * QY)) * S.Z;
  Result[12] := T.X;
  Result[13] := T.Y;
  Result[14] := T.Z;
end;

function Mat4FromMatrix16(const F: TArray<Single>): TMat4;
var
  I: Integer;
begin
  Result := Mat4Identity;
  for I := 0 to 15 do
    if I <= High(F) then
      Result[I] := F[I];
end;

{ Transform a position by the full 4x4 (rotation + scale + translation). }
function TransformPoint(const M: TMat4; const P: TPoint3D): TPoint3D;
begin
  Result := TPoint3D.Create(M[0] * P.X + M[4] * P.Y + M[8] * P.Z + M[12], M[1] * P.X + M[5] * P.Y + M[9] * P.Z + M[13], M[2] * P.X + M[6] * P.Y + M[10] * P.Z + M[14]);
end;

{ Transform a normal by the 3x3 rotation/linear part, then renormalize. For
  non-uniform scale this is an approximation (true normal matrix would be the
  inverse-transpose), but it is exact for rotation and uniform scale, which
  covers every avatar mesh we ship. }
function TransformNormal(const M: TMat4; const N: TPoint3D): TPoint3D;
var
  L: Single;
begin
  Result := TPoint3D.Create(M[0] * N.X + M[4] * N.Y + M[8] * N.Z, M[1] * N.X + M[5] * N.Y + M[9] * N.Z, M[2] * N.X + M[6] * N.Y + M[10] * N.Z);
  L := Vec3Len(Result);
  if L > 0.00001 then
    Result := TPoint3D.Create(Result.X / L, Result.Y / L, Result.Z / L)
  else
    Result := TPoint3D.Create(0, 0, 1);
end;

{ Linear part only (no translation) - for morph position deltas, which are
  offsets and must pick up rotation + scale but never the node translation. }
function TransformVec3Linear(const M: TMat4; const V: TPoint3D): TPoint3D;
begin
  Result := TPoint3D.Create(M[0] * V.X + M[4] * V.Y + M[8] * V.Z, M[1] * V.X + M[5] * V.Y + M[9] * V.Z, M[2] * V.X + M[6] * V.Y + M[10] * V.Z);
end;

{ Read a JSON array of numbers as a Single array (translation/rotation/scale/
  matrix). Tolerant of missing or mistyped fields. }
function JFloatArr(O: TJSONObject; const Key: string): TArray<Single>;
var
  Arr: TJSONArray;
  I: Integer;
  V: TJSONValue;
begin
  Result := nil;
  if O = nil then
    Exit;
  Arr := JArr(O.FindValue(Key));
  if Arr = nil then
    Exit;
  SetLength(Result, Arr.Count);
  for I := 0 to Arr.Count - 1 do
  begin
    V := Arr.Items[I];
    if V is TJSONNumber then
      Result[I] := (V as TJSONNumber).AsDouble
    else
      Result[I] := 0;
  end;
end;

{ Coerce a bare JSON number value (e.g. a node index in a children array) to
  Integer. }
function JNum(V: TJSONValue; Def: Integer): Integer;
begin
  if V is TJSONNumber then
    Result := (V as TJSONNumber).AsInt
  else
    Result := Def;
end;

{ TYutaniMeshLoader }

class function TYutaniMeshLoader.IsExcluded(const AName: string; const AKeywords: TArray<string>): Boolean;
var
  LowerName, KW: string;
begin
  if (AName = '') or (Length(AKeywords) = 0) then
    Exit(False);
  LowerName := AName.ToLower;
  for KW in AKeywords do
    if (KW <> '') and LowerName.Contains(KW.ToLower) then
      Exit(True);
  Result := False;
end;

class function TYutaniMeshLoader.IsLeftToken(const AName: string): Boolean;
var
  S: string;
begin
  { Heuristic side detection from mesh / node names. Covers the common
    naming conventions exported by DCC tools (Maya, Blender, Mixamo). }
  S := AName.ToLower;
  Result := S.Contains('left') or S.Contains('_l_') or S.Contains('_l.') or S.Contains('-l-') or S.Contains('-l.') or S.Contains('.l.') or S.Contains(' l ') or S.EndsWith('_l') or S.EndsWith('.l') or S.EndsWith('-l') or S.EndsWith(' l');
end;

class function TYutaniMeshLoader.BodyPartFromName(const AName: string): TMeshBodyPart;
var
  S: string;
begin
  S := AName.ToLower;
  if (S.Contains('head')) or S.Contains('skull') or S.Contains('face') or S.Contains('cranium') or S.Contains('visor') or S.Contains('helmet') or S.Contains('jaw') or S.Contains('scalp') then
    Exit(bpHead);
  if S.Contains('neck') or S.Contains('throat') or S.Contains('collar') then
    Exit(bpNeck);
  if S.Contains('torso') or S.Contains('chest') or S.Contains('spine') or S.Contains('pelvis') or S.Contains('hip') or S.Contains('abdomen') or S.Contains('body') or S.Contains('rib') or S.Contains('sternum') then
    Exit(bpTorso);
  if S.Contains('hand') or S.Contains('fist') or S.Contains('palm') then
    if IsLeftToken(S) then
      Exit(bpHandLeft)
    else
      Exit(bpHandRight);
  if S.Contains('foot') or S.Contains('boot') or S.Contains('toe') then
    if IsLeftToken(S) then
      Exit(bpFootLeft)
    else
      Exit(bpFootRight);
  if S.Contains('forearm') or S.Contains('elbow') or S.Contains('lowerarm') or S.Contains('lower_arm') or S.Contains('lower arm') then
    if IsLeftToken(S) then
      Exit(bpLowerArmLeft)
    else
      Exit(bpLowerArmRight);
  if S.Contains('arm') or S.Contains('shoulder') or S.Contains('bicep') or S.Contains('tricep') or S.Contains('upperarm') or S.Contains('upper_arm') or S.Contains('upper arm') or S.Contains('sleeve') or S.Contains('pauldron') then
    if IsLeftToken(S) then
      Exit(bpUpperArmLeft)
    else
      Exit(bpUpperArmRight);
  if S.Contains('shin') or S.Contains('calf') or S.Contains('knee') or S.Contains('lowerleg') or S.Contains('lower_leg') or S.Contains('lower leg') then
    if IsLeftToken(S) then
      Exit(bpLowerLegLeft)
    else
      Exit(bpLowerLegRight);
  if S.Contains('leg') or S.Contains('thigh') or S.Contains('quad') or S.Contains('upperleg') or S.Contains('upper_leg') or S.Contains('upper leg') or S.Contains('greave') or S.Contains('kneepad') then
    if IsLeftToken(S) then
      Exit(bpUpperLegLeft)
    else
      Exit(bpUpperLegRight);
  Result := bpUnknown;
end;

class procedure TYutaniMeshLoader.DetectBodyParts(var APoints: TArray<TMeshParticlePoint>; const AMeshNames: TArray<string>);
var
  I: Integer;
  MinY, MaxY, RangeY, HalfW, T, AbsX: Single;
begin
  if Length(APoints) = 0 then
    Exit;

  { Pass 1: name-based classification using the originating mesh name. This
    is the reliable path for rigged / named exports. }
  for I := 0 to High(APoints) do
  begin
    if (APoints[I].GroupTag < Cardinal(Length(AMeshNames))) and (AMeshNames[APoints[I].GroupTag] <> '') then
      APoints[I].BodyPart := BodyPartFromName(AMeshNames[APoints[I].GroupTag]);
  end;

  { Pass 2: vertical bounding-box band fallback for still-unclassified
    points. Bands are fractions of the post-normalize Y extent; horizontal
    side splits left/right. This is intentionally heuristic and only affects
    rim / contour emphasis, never geometry. }
  MinY := APoints[0].Position.Y;
  MaxY := MinY;
  HalfW := 0;
  for I := 0 to High(APoints) do
  begin
    if APoints[I].Position.Y < MinY then
      MinY := APoints[I].Position.Y;
    if APoints[I].Position.Y > MaxY then
      MaxY := APoints[I].Position.Y;
    if Abs(APoints[I].Position.X) > HalfW then
      HalfW := Abs(APoints[I].Position.X);
  end;
  RangeY := MaxY - MinY;
  if RangeY <= 0.0001 then
    RangeY := 1;
  if HalfW <= 0.0001 then
    HalfW := 1;

  for I := 0 to High(APoints) do
  begin
    if APoints[I].BodyPart <> bpUnknown then
      Continue;
    T := (APoints[I].Position.Y - MinY) / RangeY;   // 0 top .. 1 bottom
    AbsX := Abs(APoints[I].Position.X);
    if T < 0.18 then
      APoints[I].BodyPart := bpHead
    else if T < 0.24 then
      APoints[I].BodyPart := bpNeck
    else if T < 0.55 then
      APoints[I].BodyPart := bpTorso
    else if T < 0.72 then
    begin
      { Upper-limb band: outer points read as arms, inner as upper legs. }
      if AbsX > HalfW * 0.45 then
      begin
        if APoints[I].Position.X < 0 then
          APoints[I].BodyPart := bpUpperArmLeft
        else
          APoints[I].BodyPart := bpUpperArmRight;
      end
      else
      begin
        if APoints[I].Position.X < 0 then
          APoints[I].BodyPart := bpUpperLegLeft
        else
          APoints[I].BodyPart := bpUpperLegRight;
      end;
    end
    else
    begin
      { Lower band: outer = lower arms, inner = lower legs. }
      if AbsX > HalfW * 0.55 then
      begin
        if APoints[I].Position.X < 0 then
          APoints[I].BodyPart := bpLowerArmLeft
        else
          APoints[I].BodyPart := bpLowerArmRight;
      end
      else
      begin
        if APoints[I].Position.X < 0 then
          APoints[I].BodyPart := bpLowerLegLeft
        else
          APoints[I].BodyPart := bpLowerLegRight;
      end;
    end;
  end;
end;

class function TYutaniMeshLoader.LoadFromFile(const AFileName: string; ATargetRadius: Single; AStep: Integer; AMaxParticles: Integer): TArray<TMeshParticlePoint>;
var
  Opt: TMeshLoadOptions;
begin
  Opt := TMeshLoadOptions.Default;
  Opt.TargetRadius := ATargetRadius;
  Opt.Step := Max(1, AStep);
  Opt.MaxParticles := AMaxParticles;
  Result := LoadFromFile(AFileName, Opt).Points;
end;

class function TYutaniMeshLoader.LoadFromFile(const AFileName: string; const AOptions: TMeshLoadOptions): TMeshLoadResult;
var
  Ext: string;
  MeshNames: TArray<string>;
  MorphTargets: TArray<TMorphTarget>;
  VertexFrames: TArray<TVertexFrameSequence>;
begin
  Result.Points := nil;
  Result.MorphTargets := nil;
  Result.VertexFrames := nil;
  Result.MeshNames := nil;
  Result.Center := TPoint3D.Create(0, 0, 0);
  Result.Extent := 1;
  Result.Scale := 1;
  if not FileExists(AFileName) then
    Exit;

  Ext := ExtractFileExt(AFileName).ToLower;
  if Ext = '.glb' then
    Result.Points := LoadGLB(AFileName, AOptions, MeshNames, MorphTargets, VertexFrames)
  else if Ext = '.obj' then
    Result.Points := LoadOBJ(AFileName, AOptions, MeshNames, MorphTargets, VertexFrames)
  else
    raise Exception.CreateFmt('Unsupported mesh format: %s (use .glb or .obj)', [Ext]);

  Result.MeshNames := MeshNames;
  Result.MorphTargets := MorphTargets;
  Result.VertexFrames := VertexFrames;

  NormalizeAndFilter(Result.Points, AOptions, Result.Center, Result.Extent, Result.Scale);

  if AOptions.DetectBodyParts then
    DetectBodyParts(Result.Points, Result.MeshNames);
end;

{ Cap particle density per 64^3 voxel cell so dense interior geometry
  (teeth, mouth cavity, eye corners, nose wings) cannot dominate the rim light.
  Universal - works on any mesh without keyword tuning. Runs on the already
  normalized cloud, so the grid spans the [-ARadius, +ARadius] cube. Keeps at
  most MAX_PER_CELL particles per cell; survivors are compacted in place. }
procedure VoxelDedup(var APoints: TArray<TMeshParticlePoint>; ARadius: Single);
const
  GRID = 64;
  MAX_PER_CELL = 2;
var
  Cell: TArray<Byte>;
  CellSize, InvCell: Single;
  I, OutIdx, CX, CY, CZ, Idx: Integer;
  P: TPoint3D;
begin
  if Length(APoints) = 0 then
    Exit;
  CellSize := (ARadius * 2.0) / GRID;
  if CellSize <= 0.0001 then
    Exit;
  InvCell := 1.0 / CellSize;
  SetLength(Cell, GRID * GRID * GRID);
  for I := 0 to High(Cell) do
    Cell[I] := 0;
  OutIdx := 0;
  for I := 0 to High(APoints) do
  begin
    P := APoints[I].Position;
    CX := Trunc((P.X + ARadius) * InvCell);
    CY := Trunc((P.Y + ARadius) * InvCell);
    CZ := Trunc((P.Z + ARadius) * InvCell);
    if CX < 0 then
      CX := 0
    else if CX >= GRID then
      CX := GRID - 1;
    if CY < 0 then
      CY := 0
    else if CY >= GRID then
      CY := GRID - 1;
    if CZ < 0 then
      CZ := 0
    else if CZ >= GRID then
      CZ := GRID - 1;
    Idx := (CX * GRID + CY) * GRID + CZ;
    if Cell[Idx] < MAX_PER_CELL then
    begin
      APoints[OutIdx] := APoints[I];
      Inc(OutIdx);
      Inc(Cell[Idx]);
    end;
  end;
  SetLength(APoints, OutIdx);
end;

class procedure TYutaniMeshLoader.NormalizeAndFilter(var APoints: TArray<TMeshParticlePoint>; const AOptions: TMeshLoadOptions; out ACenter: TPoint3D; out AExtent, AScale: Single);
var
  I, StepVal, OutIdx: Integer;
  MinV, MaxV: TPoint3D;
  MaxExtent: Single;
  Filtered: TArray<TMeshParticlePoint>;
begin
  if Length(APoints) = 0 then
  begin
    ACenter := TPoint3D.Create(0, 0, 0);
    AExtent := 1;
    AScale := 1;
    Exit;
  end;

  { Step subsampling, widening Step automatically when a MaxParticles cap is
    set so the budget is respected without discarding geometry unevenly. }
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
  begin
    ACenter := TPoint3D.Create(0, 0, 0);
    AExtent := 1;
    AScale := 1;
    Exit;
  end;

  { Bounding box, center and uniform scale so the cloud fits TargetRadius. }
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

  ACenter := TPoint3D.Create((MinV.X + MaxV.X) * 0.5, (MinV.Y + MaxV.Y) * 0.5, (MinV.Z + MaxV.Z) * 0.5);

  MaxExtent := Max(MaxV.X - MinV.X, Max(MaxV.Y - MinV.Y, MaxV.Z - MinV.Z));
  if MaxExtent <= 0.00001 then
    MaxExtent := 1.0;
  AExtent := MaxExtent;
  AScale := (AOptions.TargetRadius * 2.0) / MaxExtent;

  for I := 0 to High(APoints) do
  begin
    APoints[I].Position.X := (APoints[I].Position.X - ACenter.X) * AScale;
    APoints[I].Position.Y := (APoints[I].Position.Y - ACenter.Y) * AScale;
    APoints[I].Position.Z := (APoints[I].Position.Z - ACenter.Z) * AScale;
    if AOptions.FlipY then
    begin
      APoints[I].Position.Y := -APoints[I].Position.Y;
      APoints[I].Normal.Y := -APoints[I].Normal.Y;
    end;
  end;

  { Voxel-grid density cap: keep at most 2 particles per 64^3 cell so dense
    interior geometry (teeth, eye corners, mouth cavity) cannot burn out the
    rim light - universal, independent of mesh names. }
  if AOptions.VoxelDedup then
    VoxelDedup(APoints, AOptions.TargetRadius);
end;

class function TYutaniMeshLoader.LoadOBJ(const AFileName: string; const AOptions: TMeshLoadOptions; out AMeshNames: TArray<string>; out AMorphTargets: TArray<TMorphTarget>; out AVertexFrames: TArray<TVertexFrameSequence>): TArray<TMeshParticlePoint>;
var
  Reader: TStreamReader;
  Line, GroupName, RawTok, Tok: string;
  Parts, Corners: TArray<string>;
  FS: TFormatSettings;
  Verts, Norms, FaceNormAcc: TList<TPoint3D>;
  Points: TList<TMeshParticlePoint>;
  PointVertIdx: TList<Integer>;
  MeshNameList: TList<string>;
  Faces: TList<TArray<Integer>>;
  SkipCurrent: Boolean;
  Pt: TMeshParticlePoint;
  VIdx, FIdx, Tri, Corner, Vi, RawVi, V0, V1, V2, VertIdx: Integer;
  A, B, C, N: TPoint3D;
  L: Single;
  HasNormals, UseDirectNormals: Boolean;
  IntCorners: TArray<Integer>;
begin
  Result := nil;
  AMorphTargets := nil;   { Wavefront .obj has no blend shapes; morphing is
                             driven from the renderer side for OBJ sources. }
  AVertexFrames := nil;
  FS := TFormatSettings.Invariant;
  Verts := TList<TPoint3D>.Create;
  Norms := TList<TPoint3D>.Create;
  FaceNormAcc := TList<TPoint3D>.Create;
  Points := TList<TMeshParticlePoint>.Create;
  PointVertIdx := TList<Integer>.Create;
  MeshNameList := TList<string>.Create;
  Faces := TList<TArray<Integer>>.Create;
  Reader := TStreamReader.Create(AFileName, TEncoding.UTF8, True, 65536);
  try
    SkipCurrent := False;
    GroupName := '';
    while not Reader.EndOfStream do
    begin
      Line := Reader.ReadLine.Trim;
      if (Line = '') or (Line[1] = '#') then
        Continue;

      if Line.StartsWith('o ') or Line.StartsWith('g ') or Line.StartsWith('usemtl ') then
      begin
        { New object / group / material switches the active name and the
          exclude filter. Each distinct name gets its own mesh index so body
          part detection can use it. }
        GroupName := Line.Substring(Line.IndexOf(' ') + 1).Trim;
        SkipCurrent := IsExcluded(GroupName, AOptions.ExcludeKeywords);
        if (not SkipCurrent) and (GroupName <> '') then
          if (MeshNameList.Count = 0) or (MeshNameList.Last <> GroupName) then
            MeshNameList.Add(GroupName);
      end
      else if Line.StartsWith('v ') then
      begin
        Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
        if Length(Parts) >= 4 then
        begin
          Verts.Add(TPoint3D.Create(StrToFloatDef(Parts[1], 0, FS), StrToFloatDef(Parts[2], 0, FS), StrToFloatDef(Parts[3], 0, FS)));
          FaceNormAcc.Add(TPoint3D.Create(0, 0, 0));
          if not SkipCurrent then
          begin
            Pt.Position := Verts.Last;
            Pt.Normal := TPoint3D.Create(0, 0, 1);
            Pt.Color := $FFFFFFFF;
            if MeshNameList.Count = 0 then
              Pt.GroupTag := 0
            else
              Pt.GroupTag := Cardinal(MeshNameList.Count - 1);
            Pt.BodyPart := bpUnknown;
            Points.Add(Pt);
            PointVertIdx.Add(Verts.Count - 1);
          end;
        end;
      end
      else if Line.StartsWith('vn ') then
      begin
        Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
        if Length(Parts) >= 4 then
          Norms.Add(TPoint3D.Create(StrToFloatDef(Parts[1], 0, FS), StrToFloatDef(Parts[2], 0, FS), StrToFloatDef(Parts[3], 1, FS)));
      end
      else if Line.StartsWith('f ') then
      begin
        { Parse face corners. Each corner may be v, v/vt or v/vt/vn or v//vn.
          Negative indices are relative to the current vertex count. Only the
          vertex index is needed for normal recompute. }
        Parts := Line.Split([' ', #9], TStringSplitOptions.ExcludeEmpty);
        if Length(Parts) < 4 then
          Continue;
        SetLength(IntCorners, Length(Parts) - 1);
        Corner := 0;
        for VIdx := 1 to High(Parts) do
        begin
          RawTok := Parts[VIdx];
          Vi := Pos('/', RawTok);
          if Vi > 0 then
            Tok := Copy(RawTok, 1, Vi - 1)
          else
            Tok := RawTok;
          RawVi := StrToIntDef(Tok, 0);
          if RawVi = 0 then
            Continue;
          if RawVi < 0 then
            Vi := Verts.Count + RawVi
          else
            Vi := RawVi - 1;
          if (Vi >= 0) and (Vi < Verts.Count) then
          begin
            IntCorners[Corner] := Vi;
            Inc(Corner);
          end;
        end;
        if Corner >= 3 then
        begin
          SetLength(IntCorners, Corner);
          Faces.Add(IntCorners);
        end;
      end;
    end;

    HasNormals := Norms.Count > 0;
    UseDirectNormals := HasNormals and (Norms.Count = Verts.Count) and (not AOptions.RecomputeNormals);

    if not UseDirectNormals then
    begin
      { Accumulate face normals into per-vertex buckets (fan triangulation
        around the first corner) and normalize. Gives smooth normals for rim
        light when the .obj lacks them or when recompute is requested. }
      for FIdx := 0 to Faces.Count - 1 do
      begin
        if Length(Faces[FIdx]) < 3 then
          Continue;
        for Tri := 1 to Length(Faces[FIdx]) - 2 do
        begin
          V0 := Faces[FIdx][0];
          V1 := Faces[FIdx][Tri];
          V2 := Faces[FIdx][Tri + 1];
          A := Verts[V1] - Verts[V0];
          B := Verts[V2] - Verts[V0];
          C := A.CrossProduct(B);
          L := Vec3Len(C);
          if L > 0.00001 then
          begin
            C := TPoint3D.Create(C.X / L, C.Y / L, C.Z / L);
            N := FaceNormAcc[V0];
            FaceNormAcc[V0] := TPoint3D.Create(N.X + C.X, N.Y + C.Y, N.Z + C.Z);
            N := FaceNormAcc[V1];
            FaceNormAcc[V1] := TPoint3D.Create(N.X + C.X, N.Y + C.Y, N.Z + C.Z);
            N := FaceNormAcc[V2];
            FaceNormAcc[V2] := TPoint3D.Create(N.X + C.X, N.Y + C.Y, N.Z + C.Z);
          end;
        end;
      end;
      for VIdx := 0 to FaceNormAcc.Count - 1 do
      begin
        N := FaceNormAcc[VIdx];
        L := Vec3Len(N);
        if L > 0.00001 then
          FaceNormAcc[VIdx] := TPoint3D.Create(N.X / L, N.Y / L, N.Z / L)
        else
          FaceNormAcc[VIdx] := TPoint3D.Create(0, 0, 1);
      end;
    end;

    { Assign the chosen normal to every emitted point via its source vertex. }
    for VIdx := 0 to Points.Count - 1 do
    begin
      Pt := Points[VIdx];
      VertIdx := PointVertIdx[VIdx];
      if UseDirectNormals then
        Pt.Normal := Norms[VertIdx]
      else
        Pt.Normal := FaceNormAcc[VertIdx];
      Points[VIdx] := Pt;
    end;

    Result := Points.ToArray;
    AMeshNames := MeshNameList.ToArray;
  finally
    Reader.Free;
    Points.Free;
    Norms.Free;
    Verts.Free;
    FaceNormAcc.Free;
    PointVertIdx.Free;
    MeshNameList.Free;
    Faces.Free;
  end;
end;

class function TYutaniMeshLoader.LoadGLB(const AFileName: string; const AOptions: TMeshLoadOptions; out AMeshNames: TArray<string>; out AMorphTargets: TArray<TMorphTarget>; out AVertexFrames: TArray<TVertexFrameSequence>): TArray<TMeshParticlePoint>;
var
  MS: TMemoryStream;
  Magic, Version, TotalLen, ChunkLen, ChunkType: Cardinal;
  JsonBytes: TBytes;
  JsonStr: string;
  Root, MeshObj, PrimObj, AttrObj, Extras, AnimObj, ChanObj, TgtObj, SamplerObj, NodeObj, SceneObj: TJSONObject;
  MeshesArr, PrimsArr, AccArr, BVArr, AnimsArr, ChansArr, SamplersArr, NodesArr, TNArr, TargetsArr, ScenesArr, RootNodesArr: TJSONArray;
  BinStart: Int64;
  MIdx, PIdx, TIdx, PosAccIdx, NormAccIdx, IdxAccIdx, AccIdx, FIdx, FrameIdx, TgtIdx, SceneIdx, RootNodeIdx: Integer;
  V: TJSONValue;
  NameDump: TStringList;
  MeshName: string;
  IdxList: TArray<Integer>;
  Points: TList<TMeshParticlePoint>;
  PrimRecords: TList<TPrimRecord>;
  MeshNameList: TList<string>;
  MeshTargetNames: TList<TArray<string>>;
  PrimRec: TPrimRecord;
  Pt: TMeshParticlePoint;
  PosList, NormList: TArray<TPoint3D>;
  ThisTargetNames: TArray<string>;
  WeightsFlat, Times: TArray<Single>;
  NumTargets, FrameCount: Integer;
  Seq: TVertexFrameSequence;
  BaseStart: Integer;

  function ReadVec3Accessor(AAccIndex: Integer; out AVecs: TArray<TPoint3D>): Boolean;
  var
    Acc, BV: TJSONObject;
    BVIndex, Count, ByteOffset, Stride, ComponentType, I: Integer;
    ReadPos: Int64;
    X, Y, Z: Single;
  begin
    Result := False;
    AVecs := nil;
    if (AAccIndex < 0) or (AccArr = nil) or (AAccIndex >= AccArr.Count) then
      Exit;
    Acc := JObj(AccArr.Items[AAccIndex]);
    ComponentType := JInt(Acc, 'componentType', 0);
    if ComponentType <> 5126 then   // 5126 = FLOAT (32-bit)
      Exit;
    Count := JInt(Acc, 'count', 0);
    BVIndex := JInt(Acc, 'bufferView', -1);
    if (Count <= 0) or (BVIndex < 0) or (BVArr = nil) or (BVIndex >= BVArr.Count) then
      Exit;
    BV := JObj(BVArr.Items[BVIndex]);
    ByteOffset := JInt(BV, 'byteOffset', 0) + JInt(Acc, 'byteOffset', 0);
    Stride := JInt(BV, 'byteStride', 12);
    if Stride < 12 then
      Stride := 12;
    SetLength(AVecs, Count);
    for I := 0 to Count - 1 do
    begin
      ReadPos := BinStart + ByteOffset + Int64(I) * Stride;
      if ReadPos + 12 > MS.Size then
        Break;
      MS.Position := ReadPos;
      MS.ReadBuffer(X, 4);
      MS.ReadBuffer(Y, 4);
      MS.ReadBuffer(Z, 4);
      AVecs[I] := TPoint3D.Create(X, Y, Z);
    end;
    Result := Length(AVecs) > 0;
  end;

  function ReadFloatAccessor(AAccIndex: Integer; out AVals: TArray<Single>): Boolean;
  var
    Acc, BV: TJSONObject;
    BVIndex, Count, ByteOffset, Stride, ComponentType, I: Integer;
    ReadPos: Int64;
    V: Single;
  begin
    Result := False;
    AVals := nil;
    if (AAccIndex < 0) or (AccArr = nil) or (AAccIndex >= AccArr.Count) then
      Exit;
    Acc := JObj(AccArr.Items[AAccIndex]);
    ComponentType := JInt(Acc, 'componentType', 0);
    if ComponentType <> 5126 then
      Exit;
    Count := JInt(Acc, 'count', 0);
    BVIndex := JInt(Acc, 'bufferView', -1);
    if (Count <= 0) or (BVIndex < 0) or (BVArr = nil) or (BVIndex >= BVArr.Count) then
      Exit;
    BV := JObj(BVArr.Items[BVIndex]);
    ByteOffset := JInt(BV, 'byteOffset', 0) + JInt(Acc, 'byteOffset', 0);
    Stride := JInt(BV, 'byteStride', 4);
    if Stride < 4 then
      Stride := 4;
    SetLength(AVals, Count);
    for I := 0 to Count - 1 do
    begin
      ReadPos := BinStart + ByteOffset + Int64(I) * Stride;
      if ReadPos + 4 > MS.Size then
        Break;
      MS.Position := ReadPos;
      MS.ReadBuffer(V, 4);
      AVals[I] := V;
    end;
    Result := Length(AVals) > 0;
  end;

  function ReadIndices(AAccIndex: Integer; out AIdx: TArray<Integer>): Boolean;
  var
    Acc, BV: TJSONObject;
    BVIndex, Count, ByteOffset, ComponentType, I: Integer;
    ReadPos: Int64;
    U8: Byte;
    U16: Word;
    U32: Cardinal;
  begin
    Result := False;
    AIdx := nil;
    if (AAccIndex < 0) or (AccArr = nil) or (AAccIndex >= AccArr.Count) then
      Exit;
    Acc := JObj(AccArr.Items[AAccIndex]);
    ComponentType := JInt(Acc, 'componentType', 0);
    Count := JInt(Acc, 'count', 0);
    BVIndex := JInt(Acc, 'bufferView', -1);
    if (Count <= 0) or (BVIndex < 0) or (BVArr = nil) or (BVIndex >= BVArr.Count) then
      Exit;
    BV := JObj(BVArr.Items[BVIndex]);
    ByteOffset := JInt(BV, 'byteOffset', 0) + JInt(Acc, 'byteOffset', 0);
    SetLength(AIdx, Count);
    for I := 0 to Count - 1 do
    begin
      case ComponentType of
        5121:
          begin
            ReadPos := BinStart + ByteOffset + Int64(I);
            MS.Position := ReadPos;
            MS.ReadBuffer(U8, 1);
            AIdx[I] := U8;
          end;
        5123:
          begin
            ReadPos := BinStart + ByteOffset + Int64(I) * 2;
            MS.Position := ReadPos;
            MS.ReadBuffer(U16, 2);
            AIdx[I] := U16;
          end;
        5125:
          begin
            ReadPos := BinStart + ByteOffset + Int64(I) * 4;
            MS.Position := ReadPos;
            MS.ReadBuffer(U32, 4);
            AIdx[I] := U32;
          end;
      else
        Exit;
      end;
      if ReadPos >= MS.Size then
        Break;
    end;
    Result := Length(AIdx) > 0;
  end;

  procedure RecomputeNormals(const APos: TArray<TPoint3D>; const AIdx: TArray<Integer>; out ANorm: TArray<TPoint3D>);
  var
    I, J, TriCount, I0, I1, I2: Integer;
    A, B, C, N: TPoint3D;
    L: Single;
    Acc: TArray<TPoint3D>;
  begin
    SetLength(ANorm, Length(APos));
    SetLength(Acc, Length(APos));
    for I := 0 to High(Acc) do
      Acc[I] := TPoint3D.Create(0, 0, 0);
    TriCount := Length(AIdx) div 3;
    for I := 0 to TriCount - 1 do
    begin
      I0 := AIdx[I * 3];
      I1 := AIdx[I * 3 + 1];
      I2 := AIdx[I * 3 + 2];
      if (I0 < 0) or (I0 > High(APos)) or (I1 < 0) or (I1 > High(APos)) or (I2 < 0) or (I2 > High(APos)) then
        Continue;
      A := APos[I1] - APos[I0];
      B := APos[I2] - APos[I0];
      C := A.CrossProduct(B);
      L := Vec3Len(C);
      if L > 0.00001 then
        C := TPoint3D.Create(C.X / L, C.Y / L, C.Z / L)
      else
        Continue;
      N := Acc[I0];
      Acc[I0] := TPoint3D.Create(N.X + C.X, N.Y + C.Y, N.Z + C.Z);
      N := Acc[I1];
      Acc[I1] := TPoint3D.Create(N.X + C.X, N.Y + C.Y, N.Z + C.Z);
      N := Acc[I2];
      Acc[I2] := TPoint3D.Create(N.X + C.X, N.Y + C.Y, N.Z + C.Z);
    end;
    for I := 0 to High(Acc) do
    begin
      N := Acc[I];
      L := Vec3Len(N);
      if L > 0.00001 then
        ANorm[I] := TPoint3D.Create(N.X / L, N.Y / L, N.Z / L)
      else
        ANorm[I] := TPoint3D.Create(0, 0, 1);
    end;
  end;

  procedure CollectTargetNames(AMesh: TJSONObject; out ANames: TArray<string>);
  var
    Arr: TJSONArray;
    I: Integer;
    TN: TJSONArray;
    TName: string;
  begin
    ANames := nil;
    Extras := JObj(AMesh.FindValue('extras'));
    if Extras <> nil then
    begin
      Arr := JArr(Extras.FindValue('targetNames'));
      if (Arr <> nil) and (Arr.Count > 0) then
      begin
        SetLength(ANames, Arr.Count);
        for I := 0 to Arr.Count - 1 do
          ANames[I] := (Arr.Items[I] as TJSONString).Value;
        Exit;
      end;
    end;
    { No targetNames supplied: synthesize neutral names so weights still map. }
    if (PrimsArr <> nil) and (PrimsArr.Count > 0) then
    begin
      PrimObj := JObj(PrimsArr.Items[0]);
      TargetsArr := JArr(PrimObj.FindValue('targets'));
      if (TargetsArr <> nil) and (TargetsArr.Count > 0) then
      begin
        SetLength(ANames, TargetsArr.Count);
        for I := 0 to High(ANames) do
          ANames[I] := 'target_' + IntToStr(I);
      end;
    end;
  end;

  { Emit one mesh's primitives into the point cloud, transforming every
    POSITION by the accumulated world matrix and every NORMAL by its 3x3
    rotation part. Morph deltas are transformed by the linear part so they
    stay consistent with the world-space base points. The node name and the
    mesh name are both checked against ExcludeKeywords. Shared by the scene
    traversal and the node-less fallback. }
  procedure EmitMesh(AMeshIdx: Integer; const AWorld: TMat4; const ANodeName: string);
  var
    LMeshObj: TJSONObject;
    LPrims: TJSONArray;
    LPIdx, LPosAcc, LNormAcc, LIdxAcc, LTgt, LDIdx: Integer;
    LPrim, LAttr, LTgtAttr: TJSONObject;
    LTargets: TJSONArray;
    LPos, LNorm: TArray<TPoint3D>;
    LIdxList: TArray<Integer>;
    LRec: TPrimRecord;
    LPt: TMeshParticlePoint;
    LBase: Integer;
    LMeshName: string;
  begin
    if (AMeshIdx < 0) or (MeshesArr = nil) or (AMeshIdx >= MeshesArr.Count) then
      Exit;
    LMeshObj := JObj(MeshesArr.Items[AMeshIdx]);
    if LMeshObj = nil then
      Exit;
    if AMeshIdx < MeshNameList.Count then
      LMeshName := MeshNameList[AMeshIdx]
    else
      LMeshName := '';
    if IsExcluded(ANodeName, AOptions.ExcludeKeywords) or IsExcluded(LMeshName, AOptions.ExcludeKeywords) then
      Exit;
    LPrims := JArr(LMeshObj.FindValue('primitives'));
    if LPrims = nil then
      Exit;
    for LPIdx := 0 to LPrims.Count - 1 do
    begin
      LPrim := JObj(LPrims.Items[LPIdx]);
      LAttr := JObj(LPrim.FindValue('attributes'));
      if LAttr = nil then
        Continue;
      LPosAcc := JInt(LAttr, 'POSITION', -1);
      if LPosAcc < 0 then
        Continue;
      if not ReadVec3Accessor(LPosAcc, LPos) then
        Continue;
      LNormAcc := JInt(LAttr, 'NORMAL', -1);
      ReadVec3Accessor(LNormAcc, LNorm);
      if (Length(LNorm) = 0) and AOptions.RecomputeNormals then
      begin
        LIdxAcc := JInt(LPrim, 'indices', -1);
        if ReadIndices(LIdxAcc, LIdxList) and (Length(LIdxList) >= 3) then
          RecomputeNormals(LPos, LIdxList, LNorm);
      end;
      if Length(LNorm) = 0 then
      begin
        SetLength(LNorm, Length(LPos));
        for LTgt := 0 to High(LNorm) do
          LNorm[LTgt] := TPoint3D.Create(0, 0, 1);
      end;

      LBase := Points.Count;
      LRec.BaseStart := LBase;
      LRec.Count := Length(LPos);
      LRec.TargetDeltas := nil;
      LRec.TargetNormDeltas := nil;

      for LTgt := 0 to High(LPos) do
      begin
        LPt.Position := TransformPoint(AWorld, LPos[LTgt]);
        if LTgt <= High(LNorm) then
          LPt.Normal := TransformNormal(AWorld, LNorm[LTgt])
        else
          LPt.Normal := TPoint3D.Create(0, 0, 1);
        LPt.Color := $FFFFFFFF;
        LPt.GroupTag := Cardinal(AMeshIdx);
        LPt.BodyPart := bpUnknown;
        Points.Add(LPt);
      end;

      if AOptions.LoadMorphTargets then
      begin
        LTargets := JArr(LPrim.FindValue('targets'));
        if (LTargets <> nil) and (LTargets.Count > 0) then
        begin
          SetLength(LRec.TargetDeltas, LTargets.Count);
          SetLength(LRec.TargetNormDeltas, LTargets.Count);
          for LTgt := 0 to LTargets.Count - 1 do
          begin
            LTgtAttr := JObj(LTargets.Items[LTgt]);
            LPosAcc := JInt(LTgtAttr, 'POSITION', -1);
            LNormAcc := JInt(LTgtAttr, 'NORMAL', -1);
            ReadVec3Accessor(LPosAcc, LRec.TargetDeltas[LTgt]);
            ReadVec3Accessor(LNormAcc, LRec.TargetNormDeltas[LTgt]);
            if Length(LRec.TargetDeltas[LTgt]) < LRec.Count then
            begin
              SetLength(LRec.TargetDeltas[LTgt], LRec.Count);
              SetLength(LRec.TargetNormDeltas[LTgt], LRec.Count);
            end;
            for LDIdx := 0 to High(LRec.TargetDeltas[LTgt]) do
            begin
              LRec.TargetDeltas[LTgt][LDIdx] := TransformVec3Linear(AWorld, LRec.TargetDeltas[LTgt][LDIdx]);
              if LDIdx <= High(LRec.TargetNormDeltas[LTgt]) then
                LRec.TargetNormDeltas[LTgt][LDIdx] := TransformNormal(AWorld, LRec.TargetNormDeltas[LTgt][LDIdx]);
            end;
          end;
        end;
      end;

      PrimRecords.Add(LRec);
    end;
  end;

  { Recursively traverse a node: build the local matrix from "matrix" or TRS,
    accumulate parent * local into the world matrix, emit any referenced mesh,
    then descend into children. }
  procedure TraverseNode(ANodeIdx: Integer; const AParent: TMat4);
  var
    LNode: TJSONObject;
    LLocal, LWorld: TMat4;
    LChildren: TJSONArray;
    LMat, LT, LR, LS: TArray<Single>;
    LTrans, LScale: TPoint3D;
    LName: string;
    LMeshIdx, LI, LC: Integer;
    LV: TJSONValue;
  begin
    if (ANodeIdx < 0) or (NodesArr = nil) or (ANodeIdx >= NodesArr.Count) then
      Exit;
    LNode := JObj(NodesArr.Items[ANodeIdx]);
    if LNode = nil then
      Exit;
    LName := JStr(LNode, 'name', '');

    LMat := JFloatArr(LNode, 'matrix');
    if Length(LMat) >= 16 then
      LLocal := Mat4FromMatrix16(LMat)
    else
    begin
      LT := JFloatArr(LNode, 'translation');
      if Length(LT) >= 3 then
        LTrans := TPoint3D.Create(LT[0], LT[1], LT[2])
      else
        LTrans := TPoint3D.Create(0, 0, 0);
      LR := JFloatArr(LNode, 'rotation');
      if Length(LR) < 4 then
      begin
        SetLength(LR, 4);
        LR[0] := 0;
        LR[1] := 0;
        LR[2] := 0;
        LR[3] := 1;
      end;
      LS := JFloatArr(LNode, 'scale');
      if Length(LS) >= 3 then
        LScale := TPoint3D.Create(LS[0], LS[1], LS[2])
      else
        LScale := TPoint3D.Create(1, 1, 1);
      LLocal := Mat4FromTRS(LTrans, LR[0], LR[1], LR[2], LR[3], LScale);
    end;

    Mat4Multiply(AParent, LLocal, LWorld);

    LMeshIdx := JInt(LNode, 'mesh', -1);
    if LMeshIdx >= 0 then
      EmitMesh(LMeshIdx, LWorld, LName);

    LChildren := JArr(LNode.FindValue('children'));
    if LChildren <> nil then
      for LI := 0 to LChildren.Count - 1 do
      begin
        LV := LChildren.Items[LI];
        LC := JNum(LV, -1);
        if LC >= 0 then
          TraverseNode(LC, LWorld);
      end;
  end;

begin
  Result := nil;
  AMorphTargets := nil;
  AVertexFrames := nil;
  AMeshNames := nil;
  MS := TMemoryStream.Create;
  Points := TList<TMeshParticlePoint>.Create;
  PrimRecords := TList<TPrimRecord>.Create;
  MeshNameList := TList<string>.Create;
  MeshTargetNames := TList<TArray<string>>.Create;
  NameDump := TStringList.Create;
  try
    MS.LoadFromFile(AFileName);
    if MS.Size < 20 then
      Exit;
    MS.ReadBuffer(Magic, 4);
    MS.ReadBuffer(Version, 4);
    MS.ReadBuffer(TotalLen, 4);
    if (Magic <> $46546C67) or (Version <> 2) then   // 'glTF' v2
      Exit;

    { Chunk 0: JSON header. }
    MS.ReadBuffer(ChunkLen, 4);
    MS.ReadBuffer(ChunkType, 4);
    if ChunkType <> $4E4F534A then   // 'JSON'
      Exit;
    SetLength(JsonBytes, ChunkLen);
    MS.ReadBuffer(JsonBytes[0], ChunkLen);
    JsonStr := TEncoding.UTF8.GetString(JsonBytes);

    { Chunk 1: BIN body. }
    if MS.Position + 8 > MS.Size then
      Exit;
    MS.ReadBuffer(ChunkLen, 4);
    MS.ReadBuffer(ChunkType, 4);
    if ChunkType <> $004E4942 then   // 'BIN\0'
      Exit;
    BinStart := MS.Position;

    Root := TJSONObject.ParseJSONValue(JsonStr) as TJSONObject;
    if Root = nil then
      Exit;
    try
      MeshesArr := JArr(Root.FindValue('meshes'));
      AccArr := JArr(Root.FindValue('accessors'));
      BVArr := JArr(Root.FindValue('bufferViews'));
      if (MeshesArr = nil) or (AccArr = nil) or (BVArr = nil) then
        Exit;

      { Pre-pass: register every mesh's name and morph-target names, indexed by
        mesh index. The vertex-frame resolver below and the MeshNames output
        both index by mesh index, so this covers all meshes even when the
        scene graph references them out of order or not at all. }
      for MIdx := 0 to MeshesArr.Count - 1 do
      begin
        MeshObj := JObj(MeshesArr.Items[MIdx]);
        MeshName := JStr(MeshObj, 'name', '');
        MeshNameList.Add(MeshName);
        PrimsArr := JArr(MeshObj.FindValue('primitives'));
        CollectTargetNames(MeshObj, ThisTargetNames);
        MeshTargetNames.Add(ThisTargetNames);
        NameDump.Add(Format('%3d  %-30s  targets=%d', [MIdx, MeshName, Length(ThisTargetNames)]));
        if (Length(AMorphTargets) = 0) and (Length(ThisTargetNames) > 0) then
        begin
          SetLength(AMorphTargets, Length(ThisTargetNames));
          for TIdx := 0 to High(AMorphTargets) do
            AMorphTargets[TIdx].Name := ThisTargetNames[TIdx];
        end;
      end;

      { Traverse the glTF scene graph so per-node Translation / Rotation / Scale
        (or a baked matrix) accumulates down the tree and is applied to every
        vertex and normal. Falls back to flat mesh iteration when the file has
        no nodes array (some minimal exporters omit the scene graph). }
      NodesArr := JArr(Root.FindValue('nodes'));
      ScenesArr := JArr(Root.FindValue('scenes'));
      if (NodesArr <> nil) and (NodesArr.Count > 0) then
      begin
        SceneIdx := JInt(Root, 'scene', 0);
        if (ScenesArr <> nil) and (SceneIdx >= 0) and (SceneIdx < ScenesArr.Count) then
        begin
          SceneObj := JObj(ScenesArr.Items[SceneIdx]);
          RootNodesArr := JArr(SceneObj.FindValue('nodes'));
          if RootNodesArr <> nil then
            for RootNodeIdx := 0 to RootNodesArr.Count - 1 do
            begin
              V := RootNodesArr.Items[RootNodeIdx];
              TraverseNode(JNum(V, -1), Mat4Identity);
            end;
        end
        else
          { No scenes entry: treat every top-level node as a root. }
          for RootNodeIdx := 0 to NodesArr.Count - 1 do
            TraverseNode(RootNodeIdx, Mat4Identity);
      end
      else
      begin
        { No node graph: emit each mesh at identity so the loader still works. }
        for MIdx := 0 to MeshesArr.Count - 1 do
          EmitMesh(MIdx, Mat4Identity, '');
      end;

      { Scatter per-primitive morph deltas into parallel arrays sized to the
        full point cloud. Zero-filled so non-morphed points stay put. }
      if Length(AMorphTargets) > 0 then
      begin
        for TIdx := 0 to High(AMorphTargets) do
        begin
          SetLength(AMorphTargets[TIdx].PositionDeltas, Points.Count);
          SetLength(AMorphTargets[TIdx].NormalDeltas, Points.Count);
          for PIdx := 0 to Points.Count - 1 do
          begin
            AMorphTargets[TIdx].PositionDeltas[PIdx] := TPoint3D.Create(0, 0, 0);
            AMorphTargets[TIdx].NormalDeltas[PIdx] := TPoint3D.Create(0, 0, 0);
          end;
        end;
        for PIdx := 0 to PrimRecords.Count - 1 do
        begin
          PrimRec := PrimRecords[PIdx];
          for TIdx := 0 to High(PrimRec.TargetDeltas) do
          begin
            if TIdx > High(AMorphTargets) then
              Break;
            for FIdx := 0 to PrimRec.Count - 1 do
            begin
              if (PrimRec.BaseStart + FIdx) > High(AMorphTargets[TIdx].PositionDeltas) then
                Break;
              AMorphTargets[TIdx].PositionDeltas[PrimRec.BaseStart + FIdx] := PrimRec.TargetDeltas[TIdx][FIdx];
              if FIdx <= High(PrimRec.TargetNormDeltas[TIdx]) then
                AMorphTargets[TIdx].NormalDeltas[PrimRec.BaseStart + FIdx] := PrimRec.TargetNormDeltas[TIdx][FIdx];
            end;
          end;
        end;
      end;

      { Vertex frame sequences from morph-weight animation channels. Each
        channel animates a node's mesh weights; output is interleaved as
        [frame0_t0, frame0_t1, ..., frame1_t0, ...]. }
      if AOptions.LoadVertexFrames and (Length(AMorphTargets) > 0) then
      begin
        AnimsArr := JArr(Root.FindValue('animations'));
        NodesArr := JArr(Root.FindValue('nodes'));
        if AnimsArr <> nil then
          for MIdx := 0 to AnimsArr.Count - 1 do
          begin
            AnimObj := JObj(AnimsArr.Items[MIdx]);
            ChansArr := JArr(AnimObj.FindValue('channels'));
            SamplersArr := JArr(AnimObj.FindValue('samplers'));
            if (ChansArr = nil) or (SamplersArr = nil) then
              Continue;
            for PIdx := 0 to ChansArr.Count - 1 do
            begin
              ChanObj := JObj(ChansArr.Items[PIdx]);
              TgtObj := JObj(ChanObj.FindValue('target'));
              if TgtObj = nil then
                Continue;
              if JStr(TgtObj, 'path', '') <> 'weights' then
                Continue;
              TIdx := JInt(TgtObj, 'node', -1);
              if (TIdx < 0) or (NodesArr = nil) or (TIdx >= NodesArr.Count) then
                Continue;
              NodeObj := JObj(NodesArr.Items[TIdx]);
              FIdx := JInt(NodeObj, 'mesh', -1);
              if (FIdx < 0) or (FIdx >= MeshTargetNames.Count) then
                Continue;
              ThisTargetNames := MeshTargetNames[FIdx];
              NumTargets := Length(ThisTargetNames);
              if NumTargets = 0 then
                Continue;
              TIdx := JInt(ChanObj, 'sampler', -1);
              if (TIdx < 0) or (TIdx >= SamplersArr.Count) then
                Continue;
              SamplerObj := JObj(SamplersArr.Items[TIdx]);
              PosAccIdx := JInt(SamplerObj, 'input', -1);
              NormAccIdx := JInt(SamplerObj, 'output', -1);
              if not ReadFloatAccessor(PosAccIdx, Times) then
                Continue;
              if not ReadFloatAccessor(NormAccIdx, WeightsFlat) then
                Continue;
              FrameCount := Length(Times);
              if FrameCount = 0 then
                Continue;
              Seq.Name := JStr(AnimObj, 'name', 'anim_' + IntToStr(MIdx));
              Seq.TargetNames := Copy(ThisTargetNames);
              SetLength(Seq.FrameTimes, FrameCount);
              SetLength(Seq.FrameWeights, FrameCount);
              for FrameIdx := 0 to FrameCount - 1 do
              begin
                Seq.FrameTimes[FrameIdx] := Times[FrameIdx];
                SetLength(Seq.FrameWeights[FrameIdx], NumTargets);
                for TgtIdx := 0 to NumTargets - 1 do
                begin
                  AccIdx := FrameIdx * NumTargets + TgtIdx;
                  if (AccIdx >= 0) and (AccIdx <= High(WeightsFlat)) then
                    Seq.FrameWeights[FrameIdx][TgtIdx] := WeightsFlat[AccIdx]
                  else
                    Seq.FrameWeights[FrameIdx][TgtIdx] := 0;
                end;
              end;
              SetLength(AVertexFrames, Length(AVertexFrames) + 1);
              AVertexFrames[High(AVertexFrames)] := Seq;
            end;
          end;
      end;

      { Dump every mesh name + morph-target count to mesh_names.txt next to
        the exe so the exact names of the loaded model are visible for keyword
        refinement. Best-effort: a read-only exe folder must not abort the load. }
      NameDump.Insert(0, 'Yutani mesh names: ' + ExtractFileName(AFileName));
      NameDump.Insert(1, 'idx  name                            morph-targets');
      try
        NameDump.SaveToFile(ExtractFilePath(ParamStr(0)) + 'mesh_names.txt');
      except
      end;
      Result := Points.ToArray;
      AMeshNames := MeshNameList.ToArray;
    finally
      Root.Free;
    end;
  finally
    Points.Free;
    PrimRecords.Free;
    MeshNameList.Free;
    MeshTargetNames.Free;
    NameDump.Free;
    MS.Free;
  end;
end;

class function TYutaniMeshLoader.ApplyMorphTargets(const APoints: TArray<TMeshParticlePoint>; const ATargets: TArray<TMorphTarget>; const AWeights: TArray<Single>): TArray<TPoint3D>;
var
  I, T: Integer;
  W: Single;
  P, D: TPoint3D;
begin
  Result := nil;
  if Length(APoints) = 0 then
    Exit;
  SetLength(Result, Length(APoints));
  for I := 0 to High(APoints) do
    Result[I] := APoints[I].Position;
  if Length(ATargets) = 0 then
    Exit;
  for T := 0 to High(ATargets) do
  begin
    if T > High(AWeights) then
      Break;
    W := AWeights[T];
    if W = 0 then
      Continue;
    if Length(ATargets[T].PositionDeltas) <> Length(APoints) then
      Continue;
    for I := 0 to High(APoints) do
    begin
      D := ATargets[T].PositionDeltas[I];
      P := Result[I];
      Result[I] := TPoint3D.Create(P.X + D.X * W, P.Y + D.Y * W, P.Z + D.Z * W);
    end;
  end;
end;

class function TYutaniMeshLoader.SampleFrameWeights(const ASequence: TVertexFrameSequence; ATime: Single): TArray<Single>;
var
  I, Lo, Hi, NumTargets: Integer;
  F0, F1, T: Single;
begin
  Result := nil;
  NumTargets := Length(ASequence.TargetNames);
  if (Length(ASequence.FrameTimes) = 0) or (NumTargets = 0) then
    Exit;
  SetLength(Result, NumTargets);

  { Clamp before the first keyframe. }
  if ATime <= ASequence.FrameTimes[0] then
  begin
    for I := 0 to NumTargets - 1 do
      Result[I] := ASequence.FrameWeights[0][I];
    Exit;
  end;
  { Clamp after the last keyframe. }
  if ATime >= ASequence.FrameTimes[High(ASequence.FrameTimes)] then
  begin
    for I := 0 to NumTargets - 1 do
      Result[I] := ASequence.FrameWeights[High(ASequence.FrameWeights)][I];
    Exit;
  end;

  { Locate the surrounding keyframes and linearly blend. }
  Lo := 0;
  for I := 0 to High(ASequence.FrameTimes) - 1 do
    if (ATime >= ASequence.FrameTimes[I]) and (ATime < ASequence.FrameTimes[I + 1]) then
    begin
      Lo := I;
      Break;
    end;
  Hi := Lo + 1;
  F0 := ASequence.FrameTimes[Lo];
  F1 := ASequence.FrameTimes[Hi];
  if F1 - F0 <= 0.00001 then
    T := 0
  else
    T := (ATime - F0) / (F1 - F0);
  for I := 0 to NumTargets - 1 do
    Result[I] := ASequence.FrameWeights[Lo][I] * (1 - T) + ASequence.FrameWeights[Hi][I] * T;
end;

class function TYutaniMeshLoader.FindMorphTarget(const ATargets: TArray<TMorphTarget>; const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(ATargets) do
    if SameText(ATargets[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

end.

