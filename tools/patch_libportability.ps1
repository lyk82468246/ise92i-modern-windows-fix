#requires -Version 5.1
<#
.SYNOPSIS
  Xilinx ISE 9.2i tool-startup fix for Windows 10 (1903+) / Windows 11.

.DESCRIPTION
  ISE 9.2i command-line tools (createsch, sch2sym, asc2sch, ...) abort during
  process initialization with:

    "Environment variable 'TEMP' not defined or points at a non-existant
     directory or a non-writable directory."   (exit code 19)

  The message is misleading: TEMP is fine. libPortability.dll validates the
  temp directory by probing it through its 2007-era CRT/STL machinery, and
  that validation fails for perfectly valid directories when the DLL runs in
  the tools' process-initialization context (the same code passes when the
  DLL is loaded at runtime - verified experimentally).

  Fix: libPortability!validate (14-byte prologue signature below) is patched
  in place to unconditionally accept the directory (mov al,1 / ret - 3 bytes).
  The original file is kept as libPortability.dll.orig next to it.

  The patch is signature-verified: it is applied only when the expected
  original bytes are found exactly once, and it refuses to touch anything
  else. Use -Revert to restore the pristine file.

.PARAMETER BinNt
  Path to the ISE installation's bin\nt directory (the one containing
  ise.exe and libPortability.dll).

.PARAMETER Revert
  Restore libPortability.dll from the libPortability.dll.orig backup.

.PARAMETER Status
  Only report whether the patch is applied; change nothing.

.EXAMPLE
  .\patch_libportability.ps1 -BinNt "C:\Xilinx\92i\bin\nt"
  .\patch_libportability.ps1 -BinNt "C:\Xilinx\92i\bin\nt" -Status
  .\patch_libportability.ps1 -BinNt "C:\Xilinx\92i\bin\nt" -Revert
#>
param(
  [Parameter(Mandatory = $true, Position = 0)]
  [string]$BinNt,
  [switch]$Revert,
  [switch]$Status
)

$ErrorActionPreference = 'Stop'
$dll = Join-Path $BinNt 'libPortability.dll'
$bak = Join-Path $BinNt 'libPortability.dll.orig'

if (-not (Test-Path $dll)) {
  throw "libPortability.dll not found under: $BinNt"
}

$enc = [System.Text.Encoding]::GetEncoding(28591)  # ISO-8859-1: byte<->char 1:1

# libPortability!validate prologue in ISE 9.2i:
#   64 A1 00 00 00 00      mov eax, dword ptr fs:[0]
#   6A FF                  push -1
#   68 A4 F6 04 10         push 0x1004F6A4   (SEH scope table)
#   50                     push eax
$sig = [byte[]](0x64,0xA1,0x00,0x00,0x00,0x00,0x6A,0xFF,0x68,0xA4,0xF6,0x04,0x10,0x50)
# what the first 3 bytes look like after the patch (mov al,1 / ret)
$patchedHead = [byte[]](0xB0,0x01,0xC3)

function Find-All([byte[]]$hay, [byte[]]$needle) {
  $hs = $enc.GetString($hay)
  $ns = $enc.GetString($needle)
  $found = New-Object System.Collections.Generic.List[int]
  $i = $hs.IndexOf($ns, [System.StringComparison]::Ordinal)
  while ($i -ge 0) { $found.Add($i); $i = $hs.IndexOf($ns, $i + 1, [System.StringComparison]::Ordinal) }
  return ,$found
}

$bytes = [System.IO.File]::ReadAllBytes($dll)

# state detection: patched sites carry (patchedHead + sig[3..])
$patchedSig = New-Object byte[] (3 + $sig.Count - 3)
[Array]::Copy($patchedHead, 0, $patchedSig, 0, 3)
[Array]::Copy($sig, 3, $patchedSig, 3, $sig.Count - 3)
$patchedHits = Find-All $bytes $patchedSig
$origHits = Find-All $bytes $sig

if ($Status) {
  if ($patchedHits.Count -eq 1) { "PATCHED (offset 0x{0:X})" -f $patchedHits[0] }
  elseif ($origHits.Count -eq 1) { "NOT PATCHED (validate at file offset 0x{0:X})" -f $origHits[0] }
  else { "UNKNOWN STATE (orig matches: $($origHits.Count), patched matches: $($patchedHits.Count))" }
  return
}

if ($Revert) {
  if (-not (Test-Path $bak)) { throw "backup not found: $bak (nothing to revert)" }
  Copy-Item $bak $dll -Force
  $now = [System.IO.File]::ReadAllBytes($dll)
  $chk = Find-All $now $sig
  if ($chk.Count -eq 1) { "REVERTED OK (validate found at file offset 0x{0:X})" -f $chk[0] }
  else { "REVERTED, but signature check found $($chk.Count) matches - inspect manually" }
  return
}

if ($patchedHits.Count -eq 1 -and $origHits.Count -eq 0) {
  "Already patched (offset 0x{0:X}). Nothing to do." -f $patchedHits[0]
  return
}
if ($origHits.Count -ne 1) {
  throw "Expected exactly 1 match of the validate prologue, found $($origHits.Count). Aborting - no changes made. (Different ISE version?)"
}
$off = $origHits[0]

# make sure no ISE process is holding the file
$locked = $true
try {
  $fs = [System.IO.File]::Open($dll, 'Open', 'ReadWrite', 'None'); $fs.Close(); $locked = $false
} catch { }
if ($locked) { throw "libPortability.dll is locked - close all ISE processes and retry." }

if (-not (Test-Path $bak)) { Copy-Item $dll $bak -Force }

$bytes[$off] = 0xB0; $bytes[$off + 1] = 0x01; $bytes[$off + 2] = 0xC3
[System.IO.File]::WriteAllBytes($dll, $bytes)

$verify = Find-All ([System.IO.File]::ReadAllBytes($dll)) $patchedSig
if ($verify.Count -eq 1) {
  "PATCHED OK: libPortability!validate -> 'mov al,1; ret' at file offset 0x{0:X}." -f $verify[0]
  "Original preserved as: $bak"
  "Revert any time with:  .\patch_libportability.ps1 -BinNt `"$BinNt`" -Revert"
} else {
  throw "Post-patch verification failed - restore from $bak and report this."
}
