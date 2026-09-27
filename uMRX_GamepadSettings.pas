{*******************************************************************************
  MRX Gamepad Settings UI
********************************************************************************
  A visual configuration form for the MRX Gamepad Core.
  Allows users to map gamepad and keyboard inputs, adjust analog stick
  deadzones, and manage controller profiles via INI files.
  Author:  Lara Miriam Tamy Reschke
  License: MIT
  Key Features:
  - Visual Controller Map: Displays a gamepad image where buttons highlight
    (Cyan) when pressed.
  - Click-to-Map Interface: Click any button on the image or UI to enter
    "Listening Mode", then press a gamepad button or keyboard key to map it.
  - Dynamic Stick Visualization: L3/R3 buttons physically move on the UI
    based on analog stick X/Y values.
  - Deadzone Configuration: Visual trackbars adjust stick deadzones,
    represented by scaling circles around the L3/R3 buttons.
  - Profile Management: Save, load, and create custom mapping profiles
    stored as local .ini files.
*******************************************************************************}
{ MRX-Gamepad-Core v0.1                                                        }
{ by Lara Miriam Tamy Reschke                                                  }
{                                                                              }
{------------------------------------------------------------------------------}
{
 ----Latest Changes
   v 0.1 (Alpha):
     - Initial Release.
     - Created dynamic UI generation (Labels over TImage background).
     - Implemented Pythagoras-based click detection for transparent buttons.
     - Added BlinkTimer for visual feedback during "Listening Mode".
     - Implemented INI save/load logic for profiles and deadzones.
     - Note: Currently parses Label.Text to determine mappings (Planned for
       replacement with a proper data dictionary in v0.2).
}
unit uMRX_GamepadSettings;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.TypInfo,
  System.IniFiles, Winapi.Windows, FMX.Types, FMX.Controls, FMX.Forms,
  FMX.Graphics, FMX.Dialogs, FMX.StdCtrls, FMX.Objects, FMX.Layouts, FMX.ListBox,
  FMX.Edit, uMRX_GamepadCore;

type
  /// <summary>
  /// Record associating a visual label with a gamepad element.
  /// </summary>
  TButtonRec = record
    Btn: TLabel;
    Element: TGamepadElement;
  end;
  /// <summary>
  /// Form for visually configuring gamepad mappings and deadzones.
  /// </summary>

  TfrmGamepadSettings = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
  private
    FCore: TMRXGamepadCore;
    FImgController: TImage;
    FComboPad: TComboBox;
    FComboProfiles: TComboBox;
    FBtnLoadProfile: TButton;
    FBtnSaveProfile: TButton;
    FBtnNewProfile: TButton;
    FBtnDefault: TButton;
    FButtonRecs: array of TButtonRec;
    FProfilePath: string;
    FCircleLeft: TCircle;
    FCircleRight: TCircle;
    FTrackLeft: TTrackBar;
    FTrackRight: TTrackBar;
    FIsListening: Boolean;
    FListeningElement: TGamepadElement;
    FListeningBtn: TLabel;
    FBlinkTimer: TTimer;
    procedure InitVisuals;
    procedure OnGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
    procedure HighlightButton(Element: TGamepadElement; Pressed: Boolean);
    procedure LoadProfilesToList;
    procedure BtnLoadClick(Sender: TObject);
    procedure BtnSaveClick(Sender: TObject);
    procedure BtnNewClick(Sender: TObject);
    procedure BtnDefaultClick(Sender: TObject);
    function GetSelectedPadID: Integer;
    function GetProfileFile: string;
    procedure OnBtnMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
    procedure OnBlinkTimer(Sender: TObject);
    procedure OnTrackChange(Sender: TObject);
    procedure LoadProfileSettings;
    procedure SaveCurrentMappings;
    procedure ResetToDefaults;
    procedure UpdateButtonLabel(Btn: TLabel; MappedValue: string);
    procedure OnImageMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
  public
    constructor Create(AOwner: TComponent; ACore: TMRXGamepadCore); reintroduce;
  end;

var
  frmGamepadSettings: TfrmGamepadSettings;

implementation
{$R *.fmx}

constructor TfrmGamepadSettings.Create(AOwner: TComponent; ACore: TMRXGamepadCore);
begin
  inherited Create(AOwner);
  FProfilePath := ExtractFilePath(ParamStr(0));
  FCore := ACore;
  FCore.OnInputEvent := OnGamepadInput;
  OnKeyDown := FormKeyDown;
end;

procedure TfrmGamepadSettings.FormCreate(Sender: TObject);
begin
  Caption := 'MRX Gamepad Settings';
  FProfilePath := ExtractFilePath(ParamStr(0));
  BorderStyle := TFmxFormBorderStyle.Single;
  ClientWidth := 900;
  ClientHeight := 650;
  Fill.Color := TAlphaColors.Black;
  Position := TFormPosition.ScreenCenter;
  InitVisuals;
  LoadProfilesToList;
end;

procedure TfrmGamepadSettings.FormDestroy(Sender: TObject);
begin
  if Assigned(FCore) then
    FCore.OnInputEvent := nil;
end;

procedure TfrmGamepadSettings.FormKeyDown(Sender: TObject; var Key: Word; var KeyChar: WideChar; Shift: TShiftState);
var
  Ini: TIniFile;
  Section, KeyName, ValName: string;
begin
  if not FIsListening then
    Exit;
  // Capture keyboard input for mapping
  if KeyChar <> #0 then
    ValName := 'KB_' + IntToStr(Ord(KeyChar))
  else
    ValName := 'KB_' + IntToStr(Key);
  FBlinkTimer.Enabled := False;
  FListeningBtn.TextSettings.FontColor := TAlphaColors.White;
  Ini := TIniFile.Create(GetProfileFile);
  try
    Section := 'Pad' + IntToStr(GetSelectedPadID);
    KeyName := 'Map_' + GetEnumName(TypeInfo(TGamepadElement), Ord(FListeningElement));
    Ini.WriteString(Section, KeyName, ValName);
  finally
    Ini.Free;
  end;
  FIsListening := False;
  UpdateButtonLabel(FListeningBtn, ValName);
  Key := 0;
  KeyChar := #0;
end;

procedure TfrmGamepadSettings.UpdateButtonLabel(Btn: TLabel; MappedValue: string);
var
  OrigName, SelfEnumName: string;
  i: Integer;
begin
  OrigName := Btn.Hint;
  SelfEnumName := '';
  // Find the enum name of the button itself
  for i := 0 to High(FButtonRecs) do
  begin
    if FButtonRecs[i].Btn = Btn then
    begin
      SelfEnumName := GetEnumName(TypeInfo(TGamepadElement), Ord(FButtonRecs[i].Element));
      Break;
    end;
  end;
  // If mapped to itself or empty, show only the original name
  if (MappedValue = '') or (MappedValue = SelfEnumName) then
  begin
    Btn.Text := OrigName;
  end
  else
  begin
    // Otherwise, show original name and mapped value below
    Btn.Text := OrigName + #13#10 + '= ' + MappedValue;
  end;
end;

procedure TfrmGamepadSettings.InitVisuals;
var
  Lbl: TLabel;
  BottomBar: TLayout;
  i: Integer;

  procedure AddButton(const AText: string; AX, AY: Single; AElement: TGamepadElement);
  var
    Rec: TButtonRec;
  begin
    Rec.Btn := TLabel.Create(Self);
    Rec.Btn.Parent := Self;
    Rec.Btn.Text := AText;
    Rec.Btn.Hint := AText;
    Rec.Btn.Position.X := AX;
    Rec.Btn.Position.Y := AY;
    // Store original X and Y for stick movement calculations
    Rec.Btn.TagFloat := AX;
    Rec.Btn.Tag := Trunc(AY);
    Rec.Btn.Width := 60;
    Rec.Btn.Height := 45;
    Rec.Btn.StyledSettings := [];
    Rec.Btn.TextSettings.Font.Style := [TFontStyle.fsBold];
    Rec.Btn.TextSettings.FontColor := TAlphaColors.White;
    Rec.Btn.TextSettings.HorzAlign := TTextAlign.Center;
    Rec.Btn.TextSettings.VertAlign := TTextAlign.Center;
    Rec.Btn.TextSettings.WordWrap := True;
    Rec.Btn.HitTest := True;
    Rec.Btn.OnMouseDown := OnBtnMouseDown;
    Rec.Element := AElement;
    SetLength(FButtonRecs, Length(FButtonRecs) + 1);
    FButtonRecs[High(FButtonRecs)] := Rec;
  end;

begin
  FImgController := TImage.Create(Self);
  FImgController.Parent := Self;
  FImgController.Align := TAlignLayout.Client;
  FImgController.WrapMode := TImageWrapMode.Fit;
  FImgController.HitTest := False;
  try
    FImgController.Bitmap.LoadFromFile('gamepad.png');
  except
    on E: Exception do
      ShowMessage('gamepad.png not found!');
  end;
  // D-Pad
  AddButton('U', 315, 275, gePadUp);
  AddButton('D', 315, 390, gePadDown);
  AddButton('L', 260, 335, gePadLeft);
  AddButton('R', 365, 335, gePadRight);
  // Left Stick
  AddButton('L3', 210, 210, geLeftStickClick);
  AddButton('LU', 210, 170, geLeftStickUp);
  AddButton('LD', 210, 250, geLeftStickDown);
  AddButton('LL', 170, 210, geLeftStickLeft);
  AddButton('LR', 250, 210, geLeftStickRight);
  // Right Stick
  AddButton('R3', 520, 320, geRightStickClick);
  AddButton('RU', 520, 280, geRightStickUp);
  AddButton('RD', 520, 360, geRightStickDown);
  AddButton('RL', 480, 320, geRightStickLeft);
  AddButton('RR', 560, 320, geRightStickRight);
  // Shoulder Triggers
  AddButton('LB', 100, 110, geLB);
  AddButton('RB', 750, 110, geRB);
  AddButton('LT', 100, 60, geLT);
  AddButton('RT', 750, 60, geRT);
  // Middle Buttons
  AddButton('Back', 370, 240, geBack);
  AddButton('Guide', 420, 180, geGuide);
  AddButton('Start', 470, 240, geStart);
  // Face Buttons
  AddButton('Y', 650, 180, geBtnY);
  AddButton('X', 590, 240, geBtnX);
  AddButton('B', 710, 240, geBtnB);
  AddButton('A', 650, 280, geBtnA);
  // Bottom Bar Setup
  BottomBar := TLayout.Create(Self);
  BottomBar.Parent := Self;
  BottomBar.Align := TAlignLayout.Bottom;
  BottomBar.Height := 60;
  Lbl := TLabel.Create(Self);
  Lbl.Parent := BottomBar;
  Lbl.Text := 'Gamepad:';
  Lbl.Position.X := 10;
  Lbl.Position.Y := 20;
  Lbl.TextSettings.FontColor := TAlphaColors.White;
  Lbl.StyledSettings := [];
  FComboPad := TComboBox.Create(Self);
  FComboPad.Parent := BottomBar;
  FComboPad.Position.X := 70;
  FComboPad.Position.Y := 15;
  FComboPad.Width := 100;
  for i := 0 to 3 do
    FComboPad.Items.Add('Gamepad ' + IntToStr(i));
  FComboPad.ItemIndex := 0;
  Lbl := TLabel.Create(Self);
  Lbl.Parent := BottomBar;
  Lbl.Text := 'Profile:';
  Lbl.Position.X := 200;
  Lbl.Position.Y := 20;
  Lbl.TextSettings.FontColor := TAlphaColors.White;
  Lbl.StyledSettings := [];
  FComboProfiles := TComboBox.Create(Self);
  FComboProfiles.Parent := BottomBar;
  FComboProfiles.Position.X := 260;
  FComboProfiles.Position.Y := 15;
  FComboProfiles.Width := 150;
  FBtnLoadProfile := TButton.Create(Self);
  FBtnLoadProfile.Parent := BottomBar;
  FBtnLoadProfile.Position.X := 420;
  FBtnLoadProfile.Position.Y := 15;
  FBtnLoadProfile.Text := 'Load';
  FBtnLoadProfile.OnClick := BtnLoadClick;
  FBtnSaveProfile := TButton.Create(Self);
  FBtnSaveProfile.Parent := BottomBar;
  FBtnSaveProfile.Position.X := 480;
  FBtnSaveProfile.Position.Y := 15;
  FBtnSaveProfile.Text := 'Save';
  FBtnSaveProfile.OnClick := BtnSaveClick;
  FBtnNewProfile := TButton.Create(Self);
  FBtnNewProfile.Parent := BottomBar;
  FBtnNewProfile.Position.X := 540;
  FBtnNewProfile.Position.Y := 15;
  FBtnNewProfile.Text := 'New...';
  FBtnNewProfile.OnClick := BtnNewClick;
  FBtnDefault := TButton.Create(Self);
  FBtnDefault.Parent := BottomBar;
  FBtnDefault.Position.X := 610;
  FBtnDefault.Position.Y := 15;
  FBtnDefault.Text := 'Defaults';
  FBtnDefault.OnClick := BtnDefaultClick;
  // Trackbars for Deadzones
  Lbl := TLabel.Create(Self);
  Lbl.Parent := BottomBar;
  Lbl.Text := 'DZ L:';
  Lbl.Position.X := 720;
  Lbl.Position.Y := 5;
  Lbl.TextSettings.FontColor := TAlphaColors.White;
  Lbl.StyledSettings := [];
  FTrackLeft := TTrackBar.Create(Self);
  FTrackLeft.Parent := BottomBar;
  FTrackLeft.Position.X := 750;
  FTrackLeft.Position.Y := 5;
  FTrackLeft.Width := 100;
  FTrackLeft.Height := 20;
  FTrackLeft.Min := 0;
  FTrackLeft.Max := 0.5;
  FTrackLeft.Frequency := 0.05;
  FTrackLeft.Value := 0.15;
  FTrackLeft.OnChange := OnTrackChange;
  Lbl := TLabel.Create(Self);
  Lbl.Parent := BottomBar;
  Lbl.Text := 'DZ R:';
  Lbl.Position.X := 720;
  Lbl.Position.Y := 30;
  Lbl.TextSettings.FontColor := TAlphaColors.White;
  Lbl.StyledSettings := [];
  FTrackRight := TTrackBar.Create(Self);
  FTrackRight.Parent := BottomBar;
  FTrackRight.Position.X := 750;
  FTrackRight.Position.Y := 30;
  FTrackRight.Width := 100;
  FTrackRight.Height := 20;
  FTrackRight.Min := 0;
  FTrackRight.Max := 0.5;
  FTrackRight.Frequency := 0.05;
  FTrackRight.Value := 0.15;
  FTrackRight.OnChange := OnTrackChange;
  // Deadzone visual circles
  FCircleLeft := TCircle.Create(Self);
  FCircleLeft.Parent := Self;
  FCircleLeft.Width := 60;
  FCircleLeft.Height := 60;
  FCircleLeft.Position.X := 210 + 30 - 30;
  FCircleLeft.Position.Y := 210 + 22 - 30;
  FCircleLeft.Fill.Color := TAlphaColors.Null;
  FCircleLeft.Stroke.Color := $66FFFFFF;
  FCircleLeft.Stroke.Thickness := 1.5;
  FCircleLeft.HitTest := False;
  FCircleRight := TCircle.Create(Self);
  FCircleRight.Parent := Self;
  FCircleRight.Width := 60;
  FCircleRight.Height := 60;
  FCircleRight.Position.X := 520 + 30 - 30;
  FCircleRight.Position.Y := 320 + 22 - 30;
  FCircleRight.Fill.Color := TAlphaColors.Null;
  FCircleRight.Stroke.Color := $66FFFFFF;
  FCircleRight.Stroke.Thickness := 1.5;
  FCircleRight.HitTest := False;
  FBlinkTimer := TTimer.Create(Self);
  FBlinkTimer.Interval := 200;
  FBlinkTimer.Enabled := False;
  FBlinkTimer.OnTimer := OnBlinkTimer;
  // Enable background image clicks for mapping
  FImgController.HitTest := True;
  FImgController.OnMouseDown := OnImageMouseDown;
end;

procedure TfrmGamepadSettings.OnImageMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  i: Integer;
  BestIdx: Integer;
  BestDist, Dist: Single;
  BtnCenterX, BtnCenterY: Single;
begin
  if FIsListening then
    Exit;
  // Find the closest button to the mouse click position
  BestIdx := -1;
  BestDist := 9999;
  for i := 0 to High(FButtonRecs) do
  begin
    BtnCenterX := FButtonRecs[i].Btn.Position.X + (FButtonRecs[i].Btn.Width / 2);
    BtnCenterY := FButtonRecs[i].Btn.Position.Y + (FButtonRecs[i].Btn.Height / 2);
    Dist := Sqrt(Sqr(X - BtnCenterX) + Sqr(Y - BtnCenterY));
    if Dist < BestDist then
    begin
      BestDist := Dist;
      BestIdx := i;
    end;
  end;
  // If a button is found within a 40px tolerance, start listening
  if (BestIdx <> -1) and (BestDist < 40) then
  begin
    FIsListening := True;
    FListeningElement := FButtonRecs[BestIdx].Element;
    FListeningBtn := FButtonRecs[BestIdx].Btn;
    FListeningBtn.TextSettings.FontColor := TAlphaColors.Red;
    FBlinkTimer.Enabled := True;
  end;
end;

procedure TfrmGamepadSettings.OnGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
var
  i: Integer;
  OrigX, OrigY: Single;
  OffX, OffY: Single;
  TargetElement: TGamepadElement;
  Ini: TIniFile;
  Section, KeyName, ValName, SelfEnumName: string;
  MappedElement: TGamepadElement;
begin
  if PadID <> GetSelectedPadID then
    Exit;
  // 1. LISTEN MODE: Assign mapping
  if FIsListening and Pressed then
  begin
    // Convert axis values to specific directions for cleaner mapping
    MappedElement := Element;
    if Element = geLeftStickX then
    begin
      if Value < -0.1 then
        MappedElement := geLeftStickLeft
      else if Value > 0.1 then
        MappedElement := geLeftStickRight;
    end
    else if Element = geLeftStickY then
    begin
      if Value < -0.1 then
        MappedElement := geLeftStickUp
      else if Value > 0.1 then
        MappedElement := geLeftStickDown;
    end
    else if Element = geRightStickX then
    begin
      if Value < -0.1 then
        MappedElement := geRightStickLeft
      else if Value > 0.1 then
        MappedElement := geRightStickRight;
    end
    else if Element = geRightStickY then
    begin
      if Value < -0.1 then
        MappedElement := geRightStickUp
      else if Value > 0.1 then
        MappedElement := geRightStickDown;
    end;
    SelfEnumName := GetEnumName(TypeInfo(TGamepadElement), Ord(FListeningElement));
    // Prevent mapping a button to itself
    if GetEnumName(TypeInfo(TGamepadElement), Ord(MappedElement)) = SelfEnumName then
    begin
      ValName := '';
    end
    else
    begin
      ValName := GetEnumName(TypeInfo(TGamepadElement), Ord(MappedElement));
      Ini := TIniFile.Create(GetProfileFile);
      try
        Section := 'Pad' + IntToStr(GetSelectedPadID);
        KeyName := 'Map_' + SelfEnumName;
        Ini.WriteString(Section, KeyName, ValName);
      finally
        Ini.Free;
      end;
    end;
    FBlinkTimer.Enabled := False;
    FIsListening := False;
    UpdateButtonLabel(FListeningBtn, ValName);
    Exit;
  end;
  // 2. STANDARD BUTTONS (including L3/R3 clicks)
  if not (Element in [geLeftStickX, geLeftStickY, geRightStickX, geRightStickY]) then
  begin
    HighlightButton(Element, Pressed);
    Exit;
  end;
  // 3. STICK MOVEMENT (with directional highlighting)
  if Element = geLeftStickX then
  begin
    TargetElement := geLeftStickClick;
    HighlightButton(geLeftStickLeft, Value < -0.1);
    HighlightButton(geLeftStickRight, Value > 0.1);
  end
  else if Element = geLeftStickY then
  begin
    TargetElement := geLeftStickClick;
    HighlightButton(geLeftStickUp, Value < -0.1);
    HighlightButton(geLeftStickDown, Value > 0.1);
  end
  else if Element = geRightStickX then
  begin
    TargetElement := geRightStickClick;
    HighlightButton(geRightStickLeft, Value < -0.1);
    HighlightButton(geRightStickRight, Value > 0.1);
  end
  else if Element = geRightStickY then
  begin
    TargetElement := geRightStickClick;
    HighlightButton(geRightStickUp, Value < -0.1);
    HighlightButton(geRightStickDown, Value > 0.1);
  end
  else
    Exit;
  // Visually move the L3/R3 buttons without altering their color
  for i := 0 to High(FButtonRecs) do
  begin
    if FButtonRecs[i].Element = TargetElement then
    begin
      OrigX := FButtonRecs[i].Btn.TagFloat;
      OrigY := FButtonRecs[i].Btn.Tag;
      OffX := 0;
      OffY := 0;
      if (Element = geLeftStickX) or (Element = geRightStickX) then
      begin
        if Abs(Value) > 0.1 then
          OffX := Value * 15
        else
          OffX := 0;
        OffY := FButtonRecs[i].Btn.Position.Y - OrigY;
      end
      else
      begin
        if Abs(Value) > 0.1 then
          OffY := Value * 15
        else
          OffY := 0;
        OffX := FButtonRecs[i].Btn.Position.X - OrigX;
      end;
      FButtonRecs[i].Btn.Position.X := OrigX + OffX;
      FButtonRecs[i].Btn.Position.Y := OrigY + OffY;
      Break;
    end;
  end;
end;

procedure TfrmGamepadSettings.HighlightButton(Element: TGamepadElement; Pressed: Boolean);
var
  i: Integer;
begin
  for i := 0 to High(FButtonRecs) do
  begin
    if FButtonRecs[i].Element = Element then
    begin
      if Pressed then
        FButtonRecs[i].Btn.TextSettings.FontColor := TAlphaColors.Aqua
      else
        FButtonRecs[i].Btn.TextSettings.FontColor := TAlphaColors.White;
      FButtonRecs[i].Btn.Repaint;
    end;
  end;
end;

function TfrmGamepadSettings.GetSelectedPadID: Integer;
begin
  Result := FComboPad.ItemIndex;
  if Result < 0 then
    Result := 0;
end;

procedure TfrmGamepadSettings.LoadProfilesToList;
var
  SR: TSearchRec;
  Ini: TIniFile;
  DefaultFile: string;
begin
  FComboProfiles.Items.Clear;
  if FindFirst(FProfilePath + '*.ini', faAnyFile, SR) = 0 then
  begin
    repeat
      FComboProfiles.Items.Add(ChangeFileExt(SR.Name, ''));
    until FindNext(SR) <> 0;
    System.SysUtils.FindClose(SR);
  end;
  // Create a default profile if none exist
  if FComboProfiles.Items.Count = 0 then
  begin
    FComboProfiles.Items.Add('Default');
    DefaultFile := FProfilePath + 'Default.ini';
    Ini := TIniFile.Create(DefaultFile);
    try
      Ini.WriteString('Settings', 'Name', 'Default');
      Ini.WriteFloat('Settings', 'Deadzone', 0.15);
    finally
      Ini.Free;
    end;
  end;
  FComboProfiles.ItemIndex := 0;
  LoadProfileSettings;
end;

function TfrmGamepadSettings.GetProfileFile: string;
begin
  if FComboProfiles.ItemIndex >= 0 then
    Result := FProfilePath + FComboProfiles.Items[FComboProfiles.ItemIndex] + '.ini'
  else
    Result := FProfilePath + 'Default.ini';
end;

procedure TfrmGamepadSettings.SaveCurrentMappings;
var
  Ini: TIniFile;
  i: Integer;
  Section, KeyName, ValName, OrigName: string;
begin
  if FComboProfiles.ItemIndex < 0 then
    Exit;
  Ini := TIniFile.Create(GetProfileFile);
  try
    Ini.WriteString('Settings', 'Name', FComboProfiles.Items[FComboProfiles.ItemIndex]);
    Ini.WriteFloat('Settings', 'Deadzone', FTrackLeft.Value);
    Section := 'Pad' + IntToStr(GetSelectedPadID);
    for i := 0 to High(FButtonRecs) do
    begin
      KeyName := 'Map_' + GetEnumName(TypeInfo(TGamepadElement), Ord(FButtonRecs[i].Element));
      OrigName := FButtonRecs[i].Btn.Hint;
      // If text matches original name, no mapping exists (or mapped to self)
      if FButtonRecs[i].Btn.Text = OrigName then
        Ini.DeleteKey(Section, KeyName)
      else
      begin
        ValName := FButtonRecs[i].Btn.Text;
        if Pos('= ', ValName) > 0 then
          ValName := Copy(ValName, Pos('= ', ValName) + 2, Length(ValName));
        Ini.WriteString(Section, KeyName, ValName);
      end;
    end;
  finally
    Ini.Free;
  end;
end;

procedure TfrmGamepadSettings.BtnSaveClick(Sender: TObject);
begin
  SaveCurrentMappings;
end;

procedure TfrmGamepadSettings.BtnLoadClick(Sender: TObject);
begin
  if FComboProfiles.ItemIndex < 0 then
    Exit;
  LoadProfileSettings;
end;

procedure TfrmGamepadSettings.BtnNewClick(Sender: TObject);
var
  NewName: string;
begin
  NewName := 'NewProfile1';
  if InputQuery('New Profile', 'Enter profile name:', NewName) then
  begin
    if (NewName <> '') and (FComboProfiles.Items.IndexOf(NewName) = -1) then
    begin
      FComboProfiles.Items.Add(NewName);
      FComboProfiles.ItemIndex := FComboProfiles.Items.Count - 1;
      SaveCurrentMappings;
    end;
  end;
end;

procedure TfrmGamepadSettings.BtnDefaultClick(Sender: TObject);
begin
  ResetToDefaults;
end;

procedure TfrmGamepadSettings.ResetToDefaults;
var
  i: Integer;
  Ini: TIniFile;
  Section: string;
begin
  for i := 0 to High(FButtonRecs) do
    FButtonRecs[i].Btn.Text := FButtonRecs[i].Btn.Hint;
  FTrackLeft.Value := 0.15;
  FTrackRight.Value := 0.15;
  OnTrackChange(Self);
  if FComboProfiles.ItemIndex >= 0 then
  begin
    Ini := TIniFile.Create(GetProfileFile);
    try
      Section := 'Pad' + IntToStr(GetSelectedPadID);
      Ini.EraseSection(Section);
      Ini.WriteFloat('Settings', 'Deadzone', 0.15);
    finally
      Ini.Free;
    end;
  end;
end;

procedure TfrmGamepadSettings.OnTrackChange(Sender: TObject);
var
  CircleSize: Single;
begin
  if not Visible then
    Exit;
  FCore.Deadzone := FTrackLeft.Value;
  // Update visual deadzone circles
  CircleSize := FTrackLeft.Value * 300;
  FCircleLeft.Width := CircleSize;
  FCircleLeft.Height := CircleSize;
  FCircleLeft.Position.X := (230 + 30) - (CircleSize / 2);
  FCircleLeft.Position.Y := (210 + 22) - (CircleSize / 2);
  CircleSize := FTrackRight.Value * 300;
  FCircleRight.Width := CircleSize;
  FCircleRight.Height := CircleSize;
  FCircleRight.Position.X := (520 + 30) - (CircleSize / 2);
  FCircleRight.Position.Y := (320 + 22) - (CircleSize / 2);
end;

procedure TfrmGamepadSettings.OnBtnMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Single);
var
  i: Integer;
begin
  if FIsListening then
    Exit;
  for i := 0 to High(FButtonRecs) do
  begin
    if FButtonRecs[i].Btn = Sender then
    begin
      FIsListening := True;
      FListeningElement := FButtonRecs[i].Element;
      FListeningBtn := FButtonRecs[i].Btn;
      FListeningBtn.TextSettings.FontColor := TAlphaColors.Red;
      FBlinkTimer.Enabled := True;
      Break;
    end;
  end;
end;

procedure TfrmGamepadSettings.OnBlinkTimer(Sender: TObject);
begin
  if FListeningBtn.TextSettings.FontColor = TAlphaColors.Red then
    FListeningBtn.TextSettings.FontColor := TAlphaColors.White
  else
    FListeningBtn.TextSettings.FontColor := TAlphaColors.Red;
end;

procedure TfrmGamepadSettings.LoadProfileSettings;
var
  Ini: TIniFile;
  DZ: Single;
  i: Integer;
  MapKey, MapVal: string;
  Section: string;
begin
  if FComboProfiles.ItemIndex < 0 then
    Exit;
  Ini := TIniFile.Create(GetProfileFile);
  try
    DZ := Ini.ReadFloat('Settings', 'Deadzone', 0.15);
    FTrackLeft.Value := DZ;
    FTrackRight.Value := DZ;
    OnTrackChange(Self);
    Section := 'Pad' + IntToStr(GetSelectedPadID);
    for i := 0 to High(FButtonRecs) do
    begin
      MapKey := 'Map_' + GetEnumName(TypeInfo(TGamepadElement), Ord(FButtonRecs[i].Element));
      MapVal := Ini.ReadString(Section, MapKey, '');
      UpdateButtonLabel(FButtonRecs[i].Btn, MapVal);
    end;
  finally
    Ini.Free;
  end;
end;

end.

