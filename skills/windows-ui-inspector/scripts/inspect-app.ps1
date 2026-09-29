[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExecutablePath,
    [string]$OutputDirectory = "",
    [Nullable[int]]$SecondaryControlId,
    [switch]$ConfirmSecondaryOpen,
    [switch]$DeepStrings,
    [int]$WindowTimeoutSeconds = 20,
    [int]$SecondaryTimeoutSeconds = 15,
    [string]$PythonPath = ""
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) { throw "Executable not found: $ExecutablePath" }
$ExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
$exeItem = Get-Item -LiteralPath $ExecutablePath
if (-not $OutputDirectory) { $OutputDirectory = Join-Path (Get-Location) ("outputs\{0}-ui-analysis" -f $exeItem.BaseName) }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$secondaryRequested = $PSBoundParameters.ContainsKey('SecondaryControlId')
if ($secondaryRequested -and -not $ConfirmSecondaryOpen) {
    throw 'Opening a secondary window requires -ConfirmSecondaryOpen after explicit user approval.'
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class WuiNative {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern bool EnumChildWindows(IntPtr parent, EnumProc cb, IntPtr lp);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll")] public static extern IntPtr GetDlgItem(IntPtr parent, int id);
  [DllImport("user32.dll")] public static extern IntPtr GetParent(IntPtr hWnd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder text, int max);
  [DllImport("user32.dll")] public static extern int GetDlgCtrlID(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowEnabled(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
}
'@

function Get-Text([IntPtr]$Handle) { $b=[Text.StringBuilder]::new(4096); [void][WuiNative]::GetWindowText($Handle,$b,$b.Capacity); $b.ToString() }
function Get-Class([IntPtr]$Handle) { $b=[Text.StringBuilder]::new(512); [void][WuiNative]::GetClassName($Handle,$b,$b.Capacity); $b.ToString() }
function Get-Interface([string]$ClassName) {
    switch -Regex ($ClassName) {
        '^Button$' {'BM_CLICK/WM_COMMAND';break}; '^Edit$' {'WM_GETTEXT/WM_SETTEXT';break}
        '^Static$' {'WM_GETTEXT';break}; '^ListBox$' {'LB_GETCOUNT/LB_GETTEXT/LB_GETCURSEL/LB_SETCURSEL';break}
        '^ComboBox$' {'CB_GETCOUNT/CB_GETLBTEXT/CB_GETCURSEL/CB_SETCURSEL';break}
        '^SysTabControl32$' {'TCM_GETCURSEL/TCM_SETCURSEL';break}; '^msctls_progress32$' {'PBM_GETPOS';break}
        default {'inspect-before-use'}
    }
}
function Get-Risk([string]$Text,[string]$ClassName) {
    if($Text -match '(?i)erase|program|flash|burn|write|delete|update|reset|擦除|烧录|写入|删除|更新|恢复'){return 'destructive'}
    if($ClassName -eq 'Button'){return 'interactive'}
    'read-only'
}
function Get-Controls([IntPtr]$Root,[string]$Scope) {
    $items=[Collections.Generic.List[object]]::new()
    $cb=[WuiNative+EnumProc]{ param([IntPtr]$h,[IntPtr]$lp)
        $r=[WuiNative+RECT]::new(); [void][WuiNative]::GetWindowRect($h,[ref]$r)
        $class=Get-Class $h; $text=Get-Text $h; $parentHex=('0x{0:X}' -f ([WuiNative]::GetParent($h)).ToInt64()); $controlId=[WuiNative]::GetDlgCtrlID($h)
        $items.Add([pscustomobject]@{
            window_path="$Scope/$parentHex/$controlId"; hwnd=('0x{0:X}' -f $h.ToInt64()); parent_hwnd=$parentHex
            control_id=$controlId; class_name=$class; text=$text
            enabled=[WuiNative]::IsWindowEnabled($h); visible=[WuiNative]::IsWindowVisible($h)
            x=$r.Left; y=$r.Top; width=$r.Right-$r.Left; height=$r.Bottom-$r.Top
            suggested_interface=Get-Interface $class; risk=Get-Risk $text $class
        }); return $true }
    [void][WuiNative]::EnumChildWindows($Root,$cb,[IntPtr]::Zero); @($items)
}
function Get-TopWindows([int]$TargetPid) {
    $items=[Collections.Generic.List[object]]::new()
    $cb=[WuiNative+EnumProc]{ param([IntPtr]$h,[IntPtr]$lp)
        $pidValue=[uint32]0; [void][WuiNative]::GetWindowThreadProcessId($h,[ref]$pidValue)
        if($pidValue -eq $TargetPid -and [WuiNative]::IsWindowVisible($h)){
            $items.Add([pscustomobject]@{handle=$h;hwnd=('0x{0:X}' -f $h.ToInt64());title=Get-Text $h;class_name=Get-Class $h})
        }; return $true }
    [void][WuiNative]::EnumWindows($cb,[IntPtr]::Zero); @($items)
}
function Get-Uia([IntPtr]$Root) {
    $items=[Collections.Generic.List[object]]::new(); $rootElement=[Windows.Automation.AutomationElement]::FromHandle($Root)
    $walker=[Windows.Automation.TreeWalker]::ControlViewWalker
    function Add-Element([Windows.Automation.AutomationElement]$Element,[int]$Depth,[string]$ParentPath){
        try{
            $c=$Element.Current; $type=$c.ControlType.ProgrammaticName -replace '^ControlType\.',''
            $segment=if($c.AutomationId){$c.AutomationId}elseif($c.Name){$c.Name}else{$type}; $path=if($ParentPath){"$ParentPath/$segment"}else{$segment}
            $patterns=[Collections.Generic.List[string]]::new()
            foreach($e in @(@{n='Invoke';p=[Windows.Automation.InvokePattern]::Pattern},@{n='Value';p=[Windows.Automation.ValuePattern]::Pattern},@{n='Selection';p=[Windows.Automation.SelectionPattern]::Pattern},@{n='SelectionItem';p=[Windows.Automation.SelectionItemPattern]::Pattern},@{n='ExpandCollapse';p=[Windows.Automation.ExpandCollapsePattern]::Pattern},@{n='Toggle';p=[Windows.Automation.TogglePattern]::Pattern})){
                $out=$null;if($Element.TryGetCurrentPattern($e.p,[ref]$out)){$patterns.Add($e.n)}
            }
            $r=$c.BoundingRectangle; $items.Add([pscustomobject]@{depth=$Depth;path=$path;name=$c.Name;control_type=$type;automation_id=$c.AutomationId;class_name=$c.ClassName;enabled=$c.IsEnabled;offscreen=$c.IsOffscreen;x=[int]$r.X;y=[int]$r.Y;width=[int]$r.Width;height=[int]$r.Height;patterns=@($patterns)})
        }catch{return}
        $child=$walker.GetFirstChild($Element);while($null -ne $child){Add-Element $child ($Depth+1) $path;$child=$walker.GetNextSibling($child)}
    }
    Add-Element $rootElement 0 ''; @($items)
}
function Yaml([object]$Value){if($Value -is [bool]){return $Value.ToString().ToLowerInvariant()};if($null -eq $Value){return "''"};"'{0}'" -f ($Value.ToString() -replace "'","''")}

$signature=Get-AuthenticodeSignature -LiteralPath $ExecutablePath; $hash=Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256
$metadata=[pscustomobject]@{executable=$ExecutablePath;size_bytes=$exeItem.Length;file_version=$exeItem.VersionInfo.FileVersion;product_version=$exeItem.VersionInfo.ProductVersion;company=$exeItem.VersionInfo.CompanyName;description=$exeItem.VersionInfo.FileDescription;signature_status=$signature.Status.ToString();sha256=$hash.Hash}
$warnings=[Collections.Generic.List[string]]::new();if($signature.Status -ne 'Valid'){$warnings.Add("Executable signature status: $($signature.Status)")}
$process=$null;$started=$false
try{
    $process=Start-Process -FilePath $ExecutablePath -PassThru;$started=$true;$deadline=(Get-Date).AddSeconds($WindowTimeoutSeconds)
    do{Start-Sleep -Milliseconds 250;$process.Refresh();$main=[IntPtr]$process.MainWindowHandle}while($main -eq [IntPtr]::Zero -and -not $process.HasExited -and (Get-Date)-lt $deadline)
    if($process.HasExited){throw 'Application exited before exposing a main window.'};if($main -eq [IntPtr]::Zero){throw "No main window appeared within $WindowTimeoutSeconds seconds."}
    $mainControls=@(Get-Controls $main "main:$($process.MainWindowTitle)");try{$uia=@(Get-Uia $main)}catch{$uia=@();$warnings.Add("UI Automation scan failed: $($_.Exception.Message)")}
    $candidates=@($mainControls|Where-Object{$_.class_name -eq 'Button' -and $_.control_id -ge 0}|Select-Object control_id,text,class_name,enabled,visible,risk)
    $mainResult=[pscustomobject]@{scanned_at=(Get-Date).ToString('o');metadata=$metadata;process_id=$process.Id;window=[pscustomobject]@{hwnd=('0x{0:X}' -f $main.ToInt64());title=$process.MainWindowTitle;class_name=Get-Class $main};win32_control_count=$mainControls.Count;uia_control_count=$uia.Count;win32_controls=$mainControls;uia_controls=$uia;secondary_candidates=$candidates;warnings=@($warnings)}
    $mainResult|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDirectory 'main-window-controls.json') -Encoding utf8
    $secondaries=[Collections.Generic.List[object]]::new()
    if($secondaryRequested){
        $secondaryId=[int]$SecondaryControlId
        $before=@(Get-TopWindows $process.Id);$opener=[WuiNative]::GetDlgItem($main,$secondaryId)
        if($opener -eq [IntPtr]::Zero){throw "Control ID $secondaryId was not found under the main window."}
        if((Get-Risk (Get-Text $opener) (Get-Class $opener)) -eq 'destructive'){throw 'The requested opener is classified as destructive and will not be activated.'}
        [void][WuiNative]::PostMessage($opener,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero);$new=@();$deadline=(Get-Date).AddSeconds($SecondaryTimeoutSeconds)
        do{Start-Sleep -Milliseconds 250;$after=@(Get-TopWindows $process.Id);$old=@($before|ForEach-Object{$_.handle.ToInt64()});$new=@($after|Where-Object{$_.handle.ToInt64() -notin $old})}while($new.Count -eq 0 -and (Get-Date)-lt $deadline)
        if($new.Count -eq 0){throw "No secondary window appeared within $SecondaryTimeoutSeconds seconds."}
        foreach($w in $new){$controls=@(Get-Controls $w.handle "secondary:$($w.title)");$secondaries.Add([pscustomobject]@{hwnd=$w.hwnd;title=$w.title;class_name=$w.class_name;control_count=$controls.Count;controls=$controls})}
        foreach($w in $new){$cancel=[WuiNative]::GetDlgItem($w.handle,2);if($cancel -ne [IntPtr]::Zero -and [WuiNative]::IsWindowVisible($cancel)){[void][WuiNative]::PostMessage($cancel,0x00F5,[IntPtr]::Zero,[IntPtr]::Zero)}else{[void][WuiNative]::PostMessage($w.handle,0x0010,[IntPtr]::Zero,[IntPtr]::Zero)}}
    }
    @($secondaries)|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDirectory 'secondary-windows.json') -Encoding utf8
    if($DeepStrings){
        if(-not $PythonPath){$cmd=Get-Command python -ErrorAction SilentlyContinue;if($cmd){$PythonPath=$cmd.Source}}
        if(-not $PythonPath){throw 'Deep string extraction requires -PythonPath or python on PATH.'}
        & $PythonPath (Join-Path $PSScriptRoot 'extract_binary_strings.py') $ExecutablePath (Join-Path $OutputDirectory 'binary-string-clues.json');if($LASTEXITCODE -ne 0){throw 'Binary string extraction failed.'}
    }
    $all=@($mainControls)+@($secondaries|ForEach-Object{$_.controls});$lines=[Collections.Generic.List[string]]::new()
    $lines.Add('application:');$lines.Add("  executable: $(Yaml $ExecutablePath)");$lines.Add("  sha256: $(Yaml $metadata.sha256)");$lines.Add("  signature_status: $(Yaml $metadata.signature_status)")
    $lines.Add('locator_policy:');$lines.Add("  preferred: 'window ancestry + control_id + class_name'");$lines.Add("  warning: 'HWND changes per run; IDs may repeat under different parents'");$lines.Add('controls:')
    foreach($c in $all){$lines.Add("  - window_path: $(Yaml $c.window_path)");$lines.Add("    parent_hwnd: $(Yaml $c.parent_hwnd)");$lines.Add("    hwnd: $(Yaml $c.hwnd)");$lines.Add("    control_id: $($c.control_id)");$lines.Add("    class_name: $(Yaml $c.class_name)");$lines.Add("    text: $(Yaml $c.text)");$lines.Add("    visible: $($c.visible.ToString().ToLowerInvariant())");$lines.Add("    enabled: $($c.enabled.ToString().ToLowerInvariant())");$lines.Add("    suggested_interface: $(Yaml $c.suggested_interface)");$lines.Add("    risk: $(Yaml $c.risk)")}
    $lines|Set-Content -LiteralPath (Join-Path $OutputDirectory 'control-map.yaml') -Encoding utf8
    $report=@("# $($exeItem.BaseName) Windows UI analysis",'',"- Executable: ``$ExecutablePath``","- SHA-256: ``$($metadata.sha256)``","- Signature: $($metadata.signature_status)","- Main window: ``$($process.MainWindowTitle)``","- Main Win32 controls: $($mainControls.Count)","- Main UI Automation elements: $($uia.Count)","- Secondary windows scanned: $($secondaries.Count)",'','## Findings','','- Prefer parent/page ancestry, control ID, and class name over coordinates.','- HWND values are run-specific evidence, not stable locators.','- Duplicate IDs must be scoped by parent dialog or active tab page.','- Suggested interfaces require workflow validation.','','## Warnings','')
    if($warnings.Count -eq 0){$report+='- None'}else{$report+=@($warnings|ForEach-Object{"- $_"})};$report+=@('','## Secondary-window candidates','');$report+=@($candidates|ForEach-Object{"- ID $($_.control_id): $($_.text) [$($_.risk)]"})
    $report|Set-Content -LiteralPath (Join-Path $OutputDirectory 'analysis-report.md') -Encoding utf8
    [pscustomobject]@{output_directory=$OutputDirectory;main_win32_controls=$mainControls.Count;main_uia_controls=$uia.Count;secondary_windows=$secondaries.Count;secondary_controls=(@($secondaries|ForEach-Object{$_.controls}).Count);signature_status=$metadata.signature_status;sha256=$metadata.sha256}|ConvertTo-Json
}finally{
    if($started -and $null -ne $process){try{$process.Refresh()}catch{};if(-not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue}}
}
