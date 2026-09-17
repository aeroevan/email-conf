#!/bin/sh
set -eu
cd "$(dirname "$0")"

# Inside a toolbox container, use:  PODMAN="podman --remote" ./build.sh
PODMAN="${PODMAN:-podman}"

mkdir -p "$HOME/.local/state/pizauth-run"

$PODMAN build -t local/email-pizauth:latest -f pizauth/Containerfile pizauth/
$PODMAN build -t local/email-msmtp:latest -f msmtp/Containerfile msmtp/
