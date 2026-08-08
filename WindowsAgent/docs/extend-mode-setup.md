# Setting up Extend Mode

Extend mode makes the iPad act as a genuine second Windows monitor — you can drag windows
onto it, and it shows independent content, unlike mirror mode which just shows a copy of
your primary display.

Windows has no built-in way to create a "fake" monitor for an app to draw into, so extend
mode relies on a separate, third-party virtual display driver. The Agent's job is only to
detect and capture that virtual monitor — it does not install or manage the driver itself.

## 1. Install Virtual-Display-Driver

Install [VirtualDrivers/Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver).
It's an open-source, properly signed (via SignPath.io) indirect display driver — no
test-signing mode or driver-signature-enforcement changes needed. It's the same class of
driver used by tools like Sunshine/Moonlight.

Follow the project's own install instructions. Once installed, you should see a new
monitor appear in Windows' Display Settings.

## 2. Set the virtual monitor's resolution to match your iPad

Extend mode fills the entire iPad screen (unlike mirror mode, which letterboxes to
preserve aspect ratio) — so the virtual monitor should be configured at your iPad's
resolution, not left at a default.

Find your iPad's resolution: Settings → Display & Brightness → look up your model's native
point resolution (e.g. iPad Pro 11" is 2388×1668 pixels; check Apple's tech specs page
for your exact model if unsure).

Set that resolution either via the "Virtual Driver Control" GUI app (comes with the
driver), or by directly editing `C:\VirtualDisplayDriver\vdd_settings.xml`.

## 3. Tell the Agent which monitor is the virtual one

The Agent tries to auto-detect the virtual monitor by matching its resolution against
`vdd_settings.xml`, but this is a best-effort heuristic — Virtual-Display-Driver doesn't
expose a reliable way to identify itself. If auto-detection doesn't pick the right
monitor (check the Agent's console/log output for a warning), set it explicitly.

In `appsettings.Local.json` (or `appsettings.json`), under `Agent:ScreenStream`:

```json
"ScreenStream": {
  "ExtendMonitorDeviceName": "\\\\.\\DISPLAY2"
}
```

To find the exact device name, check the Agent's startup logs, or use Windows' own
Display Settings identify feature and cross-reference against `EnumDisplayMonitors`
output (the Agent logs a warning naming the monitor it fell back to if your configured
name doesn't match anything currently attached).

## 4. Connect from the iPad

Open the Screen Mirror widget configured for Extend mode (a separate widget instance
from the Mirror one — each widget on the dashboard is configured for one mode). It
connects to `wss://<agent>/api/v1/screen/mirror/ws?mode=extend`.

Only one mode (mirror or extend) can be actively streamed at a time in this version — if
you try to open the other mode while one is already active, you'll see a "currently
active in [mode] mode" error. Disconnect the active session first.
