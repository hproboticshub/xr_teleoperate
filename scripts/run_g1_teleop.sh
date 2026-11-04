#!/usr/bin/env bash
# Start the teleimager server on the G1's PC2 (Jetson) over SSH, then run the
# teleoperation program locally. Every argument is forwarded to
# teleop/teleop_hand_and_arm.py, except the wrapper flags below.
#
# Usage:
#   scripts/run_g1_teleop.sh [wrapper flags] [teleop flags...]
#
# Examples:
#   scripts/run_g1_teleop.sh --motion --network-interface enxf44dad0705a2
#   scripts/run_g1_teleop.sh --arm G1_29 --ee dex3 --input-mode controller --record
#
# Wrapper flags (consumed here, not forwarded):
#   --no-server        do not touch the image server (assume it is running)
#   --restart-server   kill the running image server and start it again
#   --stop-server      stop the image server on PC2 and exit
#
# Environment overrides:
#   G1_SSH_HOST      ssh host/alias of PC2          (default: g1-jetson)
#   G1_REMOTE_START  command on PC2 that (re)starts the image server
#                                                   (default: ~/start_teleimager.sh)
#   G1_LOCAL_ENV     micromamba/conda env locally   (default: tv)
#   G1_IMG_PORT      zmq port used to check the server is up (default: 55555)
#   G1_REMOTE_LOG    server log file on PC2         (default: /tmp/teleimager.log)

set -euo pipefail

SSH_HOST="${G1_SSH_HOST:-g1-jetson}"
REMOTE_START="${G1_REMOTE_START:-~/start_teleimager.sh}"
LOCAL_ENV="${G1_LOCAL_ENV:-tv}"
IMG_PORT="${G1_IMG_PORT:-55555}"
REMOTE_LOG="${G1_REMOTE_LOG:-/tmp/teleimager.log}"
SERVER_WAIT_S=40

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

# --- wrapper flags ---------------------------------------------------------
START_SERVER=1
RESTART_SERVER=0
STOP_ONLY=0
TELEOP_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --no-server)      START_SERVER=0 ;;
        --restart-server) RESTART_SERVER=1 ;;
        --stop-server)    STOP_ONLY=1 ;;
        *)                TELEOP_ARGS+=("$arg") ;;
    esac
done

# --- helpers ---------------------------------------------------------------
log() { printf '\033[1;34m[g1]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[g1] %s\033[0m\n' "$*" >&2; exit 1; }

remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }

# The [x] trick keeps pgrep from matching its own command line.
SERVER_PATTERN='[t]eleimager.image_server'
server_running() { remote "pgrep -f '$SERVER_PATTERN' >/dev/null"; }
stop_server()    { remote "pkill -f '$SERVER_PATTERN' || true"; }

wait_for_port() {
    local host
    host="$(ssh -G "$SSH_HOST" | awk '/^hostname /{print $2}')"
    for ((i = 0; i < SERVER_WAIT_S; i++)); do
        if timeout 1 bash -c ">/dev/tcp/$host/$IMG_PORT" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# --- image server on PC2 ---------------------------------------------------
remote true 2>/dev/null || die "Cannot ssh to '$SSH_HOST' without a password. Check the robot is reachable and the key is installed (ssh-copy-id)."

if [[ $STOP_ONLY -eq 1 ]]; then
    log "Stopping image server on $SSH_HOST"
    stop_server
    exit 0
fi

if [[ $START_SERVER -eq 1 ]]; then
    if [[ $RESTART_SERVER -eq 1 ]]; then
        log "Restarting image server on $SSH_HOST"
        stop_server
        sleep 1
    fi

    if server_running; then
        log "Image server already running on $SSH_HOST"
    else
        log "Starting image server on $SSH_HOST ($REMOTE_START, log: $REMOTE_LOG)"
        # The start script detaches the server itself (setsid), so ssh returns at once.
        remote "$REMOTE_START"
    fi

    log "Waiting for image server (port $IMG_PORT)..."
    wait_for_port || die "Image server did not come up in ${SERVER_WAIT_S}s. Check: ssh $SSH_HOST tail -n 50 $REMOTE_LOG"
    log "Image server is up"
fi

# --- teleop on the host ----------------------------------------------------
if [[ "${CONDA_DEFAULT_ENV:-${MAMBA_DEFAULT_ENV:-}}" != "$LOCAL_ENV" ]]; then
    if command -v micromamba >/dev/null 2>&1; then
        eval "$(micromamba shell hook -s bash)"
        micromamba activate "$LOCAL_ENV"
    elif command -v conda >/dev/null 2>&1; then
        eval "$(conda shell.bash hook)"
        conda activate "$LOCAL_ENV"
    else
        die "Neither micromamba nor conda found; activate the '$LOCAL_ENV' env yourself."
    fi
fi

cd "$REPO_DIR/teleop"
log "python teleop_hand_and_arm.py ${TELEOP_ARGS[*]:-}"
exec python teleop_hand_and_arm.py "${TELEOP_ARGS[@]}"
