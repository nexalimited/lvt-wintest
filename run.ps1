param([string]$Label, [string]$Exe, [int]$Reps = 3)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
if (-not ('SlowBox' -as [type])) {
Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System; using System.Runtime.InteropServices; using System.Windows.Forms;
public class SlowBox : TextBox {
  public int Delay = 0;
  protected override void WndProc(ref Message m) {
    if (Delay > 0 && m.Msg == 0x0100 && (int)m.WParam == 0x56 && (Control.ModifierKeys & Keys.Control) != 0) System.Threading.Thread.Sleep(Delay);
    if (Delay > 0 && m.Msg == 0x0302) System.Threading.Thread.Sleep(Delay);
    base.WndProc(ref m);
  }
}
public class SlowRich : RichTextBox {
  public int Delay = 0;
  protected override void WndProc(ref Message m) {
    if (Delay > 0 && m.Msg == 0x0100 && (int)m.WParam == 0x56) System.Threading.Thread.Sleep(Delay);
    base.WndProc(ref m);
  }
}
public static class Fg {
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
}
$case = Get-Content "$PSScriptRoot\case1.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$exp = $case.expected
$frames = @($case.frames | ForEach-Object { $_ | ConvertTo-Json -Compress })

Get-Process lazyvoicetype* -EA 0 | Stop-Process -Force; Start-Sleep 1
Remove-Item "$env:LOCALAPPDATA\LazyVoiceType" -Recurse -Force -EA 0
$proc = Start-Process $Exe -ArgumentList '--quiet' -PassThru
for ($i = 0; $i -lt 40 -and -not (Test-Path "$env:LOCALAPPDATA\LazyVoiceType\config.json"); $i++) { Start-Sleep 1 }
Start-Sleep 3
$code = (Get-Content "$env:LOCALAPPDATA\LazyVoiceType\config.json" | ConvertFrom-Json).PairCode

$results = @()
foreach ($target in @('TextBox', 'SlowTextBox700', 'RichTextBox', 'SlowRich700')) {
 for ($rep = 1; $rep -le $Reps; $rep++) {
  Set-Clipboard -Value 'LVT-SENTINEL'
  $f = New-Object Windows.Forms.Form; $f.Text = 'LVTtest'; $f.Width = 900; $f.Height = 600; $f.TopMost = $true
  if ($target -like '*Rich*') { $tb = New-Object SlowRich } else { $tb = New-Object SlowBox; $tb.Multiline = $true; $tb.AcceptsReturn = $true; $tb.MaxLength = 0 }
  if ($target -like '*700') { $tb.Delay = 700 }
  $tb.Dock = 'Fill'; $f.Controls.Add($tb)
  $st = [hashtable]::Synchronized(@{ done = $false; err = '' })
  $rs = [runspacefactory]::CreateRunspace(); $rs.Open(); $ps = [powershell]::Create(); $ps.Runspace = $rs
  [void]$ps.AddScript({ param($c, $frames, $st)
    try {
      $ws = New-Object Net.WebSockets.ClientWebSocket
      $ws.ConnectAsync('ws://127.0.0.1:8771/ws', [Threading.CancellationToken]::None).Wait()
      function S($j) { $b = [Text.Encoding]::UTF8.GetBytes($j); $ws.SendAsync([ArraySegment[byte]]$b, 'Text', $true, [Threading.CancellationToken]::None).Wait() }
      S (@{ t = 'auth'; code = $c } | ConvertTo-Json -Compress); Start-Sleep 2
      foreach ($j in $frames) { S $j }   # 真手機貼一篇文：所有 frame 一下過送出
      $st.done = $true; Start-Sleep 900
    } catch { $st.err = "$_"; $st.done = $true }
  }).AddArgument($code).AddArgument($frames).AddArgument($st)
  $script:last = -1; $script:stable = 0; $script:t0 = Get-Date
  $f.Add_Shown({ $f.Activate(); [Fg]::SetForegroundWindow($f.Handle) | Out-Null; $tb.Focus() | Out-Null; $script:h = $ps.BeginInvoke() })
  $tm = New-Object Windows.Forms.Timer; $tm.Interval = 500
  $tm.Add_Tick({
    if ($st.done) { if ($tb.TextLength -eq $script:last) { $script:stable++ } else { $script:stable = 0; $script:last = $tb.TextLength } }
    if ($script:stable -ge 16 -or ((Get-Date) - $script:t0).TotalSeconds -gt 240) { $tm.Stop(); $f.Close() } })
  $tm.Start()
  [void]$f.ShowDialog(); $ps.Stop(); $rs.Close()
  $g = $tb.Text -replace "`r`n", "`n" -replace "`r", "`n"; $e = $exp -replace "`r`n", "`n"
  $d = -1; for ($k = 0; $k -lt [Math]::Min($g.Length, $e.Length); $k++) { if ($g[$k] -ne $e[$k]) { $d = $k; break } }
  if ($d -lt 0 -and $g.Length -ne $e.Length) { $d = [Math]::Min($g.Length, $e.Length) }
  $ctx = if ($d -ge 0) { ' got="' + $g.Substring($d, [Math]::Min(25, $g.Length - $d)).Replace("`n", '\n') + '" exp="' + $e.Substring($d, [Math]::Min(25, [Math]::Max(0, $e.Length - $d))).Replace("`n", '\n') + '"' } else { '' }
  $results += "RESULT $Label $target rep$rep exp=$($e.Length) got=$($g.Length) equal=$($g -ceq $e) firstdiff=$d vCount=$(([regex]::Matches($g, '(?m)^v$')).Count) err=$($st.err)$ctx"
 }
}
Stop-Process -Id $proc.Id -Force -EA 0
$results | ForEach-Object { Write-Output $_ }
