// WASAPI loopback capture for webpcap display REC (system / "what you hear").
// Compiled at runtime by video-host.ps1 via Add-Type. Writes 16-bit PCM WAV.
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public sealed class WasapiLoopbackRecorder : IDisposable
{
    public const int eRender = 0;
    public const int eConsole = 0;
    public const int AUDCLNT_SHAREMODE_SHARED = 0;
    public const int AUDCLNT_STREAMFLAGS_LOOPBACK = 0x00020000;
    public const int AUDCLNT_BUFFERFLAGS_SILENT = 0x2;
    public const ushort WAVE_FORMAT_PCM = 0x0001;
    public const ushort WAVE_FORMAT_IEEE_FLOAT = 0x0003;
    public const ushort WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

    private Thread _thread;
    private volatile bool _run;
    private string _path;
    private string _error;
    private DateTime _startedUtc;
    private readonly object _gate = new object();
    private readonly ManualResetEventSlim _started = new ManualResetEventSlim(false);

    public string LastError { get { lock (_gate) { return _error; } } }
    public bool IsRunning { get { return _run && _thread != null && _thread.IsAlive; } }
    /// <summary>Wall-clock time when WASAPI capture actually began (client.Start). MinValue if never.</summary>
    public DateTime StartedUtc { get { lock (_gate) { return _startedUtc; } } }
    // 2026-10-17: device actually captured (friendly name + endpoint id) and a log of anything
    // that happened mid-REC (default output changed, device lost, silence padded).
    private string _deviceName = "", _deviceId = "";
    private readonly System.Text.StringBuilder _events = new System.Text.StringBuilder();
    private long _paddedFrames;
    public string DeviceName { get { lock (_gate) { return _deviceName; } } }
    public string DeviceId { get { lock (_gate) { return _deviceId; } } }
    public string Events { get { lock (_gate) { return _events.ToString(); } } }
    public long PaddedFrames { get { lock (_gate) { return _paddedFrames; } } }
    private void Note(string m) { lock (_gate) { if (_events.Length < 4000) _events.Append(DateTime.Now.ToString("HH:mm:ss")).Append(' ').Append(m).Append("; "); } }

    // Current default render endpoint (same role the capture uses). "name|id" or "" on failure.
    public static string DefaultDeviceInfo()
    {
        IMMDeviceEnumerator en = null; IMMDevice dev = null;
        try
        {
            en = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            if (en.GetDefaultAudioEndpoint(eRender, eConsole, out dev) != 0 || dev == null) return "";
            return FriendlyName(dev) + "|" + DevId(dev);
        }
        catch { return ""; }
        finally
        {
            if (dev != null) try { Marshal.ReleaseComObject(dev); } catch { }
            if (en != null) try { Marshal.ReleaseComObject(en); } catch { }
        }
    }

    public void Start(string wavPath)
    {
        if (string.IsNullOrEmpty(wavPath)) throw new ArgumentException("wavPath");
        Stop();
        _path = wavPath;
        lock (_gate) { _error = null; _startedUtc = DateTime.MinValue; _deviceName = ""; _deviceId = ""; _events.Length = 0; _paddedFrames = 0; }
        _started.Reset();
        _run = true;
        _thread = new Thread(CaptureThread) { IsBackground = true, Name = "webpcap-wasapi-loopback" };
        _thread.Start();
        // Wait until capture starts (or fails) so host can measure A/V offset accurately
        if (!_started.Wait(3000))
            throw new InvalidOperationException("WASAPI loopback failed to start in time");
        if (LastError != null)
            throw new InvalidOperationException(LastError);
    }

    public void Stop()
    {
        _run = false;
        var t = _thread;
        if (t != null)
        {
            if (!t.Join(8000))
            {
                try { t.Interrupt(); } catch { }
                t.Join(1000);
            }
        }
        _thread = null;
        try { _started.Set(); } catch { }
    }

    public void Dispose() { Stop(); }

    private void SetError(string msg)
    {
        lock (_gate) { _error = msg; }
        try { _started.Set(); } catch { }
    }

    private void MarkStarted()
    {
        lock (_gate) { _startedUtc = DateTime.UtcNow; }
        try { _started.Set(); } catch { }
    }

    // Open loopback on the current default render endpoint. Returns null + sets err on failure.
    private sealed class Loop
    {
        public IMMDevice Device; public IAudioClient Client; public IAudioCaptureClient Capture;
        public IntPtr MixFmt; public WaveFormatEx Wfx; public string Name = "", Id = "";
        public void Release()
        {
            try { if (Client != null) Client.Stop(); } catch { }
            if (MixFmt != IntPtr.Zero) { Marshal.FreeCoTaskMem(MixFmt); MixFmt = IntPtr.Zero; }
            if (Capture != null) try { Marshal.ReleaseComObject(Capture); } catch { }
            if (Client != null) try { Marshal.ReleaseComObject(Client); } catch { }
            if (Device != null) try { Marshal.ReleaseComObject(Device); } catch { }
            Capture = null; Client = null; Device = null;
        }
    }

    private static Loop OpenDefault(IMMDeviceEnumerator enumerator, out string err)
    {
        err = null;
        var L = new Loop();
        try
        {
            int hr = enumerator.GetDefaultAudioEndpoint(eRender, eConsole, out L.Device);
            if (hr != 0) { err = "GetDefaultAudioEndpoint 0x" + hr.ToString("X8"); L.Release(); return null; }
            L.Name = FriendlyName(L.Device); L.Id = DevId(L.Device);
            object oClient;
            Guid iidClient = typeof(IAudioClient).GUID;
            hr = L.Device.Activate(ref iidClient, 1 /*CLSCTX_INPROC_SERVER*/, IntPtr.Zero, out oClient);
            if (hr != 0) { err = "Activate IAudioClient 0x" + hr.ToString("X8"); L.Release(); return null; }
            L.Client = (IAudioClient)oClient;
            hr = L.Client.GetMixFormat(out L.MixFmt);
            if (hr != 0 || L.MixFmt == IntPtr.Zero) { err = "GetMixFormat 0x" + hr.ToString("X8"); L.Release(); return null; }
            L.Wfx = WaveFormatEx.FromPointer(L.MixFmt);
            hr = L.Client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 30000000, 0, L.MixFmt, IntPtr.Zero);
            if (hr != 0) { err = "IAudioClient.Initialize loopback 0x" + hr.ToString("X8"); L.Release(); return null; }
            object oCap;
            Guid iidCap = typeof(IAudioCaptureClient).GUID;
            hr = L.Client.GetService(ref iidCap, out oCap);
            if (hr != 0) { err = "GetService IAudioCaptureClient 0x" + hr.ToString("X8"); L.Release(); return null; }
            L.Capture = (IAudioCaptureClient)oCap;
            return L;
        }
        catch (Exception ex) { err = ex.Message; L.Release(); return null; }
    }

    private static string DevId(IMMDevice d)
    {
        try { IntPtr p; if (d.GetId(out p) == 0 && p != IntPtr.Zero) { string s = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p); return s ?? ""; } } catch { }
        return "";
    }

    private static string FriendlyName(IMMDevice d)
    {
        IPropertyStore ps = null;
        try
        {
            if (d.OpenPropertyStore(0 /*STGM_READ*/, out ps) != 0 || ps == null) return "";
            var key = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 }; // PKEY_Device_FriendlyName
            var pv = new PropVariant();
            if (ps.GetValue(ref key, out pv) != 0) return "";
            string s = (pv.vt == 31 /*VT_LPWSTR*/ && pv.p != IntPtr.Zero) ? Marshal.PtrToStringUni(pv.p) : "";
            try { PropVariantClear(ref pv); } catch { }
            return s ?? "";
        }
        catch { return ""; }
        finally { if (ps != null) try { Marshal.ReleaseComObject(ps); } catch { } }
    }

    [DllImport("ole32.dll")] private static extern int PropVariantClear(ref PropVariant pv);

    private void CaptureThread()
    {
        IMMDeviceEnumerator enumerator = null;
        Loop cur = null;
        FileStream fs = null;
        BinaryWriter bw = null;
        long dataBytes = 0;
        long dataSizePos = 0;
        long riffSizePos = 0;

        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            string err;
            cur = OpenDefault(enumerator, out err);
            if (cur == null) { SetError(err); return; }
            lock (_gate) { _deviceName = cur.Name; _deviceId = cur.Id; }

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path)) ?? ".");
            fs = new FileStream(_path, FileMode.Create, FileAccess.Write, FileShare.Read);
            bw = new BinaryWriter(fs);

            // Always write 16-bit PCM stereo-or-mono at mix sample rate (ffmpeg-friendly).
            // The WAV format is fixed by the device we started on.
            int outCh = cur.Wfx.nChannels;
            int outRate = (int)cur.Wfx.nSamplesPerSec;
            int outBits = 16;
            int outBlock = outCh * outBits / 8;
            WriteWavHeader(bw, outCh, outRate, outBits, 0, out riffSizePos, out dataSizePos);

            int hr = cur.Client.Start();
            if (hr != 0) { SetError("IAudioClient.Start 0x" + hr.ToString("X8")); return; }
            MarkStarted();
            var clock = System.Diagnostics.Stopwatch.StartNew();
            long lastPacketMs = 0, lastDefaultCheckMs = 0;
            bool lost = false;   // device gone and no compatible replacement: silence only
            string skipId = "";  // incompatible default already logged - don't retry it every second

            byte[] silenceScratch = null;
            while (_run)
            {
                long nowMs = clock.ElapsedMilliseconds;

                // Watch the default output about once a second (log; follow it when compatible)
                if (nowMs - lastDefaultCheckMs >= 1000)
                {
                    lastDefaultCheckMs = nowMs;
                    string info = DefaultDeviceInfo();
                    int bar = info.LastIndexOf('|');
                    string defId = bar >= 0 ? info.Substring(bar + 1) : "";
                    if (defId != "" && (lost || defId != cur.Id) && !(defId == skipId && !lost))
                    {
                        string defName = bar >= 0 ? info.Substring(0, bar) : info;
                        Loop nx = OpenDefault(enumerator, out err);
                        if (nx != null && nx.Wfx.nChannels == outCh && (int)nx.Wfx.nSamplesPerSec == outRate && nx.Client.Start() == 0)
                        {
                            Note("default output changed: " + (lost ? "(lost)" : cur.Name) + " -> " + nx.Name + " (switched)");
                            if (cur != null) cur.Release();
                            cur = nx; lost = false;
                            lock (_gate) { _deviceName = cur.Name; _deviceId = cur.Id; }
                        }
                        else
                        {
                            string why = nx == null ? ("open failed " + err) : ("format " + nx.Wfx.nChannels + "ch/" + nx.Wfx.nSamplesPerSec + "Hz differs from " + outCh + "ch/" + outRate + "Hz");
                            if (nx != null) nx.Release();
                            // remember it so the same change is not retried/logged every second
                            if (!lost) Note("default output changed to " + defName + " - kept " + cur.Name + " (" + why + ")");
                            skipId = defId;
                        }
                    }
                }

                uint packet = 0;
                if (!lost)
                {
                    hr = cur.Capture.GetNextPacketSize(out packet);
                    if (hr != 0)
                    {
                        Note("capture device lost (0x" + hr.ToString("X8") + ") on " + cur.Name + " - silence until a compatible default appears");
                        lost = true; lastDefaultCheckMs = 0; packet = 0;
                    }
                }

                if (packet == 0)
                {
                    // Loopback delivers NO packets while nothing plays on the device. Fill the
                    // gap with silence (after 150 ms idle) so the WAV keeps wall-clock time.
                    if (nowMs - lastPacketMs >= 150)
                        PadSilenceTo(bw, nowMs, outRate, outBlock, ref dataBytes, ref silenceScratch);
                    Thread.Sleep(5);
                    continue;
                }

                IntPtr data;
                uint frames;
                int flags;
                long devPos, qpcPos;
                hr = cur.Capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos);
                if (hr != 0) { Note("GetBuffer 0x" + hr.ToString("X8") + " - silence"); lost = true; lastDefaultCheckMs = 0; continue; }
                lastPacketMs = clock.ElapsedMilliseconds;

                var wfx = cur.Wfx;
                int byteLen = (int)frames * wfx.nBlockAlign;
                if (byteLen > 0)
                {
                    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0)
                    {
                        if (silenceScratch == null || silenceScratch.Length < byteLen)
                            silenceScratch = new byte[byteLen];
                        else
                            Array.Clear(silenceScratch, 0, byteLen);
                        WriteAsPcm16(bw, silenceScratch, byteLen, wfx, ref dataBytes);
                    }
                    else if (data != IntPtr.Zero)
                    {
                        byte[] buf = new byte[byteLen];
                        Marshal.Copy(data, buf, 0, byteLen);
                        WriteAsPcm16(bw, buf, byteLen, wfx, ref dataBytes);
                    }
                }

                cur.Capture.ReleaseBuffer(frames);
            }

            // Trailing idle: pad to the stop moment so the WAV covers the whole REC
            PadSilenceTo(bw, clock.ElapsedMilliseconds, outRate, outBlock, ref dataBytes, ref silenceScratch);
            try { if (cur != null) cur.Client.Stop(); } catch { }

            // patch WAV sizes
            bw.Flush();
            fs.Position = riffSizePos;
            bw.Write((int)(36 + dataBytes));
            fs.Position = dataSizePos;
            bw.Write((int)dataBytes);
            bw.Flush();
        }
        catch (Exception ex)
        {
            SetError(ex.Message);
        }
        finally
        {
            if (bw != null) try { bw.Dispose(); } catch { }
            if (fs != null) try { fs.Dispose(); } catch { }
            if (cur != null) cur.Release();
            if (enumerator != null) try { Marshal.ReleaseComObject(enumerator); } catch { }
        }
    }

    // Write zero frames until the WAV reaches elapsedMs of audio (no-op if already there).
    private void PadSilenceTo(BinaryWriter bw, long elapsedMs, int rate, int block, ref long dataBytes, ref byte[] scratch)
    {
        long want = elapsedMs * (long)rate / 1000;
        long have = dataBytes / block;
        long gap = want - have;
        if (gap <= 0) return;
        if (scratch == null || scratch.Length < 65536) scratch = new byte[65536];
        else Array.Clear(scratch, 0, scratch.Length);
        long bytes = gap * block;
        while (bytes > 0)
        {
            int n = (int)Math.Min(bytes, scratch.Length - (scratch.Length % block));
            bw.Write(scratch, 0, n);
            bytes -= n; dataBytes += n;
        }
        lock (_gate) { _paddedFrames += gap; }
    }

    private static void WriteWavHeader(BinaryWriter bw, int channels, int sampleRate, int bits, int dataLen, out long riffSizePos, out long dataSizePos)
    {
        int blockAlign = channels * bits / 8;
        int avgBytes = sampleRate * blockAlign;
        bw.Write(new char[] { 'R', 'I', 'F', 'F' });
        riffSizePos = bw.BaseStream.Position;
        bw.Write(36 + dataLen);
        bw.Write(new char[] { 'W', 'A', 'V', 'E' });
        bw.Write(new char[] { 'f', 'm', 't', ' ' });
        bw.Write(16);
        bw.Write((ushort)WAVE_FORMAT_PCM);
        bw.Write((ushort)channels);
        bw.Write(sampleRate);
        bw.Write(avgBytes);
        bw.Write((ushort)blockAlign);
        bw.Write((ushort)bits);
        bw.Write(new char[] { 'd', 'a', 't', 'a' });
        dataSizePos = bw.BaseStream.Position;
        bw.Write(dataLen);
    }

    private static void WriteAsPcm16(BinaryWriter bw, byte[] src, int byteLen, WaveFormatEx wfx, ref long dataBytes)
    {
        int ch = wfx.nChannels;
        int bits = wfx.wBitsPerSample;
        bool isFloat = wfx.IsFloat;
        int frameCount;

        if (isFloat && bits == 32)
        {
            frameCount = byteLen / (4 * ch);
            for (int i = 0; i < frameCount; i++)
            {
                for (int c = 0; c < ch; c++)
                {
                    float f = BitConverter.ToSingle(src, (i * ch + c) * 4);
                    if (f > 1f) f = 1f;
                    if (f < -1f) f = -1f;
                    short s = (short)Math.Round(f * 32767.0);
                    bw.Write(s);
                    dataBytes += 2;
                }
            }
            return;
        }

        if (!isFloat && bits == 16)
        {
            bw.Write(src, 0, byteLen);
            dataBytes += byteLen;
            return;
        }

        if (!isFloat && bits == 32)
        {
            frameCount = byteLen / (4 * ch);
            for (int i = 0; i < frameCount; i++)
            {
                for (int c = 0; c < ch; c++)
                {
                    int sample = BitConverter.ToInt32(src, (i * ch + c) * 4);
                    short s = (short)(sample >> 16);
                    bw.Write(s);
                    dataBytes += 2;
                }
            }
            return;
        }

        // fallback: treat as raw bytes truncated to even
        int n = byteLen & ~1;
        bw.Write(src, 0, n);
        dataBytes += n;
    }

    private struct WaveFormatEx
    {
        public ushort wFormatTag;
        public ushort nChannels;
        public uint nSamplesPerSec;
        public uint nAvgBytesPerSec;
        public ushort nBlockAlign;
        public ushort wBitsPerSample;
        public ushort cbSize;
        public bool IsFloat;

        public static WaveFormatEx FromPointer(IntPtr p)
        {
            var w = new WaveFormatEx();
            w.wFormatTag = (ushort)Marshal.ReadInt16(p, 0);
            w.nChannels = (ushort)Marshal.ReadInt16(p, 2);
            w.nSamplesPerSec = (uint)Marshal.ReadInt32(p, 4);
            w.nAvgBytesPerSec = (uint)Marshal.ReadInt32(p, 8);
            w.nBlockAlign = (ushort)Marshal.ReadInt16(p, 12);
            w.wBitsPerSample = (ushort)Marshal.ReadInt16(p, 14);
            w.cbSize = 0;
            if (w.wFormatTag == WAVE_FORMAT_EXTENSIBLE)
            {
                w.cbSize = (ushort)Marshal.ReadInt16(p, 16);
                // SubFormat GUID at offset 24 for WAVEFORMATEXTENSIBLE
                // KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {00000003-0000-0010-8000-00aa00389b71}
                byte b0 = Marshal.ReadByte(p, 24);
                byte b1 = Marshal.ReadByte(p, 25);
                byte b2 = Marshal.ReadByte(p, 26);
                byte b3 = Marshal.ReadByte(p, 27);
                int data1 = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
                w.IsFloat = (data1 == 3);
            }
            else
            {
                w.IsFloat = (w.wFormatTag == WAVE_FORMAT_IEEE_FLOAT);
            }
            return w;
        }
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    private class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        int NotImpl1();
        [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig] int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        [PreserveSig] int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        [PreserveSig] int GetId(out IntPtr ppstrId);
        [PreserveSig] int GetState(out int pdwState);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IPropertyStore
    {
        [PreserveSig] int GetCount(out int cProps);
        [PreserveSig] int GetAt(int iProp, out PropertyKey pkey);
        [PreserveSig] int GetValue(ref PropertyKey key, out PropVariant pv);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PropertyKey { public Guid fmtid; public int pid; }

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct PropVariant
    {
        [FieldOffset(0)] public short vt;
        [FieldOffset(8)] public IntPtr p;
    }

    [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioClient
    {
        [PreserveSig] int Initialize(int ShareMode, int StreamFlags, long hnsBufferDuration, long hnsPeriodicity, IntPtr pFormat, IntPtr AudioSessionGuid);
        [PreserveSig] int GetBufferSize(out uint pNumBufferFrames);
        [PreserveSig] int GetStreamLatency(out long phnsLatency);
        [PreserveSig] int GetCurrentPadding(out uint pNumPaddingFrames);
        [PreserveSig] int IsFormatSupported(int ShareMode, IntPtr pFormat, out IntPtr ppClosestMatch);
        [PreserveSig] int GetMixFormat(out IntPtr ppDeviceFormat);
        [PreserveSig] int GetDevicePeriod(out long phnsDefaultDevicePeriod, out long phnsMinimumDevicePeriod);
        [PreserveSig] int Start();
        [PreserveSig] int Stop();
        [PreserveSig] int Reset();
        [PreserveSig] int SetEventHandle(IntPtr eventHandle);
        [PreserveSig] int GetService(ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    }

    [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioCaptureClient
    {
        [PreserveSig] int GetBuffer(out IntPtr ppData, out uint pNumFramesToRead, out int pdwFlags, out long pu64DevicePosition, out long pu64QPCPosition);
        [PreserveSig] int ReleaseBuffer(uint NumFramesRead);
        [PreserveSig] int GetNextPacketSize(out uint pNumFramesInNextPacket);
    }
}
