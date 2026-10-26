#!/usr/bin/env bash
# Opens the G1-D teleoperation tmux layout:
#   left        : teleop_hand_and_arm.py (waits for the PC2 services, then for [r])
#   top right   : PC2 -> stop fatigue.service + BrainCo hand server (asks for sudo password)
#   bottom right: PC2 -> teleimager image server
#
# Usage: ./run_g1d_tmux.sh          (create / attach the session)
#        ./run_g1d_tmux.sh teleop   (internal: what the left pane runs)

set -u

SESSION=g1teleop
PC2=unitree@192.168.123.164
PC2_IP=192.168.123.164
NET_IF=enxf44dad0705a2
TELEOP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TELEOP_DIR/$(basename "${BASH_SOURCE[0]}")"
TELEOP_ARGS=(--input-mode=controller --arm=G1_29 --ee=brainco --network-interface="$NET_IF")

HANDS_CMD="ssh -t $PC2 'sudo systemctl stop fatigue.service && cd ~/unitree_eai_environment/service/brainco_hand_service/bin && sudo ./brainco_hand_server --network eth0'"
CAMERA_CMD="ssh -t $PC2 'cd ~/unitree_eai_environment/service/teleimager && ~/miniconda3/envs/tv/bin/python -m teleimager.image_server'"

run_teleop() {
    echo ">>> waiting for fatigue.service to stop on PC2 (type the sudo password in the top-right pane)..."
    while :; do
        case "$(ssh -o BatchMode=yes "$PC2" systemctl is-active fatigue.service 2>/dev/null)" in
            active|activating|deactivating|reloading|"") sleep 2 ;;
            *) break ;;
        esac
    done
    echo ">>> fatigue.service stopped."

    echo ">>> waiting for teleimager on PC2 (camera config port 60000)..."
    until timeout 1 bash -c "</dev/tcp/$PC2_IP/60000" 2>/dev/null; do
        sleep 1
    done
    sleep 2  # let the cameras finish initializing
    echo ">>> teleimager is up."

    local wifi_ip
    wifi_ip=$(ip -4 -o addr show | awk '!/ lo |docker|'"$NET_IF"'/ {split($4,a,"/"); print a[1]; exit}')
    echo
    echo ">>> PICO: close any old tab, open a NEW one at https://$wifi_ip:8012/?ws=wss://$wifi_ip:8012"
    echo ">>>       wait for the video, press Virtual Reality, stand in the robot pose, THEN press [r] here."
    echo ">>> WARNING: the arms are about to move to the zero pose. Keep clear of the robot."
    echo

    # activate the env exactly like an interactive 'micromamba activate tv'
    export MAMBA_ROOT_PREFIX="$HOME/micromamba"
    eval "$("$HOME/.local/bin/micromamba" shell hook --shell bash)"
    micromamba activate tv
    cd "$TELEOP_DIR" && python teleop_hand_and_arm.py "${TELEOP_ARGS[@]}"
}

if [ "${1:-}" = "teleop" ]; then
    run_teleop
    exit
fi

if tmux has-session -t "$SESSION" 2>/dev/null; then
    exec tmux attach -t "$SESSION"
fi

tmux new-session -d -s "$SESSION" -x "$(tput cols)" -y "$(tput lines)"
tmux split-window -h -t "$SESSION:0.0"
tmux split-window -v -t "$SESSION:0.1"

tmux send-keys -t "$SESSION:0.1" "$HANDS_CMD" C-m
tmux send-keys -t "$SESSION:0.2" "$CAMERA_CMD" C-m
tmux send-keys -t "$SESSION:0.0" "$SCRIPT teleop" C-m

tmux select-pane -t "$SESSION:0.1"   # focus the hands pane for the sudo password
exec tmux attach -t "$SESSION"
