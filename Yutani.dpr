program Yutani;

uses
  Vcl.Forms,
  RaylibSandbox in 'RaylibSandbox.pas',
  JoltPhysics in 'JoltPhysics.pas',
  ModelEngine in 'ModelEngine.pas',
  Unit1 in 'Unit1.pas' {Form1},
  VCL3D in 'VCL3D.pas',
  MPVManager in 'MPVManager.pas',
  MPVEmbedded in 'MPVEmbedded.pas',
  uMRX_GamepadCore in 'uMRX_GamepadCore.pas',
  uMRX_GamepadCoreMain in 'uMRX_GamepadCoreMain.pas' {Form2},
  uYutaniSkiaIntro in 'uYutaniSkiaIntro.pas',
  Yutani.VoronoiFracture in 'Yutani.VoronoiFracture.pas',
  Yutani.Render.Shaders in 'Yutani.Render.Shaders.pas',
  Yutani.Worlds.Island in 'Yutani.Worlds.Island.pas',
  Yutani.Render.Particles in 'Yutani.Render.Particles.pas',
  Yutani.AliveHighlighter3D in 'Yutani.AliveHighlighter3D.pas',
  Yutani.Render.NanoFog in 'Yutani.Render.NanoFog.pas',
  Yutani.Worlds.Space in 'Yutani.Worlds.Space.pas',
  Yutani.Worlds.Space.Textures in 'Yutani.Worlds.Space.Textures.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm1, Form1);
  Application.CreateForm(TForm2, Form2);
  Application.Run;
end.
