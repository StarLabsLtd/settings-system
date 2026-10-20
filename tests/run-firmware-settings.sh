#!/bin/sh
set -eu
exec dbus-run-session -- xvfb-run -a "$1"
