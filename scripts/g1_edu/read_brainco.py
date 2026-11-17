# Passive: subscribes to BrainCo hand state topics only.
import sys, time
from unitree_sdk2py.core.channel import ChannelFactoryInitialize, ChannelSubscriber
from unitree_sdk2py.idl.unitree_go.msg.dds_ import MotorStates_
ChannelFactoryInitialize(0, sys.argv[1])
got = {"left": [], "right": []}
subs = []
for side in got:
    s = ChannelSubscriber(f"rt/brainco/{side}/state", MotorStates_); s.Init(lambda m, side=side: got[side].append(m), 10); subs.append(s)
time.sleep(2)
for side, msgs in got.items():
    q = [round(x.q, 2) for x in msgs[-1].states] if msgs else None
    print(f"{side}: {len(msgs)} msgs em 2 s, q={q}")
