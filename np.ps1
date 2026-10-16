param([string]$Label, [string]$Exe, [int]$Reps = 3)
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (-not ('W32' -as [type])) {
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public static class W32 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr p, EnumProc f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, StringBuilder l);
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  public static string ReadEdit(IntPtr top) {
    string best = null;
    EnumChildWindows(top, (h, l) => {
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      var cn = c.ToString();
      if (cn == "Edit" || cn.StartsWith("RichEdit")) {
        int n = (int)SendMessage(h, 0x000E, IntPtr.Zero, IntPtr.Zero);
        var sb = new StringBuilder(n + 2); SendMessage(h, 0x000D, (IntPtr)(n + 1), sb);
        if (best == null || sb.Length > best.Length) best = sb.ToString();
      }
      return true; }, IntPtr.Zero);
    return best;
  }
}
"@
}
$case = Get-Content "$PSScriptRoot\case1.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$exp = $case.expected -replace "`r`n", "`n"
$frames = @($case.frames | ForEach-Object { $_ | ConvertTo-Json -Compress })

Get-Process lazyvoicetype* -EA 0 | Stop-Process -Force; Start-Sleep 1
Remove-Item "$env:LOCALAPPDATA\LazyVoiceType" -Recurse -Force -EA 0
$proc = Start-Process $Exe -ArgumentList '--quiet' -PassThru
for ($i = 0; $i -lt 40 -and -not (Test-Path "$env:LOCALAPPDATA\LazyVoiceType\config.json"); $i++) { Start-Sleep 1 }
Start-Sleep 3
$code = (Get-Content "$env:LOCALAPPDATA\LazyVoiceType\config.json" | ConvertFrom-Json).PairCode

for ($rep = 1; $rep -le $Reps; $rep++) {
  Get-Process notepad -EA 0 | Stop-Process -Force; Start-Sleep 1
  Set-Clipboard -Value 'LVT-SENTINEL'
  $np = Start-Process notepad -PassThru; Start-Sleep 3
  $np.Refresh(); $h = $np.MainWindowHandle
  if ($h -eq [IntPtr]::Zero) { $h = (Get-Process notepad | Where-Object MainWindowHandle -ne 0 | Select-Object -First 1).MainWindowHandle }
  [W32]::ShowWindow($h, 3) | Out-Null
  [W32]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [W32]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  [W32]::SetForegroundWindow($h) | Out-Null; Start-Sleep 1
  $fgOk = ([W32]::GetForegroundWindow() -eq $h)
  $ws = New-Object Net.WebSockets.ClientWebSocket
  $ws.ConnectAsync('ws://127.0.0.1:8771/ws', [Threading.CancellationToken]::None).Wait()
  function S($j) { $b = [Text.Encoding]::UTF8.GetBytes($j); $ws.SendAsync([ArraySegment[byte]]$b, 'Text', $true, [Threading.CancellationToken]::None).Wait() }
  S (@{ t = 'auth'; code = $code } | ConvertTo-Json -Compress); Start-Sleep 2
  foreach ($j in $frames) { S $j }
  $last = -1; $stable = 0
  for ($k = 0; $k -lt 240 -and $stable -lt 8; $k++) {
    Start-Sleep -Milliseconds 500
    $g = [W32]::ReadEdit($h); $len = if ($g) { $g.Length } else { -1 }
    if ($len -eq $last) { $stable++ } else { $stable = 0; $last = $len }
  }
  try { $ws.Dispose() } catch {}
  if ($g -eq $null) {
    try { $el = [Windows.Automation.AutomationElement]::FromHandle($h)
      $doc = $el.FindFirst('Descendants', (New-Object Windows.Automation.PropertyCondition([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::Document)))
      $g = $doc.GetCurrentPattern([Windows.Automation.TextPattern]::Pattern).DocumentRange.GetText(-1) } catch { $g = "<read failed: $_>" }
  }
  $g = $g -replace "`r`n", "`n" -replace "`r", "`n"
  $d = -1; for ($k = 0; $k -lt [Math]::Min($g.Length, $exp.Length); $k++) { if ($g[$k] -ne $exp[$k]) { $d = $k; break } }
  if ($d -lt 0 -and $g.Length -ne $exp.Length) { $d = [Math]::Min($g.Length, $exp.Length) }
  $ctx = if ($d -ge 0) { ' got="' + $g.Substring($d, [Math]::Min(25, $g.Length - $d)).Replace("`n", '\n') + '" exp="' + $exp.Substring($d, [Math]::Min(25, [Math]::Max(0, $exp.Length - $d))).Replace("`n", '\n') + '"' } else { '' }
  "RESULT $Label Notepad rep$rep fg=$fgOk exp=$($exp.Length) got=$($g.Length) equal=$($g -ceq $exp) firstdiff=$d vLines=$(([regex]::Matches($g, '(?m)^v$')).Count) blank=$(([regex]::Matches($g, '(?m)^$')).Count)$ctx"
}
"NOTEPAD " + (Get-Command notepad).Source + " " + ((Get-AppxPackage *WindowsNotepad* -EA 0).Version)
Get-Process notepad -EA 0 | Stop-Process -Force
Stop-Process -Id $proc.Id -Force -EA 0
