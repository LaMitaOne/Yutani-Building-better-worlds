program Yutani;

uses
  Vcl.Forms,
  Yutani.Core in 'Yutani.Core.pas',
  JoltPhysics in 'JoltPhysics.pas',
  Yutani.Core.ModelEngine in 'Yutani.Core.ModelEngine.pas',
  Yutani.Core.View in 'Yutani.Core.View.pas' {YutaniWindow},
  VCL3D in 'VCL3D.pas',
  MPVManager in 'MPVManager.pas',
  MPVEmbedded in 'MPVEmbedded.pas',
  uMRX_GamepadCore in 'uMRX_GamepadCore.pas',
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
  uMRX_GamepadSettings in 'uMRX_GamepadSettings.pas' {frmGamepadSettings};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TYutaniWindow, YutaniWindow);
  Application.CreateForm(TfrmGamepadSettings, frmGamepadSettings);
  Application.Run;
end.
