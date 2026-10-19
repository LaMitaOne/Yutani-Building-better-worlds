unit Yutani.Core.View;

{==============================================================================*
 *  Mainform of Yutani
 *------------------------------------------------------------------------------
 *  Author : Lara Miriam Tamy Reschke / LamitaOne
 *
 *  Description:
 *    This unit represents the main VCL interface for the 3D Engine Editor.
 *    It hosts the TRaylibSandbox viewport and wires the editor controls
 *    to the background physics and rendering thread.
 *==============================================================================}

interface

uses
  Winapi.Windows, System.SysUtils, System.Math, System.Classes, Vcl.Graphics,
  Vcl.Controls, Vcl.Forms, Vcl.Dialogs, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls,
  Yutani.Core, Yutani.Core.ModelEngine, TypInfo, Vcl.Grids, Raylib,
  Vcl.WinXPickers, Vcl.Samples.Spin, Yutani.VCL3D, Yutani.Worlds.WorldTransitions,
  Yutani.SkiaIntro, MiniAudio4Delphi;

type
  TYutaniWindow = class(TForm)
    pnlLeft: TPanel;
    tvSceneHierarchy: TTreeView;
    Splitter1: TSplitter;
    Splitter2: TSplitter;
    Panel1: TPanel;
    StringGrid1: TStringGrid;
    pnlRight: TPanel;
    PageControl1: TPageControl;
    tsScene: TTabSheet;
    tsEngine: TTabSheet;
    Splitter3: TSplitter;
    btnSpawnCubes: TButton;
    btnSpawnSpheres: TButton;
    btnSpawnPyramids: TButton;
    btnSpawnCapsules: TButton;
    cbFPS: TComboBox;
    Label1: TLabel;
    Shape1: TShape;
    btnSpawn3DModel: TButton;
    chkDistanceCulling: TCheckBox;
    cbFrustumCulling: TCheckBox;
    btnSpawnPrisms: TButton;
    chkHighlightCollision: TCheckBox;
    Memo1: TMemo;
    tmrStatsUpdater: TTimer;
    OpenDialog1: TOpenDialog;
    chkDayNightRythm: TCheckBox;
    TimePicker1: TTimePicker;
    SpDistance: TSpinEdit;
    seDayNightspeed: TSpinEdit;
    lblDaynightspeed: TLabel;
    btnSpawnSandbox: TButton;
    btnSpawnWall: TButton;
    btnSpawnBomb: TButton;
    btnSpawnButton: TButton;
    chkSlowMotion: TCheckBox;
    SaveDialog1: TSaveDialog;
    chkStatic: TCheckBox;
    btnSpawnScreens: TButton;
    lblstatic: TLabel;
    tsControls: TTabSheet;
    btnGamepadCore: TButton;
    tsAudio: TTabSheet;
    tbMasterVolume: TTrackBar;
    lblMasterVolume: TLabel;
    btnTestSFX: TButton;
    cbSpawnEffects: TComboBox;
    lblSpanEffect: TLabel;
    chkAntialias: TCheckBox;
    cbGravity: TLabel;
    seGravity: TSpinEdit;
    lblDestructable: TLabel;
    chkDestructable: TCheckBox;
    btnPiano: TButton;
    btnLoadSF2: TButton;
    tbSlowMotion: TTrackBar;
    btnFog: TButton;
    btnDemat: TButton;
    btnNanoFog: TButton;
    btnEndNanoFog: TButton;
    tmrStartEngine: TTimer;
    pnlTop: TPanel;
    cbWorldBase: TComboBox;
    Shape2: TShape;
    btnSelectPrev: TButton;
    btnSelectNext: TButton;
    btnClearScene: TButton;
    btnSceneLoad: TButton;
    btnSceneSave: TButton;
    btnPlayPause: TButton;
    btnFullscreen: TButton;
    btnShoot: TButton;
    btnToolDragThrow: TButton;
    lblInfo: TLabel;
    Button1: TButton;
    Button2: TButton;
    Button3: TButton;
    Button4: TButton;
    Button5: TButton;
    Label2: TLabel;
    spRain: TSpinEdit;
    chkShowInfos: TCheckBox;
    btnControls: TButton;
    tbSFXVolume: TTrackBar;
    lblSFXVolume: TLabel;
    lblMusicVolume: TLabel;
    tbMusicVOlume: TTrackBar;
    lblWorldTransition: TLabel;
    cbWorldTransitionEffect: TComboBox;
    procedure FormCreate(Sender: TObject);
    procedure btnSpawnCubesClick(Sender: TObject);
    procedure btnSpawnSpheresClick(Sender: TObject);
    procedure btnSpawnPyramidsClick(Sender: TObject);
    procedure btnClearSceneClick(Sender: TObject);
    procedure tvSceneHierarchyChange(Sender: TObject; Node: TTreeNode);
    procedure btnPlayPauseClick(Sender: TObject);
    procedure StringGrid1SetEditText(Sender: TObject; ACol, ARow: Integer; const Value: string);
    procedure StringGrid1SelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
    procedure btnToolDragThrowClick(Sender: TObject);
    procedure btnSpawnCapsulesClick(Sender: TObject);
    procedure cbFPSChange(Sender: TObject);
    procedure btnSceneSaveClick(Sender: TObject);
    procedure btnSceneLoadClick(Sender: TObject);
    procedure btnSpawn3DModelClick(Sender: TObject);
    procedure chkDistanceCullingClick(Sender: TObject);
    procedure cbFrustumCullingClick(Sender: TObject);
    procedure btnSpawnPrismsClick(Sender: TObject);
    procedure chkHighlightCollisionClick(Sender: TObject);
    procedure tmrStatsUpdaterTimer(Sender: TObject);
    procedure FormShow(Sender: TObject);
    procedure btnShootClick(Sender: TObject);
    procedure chkDayNightRythmClick(Sender: TObject);
    procedure TimePicker1Change(Sender: TObject);
    procedure btnSelectPrevClick(Sender: TObject);
    procedure btnSelectNextClick(Sender: TObject);
    procedure SpDistanceChange(Sender: TObject);
    procedure seDayNightspeedChange(Sender: TObject);
    procedure btnSpawnSandboxClick(Sender: TObject);
    procedure btnSpawnWallClick(Sender: TObject);
    procedure btnSpawnBombClick(Sender: TObject);
    procedure btnSpawnButtonClick(Sender: TObject);
    procedure chkSlowMotionClick(Sender: TObject);
    procedure chkStaticClick(Sender: TObject);
    procedure tvSceneHierarchyKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure btnSpawnScreensClick(Sender: TObject);
    procedure StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect; State: TGridDrawState);
    procedure tvSceneHierarchyAdvancedCustomDrawItem(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState; Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
    procedure btnGamepadCoreClick(Sender: TObject);
    procedure btnFullscreenClick(Sender: TObject);
    procedure tbMasterVolumeChange(Sender: TObject);
    procedure btnTestSFXClick(Sender: TObject);
    procedure cbWorldBaseChange(Sender: TObject);
    procedure cbSpawnEffectsChange(Sender: TObject);
    procedure chkAntialiasClick(Sender: TObject);
    procedure seGravityChange(Sender: TObject);
    procedure chkDestructableClick(Sender: TObject);
    procedure btnPianoClick(Sender: TObject);
    procedure btnLoadSF2Click(Sender: TObject);
    procedure tbSlowMotionChange(Sender: TObject);
    procedure btnFogClick(Sender: TObject);
    procedure btnDematClick(Sender: TObject);
    procedure btnNanoFogClick(Sender: TObject);
    procedure btnEndNanoFogClick(Sender: TObject);
    procedure tmrStartEngineTimer(Sender: TObject);
    procedure Button1Click(Sender: TObject);
    procedure Button3Click(Sender: TObject);
    procedure Button2Click(Sender: TObject);
    procedure Button4Click(Sender: TObject);
    procedure Button5Click(Sender: TObject);
    procedure chkShowInfosClick(Sender: TObject);
    procedure btnControlsClick(Sender: TObject);
    procedure tbSFXVolumeChange(Sender: TObject);
    procedure tbMusicVOlumeChange(Sender: TObject);
    procedure cbWorldTransitionEffectChange(Sender: TObject);
  private
    FSandbox: TYutaniRaylibSandbox;
    FSelectedComponent: TA3DComponent;
    FIsUpdatingGrid: Boolean;
    FYutaniIntro: TYutaniSkiaIntro;
    procedure RefreshHierarchy;
    procedure HandleViewportReady(Sender: TObject);
    procedure HandleActorSpawned(Sender: TObject; const Args: TActorEventArgs);
    procedure HandleActorDestroyed(Sender: TObject; const Args: TActorEventArgs);
    procedure HandleSceneCleared(Sender: TObject);
    procedure HandleEngineException(Sender: TObject; const Args: TEngineExceptionEventArgs);
    procedure LoadPropertiesIntoGrid(AComponent: TA3DComponent);
    procedure SelectActorInUI(AActor: TA3DComponent);
    procedure HandleObjectSelected(Sender: TObject; Actor: TA3DComponent);
    procedure My3DButtonClick(Sender: TObject);
  public
    { Public declarations }
  end;

var
  YutaniWindow: TYutaniWindow;

implementation
{$R *.dfm}

function StrToVector3(const S: string; Default: TVector3): TVector3;
var
  Parts: TArray<string>;
  v: Single;
  TempStr: string;
begin
  Result := Default;
  TempStr := StringReplace(S, ' ', '', [rfReplaceAll]);
  TempStr := StringReplace(TempStr, '.', ',', [rfReplaceAll]);
  Parts := TempStr.Split([',']);
  if Length(Parts) >= 1 then
    if TryStrToFloat(Trim(Parts[0]), v) then
      Result.x := v;
  if Length(Parts) >= 2 then
    if TryStrToFloat(Trim(Parts[1]), v) then
      Result.y := v;
  if Length(Parts) >= 3 then
    if TryStrToFloat(Trim(Parts[2]), v) then
      Result.z := v;
end;

function Vector3ToStr(const V: TVector3): string;
begin
  Result := Format('%.2f, %.2f, %.2f', [V.x, V.y, V.z], TFormatSettings.Create('en-US'));
end;

procedure TYutaniWindow.FormCreate(Sender: TObject);
const
  clrBackground = clBlack;
  clrFontSilver = clSilver;
begin

  FYutaniIntro := TYutaniSkiaIntro.Create;
  FYutaniIntro.LogoPath := ExtractFilePath(ParamStr(0)) + 'ressources\yutani_logo.png';
  FYutaniIntro.TextString := 'YUTANI';
  FYutaniIntro.Start;

  Left := -10000;
  Top := -10000;

  AlphaBlendValue := 0;

  // --- DARK MODE INTEGRATION ---
  // StringGrid Setup
  StringGrid1.FixedCols := 1;
  StringGrid1.FixedRows := 1;
  StringGrid1.ColCount := 2;
  StringGrid1.RowCount := 2;
  StringGrid1.Cells[0, 0] := 'Property';
  StringGrid1.Cells[1, 0] := 'Value';
  StringGrid1.Options := StringGrid1.Options + [goEditing, goAlwaysShowEditor];
  StringGrid1.ColWidths[0] := 120;
  StringGrid1.Color := clrBackground;
  StringGrid1.Font.Color := clrFontSilver;
  StringGrid1.FixedColor := clrBackground;
  // TreeView Setup
  tvSceneHierarchy.Color := clrBackground;
  tvSceneHierarchy.Font.Color := clrFontSilver;
  // Info Label
  lblInfo.Color := clrBackground;
  lblInfo.Font.Color := clrFontSilver;
  // -----------------------------
  FSandbox := TYutaniRaylibSandbox.Create(Self);
  FSandbox.Parent := Self;
  FSandbox.Align := alClient;
  FSandbox.OnViewportReady := HandleViewportReady;
  FSandbox.OnActorSpawned := HandleActorSpawned;
  FSandbox.OnActorDestroyed := HandleActorDestroyed;
  FSandbox.OnSceneCleared := HandleSceneCleared;
  FSandbox.OnEngineException := HandleEngineException;
  FSandbox.OnObjectSelected := HandleObjectSelected;
  FSandbox.FShowInfosGUi := True;
  seGravity.Value := Round(FSandbox.Gravity);
end;

procedure TYutaniWindow.FormShow(Sender: TObject);
begin
  tmrStartEngine.Enabled := True;
end;
// --- DARK MODE DRAWING METHODS ---

procedure TYutaniWindow.StringGrid1DrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect; State: TGridDrawState);
var
  Grid: TStringGrid;
  CellText: string;
begin
  Grid := Sender as TStringGrid;
  CellText := Grid.Cells[ACol, ARow];
  if gdFixed in State then
  begin
    Grid.Canvas.Brush.Color := clBlack;
    Grid.Canvas.Font.Color := clSilver;
    Grid.Canvas.Font.Style := [fsBold];
  end
  else
  begin
    Grid.Canvas.Brush.Color := clBlack;
    Grid.Canvas.Font.Color := clSilver;
    Grid.Canvas.Font.Style := [];
    if gdSelected in State then
    begin
      Grid.Canvas.Brush.Color := $00404040;
      Grid.Canvas.Font.Color := clWhite;
    end;
  end;
  // Zeile zeichnen
  Grid.Canvas.FillRect(Rect);
  Grid.Canvas.TextRect(Rect, CellText, [tfVerticalCenter, tfLeft, tfSingleLine]);
end;

procedure TYutaniWindow.tvSceneHierarchyAdvancedCustomDrawItem(Sender: TCustomTreeView; Node: TTreeNode; State: TCustomDrawState; Stage: TCustomDrawStage; var PaintImages, DefaultDraw: Boolean);
begin
  if Stage = cdPrePaint then
  begin
    if cdsSelected in State then
    begin
      Sender.Canvas.Brush.Color := $00404040;
      Sender.Canvas.Font.Color := clTeal;
    end
    else
    begin
      Sender.Canvas.Brush.Color := clBlack;
      Sender.Canvas.Font.Color := clSilver;
    end;
  end;
end;
// --------------------------------

procedure TYutaniWindow.btnTestSFXClick(Sender: TObject);
begin
  FSandbox.FYutaniAudio.PlaySoundEffect('ressources\audio\test.wav', 1.0);;
end;

procedure TYutaniWindow.btnToolDragThrowClick(Sender: TObject);
begin
  // Activate Drag & Throw Tool (Gizmo Mode gmDragAndThrow)
  FSandbox.SetGizmoMode(gmDragAndThrow);
  lblInfo.Caption := 'Tool: Drag & Throw Active.';
end;

procedure TYutaniWindow.Button1Click(Sender: TObject);
begin
  FSandbox.SpawnObjects(spRain.value, stBox);
end;

procedure TYutaniWindow.Button2Click(Sender: TObject);
begin
  FSandbox.SpawnObjects(spRain.value, stCapsule);
end;

procedure TYutaniWindow.Button3Click(Sender: TObject);
begin
  FSandbox.SpawnObjects(spRain.value, stSphere);
end;

procedure TYutaniWindow.Button4Click(Sender: TObject);
begin
  FSandbox.SpawnObjects(spRain.value, stPyramid);
end;

procedure TYutaniWindow.Button5Click(Sender: TObject);
begin
  FSandbox.SpawnObjects(spRain.value, stPrism);
end;

procedure TYutaniWindow.btnControlsClick(Sender: TObject);
begin
  Splitter1.Visible:= not Splitter1.Visible;
  pnlLeft.Visible := Splitter1.Visible;
  pnlRight.Visible := Splitter1.Visible;
  Splitter3.Visible := Splitter1.Visible;
  Splitter3.Left := ClientWidth - pnlRight.Width;
end;

procedure TYutaniWindow.btnNanoFogClick(Sender: TObject);
begin
  FSandbox.TriggerNanoFogDuplicate;
end;

procedure TYutaniWindow.btnSpawnButtonClick(Sender: TObject);
begin
  TVCL3D.SpawnButton(FSandbox, 'Button', Vector3Create(0, 5, 0), Vector3Create(4, 1, 0.5), My3DButtonClick);
end;

procedure TYutaniWindow.My3DButtonClick(Sender: TObject);
begin
  ShowMessage('Hello World from 3D Button!');
end;

procedure TYutaniWindow.cbFPSChange(Sender: TObject);
begin
  // TargetFPS is just an indicator, real limit is removed in RaylibSandbox to allow 144+ FPS if VSync is off
  FSandbox.TargetFPS := StrToInt(cbFPS.Items[cbFPS.ItemIndex]);
end;

procedure TYutaniWindow.cbFrustumCullingClick(Sender: TObject);
begin
  FSandbox.FrustumCulling := cbFrustumCulling.Checked;
end;

procedure TYutaniWindow.chkShowInfosClick(Sender: TObject);
begin
  FSandbox.FShowInfosGUi := chkShowInfos.Checked;
  tmrStatsUpdater.enabled := chkShowInfos.Checked;
  if not chkShowInfos.Checked then
  begin
    if Memo1.Lines.Count > 2 then
      Memo1.Clear;
  end;
end;

procedure TYutaniWindow.cbSpawnEffectsChange(Sender: TObject);
var
  SelectedText: string;
begin
  SelectedText := LowerCase(cbSpawnEffects.Text);
  if SelectedText = 'beam' then
    FSandbox.SpawnEffectType := spefBeam
  else if SelectedText = 'fade' then
    FSandbox.SpawnEffectType := spefFade
  else
    FSandbox.SpawnEffectType := spefNone;
end;

procedure TYutaniWindow.chkStaticClick(Sender: TObject);
begin
  FSandbox.FSpawnStatic := chkStatic.Checked;
end;

procedure TYutaniWindow.chkAntialiasClick(Sender: TObject);
begin
  FSandbox.AntiAliasing := chkAntialias.Checked;
  //todo - we must restart fully...save ini or restart internally, i do later , no mood for this now :D
end;

procedure TYutaniWindow.chkDayNightRythmClick(Sender: TObject);
begin
  FSandbox.DayNightRhythmActive := chkDayNightRythm.Checked;
end;

procedure TYutaniWindow.chkDestructableClick(Sender: TObject);
begin
  FSandbox.FSpawnDestructable := chkDestructable.Checked;
end;

procedure TYutaniWindow.chkDistanceCullingClick(Sender: TObject);
begin
  FSandbox.DistanceCulling := chkDistanceCulling.Checked;
end;

procedure TYutaniWindow.chkHighlightCollisionClick(Sender: TObject);
begin
  FSandbox.HighlightCollision := chkHighlightCollision.Checked;
end;

procedure TYutaniWindow.chkSlowMotionClick(Sender: TObject);
begin
  FSandbox.SetSlowMotionActive(chkSlowMotion.Checked);
end;

procedure TYutaniWindow.cbWorldBaseChange(Sender: TObject);
var
  SelectedWorld: TWorldBaseType;
  Idx: Integer;
begin
  Idx := cbWorldBase.ItemIndex;
  if Idx < 0 then
    Exit;
  SelectedWorld := TWorldBaseType(Idx);
  if Assigned(FSandbox) then
    FSandbox.CurrentWorldBase := SelectedWorld;
end;

procedure TYutaniWindow.cbWorldTransitionEffectChange(Sender: TObject);
begin
  if (cbWorldTransitionEffect.ItemIndex >= 0) and Assigned(FSandbox) then
    FSandbox.WorldTransitionType := TTransitionType(cbWorldTransitionEffect.ItemIndex);
end;

procedure TYutaniWindow.btnSceneSaveClick(Sender: TObject);
begin
  if not Assigned(FSandbox) then
    Exit;
  if SaveDialog1.Execute then
  begin
    // Delegated to the RaylibSandbox for better stability and thread safety
    FSandbox.SaveSceneToFile(SaveDialog1.FileName);
    lblInfo.Caption := 'Scene saved to: ' + SaveDialog1.FileName;
  end;
end;

procedure TYutaniWindow.btnSceneLoadClick(Sender: TObject);
begin
  if not Assigned(FSandbox) then
    Exit;
  if not OpenDialog1.Execute then
    Exit;
  // Tell the sandbox thread to load the scene. The VCL remains responsive.
  FSandbox.LoadSceneFromFile(OpenDialog1.FileName);
  lblInfo.Caption := 'Scene loaded from: ' + OpenDialog1.FileName;
end;

procedure TYutaniWindow.btnSelectNextClick(Sender: TObject);
begin
  FSandbox.SelectNextObject;
end;

procedure TYutaniWindow.btnSelectPrevClick(Sender: TObject);
begin
  FSandbox.SelectPrevObject;
end;

procedure TYutaniWindow.btnShootClick(Sender: TObject);
begin
  FSandbox.PublicShootBall;
end;

procedure TYutaniWindow.btnSpawnSandboxClick(Sender: TObject);
begin
  TVCL3D.SpawnSandbox(FSandbox);
end;

procedure TYutaniWindow.btnSpawnScreensClick(Sender: TObject);
begin
  TVCL3D.SpawnMonitorWall(FSandbox);
  lblInfo.Caption := 'Multiview: 2x5 Monitor Wall spawned.';
end;

procedure TYutaniWindow.btnSpawnWallClick(Sender: TObject);
begin
  TVCL3D.SpawnDynamicWall(FSandbox, 10, 10, false, true, chkDestructable.Checked);
end;

procedure TYutaniWindow.btnSpawn3DModelClick(Sender: TObject);
begin
  if OpenDialog1.Execute then
  begin
    FSandbox.LoadCustomModel(OpenDialog1.FileName);
  end;
end;

procedure TYutaniWindow.btnSpawnBombClick(Sender: TObject);
begin
  FSandbox.SetBrush(stBomb);
  FSandbox.SetGizmoMode(gmTranslate);
  lblInfo.Caption := 'Brush: Bomb Selected.';
end;

procedure TYutaniWindow.btnSpawnCapsulesClick(Sender: TObject);
begin
  FSandbox.SetBrush(stCapsule);
  FSandbox.SetGizmoMode(gmTranslate);
  lblInfo.Caption := 'Brush: Capsule Selected.';
end;

procedure TYutaniWindow.btnSpawnCubesClick(Sender: TObject);
begin
  FSandbox.SetBrush(stBox);
  FSandbox.SetGizmoMode(gmTranslate);
  lblInfo.Caption := 'Brush: Cube Selected.';
end;

procedure TYutaniWindow.btnSpawnSpheresClick(Sender: TObject);
begin
  FSandbox.SetBrush(stSphere);
  FSandbox.SetGizmoMode(gmTranslate);
  lblInfo.Caption := 'Brush: Sphere Selected.';
end;

procedure TYutaniWindow.btnSpawnPyramidsClick(Sender: TObject);
begin
  FSandbox.SetBrush(stPyramid);
  FSandbox.SetGizmoMode(gmTranslate);
  lblInfo.Caption := 'Brush: Pyramid Selected.';
end;

procedure TYutaniWindow.btnSpawnPrismsClick(Sender: TObject);
begin
  FSandbox.SetBrush(stPrism);
  FSandbox.SetGizmoMode(gmTranslate);
  lblInfo.Caption := 'Brush: Prism Selected.';
end;

procedure TYutaniWindow.btnClearSceneClick(Sender: TObject);
begin
  FSandbox.ClearItems;
  StringGrid1.Visible := False;
  lblInfo.Caption := 'Scene Cleared.';
end;

procedure TYutaniWindow.btnDematClick(Sender: TObject);
begin
  FSandbox.DematerializeSelectedObject;
   //or
  //FSandbox.DematerializeActor(  --  TA3DComponent  --  );
end;

procedure TYutaniWindow.btnEndNanoFogClick(Sender: TObject);
begin
  FSandbox.KillNanoFog;
end;

procedure TYutaniWindow.btnFogClick(Sender: TObject);
begin
  FSandbox.TriggerFogEffect;
end;

procedure TYutaniWindow.btnFullscreenClick(Sender: TObject);
begin
  if BorderStyle = bsNone then
  begin
    BorderStyle := bsSizeable;
    WindowState := wsNormal;
  end
  else
  begin
    WindowState := wsNormal;
    BorderStyle := bsNone;
    WindowState := wsMaximized;
  end;
end;

procedure TYutaniWindow.btnGamepadCoreClick(Sender: TObject);
begin
  //--
  FSandbox.FInputManager.ShowGamepadSettings(Self);
end;

procedure TYutaniWindow.btnLoadSF2Click(Sender: TObject);
begin
  // Set filter to Soundfont files
  OpenDialog1.Filter := 'SoundFont 2 (*.sf2)|*.sf2';
  // Set initial directory to the audio resources folder
  OpenDialog1.InitialDir := ExtractFilePath(ParamStr(0)) + 'ressources\audio';
  if OpenDialog1.Execute then
  begin
    try
      // Check if the sandbox and audio engine exist
      if Assigned(FSandbox) then
      begin
        // Load the Soundfont!
        FSandbox.FYutaniAudio.LoadSoundfont(OpenDialog1.FileName);
        ShowMessage('Soundfont loaded successfully!');
      end
      else
        ShowMessage('Audio Engine is not initialized.');
    except
      on E: Exception do
        ShowMessage('Error loading Soundfont: ' + E.Message);
    end;
  end;
end;

procedure TYutaniWindow.btnPianoClick(Sender: TObject);
begin
  FSandbox.SpawnPiano;
end;

procedure TYutaniWindow.btnPlayPauseClick(Sender: TObject);
begin
  if FSandbox.GetSimulationRunning then
  begin
    FSandbox.SetSimulationRunning(False);
    btnPlayPause.Caption := 'PLAY';
    lblInfo.Caption := 'Editor Mode (Paused). Place objects freely.';
  end
  else
  begin
    FSandbox.SetSimulationRunning(True);
    btnPlayPause.Caption := 'PAUSE';
    lblInfo.Caption := 'Simulation Running.';
  end;
end;
// === Object Inspector Logic ===

procedure TYutaniWindow.LoadPropertiesIntoGrid(AComponent: TA3DComponent);
var
  PropList: PPropList;
  Count, i: Integer;
  PropInfo: PPropInfo;
  StrVal: string;
  ColorVal: TColorB;
  IntColor: Cardinal;
  PropName: string;
begin
  FIsUpdatingGrid := True;
  try
    if not Assigned(AComponent) then
    begin
      StringGrid1.Hide;
      StringGrid1.RowCount := 2;
      StringGrid1.Cells[0, 1] := '';
      StringGrid1.Cells[1, 1] := '';
      Exit;
    end;
    Count := GetPropList(AComponent.ClassInfo, tkAny, nil, true);
    GetMem(PropList, Count * SizeOf(Pointer));
    try
      GetPropList(AComponent.ClassInfo, tkAny, PropList, true);
      StringGrid1.RowCount := Count + 1;
      StringGrid1.Cells[0, 0] := 'Property';
      StringGrid1.Cells[1, 0] := 'Value';
      StringGrid1.Show;
      for i := 0 to Count - 1 do
      begin
        PropInfo := PropList^[i];
        PropName := string(PropInfo^.Name);
        StringGrid1.Cells[0, i + 1] := PropName;
        if PropName = 'ActColor' then
        begin
          ColorVal := AComponent.ActColor;
          Move(ColorVal, IntColor, SizeOf(TColorB));
          StrVal := IntToHex(IntColor, 8);
        end
        else if PropName = 'TargetColor' then
        begin
          ColorVal := AComponent.TargetColor;
          Move(ColorVal, IntColor, SizeOf(TColorB));
          StrVal := IntToHex(IntColor, 8);
        end
        else if PropName = 'Position' then
          StrVal := Vector3ToStr(AComponent.Position)
        else if PropName = 'Scale' then
          StrVal := Vector3ToStr(AComponent.Scale)
        else if PropName = 'Rotation' then
          StrVal := Vector3ToStr(AComponent.Rotation)
        else if PropName = 'Quaternion' then
          StrVal := Vector3ToStr(Vector3Create(AComponent.Quaternion.x, AComponent.Quaternion.y, AComponent.Quaternion.z))
        else
        begin
          case PropInfo^.PropType^.Kind of
            tkFloat:
              StrVal := FloatToStrF(GetFloatProp(AComponent, PropInfo), ffGeneral, 4, 4);
            tkInteger:
              StrVal := IntToStr(GetOrdProp(AComponent, PropInfo));
            tkEnumeration:
              StrVal := GetEnumName(PropInfo^.PropType^, GetOrdProp(AComponent, PropInfo));
            tkString, tkLString, tkWString, tkUString:
              StrVal := GetStrProp(AComponent, PropInfo);
          else
            StrVal := '(Unsupported)';
          end;
        end;
        StringGrid1.Cells[1, i + 1] := StrVal;
      end;
    finally
      FreeMem(PropList);
    end;
  finally
    FIsUpdatingGrid := False;
  end;
end;

procedure TYutaniWindow.StringGrid1SelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
begin
  CanSelect := (ACol = 1) and (ARow > 0) and Assigned(FSelectedComponent);
end;

procedure TYutaniWindow.StringGrid1SetEditText(Sender: TObject; ACol, ARow: Integer; const Value: string);
var
  PropName: string;
  PropInfo: PPropInfo;
  FloatVal: Extended;
  IntVal: Integer;
  HexVal: Cardinal;
  ColorVal: TColorB;
  VecVal: TVector3;
  Rx, Ry, Rz: Single;
  CY, SY, CP, SP, CR, SR: Single;
  CYCP, SYSP, CYSP, SYCP: Single;
begin
  if FIsUpdatingGrid or (ARow = 0) or not Assigned(FSelectedComponent) then
    Exit;
  PropName := StringGrid1.Cells[0, ARow];
  if PropName = 'Name' then
  begin
    FSelectedComponent.Name := Value;
    RefreshHierarchy;
  end;
  PropInfo := GetPropInfo(FSelectedComponent, PropName);
  if not Assigned(PropInfo) then
    Exit;
  try
    if PropName = 'ActColor' then
    begin
      HexVal := StrToIntDef(Value, 0);
      Move(HexVal, ColorVal, SizeOf(TColorB));
      FSelectedComponent.ActColor := ColorVal;
    end
    else if PropName = 'TargetColor' then
    begin
      HexVal := StrToIntDef(Value, 0);
      Move(HexVal, ColorVal, SizeOf(TColorB));
      FSelectedComponent.TargetColor := ColorVal;
    end
    else if PropName = 'Position' then
    begin
      VecVal := StrToVector3(Value, FSelectedComponent.Position);
      FSelectedComponent.Position := VecVal;
    end
    else if PropName = 'Scale' then
    begin
      VecVal := StrToVector3(Value, FSelectedComponent.Scale);
      FSelectedComponent.Scale := VecVal;
    end
    else if PropName = 'Rotation' then
    begin
      VecVal := StrToVector3(Value, FSelectedComponent.Rotation);
      Rx := DegToRad(VecVal.x);
      Ry := DegToRad(VecVal.y);
      Rz := DegToRad(VecVal.z);
      CY := Cos(Ry * 0.5);
      SY := Sin(Ry * 0.5);
      CP := Cos(Rx * 0.5);
      SP := Sin(Rx * 0.5);
      CR := Cos(Rz * 0.5);
      SR := Sin(Rz * 0.5);
      CYCP := CY * CP;
      SYSP := SY * SP;
      CYSP := CY * CP;
      SYCP := SY * CP;
      FSelectedComponent.Quaternion := Vector4Create(CYCP * SR - SYSP * CR, CYSP * CR + SYCP * SR, SYCP * CR - CYSP * SR, CYCP * CR + SYSP * SR);
    end
    else if PropName = 'Quaternion' then
    begin
      VecVal := StrToVector3(Value, Vector3Create(FSelectedComponent.Quaternion.x, FSelectedComponent.Quaternion.y, FSelectedComponent.Quaternion.z));
      FSelectedComponent.Quaternion := Vector4Create(VecVal.x, VecVal.y, VecVal.z, FSelectedComponent.Quaternion.w);
    end
    else
    begin
      case PropInfo^.PropType^.Kind of
        tkFloat:
          if TryStrToFloat(Value, FloatVal) then
            SetFloatProp(FSelectedComponent, PropInfo, FloatVal);
        tkInteger:
          if TryStrToInt(Value, IntVal) then
            SetOrdProp(FSelectedComponent, PropInfo, IntVal);
        tkEnumeration:
          if TryStrToInt(Value, IntVal) then
            SetOrdProp(FSelectedComponent, PropInfo, IntVal);
        tkString, tkLString, tkWString, tkUString:
          SetStrProp(FSelectedComponent, PropInfo, Value);
      end;
    end;
  except
    on E: Exception do
      lblInfo.Caption := 'ERR SetProp: ' + E.Message;
  end;
end;

procedure TYutaniWindow.tbMasterVolumeChange(Sender: TObject);
begin
  FSandbox.FYutaniAudio.SetMasterVolume(tbMasterVolume.Position / 100.0);
  //ma_engine_set_volume(FSandbox.FYutaniAudio, tbMasterVolume.Position / 100.0);
  //tinysoundfont to do
end;

procedure TYutaniWindow.tbMusicVolumeChange(Sender: TObject);
begin
  FSandbox.FYutaniAudio.SetMusicVolume(tbMusicVOlume.Position / 100.0);
  //tinysoundfont vol to do
end;

procedure TYutaniWindow.tbSFXVolumeChange(Sender: TObject);
begin
  FSandbox.FYutaniAudio.SetSFXVolume(tbSFXVolume.Position / 100.0);
end;

procedure TYutaniWindow.tbSlowMotionChange(Sender: TObject);
begin
  FSandbox.TimeScale := tbSlowMotion.Position / 100.0;
end;

procedure TYutaniWindow.TimePicker1Change(Sender: TObject);
begin
  FSandbox.DayNightTime := TImepicker1.Time;
end;

procedure TYutaniWindow.tmrStartEngineTimer(Sender: TObject);
begin
  if not FSandbox.Active then
  begin
    FSandbox.Active := True;
    Exit;
  end;

  if not FYutaniIntro.IntroFinished then
    Exit;

  if AlphaBlendValue = 0 then
  begin
    Left := 0;
    Top := 0;
    Width := Screen.Width;
    Height := Screen.Height;
    AlphaBlendValue := 1;
    Exit;
  end;

  if AlphaBlendValue < 240 then
  begin
    AlphaBlendValue := AlphaBlendValue + 10;
    RedrawWindow(Handle, nil, 0, RDW_INVALIDATE or RDW_UPDATENOW or RDW_FRAME);
  end
  else
  begin
    AlphaBlendValue := 255;
    tmrStartEngine.Enabled := False;
    tmrStatsUpdater.Enabled := True;
  end;
end;

procedure TYutaniWindow.HandleObjectSelected(Sender: TObject; Actor: TA3DComponent);
begin
  TThread.Queue(nil,
    procedure
    begin
      // If an object was deleted, Actor is nil. We need to rebuild the TreeView.
      if not Assigned(Actor) then
      begin
        tvSceneHierarchy.Items.Clear;
        RefreshHierarchy;
      end;
      SelectActorInUI(Actor);
      if Assigned(Actor) then
        FSandbox.SetSelectedActor(Actor);
    end);
end;

procedure TYutaniWindow.SelectActorInUI(AActor: TA3DComponent);
var
  Idx: Integer;
begin
  FSelectedComponent := AActor;
  LoadPropertiesIntoGrid(AActor);
  StringGrid1.Visible := Assigned(AActor);
  if Assigned(AActor) then
  begin
    for Idx := 0 to FSandbox.ItemCount - 1 do
      if FSandbox.FItems[Idx] = AActor then
        Break;
    if (Idx >= 0) and (Idx < tvSceneHierarchy.Items.Count) then
    begin
      tvSceneHierarchy.OnChange := nil;
      try
        tvSceneHierarchy.Select(tvSceneHierarchy.Items[Idx]);
      finally
        tvSceneHierarchy.OnChange := tvSceneHierarchyChange;
      end;
    end;
  end
  else
  begin
    if tvSceneHierarchy.Selected <> nil then
    begin
      tvSceneHierarchy.OnChange := nil;
      try
        tvSceneHierarchy.Selected := nil;
      finally
        tvSceneHierarchy.OnChange := tvSceneHierarchyChange;
      end;
    end;
  end;
end;

procedure TYutaniWindow.SpDistanceChange(Sender: TObject);
begin
  FSandbox.MaxRenderDistance := SpDistance.Value;
end;

procedure TYutaniWindow.seGravityChange(Sender: TObject);
begin
  FSandbox.Gravity := seGravity.Value;
end;

procedure TYutaniWindow.HandleViewportReady(Sender: TObject);
begin
  lblInfo.Caption := 'Engine Viewport Ready.';
  btnPlayPause.Caption := 'PAUSE';
end;

procedure TYutaniWindow.HandleActorDestroyed(Sender: TObject; const Args: TActorEventArgs);
var
  i: Integer;
  NodeToDelete: TTreeNode;
begin
  if Args.Actor = nil then
    Exit;
  NodeToDelete := nil;
  // Search through all nodes in the TreeView to find the one holding the destroyed Actor
  for i := 0 to tvSceneHierarchy.Items.Count - 1 do
  begin
    if tvSceneHierarchy.Items[i].Data = Args.Actor then
    begin
      NodeToDelete := tvSceneHierarchy.Items[i];
      Break; // Found it, no need to search further
    end;
  end;
  // If the node was found, delete it from the TreeView
  if Assigned(NodeToDelete) then
    tvSceneHierarchy.Items.Delete(NodeToDelete);
end;

procedure TYutaniWindow.HandleActorSpawned(Sender: TObject; const Args: TActorEventArgs);
var
  NodeText: string;
  Node: TTreeNode;
begin
  if Args.Actor <> nil then
  begin
    // Determine the display name for the TreeView node
    if Args.Actor.Name <> '' then
      NodeText := Args.Actor.Name
    else
      NodeText := 'Unnamed ' + GetEnumName(TypeInfo(TShapeType), Ord(Args.Actor.ShapeType));
    // Add the node to the TreeView
    Node := tvSceneHierarchy.Items.AddChild(nil, NodeText);
    // CRITICAL: Store the actual Actor object pointer in the Node's Data property.
    // This ensures that clicking the node immediately gives us the Actor.
    Node.Data := Args.Actor;
  end;
end;

procedure TYutaniWindow.HandleSceneCleared(Sender: TObject);
begin
  tvSceneHierarchy.Items.Clear;
  lblInfo.Caption := 'Scene Cleared.';
  LoadPropertiesIntoGrid(nil);
end;

procedure TYutaniWindow.HandleEngineException(Sender: TObject; const Args: TEngineExceptionEventArgs);
begin
  lblInfo.Caption := Format('ERR [%s]: %s', [Args.Context, Args.Message]);
end;

procedure TYutaniWindow.tmrStatsUpdaterTimer(Sender: TObject);
var
  TotalObjects: Integer;
  SimStatus: string;
  SelectedInfo: string;
  i: Integer;
begin
  if not chkShowInfos.Checked then
    Exit;

  if (not pnlRight.Visible) or (PageControl1.ActivePageIndex <> 0) then
    Exit;

  if not Assigned(FSandbox) then
    Exit;

  if FSandbox.IsLoadingWorld then
    Exit;

  TotalObjects := FSandbox.ItemCount;
  if FSandbox.GetSimulationRunning then
    SimStatus := 'Running'
  else
    SimStatus := 'Paused';
  SelectedInfo := 'None';
  if Assigned(FSelectedComponent) then
    SelectedInfo := Format('%s (ID: %d)', [GetEnumName(TypeInfo(TShapeType), Ord(FSelectedComponent.ShapeType)), FSelectedComponent.BodyID]);
  Memo1.Lines.BeginUpdate;
  try
    Memo1.Lines.Clear;
    Memo1.Lines.Add('=== ENGINE STATS ===');
    Memo1.Lines.Add(Format('State:      %s', [SimStatus]));
    Memo1.Lines.Add(Format('FPS:         %d', [GetFPS()])); // Raylib GetFPS()
    Memo1.Lines.Add('-------------------');
    Memo1.Lines.Add(Format('Objects:     %d', [TotalObjects]));
    Memo1.Lines.Add(Format('In movement:    %d', [FSandbox.ActiveBodies]));
    Memo1.Lines.Add('-------------------');
    Memo1.Lines.Add(Format('Physic-Time: %.2f ms', [FSandbox.LastPhysicsTime]));
    Memo1.Lines.Add('-------------------');
    Memo1.Lines.Add(Format('Selected:     %s', [SelectedInfo]));
    Memo1.Lines.Add('-------------------');
    // Count models specifically
    var ModelCount: Integer := 0;
    for i := 0 to FSandbox.ItemCount - 1 do
      if Assigned(FSandbox.FItems[i]) and (FSandbox.FItems[i].ShapeType = stModel) then
        Inc(ModelCount);
    Memo1.Lines.Add(Format('3D Models:   %d', [ModelCount]));
  finally
    Memo1.Lines.EndUpdate;
  end;
end;

procedure TYutaniWindow.tvSceneHierarchyChange(Sender: TObject; Node: TTreeNode);
var
  Actor: TA3DComponent;
begin
  // If nothing is selected, or the Node has no Data (Actor), clear selection
  if (Node = nil) or (Node.Data = nil) then
  begin
    FSelectedComponent := nil;
    FSandbox.SetSelectedActor(nil);
    LoadPropertiesIntoGrid(nil); // Clear the Object Inspector
    Exit;
  end;
  // Retrieve the actual Actor object from the selected Node's Data pointer
  Actor := TA3DComponent(Node.Data);
  if Assigned(Actor) then
  begin
    FSelectedComponent := Actor;
    // Notify the Raylib Sandbox engine about the new selection
    FSandbox.SetSelectedActor(Actor);
    // Update the Object Inspector grid with the selected Actor's properties
    LoadPropertiesIntoGrid(Actor);
    // Update the status label at the bottom
    lblInfo.Caption := Format('Selected: %s | Pos: %.1f, %.1f, %.1f', [Actor.Name, Actor.Position.x, Actor.Position.y, Actor.Position.z]);
  end;
end;

procedure TYutaniWindow.tvSceneHierarchyKeyUp(Sender: TObject; var Key: Word; Shift: TShiftState);
var
  ActorToDelete: TA3DComponent;
begin
  // Check if the Delete key was pressed
  if Key = VK_DELETE then
  begin
    if (tvSceneHierarchy.Selected <> nil) and (tvSceneHierarchy.Selected.Data <> nil) then
    begin
      ActorToDelete := TA3DComponent(tvSceneHierarchy.Selected.Data);
      if Assigned(ActorToDelete) then
      begin
        // CRITICAL: Disable brush mode so the delete click doesn't instantly spawn a standard cube
        FSandbox.FIsBrushActive := False;
        FSandbox.FGhostVisible := False;
        // Tell the sandbox to delete the selected actor
        FSandbox.SetSelectedActor(ActorToDelete);
        FSandbox.DeleteSelectedActor;
        // Clear UI selection
        FSelectedComponent := nil;
        Key := 0; // Consume the key press
      end;
    end;
  end;
end;

procedure TYutaniWindow.RefreshHierarchy;
var
  i: Integer;
  Actor: TA3DComponent;
  NodeText: string;
  Node: TTreeNode;
begin
  tvSceneHierarchy.Items.BeginUpdate;
  try
    tvSceneHierarchy.Items.Clear;
    for i := 0 to FSandbox.ItemCount - 1 do
    begin
      Actor := FSandbox.FItems[i];
      if Assigned(Actor) then
      begin
        // Determine the display name for the TreeView node
        if Actor.Name <> '' then
          NodeText := Actor.Name
        else
          NodeText := 'Unnamed ' + GetEnumName(TypeInfo(TShapeType), Ord(Actor.ShapeType));
        // Add the node to the TreeView
        Node := tvSceneHierarchy.Items.AddChild(nil, NodeText);
        // CRITICAL: Store the actual Actor object pointer in the Node's Data property.
        // This allows us to instantly access the Actor when the user clicks the node.
        Node.Data := Actor;
      end;
    end;
  finally
    tvSceneHierarchy.Items.EndUpdate;
  end;
end;

procedure TYutaniWindow.seDayNightspeedChange(Sender: TObject);
var
  UserVal: Integer;
  ActualSpeed: Single;
begin
  UserVal := seDayNightspeed.Value;
  // Scale 1-100 to 0.001-0.1
  ActualSpeed := UserVal / 1000.0;
  FSandbox.DayNightSpeed := ActualSpeed;
end;

initialization
  // CRITICAL: Register the class so TReader.ReadComponent can instantiate it!
  // TReader is paranoid and refuses to create classes it doesn't know.
  RegisterClass(TA3DComponent);


finalization
  UnRegisterClass(TA3DComponent);

end.

