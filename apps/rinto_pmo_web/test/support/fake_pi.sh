#!/bin/sh
# Stands in for `pi --mode rpc` in RintoPMOWeb.PiSessionChannelTest.
#
# The behaviour under test is the last argument: a plain shell file this
# sources. Keeping the *executable* constant is the point -- macOS scans a
# newly created executable on its first execve (~300ms, and serialised
# system-wide), so a fresh script per test would tax every test in the file.
# A sourced data file is never exec'd and costs nothing to create.
for behaviour; do :; done
. "$behaviour"
