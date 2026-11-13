param(
  [string]$Exe = 'C:\Temp\Xilinx92i\bin\nt\ise.exe',
  [string]$WorkDir = 'C:\Temp\Xilinx92i',
  [int]$WatchSeconds = 96,
  [int]$StackAt = 42,
  [int]$CaptureAt = 30,
  [switch]$NoEnv
)
$ErrorActionPreference = 'Continue'

$cs = @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Dbg {
  // ---------- process launch ----------
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct SI { public uint cb; public string r1,r2,t; public uint x,y,xs,ys,xc,yc,fa,fl; public ushort sw,cb2; public IntPtr r3,h1,h2,h3; }
  [StructLayout(LayoutKind.Sequential)]
  public struct PI { public IntPtr hP,hT; public uint pid,tid; }
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inh, uint fl, IntPtr env, string dir, ref SI si, out PI pi);
  [DllImport("kernel32.dll")] public static extern bool GetExitCodeProcess(IntPtr h, out uint c);
  [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", EntryPoint="CloseHandle")] public static extern bool CloseH(IntPtr h);
  [DllImport("kernel32.dll")] public static extern bool TerminateProcess(IntPtr h, uint c);
  [DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint m);

  public static string Launch(string exe, string workdir) {
    SetErrorMode(0x8003);
    SI si = new SI(); si.cb = (uint)Marshal.SizeOf(typeof(SI));
    PI pi;
    if (!CreateProcessW(exe, "\"" + exe + "\"", IntPtr.Zero, IntPtr.Zero, false, 0x04000000, IntPtr.Zero, workdir, ref si, out pi)) {
      return "FAIL:" + Marshal.GetLastWin32Error();
    }
    CloseH(pi.hT);
    return pi.pid + "|" + pi.hP.ToInt64();
  }

  // ---------- windows ----------
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  public struct RECT { public int L,T,R,B; }
  public static HashSet<int> WFilter; public static List<string> WOut; public static EnumProc WDel;
  public static bool WCallback(IntPtr h, IntPtr l) {
    uint pid; GetWindowThreadProcessId(h, out pid);
    if (WFilter.Contains((int)pid)) {
      StringBuilder t = new StringBuilder(512); GetWindowTextW(h, t, 512);
      StringBuilder c = new StringBuilder(256); GetClassNameW(h, c, 256);
      RECT r; GetWindowRect(h, out r);
      WOut.Add(h.ToInt64() + "|" + pid + "|" + (IsWindowVisible(h)?1:0) + "|" + (r.R-r.L) + "|" + (r.B-r.T) + "|" + c.ToString() + "|" + t.ToString());
    }
    return true;
  }
  public static List<string> WindowsOf(int[] pids) {
    WFilter = new HashSet<int>(pids); WOut = new List<string>();
    WDel = new EnumProc(WCallback);
    EnumWindows(WDel, IntPtr.Zero);
    return WOut;
  }

  // ---------- modules ----------
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
  public static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
  public static extern bool Module32FirstW(IntPtr snap, ref MODULEENTRY32W me);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)]
  public static extern bool Module32NextW(IntPtr snap, ref MODULEENTRY32W me);
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct MODULEENTRY32W {
    public uint dwSize; public uint th32ModuleID; public uint th32ProcessID; public uint GlblcntUsage; public uint ProccntUsage;
    public IntPtr modBaseAddr; public uint modBaseSize; public IntPtr hModule;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=256)] public string szModule;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=260)] public string szExePath;
  }
  public static List<string> ModulesOf(uint pid) {
    List<string> res = new List<string>();
    IntPtr snap = CreateToolhelp32Snapshot(0x18, pid);
    if (snap == (IntPtr)(-1)) { res.Add("SNAPFAIL gle=" + Marshal.GetLastWin32Error()); return res; }
    MODULEENTRY32W me = new MODULEENTRY32W(); me.dwSize = (uint)Marshal.SizeOf(typeof(MODULEENTRY32W));
    if (Module32FirstW(snap, ref me)) {
      do { res.Add(me.modBaseAddr.ToInt64().ToString("X") + "+" + me.modBaseSize.ToString("X") + " " + me.szModule); }
      while (Module32NextW(snap, ref me));
    } else { res.Add("Module32First failed gle=" + Marshal.GetLastWin32Error()); }
    CloseH(snap);
    return res;
  }

  // ---------- threads / stacks ----------
  [DllImport("kernel32.dll")] public static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
  [DllImport("kernel32.dll")] public static extern uint Wow64SuspendThread(IntPtr h);
  [DllImport("kernel32.dll")] public static extern int ResumeThread(IntPtr h);
  [DllImport("kernel32.dll")] public static extern bool Wow64GetThreadContext(IntPtr h, ref W64CTX ctx);
  [DllImport("kernel32.dll")] public static extern bool ReadProcessMemory(IntPtr proc, IntPtr addr, byte[] buf, int size, out int read);
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
  [DllImport("kernel32.dll")] public static extern bool Thread32First(IntPtr snap, ref THREADENTRY32 te);
  [DllImport("kernel32.dll")] public static extern bool Thread32Next(IntPtr snap, ref THREADENTRY32 te);
  [StructLayout(LayoutKind.Sequential)]
  public struct THREADENTRY32 { public uint dwSize; public uint cntUsage; public uint th32ThreadID; public uint th32OwnerProcessID; public int tpBasePri; public int tpDeltaPri; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential)]
  public struct W64CTX {
    public uint ContextFlags;
    public uint Dr0,Dr1,Dr2,Dr3,Dr6,Dr7;
    public uint fs0,fs1,fs2,fs3,fs4,fs5,fs6;
    public uint fs8,fs9,fs10,fs11,fs12,fs13,fs14,fs15,fs16,fs17,fs18,fs19,fs20,fs21,fs22,fs23,fs24,fs25,fs26,fs27;
    public uint fsCr0Npx;
    public uint SegGs,SegFs,SegEs,SegDs;
    public uint Edi,Esi,Ebx,Edx,Ecx,Eax;
    public uint Ebp,Eip,SegCs,EFlags,Esp,SegSs;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst=128)] public uint[] xr;
  }

  public static string Symbolize(uint addr, List<long> bases, List<uint> sizes, List<string> names) {
    for (int i = 0; i < bases.Count; i++) {
      if (addr >= bases[i] && addr < bases[i] + (long)sizes[i]) {
        return names[i] + "+0x" + (addr - (uint)bases[i]).ToString("X");
      }
    }
    return "0x" + addr.ToString("X8");
  }

  public static List<string> StacksOf(uint pid) {
    List<string> outp = new List<string>();
    List<long> bases = new List<long>(); List<uint> sizes = new List<uint>(); List<string> names = new List<string>();
    foreach (string m in ModulesOf(pid)) {
      string[] parts = m.Split(' ');
      if (parts.Length == 2 && parts[0].IndexOf("+") >= 0) {
        string[] bs = parts[0].Split('+');
        long b; uint s;
        if (long.TryParse(bs[0], System.Globalization.NumberStyles.HexNumber, null, out b) && uint.TryParse(bs[1], System.Globalization.NumberStyles.HexNumber, null, out s)) {
          bases.Add(b); sizes.Add(s); names.Add(parts[1]);
        }
      }
    }
    IntPtr proc = OpenProcess(0x0410, false, pid);
    if (proc == IntPtr.Zero || proc == (IntPtr)(-1)) { outp.Add("OpenProcess failed"); return outp; }
    IntPtr snap = CreateToolhelp32Snapshot(0x4, pid);
    THREADENTRY32 te = new THREADENTRY32(); te.dwSize = (uint)Marshal.SizeOf(typeof(THREADENTRY32));
    if (Thread32First(snap, ref te)) {
      do {
        if (te.th32OwnerProcessID != pid) continue;
        IntPtr th = OpenThread(0x4A, false, te.th32ThreadID);
        if (th == IntPtr.Zero) { outp.Add("tid " + te.th32ThreadID + ": OpenThread failed"); continue; }
        Wow64SuspendThread(th);
        W64CTX ctx = new W64CTX(); ctx.xr = new uint[128]; ctx.ContextFlags = 0x10007;
        if (!Wow64GetThreadContext(th, ref ctx)) {
          outp.Add("tid " + te.th32ThreadID + ": ctx failed gle=" + Marshal.GetLastWin32Error());
          ResumeThread(th); CloseH(th); continue;
        }
        StringBuilder sb = new StringBuilder();
        sb.Append("tid " + te.th32ThreadID + " eip=" + Symbolize(ctx.Eip, bases, sizes, names) + " esp=" + ctx.Esp.ToString("X8") + " : ");
        uint ebp = ctx.Ebp; int frames = 0;
        while (frames < 24) {
          byte[] buf = new byte[8]; int rd;
          if (!ReadProcessMemory(proc, (IntPtr)(long)ebp, buf, 8, out rd) || rd < 8) break;
          uint nextEbp = BitConverter.ToUInt32(buf, 0);
          uint ret = BitConverter.ToUInt32(buf, 4);
          if (ret == 0) break;
          sb.Append(Symbolize(ret, bases, sizes, names) + " <- ");
          if (nextEbp <= ebp || nextEbp - ebp > 0x100000) break;
          ebp = nextEbp; frames++;
        }
        outp.Add(sb.ToString());
        ResumeThread(th); CloseH(th);
      } while (Thread32Next(snap, ref te));
    } else { outp.Add("Thread32First failed"); }
    CloseH(snap); CloseH(proc);
    return outp;
  }
}
"@
Add-Type -TypeDefinition $cs
Add-Type -AssemblyName System.Drawing

function Get-TreePids([uint32]$rootPid) {
  $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)
  $set = New-Object 'System.Collections.Generic.HashSet[uint32]'
  [void]$set.Add($rootPid)
  $changed = $true
  while ($changed) {
    $changed = $false
    foreach ($p in $all) {
      $pidU = [uint32]$p.ProcessId; $ppidU = [uint32]$p.ParentProcessId
      if ($set.Contains($pidU)) { continue }
      if ($set.Contains($ppidU)) { [void]$set.Add($pidU); $changed = $true }
    }
  }
  return $set
}

if (-not $NoEnv) {
  $env:XILINX = $WorkDir
  $env:PATH = (Split-Path $Exe) + ';' + $env:PATH
}

$r = [Dbg]::Launch($Exe, $WorkDir)
"LAUNCH: $r"
if ($r -like 'FAIL:*') { return }
$parts = $r -split '\|'
$rootPid = [uint32]$parts[0]
$hProc = [IntPtr][long]$parts[1]

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$stackDone = $false; $captured = $false; $exited = $false; $prevCpu = -1.0
while ($sw.Elapsed.TotalSeconds -lt $WatchSeconds) {
  Start-Sleep -Seconds 3
  if ([Dbg]::WaitForSingleObject($hProc, 0) -eq 0) {
    $c2 = [uint32]0; [Dbg]::GetExitCodeProcess($hProc, [ref]$c2) | Out-Null
    "EXITED at t=$([int]$sw.Elapsed.TotalSeconds)s code=0x$($c2.ToString('X8'))"; $exited = $true; break
  }
  $t = [int]$sw.Elapsed.TotalSeconds
  $pids = Get-TreePids $rootPid
  $ints = @($pids | ForEach-Object { [int]$_ })
  $wins = [Dbg]::WindowsOf($ints)
  $procObj = Get-Process -Id $rootPid -ErrorAction SilentlyContinue
  $cpu = if ($procObj) { [math]::Round($procObj.TotalProcessorTime.TotalSeconds,2) } else { -1 }
  $vis = @($wins | Where-Object { ($_ -split '\|')[2] -eq '1' -and [int]($_ -split '\|')[3] -gt 60 -and [int]($_ -split '\|')[4] -gt 40 })
  $titles = ($vis | ForEach-Object { ($_ -split '\|')[6] }) -join ' | '
  "t=${t}s cpu=$cpu (d=$([math]::Round($cpu-$prevCpu,2))) pids=[$($pids -join ',')] wins=$($wins.Count) vis=$($vis.Count) titles=[$titles]"
  $prevCpu = $cpu
  if (-not $captured -and $t -ge $CaptureAt -and $vis.Count -gt 0) {
    $i = 0
    foreach ($v in ($vis | Select-Object -First 2)) {
      $f = ($v -split '\|')
      try {
        $bmp = New-Object System.Drawing.Bitmap ([int]$f[3]), ([int]$f[4])
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $hdc = $g.GetHdc()
        [Dbg]::PrintWindow([IntPtr][long]$f[0], $hdc, 2) | Out-Null
        $g.ReleaseHdc($hdc); $g.Dispose()
        $path = "C:\Users\Joe\AppData\Local\Temp\ise_w${i}_t${t}.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
        "CAPTURED $path title='$($f[6])' class=$($f[5])"
        $i++
      } catch { "capture failed: $_" }
    }
    $captured = $true
  }
  if (-not $stackDone -and $t -ge $StackAt) {
    "--- STACKS at t=${t}s ---"
    try { [Dbg]::StacksOf($rootPid) | ForEach-Object { "  " + $_ } } catch { "stack dump failed: $_" }
    "--- MODULES (Xilinx only) at t=${t}s ---"
    try { $m = [Dbg]::ModulesOf($rootPid); "  total modules: $($m.Count)"; $m | Where-Object { $_ -match 'Xilinx92i' } | ForEach-Object { "  " + $_ } } catch { "module dump failed: $_" }
    $stackDone = $true
  }
}
if (-not $exited) { "watch ended, process still alive" }
$pids = Get-TreePids $rootPid
foreach ($p in $pids) { Get-Process -Id $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue }
[Dbg]::TerminateProcess($hProc, 1) | Out-Null
[Dbg]::CloseH($hProc) | Out-Null
"killed tree: [$($pids -join ',')]"