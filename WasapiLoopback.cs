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
    private readonly object _gate = new object();

    public string LastError { get { lock (_gate) { return _error; } } }
    public bool IsRunning { get { return _run && _thread != null && _thread.IsAlive; } }

    public void Start(string wavPath)
    {
        if (string.IsNullOrEmpty(wavPath)) throw new ArgumentException("wavPath");
        Stop();
        _path = wavPath;
        lock (_gate) { _error = null; }
        _run = true;
        _thread = new Thread(CaptureThread) { IsBackground = true, Name = "webpcap-wasapi-loopback" };
        _thread.Start();
        // brief wait so Activate failures surface early
        Thread.Sleep(80);
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
    }

    public void Dispose() { Stop(); }

    private void SetError(string msg)
    {
        lock (_gate) { _error = msg; }
    }

    private void CaptureThread()
    {
        IMMDeviceEnumerator enumerator = null;
        IMMDevice device = null;
        IAudioClient client = null;
        IAudioCaptureClient capture = null;
        IntPtr mixFmt = IntPtr.Zero;
        FileStream fs = null;
        BinaryWriter bw = null;
        long dataBytes = 0;
        long dataSizePos = 0;
        long riffSizePos = 0;

        try
        {
            enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
            int hr = enumerator.GetDefaultAudioEndpoint(eRender, eConsole, out device);
            if (hr != 0) { SetError("GetDefaultAudioEndpoint 0x" + hr.ToString("X8")); return; }

            object oClient;
            Guid iidClient = typeof(IAudioClient).GUID;
            hr = device.Activate(ref iidClient, 1 /*CLSCTX_INPROC_SERVER*/, IntPtr.Zero, out oClient);
            if (hr != 0) { SetError("Activate IAudioClient 0x" + hr.ToString("X8")); return; }
            client = (IAudioClient)oClient;

            hr = client.GetMixFormat(out mixFmt);
            if (hr != 0 || mixFmt == IntPtr.Zero) { SetError("GetMixFormat 0x" + hr.ToString("X8")); return; }

            WaveFormatEx wfx = WaveFormatEx.FromPointer(mixFmt);
            // 3s buffer
            long hnsBuffer = 30000000;
            hr = client.Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, hnsBuffer, 0, mixFmt, IntPtr.Zero);
            if (hr != 0) { SetError("IAudioClient.Initialize loopback 0x" + hr.ToString("X8")); return; }

            object oCap;
            Guid iidCap = typeof(IAudioCaptureClient).GUID;
            hr = client.GetService(ref iidCap, out oCap);
            if (hr != 0) { SetError("GetService IAudioCaptureClient 0x" + hr.ToString("X8")); return; }
            capture = (IAudioCaptureClient)oCap;

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(_path)) ?? ".");
            fs = new FileStream(_path, FileMode.Create, FileAccess.Write, FileShare.Read);
            bw = new BinaryWriter(fs);

            // Always write 16-bit PCM stereo-or-mono at mix sample rate (ffmpeg-friendly).
            int outCh = wfx.nChannels;
            int outRate = (int)wfx.nSamplesPerSec;
            int outBits = 16;
            int outBlock = outCh * outBits / 8;
            WriteWavHeader(bw, outCh, outRate, outBits, 0, out riffSizePos, out dataSizePos);

            hr = client.Start();
            if (hr != 0) { SetError("IAudioClient.Start 0x" + hr.ToString("X8")); return; }

            byte[] silenceScratch = null;
            while (_run)
            {
                uint packet;
                hr = capture.GetNextPacketSize(out packet);
                if (hr != 0) break;

                if (packet == 0)
                {
                    Thread.Sleep(5);
                    continue;
                }

                IntPtr data;
                uint frames;
                int flags;
                long devPos, qpcPos;
                hr = capture.GetBuffer(out data, out frames, out flags, out devPos, out qpcPos);
                if (hr != 0) break;

                int byteLen = (int)frames * wfx.nBlockAlign;
                if (byteLen > 0)
                {
                    if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0)
                    {
                        if (silenceScratch == null || silenceScratch.Length < byteLen)
                            silenceScratch = new byte[byteLen];
                        // already zeros
                        WriteAsPcm16(bw, silenceScratch, byteLen, wfx, ref dataBytes);
                    }
                    else if (data != IntPtr.Zero)
                    {
                        byte[] buf = new byte[byteLen];
                        Marshal.Copy(data, buf, 0, byteLen);
                        WriteAsPcm16(bw, buf, byteLen, wfx, ref dataBytes);
                    }
                }

                capture.ReleaseBuffer(frames);
            }

            try { client.Stop(); } catch { }

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
            if (mixFmt != IntPtr.Zero) Marshal.FreeCoTaskMem(mixFmt);
            if (capture != null) try { Marshal.ReleaseComObject(capture); } catch { }
            if (client != null) try { Marshal.ReleaseComObject(client); } catch { }
            if (device != null) try { Marshal.ReleaseComObject(device); } catch { }
            if (enumerator != null) try { Marshal.ReleaseComObject(enumerator); } catch { }
        }
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
