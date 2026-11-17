# Read-only: is the G1 under Unitree locomotion control (ai, not debug mode) and in which FSM state?
# Exit 0 only if mode is set and FSM id is 500 (Start / Main Operation Control = Regular mode, R1+X).
import sys
from unitree_sdk2py.core.channel import ChannelFactoryInitialize
from unitree_sdk2py.comm.motion_switcher.motion_switcher_client import MotionSwitcherClient
from unitree_sdk2py.g1.loco.g1_loco_client import LocoClient

FSM = {0: "zero torque", 1: "damp", 2: "squat", 3: "sit", 4: "stand up / locked",
       500: "Regular mode (Start, R1+X)"}

ChannelFactoryInitialize(0, sys.argv[1])
msc = MotionSwitcherClient(); msc.SetTimeout(3.0); msc.Init()
code, res = msc.CheckMode()
mode = (res or {}).get("name", "") if code == 0 else None
print(f"modo: {mode!r}" + ("  (debug mode: ninguém controla as pernas)" if mode == "" else ""))

loco = LocoClient(); loco.SetTimeout(3.0); loco.Init()
code, fsm = loco.GetFsmId()
print(f"FSM id: {fsm}  ({FSM.get(fsm, 'desconhecido')})" if code == 0 else f"FSM id: erro {code}")
sys.exit(0 if mode and fsm == 500 else 1)
