# Local changes to the `teleop/televuer` submodule

The submodule points at upstream `unitreerobotics/televuer`, so these changes live here as patches.
Apply them after `git submodule update --init --recursive`:

```bash
git -C teleop/televuer apply ../../patches/televuer/0001-last-motion-time-for-pico-watchdog.patch
git -C teleop/televuer apply ../../patches/televuer/0002-arm-offset-env-vars.patch   # optional
```

- **0001** (required by `teleop/utils/pico_motion_ctrl.py`): `TeleVuer.last_motion_time`, the time of the last
  controller event, used by the PICO watchdog (no data for 0.3 s = stop).
- **0002** (optional): head→waist arm offset read from env vars instead of hard-coded values.
  `XR_ARM_OFFSET_X` (forward, default 0.15), `XR_ARM_OFFSET_Z` (up, default 0.45), `XR_ARM_OFFSET_Y`
  (outward for both hands, default 0). Defaults equal upstream. G1 EDU tuning on 2026-11-17: X=-0.15 put the
  elbows closer to the operator's; Z and Y not settled yet.
  Example: `XR_ARM_OFFSET_X=-0.15 XR_ARM_OFFSET_Z=0.50 python teleop_hand_and_arm.py ...`
