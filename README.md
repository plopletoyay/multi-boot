# *HAVE MANY "Critical" SECURITY BUG PLS WAIT AND DON'T USE RIGHT NOW!*

# `multi-boot`

A safety-verified, one-shot CLI operating system and Linux kernel reboot switcher designed for UEFI systems.

Official repository:

https://github.com/plopletoyay/multi-boot

`multi-boot` discovers your installed operating systems and Linux kernels across UEFI NVRAM and `systemd-boot`, inspects their actual EFI binaries and kernel headers to determine exact versions and flavors, verifies every partition, bootloader image, and `initramfs` file before touching firmware state, and configures a single-use (`BootNext` / `LoaderEntryOneShot`) reboot target without altering your permanent `BootOrder`.

# `One-Shot UEFI & systemd-boot OS / Kernel Switcher`

> **This project is not a bootloader replacement.**
>
> It is a pre-boot verification and NVRAM one-shot orchestration layer that lets you reboot directly into Windows, macOS, or a specific Linux kernel flavor from your terminal with a single command.

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

## Cross-Distro Status (Experimental / Untested)

While `install.sh` includes package manager detection for Debian/Ubuntu (`apt-get`), Fedora/RHEL (`dnf`), openSUSE (`zypper`), Void (`xbps-install`), Alpine (`apk`), and legacy `yum`, **`multi-boot` _may_ work on other Linux distributions if and only if they are configured to boot via Direct EFISTUB**.

> **Important Note on Other Distributions:**
>
> Cross-distribution support is **experimental and has NOT been officially tested**. Most mainstream distributions default to GRUB, `shim`, or `systemd-boot` rather than Direct EFISTUB, which `install.sh` will intentionally reject during its pre-installation gatekeeper checks. Use on non-Arch distributions at your own discretion.

## Critical Operational Warnings

Even though `multi-boot` enforces strict pre-flight checks before triggering a reboot, it directly interacts with **UEFI NVRAM variables** and **system power state**:

- **UEFI Mode Required:** Legacy BIOS / CSM installations are completely unsupported. `/sys/firmware/efi` must be mounted and writable.
- **NVRAM Write Operations:** Setting a one-shot boot target writes to the UEFI `BootNext` variable via `efibootmgr` (and `LoaderEntryOneShot` via `bootctl` when targeting `systemd-boot` entries). Although `BootNext` is automatically cleared by compliant UEFI firmware on the next boot, buggy motherboard firmware implementations can occasionally behave unexpectedly.
- **Force Mode (`boot -f`) Destroys Unsaved Work:** Passing `-f` / `--force` immediately sends `SIGKILL` to user desktop application scopes (`app-*.scope`, `flatpak-*.scope`) and GUI windows before executing `systemctl reboot -f`. Always save your work before using `-f`.
- **Direct ESP Block Reads:** When your EFI System Partition (ESP) is not mounted, `multi-boot` uses `mtools` (`mcopy`/`mdir`) through a restricted root helper to inspect EFI binaries and `initramfs` images directly on the FAT32 partition.

---

# What This Project Is (and Is Not)

`multi-boot` bridges the gap between Linux CLI workflows and firmware-level multi-boot selection:

| Role | Description |
| :--- | :--- |
| **`One-Shot NVRAM Orchestrator`** | Sets UEFI `BootNext` (and `systemd-boot` `LoaderEntryOneShot`) for a single reboot without touching permanent `BootOrder`. |
| **`Pre-Reboot Safety Validator`** | Verifies NVRAM active flags, GPT `PARTUUID`, filesystem types, EFI images, and `initramfs` paths before rebooting. |
| **`Binary Header Inspector`** | Parses PE/COFF headers, Linux kernel `HdrS` setup headers, and Windows `ProductVersion` resources directly from `.efi` files. |
| **`Ambiguity Guard`** | Uses strict exact-match precedence so `boot linux` never accidentally triggers `linux zen` or `linux tkg`. |
| **`Non-Destructive CLI Utility`** | Tracks all installed artifacts and shell completion snippets in a manifest for clean removal. |

### What `multi-boot` Is NOT

- It is **not** a bootloader (it does not replace EFISTUB, `systemd-boot`, GRUB, or rEFInd).
- It does **not** rewrite your permanent UEFI `BootOrder`. After booting into your chosen OS/kernel once, the next subsequent reboot returns to your default firmware boot priority.
- It does **not** modify partition tables, kernel images, or `/loader/entries/*.conf` files.

---

# Complete Capabilities & Feature Breakdown

## 1. Core Switcher (`boot`)

### Target Cap & Deterministic Inventory (`MAX_TARGETS=10`)
- Scans and indexes up to **10 boot targets total** across all detected operating systems and Linux kernels, keeping target tables readable, bounded, and predictable.
- Automatically filters out non-OS firmware utilities (`shim*.efi`, `grub*.efi`, `refind*.efi`, `bootx64.efi`, `fwupd*.efi`, `mmx64.efi`, `mokmanager*.efi`, `shell*.efi`, `memtest*.efi`) so only real bootable OS/kernel targets appear.

### Strict Exact-Match Query Engine
- Prevents substring collisions: running `boot linux` or `boot -t linux` will **never** silently guess between `linux zen` and `linux tkg`.
- When multiple entries share a base family (such as `linux zen` and `linux tkg`), `boot` reports an explicit ambiguity error listing the exact candidates and their Boot IDs (`0000`, `0001`).
- Supports resolving targets by:
  - **Normalized OS/Kernel Name:** `windows 11`, `linux zen`, `linux tkg`, `macos sonoma`
  - **Shorthand Aliases:** `win11`, `win10`, `linux-zen`, `linux_tkg`, `zen`, `tkg`
  - **Full Name + Kernel Version:** `linux zen 7.3.5-zen1-1-zen`
  - **UEFI Boot ID:** `0000`, `Boot0000`, `0004`, `Boot0004`
  - **`systemd-boot` Entry ID:** `arch-linux.conf`, `auto-windows`
  - **Table Index Number:** `1`, `2`, `3`

### Binary Windows Version & Build Detection (`bootmgfw.efi`)
- Reads `bootmgfw.efi` or `bootmgr.efi` directly from the ESP (whether mounted or unmounted).
- Extracts `ProductVersion` and `FileVersion` metadata strings (UTF-16LE and ASCII).
- Maps Windows NT kernel version and build numbers accurately:
  - `10.0.22000+` $\rightarrow$ `windows 11`
  - `10.0.<22000` $\rightarrow$ `windows 10`
  - `6.3.x` $\rightarrow$ `windows 8.1`
  - `6.2.x` $\rightarrow$ `windows 8`
  - `6.1.x` $\rightarrow$ `windows 7`
  - `6.0.x` $\rightarrow$ `windows vista`
  - `5.1.x` $\rightarrow$ `windows xp`
- **Zero-Guess Policy:** If `bootmgfw.efi` cannot be read or contains no recognizable version header, it labels the entry `windows unknown` rather than guessing an edition.

### Binary Linux Kernel & UKI Header Inspection
- Parses DOS `MZ` and `PE/COFF` section tables inside EFI executables.
- If the image is a **Unified Kernel Image (UKI)** containing a `.linux` PE section, `boot` seeks directly into the embedded `.linux` payload, verifies the Linux boot protocol magic `HdrS` (`0x53726448`), reads the kernel version offset pointer, and extracts the exact compiled kernel release string (e.g., `7.3.5-zen1-1-zen`).
- Also supports standard raw EFISTUB `vmlinuz` images, `Linux version X.Y.Z` string scanning, and filename-based version extraction (`7.3.4-273-tkg-bore`).

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
- `lowlatency`, `ck`, `pf`, `clear`, `cfs`, `tuxedo`
- `fallback` variants (e.g., `linux fallback`, `linux zen fallback`)
- Custom and standard default kernels (`linux`)

### OpenCore, Clover & macOS Detection
- Recognizes Apple `boot.efi`, `OpenCore` (`OpenCore.efi`), and `Clover` (`CLOVERX64.efi`) entries in NVRAM and `systemd-boot`.
- Classifies macOS release names from entry titles (`Tahoe`, `Sequoia`, `Sonoma`, `Ventura`, `Monterey`, `Big Sur`, `Catalina`, `Mojave`, `High Sierra`).
- Validates target partition types against `apfs`, `hfsplus`, `hfs`, and `vfat`/`fat32`.

### `systemd-boot` One-Shot Specification Compliance
- Implements the official `systemd` / [Boot Loader Specification (freedesktop.org)](https://uapi-group.org/specifications/specs/boot_loader_specification/) one-shot boot sequence:
  1. Sets the one-shot loader entry (`LoaderEntryOneShot`) via `bootctl set-oneshot <entry_id>`.
  2. Sets UEFI `BootNext` via `efibootmgr --bootnext <sdboot_manager_id>` pointing to the active `systemd-boot` firmware manager entry.
- Parses `/loader/entries/*.conf` (including multi-line `options` and multiple `initrd` directives), `/EFI/Linux/*.efi` auto-discovered UKIs, `auto-windows`, and `bootctl list`.
- Automatically rolls back `LoaderEntryOneShot` if setting `BootNext` fails.

### Mounted & Unmounted ESP Inspection (`mtools`)
- Automatically searches mounted ESP paths (`/efi`, `/boot/efi`, `/boot`, and any `vfat`/`fat`/`msdos` mountpoint reported by `findmnt` or `/proc/mounts`) using case-insensitive FAT path traversal.
- If the ESP is **not mounted** in the running system, seamlessly falls back to `/usr/local/libexec/multiboot-efi-read`, which uses `mtools` (`mdir` / `mcopy`) to inspect and extract files directly from the block device via `PARTUUID`.

### UTF-16LE Hex & Raw UEFI Option Decoding
- Cleanly separates EFI loader paths from appended UTF-16LE hex-encoded kernel command-line arguments in `efibootmgr -v` output (preventing hex strings from bleeding into filenames).
- Strips raw Windows BCD binary blobs (`57494e444f575300...`) from Windows NVRAM entries.
- Extracts every `initrd=` parameter from decoded NVRAM options or `.conf` entries and verifies that every single microcode (`intel-ucode.img`, `amd-ucode.img`) and `initramfs` image actually exists and is non-empty on the ESP.

### Running Kernel Protection
- Compares the target kernel against the currently active OS session using `BootCurrent` (UEFI NVRAM), `LoaderEntrySelected` (`systemd-boot`), `uname -r`, and `/proc/cmdline` (`BOOT_IMAGE` / `initrd`).
- Prevents accidental reboots into the exact kernel you are already running:
  ```text
  You are already running linux zen (7.3.5-zen1-1-zen).
  ```

### Five Operational Modes + Dynamic Tab Completion
- **Normal Mode (`boot <target>`):** Runs full pre-flight verification, asks for confirmation, sets `BootNext`, and triggers a clean `systemctl reboot`.
- **Force Mode (`boot -f <target>`):** Runs full pre-flight verification, asks for confirmation, terminates open user desktop applications while sparing the active terminal, compositor, and display manager, sets `BootNext`, and executes `systemctl reboot -f`.
- **Test / Dry-Run Mode (`boot -t <target>`):** Runs every verification check (UEFI mode, NVRAM active state, `PARTUUID`, filesystem, EFI binary, all `initrd` files, and `sudo` permissions) without touching NVRAM or rebooting.
- **List Mode (`boot -l`):** Prints a detailed diagnostic breakdown of all detected targets, active/current badges, NVRAM IDs, loader paths, `PARTUUID` + filesystem types, and decoded kernel options.
- **Help Mode (`boot -h`):** Displays a compact summary of installed targets (`N/10`) and command syntax.
- **Completion Mode (`boot --complete`):** Outputs deduplicated target names, versioned disambiguators, and Boot IDs for shell tab-completion.

---

## 2. Smart Installer & Security Provisioner (`install.sh`)

### 5-Option Interactive TUI Menu
Running `./install.sh` presents a guided terminal management interface:
1. **`Install`** — Runs full pre-flight EFISTUB checks, installs dependencies, deploys `/usr/local/bin/boot`, builds the privilege-separated EFI reader helper, configures `sudoers`, and injects shell completions.
2. **`Uninstall`** — Cleanly removes all installed binaries, `sudoers` rules, and installer-added shell configuration lines using the installation manifest.
3. **`Status`** — Displays current installation state, core binary and `sudoers` health, EFISTUB verification status, and detected boot targets.
4. **`Repair`** — Re-validates EFISTUB prerequisites, regenerates `/usr/local/bin/boot`, `/usr/local/libexec/multiboot-efi-read`, `/etc/sudoers.d/multiboot` (via `visudo`), and restores any missing shell completions.
5. **`Exit`** — Exits cleanly without making changes.

### Multi-Distro Package Manager Support
Automatically detects the host package manager to ensure `efibootmgr`, `mtools`, `util-linux` (`lsblk`/`blkid`/`findmnt`), `binutils` (`strings`), and `sudo` are present:
- `pacman` (Arch Linux)
- `apt-get` (Debian / Ubuntu)
- `dnf` (Fedora / RHEL)
- `zypper` (openSUSE)
- `xbps-install` (Void Linux)
- `apk` (Alpine Linux)
- `yum` (Legacy RHEL / CentOS)

### Strict Direct-EFISTUB Gatekeeper Verification
Before allowing installation, `install.sh` performs a 6-step hardware and binary audit of your current boot path:
1. Confirms `/sys/firmware/efi` exists (true UEFI boot).
2. Reads `BootCurrent` from `efibootmgr -v` and confirms the active NVRAM entry (`*`).
3. Extracts the GPT `PARTUUID` and verifies the partition exists and uses a FAT (`vfat`/`fat`/`fat32`) filesystem.
4. Locates the real EFI file on the ESP (via mountpoint or `mtools`).
5. **Explicitly rejects intermediate bootloaders and stubs** (`GRUB`, `rEFInd`, `shim`, `systemd-boot`, and `systemd-stub` UKIs) as the primary boot path.
6. Inspects the binary's **PE/COFF header** (`MZ` + `PE\0\0`) and **Linux kernel setup header** (`HdrS` magic + kernel version string) before accepting it as a genuine Direct EFISTUB kernel.

### Hardened EFI Reader Helper (`/usr/local/libexec/multiboot-efi-read`)
- Installed as `root:root` with mode `0755`.
- Accepts only two commands: `exists <partuuid> <path>` and `read <partuuid> <path>`.
- Strictly validates 36-character UUID syntax, verifies the block device is a FAT filesystem, and rejects any path containing `..` or shell metacharacters before invoking `mtools`.

### `visudo`-Validated `sudoers` Policy (`/etc/sudoers.d/multiboot`)
- Grants tightly scoped `NOPASSWD` rules exclusively for `efibootmgr`, `bootctl`, `systemctl reboot` / `reboot`, and `/usr/local/libexec/multiboot-efi-read`.
- Validates the generated policy with `visudo -cf` before moving it into `/etc/sudoers.d/multiboot` (`0440`), guaranteeing zero risk of corrupting `sudo`.

### Multi-Shell Integration & Manifest-Tracked Uninstallation
- Automatically configures tab-completion for **Fish**, **Zsh**, **Bash**, **Nushell**, and **POSIX/TTY** shells.
- Records every created file and injected shell snippet in `/var/lib/multiboot/install.manifest` so `Uninstall` removes **only** the lines added by `install.sh` without ever touching your existing shell configuration.

---

# Technical Architecture

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                          User Terminal / Shell                          │
│               (Bash / Zsh / Fish / Nushell / POSIX / TTY)               │
└────────────────────────────────────┬────────────────────────────────────┘
                                     │
                                     ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                        /usr/local/bin/boot (CLI)                        │
│  ┌───────────────────────────────────────────────────────────────────┐  │
│  │ 1. Discovery Engine: efibootmgr -v  +  /loader/entries  +  UKI    │  │
│  │ 2. Binary Inspector: PE/COFF ProductVersion  +  Linux HdrS Header │  │
│  │ 3. Exact-Match Resolver: ID / Version / Name / Flavor / Alias     │  │
│  │ 4. Pre-Flight Validator: UEFI / NVRAM / PARTUUID / EFI / initrd   │  │
│  └───────────────────────────────────────────────────────────────────┘  │
└──────────────┬───────────────────────────────────────────┬──────────────┘
               │ (Unmounted ESP Read)                      │ (One-Shot Set & Reboot)
               ▼                                           ▼
┌──────────────────────────────┐            ┌─────────────────────────────┐
│ /usr/local/libexec/          │            │ /etc/sudoers.d/multiboot    │
│ multiboot-efi-read (root)    │            │ (visudo-verified NOPASSWD)  │
│  └─► mtools (mdir / mcopy)   │            │  ├─► efibootmgr --bootnext  │
│      on FAT32 ESP PARTUUID   │            │  ├─► bootctl set-oneshot    │
└──────────────────────────────┘            │  └─► systemctl reboot [-f]  │
                                            └──────────────┬──────────────┘
                                                           │
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
   - Queries `efibootmgr -v` and reads `BootCurrent` plus every `BootXXXX` entry.
   - Splits the device path (`HD(...,GPT,<PARTUUID>,...)/<loader_path>`) from trailing loader options.
   - Records any `systemd-bootx64.efi` / `systemd-bootaa64.efi` entry as `SDBOOT_MANAGER_ID` so `systemd-boot` entries can be chained via `BootNext` when needed.
   - Filters out generic fallback loaders (`bootx64.efi`), shims, and firmware tools.
2. **`systemd-boot` Scan (`parse_systemd_boot_entries` & `parse_bootctl_entries`):**
   - Scans mounted ESPs for `/loader/entries/*.conf` and `/EFI/Linux/*.efi` UKIs, and queries `bootctl list` if `systemd-boot` is registered in NVRAM.
   - Deduplicates entries that appear in both NVRAM and `systemd-boot` so each unique `(PARTUUID, loader, options)` tuple is listed once.

## Phase 2 — Binary Metadata & Version Extraction

- **For Windows (`bootmgfw.efi`):**
  - Copies the binary to a temporary file (via mounted ESP or `multiboot-efi-read`).
  - Extracts `ProductVersion` / `FileVersion` strings and maps the NT major/minor/build number to `windows 11` (`build >= 22000`) or `windows 10` (`build < 22000`).
- **For Linux (`vmlinuz*` or `*.efi` UKI):**
  - Checks for DOS `MZ` (`0x4d5a`) and `PE\0\0` (`0x50450000`) headers.
  - Iterates through PE section headers looking for `.linux`. If found, reads inside the `.linux` section for the `HdrS` (`0x48647253`) setup header and extracts the exact kernel release string.
  - Falls back to standard bzImage setup header offsets (`526` + `512`), `Linux version` strings, or filename regex matching.

## Phase 3 — Query Normalization & Exact-Match Resolution

When you run `boot <query>`, `normalize_query` converts underscores and backslashes to spaces, collapses whitespace, and expands shorthand aliases (`win11` $\rightarrow$ `windows 11`, `linux-zen` $\rightarrow$ `linux zen`).

`match_target` then evaluates candidates in strict priority order:
1. **Numeric Table Index** (`1`..`10`)
2. **Exact Boot Entry ID** (`0000`, `Boot0000`, `arch-linux.conf`)
3. **Exact Full Name + Kernel Version** (`linux zen 7.3.5-zen1-1-zen`)
4. **Exact Normalized Name** (`linux zen`, `windows 11`)
5. **Exact Flavor / Family / Label / Loader Filename** (`zen`, `tkg`, `windows`)

If any tier matches more than one entry (`matches > 1`), execution aborts immediately with an ambiguity report rather than guessing.

## Phase 4 — Multi-Stage Pre-Flight Safety Verification

Before setting `BootNext` or rebooting, `verify_target` validates:
1. **UEFI Runtime:** `/sys/firmware/efi` directory exists.
2. **NVRAM State:** Target entry is marked active (`*`) in UEFI NVRAM.
3. **Partition Existence:** Target GPT `PARTUUID` resolves to a valid block device in `/dev/disk/by-partuuid/` or via `blkid`.
4. **Filesystem Integrity:** Target partition is `vfat`/`fat`/`fat32` (or `apfs`/`hfsplus` for macOS; `ext4`/`btrfs`/`xfs` for `systemd-boot` `/boot` partitions).
5. **Loader Binary Presence:** The `.efi` or `vmlinuz` file exists and has size $> 0$ bytes.
6. **Initramfs Integrity:** Every `initrd=` path referenced in decoded kernel options exists and is non-empty on the ESP.
7. **Privilege Readiness:** Passwordless `sudo` rules for `efibootmgr`, `reboot`/`systemctl`, `bootctl` (if `systemd-boot`), and `multiboot-efi-read` (if ESP is unmounted) are active and valid.

## Phase 5 — One-Shot NVRAM Programming & Reboot Execution

1. **Running Kernel Guard:** If the target is the kernel currently running, `boot` exits cleanly with a notice instead of rebooting into the same kernel.
2. **Confirmation Prompt:** Displays the resolved target name, version, and Boot ID, requiring explicit `y` or `yes` confirmation.
3. **One-Shot NVRAM Write:**
   - **UEFI Direct:** Runs `sudo -n efibootmgr --bootnext <ID>`.
   - **`systemd-boot`:** Runs `sudo -n bootctl set-oneshot <ENTRY_ID>` followed by `sudo -n efibootmgr --bootnext <SDBOOT_MANAGER_ID>`.
4. **Reboot & Rollback Safety:**
   - If `-f` was specified, `kill_desktop_applications` terminates user `app-*.scope` / `flatpak-*.scope` units and GUI window PIDs (protecting your terminal PID ancestry, shell, display manager, and Wayland/X11 compositor) before calling `systemctl reboot -f`.
   - If the reboot command fails for any reason, `boot` automatically deletes `BootNext` (`efibootmgr --delete-bootnext`) and clears `LoaderEntryOneShot` so the system is not left in a stale pending-boot state.

---

# Installation & Lifecycle Management

## Prerequisites

- **Arch Linux** (recommended) booted in **UEFI mode** via **Direct EFISTUB**
- `bash` 4.0+, `sudo`, and standard core utilities
- Required packages (auto-installed by `install.sh` if missing):
  - `efibootmgr`
  - `mtools`
  - `util-linux`
  - `binutils`

## Quick Installation

```bash
git clone [https://github.com/plopletoyay/multi-boot.git](https://github.com/plopletoyay/multi-boot.git)
cd multi-boot
chmod +x boot install.sh
./install.sh
```

Select option **`1) Install`** from the interactive menu.

## Interactive Installer Menu (`./install.sh`)

```text
========================================
        multi-boot Setup Menu
========================================
  1) Install
  2) Uninstall
  3) Status
  4) Repair
  5) Exit
```

- **`1) Install`:** Validates Direct EFISTUB environment, installs dependencies, installs `/usr/local/bin/boot`, builds `/usr/local/libexec/multiboot-efi-read`, configures `/etc/sudoers.d/multiboot` via `visudo`, and enables tab-completion for your detected shells.
- **`2) Uninstall`:** Reads `/var/lib/multiboot/install.manifest` to remove installed files and strip only the shell completion blocks added by the installer.
- **`3) Status`:** Checks overall installation state, verifies `/usr/local/bin/boot`, `/usr/local/libexec/multiboot-efi-read`, `/etc/sudoers.d/multiboot`, dependency availability, Direct EFISTUB status, and lists detected boot targets.
- **`4) Repair`:** Re-runs EFISTUB validation, overwrites `/usr/local/bin/boot` and `/usr/local/libexec/multiboot-efi-read` with clean copies, re-validates `/etc/sudoers.d/multiboot`, and repairs shell completion hooks.

---

# Usage Guide & Real-World Examples

## Command Reference

| Command | Description |
| :--- | :--- |
| `boot <OS_NAME>` | Verify target, confirm `[y/N]`, set one-shot boot, and reboot gracefully |
| `boot -f <OS_NAME>` | Verify target, confirm `[y/N]`, close open desktop apps, set one-shot boot, and force reboot |
| `boot -t <OS_NAME>` | Dry-run pre-flight verification (UEFI, NVRAM, `PARTUUID`, EFI image, `initramfs`, `sudo`) |
| `boot -l` | Display detailed table of all detected boot targets, loader paths, devices, and options |
| `boot -h` | Display compact list of installed OS/kernels (`N/10`) and command summary |

## Example 1 — Listing Available Targets (`boot -h` and `boot -l`)

```text
[polpletoyay@archlinux ~]$ boot -h
INSTALLED OS AND KERNELS (3/10)
  linux zen 7.3.5-zen1-1-zen [CURRENT] (Boot0000 | UEFI)
  linux tkg 7.3.4-273-tkg-bore (Boot0001 | UEFI)
  windows 11 10.0.28000.380 (Boot0004 | UEFI)

COMMANDS
  boot <OS_NAME>   Reboot once into the selected OS or kernel
  boot -f <OS_NAME>   Close open apps immediately and force reboot
  boot -t <OS_NAME>   Verify boot image, partition, and sudo permissions
  boot -l             Show detailed boot target table and paths
  boot -h             Show installed targets and available commands
```

```text
[polpletoyay@archlinux ~]$ boot -l
DETECTED BOOT TARGETS (3/10)

  [1] linux zen 7.3.5-zen1-1-zen  [ACTIVE] [CURRENT]
      Entry   : Boot0000 (UEFI NVRAM) — Arch Linux (linux-zen)
      Loader  : /EFI/Linux/arch-linux-zen.efi
      Device  : PARTUUID=fe124bba-2553-4935-b4fc-dff33a965b9f (vfat)

  [2] linux tkg 7.3.4-273-tkg-bore  [ACTIVE]
      Entry   : Boot0001 (UEFI NVRAM) — Arch Linux TKG-BORE
      Loader  : /EFI/Linux/vmlinuz-linux73-tkg-bore
      Device  : PARTUUID=fe124bba-2553-4935-b4fc-dff33a965b9f (vfat)
      Options : root=UUID=706840b3-9119-4305-b689-725ae64c7b38 rw initrd=\intel-ucode.img initrd=\initramfs-linux73-tkg-bore.img quiet loglevel=0 rd.udev.log_level=0 systemd.show_status=false nowatchdog nvidia-drm.modeset=1 nvidia-drm.fbdev=1

  [3] windows 11 10.0.28000.380  [ACTIVE]
      Entry   : Boot0004 (UEFI NVRAM) — Windows Boot Manager
      Loader  : /EFI/MICROSOFT/BOOT/BOOTMGFW.EFI
      Device  : PARTUUID=fe124bba-2553-4935-b4fc-dff33a965b9f (vfat)
```

## Example 2 — Pre-Flight Dry-Run Verification (`boot -t`)

```text
[polpletoyay@archlinux ~]$ boot -t windows 11
Success: 'Windows Boot Manager' (windows 11 10.0.28000.380) passed UEFI, NVRAM, PARTUUID, boot image, and privilege checks.

[polpletoyay@archlinux ~]$ boot -t linux tkg
Success: 'Arch Linux TKG-BORE' (linux tkg 7.3.4-273-tkg-bore) passed UEFI, NVRAM, PARTUUID, boot image, initramfs, and privilege checks.

[polpletoyay@archlinux ~]$ boot -t linux zen
Success: 'Arch Linux (linux-zen)' (linux zen 7.3.5-zen1-1-zen) passed UEFI, NVRAM, PARTUUID, boot image, and privilege checks.
```

## Example 3 — Ambiguity Protection & Running Kernel Guard

```text
[polpletoyay@archlinux ~]$ boot -t linux
Failed: More than one entry matches 'linux': linux zen (0000), linux tkg (0001). Specify the full name, kernel version, or boot entry ID.

[polpletoyay@archlinux ~]$ boot linux zen
You are already running linux zen (7.3.5-zen1-1-zen).
```

## Example 4 — One-Shot Reboot into Windows 11 or Another Kernel

```text
[polpletoyay@archlinux ~]$ boot windows 11
Success: 'Windows Boot Manager' (windows 11 10.0.28000.380) passed UEFI, NVRAM, PARTUUID, boot image, and privilege checks.
Boot into windows 11 (10.0.28000.380) [0004]? (y/n): y
```

---

# Troubleshooting & Installer Rejection Guide

## 1. Installer Rejects Bootloader (`GRUB`, `rEFInd`, `shim`, `systemd-boot`, or `systemd-stub` UKI)

- **Symptom:** `install.sh` refuses to install and reports that the current boot entry is managed by GRUB, rEFInd, `shim`, `systemd-boot`, or a `systemd-stub` UKI rather than Direct EFISTUB.
- **Cause:** `install.sh` enforces Direct EFISTUB verification by checking `BootCurrent` in NVRAM and inspecting the EFI binary's PE/COFF + Linux `HdrS` kernel setup header. Traditional bootloaders and intermediate stubs fail this gatekeeper check.
- **Solution:** Create a direct EFISTUB NVRAM entry for your kernel using `efibootmgr`:
  ```bash
  sudo efibootmgr --create \
    --disk /dev/nvme0n1 --part 1 \
    --label "Arch Linux" \
    --loader '\vmlinuz-linux' \
    --unicode 'root=PARTUUID=XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX rw initrd=\initramfs-linux.img'
  ```
  Reboot into that NVRAM entry so `BootCurrent` points to it, then run `./install.sh` again.

## 2. `The system is not running in UEFI mode.`

- **Cause:** The system booted via Legacy BIOS / CSM, or `efivarfs` is not mounted.
- **Solution:** Reboot into your motherboard firmware settings, disable CSM / Legacy Boot, ensure UEFI mode is active, and verify `/sys/firmware/efi` exists.

## 3. `Target partition PARTUUID=... does not exist on this system.`

- **Cause:** An orphaned NVRAM entry points to a drive or partition UUID that was formatted, recreated, or disconnected.
- **Solution:** Run `boot -l` to inspect the stale `PARTUUID`, remove or update the NVRAM entry via `efibootmgr -b <ID> -B`, and recreate it with the current ESP `PARTUUID` (`blkid`).

## 4. `The initramfs '...' is missing or inaccessible`

- **Cause:** The `initrd=` path stored in your UEFI NVRAM options or `/loader/entries/*.conf` does not match the actual filename on the ESP (for example, after switching kernels or forgetting to copy microcode/initramfs images to the ESP).
- **Solution:** Run `boot -l` to view the exact `Options` string, verify the file exists on your ESP, and update the NVRAM entry or `.conf` file if the filename changed.

## 5. `Passwordless sudo permissions are incomplete`

- **Cause:** `/etc/sudoers.d/multiboot` is missing, has incorrect permissions, or `efibootmgr`/`bootctl` binary paths changed after a system update.
- **Solution:** Run `./install.sh` and select **`4) Repair`** to regenerate and `visudo`-verify `/etc/sudoers.d/multiboot`.

## 6. `The macOS EFI file '...' could not be inspected`

- **Cause:** Linux does not have native kernel read support for Apple APFS partitions unless mounted via a FUSE driver (`apfs-fuse`).
- **Solution:** Mount the macOS Preboot/System volume read-only before running `boot -t macos`, or ensure OpenCore/Clover resides on a FAT32 EFI System Partition.

---

# Security Model & Privilege Boundaries

`multi-boot` is built around the principle of least privilege:

1. **Zero Full-Root Execution:** The `boot` CLI runs entirely as your unprivileged user account. It never asks you to run `sudo boot`.
2. **Command-Restricted Helper (`/usr/local/libexec/multiboot-efi-read`):**
   - Only accepts `exists` or `read` subcommands.
   - Enforces strict UUID regex (`^[0-9a-fA-F-]{36}$`), rejects `..` directory traversal, confirms the target device is a FAT filesystem, and runs `mtools` with `MTOOLS_SKIP_CHECK=1` in read-only mode.
3. **Granular `sudoers` Policy (`/etc/sudoers.d/multiboot`):**
   - Grants `NOPASSWD` only for explicit binary paths (`efibootmgr`, `bootctl`, `systemctl reboot`, `systemctl reboot -f`, and `multiboot-efi-read`).
   - Verified with `visudo -cf` before deployment.
4. **Manifest-Tracked Configuration Hygiene (`/var/lib/multiboot/install.manifest`):**
   - Every file created and every line appended to `.bashrc`, `.zshrc`, `config.fish`, or `config.nu` is recorded with exact markers so `Uninstall` never alters your personal dotfiles.

---

# Project Structure

```text
multi-boot/
├── boot                                   # Main CLI switcher & pre-flight validator
├── install.sh                             # 5-option interactive installer, auditor & repair tool
└── README.md                              # Documentation

# Installed System Artifacts (Tracked in /var/lib/multiboot/install.manifest)
/usr/local/bin/boot                        # Executable CLI command
/usr/local/libexec/multiboot-efi-read      # Privilege-separated FAT32 ESP reader helper
/etc/sudoers.d/multiboot                   # visudo-validated NOPASSWD policy
/var/lib/multiboot/install.manifest        # Non-destructive installation manifest
```

---

# Design Philosophy

`multi-boot` follows two core principles:

```text
Verify everything before touching NVRAM. Never alter permanent BootOrder.
```

Rebooting into another OS or experimental kernel should be fast, deterministic, and safe—without manually editing boot entries, mounting hidden EFI partitions, or risking an unbootable `BootOrder`.

---

# License & Author

Licensed under the **GNU General Public License v3.0**.

SPDX identifier:

```text
GNU General Public License v3.0
```

Created by **`plopletoyay`**

> *"Keep It Simple, Stupid."*
