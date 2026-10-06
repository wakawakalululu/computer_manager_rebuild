param(
  [string]$Action = 'rect',
  [string]$Class = 'FLUTTER_RUNNER_WIN32_WINDOW',
  [int]$X = 0,
  [int]$Y = 0,
  [int]$BX = 0,
  [int]$BY = 0,
  [int]$D = -360,
  [string]$T = '',
  [int]$ProcId = 0,
  [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class UI {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
  [DllImport("user32.dll")] public static extern int GetClassName(IntPtr hWnd, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  public static IntPtr WindowAt(int x, int y) {
    // wrapper: PowerShell cannot pass a struct by value, so take ints here
    POINT p = new POINT(); p.X = x; p.Y = y;
    return GetAncestor(WindowFromPoint(p), 2);   // GA_ROOT
  }
  public static string InfoAt(int x, int y) {
    IntPtr h = WindowAt(x, y);
    if (h == IntPtr.Zero) return "none";
    StringBuilder sb = new StringBuilder(256);
    GetClassName(h, sb, 256);
    uint pid = 0;
    GetWindowThreadProcessId(h, out pid);
    RECT r;
    GetWindowRect(h, out r);
    return "hwnd=" + h.ToInt64() + " class=" + sb + " pid=" + pid + " vis=" +
           IsWindowVisible(h) + " rect=" + r.L + "," + r.T + "," + (r.R - r.L) + "," + (r.B - r.T);
  }
  [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT pt);
  [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int idx);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cbSize);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
  public static void TypeText(string s) {
    foreach (char c in s) {
      INPUT[] ins = new INPUT[2];
      ins[0].type = 1; ins[0].ki.wScan = (ushort)c; ins[0].ki.dwFlags = 0x0004;   // KEYEVENTF_UNICODE
      ins[1].type = 1; ins[1].ki.wScan = (ushort)c; ins[1].ki.dwFlags = 0x0004 | 0x0002; // + KEYEVENTF_KEYUP
      SendInput(2, ins, Marshal.SizeOf(typeof(INPUT)));
    }
  }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT {
    public ushort vk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  [StructLayout(LayoutKind.Explicit)] public struct INPUT {
    [FieldOffset(0)] public uint type;
    [FieldOffset(8)] public MOUSEINPUT mi;
    [FieldOffset(8)] public KEYBDINPUT ki;
  }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT {
    public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo;
  }
  public static void PressKey(ushort vk) {
    INPUT[] ins = new INPUT[2];
    ins[0].type = 1; ins[0].ki.vk = vk; ins[0].ki.dwFlags = 0;
    ins[1].type = 1; ins[1].ki.vk = vk; ins[1].ki.dwFlags = 0x0002;  // KEYUP
    SendInput(2, ins, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void HoldKey(ushort vk, bool down) {
    INPUT[] ins = new INPUT[1];
    ins[0].type = 1; ins[0].ki.vk = vk;
    ins[0].ki.dwFlags = down ? (uint)0 : (uint)0x0002;
    SendInput(1, ins, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void WinB() {
    HoldKey(0x5B, true);            // VK_LWIN down
    PressKey(0x42);                 // 'B'
    HoldKey(0x5B, false);           // up
  }
  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr hWnd);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public static void ClickAt(int x, int y) {    SetCursorPos(x, y);
    int vl = GetSystemMetrics(76), vt = GetSystemMetrics(77);
    int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    int nx = ((x - vl) * 65535) / (vw - 1);
    int ny = ((y - vt) * 65535) / (vh - 1);
    uint abs = 0x8000 | 0x4000;   // ABSOLUTE | VIRTUALDESK
    INPUT[] ins = new INPUT[2];
    ins[0].type = 0; ins[0].mi.dx = nx; ins[0].mi.dy = ny; ins[0].mi.dwFlags = abs | 0x0002;
    ins[1].type = 0; ins[1].mi.dx = nx; ins[1].mi.dy = ny; ins[1].mi.dwFlags = abs | 0x0004;
    SendInput(2, ins, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void WheelAt(int x, int y, int delta) {
    SetCursorPos(x, y);
    int vl = GetSystemMetrics(76), vt = GetSystemMetrics(77);
    int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
    INPUT[] ins = new INPUT[1];
    ins[0].type = 0;
    ins[0].mi.dx = ((x - vl) * 65535) / (vw - 1);
    ins[0].mi.dy = ((y - vt) * 65535) / (vh - 1);
    ins[0].mi.mouseData = (uint)delta;
    ins[0].mi.dwFlags = 0x0800 | 0x8000 | 0x4000;   // WHEEL | ABSOLUTE | VIRTUALDESK
    SendInput(1, ins, Marshal.SizeOf(typeof(INPUT)));
  }
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
'@

$script:cbRef = $null

function Find-Target([string]$className) {
  $found = New-Object System.Collections.ArrayList
  $wantPid = 0
  if ($ProcId -le 0) {
    $p = Get-Process -Name 'computer_manager' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p) { $wantPid = $p.Id }
  } else { $wantPid = $ProcId }
  $cb = [UI+EnumProc] {
    param($h, $lp)
    try {
      $cn = New-Object System.Text.StringBuilder 256
      [void][UI]::GetClassName($h, $cn, 256)
      if ($cn.ToString() -eq $className -and [UI]::IsWindowVisible($h)) {
        $pid2 = [uint32]0
        [void][UI]::GetWindowThreadProcessId($h, [ref]$pid2)
        if ($wantPid -eq 0 -or [int]$pid2 -eq $wantPid) {
          $r = New-Object UI+RECT
          [void][UI]::GetWindowRect($h, [ref]$r)
          [void]$found.Add([pscustomobject]@{Hwnd=$h; Pid=$pid2; L=$r.L; T=$r.T; W=($r.R-$r.L); H=($r.B-$r.T)})
        }
      }
    } catch { Write-Output ("CBERR: " + $_.Exception.Message) }
    return $true
  }
  # keep a rooted reference for the whole EnumWindows call, otherwise the delegate
  # gets collected and every callback parameter arrives empty
  $script:cbRef = $cb
  [void][UI]::EnumWindows($script:cbRef, [IntPtr]::Zero)
  $script:cbRef = $null
  return $found
}

switch ($Action) {
  'winb' {
    # Win+B：把键盘焦点送进托盘（Win10 会落在「显示隐藏的图标」上），
    # 之后用 Enter 开浮层、方向键选图标、VK_APPS(93) 触发右键。
    [UI]::WinB()
    Write-Output "winb sent"
  }
  'key' {
    [UI]::PressKey([uint16]::Parse($T))
    Write-Output "key=$T sent"
  }
  'esc' {
    [UI]::PressKey(27)   # VK_ESCAPE：关掉卡住的 shell 菜单浮窗（#32768）
    Write-Output "esc sent"
  }
  'wfp' {
    # 谁盖在这个点上：WindowFromPoint → 根窗口 → 类名/pid/矩形/是否置顶。
    # 托盘自动化踩坑时用来自证坐标落到了哪个窗口（而不是猜）。
    $root = [UI]::WindowAt($X, $Y)
    $info = [UI]::InfoAt($X, $Y)
    Write-Output "point=$X,$Y root=$root info=$info"
  }
  'rect' {
    $items = @(Find-Target $Class)
    Write-Output "count=$($items.Count)"
    foreach ($tgt in $items) {
      Write-Output "hwnd=$($tgt.Hwnd) pid=$($tgt.Pid) left=$($tgt.L) top=$($tgt.T) w=$($tgt.W) h=$($tgt.H)"
    }
  }
  'pos' {
    [void][UI]::SetCursorPos($X, $Y)
    $p = New-Object UI+POINT
    [void][UI]::GetCursorPos([ref]$p)
    foreach ($tgt in (Find-Target $Class)) {
      Write-Output "cursor=$($p.X),$($p.Y) hwndDpi=$([UI]::GetDpiForWindow($tgt.Hwnd)) rect=$($tgt.L),$($tgt.T),$($tgt.W),$($tgt.H)"
    }
  }
  'click' {
    [void][UI]::SetCursorPos($X, $Y)
    [UI]::mouse_event(2, 0, 0, 0, [IntPtr]::Zero)   # LEFTDOWN
    Start-Sleep -Milliseconds 80
    [UI]::mouse_event(4, 0, 0, 0, [IntPtr]::Zero)   # LEFTUP
    Write-Output "clicked $X,$Y"
  }
  'rclick' {
    # 右键：托盘图标只认右键（原生菜单已换成托盘菜单子窗口），mouse_event 的
    # RIGHTDOWN=0x0008 / RIGHTUP=0x0010。坐标仍是本进程的 DPI 虚拟逻辑空间。
    [void][UI]::SetCursorPos($X, $Y)
    Start-Sleep -Milliseconds 120
    [UI]::mouse_event(8, 0, 0, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [UI]::mouse_event(16, 0, 0, 0, [IntPtr]::Zero)
    Write-Output "rclick $X,$Y"
  }
  'fg' {
    $fg = [UI]::GetForegroundWindow()
    $p = [uint32]0
    [void][UI]::GetWindowThreadProcessId($fg, [ref]$p)
    Write-Output "foreground=$fg pid=$p"
  }
  'sclick' {
    # foreground + click in one process, so focus rules cannot swallow the input
    foreach ($tgt in (Find-Target $Class)) { [void][UI]::SetForegroundWindow($tgt.Hwnd) }
    Start-Sleep -Milliseconds 150
    [UI]::ClickAt($X, $Y)
    Write-Output "sclick $X,$Y"
  }
  'bclick' {
    # bitmap coords are physical pixels (PrintWindow), SetCursorPos takes the DPI-virtualized
    # logical space of this unaware process, so divide by the window DPI ratio.
    foreach ($tgt in (Find-Target $Class)) {
      $dpi = [UI]::GetDpiForWindow($tgt.Hwnd)
      $sx = [int]($tgt.L + $BX * 96 / $dpi)
      $sy = [int]($tgt.T + $BY * 96 / $dpi)
      [void][UI]::SetForegroundWindow($tgt.Hwnd)
      Start-Sleep -Milliseconds 150
      [UI]::ClickAt($sx, $sy)
      Write-Output "bclick bitmap=$BX,$BY -> screen=$sx,$sy (dpi=$dpi)"
    }
  }
  'wheel' {
    foreach ($tgt in (Find-Target $Class)) {
      $dpi = [UI]::GetDpiForWindow($tgt.Hwnd)
      [UI]::WheelAt([int]($tgt.L + $BX * 96 / $dpi), [int]($tgt.T + $BY * 96 / $dpi), $D)
      Write-Output "wheel bitmap=$BX,$BY delta=$D"
    }
  }
  'type' {
    [UI]::TypeText($T)
    Write-Output "typed len=$($T.Length)"
  }
  'dump' {
    $f = Find-Target $Class
    Write-Output "ftype=$($f.GetType().FullName)"
    Write-Output "fstr=[$f]"
    Write-Output "fcount=$(@($f).Count)"
  }
  'restore' {
    foreach ($tgt in (Find-Target $Class)) {
      [void][UI]::ShowWindow($tgt.Hwnd, 9)   # SW_RESTORE
      Write-Output "restored hwnd=$($tgt.Hwnd)"
    }
  }
  'max' {
    foreach ($tgt in (Find-Target $Class)) {
      [void][UI]::ShowWindow($tgt.Hwnd, 3)   # SW_MAXIMIZE
      Write-Output "maximized hwnd=$($tgt.Hwnd)"
    }
  }
  'tray' {
    # capture a screen region; default = bottom-right corner (notification area).
    # SetCursorPos/CopyFromScreen use this process's DPI-virtualized (logical) space,
    # while TrayIcon.getBounds() reports physical pixels, so divide by the scale factor.
    if ($Out -eq '') { throw 'need -Out' }
    $sw = [UI]::GetSystemMetrics(0)
    $sh = [UI]::GetSystemMetrics(1)
    $cw = if ($BX -gt 0) { $BX } else { 640 }
    $chh = if ($BY -gt 0) { $BY } else { 72 }
    $cx = if ($X -gt 0) { $X } else { $sw - $cw }
    $cy = if ($Y -gt 0) { $Y } else { $sh - $chh }
    $bmp = New-Object System.Drawing.Bitmap $cw, $chh
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($cx, $cy, 0, 0, (New-Object System.Drawing.Size $cw, $chh))
    $g.Dispose()
    $bmp.Save($Out)
    $bmp.Dispose()
    Write-Output "traycap=$Out at=$cx,$cy size=${cw}x${chh} screen=${sw}x${sh}"
  }
  'shot' {
    if ($Out -eq '') { throw 'need -Out' }
    foreach ($tgt in (Find-Target $Class)) {
      [void][UI]::SetForegroundWindow($tgt.Hwnd)
      Start-Sleep -Milliseconds 200
      # PrintWindow 按窗口的**物理**像素尺寸往目标 DC 上画，不做缩放。本脚本进程
      # 是 DPI 无关的，GetWindowRect 给的是逻辑尺寸（1020x700），直接照它建位图
      # 只会截到左上角那 80%，右边和下边整片被切掉，看起来像 UI 溢出。
      # 另：SetForegroundWindow 之后第一次 GetDpiForWindow 会返回 0（前台切换还没
      # 落定），所以取不到就补一次；再取不到退回逻辑尺寸并说明，别静默截半张图。
      $dpi = [int][UI]::GetDpiForWindow($tgt.Hwnd)
      if ($dpi -le 0) {
        Start-Sleep -Milliseconds 150
        $dpi = [int][UI]::GetDpiForWindow($tgt.Hwnd)
      }
      if ($dpi -le 0) {
        Write-Output "shot: 取不到窗口 DPI，按 96 处理（截出来可能只有左上那块）"
        $dpi = 96
      }
      $pw = [int]($tgt.W * $dpi / 96)
      $ph = [int]($tgt.H * $dpi / 96)
      $bmp = New-Object System.Drawing.Bitmap $pw, $ph
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $hdc = $g.GetHdc()
      $ok = [UI]::PrintWindow($tgt.Hwnd, $hdc, 2)
      $g.ReleaseHdc($hdc)
      $g.Dispose()
      $bmp.Save($Out)
      $bmp.Dispose()
      Write-Output "saved=$Out ok=$ok physical=${pw}x${ph} logical=$($tgt.W)x$($tgt.H) dpi=$dpi hwnd=$($tgt.Hwnd)"
    }
  }
  default { throw "unknown action $Action" }
}
