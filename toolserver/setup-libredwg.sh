#!/bin/bash
# ==============================================================================
# setup-libredwg.sh -- GNU LibreDWG (dwg2dxf), the DWG reader of the Extrusion module
#
#   sudo /opt/<domain>/setup-libredwg.sh           (the domain is this directory's name)
#   sudo /opt/<domain>/setup-libredwg.sh --force   (build again although dwg2dxf is there)
#
# Repeatable. Started from the Toolserver: Environment > Server-Config > Licences,
# group Extrusion, row LibreDWG, button Install (Verwalter job "setup").
#
# What it does: fetches the pinned source release from the publisher on GitHub,
# checks its SHA-256 against the release's own dist.sha256, builds dwg2dxf in a
# THROWAWAY container of the same base image as the Toolserver (identical glibc,
# no memory limit) and puts the program at /opt/toolserver/bin/dwg2dxf -- inside
# the Toolserver /app/bin/dwg2dxf, the command in system_config
# extrusion.dwg_converter_cmd. The running Toolserver gets neither build packages
# nor build load. Nothing is passed on: every server fetches its own copy.
#
# LICENCE: GPL-3.0-or-later. dwg2dxf runs as a program of its own; the Toolserver
# calls it through the command line and does not link it. Whoever passes the
# program on owes the source -- this script fetches it from the publisher and
# passes nothing on. The register row libredwg (governance.third_party_component)
# carries the text the Licences screen shows before the button is pressed.
#
# An existing /opt/toolserver/bin/dwg2dxf is kept (build again with --force) and
# only marked installed in the catalogue -- the server where the old manual script
# scripts/install_dwg_converter.sh built it needs no second build.
#
# 2026-09-28 (GAP-LIC-FREMDPROGRAMME-JE-MODUL-01, Toolserver v2023): taken over from
# scripts/install_dwg_converter.sh of the Toolserver, which is removed there.
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TOOLSERVER_DIR="/opt/toolserver"
readonly BIN_DIR="${TOOLSERVER_DIR}/bin"
readonly PROGRAM="${BIN_DIR}/dwg2dxf"
readonly CONTAINER="toolserver"
# Same base image as the Toolserver container (docker-compose.toolserver.yml).
readonly IMAGE="python:3.11-slim-bookworm"
readonly LIBREDWG_VERSION="0.14.8464"
readonly KEY="libredwg"

FORCE=0
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        *) echo "Unknown option: $arg (known: --force)"; exit 1 ;;
    esac
done

ok()   { echo -e "\033[1;32m[OK]\033[0m $1"; }
info() { echo -e "\033[1;36m[INFO]\033[0m $1"; }
err()  { echo -e "\033[1;31m[ERROR]\033[0m $1"; }

# shellcheck source=toolserver-link.sh
if [[ -f "${SCRIPT_DIR}/toolserver-link.sh" ]]; then
    . "${SCRIPT_DIR}/toolserver-link.sh"
else
    ts_catalogue_installed() { echo "[WARN] toolserver-link.sh missing in ${SCRIPT_DIR} -- catalogue not updated."; }
fi

if [[ ! -d "$TOOLSERVER_DIR" ]]; then
    err "No Toolserver in ${TOOLSERVER_DIR} -- LibreDWG belongs to its Extrusion module."
    exit 1
fi

if [[ $FORCE -eq 0 && -x "$PROGRAM" ]]; then
    ok "dwg2dxf is already there: ${PROGRAM} (build again with --force)."
    "$PROGRAM" --version 2>/dev/null | head -n 1 || true
    ts_catalogue_installed "$KEY"
    exit 0
fi

mkdir -p "$BIN_DIR"
info "Building LibreDWG ${LIBREDWG_VERSION} in a throwaway container (image ${IMAGE}, about 3-6 minutes)."
docker run --rm -e "V=${LIBREDWG_VERSION}" -v "${BIN_DIR}:/out" "$IMAGE" bash -ceu '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends build-essential curl ca-certificates >/dev/null
    mkdir -p /tmp/build && cd /tmp/build
    BASE="https://github.com/LibreDWG/libredwg/releases/download/$V"
    echo "-- Download $BASE/libredwg-$V.tar.gz"
    curl -fsSL -o libredwg.tar.gz "$BASE/libredwg-$V.tar.gz"
    curl -fsSL -o dist.sha256     "$BASE/dist.sha256"
    SOLL=$(grep "libredwg-$V.tar.gz" dist.sha256 | awk "{print \$1}")
    IST=$(sha256sum libredwg.tar.gz | awk "{print \$1}")
    if [ -z "$SOLL" ] || [ "$SOLL" != "$IST" ]; then
        echo "SHA-256 does not match (expected=$SOLL, actual=$IST)" >&2
        exit 1
    fi
    echo "-- SHA-256 ok, building (-j2, -O1: keeps memory low)"
    tar xzf libredwg.tar.gz
    cd "libredwg-$V"
    ./configure -q --disable-shared --disable-bindings --disable-docs --program-prefix="" >/dev/null
    make -j2 CFLAGS="-O1 -g0" >/dev/null
    cp programs/dwg2dxf /out/dwg2dxf
    chmod 755 /out/dwg2dxf
'
ok "Built: ${PROGRAM}"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONTAINER"; then
    docker exec "$CONTAINER" /app/bin/dwg2dxf --version | head -n 1
    ok "The Toolserver reaches it as /app/bin/dwg2dxf."
fi
ts_catalogue_installed "$KEY"
