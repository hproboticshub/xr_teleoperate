#!/usr/bin/env bash
# Start the teleimager server on the G1's PC2 (Jetson) over SSH, then run the
# teleoperation program locally. Every argument is forwarded to
# teleop/teleop_hand_and_arm.py, except the wrapper flags below.
#
# Usage:
#   scripts/run_g1_teleop.sh [wrapper flags] [teleop flags...]
#
# By default the robot is NOT put in dev (debug) mode: the script starts the
# teleop with --motion --input-mode controller, so the PICO drives the FSM
# (B+Y = stand up, A+X = start, ...) and nothing has to be done on the robot or
# restarted to leave dev mode. See G1_EDU_MOTION_TELEOP.md for the controls.
#
# Examples:
#   scripts/run_g1_teleop.sh --ee brainco
#   scripts/run_g1_teleop.sh --ee brainco --arm-offset-x -0.15 --arm-offset-z 0.50
#   scripts/run_g1_teleop.sh --dev-mode --arm G1_29 --ee dex3 --record
#
# Wrapper flags (consumed here, not forwarded):
#   --dev-mode         put the robot in dev (debug) mode, like upstream teleop
#                      without --motion: no PICO FSM/locomotion, legs are not
#                      controlled. Default is off (--motion is added).
#   --arm-offset-x M   head->waist arm offset, forward (default 0.15 m)
#   --arm-offset-y M   head->waist arm offset, outward for both hands (default 0)
#   --arm-offset-z M   head->waist arm offset, up (default 0.45 m)
#                      (smaller X = robot hands further back; smaller Z = lower.
#                      Same as env XR_ARM_OFFSET_X/Y/Z; the flag wins.)
#   --no-server        do not touch the image server (assume it is running)
#   --restart-server   kill the running image server and start it again
#   --stop-server      stop the image server on PC2, give the head camera back to
#                      Unitree's video_hub_pc4 service, and exit
#
# Environment overrides:
#   G1_SSH_HOST      ssh target of PC2 (user@ip or alias). Default: the 'g1-jetson'
#                    alias if it is defined in ~/.ssh/config, else
#                    unitree@192.168.123.164
#   G1_SSH_KEY       private key to use for PC2 (default: ssh's own defaults/config)
#   G1_REMOTE_DIR    teleimager folder on PC2       (default: ~/teleimager)
#   G1_REMOTE_ENV    conda env dir on PC2 that has teleimager-server
#                                                   (default: ~/miniforge3/envs/tv)
#   G1_NET_IF        DDS network interface          (default: auto-detect 192.168.123.x)
#   G1_PYTHON        python to run the teleop with  (default: the activated venv,
#                    <repo>/tv or <repo>/.venv, else the G1_LOCAL_ENV env)
#   G1_LOCAL_ENV     micromamba/conda env locally   (default: tv)
#   G1_IMG_PORT      zmq port used to check the server is up (default: 55555)
#   G1_REMOTE_LOG    server log file on PC2         (default: /tmp/teleimager.log)
#   G1_VIDEOHUB      Unitree master_service that holds /dev/video4
#                    (default: video_hub_pc4; set to "" to leave it alone)

set -euo pipefail

if [[ -z "${G1_SSH_HOST:-}" ]]; then
    # Use the g1-jetson alias when this machine defines one (it may carry the key).
    if [[ "$(ssh -G g1-jetson 2>/dev/null | awk '/^hostname /{print $2}')" != "g1-jetson" ]]; then
        G1_SSH_HOST=g1-jetson
    else
        G1_SSH_HOST=unitree@192.168.123.164
    fi
fi
SSH_HOST="$G1_SSH_HOST"
REMOTE_DIR="${G1_REMOTE_DIR:-~/teleimager}"
REMOTE_ENV="${G1_REMOTE_ENV:-~/miniforge3/envs/tv}"
LOCAL_ENV="${G1_LOCAL_ENV:-tv}"
IMG_PORT="${G1_IMG_PORT:-55555}"
REMOTE_LOG="${G1_REMOTE_LOG:-/tmp/teleimager.log}"
VIDEOHUB="${G1_VIDEOHUB-video_hub_pc4}"
MSCLI=/unitree/sbin/mscli
SERVER_WAIT_S=40

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# One multiplexed connection: if no key is installed, ssh asks for the password
# once (default Unitree password: 123) and every later call reuses it.
SSH_OPTS=(-o ConnectTimeout=5 -o LogLevel=ERROR
          -o ControlMaster=auto -o "ControlPath=/tmp/g1-ssh-%C" -o ControlPersist=10m)
[[ -n "${G1_SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$G1_SSH_KEY" -o IdentitiesOnly=yes)

# --- wrapper flags ---------------------------------------------------------
START_SERVER=1
RESTART_SERVER=0
STOP_ONLY=0
DEV_MODE=0
TELEOP_ARGS=()
# Offsets: flag (--arm-offset-x 0.1 or --arm-offset-x=0.1) -> XR_ARM_OFFSET_X env var.
needs_value() { [[ $# -ge 2 ]] || { echo "[g1] $1 needs a value" >&2; exit 1; }; }
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-server)      START_SERVER=0 ;;
        --restart-server) RESTART_SERVER=1 ;;
        --stop-server)    STOP_ONLY=1 ;;
        --dev-mode)       DEV_MODE=1 ;;
        --arm-offset-[xyz])
            needs_value "$@"
            axis="${1: -1}"; export "XR_ARM_OFFSET_${axis^^}=$2"; shift ;;
        --arm-offset-[xyz]=*)
            axis="${1:13:1}"; export "XR_ARM_OFFSET_${axis^^}=${1#*=}" ;;
        *)                TELEOP_ARGS+=("$1") ;;
    esac
    shift
done

# --- helpers ---------------------------------------------------------------
log() { printf '\033[1;34m[g1]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[g1] %s\033[0m\n' "$*" >&2; exit 1; }

remote() { ssh "${SSH_OPTS[@]}" "$SSH_HOST" "$@"; }

# The [x] trick keeps pgrep from matching its own command line.
SERVER_PATTERN='[t]eleimager-server|[t]eleimager.image_server'
server_running() { remote "pgrep -f '$SERVER_PATTERN' >/dev/null"; }
stop_server()    { remote "pkill -f '$SERVER_PATTERN' || true"; }

wait_for_port() {
    local host
    host="$(ssh "${SSH_OPTS[@]}" -G "$SSH_HOST" 2>/dev/null | awk '/^hostname /{print $2}')"
    for ((i = 0; i < SERVER_WAIT_S; i++)); do
        if timeout 1 bash -c ">/dev/tcp/$host/$IMG_PORT" 2>/dev/null; then
            return 0
        fi
        # Every 4s, bail out early if the server process already died.
        if ((i > 0 && i % 4 == 0)) && ! server_running; then
            printf '\033[1;31m[g1] Image server exited. Last log lines:\033[0m\n' >&2
            remote "grep -E 'ERROR|Error|RuntimeError|busy' '$REMOTE_LOG' | tail -n 8" >&2 || true
            return 1
        fi
        sleep 1
    done
    return 1
}

# --- image server on PC2 ---------------------------------------------------
if [[ $START_SERVER -eq 1 || $STOP_ONLY -eq 1 ]]; then
    remote true || die "Cannot ssh to '$SSH_HOST'. Check the robot is reachable (ping 192.168.123.164) and the password/key is right. To avoid the password: ssh-copy-id -i <key>.pub $SSH_HOST (and G1_SSH_KEY=<private key> if it is not a default key)."
fi

if [[ $STOP_ONLY -eq 1 ]]; then
    log "Stopping image server on $SSH_HOST"
    stop_server
    if [[ -n "$VIDEOHUB" ]]; then
        log "Restoring Unitree service $VIDEOHUB"
        remote "$MSCLI restartservice $VIDEOHUB" >/dev/null || true
    fi
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
        # Unitree's video_hub_pc4 holds /dev/video4 (head camera) and master_service
        # respawns it if killed, so stop it through mscli (undone by --stop-server
        # or a reboot).
        if [[ -n "$VIDEOHUB" ]]; then
            log "Releasing head camera: stopping $VIDEOHUB"
            remote "$MSCLI stopservice $VIDEOHUB" >/dev/null || true
            sleep 1
        fi
        log "Starting teleimager-server in $SSH_HOST:$REMOTE_DIR (log: $REMOTE_LOG)"
        # setsid + redirected fds detach the server from ssh, so ssh returns at once.
        # (cd first, then background only the simple command so no subshell keeps ssh open.)
        remote "cd $REMOTE_DIR || exit 1; setsid nohup $REMOTE_ENV/bin/teleimager-server >'$REMOTE_LOG' 2>&1 </dev/null &"
    fi

    log "Waiting for image server (port $IMG_PORT)..."
    wait_for_port || die "Image server is not up. Full log: ssh $SSH_HOST tail -n 80 $REMOTE_LOG"
    log "Image server is up"
fi

# --- teleop on the host ----------------------------------------------------
# Python environment, in order: G1_PYTHON, an activated venv, <repo>/tv or
# <repo>/.venv (see requirements.txt), then the G1_LOCAL_ENV conda/micromamba env.
PYTHON="${G1_PYTHON:-}"
if [[ -z "$PYTHON" && -n "${VIRTUAL_ENV:-}" ]]; then
    PYTHON="$VIRTUAL_ENV/bin/python"
fi
for venv in "$REPO_DIR/tv" "$REPO_DIR/.venv"; do
    if [[ -z "$PYTHON" && -x "$venv/bin/python" ]]; then
        PYTHON="$venv/bin/python"
    fi
done
if [[ -z "$PYTHON" ]]; then
    if [[ "${CONDA_DEFAULT_ENV:-${MAMBA_DEFAULT_ENV:-}}" != "$LOCAL_ENV" ]]; then
        if command -v micromamba >/dev/null 2>&1; then
            eval "$(micromamba shell hook -s bash)"
            micromamba activate "$LOCAL_ENV"
        elif command -v conda >/dev/null 2>&1; then
            eval "$(conda shell.bash hook)"
            conda activate "$LOCAL_ENV"
        else
            die "No Python environment found. Create a venv (see requirements.txt) and activate it, set G1_PYTHON, or create a '$LOCAL_ENV' conda env."
        fi
    fi
    PYTHON=python
fi

# DDS needs the wired interface that is on the robot's 192.168.123.x network.
# Auto-detect it unless the user passed --network-interface (or runs the sim).
has_arg() { local a; for a in "${TELEOP_ARGS[@]}"; do [[ "$a" == "$1" || "$a" == "$1="* ]] && return 0; done; return 1; }
if ! has_arg --network-interface && ! has_arg --sim; then
    NET_IF="${G1_NET_IF:-$(ip -br -4 addr | awk '$3 ~ /^192\.168\.123\./ {print $1; exit}')}"
    [[ -n "$NET_IF" ]] || die "No interface on 192.168.123.x found. Connect to the robot or pass --network-interface <name>."
    log "Using network interface $NET_IF"
    TELEOP_ARGS+=(--network-interface "$NET_IF")
fi

# Dev mode is opt-in. Without it, run in --motion with the PICO controllers so
# the robot is never forced into debug mode (the PICO B+Y combo handles the FSM).
if [[ $DEV_MODE -eq 1 ]]; then
    log "Dev mode ON: the teleop will put the robot in debug mode"
else
    has_arg --motion || TELEOP_ARGS+=(--motion)
    has_arg --input-mode || TELEOP_ARGS+=(--input-mode controller)
fi

# The televuer submodule needs the local patches (PICO watchdog; arm offsets).
# They are applied once; already-applied ones are skipped.
TV_DIR="$REPO_DIR/teleop/televuer"
for patch in "$REPO_DIR"/patches/televuer/*.patch; do
    [[ -f "$patch" ]] || continue
    if git -C "$TV_DIR" apply --check "$patch" 2>/dev/null; then
        log "Applying $(basename "$patch") to teleop/televuer"
        git -C "$TV_DIR" apply "$patch"
    elif ! git -C "$TV_DIR" apply --check -R "$patch" 2>/dev/null; then
        die "Cannot apply $(basename "$patch") to teleop/televuer (neither applied nor applicable)."
    fi
done

cd "$REPO_DIR/teleop"
log "$PYTHON teleop_hand_and_arm.py ${TELEOP_ARGS[*]:-}"
exec "$PYTHON" teleop_hand_and_arm.py "${TELEOP_ARGS[@]}"
