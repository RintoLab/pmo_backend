#!/bin/sh
# A self-contained echoing stand-in for `pi --mode rpc`.
#
# The channel's own `create` path builds the argv, so it cannot hand over a
# behaviour file the way fake_pi.sh expects -- the behaviour is baked in here
# instead. Kept as a checked-in file so it is scanned once by macOS rather than
# on every run.
while IFS= read -r line; do
  id=$(printf '%s' "$line" | sed 's/.*"id":"\([^"]*\)".*/\1/')
  printf '{"type":"response","id":"%s","success":true,"data":{"ok":true}}\n' "$id"
done
