<#
.SYNOPSIS
  rpimount - inspect the ext4 rootfs of a Raspberry Pi SD card through WSL2 + usbipd-win.
.NOTES
  UI texts live in lang\<code>.json (fallback: en). Settings are kept in %APPDATA%\rpimount\settings.json.
#>

# Self-elevation: relaunch as administrator (with a hidden console) if needed
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Hide the console window, but only when it was created for this process
# (never hide a terminal the user started the script from)
Add-Type -Name Win -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("kernel32.dll")] public static extern uint GetConsoleProcessList(uint[] list, uint count);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string appId);
'@
# Own taskbar identity: the window is not grouped with other PowerShell windows and keeps its icon
[void][Native.Win]::SetCurrentProcessExplicitAppUserModelID('epsilonrt.rpimount')
$consoleWindow = [Native.Win]::GetConsoleWindow()
if ($consoleWindow -ne [IntPtr]::Zero -and [Native.Win]::GetConsoleProcessList((New-Object 'uint32[]' 16), 16) -le 1) {
    [void][Native.Win]::ShowWindow($consoleWindow, 0)
}

# ---- Configuration ----
$script:Distro = 'Debian'
# Device names are localized by Windows, so match both English and French wording
$script:MassStorageRegex = 'mass storage|stockage de masse|\bUAS\b|card reader|lecteur de carte|\bSCSI\b'
$script:DiskTimeoutSec = 20
$script:KeepAlive = $null   # hidden WSL process that keeps the VM running (usbipd needs it)
$script:LangDir = Join-Path $PSScriptRoot 'lang'
$script:SettingsFile = Join-Path $env:APPDATA 'rpimount\settings.json'
$script:Loading = $true     # true while the UI is being built, so that events do not save settings

# ---- Settings ----
function Read-Settings {
    $s = @{ language = 'auto'; overwriteBashrc = $false; transferScript = $false; scriptPath = ''; distro = '' }
    try {
        if (Test-Path -LiteralPath $script:SettingsFile) {
            $o = [IO.File]::ReadAllText($script:SettingsFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $o.$k) { $s[$k] = $o.$k } }
        }
    } catch { }
    $s
}

function Save-Settings {
    if ($script:Loading) { return }
    $s = @{
        language        = $script:Settings.language
        overwriteBashrc = [bool]$script:ChkBashrc.Checked
        transferScript  = [bool]$script:ChkScript.Checked
        scriptPath      = $script:TxtScript.Text
        distro          = $script:Distro
    }
    $script:Settings = $s
    try {
        $dir = Split-Path $script:SettingsFile
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
        [IO.File]::WriteAllText($script:SettingsFile, ($s | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# ---- Translation ----
function Read-LangFile([string]$Code) {
    $path = Join-Path $script:LangDir "$Code.json"
    $h = @{}
    if (Test-Path -LiteralPath $path) {
        $o = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [string]$p.Value }
    }
    $h
}

function Get-Languages {
    $res = @()
    if (Test-Path -LiteralPath $script:LangDir) {
        foreach ($f in Get-ChildItem -LiteralPath $script:LangDir -Filter '*.json') {
            $code = [IO.Path]::GetFileNameWithoutExtension($f.Name)
            $name = (Read-LangFile $code)['language.name']
            $res += [pscustomobject]@{ Code = $code; Name = $(if ($name) { $name } else { $code }) }
        }
    }
    $res
}

# 'auto' follows the Windows display language, falling back to English
function Get-EffectiveLanguage {
    $wanted = $script:Settings.language
    if ($wanted -eq 'auto') { $wanted = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
    if (Test-Path -LiteralPath (Join-Path $script:LangDir "$wanted.json")) { return $wanted }
    'en'
}

function Set-Language {
    $script:StrEn = Read-LangFile 'en'
    $script:StrCur = Read-LangFile (Get-EffectiveLanguage)
}

# Translated, formatted string; falls back to English, then to the key itself
function T {
    param([string]$Key, [Parameter(ValueFromRemainingArguments = $true)][object[]]$A)
    $s = if ($script:StrCur.ContainsKey($Key)) { $script:StrCur[$Key] }
         elseif ($script:StrEn.ContainsKey($Key)) { $script:StrEn[$Key] }
         else { $Key }
    if ($A.Count) { $s -f $A } else { $s }
}

# ---- Logging ----
function Write-Log([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    $script:LogBox.AppendText($line + [Environment]::NewLine)
    [System.Windows.Forms.Application]::DoEvents()
}

# ---- Process helpers ----
# Run a native command, return exit code and merged output (WSL's own UTF-16 noise is cleaned)
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = (($out | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
    [pscustomobject]@{ Code = $code; Out = $text.Trim() }
}

# Run a shell command as root inside the WSL distribution (no double quotes in $Command)
function Invoke-Wsl([string]$Command) {
    Invoke-Native 'wsl.exe' @('-d', $script:Distro, '-u', 'root', '--', 'sh', '-c', $Command)
}

# ---- usbipd helpers ----
function Test-Usbipd {
    [bool](Get-Command usbipd.exe -ErrorAction SilentlyContinue)
}

# Parse `usbipd list` output. Only the "Connected" section is read.
function Get-UsbDevices {
    $r = Invoke-Native 'usbipd.exe' @('list')
    if ($r.Code -ne 0) { throw (T 'err.list_failed' $r.Out) }
    $devices = @()
    $inConnected = $false
    foreach ($l in ($r.Out -split "`n")) {
        if ($l -match '^Connected') { $inConnected = $true; continue }
        if ($l -match '^Persisted') { $inConnected = $false; continue }
        if (-not $inConnected) { continue }
        if ($l -match '^(?<bus>\d+-\d+(?:\.\d+)*)\s+(?<vid>[0-9a-fA-F]{4}:[0-9a-fA-F]{4})\s+(?<name>.+?)\s{2,}(?<state>Not shared|Shared|Attached.*?)\s*$') {
            $devices += [pscustomobject]@{
                BusId = $Matches.bus; VidPid = $Matches.vid
                Name  = $Matches.name.Trim(); State = $Matches.state.Trim()
            }
        }
    }
    $devices
}

# ext4 partitions that belong to USB disks inside WSL (the WSL system disk is never listed)
function Get-WslExt4Partitions {
    $r = Invoke-Wsl 'lsblk -J -o NAME,FSTYPE,SIZE,LABEL,MOUNTPOINT,TRAN'
    if ($r.Code -ne 0 -or -not $r.Out) { return @() }
    try { $data = $r.Out | ConvertFrom-Json } catch { return @() }
    $res = @()
    foreach ($disk in $data.blockdevices) {
        if ($disk.tran -ne 'usb') { continue }
        foreach ($p in @($disk.children)) {
            $fs = $p.fstype; $label = $p.label
            if (-not $fs) {
                # No udev in WSL: lsblk cannot see unmounted filesystems, so probe the device directly
                $b = Invoke-Wsl "blkid -p -s TYPE -s LABEL -o export /dev/$($p.name)"
                if ($b.Out -match '(?m)^TYPE=(.+)$') { $fs = $Matches[1].Trim() }
                if ($b.Out -match '(?m)^LABEL=(.+)$') { $label = $Matches[1].Trim() }
            }
            if ($fs -eq 'ext4') {
                $res += [pscustomobject]@{
                    Disk = $disk.name; Name = $p.name; Size = $p.size
                    Label = $label; MountPoint = $p.mountpoint
                }
            }
        }
    }
    $res
}

# WSL2 distributions usable here (usbipd needs WSL2; Docker Desktop's internal ones are skipped)
function Get-WslDistros {
    $res = @()
    try { $r = Invoke-Native 'wsl.exe' @('-l', '-v') } catch { return $res }
    foreach ($l in ($r.Out -split "`n")) {
        if ($l -match '^\s*(?<def>\*)?\s*(?<name>\S+)\s+.*?(?<ver>\d)\s*$' -and $Matches.ver -eq '2' -and $Matches.name -notmatch '^docker-desktop') {
            $res += [pscustomobject]@{ Name = $Matches.name; Default = [bool]$Matches.def }
        }
    }
    $res
}

# Keep the chosen distribution if it still exists, else the WSL default one, else the first
function Resolve-Distro {
    $list = @(Get-WslDistros)
    if (-not $list.Count) { return }
    if ($list.Name -contains $script:Distro) { return }
    $def = $list | Where-Object { $_.Default } | Select-Object -First 1
    $script:Distro = if ($def) { $def.Name } else { $list[0].Name }
}

# Make sure a WSL VM is running (usbipd attach --wsl requires it)
function Start-WslKeepAlive {
    if ($script:KeepAlive -and -not $script:KeepAlive.HasExited) { return }
    Write-Log (T 'log.wsl_start' $script:Distro)
    $script:KeepAlive = Start-Process wsl.exe -ArgumentList "-d $($script:Distro) -- sleep infinity" -WindowStyle Hidden -PassThru
    for ($i = 0; $i -lt 20; $i++) {
        if ((Invoke-Wsl 'true').Code -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
    throw (T 'err.wsl_start' $script:Distro)
}

# Safe directory name for a mount point
function Get-MountName($Part) {
    $n = if ($Part.Label) { $Part.Label } else { $Part.Name }
    ($n -replace '[^A-Za-z0-9._-]', '_')
}

# Open a terminal running wsl.exe with the given argument string (the distro name must stay unquoted)
function Start-WslWindow([string]$ArgString) {
    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
        Start-Process wt.exe -ArgumentList "wsl.exe $ArgString"
    } else {
        Start-Process wsl.exe -ArgumentList $ArgString
    }
}

function Open-WslTerminal([string]$Path, [switch]$Chroot) {
    $a = "-d $($script:Distro) --cd $Path"
    if ($Chroot) { $a = "-d $($script:Distro) -u root -- chroot $Path /usr/bin/env LANG=C.UTF-8 LC_ALL=C.UTF-8 /bin/bash -l" }
    Start-WslWindow $a
}

# Interactive e2fsck (no -y: every fix is asked); the window stays open until Enter is pressed
function Open-FsckTerminal([string]$Part) {
    $inner = "e2fsck -f /dev/$Part || true && echo && echo Done. Press Enter to close. && read -r _"
    Start-WslWindow "-d $($script:Distro) -u root -- sh -c `"$inner`""
}

# ---- Chroot ----
# State markers live in /run/rpimount (tmpfs) so that Disconnect undoes exactly what Enter-Chroot did
function Get-StateName([string]$MountPoint) { $MountPoint -replace '[^A-Za-z0-9._-]', '_' }

function Invoke-WslChecked([string]$Command, [string]$What) {
    $r = Invoke-Wsl $Command
    if ($r.Code -ne 0) { throw (T 'err.step_failed' $What $r.Out) }
}

# Copy the user-chosen script into the rootfs /root (CRLF converted to LF, made executable)
function Copy-ScriptToRoot([string]$Mp) {
    $src = $script:TxtScript.Text.Trim()
    if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { throw (T 'err.script_missing' $src) }
    $name = [IO.Path]::GetFileName($src)
    $w = Invoke-Native 'wsl.exe' @('-d', $script:Distro, '-u', 'root', '--', 'wslpath', '-a', '-u', ($src -replace '\\', '/'))   # wsl.exe passes arguments through a Linux shell, which eats backslashes
    $wslSrc = ($w.Out -split "`n" | Select-Object -Last 1).Trim()
    if ($w.Code -ne 0 -or -not $wslSrc) { throw (T 'err.step_failed' 'wslpath' $w.Out) }
    if ($name.Contains("'") -or $wslSrc.Contains("'")) { throw (T 'err.script_name' $name) }
    $r = Invoke-Wsl "if [ -d '$Mp/root' ]; then tr -d '\r' < '$wslSrc' > '$Mp/root/$name' && chmod 755 '$Mp/root/$name'; else exit 3; fi"
    if ($r.Code -eq 3) { Write-Log (T 'err.script_no_root'); return }
    if ($r.Code -ne 0) { throw (T 'err.step_failed' 'script copy' $r.Out) }
    Write-Log (T 'log.script_copied' $name)
}

function Enter-Chroot([string]$Mp) {
    $n = Get-StateName $Mp
    $st = "/run/rpimount/$n"
    if ((Invoke-Wsl "[ -e '$st.chroot' ]").Code -eq 0) { Write-Log (T 'log.chroot_ready'); return }

    # Architecture of the rootfs = ELF e_machine of its bash (no extra tool needed)
    $m = (Invoke-Wsl "od -An -tx1 -j18 -N2 '$Mp/usr/bin/bash'").Out.Trim()
    $target = switch -Regex ($m) { '^b7 00' { 'aarch64' } '^28 00' { 'arm' } '^3e 00' { 'x86_64' } default { $null } }
    if (-not $target) { throw (T 'err.arch' $m) }
    $hostArch = (Invoke-Wsl 'uname -m').Out.Trim()
    Write-Log (T 'log.arch' $target $hostArch)

    Invoke-WslChecked 'mkdir -p /run/rpimount' 'mkdir /run/rpimount'

    if ($target -ne $hostArch) {
        $qemu = "qemu-$target-static"
        if ((Invoke-Wsl 'dpkg -s qemu-user-static binfmt-support >/dev/null 2>&1').Code -ne 0) {
            Write-Log (T 'log.qemu_install')
            Invoke-WslChecked 'DEBIAN_FRONTEND=noninteractive apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y qemu-user-static binfmt-support' 'apt install qemu'
        }
        # binfmt_misc may not be mounted in WSL
        [void](Invoke-Wsl '[ -e /proc/sys/fs/binfmt_misc/register ] || mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc')
        [void](Invoke-Wsl "update-binfmts --enable qemu-$target")
        if ((Invoke-Wsl "[ -e /proc/sys/fs/binfmt_misc/qemu-$target ]").Code -ne 0) { throw (T 'err.binfmt' $target) }
        Write-Log (T 'log.qemu_copy' $qemu)
        Invoke-WslChecked "[ -e '$Mp/usr/bin/$qemu' ] || { cp /usr/bin/$qemu '$Mp/usr/bin/$qemu' && echo $qemu > '$st.qemu'; }" 'qemu copy'
    }

    # Temporary resolv.conf: the original is moved aside and put back by Exit-Chroot
    Write-Log (T 'log.resolv')
    # The marker makes this step idempotent: after a failed attempt the temporary file must never be taken for the original
    Invoke-WslChecked "if [ ! -e '$st.resolv' ]; then if [ -e '$Mp/etc/resolv.conf' ] || [ -L '$Mp/etc/resolv.conf' ]; then mv '$Mp/etc/resolv.conf' '$Mp/etc/resolv.conf.rpimount' && echo bak > '$st.resolv'; else echo none > '$st.resolv'; fi; fi; cp -L /etc/resolv.conf '$Mp/etc/resolv.conf'" 'resolv.conf'

    # root has no shell profile on Raspberry Pi OS: seed it from the root account of the WSL distribution.
    # An existing file is only replaced when the checkbox is ticked. The copy is kept after Disconnect.
    $keep = if ($script:ChkBashrc.Checked) { 'false' } else { 'true' }
    $r = Invoke-Wsl "if $keep && [ -e '$Mp/root/.bashrc' ]; then echo exists; elif [ -d '$Mp/root' ] && [ -f /root/.bashrc ]; then cp /root/.bashrc '$Mp/root/.bashrc' && echo copied; else echo skipped; fi"
    switch ($r.Out) {
        'copied'  { Write-Log (T 'log.bashrc_copied') }
        'exists'  { Write-Log (T 'log.bashrc_exists') }
        default   { Write-Log (T 'log.bashrc_skipped' $r.Out) }
    }

    if ($script:ChkScript.Checked) { Copy-ScriptToRoot $Mp }

    Write-Log (T 'log.binds')
    Invoke-WslChecked "mount -t proc proc '$Mp/proc' && mount --rbind /sys '$Mp/sys' && mount --make-rslave '$Mp/sys' && mount --rbind /dev '$Mp/dev' && mount --make-rslave '$Mp/dev'" 'bind-mounts'
    Invoke-WslChecked "touch '$st.chroot'" 'chroot marker'
}

# Undo Enter-Chroot in reverse order; a no-op if the chroot was never prepared
function Exit-Chroot([string]$Mp) {
    $n = Get-StateName $Mp
    $st = "/run/rpimount/$n"
    if ((Invoke-Wsl "ls '$st'.* >/dev/null 2>&1").Code -ne 0) { return }
    Write-Log (T 'log.undo_chroot' $Mp)
    foreach ($sub in 'dev', 'sys', 'proc') {
        $r = Invoke-Wsl "if mountpoint -q '$Mp/$sub'; then umount -R '$Mp/$sub'; fi"
        if ($r.Code -ne 0) {
            $msg = T 'err.umount' "$Mp/$sub"
            if ($r.Out -match 'busy|occup') { $msg += ' ' + (T 'err.busy') }
            throw (T 'err.exit_chroot' $msg $r.Out)
        }
    }
    # rm -f on exact file names only, never recursive
    [void](Invoke-Wsl "if [ -e '$st.resolv' ]; then rm -f '$Mp/etc/resolv.conf'; if [ `"`$(cat '$st.resolv')`" = bak ]; then mv '$Mp/etc/resolv.conf.rpimount' '$Mp/etc/resolv.conf'; fi; fi")
    [void](Invoke-Wsl "if [ -e '$st.qemu' ]; then rm -f '$Mp/usr/bin/'`"`$(cat '$st.qemu')`"; fi")
    [void](Invoke-Wsl "rm -f '$st'.chroot '$st'.qemu '$st'.resolv")
}

# ---- Actions ----
# Bind, start WSL, attach the card and wait for its ext4 partitions; returns them (not mounted by this function)
function Initialize-Card($Dev) {
    if (-not (Test-Usbipd)) { throw (T 'err.usbipd_missing') }
    if ($Dev.State -eq 'Not shared') {
        Write-Log "usbipd bind --busid $($Dev.BusId)"
        $r = Invoke-Native 'usbipd.exe' @('bind', '--busid', $Dev.BusId)
        if ($r.Code -ne 0) { throw (T 'err.bind' $r.Out) }
    }
    Start-WslKeepAlive
    if ($Dev.State -notlike 'Attached*') {
        Write-Log "usbipd attach --wsl --busid $($Dev.BusId)"
        $r = Invoke-Native 'usbipd.exe' @('attach', '--wsl', $script:Distro, '--busid', $Dev.BusId)
        if ($r.Code -ne 0) {
            if ($r.Out -match 'already|déjà|in use|utilis') { throw (T 'err.in_use' $r.Out) }
            throw (T 'err.attach' $r.Out)
        }
    }
    Write-Log 'modprobe usb_storage uas'
    $r = Invoke-Wsl 'modprobe usb_storage; modprobe uas'
    if ($r.Code -ne 0) { Write-Log "modprobe: $($r.Out)" }

    Write-Log (T 'log.wait_disk' $script:DiskTimeoutSec)
    $parts = @()
    $deadline = (Get-Date).AddSeconds($script:DiskTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $parts = @(Get-WslExt4Partitions)
        if ($parts.Count) { break }
        Start-Sleep -Milliseconds 700
        [System.Windows.Forms.Application]::DoEvents()
    }
    if (-not $parts.Count) {
        $r = Invoke-Wsl 'lsblk -o NAME,FSTYPE,SIZE,LABEL,TRAN'
        throw (T 'err.no_ext4' $script:DiskTimeoutSec $r.Out)
    }
    $parts
}

function Invoke-Connect($Dev, [bool]$Chroot = $false) {
    $parts = @(Initialize-Card $Dev)
    $first = $null
    foreach ($p in $parts) {
        if ($p.MountPoint) {
            Write-Log (T 'log.already_mounted' $p.Name $p.MountPoint)
            $mp = $p.MountPoint
        } else {
            $mp = '/mnt/' + (Get-MountName $p)
            Write-Log "mount /dev/$($p.Name) -> $mp"
            $r = Invoke-Wsl "mkdir -p '$mp' && mount /dev/$($p.Name) '$mp'"
            if ($r.Code -ne 0) { throw (T 'err.mount' $r.Out) }
        }
        if (-not $first) { $first = $mp }
    }
    if ($Chroot) {
        try { Enter-Chroot $first }
        catch {
            # Roll back a half-prepared chroot so that nothing is left behind
            try { Exit-Chroot $first } catch { }
            throw
        }
        Write-Log (T 'log.terminal_chroot' $first)
        Open-WslTerminal $first -Chroot
    } else {
        Write-Log (T 'log.terminal' $first)
        Open-WslTerminal $first
    }
}

# On-demand filesystem check: read-only pass first, repair only after an explicit confirmation
function Invoke-Fsck($Dev) {
    $parts = @(Initialize-Card $Dev)
    foreach ($p in $parts) {
        if ($p.MountPoint) { Write-Log (T 'err.fsck_mounted' $p.Name); continue }
        Write-Log "e2fsck -f -n /dev/$($p.Name)"
        $r = Invoke-Wsl "e2fsck -f -n /dev/$($p.Name)"
        foreach ($line in ($r.Out -split "`n" | Select-Object -Last 60)) { Write-Log $line }
        Write-Log (T 'log.fsck_code' $r.Code)
        if ($r.Code -eq 0) { continue }
        $answer = [System.Windows.Forms.MessageBox]::Show((T 'ui.fsck_ask' $p.Name), (T 'ui.fsck_ask_title'), 'YesNo', 'Warning', 'Button2')
        if ($answer -eq 'Yes') {
            Open-FsckTerminal $p.Name
            Write-Log (T 'log.fsck_terminal' $p.Name)
        }
    }
    Write-Log (T 'log.fsck_hint')
}

function Invoke-Disconnect($Dev) {
    $parts = @(Get-WslExt4Partitions | Where-Object { $_.MountPoint })
    foreach ($p in $parts) {
        $mp = $p.MountPoint
        Exit-Chroot $mp
        Write-Log "umount -R $mp"
        $r = Invoke-Wsl "sync; umount -R '$mp'"
        if ($r.Code -ne 0) {
            $busy = Invoke-Wsl "fuser -vm '$mp' 2>&1 | head -n 20"
            $msg = T 'err.umount' $mp
            if ($r.Out -match 'busy|occup') { $msg += ' ' + (T 'err.busy') }
            throw (T 'err.umount_full' $msg $r.Out $busy.Out)
        }
        # rmdir only removes an empty directory, so it is safe on a mount point left behind
        [void](Invoke-Wsl "rmdir '$mp' 2>/dev/null")
    }
    Write-Log "usbipd detach --busid $($Dev.BusId)"
    $r = Invoke-Native 'usbipd.exe' @('detach', '--busid', $Dev.BusId)
    if ($r.Code -ne 0) { throw (T 'err.detach' $r.Out) }
    Write-Log (T 'log.detached')
}

# ---- List refresh ----
function Update-DeviceList {
    $script:List.Items.Clear()
    if (-not (Test-Usbipd)) { Write-Log (T 'log.error' (T 'err.usbipd_missing')); return }
    try { $devs = Get-UsbDevices } catch { Write-Log (T 'log.error' $_.Exception.Message); return }

    $storage = @($devs | Where-Object { $_.Name -match $script:MassStorageRegex })
    Write-Log (T 'log.devices' $devs.Count $storage.Count)

    $ext4 = @()
    if ($storage | Where-Object { $_.State -like 'Attached*' }) { $ext4 = @(Get-WslExt4Partitions) }

    foreach ($d in $storage) {
        $parts = ''
        if ($d.State -like 'Attached*' -and $ext4.Count) {
            $parts = ($ext4 | ForEach-Object {
                $m = if ($_.MountPoint) { " -> $($_.MountPoint)" } else { '' }
                "$($_.Name) ($($_.Size), $($_.Label))$m"
            }) -join ' ; '
        }
        $item = New-Object System.Windows.Forms.ListViewItem($d.BusId)
        [void]$item.SubItems.Add($d.VidPid)
        [void]$item.SubItems.Add($d.Name)
        [void]$item.SubItems.Add($d.State)
        [void]$item.SubItems.Add($parts)
        $item.Tag = $d
        [void]$script:List.Items.Add($item)
    }
    Update-Buttons
}

function Update-Buttons {
    $sel = if ($script:List.SelectedItems.Count) { $script:List.SelectedItems[0].Tag } else { $null }
    $script:Btn['connect'].Enabled = [bool]$sel
    $script:Btn['chroot'].Enabled = [bool]$sel
    $script:Btn['fsck'].Enabled = [bool]$sel
    $script:Btn['disconnect'].Enabled = [bool]($sel -and $sel.State -like 'Attached*')
    $script:TxtScript.Enabled = $script:ChkScript.Checked
    $script:BtnBrowse.Enabled = $script:ChkScript.Checked
}

# Run an action with the UI locked, errors shown in the log
function Invoke-Action([scriptblock]$Action) {
    $sel = if ($script:List.SelectedItems.Count) { $script:List.SelectedItems[0].Tag } else { $null }
    if (-not $sel) { Write-Log (T 'log.select'); return }
    $script:Form.Enabled = $false
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try { & $Action $sel } catch { Write-Log (T 'log.error' $_.Exception.Message) }
    finally {
        $script:Form.Cursor = [System.Windows.Forms.Cursors]::Default
        $script:Form.Enabled = $true
        Update-DeviceList
    }
}

# ---- UI ----
# (Re)apply every translated text of the window
function Update-UiText {
    $script:Btn['refresh'].Text = T 'ui.refresh'
    $script:Btn['connect'].Text = T 'ui.connect'
    $script:Btn['chroot'].Text = T 'ui.connect_chroot'
    $script:Btn['disconnect'].Text = T 'ui.disconnect'
    $script:Btn['fsck'].Text = T 'ui.fsck'
    $script:MenuWsl.Text = T 'ui.menu_wsl'
    $script:ChkBashrc.Text = T 'ui.chk_bashrc'
    $script:ChkScript.Text = T 'ui.chk_script'
    $script:BtnBrowse.Text = T 'ui.browse'
    $script:MenuLang.Text = T 'ui.menu_language'
    $i = 0
    foreach ($k in 'col.bus', 'col.vidpid', 'col.device', 'col.state', 'col.partitions') {
        $script:List.Columns[$i].Text = T $k
        $i++
    }
    Update-LanguageMenu
}

function Update-LanguageMenu {
    $script:MenuLang.DropDownItems.Clear()
    $auto = New-Object System.Windows.Forms.ToolStripMenuItem((T 'ui.lang_auto'))
    $auto.Tag = 'auto'; $auto.Checked = ($script:Settings.language -eq 'auto')
    $auto.Add_Click({ Select-Language $this.Tag })
    [void]$script:MenuLang.DropDownItems.Add($auto)
    [void]$script:MenuLang.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    foreach ($l in Get-Languages) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($l.Name)
        $mi.Tag = $l.Code; $mi.Checked = ($script:Settings.language -eq $l.Code)
        $mi.Add_Click({ Select-Language $this.Tag })
        [void]$script:MenuLang.DropDownItems.Add($mi)
    }
}

# The distribution list is rebuilt each time the menu opens, so it is always current
function Update-WslMenu {
    $script:MenuWsl.DropDownItems.Clear()
    $list = @(Get-WslDistros)
    if (-not $list.Count) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem((T 'ui.wsl_none'))
        $none.Enabled = $false
        [void]$script:MenuWsl.DropDownItems.Add($none)
        return
    }
    foreach ($d in $list) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($d.Name)
        $mi.Tag = $d.Name; $mi.Checked = ($d.Name -eq $script:Distro)
        $mi.Add_Click({ Select-Distro $this.Tag })
        [void]$script:MenuWsl.DropDownItems.Add($mi)
    }
}

function Select-Distro([string]$Name) {
    if ($Name -eq $script:Distro) { return }
    # The keep-alive process belongs to the previous distribution
    if ($script:KeepAlive -and -not $script:KeepAlive.HasExited) { $script:KeepAlive.Kill() }
    $script:KeepAlive = $null
    $script:Distro = $Name
    Save-Settings
    Write-Log (T 'log.distro' $Name)
    Update-DeviceList
}

function Select-Language([string]$Code) {
    $script:Settings.language = $Code
    Save-Settings
    Set-Language
    Update-UiText
    Update-DeviceList
}

$script:Settings = Read-Settings
if ($script:Settings.distro) { $script:Distro = [string]$script:Settings.distro }
Resolve-Distro
Set-Language

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'rpimount'
$script:Form.ClientSize = New-Object System.Drawing.Size(850, 580)
$script:Form.StartPosition = 'CenterScreen'
$iconFile = Join-Path $PSScriptRoot 'assets\rpimount.ico'
if (Test-Path -LiteralPath $iconFile) { $script:Form.Icon = New-Object System.Drawing.Icon($iconFile) }

$menu = New-Object System.Windows.Forms.MenuStrip
$script:MenuWsl = New-Object System.Windows.Forms.ToolStripMenuItem
$script:MenuLang = New-Object System.Windows.Forms.ToolStripMenuItem
[void]$menu.Items.Add($script:MenuWsl)
[void]$menu.Items.Add($script:MenuLang)
$script:MenuWsl.Add_DropDownOpening({ Update-WslMenu })
[void]$script:MenuWsl.DropDownItems.Add('...')   # placeholder so that the drop-down can open
$script:Form.MainMenuStrip = $menu
$script:Form.Controls.Add($menu)

$script:List = New-Object System.Windows.Forms.ListView
$script:List.View = 'Details'; $script:List.FullRowSelect = $true; $script:List.MultiSelect = $false
$script:List.Location = '10,36'; $script:List.Size = '830,170'; $script:List.Anchor = 'Top,Left,Right'
foreach ($w in 50, 80, 260, 90, 320) { [void]$script:List.Columns.Add('', $w) }

$script:Btn = @{}
foreach ($b in @(@('refresh', 10, 100), @('connect', 120, 100), @('chroot', 230, 130), @('disconnect', 370, 100), @('fsck', 480, 150))) {
    $x = New-Object System.Windows.Forms.Button
    $x.Location = New-Object System.Drawing.Point($b[1], 214)
    $x.Size = New-Object System.Drawing.Size($b[2], 30)
    $script:Form.Controls.Add($x); $script:Btn[$b[0]] = $x
}

$script:ChkBashrc = New-Object System.Windows.Forms.CheckBox
$script:ChkBashrc.Location = '10,254'; $script:ChkBashrc.Size = '600,22'
$script:ChkScript = New-Object System.Windows.Forms.CheckBox
$script:ChkScript.Location = '10,282'; $script:ChkScript.Size = '260,22'
$script:TxtScript = New-Object System.Windows.Forms.TextBox
$script:TxtScript.Location = '275,281'; $script:TxtScript.Size = '450,24'; $script:TxtScript.Anchor = 'Top,Left,Right'
$script:BtnBrowse = New-Object System.Windows.Forms.Button
$script:BtnBrowse.Location = '735,279'; $script:BtnBrowse.Size = '105,28'; $script:BtnBrowse.Anchor = 'Top,Right'

$script:LogBox = New-Object System.Windows.Forms.TextBox
$script:LogBox.Multiline = $true; $script:LogBox.ReadOnly = $true; $script:LogBox.ScrollBars = 'Vertical'
$script:LogBox.Location = '10,316'; $script:LogBox.Size = '830,254'; $script:LogBox.Anchor = 'Top,Bottom,Left,Right'
$script:LogBox.Font = New-Object System.Drawing.Font('Consolas', 9)

$script:Form.Controls.AddRange(@($script:List, $script:ChkBashrc, $script:ChkScript, $script:TxtScript, $script:BtnBrowse, $script:LogBox))

# Restore saved settings, then enable saving
$script:ChkBashrc.Checked = [bool]$script:Settings.overwriteBashrc
$script:ChkScript.Checked = [bool]$script:Settings.transferScript
$script:TxtScript.Text = [string]$script:Settings.scriptPath
Update-UiText
$script:Loading = $false

$script:List.Add_SelectedIndexChanged({ Update-Buttons })
$script:ChkBashrc.Add_CheckedChanged({ Save-Settings })
$script:ChkScript.Add_CheckedChanged({ Save-Settings; Update-Buttons })
$script:TxtScript.Add_TextChanged({ Save-Settings })
$script:BtnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = T 'ui.pick_script'
    $dlg.Filter = T 'ui.filter_scripts'
    if ($script:TxtScript.Text -and (Test-Path -LiteralPath $script:TxtScript.Text)) { $dlg.FileName = $script:TxtScript.Text }
    if ($dlg.ShowDialog() -eq 'OK') { $script:TxtScript.Text = $dlg.FileName }
})
$script:Btn['refresh'].Add_Click({ Update-DeviceList })
$script:Btn['connect'].Add_Click({ Invoke-Action { param($d) Invoke-Connect $d } })
$script:Btn['chroot'].Add_Click({ Invoke-Action { param($d) Invoke-Connect $d $true } })
$script:Btn['disconnect'].Add_Click({ Invoke-Action { param($d) Invoke-Disconnect $d } })
$script:Btn['fsck'].Add_Click({ Invoke-Action { param($d) Invoke-Fsck $d } })
$script:Form.Add_Shown({ Update-DeviceList })
$script:Form.Add_FormClosed({ Save-Settings; if ($script:KeepAlive -and -not $script:KeepAlive.HasExited) { $script:KeepAlive.Kill() } })

# The console is hidden, so a fatal error must be shown in a dialog
try {
    Update-Buttons
    [void]$script:Form.ShowDialog()
} catch {
    [void][System.Windows.Forms.MessageBox]::Show((T 'err.fatal' $_.Exception.Message), 'rpimount')
}
