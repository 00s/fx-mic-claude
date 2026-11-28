# Reference

Details behind the [README](../README.md): settings, how each part behaves, and the tools for working on Squeeze.

## Settings

Most settings are in the panel. The rest are `defaults` keys; set one, then restart Squeeze:

```bash
defaults write com.miguel.fxmic <key> <value>
defaults delete com.miguel.fxmic <key>          # back to the default
```

| Key | Default | What it does |
| --- | --- | --- |
| `transcriptionEngine` | `apple` | `claude` drives Claude's own dictation (panel: "Use Claude's dictation"). |
| `appleFallback` | `true` | In Claude mode, Apple's recognizer runs alongside and takes over if dictation can't start. |
| `locales` | `en-US`, `es-MX` | Languages for Apple's recognizer; the more confident one wins per message. |
| `hudTranscript` | `true` | Live text in the island. |
| `livePreview` | `true` | A second, faster recognizer for the live text (Apple mode). The sent text still comes from the accurate one. |
| `fastLiveText` | `false` | Fast results everywhere, the sent text included, at some cost in accuracy. |
| `transcriberGainDb` | `0` | Extra gain for Apple's recognizer only. +20 dB helped quiet recordings. |
| `autoGain` | `true` | After each message, nudges the adapter's input gain toward peaks of -20 to -4 dBFS. Off in Claude mode, where Claude's dictation sets the gain. |
| `weakSignalDb` | `-26` | A squeeze whose voice peaks below this is kept as a draft, never sent or queued. `-160` turns the check off. |
| `stuckSqueezeSeconds` | `30` | A squeeze with no speech for this long and no release heard ends as a draft. `0` never. |
| `usbTrigger` | `true` | Take squeezes from the mic's USB reports when they arrive. |
| `shakeToCancel` | `true` | A hard shake while squeezing cancels. |
| `bottomButton` | `panel` | What the bottom button does: `panel`, `claude` (bring forward), `toggle` (show or hide), `none`. |
| `idleMinutes` | `20` | Mute after this long without a squeeze. |
| `logTranscripts` | `false` | Write what you say to the log. Off: word counts only. |
| `dictationButtonLabels` | `hold to record`, `dictat` | Parts of the label of Claude's mic control, for when Claude renames it. |
| `chirpMinLevelDb`, `openDb` | `-50`, `-44` | Thresholds for marker tones and speech. Lower them for quiet inputs. |
| `pressFreqs`, `releaseFreqs`, `cancelFreqs`, `chirpFreqs` | see [Marker tones](#marker-tones) | The pitches Squeeze listens for. |

## Claude's dictation

With `transcriptionEngine` set to `claude`, a squeeze presses the mic control next to Claude's composer through
Accessibility, and the release presses it again. The words stay where Claude wrote them, in the conversation they were
spoken into:

- A plain squeeze presses Send. While Claude is working, that sends a mid-turn message.
- The top button queues the message in Claude, with ⌘↩.
- The middle button leaves it as a draft.

Like dictating by hand, the words go after any draft already in the composer.

Claude starts listening 0.65 to 1 s after the squeeze. Until then the island is grey and reads "Starting…"; talk
once it turns yellow. Claude's client buffers audio until its speech connection opens, so words after the yellow are
not lost.

If Claude renames its mic control, `touch ~/.fxmic/axdump` lists the controls next to the composer in the log.
Then set `dictationButtonLabels` to part of the new label.

## Where messages go

To the conversation on screen in Claude, even with Claude behind other apps. The panel's Chats page can **pin**
another conversation: every squeeze switches Claude to it first. A pin works only while the conversation has a row
in Claude's sidebar. If it can't be shown, the words stay as a draft in the conversation on screen. Switching
conversations while talking also leaves the words unsent.

A queued message goes out once its session is idle, so it is sent right away if Claude isn't working. Queued
messages go one at a time, at least 10 s apart. One still waiting after 30 minutes is left in the composer as a
draft. Whether a session is working comes from the desktop app's own session files (`latestUserFrameAt` newer than
`lastTurnEdgeAt`), an undocumented detail that may change.

## The mic

### Marker tones

The script plays one-shot samples on the mic's four sample slots. They are above speech and vanish in the
recognizer's 16 kHz resampling.

| Event | Default pitches | Low-pitch pack |
| --- | --- | --- |
| Handle squeezed | 17 + 18.5 kHz | 4.3 + 5.7 kHz |
| Handle released | 14 + 15 kHz | 3.7 + 5.1 kHz |
| Shake (cancel) | 12 + 13 kHz | 3.4 + 4.8 kHz |
| Play button | 15.5 + 16.5 kHz | 4.0 + 5.4 kHz |

During a squeeze, the top button replays the press tone (queue) and the middle button plays the play tone (draft).

### USB reports

With the mic on a USB-C data cable, its script also prints each event on its serial console: `fxmic press`,
`release`, `queue`, `draft`, `cancel`, `tap`, and `fxmic hi` about every 2 s. While those lines arrive, Squeeze takes
squeezes from them. It opens the input only for each squeeze, so the orange microphone dot is off in between, and a
squeeze also unmutes Squeeze. On batteries or a charge-only cable, no lines arrive, and within 5 s Squeeze goes back
to listening for the tones. Squeeze only reads the port: it never writes to it or touches its modem lines. Quit
Squeeze before running `tools/mp_exec.py` or `build_fxmic_script.py --from-device`.

### Claude mode and factory mode

Claude mode keeps its files in `claude/` on the mic's disk, so the disk root stays factory. With the handle
released, hold the top button for 3 s for Claude mode, or the middle button for 3 s for factory mode. The sample LEDs
sweep up (Claude) or down (factory), and the mode is saved. Turn the mic off and on to start in it.

## Band-limited or quiet adapters

Some cheap USB-C dongles pass nothing above about 7 kHz: speech arrives, squeezes don't. Check while squeezing:

```bash
.build/release/fxmic-cal --device "<name>" --scan
```

No scan lines above 12 kHz means the tones are filtered out. Then install the low-pitch markers and tell Squeeze
about them:

```bash
tools/install_disk.sh install marker-pack-lowband   # prints four defaults commands: run them
```

If the input is quiet even with the mic's volume knob at maximum, lower `chirpMinLevelDb` (try `-85`) and `openDb`
(try `-60`). The log line "tone threshold … speech threshold …" shows the values in use.

## Tools

| Tool | Purpose |
| --- | --- |
| `fxmic-cal` (`swift build -c release`) | Calibration: live levels, tone scan, gate events, recordings, `--stt` transcription, `--file` offline replay |
| `tools/make_app.sh` | Build, sign and install the app. Runs `tools/check_design.sh` first. |
| `tools/check_design.sh` | Fails if a custom or bundled font comes back (see CLAUDE.md, Design system) |
| `tools/render_docs_images.sh` | Re-renders `docs/images/` (island, gestures, demo GIFs) from the app's own views. Needs ffmpeg. |
| `tools/build_fxmic_script.py` | Patch TE's startup script from your mic with the markers, shake and USB reports |
| `tools/install_disk.sh` | Install or remove the script and marker sounds on the mic's disk |
| `tools/mp_exec.py` | Run Python on the mic over the raw REPL without resetting it |
| `tools/make_marker_pack.py`, `make_marker_pack_lowband.py` | Generate the marker sounds |
| `tools/make_escape_uf2.py` | Build the recovery UF2 that blanks the disk |
| `tools/probe_*.py`, `serial_probe.py`, `repl.py` | The probes used to learn the handle, accelerometer and boot behavior |

### Debug hooks

| Hook | What it does |
| --- | --- |
| `echo "hello" > ~/.fxmic/send.txt` | Delivers text as if spoken |
| `open --env FXMIC_RECORD=/path/live.wav ~/Applications/Squeeze.app` | Saves what Squeeze hears until it mutes. This records your voice. |
| `open --env FXMIC_REPLAY=/path/take.wav ~/Applications/Squeeze.app` | Feeds a recording through the live pipeline 3 s after start |
| `touch ~/.fxmic/axdump` | Logs the controls next to Claude's composer |

The log is `~/.fxmic/fxmic.log`, and the state is in `~/.fxmic/state.json`. Both are readable by you only.

## Repository layout

```
Sources/FXMicCore   audio tap, speech gate, tone detection, transcriber, serial reports
Sources/FXMic       the menu bar app: island, panel, gestures, delivery into Claude, settings
Sources/fxmic-cal   calibration command line tool
firmware/           boot stub, script builder inputs, recovery UF2
packs/              marker sounds (marker-pack is the default; claude-pack and pilot-pack are early experiments)
tools/              the scripts above
claude/             the /fxmic skill, a file-inbox fallback when Accessibility isn't granted
docs/images/        README images, rendered from the app's own views
PLAN.md             engineering log
```
