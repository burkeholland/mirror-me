using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using WinPlay.Capture;
using WinPlay.Core.Discovery;
using WinPlay.Core.Hap;
using WinPlay.Core.Mdns;
using WinPlay.Core.Mirror;

namespace MirrorMe.Sender;

internal sealed record Target(string Id, string Name, string Model, string Address, int Port, bool CanMirror, string Reason);
internal sealed record Command(int Protocol, string CommandName, Target? Target, string? Pin);

internal static class Program
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    private static readonly object OutputLock = new();

    private static void Emit(string status, object? targets = null, string? error = null)
    {
        lock (OutputLock)
            Console.WriteLine(JsonSerializer.Serialize(new { protocol = 1, status, targets, error }, Json));
    }

    public static async Task<int> Main()
    {
        using var lifetime = new CancellationTokenSource();
        var pins = Channel.CreateBounded<string>(1);
        string phase = "start desktop casting";
        try
        {
            var first = await ReadCommandAsync();
            if (first is null) return 0;
            // Pipe EOF and Stop cancel discovery, a pending PIN, or the active stream.
            // Console's synchronized reader may block before returning its Task.
            var input = Task.Run(() => PumpInputAsync(pins.Writer, lifetime));
            Task operation;
            if (first.CommandName == "discover")
            {
                phase = "discover AirPlay targets";
                operation = DiscoverAsync(lifetime.Token);
            }
            else if (first.CommandName == "start" && first.Target is { } target)
            {
                phase = "mirror the desktop (check AirPlay access settings or pair again)";
                operation = MirrorAsync(target, pins.Reader, lifetime.Token);
            }
            else throw new InvalidDataException("Unsupported sender command.");

            var completed = await Task.WhenAny(operation, input);
            if (completed == input)
            {
                lifetime.Cancel();
                await input;
            }
            await operation;
            return 0;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested)
        {
            Emit("stopped");
            return 0;
        }
        catch (Exception ex)
        {
            // This is the process boundary; errors must reach the control window,
            // not disappear into a background capture/network thread.
            Emit("error", error: $"Could not {phase}: {ex.Message}");
            return 1;
        }
        finally
        {
            lifetime.Cancel();
        }
    }

    private static async Task<Command?> ReadCommandAsync()
    {
        string? line = await Console.In.ReadLineAsync();
        if (line is null) return null;
        if (line.Length > 8192) throw new InvalidDataException("Sender command is too large.");
        var command = JsonSerializer.Deserialize<Command>(line, Json);
        if (command is null || command.Protocol != 1) throw new InvalidDataException("Incompatible sender protocol.");
        return command;
    }

    private static async Task PumpInputAsync(ChannelWriter<string> pins, CancellationTokenSource lifetime)
    {
        try
        {
            while (await ReadCommandAsync() is { } command)
            {
                if (command.CommandName == "stop") return;
                if (command.CommandName != "pin" || command.Pin is not { Length: 4 } pin
                    || !pin.All(char.IsAsciiDigit) || !pins.TryWrite(pin))
                    throw new InvalidDataException("Expected a four-digit pairing code or Stop.");
            }
        }
        finally
        {
            lifetime.Cancel();
            pins.TryComplete();
        }
    }

    private static async Task DiscoverAsync(CancellationToken ct)
    {
        var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var transport = new MdnsClient();
        transport.ReceiveError += ex => failed.TrySetException(ex);
        using var browser = new AirPlayBrowser(transport);
        browser.Start();
        var scan = Task.Delay(TimeSpan.FromSeconds(6), ct);
        await await Task.WhenAny(scan, failed.Task);
        ct.ThrowIfCancellationRequested();

        var local = NetworkInterface.GetAllNetworkInterfaces()
            .SelectMany(n => n.GetIPProperties().UnicastAddresses).Select(a => a.Address).ToHashSet();
        var targets = browser.Snapshot()
            .Where(d => !d.Addresses.Any(local.Contains))
            .Select(d => (device: d, address: d.Addresses.FirstOrDefault(IsUsableAddress)))
            .Where(d => d.address is not null)
            .Where(d => d.device.DeviceId.Length is > 0 and <= 128 && d.device.Name.Length is > 0 and <= 256
                && (d.device.Model?.Length ?? 0) <= 128 && (d.device.AirPlayPort ?? d.device.RaopPort) is > 0 and <= 65535)
            .OrderBy(d => d.device.Name, StringComparer.OrdinalIgnoreCase)
            .Take(64)
            .Select(d =>
            {
                bool compatible = d.device.IsMirroringCandidate && d.device.AirPlayPort is > 0 and <= 65535;
                return new Target(d.device.DeviceId, d.device.Name, d.device.Model ?? "AirPlay",
                    d.address!.ToString(), d.device.AirPlayPort ?? d.device.RaopPort ?? 0, compatible,
                    compatible ? "" : "Audio-only or no screen-mirroring service advertised.");
            }).ToArray();
        Emit("ready", targets);
    }

    private static bool IsUsableAddress(IPAddress address) =>
        address.AddressFamily == AddressFamily.InterNetwork
        && !IPAddress.IsLoopback(address) && !address.Equals(IPAddress.Any)
        && address.GetAddressBytes()[0] is > 0 and < 224;

    private static async Task MirrorAsync(Target target, ChannelReader<string> pins, CancellationToken ct)
    {
        if (!target.CanMirror || target.Port is < 1 or > 65535 || target.Id.Length is < 1 or > 256
            || !IPAddress.TryParse(target.Address, out var address) || !IsUsableAddress(address))
            throw new InvalidDataException("Select a discovered screen-mirroring target.");

        var credentials = LoadCredentials(target.Id);
        if (credentials is null)
        {
            using var beginTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            beginTimeout.CancelAfter(TimeSpan.FromSeconds(20));
            using var pairing = await ReceiverPairing.BeginAsync(address, target.Port, beginTimeout.Token);
            Emit("pairing");
            string pin = await pins.ReadAsync(ct).AsTask().WaitAsync(TimeSpan.FromMinutes(2), ct);
            using var finishTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
            finishTimeout.CancelAfter(TimeSpan.FromSeconds(20));
            credentials = await pairing.FinishAsync(pin, finishTimeout.Token);
            SaveCredentials(target.Id, credentials);
        }

        Emit("connecting");
        using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        connectTimeout.CancelAfter(TimeSpan.FromSeconds(25));
        await using var session = await MirrorSession.ConnectAsync(address, target.Port, credentials,
            ct: connectTimeout.Token, withAudio: false);
        var failed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var source = new ScreenMirrorSource(fps: 30);
        source.Failed += ex => failed.TrySetException(ex);
        await session.StartStreamingAsync(source);
        long lastFrames = 0;
        var progress = Stopwatch.StartNew();
        bool streaming = false;
        while (true)
        {
            await await Task.WhenAny(Task.Delay(250, ct), failed.Task, session.Failure);
            ct.ThrowIfCancellationRequested();
            long frames = session.FramesSent;
            if (frames > lastFrames)
            {
                lastFrames = frames;
                progress.Restart();
                if (!streaming)
                {
                    // Count completed TCP writes, not captured or queued frames.
                    streaming = true;
                    Emit("streaming");
                }
            }
            if (progress.Elapsed > TimeSpan.FromSeconds(12))
                throw new IOException("No video reached the AirPlay data channel for 12 seconds. Check the display and network, then reconnect.");
        }
    }

    private static string CredentialPath(string id) => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MirrorMe", "sender",
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))) + ".dat");

    private static HapPairingCredentials? LoadCredentials(string id)
    {
        string path = CredentialPath(id);
        if (!File.Exists(path)) return null;
        byte[] plain = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
        try
        {
            return JsonSerializer.Deserialize<HapPairingCredentials>(plain, Json)
                ?? throw new InvalidDataException("Pairing credentials are invalid. Forget this target and pair again.");
        }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    private static void SaveCredentials(string id, HapPairingCredentials credentials)
    {
        string path = CredentialPath(id);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        byte[] plain = JsonSerializer.SerializeToUtf8Bytes(credentials, Json);
        string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllBytes(temporary, ProtectedData.Protect(plain, null, DataProtectionScope.CurrentUser));
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
