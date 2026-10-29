# MicMonitor - mostra sempre visivel o volume do microfone do fone (config.json -> "Alvo", padrao AE01)
# e a captacao de voz; registra em quedas.log cada queda de volume, com os apps que estavam usando o microfone.
# Fone desligado = widget encolhe para "AE01 off" em cinza.
# "Melhorar voz": quando algum app (Teams) capta do microfone "CABLE Output" (VB-CABLE), capta o fone em modo RAW,
# aplica ganho + limitador e toca no "CABLE Input". So roda enquanto alguem usa o CABLE Output.
# Clique e arraste para mover | duplo clique = volta para 100% | botao direito = menu

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'Local\MicMonitor')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
  int EnumAudioEndpoints(int dataFlow, int mask, out IntPtr c); int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d);
  int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice d);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
  int Activate(ref Guid iid, int ctx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); int OpenPropertyStore(int a, out IntPtr s);
  int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id); int GetState(out int s);
}
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int RegisterControlChangeNotify(IntPtr x); int UnregisterControlChangeNotify(IntPtr x); int GetChannelCount(out int c);
  int SetMasterVolumeLevel(float l, ref Guid g); int SetMasterVolumeLevelScalar(float l, ref Guid g);
  int GetMasterVolumeLevel(out float l); int GetMasterVolumeLevelScalar(out float l);
  int SetChannelVolumeLevel(int ch, float l, ref Guid g); int SetChannelVolumeLevelScalar(int ch, float l, ref Guid g);
  int GetChannelVolumeLevel(int ch, out float l); int GetChannelVolumeLevelScalar(int ch, out float l);
  int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, ref Guid g); int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
}
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioMeterInformation { int GetPeakValue(out float p); }
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
[Guid("F294ACFC-3146-4483-A7BF-ADDCA7C260E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioRenderClient { int GetBuffer(uint frames, out IntPtr data); int ReleaseBuffer(uint frames, uint flags); }
[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionManager2 {
  int GetAudioSessionControl(IntPtr g, uint f, out IntPtr c); int GetSimpleAudioVolume(IntPtr g, uint f, out IntPtr v);
  int GetSessionEnumerator(out IAudioSessionEnumerator e);
}
[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionEnumerator { int GetCount(out int n); int GetSession(int i, out IAudioSessionControl s); }
[Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioSessionControl { int GetState(out int s); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorCom {}
// IPolicyConfig (nao documentada, a mesma usada por SoundSwitch/AudioDeviceCmdlets) para trocar o dispositivo padrao
[Guid("F8679F50-850A-41CF-9C72-430F290290C8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfig {
  int GetMixFormat(); int GetDeviceFormat(); int ResetDeviceFormat(); int SetDeviceFormat(); int GetProcessingPeriod();
  int SetProcessingPeriod(); int GetShareMode(); int SetShareMode(); int GetPropertyValue(); int SetPropertyValue();
  int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, int role);
}
[ComImport, Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")] class PolicyConfigClient {}

public static class MicVol {
  static IMMDeviceEnumerator en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
  static IMMDevice dev; static string devId; static IAudioMeterInformation meter;
  static void Reset() { dev = null; devId = null; meter = null; }
  // devolve o dispositivo somente se estiver ativo (fone ligado e conectado)
  static IMMDevice Device(string id) {
    if (id == null) { Reset(); return null; }
    if (id != devId) {
      Reset(); IMMDevice d;
      if (en.GetDevice(id, out d) != 0 || d == null) return null;
      dev = d; devId = id;
    }
    int st;
    if (dev.GetState(out st) != 0 || st != 1) { Reset(); return null; }
    if (meter == null) {
      // medidor passivo: so le o pico, nao abre stream de captura (nao forca o fone para Hands-Free)
      var miid = typeof(IAudioMeterInformation).GUID; object m;
      if (dev.Activate(ref miid, 23, IntPtr.Zero, out m) == 0) meter = (IAudioMeterInformation)m;
    }
    return dev;
  }
  static IAudioEndpointVolume Volume(string id) {
    var d = Device(id); if (d == null) return null;
    var iid = typeof(IAudioEndpointVolume).GUID; object o;
    if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return null;
    return (IAudioEndpointVolume)o;
  }
  public static bool Read(string id, out int percent, out bool mute) {
    percent = -1; mute = false;
    try {
      var v = Volume(id); if (v == null) return false;
      float s; v.GetMasterVolumeLevelScalar(out s); v.GetMute(out mute);
      percent = (int)Math.Round(s * 100); Marshal.ReleaseComObject(v); return true;
    } catch { Reset(); return false; }
  }
  public static void SetFull(string id) {
    try {
      var v = Volume(id); if (v == null) return;
      var g = Guid.Empty; v.SetMasterVolumeLevelScalar(1.0f, ref g); v.SetMute(false, ref g);
      Marshal.ReleaseComObject(v);
    } catch { Reset(); }
  }
  public static float Peak() {
    try { if (meter == null) return -1; float p; meter.GetPeakValue(out p); return p; }
    catch { Reset(); return -1; }
  }
  // microfone padrao do Windows: role 0 = padrao (console), 2 = comunicacoes
  public static string DefaultCapture(int role) {
    try { IMMDevice d; if (en.GetDefaultAudioEndpoint(1, role, out d) != 0 || d == null) return null; string id; d.GetId(out id); return id; }
    catch { return null; }
  }
  public static bool SetDefaultCapture(string id) {
    try {
      var pc = (IPolicyConfig)new PolicyConfigClient();
      bool ok = true; for (int role = 0; role <= 2; role++) ok &= pc.SetDefaultEndpoint(id, role) == 0;
      return ok;
    } catch { return false; }
  }
  // quantos apps estao captando agora deste endpoint (ex.: Teams no CABLE Output)
  public static int SessoesAtivas(string id) {
    try {
      IMMDevice d; if (en.GetDevice(id, out d) != 0 || d == null) return 0;
      var iid = typeof(IAudioSessionManager2).GUID; object o;
      if (d.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) return 0;
      IAudioSessionEnumerator e; if (((IAudioSessionManager2)o).GetSessionEnumerator(out e) != 0) return 0;
      int n, ativas = 0; e.GetCount(out n);
      for (int i = 0; i < n; i++) { IAudioSessionControl s; int st; if (e.GetSession(i, out s) == 0 && s.GetState(out st) == 0 && st == 1) ativas++; }
      return ativas;
    } catch { return 0; }
  }
}

// Ponte de voz: fone (RAW, sem efeitos do Windows/Intel) -> ganho + limitador -> CABLE Input
public static class VoiceBridge {
  public static volatile bool Running; public static volatile string LastError; public static volatile float GainDb = 15f;
  static volatile bool stop; static Thread th; static float outPeak;
  public static float TakePeak() { var p = outPeak; outPeak = 0; return p; }
  public static void Start(string capId, string renId) {
    if (Running) return;
    stop = false; LastError = null; Running = true;
    th = new Thread(() => Run(capId, renId)); th.IsBackground = true; th.Priority = ThreadPriority.AboveNormal;
    th.SetApartmentState(ApartmentState.MTA); th.Start();
  }
  public static void Stop() { stop = true; if (th != null) th.Join(1000); }
  static void H(int hr, string op) { if (hr != 0) throw new Exception(op + " falhou: 0x" + hr.ToString("X8")); }
  static IAudioClient2 Client(IMMDeviceEnumerator en, string id) {
    IMMDevice d; H(en.GetDevice(id, out d), "GetDevice");
    var iid = typeof(IAudioClient2).GUID; object o; H(d.Activate(ref iid, 23, IntPtr.Zero, out o), "Activate");
    return (IAudioClient2)o;
  }
  static void Run(string capId, string renId) {
    // formato unico dos dois lados: 16 kHz mono float; o Windows converte (AUTOCONVERTPCM | SRC_DEFAULT_QUALITY)
    IntPtr fmt = Marshal.AllocCoTaskMem(18);
    Marshal.WriteInt16(fmt, 0, 3); Marshal.WriteInt16(fmt, 2, 1); Marshal.WriteInt32(fmt, 4, 16000);
    Marshal.WriteInt32(fmt, 8, 64000); Marshal.WriteInt16(fmt, 12, 4); Marshal.WriteInt16(fmt, 14, 32); Marshal.WriteInt16(fmt, 16, 0);
    const int flags = unchecked((int)0x88000000);
    IAudioClient2 cc = null, rc = null;
    try {
      var en = (IMMDeviceEnumerator)new MMDeviceEnumeratorCom();
      cc = Client(en, capId);
      var props = new AudioClientProperties { cbSize = 16, bIsOffload = 0, eCategory = 3, Options = 1 }; // Communications + RAW
      H(cc.SetClientProperties(ref props), "SetClientProperties");
      H(cc.Initialize(0, flags, 1000000, 0, fmt, IntPtr.Zero), "Initialize captura");
      rc = Client(en, renId);
      H(rc.Initialize(0, flags, 500000, 0, fmt, IntPtr.Zero), "Initialize saida");
      uint rbuf; H(rc.GetBufferSize(out rbuf), "GetBufferSize");
      object o; var ciid = typeof(IAudioCaptureClient).GUID; H(cc.GetService(ref ciid, out o), "GetService captura"); var cap = (IAudioCaptureClient)o;
      var riid = typeof(IAudioRenderClient).GUID; H(rc.GetService(ref riid, out o), "GetService saida"); var ren = (IAudioRenderClient)o;

      var q = new float[16000]; int qh = 0, qc = 0;         // fila circular (1 s)
      var tmp = new float[16000]; var outBuf = new float[16000];
      float env = 0, thr = 0.7f;                               // limitador em ~ -3 dBFS
      float atk = (float)Math.Exp(-1.0 / 16), rel = (float)Math.Exp(-1.0 / 2400);  // ataque 1 ms, release 150 ms
      bool primed = false;
      H(cc.Start(), "Start captura"); H(rc.Start(), "Start saida");
      while (!stop) {
        uint n; int hr;
        while ((hr = cap.GetNextPacketSize(out n)) == 0 && n > 0) {
          IntPtr data; uint fr, fl; ulong p1, p2;
          H(cap.GetBuffer(out data, out fr, out fl, out p1, out p2), "GetBuffer captura");
          int frames = (int)Math.Min(fr, (uint)tmp.Length);
          bool silent = (fl & 2) != 0;
          if (!silent) Marshal.Copy(data, tmp, 0, frames);
          float g = (float)Math.Pow(10, GainDb / 20.0);
          for (int i = 0; i < frames; i++) {
            float x = silent ? 0 : tmp[i] * g;
            float a = Math.Abs(x);
            env = a > env ? atk * env + (1 - atk) * a : rel * env + (1 - rel) * a;
            if (env > thr) x *= thr / env;
            if (x > 0.98f) x = 0.98f; else if (x < -0.98f) x = -0.98f;
            if (Math.Abs(x) > outPeak) outPeak = Math.Abs(x);
            if (qc == q.Length) { qh = (qh + 1) % q.Length; qc--; }
            q[(qh + qc) % q.Length] = x; qc++;
          }
          cap.ReleaseBuffer(fr);
        }
        if (hr != 0) H(hr, "GetNextPacketSize");
        // relogios do fone e do cabo derivam: se acumular > 150 ms, descarta o excesso e volta para 40 ms
        if (qc > 2400) { int drop = qc - 640; qh = (qh + drop) % q.Length; qc -= drop; }
        if (!primed && qc >= 480) primed = true;              // 30 ms de colchao antes de tocar
        if (primed) {
          uint pad; H(rc.GetCurrentPadding(out pad), "GetCurrentPadding");
          int k = Math.Min((int)(rbuf - pad), qc);
          if (k > 0) {
            for (int i = 0; i < k; i++) outBuf[i] = q[(qh + i) % q.Length];
            qh = (qh + k) % q.Length; qc -= k;
            IntPtr buf; H(ren.GetBuffer((uint)k, out buf), "GetBuffer saida");
            Marshal.Copy(outBuf, 0, buf, k); ren.ReleaseBuffer((uint)k, 0);
          } else if (qc == 0 && pad == 0) primed = false;      // esvaziou: refaz o colchao
        }
        Thread.Sleep(5);
      }
    } catch (Exception ex) { LastError = ex.Message; }
    finally {
      try { if (cc != null) cc.Stop(); } catch {}
      try { if (rc != null) rc.Stop(); } catch {}
      Marshal.FreeCoTaskMem(fmt); Running = false;
    }
  }
}
'@

$dir      = $PSScriptRoot
$logFile  = Join-Path $dir 'quedas.log'
$cfgFile  = Join-Path $dir 'config.json'
$alerta   = 80   # abaixo disso fica amarelo; abaixo de 40, vermelho
$padroes  = @{ Left = $null; Top = $null; ManterEm100 = $false; Alvo = 'AE01'; MelhorarVoz = $true; GanhoDb = 15
               MicPadraoCable = $true; MicSemFone = 'Grupo de microfones' }

$cfg = [pscustomobject]@{}
if (Test-Path $cfgFile) { try { $cfg = Get-Content $cfgFile -Raw | ConvertFrom-Json } catch { $cfg = [pscustomobject]@{} } }
foreach ($p in $padroes.GetEnumerator()) {
    if (-not ($cfg.PSObject.Properties.Name -contains $p.Key)) { $cfg | Add-Member -NotePropertyName $p.Key -NotePropertyValue $p.Value }
}

function Get-Endpoints([string]$tipo) {
    $raiz = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\$tipo"
    foreach ($k in Get-ChildItem $raiz -ErrorAction SilentlyContinue) {
        $p = Get-ItemProperty "$($k.PSPath)\Properties" -ErrorAction SilentlyContinue
        [pscustomobject]@{
            Id       = '{0.0.' + $(if ($tipo -eq 'Render') { 0 } else { 1 }) + '.00000000}.' + $k.PSChildName
            Desc     = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
            NomeFone = $p.'{026e516e-b814-414b-83cd-856d6fef4822},2'
            NomeIf   = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},26'
            Estado   = (Get-ItemProperty $k.PSPath).DeviceState
        }
    }
}

# Procura o endpoint de captura do fone pelo nome (ex.: "AE01"); prefere o que estiver ativo
function Find-Alvo {
    Get-Endpoints 'Capture' | Where-Object { $_.NomeFone -like "*$($cfg.Alvo)*" -or $_.NomeIf -like "*$($cfg.Alvo)*" } |
        Sort-Object { $_.Estado -ne 1 } | Select-Object -First 1 |
        ForEach-Object { [pscustomobject]@{ Id = $_.Id; Nome = "$($_.Desc) ($($_.NomeIf))" } }
}

# VB-CABLE: In = onde a ponte toca; Out = o microfone que o Teams usa
function Find-Cable {
    $in  = Get-Endpoints 'Render'  | Where-Object { $_.Desc -eq 'CABLE Input' -and $_.Estado -eq 1 } | Select-Object -First 1
    $out = Get-Endpoints 'Capture' | Where-Object { $_.Desc -eq 'CABLE Output' -and $_.Estado -eq 1 } | Select-Object -First 1
    if ($in -and $out) { [pscustomobject]@{ In = $in.Id; Out = $out.Id } }
}

function Get-NomeEndpoint([string]$id) {
    if (-not $id) { return 'nenhum' }
    $e = Get-Endpoints 'Capture' | Where-Object { $_.Id -eq $id } | Select-Object -First 1
    if ($e) { "$($e.Desc)$(if ($e.NomeFone) { " ($($e.NomeFone))" })" } else { $id }
}

function Update-Cable {
    if (-not $script:cable -and ((Get-Date) - $script:ultimaBuscaCable).TotalSeconds -ge 30) {
        $script:ultimaBuscaCable = Get-Date; $script:cable = Find-Cable
    }
}

# Com o fone ligado (e "Melhorar voz" ativo), o mic padrao e de comunicacao do Windows tem que ser o CABLE Output.
# Sem o fone (ou com o widget fechando), o CABLE fica mudo: devolve para o fone, se ligado, ou para o mic do notebook.
function Set-MicPadrao([bool]$usarCable, [switch]$Forcar) {
    if (-not (($Forcar -or ($cfg.MicPadraoCable -and $cfg.MelhorarVoz)) -and $script:cable)) { return }
    $atuais = @([MicVol]::DefaultCapture(0), [MicVol]::DefaultCapture(2))
    if ($usarCable) {
        if ($atuais | Where-Object { $_ -ne $script:cable.Out }) {
            $antes = Get-NomeEndpoint ($atuais | Where-Object { $_ -ne $script:cable.Out } | Select-Object -First 1)
            if ([MicVol]::SetDefaultCapture($script:cable.Out)) { Write-Log "Mic padrao do Windows -> CABLE Output (estava: $antes)" }
            else { Write-Log 'Falha ao trocar o mic padrao do Windows para CABLE Output' }
        }
        return
    }
    if (-not ($atuais -contains $script:cable.Out)) { return }
    $destino = if ($script:conectado -and $script:alvo) { $script:alvo.Id } else {
        $ativos = Get-Endpoints 'Capture' | Where-Object { $_.Estado -eq 1 -and $_.Desc -notmatch 'CABLE|Voicemeeter' }
        ($ativos | Where-Object { $_.Desc -like "*$($cfg.MicSemFone)*" } | Select-Object -First 1), ($ativos | Select-Object -First 1) |
            Where-Object { $_ } | Select-Object -First 1 | ForEach-Object { $_.Id }
    }
    if ($destino -and [MicVol]::SetDefaultCapture($destino)) { Write-Log "Mic padrao do Windows -> $(Get-NomeEndpoint $destino) (CABLE ficaria mudo)" }
}

function Get-AppsUsandoMic {
    $base = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone'
    $itens = @(Get-ChildItem $base -ErrorAction SilentlyContinue) + @(Get-ChildItem "$base\NonPackaged" -ErrorAction SilentlyContinue)
    $apps = foreach ($i in $itens) {
        $p = Get-ItemProperty $i.PSPath -ErrorAction SilentlyContinue
        if ($p.LastUsedTimeStart -and $p.LastUsedTimeStop -eq 0) { ($i.PSChildName -replace '.*#', '') -replace '_[a-z0-9]{13}$', '' }
    }
    if ($apps) { $apps -join ', ' } else { 'nenhum' }
}

function Write-Log([string]$msg) {
    Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg) -Encoding UTF8
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" SizeToContent="WidthAndHeight" ResizeMode="NoResize" Title="MicMonitor">
  <Border Name="Card" CornerRadius="8" Background="#E6202020" Padding="10,6" BorderThickness="1.5" BorderBrush="#555555">
    <StackPanel Orientation="Horizontal">
      <TextBlock Name="Rotulo" Text="Mic" Foreground="#DDDDDD" FontSize="12" VerticalAlignment="Center"/>
      <StackPanel Name="Detalhes" Orientation="Horizontal" Margin="8,0,0,0">
        <Grid Width="70" Height="8" VerticalAlignment="Center">
          <Border Background="#444444" CornerRadius="4"/>
          <Border Name="Barra" Background="#3CB371" CornerRadius="4" HorizontalAlignment="Left" Width="0"/>
        </Grid>
        <TextBlock Name="Pct" Text="--" Foreground="White" FontWeight="Bold" FontSize="14" Width="50"
                   TextAlignment="Right" VerticalAlignment="Center" Margin="6,0,0,0"/>
        <Border Width="1" Background="#555555" Margin="10,2,10,2"/>
        <TextBlock Name="VozRotulo" Text="voz" Foreground="#888888" FontSize="12" VerticalAlignment="Center" Margin="0,0,6,0"/>
        <Grid Width="60" Height="8" VerticalAlignment="Center">
          <Border Background="#444444" CornerRadius="4"/>
          <Border Name="Voz" Background="#4FC3F7" CornerRadius="4" HorizontalAlignment="Left" Width="0"/>
        </Grid>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
$win      = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$card     = $win.FindName('Card')
$rot      = $win.FindName('Rotulo')
$detalhes = $win.FindName('Detalhes')
$barra    = $win.FindName('Barra')
$pct      = $win.FindName('Pct')
$voz      = $win.FindName('Voz')
$vozRot   = $win.FindName('VozRotulo')

$win.WindowStartupLocation = 'Manual'
if ($null -ne $cfg.Left) { $win.Left = $cfg.Left; $win.Top = $cfg.Top }
else { $area = [System.Windows.SystemParameters]::WorkArea; $win.Left = $area.Right - 340; $win.Top = $area.Bottom - 60 }

function Save-Config {
    $cfg.Left = $win.Left; $cfg.Top = $win.Top
    $cfg | ConvertTo-Json | Set-Content -Path $cfgFile -Encoding UTF8
}

$script:alvo = $null          # endpoint do fone (Id, Nome)
$script:cable = $null         # endpoints do VB-CABLE (In, Out)
$script:conectado = $null     # $true / $false / $null (ainda nao sabe)
$script:ultimaBusca = [datetime]::MinValue
$script:ultimaBuscaCable = [datetime]::MinValue
$script:anterior = $null
$script:ponte = $false                          # ponte de voz ligada por nos
$script:semConsumidorDesde = $null
$script:proximaTentativa = [datetime]::MinValue

function Stop-Ponte([string]$motivo) {
    if ($script:ponte) { [VoiceBridge]::Stop(); Write-Log "Melhorar voz: desligado ($motivo)" }
    $script:ponte = $false; $script:semConsumidorDesde = $null
}

# Menu de contexto
$menu = New-Object System.Windows.Controls.ContextMenu
$miVoz  = New-Object System.Windows.Controls.MenuItem; $miVoz.Header = 'Melhorar voz (no Teams use o mic "CABLE Output")'; $miVoz.IsCheckable = $true; $miVoz.IsChecked = [bool]$cfg.MelhorarVoz
$miGanho = New-Object System.Windows.Controls.MenuItem; $miGanho.Header = 'Ganho da voz'
foreach ($db in 6, 9, 12, 15, 18, 21, 24) {
    $mi = New-Object System.Windows.Controls.MenuItem; $mi.Header = "+$db dB"; $mi.Tag = $db; $mi.IsCheckable = $true; $mi.IsChecked = ($cfg.GanhoDb -eq $db)
    $mi.Add_Click({
        param($s, $e)
        $cfg.GanhoDb = [int]$s.Tag; [VoiceBridge]::GainDb = [float]$cfg.GanhoDb; Save-Config
        foreach ($i in $miGanho.Items) { $i.IsChecked = ($i.Tag -eq $cfg.GanhoDb) }
        Write-Log "Melhorar voz: ganho alterado para +$($cfg.GanhoDb) dB"
    })
    [void]$miGanho.Items.Add($mi)
}
$miPadrao = New-Object System.Windows.Controls.MenuItem; $miPadrao.Header = 'Manter CABLE Output como mic padrao do Windows'; $miPadrao.IsCheckable = $true; $miPadrao.IsChecked = [bool]$cfg.MicPadraoCable
$miPadrao.Add_Click({ $cfg.MicPadraoCable = $miPadrao.IsChecked; Save-Config; if (-not $cfg.MicPadraoCable) { Set-MicPadrao $false -Forcar } })
$miFull = New-Object System.Windows.Controls.MenuItem; $miFull.Header = 'Voltar volume do mic para 100%'
$miKeep = New-Object System.Windows.Controls.MenuItem; $miKeep.Header = 'Manter volume em 100% automaticamente'; $miKeep.IsCheckable = $true; $miKeep.IsChecked = [bool]$cfg.ManterEm100
$miLog  = New-Object System.Windows.Controls.MenuItem; $miLog.Header = 'Abrir log'
$miExit = New-Object System.Windows.Controls.MenuItem; $miExit.Header = 'Fechar'
$miVoz.Add_Click({ $cfg.MelhorarVoz = $miVoz.IsChecked; Save-Config; if (-not $cfg.MelhorarVoz) { Stop-Ponte 'desativado no menu'; Set-MicPadrao $false -Forcar } })
$miFull.Add_Click({ if ($script:alvo) { [MicVol]::SetFull($script:alvo.Id); Write-Log 'Restaurado para 100% (manual)' } })
$miKeep.Add_Click({ $cfg.ManterEm100 = $miKeep.IsChecked; Save-Config })
$miLog.Add_Click({ if (-not (Test-Path $logFile)) { Write-Log 'Log criado' }; Start-Process notepad.exe $logFile })
$miExit.Add_Click({ $win.Close() })
foreach ($i in $miVoz, $miGanho, $miPadrao, (New-Object System.Windows.Controls.Separator), $miFull, $miKeep, $miLog, (New-Object System.Windows.Controls.Separator), $miExit) { [void]$menu.Items.Add($i) }
$card.ContextMenu = $menu

$win.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) { if ($script:alvo) { [MicVol]::SetFull($script:alvo.Id); Write-Log 'Restaurado para 100% (duplo clique)' } }
    else { try { $win.DragMove(); Save-Config } catch {} }
})

$verde    = [Windows.Media.Brushes]::MediumSeaGreen
$amarelo  = [Windows.Media.Brushes]::Goldenrod
$vermelho = [Windows.Media.Brushes]::IndianRed
$cinza    = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x55, 0x55, 0x55))
$texto    = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xDD, 0xDD, 0xDD))
$apagado  = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x88, 0x88, 0x88))
$azul     = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x4F, 0xC3, 0xF7))
$roxo     = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0xB3, 0x88, 0xFF))

function Set-Desligado {
    $rot.Text = "$($cfg.Alvo) off"; $rot.Foreground = $apagado
    $detalhes.Visibility = 'Collapsed'; $card.BorderBrush = $cinza; $card.Opacity = 0.75
    $win.ToolTip = "$($cfg.Alvo) desligado ou desconectado"
}

# Liga a ponte so enquanto algum app capta do CABLE Output (fora disso o fone fica livre, sem Hands-Free)
function Update-Ponte {
    if (-not $cfg.MelhorarVoz) { return }
    Update-Cable
    if (-not $script:cable) { return }

    if ($script:ponte -and -not [VoiceBridge]::Running) {
        Write-Log "Melhorar voz: parou com erro: $([VoiceBridge]::LastError)"
        $script:ponte = $false; $script:proximaTentativa = (Get-Date).AddSeconds(10)
    }

    $consumidor = [MicVol]::SessoesAtivas($script:cable.Out) -gt 0
    if ($consumidor) {
        $script:semConsumidorDesde = $null
        if (-not $script:ponte -and (Get-Date) -ge $script:proximaTentativa) {
            [VoiceBridge]::GainDb = [float]$cfg.GanhoDb
            [VoiceBridge]::Start($script:alvo.Id, $script:cable.In)
            $script:ponte = $true
            Write-Log "Melhorar voz: ligado (+$($cfg.GanhoDb) dB) - app captando do CABLE Output: $(Get-AppsUsandoMic)"
        }
    } elseif ($script:ponte) {
        if (-not $script:semConsumidorDesde) { $script:semConsumidorDesde = Get-Date }
        elseif (((Get-Date) - $script:semConsumidorDesde).TotalSeconds -ge 5) { Stop-Ponte 'nenhum app usando o CABLE Output' }
    }
}

$tick = {
    # (re)localiza o endpoint do fone; enquanto nao achar, tenta de novo a cada 5s
    if (-not $script:alvo -and ((Get-Date) - $script:ultimaBusca).TotalSeconds -ge 5) {
        $script:ultimaBusca = Get-Date; $script:alvo = Find-Alvo
    }

    $p = 0; $mute = $false
    $ok = $script:alvo -and [MicVol]::Read($script:alvo.Id, [ref]$p, [ref]$mute)

    if (-not $ok) {
        Stop-Ponte "$($cfg.Alvo) desconectado"
        if ($script:conectado -ne $false) {
            if ($script:conectado) { Write-Log "$($cfg.Alvo) desconectado" }
            Set-Desligado
        }
        $script:conectado = $false; $script:anterior = $null
        Update-Cable; Set-MicPadrao $false
        if (((Get-Date) - $script:ultimaBusca).TotalSeconds -ge 5) { $script:alvo = $null }   # pode ter sido pareado de novo
        return
    }

    if (-not $script:conectado) {
        Write-Log "$($cfg.Alvo) conectado - volume do mic: $p%"
        $rot.Text = $cfg.Alvo; $rot.Foreground = $texto
        $detalhes.Visibility = 'Visible'; $card.Opacity = 1.0
        $win.ToolTip = $script:alvo.Nome
        $script:conectado = $true
    }

    if ($null -ne $script:anterior -and $p -lt $script:anterior) {
        Write-Log ("Queda: {0}% -> {1}%  | apps usando o mic: {2}" -f $script:anterior, $p, (Get-AppsUsandoMic))
    }

    if ($cfg.ManterEm100 -and ($p -lt 100 -or $mute)) {
        [MicVol]::SetFull($script:alvo.Id); Write-Log "Restaurado para 100% (automatico, estava em $p%)"; $p = 100; $mute = $false
    }
    $script:anterior = $p

    $cor = if ($mute -or $p -lt 40) { $vermelho } elseif ($p -lt $alerta) { $amarelo } else { $verde }
    $pct.Text = if ($mute) { 'MUDO' } else { "$p%" }
    $barra.Width = 70 * [Math]::Min(100, $p) / 100
    $barra.Background = $cor
    $card.BorderBrush = if ($cor -eq $verde) { $cinza } else { $cor }

    Update-Cable; Set-MicPadrao $true
    Update-Ponte
}

$script:micAtivo = $false
$tickApps = {
    $apps = Get-AppsUsandoMic
    $script:micAtivo = $apps -ne 'nenhum'
    $vozRot.ToolTip = if ($script:ponte) { "Melhorar voz ativo (+$($cfg.GanhoDb) dB) - barra mostra o que o Teams recebe" }
                      elseif ($script:micAtivo) { "Captando: $apps" } else { 'Nenhum app usando o microfone' }
}

# Medidor de voz: pico em escala dB (-60..0 dB) com decaimento suave.
# Com a ponte ligada mostra a saida tratada (roxo); senao, o pico do fone (azul).
$script:nivel = 0.0
$tickVoz = {
    if (-not $script:conectado) { return }
    if ($script:ponte) {
        $peak = [VoiceBridge]::TakePeak(); $voz.Background = $roxo; $vozRot.Text = 'voz+'
    } else {
        $peak = [MicVol]::Peak(); $voz.Background = $azul; $vozRot.Text = 'voz'
        if ($peak -lt 0 -or -not $script:micAtivo) {
            $vozRot.Foreground = $cinza; $voz.Width = 0; $script:nivel = 0.0; return
        }
    }
    $alvoNivel = if ($peak -le 0.001) { 0.0 } else { [Math]::Min(1.0, [Math]::Max(0.0, (20 * [Math]::Log10($peak) + 60) / 60)) }
    $script:nivel = [Math]::Max($alvoNivel, $script:nivel * 0.85)
    $voz.Width = 60 * $script:nivel
    $vozRot.Foreground = [Windows.Media.Brushes]::LightGray
}

$win.Add_SizeChanged({
    param($s, $e)
    # ao encolher/crescer, mantem a borda direita no lugar (o widget fica perto da bandeja)
    if ($e.PreviousSize.Width -gt 0) { $win.Left += $e.PreviousSize.Width - $e.NewSize.Width }
    # e mantem o widget inteiro dentro da tela em que ele esta
    $src = [System.Windows.PresentationSource]::FromVisual($win)
    if (-not $src) { return }
    $m = $src.CompositionTarget.TransformToDevice
    $tela = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point ([int]($win.Left * $m.M11)), ([int]($win.Top * $m.M22)))).WorkingArea
    $win.Left = [Math]::Max($tela.Left / $m.M11, [Math]::Min($win.Left, $tela.Right / $m.M11 - $win.ActualWidth))
    $win.Top  = [Math]::Max($tela.Top / $m.M22,  [Math]::Min($win.Top,  $tela.Bottom / $m.M22 - $win.ActualHeight))
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1000)
$timer.Add_Tick({ & $tick; & $tickApps })
$timerVoz = New-Object System.Windows.Threading.DispatcherTimer
$timerVoz.Interval = [TimeSpan]::FromMilliseconds(50)
$timerVoz.Add_Tick($tickVoz)
$win.Add_Loaded({ & $tick; & $tickApps; $timer.Start(); $timerVoz.Start() })
$win.Add_Closed({ $timer.Stop(); $timerVoz.Stop(); Stop-Ponte 'widget fechado'; Set-MicPadrao $false -Forcar; Save-Config; $mutex.ReleaseMutex() })

[void]$win.ShowDialog()
