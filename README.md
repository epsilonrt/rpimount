# rpimount

A small Windows GUI (PowerShell + WinForms, one script plus language files in `lang/`) to inspect and modify the ext4 rootfs partition of a Raspberry Pi SD card, through WSL2 and usbipd-win.

## Requirements

- Windows 11 with WSL2 and a Debian-based distribution (selectable from the **WSL distribution** menu).
- [usbipd-win](https://github.com/dorssel/usbipd-win) installed.
- A USB card reader. `wsl --mount` does not work with a reader declared as removable, hence the detour through usbipd.

## Installer

A per-user Windows installer (`rpimount-setup-<version>.exe`, built with Inno Setup 6) is attached to each GitHub release. It does not need administrator rights to install. It shows the license, offers a desktop icon, creates a Start menu entry, and **checks the prerequisites before installing**: WSL, usbipd-win and at least one WSL2 distribution. If one is missing, a window lists what to do (commands you can copy) and blocks the installation until you click "Check again" and everything is available. The checks run in the account that runs the installer; WSL distributions are per user.

Build it yourself with Inno Setup 6 installed:

```powershell
.\installer\build.ps1 -Version 1.0.0
```

Pushing a tag such as `v1.0.0` builds the installer in GitHub Actions and publishes the release (`.github/workflows/release.yml`). The installer is not code-signed, so Windows SmartScreen may show a warning.

## Running

```powershell
powershell -ExecutionPolicy Bypass -File .\rpimount.ps1
```

The script relaunches itself as administrator (UAC prompt). The PowerShell console is hidden when it was created for the script (a console you started the script from yourself is never hidden).

## Usage

1. **Refresh**: lists the USB mass-storage devices seen by `usbipd` (state *Not shared* / *Shared* / *Attached*). The ext4 partitions show up once the card is attached.
2. **Connect**: bind if needed, start WSL, attach, load `usb_storage` and `uas`, mount on `/mnt/<label>`, then open a WSL terminal in that directory.
3. **Connect + chroot**: same as Connect, then prepare and open a root shell in a chroot (see below).
4. **Disconnect**: undo the chroot, `umount -R`, `sync`, `usbipd detach`. If the target is busy, the log lists the offending processes and the card stays attached: close the terminal and try again.
5. **Check (e2fsck)**: attach the card without mounting it, run `e2fsck -f -n` (read-only, nothing is modified) and print the result in the log. If problems are found, a confirmation (default "No") offers to open an interactive repair terminal (`e2fsck -f`, no `-y`: every fix is asked). A mounted partition is refused: Disconnect first. The card stays attached afterwards; wait for the repair to finish before clicking Disconnect, which hands the card back to Windows.

## WSL distribution

The **WSL distribution** menu lists the installed WSL2 distributions (Docker Desktop's internal ones are ignored); the list is read again each time the menu opens. The choice is remembered. On first run, or if the remembered distribution no longer exists, the WSL default distribution is used. Distribution names containing spaces are not supported.

## Chroot

- The rootfs architecture (aarch64, arm) is read from the ELF header of `/usr/bin/bash`.
- If it differs from the host (x86_64), `qemu-user-static` and `binfmt-support` are installed in WSL when missing (apt), and `qemu-<arch>-static` is copied into the rootfs.
- The rootfs `resolv.conf` is moved aside and replaced by the WSL one so that the network works.
- `/proc`, `/sys` and `/dev` (including `/dev/pts`) are mounted.
- The shell starts with `LANG=C.UTF-8` and `LC_ALL=C.UTF-8` to avoid locale warnings.
- If `/root/.bashrc` does not exist in the rootfs, it is copied from the `/root/.bashrc` of the WSL distribution (root has no shell profile by default on Raspberry Pi OS). An existing file is only replaced when the "Overwrite /root/.bashrc in chroot" checkbox is ticked (unticked by default). This copy is **kept** after Disconnect.
- If the "Copy a script to /root in chroot" checkbox is ticked, the chosen file is copied into the rootfs `/root` (CRLF line endings converted to LF, mode 755). A file with the same name is overwritten. This copy is also **kept** after Disconnect.

On Disconnect, everything else is undone in reverse order: bind-mounts, original `resolv.conf`, qemu binary (only if the tool copied it), then the rootfs is unmounted. The state is kept in `/run/rpimount/` on the WSL side. If the chroot preparation fails halfway, it is rolled back automatically.

## Remembered settings

Stored in `%APPDATA%\rpimount\settings.json` and reloaded at each start: the `.bashrc` overwrite checkbox, the script transfer checkbox, the script path, the language and the WSL distribution.

## Language

The **Language** menu offers *Automatic* (Windows display language, English if it is not available) or any language found in `lang/`. Shipped: English (`en.json`, the fallback) and French (`fr.json`).

To add a language: copy `lang/en.json` to `lang/<code>.json` (for example `de.json`), translate the values (not the keys) and set `language.name` (the name shown in the menu). A missing key falls back to English.

## Test script

`test/test-tree.sh` installs `tree` if missing, then prints the permissions, owner and group of a directory (`/home` by default). It is meant to test the script transfer: tick "Copy a script to /root in chroot", pick this file, then run `/root/test-tree.sh` in the chroot.

## License

BSD 3-Clause, see [LICENSE](LICENSE).

## Trademark notice

Raspberry Pi is a trademark of Raspberry Pi Ltd. rpimount is an independent tool, not affiliated with, endorsed or sponsored by Raspberry Pi Ltd; the name is used only to say that the tool works with Raspberry Pi SD cards.
## Limits and precautions

- Only USB disks (`TRAN=usb`) seen by WSL are considered; internal disks (NVMe) are never touched.
- No destructive operation: no `mkfs`, no automatic `fsck` repair.
- Disconnect unmounts all the USB ext4 partitions seen by WSL, not only the one of the selected row.
- The terminal opens with administrator rights (the script is elevated).
- With the console hidden, a fatal script error is shown in a dialog box. If Windows Terminal is the default terminal in Windows 11, the console window may still flash briefly at startup.
- A freshly detached reader may take a moment to show up again: click Refresh.
