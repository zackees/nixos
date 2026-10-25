{ pkgs, ... }:
let
  # The Tasks panel widget: a checklist kept as TASKS.md in a clone of
  # github.com/zackees/tasks (~/dev/tasks). Edits commit locally; the
  # tasks-sync timer below pulls and pushes. Ruff gates the backend like
  # calendar-py's.
  tasksCli = pkgs.runCommand "tasks-cli" { nativeBuildInputs = [ pkgs.ruff ]; } ''
    ruff check --no-cache ${./tasks/tasks_cli.py}
    install -Dm644 ${./tasks/tasks_cli.py} $out/tasks_cli.py
  '';
  tasks = pkgs.writeShellApplication {
    name = "tasks";
    # git's https pushes authenticate through gh's credential helper.
    runtimeInputs = [ pkgs.git pkgs.gh pkgs.uv ];
    # Python here always runs through uv: the script declares its own
    # dependencies inline (PEP 723) and uv resolves them into its cache.
    # only-managed keeps it on uv's CPython, never a /nix/store python that
    # garbage collection can delete out from under the cached environment.
    text = ''
      exec uv run --quiet --python-preference only-managed --script ${tasksCli}/tasks_cli.py "$@"
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

  # The only network traffic: pull (rebase, union-merged) and push four
  # times a day. Edits in the widget just commit locally in between.
  # Persistent catches up a slot missed while the machine was off.
  systemd.user.services.tasks-sync = {
    description = "Sync ~/dev/tasks with github.com/zackees/tasks";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${tasks}/bin/tasks sync";
    };
  };
  systemd.user.timers.tasks-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 00,06,12,18:00:00";
      Persistent = true;
    };
  };
}
