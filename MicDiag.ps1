# MicDiag - grava o microfone do fone em dois modos ao mesmo tempo, por 20s:
#   RAW  = sem os efeitos de audio do Windows/Intel (APOs)
#   COMM = categoria "comunicacoes", o que o Teams recebe do Windows
# e mostra o nivel da voz a cada 2s. Se COMM cai e RAW nao, o culpado e o efeito do Windows/Intel.
# Saida: diag-raw.wav, diag-comm.wav e diag.csv na pasta do script.
# Com -Desc 'CABLE Output' grava so esse dispositivo (modo normal), simulando o Teams usando o VB-CABLE.
param([string]$Alvo = 'AE01', [int]$Segundos = 20, [string]$Desc)

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int mask, out IntPtr c); int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d);
  int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice d);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[Guid("726778CD-F60A-4eda-82DE-E47610CD78AA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioClient2 {
  int Initialize(int shareMode, int flags, long bufferDuration, long periodicity, IntPtr format, IntPtr session);
  int GetBufferSize(out uint n); int GetStreamLatency(out long l); int GetCurrentPadding(out uint p);
  int IsFormatSupported(int m, IntPtr f, out IntPtr c); int GetMixFormat(out IntPtr f); int GetDevicePeriod(out long d, out long m);
  int Start(); int Stop(); int Reset(); int SetEventHandle(IntPtr h);
  int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object o);
  int IsOffloadCapable(int cat, out int cap); int SetClientProperties(ref AudioClientProperties p);
}
[StructLayout(LayoutKind.Sequential)] public struct AudioClientProperties { public uint cbSize; public int bIsOffload; public int eCategory; public int Options; }
[Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioCaptureClient {
  int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong pos, out ulong qpc);
  int ReleaseBuffer(uint frames); int GetNextPacketSize(out uint n);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}

public class Captura {
  public string Nome; public int Rate; public int Canais; public List<float> Amostras = new List<float>();
  IAudioClient2 cli; IAudioCaptureClient cap; bool isFloat; int bits;
  public Captura(string id, string nome, bool raw) {
    Nome = nome;
    var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom(); IMMDevice d;
    Check(en.GetDevice(id, out d), "GetDevice");
    var iid = typeof(IAudioClient2).GUID; object o;
    Check(d.Activate(ref iid, 23, IntPtr.Zero, out o), "Activate");
    cli = (IAudioClient2)o;
    // categoria 3 = Communications; Options 1 = AUDCLNT_STREAMOPTIONS_RAW
    var p = new AudioClientProperties { cbSize = 16, bIsOffload = 0, eCategory = 3, Options = raw ? 1 : 0 };
    Check(cli.SetClientProperties(ref p), "SetClientProperties");
    IntPtr fmt; Check(cli.GetMixFormat(out fmt), "GetMixFormat");
    Canais = Marshal.ReadInt16(fmt, 2); Rate = Marshal.ReadInt32(fmt, 4); bits = Marshal.ReadInt16(fmt, 14);
    int tag = Marshal.ReadInt16(fmt, 0) & 0xFFFF;
    isFloat = tag == 3 || (tag == 0xFFFE && Marshal.ReadInt32(fmt, 24) == 3);
    Check(cli.Initialize(0, 0, 10000000, 0, fmt, IntPtr.Zero), "Initialize");
    var ciid = typeof(IAudioCaptureClient).GUID; object c;
    Check(cli.GetService(ref ciid, out c), "GetService"); cap = (IAudioCaptureClient)c;
  }
  static void Check(int hr, string op) { if (hr != 0) throw new Exception(op + " falhou: 0x" + hr.ToString("X8")); }
  public void Start() { Check(cli.Start(), "Start"); }
  public void Stop() { cli.Stop(); }
  public void Poll() {
    uint n;
    while (cap.GetNextPacketSize(out n) == 0 && n > 0) {
      IntPtr data; uint frames, flags; ulong pos, qpc;
      if (cap.GetBuffer(out data, out frames, out flags, out pos, out qpc) != 0) return;
      bool silent = (flags & 2) != 0; int bps = bits / 8;
      for (int i = 0; i < frames; i++) {
        float v = 0;
        if (!silent) {
          int off = i * Canais * bps; // so o canal 0
          if (isFloat) v = BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(data, off)), 0);
          else if (bits == 16) v = Marshal.ReadInt16(data, off) / 32768f;
          else if (bits == 32) v = Marshal.ReadInt32(data, off) / 2147483648f;
        }
        Amostras.Add(v);
      }
      cap.ReleaseBuffer(frames);
    }
  }
  public void SalvarWav(string path) {
    using (var w = new BinaryWriter(File.Create(path))) {
      int len = Amostras.Count * 2;
      w.Write("RIFF".ToCharArray()); w.Write(36 + len); w.Write("WAVE".ToCharArray());
      w.Write("fmt ".ToCharArray()); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
      w.Write("data".ToCharArray()); w.Write(len);
      foreach (var s in Amostras) w.Write((short)Math.Max(-32768, Math.Min(32767, s * 32767)));
    }
  }
  // nivel RMS em dBFS por janela de ms
  public List<double> Niveis(int ms) {
    var r = new List<double>(); int win = Rate * ms / 1000;
    for (int i = 0; i + win <= Amostras.Count; i += win) {
      double acc = 0; for (int j = i; j < i + win; j++) acc += Amostras[j] * Amostras[j];
      double rms = Math.Sqrt(acc / win); r.Add(rms < 1e-6 ? -120 : 20 * Math.Log10(rms));
    }
    return r;
  }
}
'@

$raiz = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Capture'
$ep = Get-ChildItem $raiz | Where-Object {
    $p = Get-ItemProperty "$($_.PSPath)\Properties" -ErrorAction SilentlyContinue
    (Get-ItemProperty $_.PSPath).DeviceState -eq 1 -and $(if ($Desc) { $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2' -eq $Desc }
                                                        else { $p.'{026e516e-b814-414b-83cd-856d6fef4822},2' -like "*$Alvo*" })
} | Select-Object -First 1
if (-not $ep) { Write-Host "Microfone $(if ($Desc) { $Desc } else { $Alvo }) nao encontrado ou desconectado." -ForegroundColor Red; exit 1 }
$id = '{0.0.1.00000000}.' + $ep.PSChildName

if ($Desc) {
    $cap = New-Object Captura($id, $Desc, $false)
    Write-Host "Gravando '$Desc' ($($cap.Rate) Hz). Quando aparecer GRAVANDO, fale SEM PARAR por $Segundos s." -ForegroundColor Yellow
    3..1 | ForEach-Object { Write-Host "  $_..."; Start-Sleep -Seconds 1 }
    $cap.Start(); Write-Host "GRAVANDO..." -ForegroundColor Green
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Segundos) { $cap.Poll(); Start-Sleep -Milliseconds 10 }
    $cap.Stop(); Write-Host "Fim." -ForegroundColor Green
    $cap.SalvarWav((Join-Path $PSScriptRoot 'diag-cable.wav'))
    $nv = $cap.Niveis(100)
    Write-Host ""; Write-Host "Bloco    nivel voz (dBFS)   pico (dBFS)"
    for ($b = 0; $b -lt [Math]::Floor($nv.Count / 20); $b++) {
        $blk = $nv[($b * 20)..($b * 20 + 19)]
        $m = $blk | Sort-Object -Descending | Select-Object -First 10 | Measure-Object -Average
        '{0,2}-{1,2}s   {2,12:0.0}   {3,11:0.0}' -f ($b * 2), ($b * 2 + 2), $m.Average, ($blk | Measure-Object -Maximum).Maximum
    }
    Write-Host ""; Write-Host "Arquivo: $PSScriptRoot\diag-cable.wav"
    exit 0
}

$raw  = New-Object Captura($id, 'RAW', $true)
$comm = New-Object Captura($id, 'COMM', $false)
Write-Host "Formato: $($raw.Rate) Hz, $($raw.Canais) canal(is)"
Write-Host ""
Write-Host "Quando aparecer GRAVANDO, fale SEM PARAR por $Segundos s (leia um texto em voz normal)." -ForegroundColor Yellow
3..1 | ForEach-Object { Write-Host "  $_..."; Start-Sleep -Seconds 1 }
$raw.Start(); $comm.Start()
Write-Host "GRAVANDO..." -ForegroundColor Green
$sw = [Diagnostics.Stopwatch]::StartNew()
while ($sw.Elapsed.TotalSeconds -lt $Segundos) { $raw.Poll(); $comm.Poll(); Start-Sleep -Milliseconds 10 }
$raw.Stop(); $comm.Stop()
Write-Host "Fim." -ForegroundColor Green

$dir = $PSScriptRoot
$raw.SalvarWav((Join-Path $dir 'diag-raw.wav')); $comm.SalvarWav((Join-Path $dir 'diag-comm.wav'))
$nr = $raw.Niveis(100); $nc = $comm.Niveis(100)
$n = [Math]::Min($nr.Count, $nc.Count)
'tempo_s;raw_dbfs;comm_dbfs' | Set-Content (Join-Path $dir 'diag.csv')
0..($n - 1) | ForEach-Object { '{0:0.0};{1:0.0};{2:0.0}' -f ($_ / 10), $nr[$_], $nc[$_] } | Add-Content (Join-Path $dir 'diag.csv')

# Resumo a cada 2s: media das janelas com voz (as 50% mais altas do bloco)
Write-Host ""
Write-Host "Bloco    RAW (dBFS)   COMM (dBFS)   diferenca"
for ($b = 0; $b -lt [Math]::Floor($n / 20); $b++) {
    $r = $nr[($b * 20)..($b * 20 + 19)] | Sort-Object -Descending | Select-Object -First 10 | Measure-Object -Average
    $c = $nc[($b * 20)..($b * 20 + 19)] | Sort-Object -Descending | Select-Object -First 10 | Measure-Object -Average
    '{0,2}-{1,2}s   {2,8:0.0}   {3,10:0.0}   {4,8:0.0}' -f ($b * 2), ($b * 2 + 2), $r.Average, $c.Average, ($c.Average - $r.Average)
}
Write-Host ""
Write-Host "Arquivos: $dir\diag-raw.wav e diag-comm.wav (ouca os dois)"
