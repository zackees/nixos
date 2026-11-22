{ pkgs, ... }:
let
  # Elgato Wave:3 (USB 0fd9:0070), the microphone voxtype dictates from.
  vendor = "0fd9";
  product = "0070";
  card = "alsa_card.usb-Elgato_Systems_Elgato_Wave_3_BS38J1A03981-00";
  profile = "output:analog-stereo+input:mono-fallback";
in
{
  # ── The Wave:3 hangs; power-cycle its USB port and say so ──
  # On 2026-11-21 the mic's firmware stopped answering mid-session: every
  # stream start failed in the kernel with `usb_set_interface failed (-110)`,
  # PipeWire switched the card's profile to "off", the default input fell
  # back to the Cam Link 4K (a capture card with no audio), and voxtype
  # recorded pure digital silence on every press -- "No speech detected ...
  # avg rms 0.0000" -- for hours, with nothing on screen. A USB reset
  # (authorized 0/1) was not enough, the device then refused even
  # SET_CONFIGURATION; cutting the port's power, as a replug does, cleared it.
  #
  # The trigger is rms exactly 0.0000. A working mic never produces that,
  # however quiet the room: its noise floor alone reads rms 20-60. So a
  # press where you simply did not speak does not set this off.

  # Root half: power-cycle whichever hub port the Wave:3 is on (found by USB
  # id, not by a hard-coded port, so moving the cable does not break it).
  systemd.services.wave3-power-cycle = {
    description = "Power-cycle the Elgato Wave:3's USB port";
    path = [ pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      for d in /sys/bus/usb/devices/*; do
        [ "$(cat "$d/idVendor" 2>/dev/null)" = ${vendor} ] &&
          [ "$(cat "$d/idProduct" 2>/dev/null)" = ${product} ] && dev="$d" && break
      done
      if [ -z "''${dev:-}" ] || [ ! -e "$dev/port/disable" ]; then
        echo "Wave:3 not found on USB, or its port cannot be power-switched" >&2
        exit 1
      fi
      port="$(readlink -f "$dev/port")"
      echo "power-cycling $port"
      echo 1 > "$port/disable"
      sleep 3
      echo 0 > "$port/disable"
    '';
  };
  # ...which this user may start without a password dialog, and only it.
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          action.lookup("unit") == "wave3-power-cycle.service" &&
          action.lookup("verb") == "start" && subject.user == "niteris")
        return polkit.Result.YES;
    });
  '';

  # User half: repair, put the card's profile back, prove there is signal,
  # and pop up what happened. One repair per 10 minutes, so a mic that a
  # power cycle cannot fix produces a message rather than a loop.
  systemd.user.services.wave3-heal = {
    description = "Repair a hung Elgato Wave:3";
    path = with pkgs; [ systemd libnotify pulseaudio pipewire coreutils findutils gnugrep ];
    serviceConfig.Type = "oneshot";
    script = ''
      stamp="$XDG_RUNTIME_DIR/wave3-heal.stamp"
      if find "$stamp" -mmin -10 2>/dev/null | grep -q .; then
        echo "repaired less than 10 minutes ago; not repeating" >&2
        exit 0
      fi
      touch "$stamp"
      notify-send -a voxtype -i audio-input-microphone \
        "Repairing microphone…" \
        "Dictation heard digital silence: the Wave:3 has hung. Power-cycling it."

      if ! systemctl start wave3-power-cycle.service; then
        notify-send -a voxtype -u critical -i dialog-error \
          "Microphone repair failed" \
          "The Wave:3 is not on USB, or its port could not be power-cycled. Replug it."
        exit 1
      fi

      # Wait for PipeWire to see the card again (normally 2-4 s).
      for _ in $(seq 30); do
        pactl list cards short | grep -q ${card} && break
        sleep 1
      done
      sleep 2
      pactl set-card-profile ${card} ${profile} || true
      sleep 2
      src="$(pactl list sources short | grep -F ${card} -m1 | cut -f2)"
      src="''${src:-$(pactl list sources short | grep Elgato_Wave_3 | grep -v monitor | head -1 | cut -f2)}"
      [ -n "$src" ] && pactl set-default-source "$src"

      # Prove it: the default source must not record flat zero.
      wav="$XDG_RUNTIME_DIR/wave3-heal.wav"
      timeout 3 pw-record --rate 16000 --channels 1 --format s16 "$wav" || true
      # Any non-zero byte after the 44-byte WAV header is signal.
      live="$(tail -c +45 "$wav" 2>/dev/null | tr -d '\000' | head -c 1 | wc -c)"
      rm -f "$wav"
      echo "after repair: source=$src live=$live"
      if [ -n "$src" ] && [ "$live" = 1 ]; then
        notify-send -a voxtype -i audio-input-microphone \
          "Microphone repaired" "The Wave:3 is back. Press the dictation key again."
      else
        notify-send -a voxtype -u critical -i dialog-error \
          "Microphone repair failed" \
          "The Wave:3 still records silence after a power cycle. Unplug it and plug it back in."
        exit 1
      fi
    '';
  };

  # Watches voxtype's log and starts the repair on a dead-silent recording.
  systemd.user.services.wave3-watch = {
    description = "Start wave3-heal when voxtype records digital silence";
    after = [ "voxtype.service" ];
    wantedBy = [ "graphical-session.target" ];
    partOf = [ "graphical-session.target" ];
    path = [ pkgs.systemd pkgs.gnugrep ];
    script = ''
      journalctl --user -u voxtype.service -f -n 0 -o cat |
        grep --line-buffered -F 'avg rms 0.0000' |
        while read -r _; do
          systemctl --user start --no-block wave3-heal.service
        done
    '';
    serviceConfig = {
      Restart = "always";
      RestartSec = 5;
    };
  };
}
