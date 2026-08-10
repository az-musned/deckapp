using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;

namespace DeckWindowsAgent.Discord;

/// <summary>Raw framing for Discord's local RPC named pipe (`\\.\pipe\discord-ipc-{0..9}`): each frame is an
/// 8-byte little-endian (opcode, length) header followed by a UTF-8 JSON payload.</summary>
public sealed class DiscordIpcTransport : IAsyncDisposable
{
    public const int OpcodeHandshake = 0;
    public const int OpcodeFrame = 1;
    public const int OpcodeClose = 2;
    public const int OpcodePing = 3;
    public const int OpcodePong = 4;

    private const int MaximumFrameBytes = 1024 * 1024;

    private NamedPipeClientStream? _pipe;

    public bool IsConnected => _pipe?.IsConnected == true;

    public async Task<bool> TryConnectAsync(CancellationToken cancellationToken)
    {
        for (var index = 0; index < 10; index++)
        {
            var pipe = new NamedPipeClientStream(".", $"discord-ipc-{index}", PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                await pipe.ConnectAsync(250, cancellationToken);
                _pipe = pipe;
                return true;
            }
            catch (Exception) when (!cancellationToken.IsCancellationRequested)
            {
                pipe.Dispose();
            }
        }
        return false;
    }

    public async Task SendAsync(int opcode, string json, CancellationToken cancellationToken)
    {
        if (_pipe is null) throw new InvalidOperationException("The Discord IPC pipe is not connected.");
        var payload = Encoding.UTF8.GetBytes(json);
        var header = new byte[8];
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(0, 4), opcode);
        BinaryPrimitives.WriteInt32LittleEndian(header.AsSpan(4, 4), payload.Length);
        await _pipe.WriteAsync(header, cancellationToken);
        await _pipe.WriteAsync(payload, cancellationToken);
        await _pipe.FlushAsync(cancellationToken);
    }

    public async Task<(int Opcode, string Json)> ReceiveAsync(CancellationToken cancellationToken)
    {
        if (_pipe is null) throw new InvalidOperationException("The Discord IPC pipe is not connected.");
        var header = new byte[8];
        await ReadExactAsync(_pipe, header, cancellationToken);
        var opcode = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(0, 4));
        var length = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(4, 4));
        if (length is < 0 or > MaximumFrameBytes) throw new InvalidOperationException("Discord IPC frame length is out of range.");
        var payload = new byte[length];
        await ReadExactAsync(_pipe, payload, cancellationToken);
        return (opcode, Encoding.UTF8.GetString(payload));
    }

    private static async Task ReadExactAsync(Stream stream, byte[] buffer, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < buffer.Length)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset), cancellationToken);
            if (read == 0) throw new IOException("The Discord IPC pipe closed unexpectedly.");
            offset += read;
        }
    }

    public ValueTask DisposeAsync()
    {
        _pipe?.Dispose();
        _pipe = null;
        return ValueTask.CompletedTask;
    }
}
