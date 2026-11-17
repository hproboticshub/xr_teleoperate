#!/bin/bash
# Restarts the teleimager camera server in the background (log: /tmp/teleimager.log).
# setsid detaches it from the ssh session, so `ssh pc2 '~/start_teleimager.sh'` returns at once.
pkill -f "python -m teleimager.image_server"
sleep 1
cd ~/teleimager && setsid nohup ~/miniforge3/envs/tv/bin/python -m teleimager.image_server > /tmp/teleimager.log 2>&1 < /dev/null &
echo "teleimager started, pid $!"
