using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using DeckWindowsAgent.Configuration;
using DeckWindowsAgent.Screen;

namespace DeckWindowsAgent.Input;

public sealed class WindowsSendInputSink(AgentOptions options, ILogger<WindowsSendInputSink> logger) : IWindowsInputSink
{
    private const uint InputMouse = 0;
    private const uint InputKeyboard = 1;
    private const uint KeyUp = 0x0002;
    private const uint KeyUnicode = 0x0004;
    private const uint KeyExtended = 0x0001;
    private const uint MouseMove = 0x0001;
    private const uint LeftDown = 0x0002;
    private const uint LeftUp = 0x0004;
    private const uint RightDown = 0x0008;
    private const uint RightUp = 0x0010;
    private const uint MiddleDown = 0x0020;
    private const uint MiddleUp = 0x0040;
    private const uint MouseWheel = 0x0800;
    private const uint MouseHWheel = 0x1000;
    private const uint MouseAbsolute = 0x8000;
    private const uint MouseVirtualDesk = 0x4000;
    private const int SmXVirtualScreen = 76;
    private const int SmYVirtualScreen = 77;
    private const int SmCxVirtualScreen = 78;
    private const int SmCyVirtualScreen = 79;
    private const int WheelScale = 12;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly Dictionary<ushort, HashSet<Guid>> _heldKeys = [];
    private readonly List<ushort> _keyPressOrder = [];
    private readonly Dictionary<string, HashSet<Guid>> _heldMouseButtons = new(StringComparer.Ordinal);
    private readonly Dictionary<(Guid SessionId, string Key), List<ushort>> _transientModifiers = [];

    public bool IsAvailable => OperatingSystem.IsWindows()
        && Environment.UserInteractive
        && IsDefaultInputDesktop();

    public async ValueTask ApplyAsync(Guid sessionId, AgentInputCommand command, CancellationToken cancellationToken = default)
    {
        if (!IsAvailable) throw new InputInjectionException("Windows input injection is unavailable in this session.");
        await _gate.WaitAsync(cancellationToken);
        try
        {
            switch (command)
            {
                case RelativePointerCommand pointer:
                    SendMouse(ApplyPointerAcceleration(pointer.DeltaX, pointer.DeltaY, pointer.Acceleration));
                    break;
                case AbsoluteTouchCommand touch:
                    ApplyAbsoluteTouch(sessionId, touch);
                    break;
                case ScrollCommand scroll:
                    SendScroll(scroll);
                    break;
                case MouseButtonCommand button:
                    ApplyMouseButton(sessionId, button);
                    break;
                case ModifierCommand modifier:
                    foreach (var key in ModifierKeys(modifier.Modifiers))
                        ApplyKey(sessionId, key, modifier.IsDown);
                    break;
                case VirtualKeyCommand key:
                    ApplyVirtualKey(sessionId, key);
                    break;
                case KeyChordCommand chord:
                    ApplyKeyChord(sessionId, chord);
                    break;
                case UnicodeTextCommand text:
                    ApplyUnicodeText(text.Text);
                    break;
                case ClipboardTextCommand:
                    throw new InputInjectionException("Clipboard actions are not enabled in this Agent build.");
                case ReleaseAllCommand:
                    ReleaseSessionInternal(sessionId);
                    break;
                default:
                    throw new InputInjectionException("Unsupported input command.");
            }
        }
        catch (Win32Exception error)
        {
            ReleaseAllBestEffort();
            throw new InputInjectionException($"SendInput was rejected by Windows (error {error.NativeErrorCode}).");
        }
        finally
        {
            _gate.Release();
        }
    }

    public async ValueTask ReleaseSessionAsync(Guid sessionId, CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try { ReleaseSessionBestEffort(sessionId); }
        finally { _gate.Release(); }
    }

    public async ValueTask ReleaseAllAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try { ReleaseAllBestEffort(); }
        finally { _gate.Release(); }
    }

    private void ApplyVirtualKey(Guid sessionId, VirtualKeyCommand command)
    {
        var (key, implicitModifiers) = ResolveVirtualKey(command.Key);
        var requestedModifiers = ModifierKeys(command.Modifiers).Concat(implicitModifiers).Distinct().ToArray();
        if (command.IsDown)
        {
            var transient = new List<ushort>();
            foreach (var modifier in requestedModifiers)
            {
                if (_heldKeys.TryGetValue(modifier, out var owners) && owners.Contains(sessionId)) continue;
                ApplyKey(sessionId, modifier, true);
                transient.Add(modifier);
            }
            _transientModifiers[(sessionId, command.Key)] = transient;
            ApplyKey(sessionId, key, true);
        }
        else
        {
            ApplyKey(sessionId, key, false);
            if (_transientModifiers.Remove((sessionId, command.Key), out var transient))
            {
                foreach (var modifier in transient.AsEnumerable().Reverse()) ApplyKey(sessionId, modifier, false);
            }
        }
    }

    private void ApplyKeyChord(Guid sessionId, KeyChordCommand command)
    {
        if (!HotkeyKeyAllowList.IsAllowed(command.KeyCode))
            throw new InputInjectionException("That key is not allowed for remote hotkeys.");
        var modifiers = ModifierKeys(command.Modifiers).ToArray();
        foreach (var modifier in modifiers) ApplyKey(sessionId, modifier, true);
        ApplyKey(sessionId, command.KeyCode, true);
        ApplyKey(sessionId, command.KeyCode, false);
        foreach (var modifier in modifiers.Reverse()) ApplyKey(sessionId, modifier, false);
    }

    private void ApplyKey(Guid sessionId, ushort key, bool isDown)
    {
        if (!_heldKeys.TryGetValue(key, out var owners))
        {
            owners = [];
            _heldKeys[key] = owners;
        }
        if (isDown && !owners.Add(sessionId)) return;
        if (!isDown && !owners.Remove(sessionId)) return;
        if (isDown && owners.Count > 1) return;
        if (!isDown && owners.Count > 0) return;
        var flags = (IsExtendedKey(key) ? KeyExtended : 0) | (isDown ? 0u : KeyUp);
        SendChecked([KeyboardInput(key, '\0', flags)]);
        if (isDown)
        {
            _keyPressOrder.Add(key);
        }
        else
        {
            _heldKeys.Remove(key);
            _keyPressOrder.Remove(key);
        }
    }

    private void ApplyUnicodeText(string text)
    {
        foreach (var codeUnit in text)
        {
            SendChecked([
                KeyboardInput(0, codeUnit, KeyUnicode),
                KeyboardInput(0, codeUnit, KeyUnicode | KeyUp)
            ]);
        }
    }

    private void ApplyMouseButton(Guid sessionId, MouseButtonCommand command)
    {
        var normalized = command.Button.ToLowerInvariant();
        if (!_heldMouseButtons.TryGetValue(normalized, out var owners))
        {
            owners = [];
            _heldMouseButtons[normalized] = owners;
        }
        if (command.IsDown && !owners.Add(sessionId)) return;
        if (!command.IsDown && !owners.Remove(sessionId)) return;
        if (command.IsDown && owners.Count > 1) return;
        if (!command.IsDown && owners.Count > 0) return;
        var flags = (normalized, command.IsDown) switch
        {
            ("left", true) => LeftDown, ("left", false) => LeftUp,
            ("right", true) => RightDown, ("right", false) => RightUp,
            ("middle", true) => MiddleDown, ("middle", false) => MiddleUp,
            _ => throw new InputInjectionException("Unknown mouse button.")
        };
        SendChecked([MouseInput(0, 0, 0, flags)]);
        if (!command.IsDown) _heldMouseButtons.Remove(normalized);
    }

    private static void SendMouse((int X, int Y) delta)
    {
        if (delta.X == 0 && delta.Y == 0) return;
        SendChecked([MouseInput(delta.X, delta.Y, 0, MouseMove)]);
    }

    /// Extend mode's iPad surface acts as a real touchscreen for the virtual display rather
    /// than a relative trackpad: "began" moves the cursor to the touched point and presses the
    /// left button there (in one SendInput call, so the click lands exactly where the finger
    /// touched down, not wherever the cursor happened to already be); "moved" just moves the
    /// (already-down) cursor for the drag; "ended"/"cancelled" moves once more to the final
    /// point and releases. Button ownership reuses _heldMouseButtons so a session that
    /// disconnects mid-touch still gets its left-button-down released by ReleaseSessionInternal.
    private void ApplyAbsoluteTouch(Guid sessionId, AbsoluteTouchCommand touch)
    {
        // Unlike every other command here, a missing extend display is an expected, transient
        // condition (extend mode not currently active on the Agent side, or the virtual display
        // still settling right after attach) rather than a real injection failure -- throwing
        // InputInjectionException would tear down the *entire* input session (see
        // InputWebSocketEndpoint's catch), killing keyboard/mouse too and forcing a full
        // reconnect over one stray touch. Drop it instead.
        var monitor = ResolveExtendMonitor();
        if (monitor is null)
        {
            logger.LogWarning("Ignoring absolute-touch input: no extend-mode display is currently attached.");
            return;
        }
        var (x, y) = NormalizeToVirtualDesktop(monitor.Value, touch.XFraction, touch.YFraction);
        var moveInput = MouseInput(x, y, 0, MouseMove | MouseAbsolute | MouseVirtualDesk);

        if (!_heldMouseButtons.TryGetValue("left", out var owners))
        {
            owners = [];
            _heldMouseButtons["left"] = owners;
        }

        switch (touch.Phase)
        {
            case "began":
                var isFirstDown = owners.Add(sessionId) && owners.Count == 1;
                var downInputs = new List<NativeInput> { moveInput };
                if (isFirstDown) downInputs.Add(MouseInput(x, y, 0, LeftDown));
                SendChecked([.. downInputs]);
                break;
            case "moved":
                SendChecked([moveInput]);
                break;
            case "ended" or "cancelled":
                var isLastUp = owners.Remove(sessionId) && owners.Count == 0;
                var upInputs = new List<NativeInput> { moveInput };
                if (isLastUp) upInputs.Add(MouseInput(x, y, 0, LeftUp));
                SendChecked([.. upInputs]);
                if (owners.Count == 0) _heldMouseButtons.Remove("left");
                break;
            default:
                throw new InputInjectionException("Unknown touch phase.");
        }
    }

    private MonitorDescriptor? ResolveExtendMonitor()
    {
        var deviceName = options.ScreenStream.ExtendMonitorDeviceName ?? VirtualDisplayAttachment.FindVirtualDisplayDeviceName();
        if (deviceName is null) return null;
        foreach (var monitor in MonitorEnumerator.EnumerateAll())
        {
            if (string.Equals(monitor.DeviceName, deviceName, StringComparison.OrdinalIgnoreCase)) return monitor;
        }
        return null;
    }

    /// SendInput's MOUSEEVENTF_ABSOLUTE|MOUSEEVENTF_VIRTUALDESK flags take a position normalized
    /// to 0-65535 across the *entire* virtual desktop (all monitors combined), not the target
    /// monitor alone -- this maps the touch's monitor-relative fraction to a pixel position
    /// within that monitor's bounds, then normalizes that pixel position against the virtual
    /// desktop's bounds from GetSystemMetrics.
    private static (int X, int Y) NormalizeToVirtualDesktop(MonitorDescriptor monitor, double xFraction, double yFraction)
    {
        var clampedX = Math.Clamp(xFraction, 0, 1);
        var clampedY = Math.Clamp(yFraction, 0, 1);
        var absoluteX = monitor.Left + (clampedX * monitor.Width);
        var absoluteY = monitor.Top + (clampedY * monitor.Height);

        var virtualLeft = GetSystemMetrics(SmXVirtualScreen);
        var virtualTop = GetSystemMetrics(SmYVirtualScreen);
        var virtualWidth = Math.Max(1, GetSystemMetrics(SmCxVirtualScreen) - 1);
        var virtualHeight = Math.Max(1, GetSystemMetrics(SmCyVirtualScreen) - 1);

        var normalizedX = (int)Math.Round((absoluteX - virtualLeft) * 65535.0 / virtualWidth);
        var normalizedY = (int)Math.Round((absoluteY - virtualTop) * 65535.0 / virtualHeight);
        return (Math.Clamp(normalizedX, 0, 65535), Math.Clamp(normalizedY, 0, 65535));
    }

    private static void SendScroll(ScrollCommand scroll)
    {
        var inputs = new List<NativeInput>(2);
        var vertical = ClampToInt(scroll.DeltaY * WheelScale);
        var horizontal = ClampToInt(scroll.DeltaX * WheelScale);
        if (vertical != 0) inputs.Add(MouseInput(0, 0, unchecked((uint)vertical), MouseWheel));
        if (horizontal != 0) inputs.Add(MouseInput(0, 0, unchecked((uint)horizontal), MouseHWheel));
        if (inputs.Count > 0) SendChecked([.. inputs]);
    }

    private static (int X, int Y) ApplyPointerAcceleration(double x, double y, bool acceleration)
    {
        var magnitude = Math.Sqrt((x * x) + (y * y));
        var factor = acceleration ? Math.Clamp(0.82 + (magnitude / 28), 0.82, 1.65) : 1;
        return (ClampToInt(x * factor), ClampToInt(y * factor));
    }

    private void ReleaseAllInternal()
    {
        var releases = new List<NativeInput>();
        foreach (var button in _heldMouseButtons.Keys)
        {
            var flags = button switch
            {
                "left" => LeftUp,
                "right" => RightUp,
                "middle" => MiddleUp,
                _ => 0u
            };
            if (flags != 0) releases.Add(MouseInput(0, 0, 0, flags));
        }
        foreach (var key in _keyPressOrder.AsEnumerable().Reverse())
            releases.Add(KeyboardInput(key, '\0', KeyUp | (IsExtendedKey(key) ? KeyExtended : 0)));
        if (releases.Count > 0) SendChecked([.. releases]);
        _heldMouseButtons.Clear();
        _heldKeys.Clear();
        _keyPressOrder.Clear();
        _transientModifiers.Clear();
    }

    private void ReleaseSessionInternal(Guid sessionId)
    {
        var releases = new List<NativeInput>();
        foreach (var pair in _heldMouseButtons.ToArray())
        {
            if (!pair.Value.Remove(sessionId) || pair.Value.Count > 0) continue;
            var flags = pair.Key switch
            {
                "left" => LeftUp,
                "right" => RightUp,
                "middle" => MiddleUp,
                _ => 0u
            };
            if (flags != 0) releases.Add(MouseInput(0, 0, 0, flags));
            _heldMouseButtons.Remove(pair.Key);
        }
        foreach (var pair in _heldKeys.ToArray())
        {
            if (!pair.Value.Remove(sessionId) || pair.Value.Count > 0) continue;
            releases.Add(KeyboardInput(pair.Key, '\0', KeyUp | (IsExtendedKey(pair.Key) ? KeyExtended : 0)));
            _heldKeys.Remove(pair.Key);
            _keyPressOrder.Remove(pair.Key);
        }
        foreach (var transient in _transientModifiers.Keys.Where(value => value.SessionId == sessionId).ToArray())
            _transientModifiers.Remove(transient);
        if (releases.Count > 0) SendChecked([.. releases]);
    }

    private void ReleaseSessionBestEffort(Guid sessionId)
    {
        try { ReleaseSessionInternal(sessionId); }
        catch
        {
            foreach (var owners in _heldKeys.Values) owners.Remove(sessionId);
            foreach (var owners in _heldMouseButtons.Values) owners.Remove(sessionId);
            foreach (var transient in _transientModifiers.Keys.Where(value => value.SessionId == sessionId).ToArray())
                _transientModifiers.Remove(transient);
        }
    }

    private void ReleaseAllBestEffort()
    {
        try { ReleaseAllInternal(); }
        catch { _heldMouseButtons.Clear(); _heldKeys.Clear(); _keyPressOrder.Clear(); _transientModifiers.Clear(); }
    }

    private static IEnumerable<ushort> ModifierKeys(int raw)
    {
        if ((raw & 1) != 0) yield return 0xA2; // VK_LCONTROL
        if ((raw & 2) != 0) yield return 0xA4; // VK_LMENU
        if ((raw & 4) != 0) yield return 0xA0; // VK_LSHIFT
        if ((raw & 8) != 0) yield return 0x5B; // VK_LWIN
    }

    private static bool IsExtendedKey(ushort key) => key is
        0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x2D or 0x2E
        or 0x5B or 0x5C or 0xAD or 0xAE or 0xAF or 0xB0 or 0xB1 or 0xB3;

    private static (ushort Key, ushort[] Modifiers) ResolveVirtualKey(string key) => key switch
    {
        "enter" => (0x0D, []), "tab" => (0x09, []), "escape" => (0x1B, []),
        "backspace" => (0x08, []), "delete" => (0x2E, []),
        "arrowUp" => (0x26, []), "arrowDown" => (0x28, []),
        "arrowLeft" => (0x25, []), "arrowRight" => (0x27, []),
        "home" => (0x24, []), "end" => (0x23, []),
        "pageUp" => (0x21, []), "pageDown" => (0x22, []),
        "copy" => (0x43, [0xA2]), "paste" => (0x56, [0xA2]),
        "undo" => (0x5A, [0xA2]), "redo" => (0x59, [0xA2]),
        "altTab" => (0x09, [0xA4]), "desktop" => (0x44, [0x5B]),
        "function1" => (0x70, []), "function2" => (0x71, []), "function3" => (0x72, []),
        "function4" => (0x73, []), "function5" => (0x74, []), "function6" => (0x75, []),
        "function7" => (0x76, []), "function8" => (0x77, []), "function9" => (0x78, []),
        "function10" => (0x79, []), "function11" => (0x7A, []), "function12" => (0x7B, []),
        "mediaPlayPause" => (0xB3, []), "mediaPrevious" => (0xB1, []), "mediaNext" => (0xB0, []),
        "volumeDown" => (0xAE, []), "volumeUp" => (0xAF, []), "volumeMute" => (0xAD, []),
        _ => throw new InputInjectionException("Unknown virtual key.")
    };

    private static int ClampToInt(double value) => (int)Math.Clamp(Math.Round(value), int.MinValue, int.MaxValue);

    private static void SendChecked(NativeInput[] inputs)
    {
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeInput>());
        if (sent != inputs.Length) throw new Win32Exception(Marshal.GetLastWin32Error());
    }

    private static NativeInput KeyboardInput(ushort virtualKey, char scanCode, uint flags) => new()
    {
        Type = InputKeyboard,
        Union = new InputUnion { Keyboard = new KeyboardInputData { VirtualKey = virtualKey, ScanCode = scanCode, Flags = flags } }
    };

    private static NativeInput MouseInput(int x, int y, uint data, uint flags) => new()
    {
        Type = InputMouse,
        Union = new InputUnion { Mouse = new MouseInputData { X = x, Y = y, MouseData = data, Flags = flags } }
    };

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint inputCount, [In] NativeInput[] inputs, int inputSize);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint desiredAccess);

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder information, int length, out int needed);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseDesktop(IntPtr desktop);

    private static bool IsDefaultInputDesktop()
    {
        const uint desktopReadObjects = 0x0001;
        const int userObjectName = 2;
        var desktop = OpenInputDesktop(0, false, desktopReadObjects);
        if (desktop == IntPtr.Zero) return false;
        try
        {
            var name = new StringBuilder(64);
            return GetUserObjectInformation(desktop, userObjectName, name, name.Capacity * sizeof(char), out _)
                && string.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            _ = CloseDesktop(desktop);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInput { public uint Type; public InputUnion Union; }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public MouseInputData Mouse;
        [FieldOffset(0)] public KeyboardInputData Keyboard;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInputData
    {
        public int X; public int Y; public uint MouseData; public uint Flags; public uint Time; public UIntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInputData
    {
        public ushort VirtualKey; public ushort ScanCode; public uint Flags; public uint Time; public UIntPtr ExtraInfo;
    }
}
