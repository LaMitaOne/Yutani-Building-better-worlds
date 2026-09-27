{*******************************************************************************
  MRX Gamepad Core
*******************************************************************************}
{ MRX-Gamepad-Core v0.1                                                        }
{ by Lara Miriam Tamy Reschke                                                  }
{                                                                              }
{------------------------------------------------------------------------------}


unit uMRX_GamepadCoreMain;

interface

uses
  System.SysUtils, System.Types, System.UITypes, System.Classes, System.Variants,
  Winapi.Windows, Winapi.Messages, Vcl.Forms, Vcl.Controls, Vcl.Graphics,
  Vcl.Dialogs, Vcl.StdCtrls, Vcl.ComCtrls, Vcl.ExtCtrls, uMRX_GamepadCore,
  uMRX_GamepadSettings;

type
  /// <summary>
  /// Demo form showing how to use the TMRXGamepadCore and Settings.
  /// </summary>
  TForm2 = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    FGamepadCore: TMRXGamepadCore;
    FMemo: TMemo;
    FBtnSettings: TButton;
    FBtnRumble: TButton;
    FBtnRumble2: TButton;
    procedure OnGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
    procedure BtnSettingsClick(Sender: TObject);
    procedure BtnRumbleClick(Sender: TObject);
    procedure BtnRumble2Click(Sender: TObject);
  public
    { Public declarations }
  end;

var
  Form2: TForm2;

implementation
{$R *.dfm}

procedure TForm2.FormCreate(Sender: TObject);
begin
  Caption := 'MRX Gamepad Core';
  ClientWidth := 600;
  ClientHeight := 400;
  Position := poScreenCenter;
  Color := clBtnFace;

  // Rumble Test Buttons
  FBtnRumble := TButton.Create(Self);
  FBtnRumble.Parent := Self;
  FBtnRumble.Caption := 'Rumble Test (Player 0)';
  FBtnRumble.Align := alTop;
  FBtnRumble.Height := 40;
  FBtnRumble.OnClick := BtnRumbleClick;

  FBtnRumble2 := TButton.Create(Self);
  FBtnRumble2.Parent := Self;
  FBtnRumble2.Caption := 'Rumble Test (Player 1)';
  FBtnRumble2.Align := alTop;
  FBtnRumble2.Height := 40;
  FBtnRumble2.OnClick := BtnRumble2Click;

  // Settings Button
  FBtnSettings := TButton.Create(Self);
  FBtnSettings.Parent := Self;
  FBtnSettings.Caption := 'Open Settings';
  FBtnSettings.Align := alBottom;
  FBtnSettings.Height := 40;
  FBtnSettings.OnClick := BtnSettingsClick;

  // Log Memo
  FMemo := TMemo.Create(Self);
  FMemo.Parent := Self;
  FMemo.Align := alClient;
  FMemo.ScrollBars := ssBoth;
  FMemo.Lines.Clear;
  FMemo.Lines.Add('MRX Gamepad Core');
  FMemo.Lines.Add('Waiting for SDL3...');

  // Initialize Core
  FGamepadCore := TMRXGamepadCore.Create;
  FGamepadCore.OnInputEvent := OnGamepadInput;
  try
    FGamepadCore.Initialize;
    FMemo.Lines.Add('SDL3 loaded successfully! Press buttons on your gamepad.');
  except
    on E: Exception do
      FMemo.Lines.Add('ERROR: ' + E.Message);
  end;
end;

procedure TForm2.FormDestroy(Sender: TObject);
begin
  FGamepadCore.Free;
end;

procedure TForm2.OnGamepadInput(Sender: TObject; PadID: Integer; Element: TGamepadElement; Pressed: Boolean; Value: Single);
var
  BtnName, StateStr: string;
begin
  BtnName := 'Unknown';
  case Element of
    geBtnA:
      BtnName := 'A';
    geBtnB:
      BtnName := 'B';
    geBtnX:
      BtnName := 'X';
    geBtnY:
      BtnName := 'Y';
    geLB:
      BtnName := 'LB';
    geRB:
      BtnName := 'RB';
    geStart:
      BtnName := 'Start';
    geBack:
      BtnName := 'Back';
    geGuide:
      BtnName := 'Guide (Xbox)';
    geLeftStickClick:
      BtnName := 'L3 (Stick Click)';
    geRightStickClick:
      BtnName := 'R3 (Stick Click)';
    gePadUp:
      BtnName := 'D-Pad Up';
    gePadDown:
      BtnName := 'D-Pad Down';
    gePadLeft:
      BtnName := 'D-Pad Left';
    gePadRight:
      BtnName := 'D-Pad Right';
    geExtra1:
      BtnName := 'Extra1 (Share/Paddle)';
    geExtra2:
      BtnName := 'Extra2 (Paddle)';
    geExtra3:
      BtnName := 'Extra3 (Paddle)';
    geExtra4:
      BtnName := 'Extra4 (Paddle)';
    geLeftStickX:
      BtnName := 'Left Stick X';
    geLeftStickY:
      BtnName := 'Left Stick Y';
    geRightStickX:
      BtnName := 'Right Stick X';
    geRightStickY:
      BtnName := 'Right Stick Y';
    geLT:
      BtnName := 'Trigger Left (LT)';
    geRT:
      BtnName := 'Trigger Right (RT)';
  end;
  // Log analog axes only if value exceeds threshold to prevent spam
  if Element in [geLeftStickX, geLeftStickY, geRightStickX, geRightStickY, geLT, geRT] then
  begin
    if Abs(Value) > 0.1 then
      FMemo.Lines.Add(Format('[Pad %d] %s: %.2f', [PadID, BtnName, Value]));
  end
  else
  begin
    // Standard buttons
    if Pressed then
      StateStr := 'pressed'
    else
      StateStr := 'released';
    FMemo.Lines.Add(Format('[Pad %d] %s %s', [PadID, BtnName, StateStr]));
  end;
end;

procedure TForm2.BtnSettingsClick(Sender: TObject);
var
  FrmSettings: TfrmGamepadSettings;
begin
  // Open settings form modally
  FrmSettings := TfrmGamepadSettings.Create(Self, FGamepadCore);
  try
    FrmSettings.ShowModal;
  finally
    FrmSettings.Free;
  end;
end;

procedure TForm2.BtnRumbleClick(Sender: TObject);
begin
  FGamepadCore.Rumble(0, 65535, 65535, 500);
end;

procedure TForm2.BtnRumble2Click(Sender: TObject);
begin
  FGamepadCore.Rumble(1, 65535, 65535, 500);
end;

end.

