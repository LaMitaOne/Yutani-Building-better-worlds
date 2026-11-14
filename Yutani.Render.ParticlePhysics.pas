{*******************************************************************************
  Yutani.Render.ParticlePhysics
********************************************************************************
  Physics-Bridge Interface for the Yutani GPU Particle Engine.

  The host (Yutani main engine, or any other game/app) implements this
  interface and hands it to TYutaniParticleEngine.SetPhysicsBridge. Every
  frame the GPU engine calls GetColliders to fetch a list of AABB colliders
  that particles should bounce off. The compute shader reads the colliders
  from the collider SSBO (binding 8) and reflects particle velocities on
  contact.

  This is the abstraction layer between the GPU particle engine and the
  host's physics world. It lets you connect ANY physics system (Jolt,
  Bullet, custom) by implementing the interface in one short adapter unit.

  Provided adapters (separate units):
    Yutani.Render.ParticlePhysics.Jolt.pas - wraps TModelEngine (Yutani.Core)
    Yutani.Render.ParticlePhysics.SDF.pas  - samples a precomputed SDF texture

  Author: Lara Miriam Tamy Reschke / LamitaOne
*******************************************************************************}

unit Yutani.Render.ParticlePhysics;

{$POINTERMATH ON}

interface

uses
  System.SysUtils, System.Classes,
  Raylib, RayMath;

type
  { TColliderAABB - axis-aligned bounding box collider for particle reflection.
    Stored as 2 vec4 records in the collider SSBO. }
  TColliderAABB = record
    Min: TVector3;
    Max: TVector3;
    Restitution: Single;   // bounce factor 0..1 (1.0 = perfect bounce, 0 = sticky)
  end;
  PColliderAABB = ^TColliderAABB;

  { IParticlePhysicsBridge - the host-side physics adapter interface.
    Implement this on your physics side; the GPU engine queries it once per
    frame to sync the collider SSBO. }
  IParticlePhysicsBridge = interface
    ['{C3F8A1E2-9D2B-4E8F-9F1C-1A2B3C4D5E6F}']
    { Called once per frame from the GPU engine's Update. The host should
      fill the provided buffer with up to MaxCount colliders and return
      the actual count written. The host is responsible for keeping the
      collider list stable across the frame (no mutation during the
      compute shader pass). }
    function GetColliders(out ABuf: PColliderAABB; MaxCount: Integer): Integer;
    { Returns the maximum number of colliders the host can provide. The
      GPU engine clamps to this. }
    function GetMaxColliders: Integer;
    { Returns a friendly name for diagnostics. }
    function GetName: string;
  end;

  { TDummyPhysicsBridge - simple in-memory collider list for offline testing.
    Lets you test particle bounce without connecting a real physics engine.
    Just add static AABBs and they're passed straight to the GPU engine. }
  TDummyPhysicsBridge = class(TInterfacedObject, IParticlePhysicsBridge)
  private
    FColliders: array of TColliderAABB;
    FName: string;
  public
    constructor Create;
    function AddCollider(const AMin, AMax: TVector3; ARestitution: Single = 0.5): Integer;
    procedure ClearColliders;
    { IParticlePhysicsBridge }
    function GetColliders(out ABuf: PColliderAABB; MaxCount: Integer): Integer;
    function GetMaxColliders: Integer;
    function GetName: string;
  end;

implementation

{ TDummyPhysicsBridge }

constructor TDummyPhysicsBridge.Create;
begin
  inherited Create;
  FName := 'DummyPhysicsBridge';
  SetLength(FColliders, 0);
end;

function TDummyPhysicsBridge.AddCollider(const AMin, AMax: TVector3;
  ARestitution: Single): Integer;
var
  N: Integer;
begin
  N := Length(FColliders);
  SetLength(FColliders, N + 1);
  FColliders[N].Min := AMin;
  FColliders[N].Max := AMax;
  FColliders[N].Restitution := ARestitution;
  Result := N;
end;

procedure TDummyPhysicsBridge.ClearColliders;
begin
  SetLength(FColliders, 0);
end;

function TDummyPhysicsBridge.GetColliders(out ABuf: PColliderAABB;
  MaxCount: Integer): Integer;
var
  N: Integer;
begin
  N := Length(FColliders);
  if N > MaxCount then N := MaxCount;
  if N > 0 then
    ABuf := @FColliders[0]
  else
    ABuf := nil;
  Result := N;
end;

function TDummyPhysicsBridge.GetMaxColliders: Integer;
begin
  // No artificial cap on the dummy bridge - the GPU engine clamps anyway.
  Result := 32;
end;

function TDummyPhysicsBridge.GetName: string;
begin
  Result := FName;
end;

end.
