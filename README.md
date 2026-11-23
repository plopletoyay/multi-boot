# `multi-boot`

A safety-verified, one-shot CLI operating system and Linux kernel reboot switcher designed for UEFI systems.

Official repository:

https://github.com/plopletoyay/multi-boot

`multi-boot` discovers your installed operating systems and Linux kernels across UEFI NVRAM, `systemd-boot`, GRUB2, rEFInd, Limine, and Windows multi-OS BCD stores, inspects their actual EFI binaries, kernel headers, OS partitions, and registry hives to determine exact versions, editions, and flavors, verifies every partition, bootloader image, and `initramfs` file before touching firmware state, and configures a single-use (`BootNext` / `LoaderEntryOneShot` / `grub-reboot` / `PreviousBoot`) reboot target without altering your permanent `BootOrder`.

> <sub>Support for other distributions and other bootloaders has not been officially tested. Please use with caution, and if any bugs occur on other distributions or bootloaders, please submit feedback on this GitHub repository.</sub>
>
> <sub>Most stable configuration: Arch Linux distro paired with EFISTUB.</sub>

# `One-Shot UEFI & systemd-boot OS / Kernel Switcher`

> **This project is not a bootloader replacement.**
>
> It is a pre-boot verification and NVRAM one-shot orchestration layer that lets you reboot directly into Windows (including isolated multi-Windows BCD entries), macOS, or a specific Linux distribution and kernel flavor from your terminal with a single command.

---

# Table of Contents

- [Important Compatibility Notice & Warnings](#important-compatibility-notice--warnings)
- [What This Project Is (and Is Not)](#what-this-project-is-and-is-not)
- [Complete Capabilities & Feature Breakdown](#complete-capabilities--feature-breakdown)
  - [1. Core Switcher (`boot`)](#1-core-switcher-boot)
  - [2. Smart Installer & Security Provisioner (`install.sh`)](#2-smart-installer--security-provisioner-installsh)
- [Technical Architecture](#technical-architecture)
- [Deep-Dive Workflow: How It Works Internally](#deep-dive-workflow-how-it-works-internally)
  - [Phase 1 — Target Discovery & Deduplication](#phase-1--target-discovery--deduplication)
  - [Phase 2 — Binary Metadata & Version Extraction](#phase-2--binary-metadata--version-extraction)
  - [Phase 3 — Query Normalization & Exact-Match Resolution](#phase-3--query-normalization--exact-match-resolution)
  - [Phase 4 — Multi-Stage Pre-Flight Safety Verification](#phase-4--multi-stage-pre-flight-safety-verification)
  - [Phase 5 — One-Shot NVRAM Programming & Reboot Execution](#phase-5--one-shot-nvram-programming--reboot-execution)
- [Installation & Lifecycle Management](#installation--lifecycle-management)
- [Usage Guide & Real-World Examples](#usage-guide--real-world-examples)
- [Troubleshooting & Installer Rejection Guide](#troubleshooting--installer-rejection-guide)
- [Security Model & Privilege Boundaries](#security-model--privilege-boundaries)
- [Project Structure](#project-structure)
- [Design Philosophy](#design-philosophy)
- [License & Author](#license--author)

---

# Important Compatibility Notice & Warnings

## Primary Platform: Arch Linux with Direct EFISTUB

`multi-boot` is engineered, calibrated, and verified primarily for **Arch Linux systems booting via Direct EFISTUB** (where the UEFI firmware loads the Linux kernel's built-in EFI stub directly from the EFI System Partition via an NVRAM boot entry).

## Cross-Distro & Multi-Bootloader Status (Experimental / Untested)

While `install.sh` includes package manager detection across 13 Linux package managers (`pacman`, `apt-get`, `dnf`, `rpm-ostree`, `zypper`, `xbps-install`, `apk`, `yum`, `emerge`, `nix-env`, `eopkg`, `swupd`, and `slackpkg`), **`multi-boot` requires the host system to be booted via Direct EFISTUB during installation**, while `boot` itself can discover and chainload secondary entries across UEFI NVRAM, `systemd-boot`, GRUB2, rEFInd, Limine, and Windows BCD.

> **Important Note on Other Distributions & Bootloaders:**
>
> Cross-distribution and non-EFISTUB bootloader support is **experimental and has NOT been officially tested**. Most mainstream distributions default to GRUB, `shim`, or `systemd-boot` as their primary boot path rather than Direct EFISTUB, which `install.sh` will intentionally reject during its pre-installation gatekeeper checks. Use on non-Arch distributions or secondary bootloaders at your own discretion.

## Critical Operational Warnings

Even though `multi-boot` enforces strict pre-flight checks before triggering a reboot, it directly interacts with **UEFI NVRAM variables**, **EFI System Partition files**, and **system power state**:

- **UEFI Mode Required:** Legacy BIOS / CSM installations are completely unsupported. `/sys/firmware/efi` must be mounted and writable.
- **NVRAM & Bootloader State Writes:** Setting a one-shot boot target writes to the UEFI `BootNext` variable via `efibootmgr` (alongside `LoaderEntryOneShot` via `bootctl` for `systemd-boot`, `grub-reboot` for GRUB2, or `PreviousBoot` efivar for rEFInd). Although `BootNext` is automatically cleared by compliant UEFI firmware on the next boot, buggy motherboard firmware implementations can occasionally behave unexpectedly.
- **Windows BCD Splitting (`boot -s`):** When multiple Windows installations share a single Windows Boot Manager (`bootmgfw.efi`), `boot` can create isolated per-OS boot directories (`/EFI/multiboot-win-<id>/`) on the ESP containing a single-target patched `BCD` hive and register dedicated UEFI NVRAM entries. Use `boot -u` (or uninstall) to clean them up at any time.
- **Force Mode (`boot -f`) Destroys Unsaved Work:** Passing `-f` / `--force` skips confirmation prompts, sends `SIGTERM` followed by `SIGKILL` to open user desktop processes (while sparing your active terminal session, shell, `systemd`, `dbus`, and `sshd`), and executes `systemctl reboot --force --no-block` (`reboot -f`). Always save your work before using `-f`.
- **Direct ESP Block Reads:** When your EFI System Partition (ESP) is not mounted, `multi-boot` uses `mtools` (`mcopy`/`mdir`) through a restricted root helper (`/usr/local/libexec/multiboot-efi-read`) to inspect EFI binaries, Windows BCD hives, and `initramfs` images directly on the FAT32 partition.

---

# What This Project Is (and Is Not)

`multi-boot` bridges the gap between Linux CLI workflows and firmware-level multi-boot selection:

| Role | Description |
| :--- | :--- |
| **`One-Shot NVRAM & Loader Orchestrator`** | Sets UEFI `BootNext` (plus `systemd-boot` `LoaderEntryOneShot`, `grub-reboot`, rEFInd `PreviousBoot`, or isolated Windows BCD entries) for a single reboot without touching permanent `BootOrder`. |
| **`Pre-Reboot Safety Validator`** | Verifies NVRAM active flags, GPT `PARTUUID`, filesystem types, EFI images, `initramfs` paths, root devices, and `sudo` readiness before rebooting. |
| **`Binary & Partition Metadata Inspector`** | Parses PE/COFF headers, Linux kernel `HdrS` / `zboot` / UKI `.linux` & `.osrel` sections, Windows `ProductVersion` + NTFS `SOFTWARE` registry hives, and macOS `SystemVersion.plist` / OpenCore / Clover metadata. |
| **`Ambiguity & Duplicate Guard`** | Uses strict exact-match precedence, partition-label disambiguation for duplicate OS entries, and `difflib` fuzzy suggestions so `boot linux` never silently guesses. |
| **`Password-Authenticated & Manifest-Tracked`** | Enforces interactive password authentication (`sudo -v` with `sudo -k` cleanup—never `NOPASSWD`) and tracks all system and user shell artifacts for clean removal. |

### What `multi-boot` Is NOT

- It is **not** a bootloader (it does not replace EFISTUB, `systemd-boot`, GRUB2, rEFInd, or Limine).
- It does **not** rewrite your permanent UEFI `BootOrder`. After booting into your chosen OS/kernel once, the next subsequent reboot returns to your default firmware boot priority.
- It does **not** modify partition tables, kernel images, or `/loader/entries/*.conf` files.

---

# Complete Capabilities & Feature Breakdown

## 1. Core Switcher (`boot`)

### Configurable Target Cap & Multi-Backend Inventory (`MAX_TARGETS=64`)
- Scans and indexes up to **64 boot targets total** by default (overridable via `BOOT_MAX_TARGETS`) across **6 boot backends**:
  - `uefi` (`BootXXXX | UEFI` / `UEFI-WinDirect`) — Direct UEFI NVRAM entries via `efibootmgr`
  - `winbcd` (`bcd-<id> | WinBCD-Split`) — Individual OS entries extracted from a merged Windows `BCD` store
  - `sdboot` (`<id> | sd-boot`) — `systemd-boot` entries (`/loader/entries/*.conf` + drop-ins, `/EFI/Linux/*.efi`/`.uki`, `bootctl list`)
  - `grub` (`<id> | GRUB2`) — GRUB2 menu entries (including nested submenus and BLS `/boot/loader/entries/*.conf`)
  - `refind` (`<id> | rEFInd`) — rEFInd `menuentry` definitions from `EFI/refind/refind.conf`
  - `limine_efi` (`limine-<n> | Limine-EFISTUB`) — Direct EFISTUB/EFI entries parsed from `limine.conf` / `limine.cfg`
- Automatically identifies generic fallback loaders (`bootx64.efi`, `bootaa64.efi`, `bootia32.efi`) by scanning their binary signatures for `systemd-boot`, `grub`, `refind`, or `limine`, and filters out non-OS firmware utilities (`fwupd*.efi`, `mmx64.efi`, `mmaa64.efi`, `mokmanager*.efi`, `shell*.efi`, `memtest*.efi`).

### Strict Exact-Match Query Engine & Fuzzy Suggestions
- Prevents substring collisions: running `boot linux` or `boot -t linux` will **never** silently guess between `linux zen` and `linux tkg`.
- When multiple entries match a query, `boot` reports an explicit ambiguity error listing every candidate index, name, version, and entry ID (`[#1] arch linux zen ... [0000]`).
- When a query matches nothing, `boot` uses Python `difflib.SequenceMatcher` to suggest up to 3 close matches (`Did you mean: [1] ...?`).
- Supports resolving targets by:
  - **Normalized OS/Kernel Name:** `windows 11 pro`, `arch linux zen`, `linux tkg`, `macos sequoia`
  - **Shorthand Aliases:** `win11`, `win10`, `winserver2022`, `linux-zen`, `linux_tkg`, `arch linux`, `pop`, `sequoia`, `tahoe`
  - **Full Name + Kernel/OS Version:** `arch linux zen 7.3.5-zen1-1-zen`
  - **UEFI Boot ID:** `0000`, `Boot0000`, `0004`, `Boot0004`
  - **Bootloader Entry ID:** `arch-linux.conf`, `bcd-1a2b3c4d`, `limine-1`
  - **Table Index Number:** `1`, `2`, `3`
  - **Distro-Scoped Selection (`-d <distro>`):** Narrow resolution or listing to a specific Linux distribution (e.g., `boot -d arch zen`).

### Multi-Windows BCD Parsing, OS Hive Inspection & Boot Isolation (`boot -s` / `boot -u`)
- Reads `/EFI/Microsoft/Boot/BCD` directly from the ESP and parses the Windows registry hive (`regf`) to enumerate every configured Windows OS loader object while excluding Windows Recovery Environment (`WinRE` / `.wim` / `winpe`) entries.
- Inspects each Windows OS partition (via mounted NTFS or `ntfscat`) to read `System32/ntoskrnl.exe` (`VS_VERSION_INFO`) and `System32/config/SOFTWARE` (`ProductName`, `DisplayVersion`, `ReleaseId`, `CurrentBuildNumber`, `UBR`, `EditionID`, `InstallationType`).
- Accurately identifies **Windows XP, Vista, 7, 8, 8.1, 10, 11**, and **Windows Server 2003, 2008, 2008 R2, 2012, 2012 R2, 2016, 2019, 2022, 2025**, including feature release tags (`1507`–`25H2`, `Canary`) and editions (`Home`, `Pro`, `Pro for Workstations`, `Pro Education`, `Enterprise`, `Enterprise LTSC`, `Education`, `Standard`, `Datacenter`).
- **One-Shot Multi-Windows Direct Boot:** When selecting a secondary Windows OS from a merged BCD store (or running `boot -s` / `--split-windows`), `boot` creates an isolated directory `/EFI/multiboot-win-<guid>/` containing `bootmgfw.efi`, localization `.mui`, and a patched single-target `BCD` hive (with recalculated XOR header checksum) and registers a UEFI NVRAM entry (`UEFI-WinDirect`), booting straight into that specific Windows installation without pausing at the Windows Boot Manager menu.
- **Cleanup (`boot -u` / `--cleanup-windows`):** Removes all isolated `multiboot-win-*` UEFI NVRAM entries and ESP directories.

### Binary Linux Kernel, UKI & Distro Inspection
- Parses DOS `MZ` and `PE/COFF` section tables inside EFI executables, inspecting `.linux`, `.osrel`, `.cmdline`, and `.uname` sections in Unified Kernel Images (UKIs) as well as standard EFISTUB `vmlinuz` / `bzImage` headers (`HdrS` magic `0x48647253`).
- Identifies **30+ Linux distributions** by inspecting the target root partition's `/etc/os-release` or `/usr/lib/os-release` (via active mountpoint, `debugfs` on `ext2`/`ext3`/`ext4`, or temporary read-only mount with `btrfs` `subvol=` support), UKI `.osrel` metadata, and loader/label signatures (Arch, CachyOS, EndeavourOS, Manjaro, Garuda, Artix, Ubuntu, Debian, Linux Mint, Pop!_OS, Kali, elementary, Zorin, KDE neon, TUXEDO, MX Linux, Fedora, Nobara, Bazzite, RHEL, Rocky, AlmaLinux, CentOS, openSUSE, NixOS, Gentoo, Void, Alpine, Solus, SteamOS, Slackware, Clear Linux).
- **Duplicate Disambiguation:** If two targets share the same OS name and kernel version, `boot` automatically appends `[<partition_label>]` or `[<device>]` so they remain uniquely identifiable.

### Comprehensive Linux Kernel Flavor Classification
Automatically detects and classifies standard, distribution, and custom-compiled Linux kernel flavors from loader filenames, kernel version strings, and NVRAM labels:
- `zen` (`linux-zen`)
- `tkg` (`linux-tkg`, including `tkg-bore`, `tkg-pds`, etc.)
- `lts` (`linux-lts`)
- `hardened` (`linux-hardened`)
- `cachyos` (including `cachyos bore`, `cachyos lto`, `cachyos eevdf`)
- `xanmod` (`linux-xanmod`)
- `liquorix` (`linux-liquorix`)
- `bore` (`linux-bore`)
- `mainline` (`linux-mainline`)
- `rt` / `rt lts` (Real-Time kernels)
- `lowlatency`, `ck`, `pf`, `clear`, `cfs`, `tuxedo`, `virt`, `edge`, `huge`
- `fallback` variants (e.g., `linux fallback`, `linux zen fallback`)
- Custom and standard default kernels (`linux`)

### OpenCore, Clover & macOS Detection
- Recognizes Apple `boot.efi`, `OpenCore` (`OpenCore.efi`), and `Clover` (`CLOVERX64.efi`) entries across UEFI NVRAM, `systemd-boot`, GRUB2, and rEFInd.
- Reads `/System/Library/CoreServices/SystemVersion.plist` from mounted `apfs` / `hfsplus` / `hfs` volumes to extract exact macOS version and build numbers (mapping **Catalina** through **Sequoia** and **macOS 26 Tahoe**), alongside OpenCore build tags, SMBIOS `SystemProductName` from `/EFI/OC/config.plist`, and Clover revisions.

### Mounted & Unmounted ESP Inspection (`mtools`)
- Automatically searches mounted ESP paths (`/efi`, `/boot/efi`, `/boot`, and any `vfat`/`fat`/`msdos` mountpoint reported by `findmnt` or `/proc/mounts`) using case-insensitive FAT path traversal.
- If the ESP is **not mounted** in the running system, seamlessly falls back to `/usr/local/libexec/multiboot-efi-read`, which uses `mtools` (`mdir` / `mcopy`) to inspect and extract files directly from the block device via `PARTUUID`.

### Complete CLI Options, Dry-Run, JSON & Dynamic Tab Completion
- **`boot <OS_NAME|INDEX>`:** Verifies target, prompts `[y/N]`, sets one-shot boot, and triggers `systemctl reboot` (with `shutdown -r now` and `reboot` fallbacks).
- **`boot -y` / `--yes`:** Skips confirmation prompt and reboots immediately.
- **`boot -f` / `--force`:** Terminates user desktop processes (`SIGTERM` then `SIGKILL`, sparing active session/shell/daemons) and executes `systemctl reboot --force --no-block`.
- **`boot -i` / `--interactive`:** Displays targets and prompts interactively for a target number `[1-N]`.
- **`boot -D` / `--default`:** Reboots into the firmware (`BootOrder` primary) or BCD default OS target.
- **`boot -d <DISTRO>` / `--distro=<DISTRO>`:** Filters target listing, default selection, JSON output, or query matching to a specific Linux distribution.
- **`boot -t` / `--test`:** Runs pre-flight verification (backend readiness, active state, `PARTUUID`, filesystem, EFI image, `initrd`, root device, and `sudo` rules) without modifying NVRAM or rebooting.
- **`boot -n` / `--dry-run`:** Runs verification and prints the exact step-by-step execution plan without touching NVRAM or disk.
- **`boot -p` / `--status`:** Displays current OS/kernel, `BootCurrent`, `BootNext`, `BootOrder`, `LoaderEntryOneShot`, and all detected bootloaders.
- **`boot -c` / `--clear`:** Clears pending one-shot selections (`efibootmgr --delete-bootnext`, `LoaderEntryOneShot`, and `grubenv` `next_entry`).
- **`boot -w` / `--firmware`:** Reboots directly into UEFI Firmware / BIOS setup (`systemctl reboot --firmware-setup` or `efibootmgr --indicate-firmware-setup`).
- **`boot -s` / `--split-windows`:** Splits all merged multi-OS Windows BCD entries into isolated UEFI NVRAM entries.
- **`boot -u` / `--cleanup-windows`:** Cleans up isolated `multiboot-win-*` UEFI entries and ESP directories.
- **`boot -l` / `--list`:** Prints a detailed diagnostic table of all targets, backends, loader paths, ESP `PARTUUID`s, root distro/devices, WinBCD GUIDs, and kernel options.
- **`boot -j` / `--json`:** Outputs detected targets, active/default/current states, and UEFI boot status as structured JSON.
- **`boot -v` / `--version` & `boot -h` / `--help`:** Prints version (`boot 2.2.0`) or compact target summary (`N/64`).
- **Bundled Short Flags & Completion (`boot --complete`):** Supports combined flags (e.g., `boot -yf win11`, `boot -dn arch`) and dynamic shell completion.

---

## 2. Smart Installer & Security Provisioner (`install.sh`)

### 7-Option Interactive TUI Menu & CLI Automation Flags
Running `./install.sh` launches a guided terminal management interface (and also supports non-interactive CLI flags `--install`, `--deps`, `--remove`, `--status`, `--repair`, `--sync-shells`, `-y/--yes`, and `-h/--help`):
1. **`Install` (`--install`):** Validates source integrity and Direct EFISTUB prerequisites, deploys `/usr/local/bin/boot` (with embedded password-authenticated `sudo` wrapper), builds `/usr/local/libexec/multiboot-efi-read`, generates and validates `/etc/sudoers.d/efiboot-next`, and configures user + system-wide shell integrations.
2. **`Install Required Dependencies` (`--deps`):** Checks and installs missing required packages (`efibootmgr`, `mtools`, `python3`, `sudo`, `util-linux`) via the detected distro package manager.
3. **`Remove / Uninstall` (`--remove`):** Purges `/usr/local/bin/boot`, `/usr/local/libexec/multiboot-efi-read`, `/etc/sudoers.d/efiboot-next`, isolated Windows BCD entries, system-wide shell hooks, user shell completion lines, Fish history entries, backups, and state/cache directories (`~/.local/share/multiboot`, `~/.cache/multiboot`, `/var/lib/multiboot`) with zero leftover files.
4. **`Status` (`--status`):** Displays installation completeness, distribution and package manager, UEFI Secure Boot status, core binary and `sudoers` health, EFI reader helper status, dependency trust diagnostics, detected/configured shells, and Direct EFISTUB verification status.
5. **`Repair` (`--repair`):** Re-validates Direct EFISTUB prerequisites, replaces `/usr/local/bin/boot` and `/usr/local/libexec/multiboot-efi-read`, refreshes `/etc/sudoers.d/efiboot-next`, and rebuilds all shell integrations.
6. **`Sync All Shells` (`--sync-shells`):** Re-applies Multi Boot shell functions, completions, and PATH hooks across all detected user shells and system-wide vendor paths.
7. **`Exit`:** Exits cleanly without making changes.

### Multi-Distro Package Manager Support (13 Package Managers)
Automatically detects the host distribution and package manager to verify or install `efibootmgr`, `mtools`, `python3`, `sudo`, and `util-linux`:
- `pacman` (Arch Linux, Manjaro, EndeavourOS, CachyOS, Garuda, Artix)
- `apt-get` (Debian, Ubuntu, Linux Mint, Pop!_OS, Kali, elementary, Zorin, KDE neon, TUXEDO)
- `dnf` (Fedora, RHEL, CentOS, Rocky, AlmaLinux, Oracle Linux, Nobara, Bazzite)
- `rpm-ostree` (Atomic Fedora / ostree-booted systems)
- `zypper` (openSUSE / SLES)
- `xbps-install` (Void Linux)
- `apk` (Alpine Linux)
- `yum` (Legacy RHEL / CentOS)
- `emerge` (Gentoo)
- `nix-env` (NixOS)
- `eopkg` (Solus)
- `swupd` (Clear Linux)
- `slackpkg` (Slackware)

### Strict Direct-EFISTUB Gatekeeper Verification
Before allowing installation or repair, `install.sh` performs a deep hardware and binary audit of your active boot path:
1. Confirms `/sys/firmware/efi` and `/sys/firmware/efi/efivars` exist (true UEFI boot).
2. Inspects `LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f` and `BootCurrent` via `efibootmgr -v`.
3. Extracts the GPT `PARTUUID` and verifies the partition resolves to a FAT (`vfat`/`fat`/`fat32`/`msdos`) EFI System Partition.
4. Reads the active EFI image (via mountpoint or `mtools`) and validates its **PE/COFF header** (`MZ`, `PE\0\0`, PE32/PE32+, UEFI Application subsystem `10`).
5. **Explicitly rejects intermediate bootloaders and chainloaders** (`shim`, `GRUB`, `rEFInd`, `systemd-boot`, `Limine`, `OpenCore`, `Clover`, `bootmgfw.efi`, etc.) as the primary boot path.
6. Verifies the image contains a genuine Linux kernel payload: **Direct EFISTUB `vmlinuz`/`bzImage`** (`HdrS` magic `0x48647253`), **EFI `zboot` compressed kernel** (`zimg`), **ARM64/RISC-V EFI kernel**, or **Unified Kernel Image (UKI)** with a valid embedded `.linux` PE section.

### Hardened Privileged Helper (`/usr/local/libexec/multiboot-efi-read`)
- Installed as `0755 root:root` using a verified root-owned `bash` interpreter (never `/usr/bin/env`).
- Exposes a strict, allowlisted command interface (`exists`, `read`, `set-oneshot`, `clear-oneshot`, `set-grub-oneshot`, `create-uefi-entry`, `remove-uefi-entry`, `write-efivar`, `mount-esp`, `umount-esp`, `esp-mkdir`, `esp-copy`, `clean-win-isolated`).
- Validates 36-character GPT `PARTUUID`s, verifies the EFI System Partition GPT type GUID (`c12a7328-f81f-11d2-ba4b-00a0c93ec93b`) and FAT filesystem, rejects virtual loop/ram/nbd devices, and blocks path traversal (`..`).

### Password-Authenticated `visudo`-Validated `sudoers` Policy (`/etc/sudoers.d/efiboot-next`)
- **Zero `NOPASSWD` / Zero Persistent Caching:** Explicitly forbids `NOPASSWD` and `timestamp_timeout`. Every `boot` invocation clears any cached timestamp (`sudo -k`), authenticates the user once via `sudo -v`, and revokes credentials on exit (`trap 'command sudo -k' EXIT INT TERM HUP`).
- Grants tightly scoped `root` execution rules at `/etc/sudoers.d/efiboot-next` (`0440 root:root`) exclusively for trusted root-owned `efibootmgr`, `/usr/local/libexec/multiboot-efi-read`, and `systemctl reboot` / `reboot`.
- Validates syntax with `visudo -cf` and full configuration with `visudo -c`, rolling back automatically on any validation error.

### 13-Shell Integration & Atomic Manifest-Tracked Uninstallation
- Automatically detects and configures **Bash**, **Zsh**, **Fish** (function, completion, and pre-populated `fish_history`), **Nushell**, **Elvish**, **Xonsh**, **PowerShell (`pwsh`)**, **Tcsh/Csh**, **Ksh/Mksh**, **Oils (`osh`/`ysh`)**, **Ion**, **Murex**, and **POSIX (`sh`/`dash`/`ash`)/TTY**, plus system-wide `/etc/profile.d/` hooks and vendor completion directories.
- Validates every user path against symlinks and UID ownership mismatches (`validate_safe_user_path`), backs up pre-existing completion files, and records all directives in `~/.local/share/multiboot/installed-directives` and `/var/lib/multiboot/system-files.manifest` for clean removal.

---

# Technical Architecture

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                          User Terminal / Shell                          │
│  (Bash / Zsh / Fish / Nu / Elvish / Xonsh / Pwsh / Tcsh / Ksh / POSIX)  │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        /usr/local/bin/boot (CLI)                        │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 0. Auth Wrapper: sudo -k && sudo -v (revoked automatically on exit)│  │
│  │ 1. Discovery Engine: UEFI NVRAM + sd-boot + GRUB2 + rEFInd + Limine│  │
│  │ 2. Metadata Inspector: PE/COFF + UKI + WinBCD/Hive + macOS Plist  │  │
│  │ 3. Exact-Match & Fuzzy Resolver: ID / Version / Distro / Flavor   │  │
│  │ 4. Pre-Flight Validator: UEFI / PARTUUID / EFI / initrd / root    │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└──────────────┬───────────────────────────────────────────┬──────────────┘
               │ (ESP / Loader / Efivar Ops)               │ (One-Shot Set & Reboot)
               ▼                                           ▼
┌──────────────────────────────┐            ┌─────────────────────────────┐
│ /usr/local/libexec/          │            │ /etc/sudoers.d/efiboot-next │
│ multiboot-efi-read (root)    │            │ (visudo-verified, password) │
│  ├─► mtools (mdir / mcopy)   │            │  ├─► efibootmgr --bootnext  │
│  ├─► bootctl / grub-reboot   │            │  ├─► multiboot-efi-read     │
│  ├─► WinBCD isolated ESP dir │            │  └─► systemctl reboot [-f]  │
│  └─► efivars PreviousBoot    │            └──────────────┬──────────────┘
└──────────────────────────────┘                           │
                                                           ▼
                                            ┌─────────────────────────────┐
                                            │   UEFI NVRAM (BootNext)     │
                                            │   & Firmware Reboot         │
                                            └─────────────────────────────┘
```

---

# Deep-Dive Workflow: How It Works Internally

## Phase 1 — Target Discovery & Deduplication

1. **UEFI NVRAM Scan (`parse_uefi_entries`):**
   - Queries `efibootmgr -v` and reads `BootCurrent`, `BootNext`, `BootOrder`, and every `BootXXXX` entry.
   - Splits device paths (`HD(...,GPT,<PARTUUID>,...)/<loader_path>`) from trailing options and decodes UTF-16LE hex arguments.
   - Detects bootloader manager entries (`systemd-boot`, `GRUB2`, `rEFInd`, `Limine`—including generic `bootx64.efi` / `bootaa64.efi` binaries identified via PE string inspection) so secondary loader targets can be chained via `BootNext`.
   - When `bootmgfw.efi` / `bootmgr.efi` is encountered, parses `/EFI/Microsoft/Boot/BCD` to register either a single Windows target or individual `WinBCD-Split` / `UEFI-WinDirect` targets for multi-Windows setups.
2. **Secondary Bootloader Scans:**
   - **`systemd-boot` (`parse_systemd_boot_entries` & `parse_bootctl_entries`):** Scans mounted ESPs for `/loader/entries/*.conf` (including `.conf.d/*.conf` drop-ins and multiple `initrd` lines), `/EFI/Linux/*.efi`/`.uki`, `auto-windows`, and `bootctl list`.
   - **GRUB2 (`parse_grub_entries`):** Parses `grub.cfg` menuentries (including nested `submenu` paths `submenu>entry`) and BLS `/boot/loader/entries/*.conf` when `blscfg` is active.
   - **rEFInd (`parse_refind_entries`):** Parses enabled `menuentry` blocks from `EFI/refind/refind.conf`.
   - **Limine (`parse_limine_entries`):** Parses `limine.conf` / `limine.cfg` entries targeting EFI/UKIs.
3. **Deduplication & Disambiguation:**
   - Deduplicates identical `(PARTUUID, loader, options)` tuples across NVRAM and `systemd-boot`, and appends `[<partition_label>]` if multiple distinct installations share the same OS name and kernel version.

## Phase 2 — Binary Metadata & Version Extraction

- **For Windows (`bootmgfw.efi` + `BCD` + OS Partition):**
  - Parses `/EFI/Microsoft/Boot/BCD` to extract each OS entry's GUID, description, `SystemRoot`, and OS partition `PARTUUID`.
  - Inspects `System32/ntoskrnl.exe` (`VS_VERSION_INFO`) and `System32/config/SOFTWARE` on the Windows partition to determine exact major/minor/build/UBR numbers, release tag (`22H2`, `23H2`, `24H2`, `25H2`), edition (`Pro`, `Home`, `Enterprise`, `Server`), and label.
- **For Linux (`vmlinuz*` or `*.efi` / `*.uki`):**
  - Inspects DOS `MZ` and `PE/COFF` sections (`.linux`, `.osrel`, `.cmdline`, `.uname`).
  - Reads the Linux setup header (`HdrS` magic `0x48647253`) or kernel version strings to extract the exact release string, and inspects the target root filesystem's `/etc/os-release` to identify the Linux distribution.
- **For macOS (`boot.efi`, `OpenCore.efi`, `CLOVERX64.efi`):**
  - Reads `SystemVersion.plist` on mounted `apfs` / `hfsplus` / `hfs` partitions along with OpenCore `config.plist` SMBIOS/version strings or Clover revision numbers.

## Phase 3 — Query Normalization & Exact-Match Resolution

When you run `boot <query>`, `normalize_query` converts underscores and backslashes to spaces, collapses whitespace, and expands shorthand aliases (`win11` $\rightarrow$ `windows 11`, `linux-zen` $\rightarrow$ `linux zen`, `arch linux` $\rightarrow$ `arch`, `sequoia` $\rightarrow$ `macos sequoia`).

`match_target` evaluates candidates (optionally filtered by `-d <distro>`) in strict priority order:
1. **Numeric Table Index** (`1`..`64`)
2. **Exact Boot / Loader Entry ID** (`0000`, `Boot0000`, `arch-linux.conf`, `bcd-1a2b3c4d`)
3. **Exact Full Name + Kernel/OS Version** (`arch linux zen 7.3.5-zen1-1-zen`)
4. **Exact Normalized Name or Distro Default** (`arch linux zen`, `windows 11 pro`, `arch`)
5. **Partial Substring Match** across display name, NVRAM label, version, or kernel flavor

If any tier matches more than one entry (`matches > 1`), execution aborts with an ambiguity report listing all matching candidates. If zero entries match, `suggest_similar_targets` displays close matches via `difflib`.

## Phase 4 — Multi-Stage Pre-Flight Safety Verification

Before setting `BootNext` or rebooting, `verify_target` validates:
1. **Backend & Manager Readiness:** Confirms `efibootmgr`, `bootctl`, `grub-reboot`, or `python3` availability and ensures the UEFI NVRAM entry or parent boot manager (`systemd-boot`, `GRUB2`, `rEFInd`) is marked active (`*`).
2. **Partition & Filesystem Integrity:** Resolves the target GPT `PARTUUID` to a block device and verifies its filesystem type (`vfat`/`fat`/`fat32` for ESPs).
3. **Loader Binary Presence:** Verifies that the `.efi`, `.uki`, or kernel image exists and is non-empty on the ESP (via mountpoint or `multiboot-efi-read`).
4. **Initramfs & Root Device Checks:** Verifies every `initrd=` path referenced in kernel options exists on the ESP and checks whether the `root=` block device is currently visible.
5. **Privilege Readiness:** Checks `sudo -n -l` rules for the required target backend and reboot command.

## Phase 5 — One-Shot NVRAM Programming & Reboot Execution

1. **Confirmation Prompt:** Displays the resolved target name, version, and label, requiring `[y/N]` confirmation (unless `-y` or `-f` is passed).
2. **One-Shot Boot Programming:**
   - **UEFI Direct (`uefi`):** Runs `efibootmgr --bootnext <ID>`.
   - **Windows Multi-OS Split (`winbcd`):** Generates `/EFI/multiboot-win-<guid>/` with a single-target `BCD`, registers/reuses its UEFI NVRAM entry, and sets `BootNext`.
   - **`systemd-boot` (`sdboot`):** Sets `BootNext` to `SDBOOT_MANAGER_ID` and runs `bootctl set-oneshot <ENTRY_ID>`.
   - **GRUB2 (`grub`):** Sets `BootNext` to `GRUB_MANAGER_ID` and runs `grub-reboot <ENTRY_ID>`.
   - **rEFInd (`refind`):** Sets `BootNext` to `REFIND_MANAGER_ID` and writes the UTF-16LE entry title to `PreviousBoot-36d08fa7-cf0b-42f5-8f14-68df73ed3740`.
   - **Limine (`limine_efi`):** Registers/reuses a direct EFISTUB UEFI entry for the Limine target image and sets `BootNext`.
3. **Reboot Execution:**
   - If `-f` was specified, `terminate_user_applications` sends `SIGTERM` then `SIGKILL` to user session processes (sparing the active session, shell, `systemd`, `dbus`, and `sshd`) before executing `systemctl reboot --force --no-block` (`reboot -f`).
   - Otherwise, executes `systemctl reboot` (falling back to `shutdown -r now` or `reboot`).

---

# Installation & Lifecycle Management

## Prerequisites

- **Arch Linux** (recommended) booted in **UEFI mode** via **Direct EFISTUB**
- `bash` 4.0+, `sudo`, and standard core utilities
- Required packages (checked and installed via `./install.sh --deps` or menu option `2`):
  - `efibootmgr`
  - `mtools`
  - `python3`
  - `sudo`
  - `util-linux`

## Quick Installation

```bash
git clone [https://github.com/plopletoyay/multi-boot.git](https://github.com/plopletoyay/multi-boot.git)
cd multi-boot
chmod +x boot install.sh
./install.sh --deps
./install.sh --install
```

Or run `./install.sh` without arguments to use the interactive management menu.

## Interactive Installer Menu (`./install.sh`)

```text
Multi Boot Management
Status : Not installed
User   : plopletoyay (plopletoyay)
Shells : Bash, Zsh, Fish

1) Install
2) Install Required Dependencies
3) Remove / Uninstall
4) Status
5) Repair
6) Sync All Shells
7) Exit

Select an option [1-7]:
```

- **`1) Install` (`--install`):** Validates Direct EFISTUB environment, installs `/usr/local/bin/boot`, builds `/usr/local/libexec/multiboot-efi-read`, configures `/etc/sudoers.d/efiboot-next` via `visudo`, and configures user + system-wide shell integrations.
- **`2) Install Required Dependencies` (`--deps`):** Checks `efibootmgr`, `mtools`, `python3`, `sudo`, and `util-linux`, and installs any missing packages using the detected package manager.
- **`3) Remove / Uninstall` (`--remove`):** Purges all system binaries, the privileged helper, `sudoers` rules, isolated Windows BCD entries, system-wide vendor hooks, user shell completion lines, Fish history entries, and state/cache directories.
- **`4) Status` (`--status`):** Checks installation completeness, distro/package manager, Secure Boot state, `/usr/local/bin/boot`, `/usr/local/libexec/multiboot-efi-read`, `/etc/sudoers.d/efiboot-next`, dependency binary trust, shell hooks, and Direct EFISTUB status.
- **`5) Repair` (`--repair`):** Re-runs Direct EFISTUB validation, overwrites `/usr/local/bin/boot` and `/usr/local/libexec/multiboot-efi-read` with clean copies, re-validates `/etc/sudoers.d/efiboot-next`, and rebuilds all shell integrations.
- **`6) Sync All Shells` (`--sync-shells`):** Re-synchronizes shell functions, completions, and PATH hooks across all detected user shells and system-wide vendor paths.

---

# Usage Guide & Real-World Examples

## Command Reference

| Command | Description |
| :--- | :--- |
| `boot <OS_NAME\|INDEX>` | Verify target, confirm `[y/N]`, set one-shot boot, and reboot gracefully |
| `boot -y <OS_NAME>` | Skip confirmation prompt and reboot immediately |
| `boot -f <OS_NAME>` | Close open user apps immediately and force reboot (`systemctl reboot --force`) |
| `boot -i` | Interactive menu to pick a boot target by number `[1-N]` |
| `boot -D` / `--default` | Reboot into the firmware (`BootOrder` primary) or BCD default OS target |
| `boot -d <DISTRO> [TARGET]` | Filter target listings or narrow target resolution to a specific Linux distro |
| `boot -t <OS_NAME>` | Verify boot image, partition, `initrd`, root device, and `sudo` permissions |
| `boot -n <OS_NAME>` | Dry-run: verify target and preview the exact step-by-step execution plan |
| `boot -p` / `--status` | Show running OS/kernel, `BootCurrent`, `BootNext`, `BootOrder`, and detected bootloaders |
| `boot -c` / `--clear` | Clear any pending one-shot boot selection (`BootNext`, `LoaderEntryOneShot`, `next_entry`) |
| `boot -w` / `--firmware` | Reboot directly into UEFI Firmware / BIOS setup |
| `boot -s` / `--split-windows` | Split merged multi-OS Windows BCD entries into isolated direct UEFI entries |
| `boot -u` / `--cleanup-windows` | Clean up isolated `multiboot-win-*` UEFI entries and ESP directories |
| `boot -l` / `--list` | Display detailed table of all detected boot targets, backends, paths, and options |
| `boot -j` / `--json` | Output detected boot targets and UEFI status in JSON format |
| `boot -v` / `--version` | Display `boot` version (`boot 2.2.0`) |
| `boot -h` / `--help` | Display compact list of installed OS/kernels (`N/64`) and command summary |

## Example 1 — Listing Available Targets (`boot -h` and `boot -l`)

```text
[plopletoyay@archlinux ~]$ boot -h
INSTALLED OS AND KERNELS (3/64)
  [1] arch linux zen 7.3.5-zen1-1-zen [CURRENT] (Boot0000 | UEFI)
  [2] arch linux tkg 7.3.4-273-tkg-bore (Boot0001 | UEFI)
  [3] windows 11 pro 24H2 (10.0.26100.3194) (Boot0004 | UEFI)

COMMANDS & OPTIONS
  boot <OS_NAME|INDEX>      Reboot once into the selected OS or kernel
  boot -y <OS_NAME>         Skip confirmation prompt and reboot immediately
  boot -f <OS_NAME>         Close open apps immediately and force reboot
  boot -i                   Interactive menu to pick a boot target by number
  boot -D | --default       Reboot into the firmware/BCD default OS target
  boot -d <DISTRO> [TARGET] Filter or select a specific Linux distro
  boot -t <OS_NAME>         Verify boot image, partition, and sudo permissions
  boot -n <OS_NAME>         Dry-run: preview execution plan without rebooting
  boot -p                   Show current UEFI BootCurrent, BootNext, and bootloaders
  boot -c                   Clear any pending one-shot boot selection
  boot -w                   Reboot directly into UEFI Firmware / BIOS setup
  boot -s                   Split merged Windows BCD entries into direct UEFI entries
  boot -u                   Clean up isolated multiboot-win-* UEFI entries
  boot -l                   Show detailed boot target table, root devices, and paths
  boot -j | --json          Output detected boot targets and status in JSON format
  boot -h                   Show installed targets and available commands
```

```text
[plopletoyay@archlinux ~]$ boot -l
DETECTED BOOT TARGETS (3/64)

  [1] arch linux zen 7.3.5-zen1-1-zen  [ACTIVE] [CURRENT]
      Entry   : UEFI NVRAM (Boot0000) - Arch Linux (linux-zen)
      Loader  : /EFI/Linux/arch-linux-zen.efi
      ESP/Boot: PARTUUID=fe124bba-2553-4935-b4fc-dff33a965b9f (vfat)
      Distro  : Arch Linux (Root: ArchRoot)

  [2] arch linux tkg 7.3.4-273-tkg-bore  [ACTIVE]
      Entry   : UEFI NVRAM (Boot0001) - Arch Linux (linux-tkg)
      Loader  : /vmlinuz-linux-tkg-bore
      ESP/Boot: PARTUUID=fe124bba-2553-4935-b4fc-dff33a965b9f (vfat)
      Distro  : Arch Linux (Root: ArchRoot)
      Options : root=UUID=8f3c1e2a-9b4d-4c1a-8e2f-1a2b3c4d5e6f rw initrd=\initramfs-linux-tkg-bore.img

  [3] windows 11 pro 24H2 (10.0.26100.3194)  [ACTIVE]
      Entry   : UEFI NVRAM (Boot0004) - Windows Boot Manager
      Loader  : /EFI/Microsoft/Boot/bootmgfw.efi
      ESP/Boot: PARTUUID=fe124bba-2553-4935-b4fc-dff33a965b9f (vfat)
```

## Example 2 — Pre-Flight Verification & Dry-Run (`boot -t` and `boot -n`)

```text
[plopletoyay@archlinux ~]$ boot -n win11
Success: 'Windows Boot Manager' (windows 11 pro 24H2 (10.0.26100.3194)) passed entry, active, part(vfat), image, sudo.

DRY-RUN EXECUTION PLAN
  Target OS   : windows 11 pro 24H2 (10.0.26100.3194)
  Backend     : uefi (0004)
  Loader      : /EFI/Microsoft/Boot/bootmgfw.efi
  ESP PARTUUID: fe124bba-2553-4935-b4fc-dff33a965b9f
  Step 1      : /usr/bin/efibootmgr --bootnext 0004
  Reboot Step : /usr/bin/systemctl reboot

Info: Dry-run complete. No changes were written to NVRAM or disk.
```

---

# Troubleshooting & Installer Rejection Guide

| Installer Message | Root Cause | Resolution |
| :--- | :--- | :--- |
| `Multi Boot requires UEFI mode. Installation stopped.` | System is booted in Legacy BIOS / CSM mode (`/sys/firmware/efi` is missing). | Reinstall or convert your system to boot in native UEFI mode. |
| `The current boot path uses a boot manager or chainloader instead of direct EFISTUB.` | Your active `BootCurrent` entry points to `GRUB`, `systemd-boot`, `rEFInd`, `shim`, `Limine`, `OpenCore`, or `Clover`. | Configure a direct EFISTUB NVRAM entry (`efibootmgr -c ...`) or UKI entry and boot directly into it before running `./install.sh`. |
| `Missing required dependencies: ...` | One or more required tools (`efibootmgr`, `mtools`, `python3`, `sudo`, `util-linux`) are missing or reside in untrusted paths. | Run `./install.sh --deps` (or menu option `2`) first, then re-run `./install.sh --install`. |
| `/etc/sudoers does not appear to include /etc/sudoers.d` | Your distribution's `/etc/sudoers` lacks `@includedir /etc/sudoers.d`. | Uncomment or add `@includedir /etc/sudoers.d` in `/etc/sudoers` via `visudo`. |
| `More than one entry matches '<query>'` | Two or more targets share the same base name or flavor. | Pass the full target name with version, the table index (`boot 2`), the Boot ID (`boot 0001`), or filter by distro (`boot -d arch <target>`). |

---

# Security Model & Privilege Boundaries

- **Password-Authenticated Privilege Elevation:** `install.sh` explicitly prohibits `NOPASSWD` and `timestamp_timeout` in `/etc/sudoers.d/efiboot-next`. `/usr/local/bin/boot` calls `sudo -k` before `sudo -v` and registers an `EXIT INT TERM HUP` trap to run `sudo -k` immediately upon exit so elevated credentials never linger in the terminal session.
- **Root-Owned Binary Trust Verification:** Before adding any binary to `sudoers` or executing privileged tools, `is_trusted_root_binary()` walks every path component up to `/` to guarantee `UID 0` ownership and non-world/group-writable permissions.
- **Restricted Root Helper (`/usr/local/libexec/multiboot-efi-read`):** Runs with a sanitized `PATH`, validates GPT `PARTUUID`s and EFI System Partition type GUIDs (`c12a7328-f81f-11d2-ba4b-00a0c93ec93b`), rejects symbolic links and `..` traversal, and restricts file reads and writes to allowlisted boot/EFI paths and efivars.
- **Atomic Backup & Rollback:** Failed installation or removal operations automatically restore backed-up system files (`/usr/local/bin/boot`, `/usr/local/libexec/multiboot-efi-read`, `/etc/sudoers.d/efiboot-next`) and user shell configurations without leaving broken states.

---

# Project Structure

```text
multi-boot/
├── boot                                         # Core CLI switcher, multi-loader & BCD/UKI inspector (v2.2.0)
├── install.sh                                   # Interactive TUI / CLI installer, EFISTUB auditor & shell provisioner
└── README.md                                    # Documentation

# Installed System & User Artifacts (managed by install.sh):
├── /usr/local/bin/boot                          # Installed CLI with embedded sudo credential-scoping wrapper
├── /usr/local/libexec/multiboot-efi-read        # Restricted root helper for ESP, BCD, efivars & one-shot loader ops
├── /etc/sudoers.d/efiboot-next                  # visudo-validated, password-authenticated sudoers rule (0440)
├── /var/lib/multiboot/system-files.manifest     # Manifest of installed system-wide shell hooks
└── ~/.local/share/multiboot/                    # Per-user directive tracker & pre-install dotfile backups
```

---

# Design Philosophy

1. **Verify Before Touching Firmware:** Never write `BootNext` or trigger a reboot until the target entry, GPT partition, filesystem, EFI binary, and `initramfs` have been verified on disk.
2. **Inspect Real Binaries, Never Guess:** Read actual PE/COFF headers, Linux `HdrS` setup structures, Windows `BCD` / `SOFTWARE` hives, and `/etc/os-release` files rather than relying solely on mutable NVRAM labels.
3. **Least Privilege & Reversible State:** Require explicit user password authentication per invocation, isolate privileged block/efivar access behind a strictly validated helper, and track every artifact so uninstallation leaves zero trace.

---

# License & Author

- **Author:** [plopletoyay](https://github.com/plopletoyay)
- **Repository:** https://github.com/plopletoyay/multi-boot
