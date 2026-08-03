using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

namespace DeckWindowsAgent.Input;

public sealed class WindowsSendInputSink : IWindowsInputSink
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
    private const int WheelScale = 12;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly HashSet<ushort> _heldKeys = [];
    private readonly List<ushort> _keyPressOrder = [];
    private readonly HashSet<string> _heldMouseButtons = new(StringComparer.Ordinal);
    private readonly Dictionary<string, List<ushort>> _transientModifiers = new(StringComparer.Ordinal);

    public bool IsAvailable => OperatingSystem.IsWindows()
        && Environment.UserInteractive
        && IsDefaultInputDesktop();

    public async ValueTask ApplyAsync(AgentInputCommand command, CancellationToken cancellationToken = default)
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
                case ScrollCommand scroll:
                    SendScroll(scroll);
                    break;
                case MouseButtonCommand button:
                    ApplyMouseButton(button);
                    break;
                case ModifierCommand modifier:
                    foreach (var key in ModifierKeys(modifier.Modifiers))
                        ApplyKey(key, modifier.IsDown);
                    break;
                case VirtualKeyCommand key:
                    ApplyVirtualKey(key);
                    break;
                case UnicodeTextCommand text:
                    ApplyUnicodeText(text.Text);
                    break;
                case ClipboardTextCommand:
                    throw new InputInjectionException("Clipboard actions are not enabled in this Agent build.");
                case ReleaseAllCommand:
                    ReleaseAllInternal();
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

    public async ValueTask ReleaseAllAsync(CancellationToken cancellationToken = default)
    {
        await _gate.WaitAsync(cancellationToken);
        try { ReleaseAllBestEffort(); }
        finally { _gate.Release(); }
    }

    private void ApplyVirtualKey(VirtualKeyCommand command)
    {
        var (key, implicitModifiers) = ResolveVirtualKey(command.Key);
        var requestedModifiers = ModifierKeys(command.Modifiers).Concat(implicitModifiers).Distinct().ToArray();
        if (command.IsDown)
        {
            var transient = new List<ushort>();
            foreach (var modifier in requestedModifiers)
            {
                if (_heldKeys.Contains(modifier)) continue;
                ApplyKey(modifier, true);
                transient.Add(modifier);
            }
            _transientModifiers[command.Key] = transient;
            ApplyKey(key, true);
        }
        else
        {
            ApplyKey(key, false);
            if (_transientModifiers.Remove(command.Key, out var transient))
            {
                foreach (var modifier in transient.AsEnumerable().Reverse()) ApplyKey(modifier, false);
            }
        }
    }

    private void ApplyKey(ushort key, bool isDown)
    {
        if (isDown && _heldKeys.Contains(key)) return;
        if (!isDown && !_heldKeys.Contains(key)) return;
        var flags = (IsExtendedKey(key) ? KeyExtended : 0) | (isDown ? 0u : KeyUp);
        SendChecked([KeyboardInput(key, 0, flags)]);
        if (isDown)
        {
            _heldKeys.Add(key);
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

    private void ApplyMouseButton(MouseButtonCommand command)
    {
        var normalized = command.Button.ToLowerInvariant();
        if (command.IsDown && _heldMouseButtons.Contains(normalized)) return;
        if (!command.IsDown && !_heldMouseButtons.Contains(normalized)) return;
        var flags = (normalized, command.IsDown) switch
        {
            ("left", true) => LeftDown, ("left", false) => LeftUp,
            ("right", true) => RightDown, ("right", false) => RightUp,
            ("middle", true) => MiddleDown, ("middle", false) => MiddleUp,
            _ => throw new InputInjectionException("Unknown mouse button.")
        };
        SendChecked([MouseInput(0, 0, 0, flags)]);
        if (command.IsDown) _heldMouseButtons.Add(normalized);
        else _heldMouseButtons.Remove(normalized);
    }

    private static void SendMouse((int X, int Y) delta)
    {
        if (delta.X == 0 && delta.Y == 0) return;
        SendChecked([MouseInput(delta.X, delta.Y, 0, MouseMove)]);
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
        foreach (var button in _heldMouseButtons)
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
            releases.Add(KeyboardInput(key, 0, KeyUp | (IsExtendedKey(key) ? KeyExtended : 0)));
        if (releases.Count > 0) SendChecked([.. releases]);
        _heldMouseButtons.Clear();
        _heldKeys.Clear();
        _keyPressOrder.Clear();
        _transientModifiers.Clear();
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

    private static NativeInput KeyboardInput(ushort virtualKey, ushort scanCode, uint flags) => new()
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
