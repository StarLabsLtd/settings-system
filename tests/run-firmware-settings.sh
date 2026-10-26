#!/bin/sh
set -eu
export LIBGL_ALWAYS_SOFTWARE=1
exec dbus-run-session -- xvfb-run -a "$1"
