# ComfyPhone

A tiny iPhone app that sends a prompt to your own PC's ComfyUI and shows the picture back.
The phone does no rendering — the PC's GPU does all of it.

```
[ ComfyPhone IPA ] --HTTP--> [ comfy-bridge :8200 ] --loopback--> [ ComfyUI :8188 ] --GPU--> image
```

## Pieces

| Where | What |
|---|---|
| PC | `bridge/app.py` — token-protected HTTP bridge, binds `0.0.0.0:8200`, starts/stops ComfyUI on command, submits jobs, returns PNG bytes |
| PC | `bridge/Start Phone Server.vbs` — starts the bridge hidden; desktop/Start-Menu shortcut **ComfyPhone Server** |
| iPhone | `ComfyPhone` IPA (this repo) — prompt, model picker, size/steps, engine start/stop/restart/free-VRAM, Save to Photos, gallery of past renders |

## Bridge API

| Route | Purpose |
|---|---|
| `GET /health` | engine up/down, GPU, free VRAM, engine pid, queue (no token needed) |
| `GET /models` | pipelines + defaults |
| `POST /generate` | queue a job → `{"job": id}` |
| `GET /job?id=` | state, progress, elapsed, queue depth, image list |
| `GET /image?id=&i=` | PNG bytes |
| `POST /cancel` | interrupt + clear the queue |
| `POST /engine/start` · `/stop` · `/restart` | start, kill, or restart ComfyUI on the PC |
| `POST /engine/free` | unload models and free VRAM without stopping the engine |
| `GET /gallery` · `GET /file?rel=` | past outputs |

## App setup

1. Open the app → **Settings**: enter your bridge base URL (Tailscale HTTPS name recommended) and the bridge token from `bridge/token.txt` on the PC.
2. Optionally add a LAN fallback URL for home Wi-Fi.
3. **Test connection** should say *PC online · engine ready*.
4. Create tab → pick model, type a prompt, **Make image**.

## Build

Unsigned IPA, built on a GitHub macOS runner:

```
# trigger: Actions → Build unsigned IPA → Run workflow
gh run watch <id> -R Neo664evr/comfyphone
gh run download <id> -R Neo664evr/comfyphone -n comfyphone-ipa -D dist
```

Load `dist/ComfyPhone-unsigned.ipa` through LiveContainer or your normal sideload path.

## Notes

- Keep the bridge token only in `bridge/token.txt` on the PC and in the app Settings field — never commit a real token or personal Tailscale/LAN addresses.
- ComfyUI itself stays bound to loopback; only the bridge port is reachable, and only over your tailnet or home Wi-Fi.
