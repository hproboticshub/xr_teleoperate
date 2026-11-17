# Switches one master_service service on/off (no motor commands).
import sys, time
from unitree_sdk2py.core.channel import ChannelFactoryInitialize
from unitree_sdk2py.go2.robot_state.robot_state_client import RobotStateClient
iface, name, on = sys.argv[1], sys.argv[2], sys.argv[3] == "on"
ChannelFactoryInitialize(0, iface)
c = RobotStateClient(); c.SetTimeout(5.0); c.Init()
print("ServiceSwitch", name, on, "->", c.ServiceSwitch(name, on))
time.sleep(3)
code, lst = c.ServiceList()
print([(s.name, s.status) for s in lst if s.name == name])
