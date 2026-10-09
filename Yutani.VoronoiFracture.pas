{*******************************************************************************
  Yutani.VoronoiFracture v0.2
********************************************************************************
  A pure Delphi implementation of 3D Voronoi mesh fracturing algorithms.
  Calculates structural fragmentation using Sutherland-Hodgman clipping.
  Key Features:
  - 3D Vector Math: Custom TVec3 record with inline operators for physics/math.
  - Sutherland-Hodgman Clipping: Slices convex meshes by arbitrary planes.
  - Newell's Method: Calculates robust surface normals for non-planar caps.
  - Voronoi Cell Generation: Bisects a base mesh with planes equidistant to
    neighboring seeds to produce solid convex fragments.

   Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}

unit Yutani.VoronoiFracture;

interface

uses
  System.SysUtils, System.Math, raylib, rlgl;

type
  // Lightweight 3D Vector with Delphi operator overloading
  TVec3 = record
    X, Y, Z: Single;
    class operator Add(const A, B: TVec3): TVec3;
    class operator Subtract(const A, B: TVec3): TVec3;
    class operator Multiply(const A: TVec3; S: Single): TVec3;
    function Dot(const B: TVec3): Single;
    function LengthSq: Single;
    function Length: Single;
    function Normalize: TVec3;
    function Cross(const B: TVec3): TVec3;
  end;

  TVertex = TVec3;

  TPolygon = array of TVertex;

  TPolyMesh = array of TPolygon;

  TFragment = record
    Mesh: TPolyMesh;
    Position: TVec3;
    Velocity: TVec3;
    RotationAxis: TVec3;
    Angle: Single;
    AngularVelocity: Single;
  end;

  TFragmentArray = array of TFragment;

  TPlane = record
    Normal: TVec3;
    D: Single; // Plane equation: Normal.Dot(Point) + D = 0
  end;

function FractureMesh(const BaseMesh: TPolyMesh; const Seeds: array of TVec3): TFragmentArray;

function BuildRaylibMeshFromFragment(const Frag: TFragment): TMesh;

implementation

class operator TVec3.Add(const A, B: TVec3): TVec3;
begin
  Result.X := A.X + B.X;
  Result.Y := A.Y + B.Y;
  Result.Z := A.Z + B.Z;
end;

class operator TVec3.Subtract(const A, B: TVec3): TVec3;
begin
  Result.X := A.X - B.X;
  Result.Y := A.Y - B.Y;
  Result.Z := A.Z - B.Z;
end;

class operator TVec3.Multiply(const A: TVec3; S: Single): TVec3;
begin
  Result.X := A.X * S;
  Result.Y := A.Y * S;
  Result.Z := A.Z * S;
end;

function TVec3.Dot(const B: TVec3): Single;
begin
  Result := (X * B.X) + (Y * B.Y) + (Z * B.Z);
end;

function TVec3.LengthSq: Single;
begin
  Result := Self.Dot(Self);
end;

function TVec3.Length: Single;
begin
  Result := Sqrt(LengthSq);
end;

function TVec3.Normalize: TVec3;
var
  L: Single;
begin
  L := Length;
  if L > 1e-6 then
    Result := Self * (1.0 / L)
  else
    Result := Default(TVec3);
end;

function TVec3.Cross(const B: TVec3): TVec3;
begin
  Result.X := (Y * B.Z) - (Z * B.Y);
  Result.Y := (Z * B.X) - (X * B.Z);
  Result.Z := (X * B.Y) - (Y * B.X);
end;
{ --- 3D Sutherland-Hodgman Clipping Engine --- }

// Clips a convex polygon by a single plane, tracking intersection points for cap generation

procedure ClipPolygonByPlane(const Poly: TPolygon; const Plane: TPlane; var OutputPoly: TPolygon; var OutIntersectionPoints: TPolygon);
var
  I: Integer;
  Cur, Prev: TVertex;
  DistCur, DistPrev: Single;
  IntersectionT: Single;
  Intersection: TVertex;
begin
  if Length(Poly) = 0 then
    Exit;

  for I := 0 to High(Poly) do
  begin
    Cur := Poly[I];
    Prev := Poly[(I - 1 + Length(Poly)) mod Length(Poly)];

    // Signed distance to plane
    DistCur := Cur.Dot(Plane.Normal) + Plane.D;
    DistPrev := Prev.Dot(Plane.Normal) + Plane.D;

    if DistCur >= 0 then
    begin
      // Entering the half-space: Add intersection point and current point
      if DistPrev < 0 then
      begin
        IntersectionT := DistPrev / (DistPrev - DistCur);
        Intersection := Prev + (Cur - Prev) * IntersectionT;
        SetLength(OutputPoly, Length(OutputPoly) + 1);
        OutputPoly[High(OutputPoly)] := Intersection;

        // Track intersections to build the cap later
        SetLength(OutIntersectionPoints, Length(OutIntersectionPoints) + 1);
        OutIntersectionPoints[High(OutIntersectionPoints)] := Intersection;
      end;
      SetLength(OutputPoly, Length(OutputPoly) + 1);
      OutputPoly[High(OutputPoly)] := Cur;
    end
    else if DistPrev >= 0 then
    begin
      // Leaving the half-space: Add intersection point
      IntersectionT := DistPrev / (DistPrev - DistCur);
      Intersection := Prev + (Cur - Prev) * IntersectionT;
      SetLength(OutputPoly, Length(OutputPoly) + 1);
      OutputPoly[High(OutputPoly)] := Intersection;

      SetLength(OutIntersectionPoints, Length(OutIntersectionPoints) + 1);
      OutIntersectionPoints[High(OutIntersectionPoints)] := Intersection;
    end;
  end;
end;

function CalculateCentroid(const Poly: TPolygon): TVec3;
var
  I: Integer;
begin
  Result := Default(TVec3);
  for I := 0 to High(Poly) do
    Result := Result + Poly[I];
  if Length(Poly) > 0 then
    Result := Result * (1.0 / Length(Poly));
end;
// Newell's method provides robust normals even for non-perfectly-planar polygons

function CalculateNewellsNormal(const Poly: TPolygon): TVec3;
var
  I, NextI: Integer;
  Curr, Next: TVec3;
begin
  Result := Default(TVec3);
  if Length(Poly) < 3 then
    Exit;

  for I := 0 to High(Poly) do
  begin
    NextI := (I + 1) mod Length(Poly);
    Curr := Poly[I];
    Next := Poly[NextI];

    Result.X := Result.X + (Curr.Y - Next.Y) * (Curr.Z + Next.Z);
    Result.Y := Result.Y + (Curr.Z - Next.Z) * (Curr.X + Next.X);
    Result.Z := Result.Z + (Curr.X - Next.X) * (Curr.Y + Next.Y);
  end;

  Result := Result.Normalize;
end;
// Sorts cap vertices Counter-Clockwise relative to the normal to prevent invalid triangulation

procedure SortCapPolygonCCW(var Poly: TPolygon; const Normal: TVec3);
var
  Center, Right, Up: TVec3;
  I, J: Integer;
  Temp: TVertex;
  Angles: array of Single;
  TempAngle: Single;
  V: TVec3;
  DummyUp: TVec3;
begin
  if Length(Poly) < 3 then
    Exit;

  Center := CalculateCentroid(Poly);

  // Determine an arbitrary up vector that is not parallel to the normal
  if Abs(Normal.Y) > 0.9 then
  begin
    DummyUp.X := 1.0;
    DummyUp.Y := 0.0;
    DummyUp.Z := 0.0;
  end
  else
  begin
    DummyUp.X := 0.0;
    DummyUp.Y := 1.0;
    DummyUp.Z := 0.0;
  end;

  Right := Normal.Cross(DummyUp).Normalize;
  Up := Right.Cross(Normal).Normalize;

  // Calculate angles and sort using simple BubbleSort (sizes are typically small)
  SetLength(Angles, Length(Poly));
  for I := 0 to High(Poly) do
  begin
    V := Poly[I] - Center;
    Angles[I] := ArcTan2(V.Dot(Up), V.Dot(Right));
  end;

  for I := 0 to High(Poly) - 1 do
  begin
    for J := I + 1 to High(Poly) do
    begin
      if Angles[I] > Angles[J] then
      begin
        TempAngle := Angles[I];
        Angles[I] := Angles[J];
        Angles[J] := TempAngle;

        Temp := Poly[I];
        Poly[I] := Poly[J];
        Poly[J] := Temp;
      end;
    end;
  end;
end;
// Clips an entire mesh by a plane, adding a cap polygon where intersections occurred

function ClipMeshByPlane(const Mesh: TPolyMesh; const Plane: TPlane): TPolyMesh;
var
  I: Integer;
  Clipped: TPolygon;
  Intersections: TPolygon;
  OutwardNormal: TVec3;
begin
  SetLength(Result, 0);
  SetLength(Intersections, 0);

  for I := 0 to High(Mesh) do
  begin
    Clipped := nil;
    ClipPolygonByPlane(Mesh[I], Plane, Clipped, Intersections);
    if Length(Clipped) > 2 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Clipped;
    end;
  end;

  // If intersections exist, build a cap polygon to keep the mesh solid
  if Length(Intersections) >= 3 then
  begin
    // 1. Calculate the true normal of the cap
    OutwardNormal := CalculateNewellsNormal(Intersections);
    if OutwardNormal.Dot(Plane.Normal) > 0 then
      OutwardNormal := OutwardNormal *  - 1.0; // Cap normal must face inward to the fragment

    // 2. Sort strictly CCW for correct triangle generation
    SortCapPolygonCCW(Intersections, OutwardNormal);

    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Intersections;
  end;
end;
{ --- The Voronoi Core --- }

// Generates Voronoi fragments by iteratively slicing the base mesh with bisection planes

function FractureMesh(const BaseMesh: TPolyMesh; const Seeds: array of TVec3): TFragmentArray;
var
  I, J: Integer;
  WorkingMesh: TPolyMesh;
  MidPoint, Dir: TVec3;
  ClipPlane: TPlane;
  Dist: Single;
  TempFragment: TFragment;
begin
  if (Length(Seeds) = 0) or (Length(BaseMesh) = 0) then
    Exit;

  SetLength(Result, Length(Seeds));

  // For each seed, construct a convex cell by clipping away space belonging to other seeds
  for I := 0 to High(Seeds) do
  begin
    WorkingMesh := Copy(BaseMesh);

    for J := 0 to High(Seeds) do
    begin
      if I = J then
        Continue;

      // The bisection plane is exactly halfway between seed I and seed J
      MidPoint := (Seeds[I] + Seeds[J]) * 0.5;
      Dir := Seeds[J] - Seeds[I];

      ClipPlane.Normal := Dir.Normalize;
      Dist := ClipPlane.Normal.Dot(MidPoint);
      ClipPlane.D := -Dist;

      // Slice the mesh, discarding the half that belongs to seed J
      WorkingMesh := ClipMeshByPlane(WorkingMesh, ClipPlane);

      if Length(WorkingMesh) = 0 then
        Break;
    end;

    // Assign final fragment data
    TempFragment.Mesh := WorkingMesh;
    TempFragment.Position := Default(TVec3);
    TempFragment.Velocity := Default(TVec3);
    TempFragment.RotationAxis := Default(TVec3);
    TempFragment.Angle := 0;
    TempFragment.AngularVelocity := 0;

    Result[I] := TempFragment;
  end;
end;

// Helper function to convert a Voronoi Fragment into a renderable Raylib Mesh
function BuildRaylibMeshFromFragment(const Frag: TFragment): TMesh;
var
  I, J, VCount: Integer;
  Vertices: array of Single;
  Normals: array of Single;
  TexCoords: array of Single;
  VtxCounter: Integer;
  Normal: TVec3;
  MinV, MaxV, Center: TVec3;
  Vert: TVec3;
  Poly: TPolygon;
  P0, P1, P2: TVec3;
  CrossZ: Single;
  TempVert: TVec3;
begin
  Result := Default(TMesh);
  VCount := 0;
  MinV := Default(TVec3);
  MaxV := Default(TVec3);
  var FirstVert: Boolean := True;
  // 1. Find the exact geometric bounds of the fragment
  for I := 0 to High(Frag.Mesh) do
  begin
    for J := 0 to High(Frag.Mesh[I]) do
    begin
      Vert := Frag.Mesh[I][J];
      if FirstVert then
      begin
        MinV := Vert;
        MaxV := Vert;
        FirstVert := False;
      end
      else
      begin
        if Vert.X < MinV.X then MinV.X := Vert.X;
        if Vert.Y < MinV.Y then MinV.Y := Vert.Y;
        if Vert.Z < MinV.Z then MinV.Z := Vert.Z;
        if Vert.X > MaxV.X then MaxV.X := Vert.X;
        if Vert.Y > MaxV.Y then MaxV.Y := Vert.Y;
        if Vert.Z > MaxV.Z then MaxV.Z := Vert.Z;
      end;
    end;
  end;
  if FirstVert then Exit; // No vertices found
  // Calculate the exact center of the mesh
  Center.X := (MinV.X + MaxV.X) * 0.5;
  Center.Y := (MinV.Y + MaxV.Y) * 0.5;
  Center.Z := (MinV.Z + MaxV.Z) * 0.5;
  for I := 0 to High(Frag.Mesh) do
    if Length(Frag.Mesh[I]) >= 3 then
      Inc(VCount, (Length(Frag.Mesh[I]) - 2) * 3);
  if VCount = 0 then
    Exit;
  SetLength(Vertices, VCount * 3);
  SetLength(Normals, VCount * 3);
  SetLength(TexCoords, VCount * 2);
  VtxCounter := 0;
  for I := 0 to High(Frag.Mesh) do
  begin
    if Length(Frag.Mesh[I]) >= 3 then
    begin
      // Copy polygon to ensure CCW winding
      Poly := Copy(Frag.Mesh[I]);
      // Calculate Newell's Normal first
      Normal := CalculateNewellsNormal(Poly);
      // ENSURE CCW: Check if the normal points towards the center of the fragment.
      // If it points inwards, the winding is wrong (Clockwise), so we reverse the polygon!
      var Centroid: TVec3 := Default(TVec3);
      for J := 0 to High(Poly) do Centroid := Centroid + Poly[J];
      Centroid := Centroid * (1.0 / Length(Poly));
      var ToCenter: TVec3 := Center - Centroid;
      if Normal.Dot(ToCenter) > 0 then
      begin
        // Normal points inwards! Reverse the polygon vertices
        for J := 0 to (Length(Poly) div 2) - 1 do
        begin
          TempVert := Poly[J];
          Poly[J] := Poly[High(Poly) - J];
          Poly[High(Poly) - J] := TempVert;
        end;
        // Recalculate normal after reversing
        Normal := CalculateNewellsNormal(Poly);
      end;
      for J := 1 to Length(Poly) - 2 do
      begin
        // Vertex 1 (Shifted by -Center)
        Vertices[VtxCounter*3] := Poly[0].X - Center.X;
        Vertices[VtxCounter*3+1] := Poly[0].Y - Center.Y;
        Vertices[VtxCounter*3+2] := Poly[0].Z - Center.Z;
        Normals[VtxCounter*3] := Normal.X;
        Normals[VtxCounter*3+1] := Normal.Y;
        Normals[VtxCounter*3+2] := Normal.Z;
        TexCoords[VtxCounter*2] := 0.0;
        TexCoords[VtxCounter*2+1] := 0.0;
        Inc(VtxCounter);
        // Vertex 2 (Shifted by -Center)
        Vertices[VtxCounter*3] := Poly[J].X - Center.X;
        Vertices[VtxCounter*3+1] := Poly[J].Y - Center.Y;
        Vertices[VtxCounter*3+2] := Poly[J].Z - Center.Z;
        Normals[VtxCounter*3] := Normal.X;
        Normals[VtxCounter*3+1] := Normal.Y;
        Normals[VtxCounter*3+2] := Normal.Z;
        TexCoords[VtxCounter*2] := 1.0;
        TexCoords[VtxCounter*2+1] := 0.0;
        Inc(VtxCounter);
        // Vertex 3 (Shifted by -Center)
        Vertices[VtxCounter*3] := Poly[J+1].X - Center.X;
        Vertices[VtxCounter*3+1] := Poly[J+1].Y - Center.Y;
        Vertices[VtxCounter*3+2] := Poly[J+1].Z - Center.Z;
        Normals[VtxCounter*3] := Normal.X;
        Normals[VtxCounter*3+1] := Normal.Y;
        Normals[VtxCounter*3+2] := Normal.Z;
        TexCoords[VtxCounter*2] := 1.0;
        TexCoords[VtxCounter*2+1] := 1.0;
        Inc(VtxCounter);
      end;
    end;
  end;
  Result.vertexCount := VCount;
  Result.triangleCount := VCount div 3;
  Result.vertices := @Vertices[0];
  Result.normals := @Normals[0];
  Result.texcoords := @TexCoords[0];
  UploadMesh(@Result, False);
end;

end.

