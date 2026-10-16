#!/usr/bin/env bash
# Rotate pf-synology@pf-synology.lan's login password to a random value kept ONLY in the
# laptop keyring (GNOME keyring via secret-tool). The current password is typed once at a
# hidden prompt and is never stored. Secrets travel only over stdin, never argv or logs.
# Keyring entry afterwards: service=pf-synology.lan user=pf-synology state=current
set -euo pipefail
HOST=pf-synology.lan
ACCT=pf-synology
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 "$ACCT@$HOST")
ATTR=(service "$HOST" user "$ACCT")

command -v secret-tool >/dev/null || { echo "REFUSE: secret-tool missing"; exit 2; }
"${SSH[@]}" true || { echo "REFUSE: SSH key login to $ACCT@$HOST failed"; exit 2; }

if [ -n "${PF_ROTATE_CURRENT_FILE:-}" ]; then
  # One-shot: read the current password from a private file and delete it immediately.
  cur=$(head -n1 "$PF_ROTATE_CURRENT_FILE"); shred -u "$PF_ROTATE_CURRENT_FILE" 2>/dev/null || rm -f "$PF_ROTATE_CURRENT_FILE"
else
  read -r -s -p "Current password for $ACCT@$HOST (typed once, never stored): " cur </dev/tty
  echo
fi
[ -n "$cur" ] || { echo "REFUSE: empty password"; exit 2; }

# 1. Prove the current password works before touching anything.
if ! printf '%s\n' "$cur" | "${SSH[@]}" 'sudo -S -p "" -k true' 2>/dev/null; then
  unset cur; echo "REFUSE: current password rejected by sudo; nothing changed"; exit 3
fi

# 2. Generate the new password and save it to the keyring FIRST, so it can never be lost.
new=$(python3 -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(40)))')
printf '%s' "$new" | secret-tool store --label="pf-synology login (pending rotation)" "${ATTR[@]}" state pending
[ "$(secret-tool lookup "${ATTR[@]}" state pending)" = "$new" ] || { unset cur new; echo "REFUSE: keyring write did not verify; nothing changed on the host"; exit 4; }

# 3. Change it on the host. sudo -S reads exactly the first line; chpasswd reads the rest.
if ! printf '%s\n%s:%s\n' "$cur" "$ACCT" "$new" | "${SSH[@]}" 'sudo -S -p "" -k chpasswd' 2>/dev/null; then
  unset cur new; echo "FAIL: chpasswd failed; host password unchanged; pending keyring entry left for inspection"; exit 5
fi

# 4. Verify the new password works, and that the old one no longer does.
printf '%s\n' "$new" | "${SSH[@]}" 'sudo -S -p "" -k true' 2>/dev/null \
  || { unset cur new; echo "FAIL: new password not accepted; the keyring 'pending' entry holds the value that was set"; exit 6; }
if printf '%s\n' "$cur" | "${SSH[@]}" 'sudo -S -p "" -k true' 2>/dev/null; then
  unset cur new; echo "FAIL: old password still accepted"; exit 7
fi

# 5. Promote pending -> current, and drop the pending entry.
printf '%s' "$new" | secret-tool store --label="pf-synology login" "${ATTR[@]}" state current
[ "$(secret-tool lookup "${ATTR[@]}" state current)" = "$new" ] || { unset cur new; echo "FAIL: could not verify the current keyring entry; the pending entry is kept"; exit 8; }
secret-tool clear "${ATTR[@]}" state pending
unset cur new
echo "ROTATED: 40-char random password set and verified; stored only in the laptop keyring (service=$HOST user=$ACCT state=current)."
