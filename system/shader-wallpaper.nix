{ pkgs, inputs, ... }:
let
  shaderWallpaper = import ./kde-shader-wallpaper.nix {
    inherit pkgs;
    src = inputs.kde-shader-wallpaper-src;
  };
in {
  environment.systemPackages = [ shaderWallpaper ];
  home-manager.users.niteris.programs.plasma.kscreenlocker.appearance.wallpaperCustomPlugin = {
    plugin = "online.knowmad.shaderwallpaper";
    config.General = {
      selectedShaderPath = "Shaders/Auroras.frag";
      running = true;
      shaderSpeed = 0.7;
      targetFps = 30;
      resolutionScale = 1.0;
      pauseMode = 3;
      mouseEnabled = false;
      audioEnabled = false;
    };
  };
}
