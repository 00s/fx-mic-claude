# firmware

What goes on the mic. Nothing from Teenage Engineering ships here: the mic's own startup script is read from **your**
device and patched locally.

| File | On the mic's disk | What it is |
| --- | --- | --- |
| `fxmic/boot_main.py` | `main.py` | The boot stub. Reads the saved mode from `claude/mode` and starts Claude mode (`claude/fxmic.py`) or TE's own startup. Also watches for the 3 s holds that switch modes. |
| `fxmic/main.py` (git-ignored) | `claude/fxmic.py` | TE's startup script plus the marker tones, shake to cancel, the queue and draft buttons, and the USB reports. Written by `tools/build_fxmic_script.py --from-device`. |
| `te/escape_blank_disk.uf2` | (bootloader only) | Blanks the disk's first 8 KB, so the mic reformats it at the next start. Rebuild it with `tools/make_escape_uf2.py`. |

`tools/install_disk.sh install` copies both scripts, `config.json` and the marker sounds into place;
`tools/install_disk.sh remove` makes the mic stock again. The disk root never holds `config.json` or marker sounds, so
factory mode loads TE's own.

**Recovery.** If a script stops the mic from starting: hold the handle and double-click the small button above the
USB port. A drive called "FX MIC BOOT" appears; drag `te/escape_blank_disk.uf2` onto it. TE's firmware is at
https://teenage.engineering/downloads/ep-2350 if you need a full reflash; it doesn't touch the disk.

**Never** run `mpremote` or pyserial tools against the mic's serial port: they toggle DTR/RTS and reset it. Use
`tools/mp_exec.py`. Why the boot stub is written the way it is: [PLAN.md](../PLAN.md), "Firmware route".
