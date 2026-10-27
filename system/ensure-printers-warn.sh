#!/run/current-system/sw/bin/bash
# Warn about declared CUPS queues that ensure-printers could not create.
#
# ensure-printers.service calls this from ExecStartPost with every declared
# queue name. lpadmin exits 1 when the device is unreachable (printer switched
# off, .local not routed), and that exit code is now treated as success --
# a printer being off must not fail a whole system rebuild, which is what used
# to happen: `nixos-rebuild switch` returned exit 4 and any real fault hid
# behind it.
#
# The check is a real query, not an inference from the exit code: "does the
# queue exist in CUPS" is the property that matters, and it is also right when
# lpadmin succeeded but CUPS was not up yet.
#
# Must never fail the unit. It runs with a "-" prefix in ExecStartPost and
# exits 0 on every path.

missing=()
for printer in "$@"; do
  /run/current-system/sw/bin/lpstat -p "$printer" >/dev/null 2>&1 || missing+=("$printer")
done

if [ "${#missing[@]}" -gt 0 ]; then
  message="warning: printers not configured (device unreachable?): ${missing[*]}"
  echo "$message" >&2
  # Priority goes to the journal as well, so it is visible without the unit's
  # own stderr being open on a console.
  if [ -x /run/current-system/sw/bin/logger ]; then
    /run/current-system/sw/bin/logger -t ensure-printers -p user.warning \
      "printers not configured (device unreachable?): ${missing[*]}"
  fi
fi

exit 0
