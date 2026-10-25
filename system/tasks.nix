{ pkgs, ... }:
let
  # The Tasks panel widget: a checklist kept as TASKS.md in a clone of
  # github.com/zackees/tasks (~/dev/tasks), pulled on refresh and pushed on
  # every edit. Ruff gates the backend like calendar-py's.
  tasksCli = pkgs.runCommand "tasks-cli" { nativeBuildInputs = [ pkgs.ruff ]; } ''
    ruff check --no-cache ${./tasks/tasks_cli.py}
    install -Dm644 ${./tasks/tasks_cli.py} $out/tasks_cli.py
  '';
  tasks = pkgs.writeShellApplication {
    name = "tasks";
    # git's https pushes authenticate through gh's credential helper.
    runtimeInputs = [ pkgs.git pkgs.gh ];
    text = ''
      exec ${pkgs.python3}/bin/python ${tasksCli}/tasks_cli.py "$@"
    '';
  };
  tasksApplet = pkgs.runCommand "tasks-applet" { } ''
    mkdir -p $out
    cp -r ${./tasks/applet}/. $out/
    substituteInPlace $out/contents/ui/main.qml \
      --replace-fail '@TASKS@' '${tasks}/bin/tasks'
  '';
in {
  home-manager.users.niteris.home.file.".local/share/plasma/plasmoids/org.niteris.tasks".source = tasksApplet;
  environment.systemPackages = [ tasks ];
}
