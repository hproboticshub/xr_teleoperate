# Local addition (2026-11-03, Tiago): drive the G1 from the PICO controllers alone, without the Unitree remote.
#   B+Y held 1 s          : leave debug mode if needed, then Damp -> StandUp (FSM 4) -> Start (FSM 500, Regular mode)
#   A+X held 1 s          : start following (instead of `r`), or resume after a stop
#   both stick clicks 0.5 s: stop - zero velocity, arms and hands frozen at the last target; the robot keeps balancing
#   watchdog              : no PICO data for WATCHDOG_S behaves like a stop until data comes back
import copy
import threading
import time

import numpy as np
import logging_mp
from unitree_sdk2py.comm.motion_switcher.motion_switcher_client import MotionSwitcherClient
from unitree_sdk2py.g1.loco.g1_loco_client import LocoClient

logger_mp = logging_mp.getLogger(__name__)

FSM_ZERO_TORQUE, FSM_DAMP, FSM_STAND_UP, FSM_REGULAR = 0, 1, 4, 500  # g1_loco_client.hpp: ZeroTorque/Damp/StandUp/Start
WATCHDOG_S = 0.3


class Hold:
    """Fires once when `pressed` has stayed true for `seconds`; re-arms when released."""
    def __init__(self, seconds):
        self.seconds, self.since, self.fired = seconds, None, False

    def update(self, pressed):
        if not pressed:
            self.since, self.fired = None, False
            return False
        now = time.time()
        if self.since is None:
            self.since = now
        if not self.fired and now - self.since >= self.seconds:
            self.fired = True
            return True
        return False


class PicoMotionCtrl:
    def __init__(self, tvuer):
        self.tvuer = tvuer
        self.start_hold, self.stand_hold, self.stop_hold = Hold(1.0), Hold(1.0), Hold(0.5)
        self.frozen = False
        self.stale = False
        self.last_good = None
        self._standing_up = False
        self._last_buttons = None
        self.loco = LocoClient(); self.loco.SetTimeout(3.0); self.loco.Init()
        self.msc = MotionSwitcherClient(); self.msc.SetTimeout(3.0); self.msc.Init()

    def poll(self):
        """Reads the button combos (live). Returns True when A+X fired (start / resume)."""
        t = self.tvuer
        a, b = t.right_ctrl_aButton, t.right_ctrl_bButton
        x, y = t.left_ctrl_aButton, t.left_ctrl_bButton  # televuer names the left X/Y buttons a/b
        state = (a, b, x, y, t.left_ctrl_thumbstick, t.right_ctrl_thumbstick)
        if state != self._last_buttons:  # debug for the first robot tests: what the PICO really sends
            self._last_buttons = state
            logger_mp.info("[PICO] buttons A=%d B=%d X=%d Y=%d LS=%d RS=%d" % tuple(map(int, state)))
        if self.stand_hold.update(b and y and not (a or x)):
            self.stand_up()
        if self.stop_hold.update(t.left_ctrl_thumbstick and t.right_ctrl_thumbstick) and not self.frozen:
            self.frozen = True
            logger_mp.warning("[PICO] STOP: velocity zero, arms and hands frozen. Hold A+X 1 s to resume.")
        started = self.start_hold.update(a and x and not (b or y))
        if started and self.frozen:
            self.frozen = False
            logger_mp.info("[PICO] resumed")
        return started

    def filter(self, tele_data):
        """The data the robot should follow: live data, or the last good data with the sticks zeroed
        while stopped or while the PICO stream is stale."""
        stale = time.time() - self.tvuer.last_motion_time > WATCHDOG_S
        if stale != self.stale:
            self.stale = stale
            if stale:
                logger_mp.warning(f"[PICO] no data for {WATCHDOG_S} s: velocity zero, arms frozen "
                                  "(PICO asleep, VR left, or adb tunnel down). Resumes when data returns.")
            else:
                logger_mp.info("[PICO] data back")
        if not (stale or self.frozen):
            self.last_good = tele_data
            return tele_data
        held = copy.copy(self.last_good if self.last_good is not None else tele_data)
        held.left_ctrl_thumbstickValue = np.zeros(2)
        held.right_ctrl_thumbstickValue = np.zeros(2)
        return held

    def stand_up(self):
        if self._standing_up:
            return
        self._standing_up = True
        threading.Thread(target=self._stand_up, daemon=True).start()

    def _fsm(self):
        code, fsm = self.loco.GetFsmId()
        return fsm if code == 0 else None

    def _wait_fsm(self, target, timeout):
        end = time.time() + timeout
        while time.time() < end:
            if self._fsm() == target:
                return True
            time.sleep(0.2)
        return False

    def _stand_up(self):
        try:
            code, res = self.msc.CheckMode()
            if code == 0 and not (res or {}).get("name"):
                logger_mp.info("[PICO] debug mode: selecting ai")
                self.msc.SelectMode("ai")
                end = time.time() + 10
                while time.time() < end and not (self.msc.CheckMode()[1] or {}).get("name"):
                    time.sleep(0.5)
            fsm = self._fsm()
            logger_mp.info(f"[PICO] stand up: FSM {fsm}")
            if fsm == FSM_REGULAR:
                logger_mp.info("[PICO] already in Regular mode")
                return
            if fsm == FSM_ZERO_TORQUE:
                self.loco.Damp()
                time.sleep(1.0)
                fsm = FSM_DAMP
            if fsm == FSM_DAMP:
                self.loco.SetFsmId(FSM_STAND_UP)
                if not self._wait_fsm(FSM_STAND_UP, 5.0):
                    logger_mp.error(f"[PICO] StandUp not reached (FSM {self._fsm()})")
                    return
                time.sleep(2.0)  # let the legs extend before walking mode
            self.loco.Start()
            if self._wait_fsm(FSM_REGULAR, 5.0):
                logger_mp.info("[PICO] Regular mode (FSM 500): sticks walk")
            else:
                logger_mp.error(f"[PICO] Regular mode not reached (FSM {self._fsm()})")
        except Exception as e:
            logger_mp.error(f"[PICO] stand up failed: {e}")
        finally:
            self._standing_up = False
