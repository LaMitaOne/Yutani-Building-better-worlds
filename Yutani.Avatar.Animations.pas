unit Yutani.Avatar.Animations;

{==============================================================================*
 *  Yutani.Avatar.Animations v0.01 - Avatar Skeleton & Animation Mixer
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    Provides a hierarchical bone skeleton, animation clip storage, and a
 *    weighted animation mixer that produces final skinning matrices ready
 *    to upload to a Raylib Model.
 *
 *  Architecture:
 *    - TSkeleton        : Holds bones (name, parent, local, global, offset).
 *    - TAnimationClip   : Holds per-bone keyframe tracks + metadata.
 *    - TAnimationState  : Per-instance playback state (time, speed, weight).
 *    - TAvatarAnimator  : Owns clips + active states, mixes and outputs
 *                         final bone matrices each frame.
 *    - TAvatarComponent : Lightweight subclass of TA3DComponent that hosts
 *                         an animator and feeds it the model's mesh data.
 *
 *  Integration:
 *    - Built on top of Yutani.Core.ModelEngine (TA3DComponent / TModelEngine).
 *    - Uses Raylib types (TModel, TMatrix, TVector3, TQuaternion).
 *    - Designed to be thread-friendly: heavy work happens in Update(dt),
 *      called from the same thread that owns the TA3DComponent (render thread).
 *==============================================================================}
{$POINTERMATH ON}
interface

uses
  System.SysUtils, System.Classes, System.Math, System.Generics.Collections,
  Raylib, RayMath, rlgl, Yutani.Core.ModelEngine;

type
  TBoneID = type Integer;

  TClipID = type Integer;

  TPosKey = record
    Time: Single;
    Value: TVector3;
  end;

  TRotKey = record
    Time: Single;
    Value: TQuaternion;
  end;

  TSclKey = record
    Time: Single;
    Value: TVector3;
  end;

  TAnimationTrack = record
    BoneName: string;
    PositionKeys: TArray<TPosKey>;
    RotationKeys: TArray<TRotKey>;
    ScaleKeys: TArray<TSclKey>;
  end;

  TBone = record
    Name: string;
    ParentID: TBoneID;
    LocalTransform: TMatrix;
    GlobalTransform: TMatrix;
    OffsetMatrix: TMatrix;
  end;

  TSkeleton = class
  private
    FNameLookup: TDictionary<string, TBoneID>;
  public
    Bones: TArray<TBone>;
    RootID: TBoneID;
    constructor Create;
    destructor Destroy; override;
    function AddBone(const AName: string; AParent: TBoneID): TBoneID;
    function FindBone(const AName: string): TBoneID;
    procedure UpdateGlobalTransforms;
    procedure ResetToBindPose;
  end;

  TAnimationClip = class
  private
    FName: string;
    FDuration: Single;
    FTicksPerSecond: Single;
    FTracks: TArray<TAnimationTrack>;
    FLoopable: Boolean;
    FHasRootMotion: Boolean;
    FRootBoneName: string;
  public
    constructor Create(const AName: string);
    destructor Destroy; override;
    property Name: string read FName write FName;
    property Duration: Single read FDuration write FDuration;
    property TicksPerSecond: Single read FTicksPerSecond write FTicksPerSecond;
    property Tracks: TArray<TAnimationTrack> read FTracks write FTracks;
    property Loopable: Boolean read FLoopable write FLoopable;
    property HasRootMotion: Boolean read FHasRootMotion write FHasRootMotion;
    property RootBoneName: string read FRootBoneName write FRootBoneName;
  end;

  TPlaybackState = (psStopped, psPlaying, psPaused);

  TAnimationState = class
  private
    FClip: TAnimationClip;
    FLocalTime: Single;
    FSpeed: Single;
    FWeight: Single;
    FTargetWeight: Single;
    FFadeRate: Single;
    FState: TPlaybackState;
    FLoop: Boolean;
    FOnComplete: TNotifyEvent;
  public
    constructor Create(AClip: TAnimationClip);
    destructor Destroy; override;
    procedure Play(ALoop: Boolean = True; ASpeed: Single = 1.0);
    procedure Pause;
    procedure Resume;
    procedure Stop;
    procedure Advance(DeltaTime: Single);
    property Clip: TAnimationClip read FClip;
    property LocalTime: Single read FLocalTime write FLocalTime;
    property Speed: Single read FSpeed write FSpeed;
    property Weight: Single read FWeight;
    property TargetWeight: Single read FTargetWeight write FTargetWeight;
    property FadeRate: Single read FFadeRate write FFadeRate;
    property State: TPlaybackState read FState;
    property Loop: Boolean read FLoop;
    property OnComplete: TNotifyEvent read FOnComplete write FOnComplete;
  end;

  TAvatarAnimator = class
  private
    FOwner: TA3DComponent;
    FSkeleton: TSkeleton;
    FClips: TObjectList<TAnimationClip>;
    FActiveStates: TObjectList<TAnimationState>;
    FFinalMatrices: TArray<TMatrix>;
    FUseRootMotion: Boolean;
    FRootMotionDelta: TVector3;
    FDirty: Boolean;
    procedure ResizeFinalMatrices;
    procedure ComputeFinalBoneTransforms(DeltaTime: Single);
    function FindState(AClip: TAnimationClip): TAnimationState;
  public
    constructor Create(AOwner: TA3DComponent);
    destructor Destroy; override;
    procedure LoadSkeletonFromModel(const AModel: TModel);
    function LoadAnimationsFromModel(const AModel: TModel): Integer;
    function AddClip(AClip: TAnimationClip): TClipID;
    function FindClip(const AName: string): TAnimationClip;
    function Play(const AClipName: string; ALoop: Boolean = True; ASpeed: Single = 1.0; AWeight: Single = 1.0): TAnimationState;
    procedure Stop(const AClipName: string);
    procedure StopAll;
    procedure CrossFade(const AFromClip, AToClip: string; Duration: Single);
    procedure Update(DeltaTime: Single);
    procedure ApplyToModel;
    property Skeleton: TSkeleton read FSkeleton;
    property Clips: TObjectList<TAnimationClip> read FClips;
    property ActiveStates: TObjectList<TAnimationState> read FActiveStates;
    property FinalMatrices: TArray<TMatrix> read FFinalMatrices;
    property UseRootMotion: Boolean read FUseRootMotion write FUseRootMotion;
    property RootMotionDelta: TVector3 read FRootMotionDelta;
    procedure ConsumeRootMotion(out Delta: TVector3);
  end;

  TAvatarComponent = class(TA3DComponent)
  private
    FAnimator: TAvatarAnimator;
  protected
    // Override Update instead of UpdateModelTransform, as UpdateModelTransform
    // is not virtual in the base class.
    procedure Update(DeltaTime: single); override;
  public
    constructor Create(AOwner: TComponent); overload; override;
    destructor Destroy; override;
    property Animator: TAvatarAnimator read FAnimator;
  end;

function FindPosKeys(const Keys: TArray<TPosKey>; ATime: Single; out K0, K1: TPosKey; out Factor: Single): Boolean; overload;

function FindRotKeys(const Keys: TArray<TRotKey>; ATime: Single; out K0, K1: TRotKey; out Factor: Single): Boolean; overload;

function FindSclKeys(const Keys: TArray<TSclKey>; ATime: Single; out K0, K1: TSclKey; out Factor: Single): Boolean; overload;

implementation

function FindPosKeys(const Keys: TArray<TPosKey>; ATime: Single; out K0, K1: TPosKey; out Factor: Single): Boolean;
var
  I: Integer;
begin
  Result := False;
  Factor := 0.0;
  if Length(Keys) = 0 then
    Exit;
  if Length(Keys) = 1 then
  begin
    K0 := Keys[0];
    K1 := Keys[0];
    Exit(True);
  end;
  for I := 0 to High(Keys) - 1 do
  begin
    if (ATime >= Keys[I].Time) and (ATime <= Keys[I + 1].Time) then
    begin
      K0 := Keys[I];
      K1 := Keys[I + 1];
      if (K1.Time - K0.Time) > 1e-6 then
        Factor := (ATime - K0.Time) / (K1.Time - K0.Time)
      else
        Factor := 0.0;
      Result := True;
      Exit;
    end;
  end;
  K0 := Keys[High(Keys)];
  K1 := K0;
  Factor := 0.0;
  Result := True;
end;

function FindRotKeys(const Keys: TArray<TRotKey>; ATime: Single; out K0, K1: TRotKey; out Factor: Single): Boolean;
var
  I: Integer;
begin
  Result := False;
  Factor := 0.0;
  if Length(Keys) = 0 then
    Exit;
  if Length(Keys) = 1 then
  begin
    K0 := Keys[0];
    K1 := Keys[0];
    Exit(True);
  end;
  for I := 0 to High(Keys) - 1 do
  begin
    if (ATime >= Keys[I].Time) and (ATime <= Keys[I + 1].Time) then
    begin
      K0 := Keys[I];
      K1 := Keys[I + 1];
      if (K1.Time - K0.Time) > 1e-6 then
        Factor := (ATime - K0.Time) / (K1.Time - K0.Time)
      else
        Factor := 0.0;
      Result := True;
      Exit;
    end;
  end;
  K0 := Keys[High(Keys)];
  K1 := K0;
  Factor := 0.0;
  Result := True;
end;

function FindSclKeys(const Keys: TArray<TSclKey>; ATime: Single; out K0, K1: TSclKey; out Factor: Single): Boolean;
var
  I: Integer;
begin
  Result := False;
  Factor := 0.0;
  if Length(Keys) = 0 then
    Exit;
  if Length(Keys) = 1 then
  begin
    K0 := Keys[0];
    K1 := Keys[0];
    Exit(True);
  end;
  for I := 0 to High(Keys) - 1 do
  begin
    if (ATime >= Keys[I].Time) and (ATime <= Keys[I + 1].Time) then
    begin
      K0 := Keys[I];
      K1 := Keys[I + 1];
      if (K1.Time - K0.Time) > 1e-6 then
        Factor := (ATime - K0.Time) / (K1.Time - K0.Time)
      else
        Factor := 0.0;
      Result := True;
      Exit;
    end;
  end;
  K0 := Keys[High(Keys)];
  K1 := K0;
  Factor := 0.0;
  Result := True;
end;
{ TSkeleton }

constructor TSkeleton.Create;
begin
  inherited Create;
  FNameLookup := TDictionary<string, TBoneID>.Create;
  RootID := -1;
end;

destructor TSkeleton.Destroy;
begin
  FNameLookup.Free;
  inherited;
end;

function TSkeleton.AddBone(const AName: string; AParent: TBoneID): TBoneID;
var
  B: TBone;
begin
  B.Name := AName;
  B.ParentID := AParent;
  B.LocalTransform := MatrixIdentity;
  B.GlobalTransform := MatrixIdentity;
  B.OffsetMatrix := MatrixIdentity;
  SetLength(Bones, Length(Bones) + 1);
  Bones[High(Bones)] := B;
  Result := High(Bones);
  FNameLookup.AddOrSetValue(AName, Result);
  if AParent = -1 then
    RootID := Result;
end;

function TSkeleton.FindBone(const AName: string): TBoneID;
begin
  if not FNameLookup.TryGetValue(AName, Result) then
    Result := -1;
end;

procedure TSkeleton.UpdateGlobalTransforms;
var
  I: Integer;
begin
  for I := 0 to High(Bones) do
  begin
    if (Bones[I].ParentID < 0) or (Bones[I].ParentID > High(Bones)) then
      Bones[I].GlobalTransform := Bones[I].LocalTransform
    else
      Bones[I].GlobalTransform := MatrixMultiply(Bones[I].LocalTransform, Bones[Bones[I].ParentID].GlobalTransform);
  end;
end;

procedure TSkeleton.ResetToBindPose;
var
  I: Integer;
begin
  for I := 0 to High(Bones) do
    Bones[I].LocalTransform := MatrixIdentity;
  UpdateGlobalTransforms;
end;
{ TAnimationClip }

constructor TAnimationClip.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FDuration := 0.0;
  FTicksPerSecond := 24.0;
  FLoopable := True;
  FHasRootMotion := False;
  FRootBoneName := '';
end;

destructor TAnimationClip.Destroy;
begin
  inherited;
end;
{ TAnimationState }

constructor TAnimationState.Create(AClip: TAnimationClip);
begin
  inherited Create;
  FClip := AClip;
  FLocalTime := 0.0;
  FSpeed := 1.0;
  FWeight := 0.0;
  FTargetWeight := 0.0;
  FFadeRate := 1.0;
  FState := psStopped;
  FLoop := True;
  FOnComplete := nil;
end;

destructor TAnimationState.Destroy;
begin
  inherited;
end;

procedure TAnimationState.Play(ALoop: Boolean; ASpeed: Single);
begin
  FLoop := ALoop;
  FSpeed := ASpeed;
  if FState = psStopped then
    FLocalTime := 0.0;
  FState := psPlaying;
end;

procedure TAnimationState.Pause;
begin
  if FState = psPlaying then
    FState := psPaused;
end;

procedure TAnimationState.Resume;
begin
  if FState = psPaused then
    FState := psPlaying;
end;

procedure TAnimationState.Stop;
begin
  FState := psStopped;
  FLocalTime := 0.0;
  FWeight := 0.0;
  FTargetWeight := 0.0;
end;

procedure TAnimationState.Advance(DeltaTime: Single);
begin
  if FState <> psPlaying then
    Exit;
  FLocalTime := FLocalTime + DeltaTime * FSpeed;
  if FClip.Duration > 0.0 then
  begin
    if FLoop then
    begin
      while FLocalTime >= FClip.Duration do
        FLocalTime := FLocalTime - FClip.Duration;
    end
    else if FLocalTime >= FClip.Duration then
    begin
      FLocalTime := FClip.Duration;
      FState := psStopped;
      if Assigned(FOnComplete) then
        FOnComplete(Self);
    end;
  end;
  if Abs(FWeight - FTargetWeight) > 1e-4 then
  begin
    if FWeight < FTargetWeight then
      FWeight := Min(FTargetWeight, FWeight + FFadeRate * DeltaTime)
    else
      FWeight := Max(FTargetWeight, FWeight - FFadeRate * DeltaTime);
  end;
end;
{ TAvatarAnimator }

constructor TAvatarAnimator.Create(AOwner: TA3DComponent);
begin
  inherited Create;
  FOwner := AOwner;
  FSkeleton := TSkeleton.Create;
  FClips := TObjectList<TAnimationClip>.Create(True);
  FActiveStates := TObjectList<TAnimationState>.Create(True);
  FFinalMatrices := nil;
  FUseRootMotion := False;
  FRootMotionDelta := Vector3Create(0, 0, 0);
  FDirty := False;
end;

destructor TAvatarAnimator.Destroy;
begin
  FActiveStates.Free;
  FClips.Free;
  FSkeleton.Free;
  inherited;
end;

procedure TAvatarAnimator.ResizeFinalMatrices;
var
  I: Integer;
begin
  SetLength(FFinalMatrices, Length(FSkeleton.Bones));
  for I := 0 to High(FFinalMatrices) do
    FFinalMatrices[I] := MatrixIdentity;
end;

procedure TAvatarAnimator.LoadSkeletonFromModel(const AModel: TModel);
begin
  // TODO: Walk AModel.meshes[].bones[] and populate FSkeleton.
  ResizeFinalMatrices;
end;

function TAvatarAnimator.LoadAnimationsFromModel(const AModel: TModel): Integer;
begin
  Result := 0;
  if AModel.meshes = nil then
    Exit;
  ResizeFinalMatrices;
end;

function TAvatarAnimator.AddClip(AClip: TAnimationClip): TClipID;
begin
  FClips.Add(AClip);
  Result := FClips.Count - 1;
end;

function TAvatarAnimator.FindClip(const AName: string): TAnimationClip;
var
  I: Integer;
begin
  for I := 0 to FClips.Count - 1 do
    if SameText(FClips[I].Name, AName) then
      Exit(FClips[I]);
  Result := nil;
end;

function TAvatarAnimator.FindState(AClip: TAnimationClip): TAnimationState;
var
  I: Integer;
begin
  for I := 0 to FActiveStates.Count - 1 do
    if FActiveStates[I].Clip = AClip then
      Exit(FActiveStates[I]);
  Result := nil;
end;

function TAvatarAnimator.Play(const AClipName: string; ALoop: Boolean; ASpeed: Single; AWeight: Single): TAnimationState;
var
  Clip: TAnimationClip;
  State: TAnimationState;
begin
  Result := nil;
  Clip := FindClip(AClipName);
  if Clip = nil then
    Exit;
  State := FindState(Clip);
  if State = nil then
  begin
    State := TAnimationState.Create(Clip);
    FActiveStates.Add(State);
  end;
  State.FadeRate := 1.0;
  State.TargetWeight := AWeight;
  State.Play(ALoop, ASpeed);
  Result := State;
end;

procedure TAvatarAnimator.Stop(const AClipName: string);
var
  Clip: TAnimationClip;
  State: TAnimationState;
  I: Integer;
begin
  Clip := FindClip(AClipName);
  if Clip = nil then
    Exit;
  State := FindState(Clip);
  if State <> nil then
  begin
    State.Stop;
    I := FActiveStates.IndexOf(State);
    if I >= 0 then
      FActiveStates.Delete(I);
  end;
end;

procedure TAvatarAnimator.StopAll;
begin
  FActiveStates.Clear;
end;

procedure TAvatarAnimator.CrossFade(const AFromClip, AToClip: string; Duration: Single);
var
  ClipFrom, ClipTo: TAnimationClip;
  StateFrom, StateTo: TAnimationState;
  Rate: Single;
begin
  ClipFrom := FindClip(AFromClip);
  ClipTo := FindClip(AToClip);
  if (ClipFrom = nil) or (ClipTo = nil) then
    Exit;
  if Duration <= 1e-4 then
    Rate := 1e6
  else
    Rate := 1.0 / Duration;
  StateFrom := FindState(ClipFrom);
  if StateFrom <> nil then
  begin
    StateFrom.FadeRate := Rate;
    StateFrom.TargetWeight := 0.0;
  end;
  StateTo := FindState(ClipTo);
  if StateTo = nil then
  begin
    StateTo := TAnimationState.Create(ClipTo);
    FActiveStates.Add(StateTo);
  end;
  StateTo.FadeRate := Rate;
  StateTo.TargetWeight := 1.0;
  StateTo.Play(True, 1.0);
end;

procedure TAvatarAnimator.ComputeFinalBoneTransforms(DeltaTime: Single);
var
  I, B: Integer;
  State: TAnimationState;
  Clip: TAnimationClip;
  Track: TAnimationTrack;
  BoneID: TBoneID;
  P0, P1: TPosKey;
  R0, R1: TRotKey;
  S0, S1: TSclKey;
  PF, RF, SF: Single;
  LocalPos: TVector3;
  LocalRot: TQuaternion;
  LocalScl: TVector3;
  LocalMat: TMatrix;
  TotalWeight: Single;
begin
  if Length(FSkeleton.Bones) = 0 then
    Exit;
  FSkeleton.ResetToBindPose;
  TotalWeight := 0.0;
  for I := 0 to FActiveStates.Count - 1 do
  begin
    State := FActiveStates[I];
    if (State.State = psStopped) or (State.Weight <= 1e-4) then
      Continue;
    Clip := State.Clip;
    TotalWeight := TotalWeight + State.Weight;
    for B := 0 to High(Clip.Tracks) do
    begin
      Track := Clip.Tracks[B];
      BoneID := FSkeleton.FindBone(Track.BoneName);
      if BoneID < 0 then
        Continue;
      LocalPos := Vector3Create(0, 0, 0);
      if FindPosKeys(Track.PositionKeys, State.LocalTime, P0, P1, PF) then
        LocalPos := Vector3Lerp(P0.Value, P1.Value, PF);
      LocalRot := QuaternionIdentity;
      if FindRotKeys(Track.RotationKeys, State.LocalTime, R0, R1, RF) then
        LocalRot := QuaternionSlerp(R0.Value, R1.Value, RF);
      LocalScl := Vector3Create(1, 1, 1);
      if FindSclKeys(Track.ScaleKeys, State.LocalTime, S0, S1, SF) then
        LocalScl := Vector3Lerp(S0.Value, S1.Value, SF);
      LocalMat := MatrixMultiply(MatrixMultiply(MatrixScale(LocalScl.x, LocalScl.y, LocalScl.z), QuaternionToMatrix(LocalRot)), MatrixTranslate(LocalPos.x, LocalPos.y, LocalPos.z));
      FSkeleton.Bones[BoneID].LocalTransform := LocalMat;
    end;
  end;
  FSkeleton.UpdateGlobalTransforms;
  for B := 0 to High(FSkeleton.Bones) do
    FFinalMatrices[B] := MatrixMultiply(FSkeleton.Bones[B].OffsetMatrix, FSkeleton.Bones[B].GlobalTransform);
  FDirty := True;
end;

procedure TAvatarAnimator.Update(DeltaTime: Single);
var
  I: Integer;
  State: TAnimationState;
  ToRemoveIndices: TArray<Integer>;
begin
  if Length(FSkeleton.Bones) = 0 then
    Exit;
  for I := 0 to FActiveStates.Count - 1 do
  begin
    State := FActiveStates[I];
    State.Advance(DeltaTime);
    if (State.State = psStopped) and (State.Weight <= 1e-4) then
      ToRemoveIndices := ToRemoveIndices + [I];
  end;
  for I := High(ToRemoveIndices) downto Low(ToRemoveIndices) do
    FActiveStates.Delete(ToRemoveIndices[I]);
  ComputeFinalBoneTransforms(DeltaTime);
end;

procedure TAvatarAnimator.ApplyToModel;
var
  I, B: Integer;
begin
  if (FOwner = nil) or (FOwner.FModel.meshes = nil) then
    Exit;
  if not FDirty then
    Exit;
  // TODO: Once we use a custom skinning shader, we will upload FFinalMatrices
  // using SetShaderValueMatrix or SetShaderValueV.
  // Raylib's default TMesh struct in Delphi doesn't expose skinningMatrices safely,
  // so we bypass it for now until we hook the shader.
  FDirty := False;
end;

procedure TAvatarAnimator.ConsumeRootMotion(out Delta: TVector3);
begin
  Delta := FRootMotionDelta;
  FRootMotionDelta := Vector3Create(0, 0, 0);
end;
{ TAvatarComponent }

constructor TAvatarComponent.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FAnimator := TAvatarAnimator.Create(Self);
end;

destructor TAvatarComponent.Destroy;
begin
  FAnimator.Free;
  inherited;
end;

procedure TAvatarComponent.Update(DeltaTime: single);
begin
  inherited Update(DeltaTime);
  if Assigned(FAnimator) then
  begin
    FAnimator.Update(DeltaTime);
    FAnimator.ApplyToModel;
  end;
end;

end.

