program Yutani;

uses
  Vcl.Forms,
  Yutani.Core in 'Yutani.Core.pas',
  JoltPhysics in 'JoltPhysics.pas',
  Yutani.Core.ModelEngine in 'Yutani.Core.ModelEngine.pas',
  Yutani.Core.View in 'Yutani.Core.View.pas' {YutaniWindow},
  Yutani.VCL3D in 'Yutani.VCL3D.pas',
  Yutani.Avatar.Controls.GamepadCore in 'Yutani.Avatar.Controls.GamepadCore.pas',
  Yutani.SkiaIntro in 'Yutani.SkiaIntro.pas',
  Yutani.Render.VoronoiFracture in 'Yutani.Render.VoronoiFracture.pas',
  Yutani.Render.Shaders in 'Yutani.Render.Shaders.pas',
  Yutani.Worlds.Island in 'Yutani.Worlds.Island.pas',
  Yutani.Render.Particles in 'Yutani.Render.Particles.pas',
  Yutani.AliveHighlighter3D in 'Yutani.AliveHighlighter3D.pas',
  Yutani.Render.NanoFog in 'Yutani.Render.NanoFog.pas',
  Yutani.Worlds.Space in 'Yutani.Worlds.Space.pas',
  Yutani.Worlds.Space.Textures in 'Yutani.Worlds.Space.Textures.pas',
  Yutani.Render.LoadingScreen in 'Yutani.Render.LoadingScreen.pas',
  Yutani.Avatar.Controls in 'Yutani.Avatar.Controls.pas',
  Yutani.Avatar.Animations in 'Yutani.Avatar.Animations.pas',
  Yutani.Audio in 'Yutani.Audio.pas',
  Yutani.Avatar.Controls.GamepadSettings in 'Yutani.Avatar.Controls.GamepadSettings.pas' {frmGamepadSettings},
  Yutani.Video.MPV in 'Yutani.Video.MPV.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TYutaniWindow, YutaniWindow);
  Application.CreateForm(TfrmGamepadSettings, frmGamepadSettings);
  Application.Run;
end.
