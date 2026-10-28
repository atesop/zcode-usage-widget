# =====================================================================
# GLM 用量悬浮小组件（Windows 侧）
# 数据来源: WSL 里的 glm_usage_all.py --json（通过 wsl.exe 调用）
# 路径:   查询命令默认从脚本自身位置（\\wsl.localhost\<发行版>\...\windows）
#          自动推导仓库根下的 glm_usage_all.py，无需硬编码绝对路径；
#          也可用 -WslCommand 显式指定完整命令覆盖推导结果
# 行为: 启动即查询 + 每分钟自动刷新（-AutoRefreshSec 可调，0 关闭）；
#       状态栏以身份色 chip 展示各订阅 5 小时窗口已用百分比（简写 01-w/02-z/03-a）；
#       置顶、无边框、可拖动、记忆位置；可停靠屏幕四角（-Dock，拖动即解除）
# 注意: 本文件必须保存为 UTF-8 with BOM（PowerShell 5.1 才能正确读中文）
# =====================================================================
#requires -Version 5.1
param(
    [string]$WslCommand = "",
    [int]$QueryTimeoutMs = 25000,
    [int]$AutoRefreshSec = 60,
    [string]$PosFile = "$env:LOCALAPPDATA\glmu_widget.json",
    # 停靠角落：BottomLeft/BottomRight/TopLeft/TopRight；None 解除停靠；空 = 沿用记忆值
    [string]$Dock = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# -Dock 取值校验（早失败，避免带着非法值跑到定位阶段）
if (@("", "None", "BottomLeft", "BottomRight", "TopLeft", "TopRight") -notcontains $Dock) {
    [System.Windows.MessageBox]::Show(
        "-Dock 取值必须是 BottomLeft / BottomRight / TopLeft / TopRight / None，当前: $Dock",
        "glmu-widget") | Out-Null
    exit 1
}

# ---- 推导 WSL 查询命令：从脚本自身 UNC 位置定位仓库根，不依赖硬编码路径 ----
# $PSScriptRoot 形如 \\wsl.localhost\<发行版>\home\<用户>\...\zcode\windows
# 仓库根 = windows 目录上一级；发行版名单独传给 wsl.exe -d，避免依赖默认发行版
if (-not $WslCommand) {
    $repoRoot = if ($PSScriptRoot) { Split-Path -Parent $PSScriptRoot } else { $null }
    if ($repoRoot -and $repoRoot -match '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)\\(.+)$') {
        $distro  = $Matches[1]
        $wslPath = '/' + ($Matches[2] -replace '\\', '/')
        # 注意：-d 的值不能加引号——旧版 wsl.exe（≤2.4.x，如本机 2.4.13）会把引号当成
        # 发行版名的一部分，找名为 "Ubuntu-22.04"（带引号）的发行版并报
        # WSL_E_DISTRO_NOT_FOUND；错误文本还会以 UTF-16LE 混入 stdout，导致 JSON 解析报
        # "无效的 JSON 基元"。尾部 python3 后的路径引号是传给 WSL 内 shell 消费的，可保留。
        $WslCommand = "-d $distro python3 `"$wslPath/glm_usage_all.py`" --json"
    } else {
        [System.Windows.MessageBox]::Show(
            "无法从脚本位置推导 WSL 仓库路径（$repoRoot）。`n`n请把本脚本放在 WSL 文件系统内仓库的 windows 目录下运行，`n或用 -WslCommand 显式指定，例如：`npython3 /home/<用户>/zcode/glm_usage_all.py --json",
            "glmu-widget") | Out-Null
        exit 1
    }
}

# 单实例保护：已有小组件在跑就把已开的窗口弹到前台（而非静默退出）
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, "Local\glmu-widget-mutex", [ref]$created)
if (-not $created) {
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WExist {
  public delegate bool EnumProc(IntPtr h, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder sb, int max);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);

  public static IntPtr FindGlmu() {
    IntPtr result = IntPtr.Zero;
    EnumWindows(delegate(IntPtr h, IntPtr lp) {
      if (!IsWindowVisible(h)) return true;
      StringBuilder t = new StringBuilder(256);
      GetWindowText(h, t, 256);
      if (t.ToString() == "glmu-widget") { result = h; return false; }
      return true;
    }, IntPtr.Zero);
    return result;
  }
}
'@
        $h = [WExist]::FindGlmu()
        if ($h -ne [IntPtr]::Zero) {
            [void][WExist]::ShowWindow($h, 9)          # SW_RESTORE
            [void][WExist]::SetForegroundWindow($h)
        }
    } catch {}
    exit 0
}

# ---- 配色（与 glmu CLI 一致的暗色系）----
$script:COLOR_TEXT   = "#CDD6F4"   # 正文
$script:COLOR_ACCENT = "#89B4FA"   # 标题/档位
$script:COLOR_DIM    = "#9399B2"   # 次要信息
$script:COLOR_GREEN  = "#A6E3A1"   # 用量 <60%
$script:COLOR_YELLOW = "#F9E2AF"   # 60% ~ 85%
$script:COLOR_RED    = "#F38BA8"   # >=85% 或错误
$script:COLOR_NAME   = "#BAC1D9"   # 维度名

# 每个套餐卡片的身份色板（按名称哈希取色，保证同名套餐颜色稳定）
$script:PALETTE = @("#89B4FA", "#A6E3A1", "#F5C2E7", "#FAB387", "#CBA6F7", "#94E2D5")

function Get-AccentFor([string]$name) {
    # 套餐名哈希 -> 调色板颜色（增删 profile 不串色）
    $sum = 0
    foreach ($ch in $name.ToCharArray()) { $sum += [int]$ch }
    return $script:PALETTE[$sum % $script:PALETTE.Count]
}

$script:brushCache = @{}
function Get-Brush([string]$hex) {
    # 颜色字符串转 SolidColorBrush（带缓存）
    if (-not $script:brushCache.ContainsKey($hex)) {
        $color = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
        $script:brushCache[$hex] = (New-Object System.Windows.Media.SolidColorBrush($color))
    }
    return $script:brushCache[$hex]
}

function Get-PctColor([double]$pct) {
    # 按已用百分比取警示色
    if ($pct -ge 85) { return $script:COLOR_RED }
    if ($pct -ge 60) { return $script:COLOR_YELLOW }
    return $script:COLOR_GREEN
}

function Format-Reset([string]$ts) {
    # "2026-09-20 19:12" -> "09-20 19:12"（去掉年份节省宽度）
    if (-not $ts -or $ts -eq "未知") { return "未知" }
    return ($ts -replace '^\d{4}-', '')
}

# ---- 后台查询脚本（在独立 Runspace 里执行，避免卡 UI）----
$script:queryScript = {
    param($sync, $wslArgs, [int]$timeoutMs)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "wsl.exe"
        $psi.Arguments = $wslArgs
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        if (-not $p.WaitForExit($timeoutMs)) {
            try { $p.Kill() } catch {}
            throw "查询超时（WSL 冷启动或网络异常）"
        }
        if (-not $out.Trim()) {
            throw ("WSL 调用失败: " + $err.Trim())
        }
        if ($out.TrimStart() -notmatch '^\{') {
            # wsl.exe 自身报错（找不到发行版、升级卡住等）会把 UTF-16LE 错误文本写进
            # stdout；此时不让 JSON 解析器报"无效的基元"，直接透出输出开头便于定位
            $head = $out.Trim() -replace '[\r\n]+', ' '
            if ($head.Length -gt 120) { $head = $head.Substring(0, 120) }
            throw ("wsl.exe 输出非 JSON（wsl 层错误）: " + $head)
        }
        $sync.Data = $out | ConvertFrom-Json
    } catch {
        $sync.Error = $_.Exception.Message
    } finally {
        $sync.Done = $true
    }
}

$script:sync = [hashtable]::Synchronized(@{ Done = $false; Data = $null; Error = "" })

# ---- UI 构建 ----
function Add-ProfileBlock($prof) {
    # 向内容面板追加一个 profile 卡片（彩色描边 + 左色条 + 圆点标题 + 各限额维度行）
    $accent = Get-AccentFor $prof.name
    $tint = "#0F" + $accent.Substring(1)     # 卡片底色：身份色 6% 透明度
    $edge = "#5C" + $accent.Substring(1)     # 卡片描边：身份色 36% 透明度

    $card = New-Object System.Windows.Controls.Border
    $card.CornerRadius = "8"
    $card.BorderBrush = Get-Brush $edge
    $card.BorderThickness = "3,1,1,1"        # 左侧粗色条 + 细描边
    $card.Background = Get-Brush $tint
    $card.Margin = "0,8,0,0"
    $card.Padding = "10,8,10,8"

    $sp = New-Object System.Windows.Controls.StackPanel
    $card.Child = $sp

    $hdr = New-Object System.Windows.Controls.TextBlock
    $rDot = New-Object System.Windows.Documents.Run("● ")
    $rDot.FontSize = 10; $rDot.Foreground = Get-Brush $accent
    $r1 = New-Object System.Windows.Documents.Run($prof.name)
    $r1.FontWeight = "Bold"; $r1.FontSize = 12; $r1.Foreground = Get-Brush $script:COLOR_TEXT
    $r2 = New-Object System.Windows.Documents.Run("  〔" + $prof.level + "〕")
    $r2.FontSize = 11; $r2.Foreground = Get-Brush $accent
    [void]$hdr.Inlines.Add($rDot); [void]$hdr.Inlines.Add($r1); [void]$hdr.Inlines.Add($r2)
    $sp.Children.Add($hdr) | Out-Null

    if (-not $prof.ok) {
        # 该 profile 查询失败：红字显示原因，不中断其他分块
        $errText = New-Object System.Windows.Controls.TextBlock
        $errText.Text = "✗ " + $prof.error
        $errText.Foreground = Get-Brush $script:COLOR_RED
        $errText.FontSize = 11
        $errText.TextWrapping = "Wrap"
        $errText.Margin = "0,2,0,0"
        $sp.Children.Add($errText) | Out-Null
        $script:contentPanel.Children.Add($card) | Out-Null
        return
    }

    foreach ($row in @($prof.rows)) {
        $pct = 0.0
        if ($row.pct) { $pct = [double]$row.pct }

        # 第一行：维度名 + 进度条 + 百分比
        $grid = New-Object System.Windows.Controls.Grid
        $grid.Margin = "0,4,0,0"
        $c1 = New-Object System.Windows.Controls.ColumnDefinition
        $c1.Width = New-Object System.Windows.GridLength(92)
        $c2 = New-Object System.Windows.Controls.ColumnDefinition
        $c2.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $c3 = New-Object System.Windows.Controls.ColumnDefinition
        $c3.Width = New-Object System.Windows.GridLength(40)
        [void]$grid.ColumnDefinitions.Add($c1)
        [void]$grid.ColumnDefinitions.Add($c2)
        [void]$grid.ColumnDefinitions.Add($c3)

        $nameText = New-Object System.Windows.Controls.TextBlock
        $nameText.Text = $row.name
        $nameText.FontSize = 11; $nameText.Foreground = Get-Brush $script:COLOR_NAME
        $nameText.VerticalAlignment = "Center"
        $nameText.TextTrimming = "CharacterEllipsis"
        [System.Windows.Controls.Grid]::SetColumn($nameText, 0)
        $grid.Children.Add($nameText) | Out-Null

        $bar = New-Object System.Windows.Controls.ProgressBar
        $bar.Minimum = 0; $bar.Maximum = 100; $bar.Value = $pct
        $bar.Height = 6; $bar.Margin = "0,0,6,0"
        $bar.VerticalAlignment = "Center"
        $bar.Foreground = Get-Brush (Get-PctColor $pct)
        $bar.Background = Get-Brush "#26FFFFFF"
        $bar.BorderThickness = "0"
        [System.Windows.Controls.Grid]::SetColumn($bar, 1)
        $grid.Children.Add($bar) | Out-Null

        $pctText = New-Object System.Windows.Controls.TextBlock
        $pctText.Text = ("{0}%" -f [int]$pct)
        $pctText.FontSize = 11
        $pctText.Foreground = Get-Brush (Get-PctColor $pct)
        $pctText.HorizontalAlignment = "Right"
        $pctText.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($pctText, 2)
        $grid.Children.Add($pctText) | Out-Null
        $sp.Children.Add($grid) | Out-Null

        # 第二行：剩余/总量 + 重置时间（小字暗色）
        $sub = New-Object System.Windows.Controls.TextBlock
        $sub.Text = $row.extra + " · 重置 " + (Format-Reset $row.reset)
        $sub.FontSize = 10.5; $sub.Foreground = Get-Brush $script:COLOR_DIM
        $sub.Margin = "0,1,0,0"; $sub.TextWrapping = "Wrap"
        $sp.Children.Add($sub) | Out-Null

        # 第三行（可选）：分模型明细
        if ($row.details) {
            $det = New-Object System.Windows.Controls.TextBlock
            $det.Text = "· " + $row.details
            $det.FontSize = 10; $det.Foreground = Get-Brush "#6C7086"
            $det.Margin = "0,1,0,0"; $det.TextWrapping = "Wrap"
            $sp.Children.Add($det) | Out-Null
        }
    }
    $script:contentPanel.Children.Add($card) | Out-Null
}

function Update-Content($data) {
    # 用查询结果重建内容面板
    $script:contentPanel.Children.Clear()
    foreach ($prof in @($data.results)) { Add-ProfileBlock $prof }
}

function Set-Status([string]$text, [string]$color) {
    # 纯文本状态（启动中/查询中/查询失败）：清空摘要 chip 后放单个 TextBlock
    $script:statusHost.Children.Clear()
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.FontSize = 10.5
    $tb.Foreground = Get-Brush $color
    $tb.VerticalAlignment = "Center"
    $script:statusHost.Children.Add($tb) | Out-Null
    $script:statusHost.ToolTip = $null
}

function Get-ShortLabel([string]$name) {
    # 状态栏简写："01-wanghao-glm-flash-bigmodel" -> "01-w"（序号 + 紧随其后的首字母）
    if ($name -match '^(\d{1,2})[-_ ]*([A-Za-z])') { return ($Matches[1] + "-" + $Matches[2]) }
    return $name
}

function New-QuotaChip([string]$accent) {
    # 单个订阅的状态 chip：身份色圆角药丸（底色 25% / 描边 40% 透明度），内容上下两行
    $chip = New-Object System.Windows.Controls.Border
    $chip.CornerRadius = "8"
    $chip.Background = Get-Brush ("#3D" + $accent.Substring(1))
    $chip.BorderBrush = Get-Brush ("#66" + $accent.Substring(1))
    $chip.BorderThickness = "1"
    $chip.Padding = "6,2,6,2"
    $sp = New-Object System.Windows.Controls.StackPanel
    $top = New-Object System.Windows.Controls.TextBlock      # 上行：简写
    $top.FontSize = 10
    $top.HorizontalAlignment = "Center"
    $bot = New-Object System.Windows.Controls.TextBlock      # 下行：百分比
    $bot.FontSize = 10.5
    $bot.HorizontalAlignment = "Center"
    $sp.Children.Add($top) | Out-Null
    $sp.Children.Add($bot) | Out-Null
    $chip.Child = $sp
    return $chip
}

function Set-QuotaStatus($data) {
    # 状态栏摘要：每个订阅一枚身份色 chip，上下两行——上行简写 / 下行 N 小时窗口已用%
    # chip 底色/描边与展开卡片同色系（按订阅名哈希，增删 profile 不串色）；
    # 简写统一蓝色（COLOR_ACCENT）、百分比按已用阈值绿/黄/红着色；无该维度收起下行；失败下行标 ✗；
    # 更新时间/剩余/重置点放悬停 ToolTip（整体 + 单 chip 各一份）
    $all = @($data.results)
    $okN = @($all | Where-Object { $_.ok }).Count
    $tip = @("更新于 " + $data.queried_at + " · " + $okN + "/" + $all.Count)

    $script:statusHost.Children.Clear()
    $first = $true
    foreach ($res in $all) {
        $label = Get-ShortLabel $res.name
        $accent = Get-AccentFor $res.name
        $chip = New-QuotaChip $accent
        if (-not $first) { $chip.Margin = "5,0,0,0" }
        $first = $false
        $lines = $chip.Child.Children

        $lines[0].Text = $label
        $lines[0].Foreground = Get-Brush $script:COLOR_ACCENT

        $win = @($res.rows) | Where-Object { $_.name -match '小时窗口' } | Select-Object -First 1
        if (-not $res.ok) {
            $lines[1].Text = "✗"
            $lines[1].Foreground = Get-Brush $script:COLOR_RED
            $line = ($label + " 查询失败: " + $res.error)
        } elseif ($win) {
            $pct = 0.0
            if ($win.pct) { $pct = [double]$win.pct }
            $lines[1].Text = ("{0}%" -f [int]$pct)
            $lines[1].Foreground = Get-Brush (Get-PctColor $pct)
            $line = ($label + " " + $win.name + " 已用 " + [int]$pct + "% · " + $win.extra + " · 重置 " + (Format-Reset $win.reset))
        } else {
            $lines[1].Visibility = "Collapsed"
            $line = ($label + "（" + $res.level + "）无小时窗口维度")
        }
        $chip.ToolTip = $line
        $tip += $line
        $script:statusHost.Children.Add($chip) | Out-Null
    }
    $script:statusHost.ToolTip = ($tip -join "`n")
}

$script:collapsed = $false
$script:restoredCollapsed = $false

function Set-Collapsed([bool]$on) {
    # 折叠/展开：折叠时只留标题药丸；状态随改随存
    $script:collapsed = $on
    $script:contentPanel.Visibility = if ($on) { "Collapsed" } else { "Visible" }
    # SizeToContent 偶发不再重估（窗口冻结在旧高度，2026-10-28 实证）：
    # 重装一遍 Manual→Height 强制重新量高
    $win.SizeToContent = "Manual"
    $win.SizeToContent = "Height"
    # 高度变化后重贴角（推迟到布局完成后；不依赖 SizeChanged——该场景偶发不触发，底边会悬空）
    Request-Redock
    Save-Pos
}

# ---- XAML 界面骨架（事件在下方代码里绑定，不写进 XAML）----
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="glmu-widget" Width="330" SizeToContent="Height"
        WindowStyle="None" Background="#F0202028"
        Topmost="True" ShowInTaskbar="False"
        FontFamily="Microsoft YaHei UI" FontSize="12">
  <Border BorderBrush="#3DFFFFFF"
          BorderThickness="1" Padding="14,10,14,12">
    <StackPanel>
      <Grid x:Name="TitleGrid" Background="Transparent">
        <TextBlock Text="GLM 用量" Foreground="#89B4FA" FontWeight="Bold"
                   FontSize="14" VerticalAlignment="Center"/>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right"
                    VerticalAlignment="Center" Background="Transparent">
          <StackPanel x:Name="StatusHost" Orientation="Horizontal" Margin="0,0,8,0">
            <TextBlock Text="启动中…" Foreground="#9399B2" FontSize="10.5"
                       VerticalAlignment="Center"/>
          </StackPanel>
          <Button x:Name="BtnClose" Content="×" Width="24" Height="22"
                  Background="Transparent" Foreground="#9399B2"
                  BorderThickness="0" FontSize="14" Cursor="Hand"/>
        </StackPanel>
      </Grid>
      <StackPanel x:Name="ContentPanel" MinHeight="70"/>
    </StackPanel>
  </Border>
</Window>
'@

$win = [System.Windows.Markup.XamlReader]::Parse($xaml)
$script:contentPanel = $win.FindName("ContentPanel")
$script:statusHost = $win.FindName("StatusHost")
$titleGrid = $win.FindName("TitleGrid")
$btnClose = $win.FindName("BtnClose")

# ---- 位置：优先读记忆文件，否则默认停靠屏幕右上角 ----
$placed = $false
$dockSaved = ""
if (Test-Path $PosFile) {
    try {
        $pos = Get-Content $PosFile -Raw | ConvertFrom-Json
        $win.Left = [double]$pos.x
        $win.Top = [double]$pos.y
        $placed = $true
        if ($pos.collapsed) { $script:restoredCollapsed = $true }
        if ($pos.dock) { $dockSaved = [string]$pos.dock }
    } catch {}
}
if (-not $placed) {
    # 用 WPF 的 DIP 坐标系（SystemParameters）；混用 WinForms Screen 的物理像素
    # 在高 DPI 缩放（如 150%）下会把窗口算到屏幕外
    $wa = [System.Windows.SystemParameters]::WorkArea
    $win.Left = $wa.Right - $win.Width - 16
    $win.Top = $wa.Top + 16
}

# 停靠模式解析：角落停靠暂缓（2026-10-28 老大决定，该功能待修）——
# 强制 None 使全部停靠路径短路，行为等同停靠功能上线前的版本；修复后还原下面注释行即可
# $script:dock = if ($Dock) { $Dock } elseif ($dockSaved) { $dockSaved } else { "None" }
$script:dock = "None"

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class GlmuMon {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint Flags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string Dev; }
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO i);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
}
'@

function Invoke-Redock {
    # 停靠态按当前窗口尺寸重贴角（工作区角落留 8 物理像素边距）。
    # 窗口显示后走物理像素路径：GetWindowRect/GetMonitorInfo/SetWindowPos 同一坐标系，
    # 规避 WPF 每显示器 DPI（副屏缩放非 100% 时）DIP 换算与实际渲染不一致的偏差；
    # 窗口未显示时按记忆位置粗贴（系统 DPI 估算），显示后由 Loaded/SizeChanged 精贴。
    # 多显示器下选"窗口当前所在"那块屏（启动即停靠时窗口停在记忆位置 → 即用户常用屏）
    if ($script:dock -eq "None") { return $false }
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($win)).Handle
    if ($hwnd -eq [IntPtr]::Zero) {
        # 未显示：窗口中心换算物理像素选屏，按 200 DIP 估算高度粗贴（仅求首帧就近）
        try {
            Add-Type -AssemblyName System.Drawing
            $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
            $scale = $g.DpiX / 96.0
            $g.Dispose()
            if ($scale -le 0) { $scale = 1.0 }
            $pt = New-Object GlmuMon+POINT
            $pt.X = [int](($win.Left + $win.Width / 2) * $scale)
            $pt.Y = [int](($win.Top + 100) * $scale)
            $mi = New-Object GlmuMon+MONITORINFO
            $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][GlmuMon+MONITORINFO])
            if (-not [GlmuMon]::GetMonitorInfo([GlmuMon]::MonitorFromPoint($pt, 2), [ref]$mi)) { return $false }
            $x = 0; $y = 0
            $wPx = [int]($win.Width * $scale); $hPx = [int](200 * $scale)
            switch ($script:dock) {
                "BottomLeft"  { $x = $mi.rcWork.L + 8;           $y = $mi.rcWork.B - $hPx - 8 }
                "BottomRight" { $x = $mi.rcWork.R - $wPx - 8;    $y = $mi.rcWork.B - $hPx - 8 }
                "TopLeft"     { $x = $mi.rcWork.L + 8;           $y = $mi.rcWork.T + 8 }
                "TopRight"    { $x = $mi.rcWork.R - $wPx - 8;    $y = $mi.rcWork.T + 8 }
            }
            $win.Left = $x / $scale
            $win.Top = $y / $scale
            return $true
        } catch { return $false }
    }
    $wr = New-Object GlmuMon+RECT
    if (-not [GlmuMon]::GetWindowRect($hwnd, [ref]$wr)) { return $false }
    $mi = New-Object GlmuMon+MONITORINFO
    $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][GlmuMon+MONITORINFO])
    if (-not [GlmuMon]::GetMonitorInfo([GlmuMon]::MonitorFromWindow($hwnd, 2), [ref]$mi)) { return $false }
    $wPx = $wr.R - $wr.L; $hPx = $wr.B - $wr.T
    $x = 0; $y = 0
    switch ($script:dock) {
        "BottomLeft"  { $x = $mi.rcWork.L + 8;          $y = $mi.rcWork.B - $hPx - 8 }
        "BottomRight" { $x = $mi.rcWork.R - $wPx - 8;   $y = $mi.rcWork.B - $hPx - 8 }
        "TopLeft"     { $x = $mi.rcWork.L + 8;          $y = $mi.rcWork.T + 8 }
        "TopRight"    { $x = $mi.rcWork.R - $wPx - 8;   $y = $mi.rcWork.T + 8 }
    }
    # SWP_NOSIZE|SWP_NOZORDER|SWP_NOACTIVATE：只挪位置，不抢焦点（防停靠瞬移打断用户输入）
    [void][GlmuMon]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, 0, 0, 0x0015)
    return $true
}

function Request-Redock {
    # 高度即将变化（内容重建/折叠切换）后请求重贴角：ContextIdle 优先级在本轮布局渲染之后
    # 执行，保证读到最终窗口高度；比依赖 SizeChanged 可靠（后者在该场景偶发不触发）
    $win.Dispatcher.BeginInvoke(
        [action]{ if ($script:dock -and $script:dock -ne "None") { Invoke-Redock } },
        [System.Windows.Threading.DispatcherPriority]::ContextIdle) | Out-Null
}
# 启动先按记忆位置所在屏贴一次（此刻窗口未显示、高度为估算），
# Loaded/SizeChanged 后用精确设备变换再校正
Invoke-Redock | Out-Null

$win.Add_Loaded({ if ($script:dock -ne "None") { Invoke-Redock | Out-Null } })

# 高度变化（首次布局/折叠展开/每轮刷新内容）自动重贴角，保证停靠的底边/顶边钉死不留缝
$win.Add_SizeChanged({ if ($script:dock -ne "None") { Invoke-Redock | Out-Null } })

function Reset-IfOffscreen {
    # 显示器拓扑/缩放变化后窗口可能漂出可见区域：落在虚拟桌面外较多时召回工作区右上角
    # 坐标一律用 WPF SystemParameters（DIP），与 Window.Left/Top 同一坐标系
    $w = $win.Width
    $h = if ($win.ActualHeight -gt 0) { $win.ActualHeight } else { 460 }
    $x = $win.Left; $y = $win.Top
    $vsL = [System.Windows.SystemParameters]::VirtualScreenLeft
    $vsT = [System.Windows.SystemParameters]::VirtualScreenTop
    $vsR = $vsL + [System.Windows.SystemParameters]::VirtualScreenWidth
    $vsB = $vsT + [System.Windows.SystemParameters]::VirtualScreenHeight
    $inside = (($x + $w) -gt ($vsL + 60)) -and ($x -lt ($vsR - 60)) -and (($y + $h) -gt ($vsT + 40)) -and ($y -lt ($vsB - 40))
    if (-not $inside) {
        # 停靠态优先重贴角（等效召回）；自由态才回工作区右上角
        if (Invoke-Redock) { return }
        $wa = [System.Windows.SystemParameters]::WorkArea
        $win.Left = $wa.Right - $win.Width - 16
        $win.Top = $wa.Top + 16
    }
}
Reset-IfOffscreen

# 显示器拓扑变化（插拔/切换主屏）时：停靠态重贴角，自由态召回工作区右上角；
# SystemEvents 回调在非 UI 线程，需 Dispatcher 转发
$script:displayChangedHandler = {
    $win.Dispatcher.Invoke([action]{ if (-not (Invoke-Redock)) { Reset-IfOffscreen } })
}
[Microsoft.Win32.SystemEvents]::add_DisplaySettingsChanged($script:displayChangedHandler)

function Save-Pos {
    # 关闭/退出时记忆窗口位置与折叠状态
    try {
        @{ x = $win.Left; y = $win.Top; collapsed = $script:collapsed; dock = $script:dock } |
            ConvertTo-Json | Set-Content -Path $PosFile -Encoding UTF8
    } catch {}
}

# ---- 查询调度：Runspace 后台执行 + DispatcherTimer 轮询回收 ----
$script:timer = New-Object System.Windows.Threading.DispatcherTimer
$script:timer.Interval = [TimeSpan]::FromMilliseconds(250)

function Start-Query {
    $script:sync.Done = $false; $script:sync.Data = $null; $script:sync.Error = ""
    $script:runspace = [runspacefactory]::CreateRunspace()
    $script:runspace.Open()
    $script:psInst = [powershell]::Create()
    $script:psInst.Runspace = $script:runspace
    [void]$script:psInst.AddScript($script:queryScript)
    [void]$script:psInst.AddArgument($script:sync)
    [void]$script:psInst.AddArgument($WslCommand)
    [void]$script:psInst.AddArgument($QueryTimeoutMs)
    $script:handle = $script:psInst.BeginInvoke()
    $script:timer.Start()
}

$script:timer.Add_Tick({
    if ($script:handle -and $script:handle.IsCompleted) {
        try { $script:psInst.EndInvoke($script:handle) | Out-Null } catch {}
        if ($script:sync.Error) {
            Set-Status ("查询失败: " + $script:sync.Error) $script:COLOR_RED
        } elseif ($script:sync.Data) {
            Update-Content $script:sync.Data
            Set-QuotaStatus $script:sync.Data
            # 内容重建后高度变化，布局完成后重贴角（SizeChanged 在此场景偶发不触发，不单独依赖它）
            Request-Redock
        } else {
            Set-Status "查询失败: 空响应" $script:COLOR_RED
        }
        try { $script:psInst.Dispose(); $script:runspace.Dispose() } catch {}
        $script:handle = $null
        $script:timer.Stop()
    }
})

# ---- 自动刷新：默认每 60 秒静默补一查 ----
# 不闪"查询中…"（状态栏摘要原地更新）；上一轮查询尚未回收则跳过本轮，避免叠查询
if ($AutoRefreshSec -gt 0) {
    $script:autoTimer = New-Object System.Windows.Threading.DispatcherTimer
    $script:autoTimer.Interval = [TimeSpan]::FromSeconds($AutoRefreshSec)
    $script:autoTimer.Add_Tick({ if (-not $script:handle) { Start-Query } })
    $script:autoTimer.Start()
}

# ---- 事件绑定 ----
# 标题栏：按住拖动（位移>3 DIP 判定为拖）；松开未移动视为点击
#   折叠状态点击 = 展开并刷新；展开状态点击 = 手动刷新；停靠状态拖动 = 解除停靠
$script:grabOffset = $null
$script:titleMoved = $false

$titleGrid.Add_MouseLeftButtonDown({
    $script:grabOffset = [System.Windows.Input.Mouse]::GetPosition($titleGrid)
    $script:titleMoved = $false
    $titleGrid.CaptureMouse()
})
$titleGrid.Add_MouseMove({
    if ($script:grabOffset) {
        $rel = [System.Windows.Input.Mouse]::GetPosition($titleGrid)
        $dx = $rel.X - $script:grabOffset.X
        $dy = $rel.Y - $script:grabOffset.Y
        if (([Math]::Abs($dx) + [Math]::Abs($dy)) -gt 3) { $script:titleMoved = $true }
        if ($script:titleMoved) {
            # 停靠态下拖动即解除停靠（窗口跟手走，停靠选择随之解除记忆）
            if ($script:dock -ne "None") { $script:dock = "None" }
            $win.Left += $dx
            $win.Top += $dy
        }
    }
})
$titleGrid.Add_MouseLeftButtonUp({
    if ($script:grabOffset -and -not $script:titleMoved) {
        if ($script:collapsed) { Set-Collapsed $false }
        Set-Status "查询中…" $script:COLOR_YELLOW
        Start-Query
    }
    $script:grabOffset = $null
    $titleGrid.ReleaseMouseCapture()
})

# 内容区点击：收起
$script:contentPanel.Add_MouseLeftButtonDown({
    if (-not $script:collapsed) { Set-Collapsed $true }
})

$btnClose.Add_Click({ Save-Pos; $win.Close() })
$win.Add_KeyDown({
    if ($_.Key -eq [System.Windows.Input.Key]::Escape) { Save-Pos; $win.Close() }
})
$win.Add_Closed({ try { $script:mutex.ReleaseMutex() } catch {} })

# ---- 启动：显示窗口并立即执行首次查询 ----
if ($script:restoredCollapsed) { Set-Collapsed $true }
Start-Query
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnMainWindowClose
[void]$app.Run($win)
