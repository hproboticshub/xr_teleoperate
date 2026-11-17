# Read-only: lists master_service services and their state.
import sys
from unitree_sdk2py.core.channel import ChannelFactoryInitialize
from unitree_sdk2py.go2.robot_state.robot_state_client import RobotStateClient
ChannelFactoryInitialize(0, sys.argv[1])
c = RobotStateClient(); c.SetTimeout(3.0); c.Init()
code, lst = c.ServiceList()
print("code", code)
for s in lst or []:
    print(f"{s.name:30s} status={s.status} protect={s.protect}")
