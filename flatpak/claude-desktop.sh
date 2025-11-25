#!/bin/bash
export ELECTRON_FORCE_IS_PACKAGED=true

cd /app/lib/electron || exit 1
exec zypak-wrapper ./electron \
    /app/lib/resources/app.asar \
    "$@"
