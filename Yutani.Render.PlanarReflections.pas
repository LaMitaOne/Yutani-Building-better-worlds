unit Yutani.Render.PlanarReflections;

{==============================================================================*
 *  Yutani Render PlanarReflections v0.1
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    This component provides someday maybe a modular, real-time planar reflection system
 *    for Raylib. It renders the 3D scene from a mirrored camera perspective
 *    into a RenderTexture and provides the necessary View-Projection matrix
 *    to apply the reflection on surfaces (like Holodeck floors, water, or mirrors).
 *
 *  Architecture:
 *    - The system calculates a reflected camera position and target based on
 *      a given plane (position + normal).
 *    - It modifies the Projection Matrix using an "Oblique Near Clipping Plane"
 *      to prevent objects below the reflection plane from being rendered into
 *      the reflection texture.
 *    - The resulting texture and matrix can be bound to any GLSL shader.
 *
 *  License : Apache-2.0
 *==============================================================================}

interface

uses
  Raylib, RayMath, rlgl;

type
  { TYutaniMirrorSystem handles the reflection camera, render target, and matrix math }
  TYutaniMirrorSystem = class
  private
    FReflectionTexture: TRenderTexture2D;
    FMirrorCam: TCamera3D;
    FMirrorMatrix: TMatrix;
    FIsInitialized: Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    { Initializes the render texture with the desired resolution }
    procedure Init(TexWidth, TexHeight: Integer);

    { Begins rendering into the reflection texture. Call your scene drawing between Begin/End }
    procedure BeginReflection(UpVector: TVector3);
    procedure EndReflection;

    { Updates the internal mirror camera and reflection matrix based on the main camera }
    procedure Update(MainCam: TCamera3D; PlanePos: TVector3; PlaneNormal: TVector3);

    { Binds the reflection texture and matrix to a custom GLSL shader }
    procedure BindToShader(Shader: TShader; const TexUniformName, MatUniformName: PAnsiChar);

    { Sets the mix factor for blending reflection and surface color in the shader }
    procedure SetMixFactor(Shader: TShader; const MixUniformName: PAnsiChar; Factor: Single);

    property ReflectionTexture: TRenderTexture2D read FReflectionTexture;
    property MirrorCam: TCamera3D read FMirrorCam;
    property MirrorMatrix: TMatrix read FMirrorMatrix;
  end;

implementation

{ ==============================================================================
  LOCAL HELPER FUNCTIONS FOR VECTOR4 MATH
  Raylib-Delphi bindings often lack native Vector4DotProduct and Vector4Transform.
  We implement them here using the correct TMatrix layout (m0, m4, m8...).
  ============================================================================== }

function Vec4Dot(const v1, v2: TVector4): Single;
begin
  Result := (v1.x * v2.x) + (v1.y * v2.y) + (v1.z * v2.z) + (v1.w * v2.w);
end;

function Vec4Scale(const v: TVector4; scale: Single): TVector4;
begin
  Result.x := v.x * scale;
  Result.y := v.y * scale;
  Result.z := v.z * scale;
  Result.w := v.w * scale;
end;

function Vec4Transform(const v: TVector4; m: TMatrix): TVector4;
begin
  Result.x := (v.x * m.m0) + (v.y * m.m4) + (v.z * m.m8)  + (v.w * m.m12);
  Result.y := (v.x * m.m1) + (v.y * m.m5) + (v.z * m.m9)  + (v.w * m.m13);
  Result.z := (v.x * m.m2) + (v.y * m.m6) + (v.z * m.m10) + (v.w * m.m14);
  Result.w := (v.x * m.m3) + (v.y * m.m7) + (v.z * m.m11) + (v.w * m.m15);
end;

{ ==============================================================================
  TYutaniMirrorSystem
  ============================================================================== }

constructor TYutaniMirrorSystem.Create;
begin
  FIsInitialized := False;
  FReflectionTexture.id := 0;
end;

destructor TYutaniMirrorSystem.Destroy;
begin
  if FReflectionTexture.id > 0 then
    UnloadRenderTexture(FReflectionTexture);
  inherited;
end;

procedure TYutaniMirrorSystem.Init(TexWidth, TexHeight: Integer);
begin
  // Create the offscreen render target for the reflection
  FReflectionTexture := LoadRenderTexture(TexWidth, TexHeight);
  SetTextureFilter(FReflectionTexture.texture, TEXTURE_FILTER_TRILINEAR);

  // Default mirror camera setup
  FMirrorCam.position := Vector3Create(0, -10, 0);
  FMirrorCam.target := Vector3Create(0, 0, 0);
  FMirrorCam.up := Vector3Create(0, 1, 0);
  FMirrorCam.fovy := 45.0;
  FMirrorCam.projection := CAMERA_PERSPECTIVE;

  FIsInitialized := True;
end;

procedure TYutaniMirrorSystem.Update(MainCam: TCamera3D; PlanePos: TVector3; PlaneNormal: TVector3);
var
  Dist: Single;
  ReflectedPos, ReflectedTarget: TVector3;
  ProjMat: TMatrix;
  ClipPlane, Q, c: TVector4;
begin
  if not FIsInitialized then Exit;

  // Sync FOV with the main camera
  FMirrorCam.fovy := MainCam.fovy;

  // 1. Calculate the reflected camera position and target
  // Formula: ReflectedPos = Pos - 2 * Dot(Pos - PlanePos, Normal) * Normal
  Dist := Vector3DotProduct(Vector3Subtract(MainCam.position, PlanePos), PlaneNormal);
  ReflectedPos := Vector3Subtract(MainCam.position, Vector3Scale(PlaneNormal, 2 * Dist));

  Dist := Vector3DotProduct(Vector3Subtract(MainCam.target, PlanePos), PlaneNormal);
  ReflectedTarget := Vector3Subtract(MainCam.target, Vector3Scale(PlaneNormal, 2 * Dist));

  FMirrorCam.position := ReflectedPos;
  FMirrorCam.target := ReflectedTarget;
  FMirrorCam.up := Vector3Create(0, 1, 0); // Standard up vector

  // 2. Calculate View and Projection Matrices
  var ViewMat := GetCameraMatrix(FMirrorCam);
  ProjMat := MatrixPerspective(FMirrorCam.fovy * DEG2RAD,
                               GetScreenWidth() / GetScreenHeight(),
                               0.01, 5000.0);

  // 3. Oblique Near Clipping Plane
  // This advanced technique modifies the projection matrix so that the near plane
  // aligns with the reflection plane. This prevents geometry below the floor
  // (like underground walls) from poking through and ruining the reflection.
  ClipPlane := Vector4Create(PlaneNormal.x, PlaneNormal.y, PlaneNormal.z, -Vector3DotProduct(PlanePos, PlaneNormal));

  Q := Vec4Transform(ClipPlane, MatrixTranspose(MatrixInvert(ProjMat)));
  c := Vector4Create(ClipPlane.x, ClipPlane.y, ClipPlane.z, ClipPlane.w);
  c := Vec4Scale(c, 2.0 / Vec4Dot(ClipPlane, Q));

  // Inject the oblique clip plane into the 3rd row of the projection matrix
  // Raylib Delphi uses m8, m9, m10, m11 for the 3rd row.
  ProjMat.m8  := ProjMat.m8  + ProjMat.m12 * c.x;
  ProjMat.m9  := ProjMat.m9  + ProjMat.m12 * c.y;
  ProjMat.m10 := ProjMat.m10 + ProjMat.m12 * c.z;
  ProjMat.m11 := ProjMat.m11 + ProjMat.m12 * c.w;

  // Final Mirror View-Projection Matrix
  FMirrorMatrix := MatrixMultiply(ViewMat, ProjMat);
end;

procedure TYutaniMirrorSystem.BeginReflection(UpVector: TVector3);
begin
  if not FIsInitialized then Exit;

  BeginTextureMode(FReflectionTexture);
  ClearBackground(BLACK); // Clear to black so reflections blend cleanly with lighting

  BeginMode3D(FMirrorCam);
end;

procedure TYutaniMirrorSystem.EndReflection;
begin
  EndMode3D();
  EndTextureMode();
end;

procedure TYutaniMirrorSystem.BindToShader(Shader: TShader; const TexUniformName, MatUniformName: PAnsiChar);
var
  TexLoc, MatLoc: Integer;
begin
  if not FIsInitialized then Exit;

  TexLoc := GetShaderLocation(Shader, TexUniformName);
  if TexLoc >= 0 then
    SetShaderValueTexture(Shader, TexLoc, FReflectionTexture.texture);

  MatLoc := GetShaderLocation(Shader, MatUniformName);
  if MatLoc >= 0 then
    SetShaderValueMatrix(Shader, MatLoc, FMirrorMatrix);
end;

procedure TYutaniMirrorSystem.SetMixFactor(Shader: TShader; const MixUniformName: PAnsiChar; Factor: Single);
var
  Loc: Integer;
begin
  Loc := GetShaderLocation(Shader, MixUniformName);
  if Loc >= 0 then
    SetShaderValue(Shader, Loc, @Factor, SHADER_UNIFORM_FLOAT);
end;

end.
