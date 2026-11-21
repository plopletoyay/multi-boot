#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_SCRIPT="$SCRIPT_DIR/boot"
BIN_DIR=/usr/local/bin
BIN_PATH="$BIN_DIR/boot"
LIBEXEC_DIR=/usr/local/libexec
HELPER_PATH="$LIBEXEC_DIR/multiboot-efi-read"
SUDOERS_DIR=/etc/sudoers.d
SUDOERS_PATH="$SUDOERS_DIR/efiboot-next"
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
PASSWD_RECORD=""
if command -v getent >/dev/null 2>&1; then
    PASSWD_RECORD="$(getent passwd "$TARGET_USER" 2>/dev/null || true)"
fi
if [[ -z "$PASSWD_RECORD" ]]; then
    if [[ "$TARGET_USER" =~ ^[0-9]+$ ]]; then
        PASSWD_RECORD="$(awk -F: -v uid="$TARGET_USER" '$3 == uid { print; exit }' /etc/passwd)"
    else
        PASSWD_RECORD="$(awk -F: -v user="$TARGET_USER" '$1 == user { print; exit }' /etc/passwd)"
    fi
fi
if [[ -z "$PASSWD_RECORD" ]]; then
    printf '%s\n' "Unable to resolve the target user's account."
    exit 1
fi
TARGET_USER="${PASSWD_RECORD%%:*}"
TARGET_HOME="$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || printf '%s' "$TARGET_USER")"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/root"

FISH_DIR="$TARGET_HOME/.config/fish"
FISH_FUNC_DIR="$FISH_DIR/functions"
FISH_COMP_DIR="$FISH_DIR/completions"
FISH_DATA_DIR="$TARGET_HOME/.local/share/fish"
ZSH_COMP_DIR="$TARGET_HOME/.zsh/completions"
BASH_COMP_DIR="$TARGET_HOME/.local/share/bash-completion/completions"
NU_DIR="$TARGET_HOME/.config/nushell"
STATE_DIR="$TARGET_HOME/.local/share/multiboot"
STATE_FILE="$STATE_DIR/installed-directives"

RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
RESET=$'\033[0m'
APT_UPDATED=0
EFI_BIN=""
MCOPY_BIN=""
MDIR_BIN=""
SYSTEMCTL_BIN=""
BOOTCTL_BIN=""
REBOOT_BIN=""
VISUDO_BIN=""
BOOT_MODE=""
EFISTUB_STATUS="Not verified"
EFISTUB_REASON=""
EFISTUB_PARTUUID=""
EFISTUB_LOADER=""
EFISTUB_OPTS=""

say() {
    printf '%b\n' "$*"
}

run_root() {
    if (( EUID == 0 )); then
        "$@"
    else
        sudo "$@"
    fi
}

resolve_binary() {
    local name="$1"
    local path=""
    path="$(command -v "$name" 2>/dev/null || true)"
    if [[ -n "$path" && -x "$path" ]]; then
        printf '%s' "$path"
        return 0
    fi
    for path in "/usr/bin/$name" "/usr/sbin/$name" "/bin/$name" "/sbin/$name" "/usr/local/bin/$name" "/usr/local/sbin/$name"; do
        if [[ -x "$path" ]]; then
            printf '%s' "$path"
            return 0
        fi
    done
    return 1
}

is_installed() {
    [[ -x "$BIN_PATH" && -x "$HELPER_PATH" && -f "$SUDOERS_PATH" ]]
}

installation_state() {
    if is_installed; then
        printf 'Installed'
    elif [[ -e "$BIN_PATH" || -e "$HELPER_PATH" || -e "$SUDOERS_PATH" ]]; then
        printf 'Incomplete'
    else
        printf 'Not installed'
    fi
}

confirm_twice() {
    local first second answer
    first="$1"
    second="$2"
    say "${YELLOW}${first}${RESET}"
    printf '> '
    read -r answer || return 1
    [[ "${answer,,}" == y || "${answer,,}" == yes ]] || return 1
    say "${RED}${second}${RESET}"
    printf '> '
    read -r answer || return 1
    [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

install_package() {
    local package="$1"
    if [[ "$package" == efibootmgr ]] && resolve_binary efibootmgr >/dev/null 2>&1; then
        say "${GREEN}[+] efibootmgr is already installed.${RESET}"
        return 0
    fi
    if [[ "$package" == mtools ]] && resolve_binary mcopy >/dev/null 2>&1 && resolve_binary mdir >/dev/null 2>&1; then
        say "${GREEN}[+] mtools is already installed.${RESET}"
        return 0
    fi
    say "${YELLOW}[!] Installing package: ${package}${RESET}"
    if command -v pacman >/dev/null 2>&1; then
        run_root pacman -S --needed --noconfirm "$package"
    elif command -v apt-get >/dev/null 2>&1; then
        if (( APT_UPDATED == 0 )); then
            run_root apt-get update -qq
            APT_UPDATED=1
        fi
        run_root apt-get install -y "$package"
    elif command -v dnf >/dev/null 2>&1; then
        run_root dnf install -y "$package"
    elif command -v zypper >/dev/null 2>&1; then
        run_root zypper --non-interactive install -y "$package"
    elif command -v xbps-install >/dev/null 2>&1; then
        run_root xbps-install -Sy "$package"
    elif command -v apk >/dev/null 2>&1; then
        run_root apk add "$package"
    elif command -v yum >/dev/null 2>&1; then
        run_root yum install -y "$package"
    elif command -v emerge >/dev/null 2>&1; then
        run_root emerge --noreplace "$package"
    else
        say "${RED}[!] No supported package manager was found. Install '${package}' manually.${RESET}"
        return 1
    fi
}

validate_source() {
    if [[ ! -f "$SRC_SCRIPT" ]]; then
        say "${RED}[!] The boot script was not found beside install.sh.${RESET}"
        return 1
    fi
    if [[ "$(head -n 1 "$SRC_SCRIPT")" != '#!/usr/bin/env bash' ]]; then
        say "${RED}[!] The boot script has an invalid interpreter line.${RESET}"
        return 1
    fi
    if ! bash -n "$SRC_SCRIPT"; then
        say "${RED}[!] The boot script contains a syntax error.${RESET}"
        return 1
    fi
    if grep -nE '^[[:space:]]*#' "$SRC_SCRIPT" | grep -v '^1:#!/usr/bin/env bash$' >/dev/null 2>&1; then
        say "${RED}[!] The boot script contains a prohibited comment line.${RESET}"
        return 1
    fi
}

resolve_partuuid_device() {
    local pu="$1"
    local dev=""
    if [[ -b "/dev/disk/by-partuuid/${pu,,}" ]]; then
        printf '/dev/disk/by-partuuid/%s' "${pu,,}"
        return 0
    elif [[ -b "/dev/disk/by-partuuid/${pu^^}" ]]; then
        printf '/dev/disk/by-partuuid/%s' "${pu^^}"
        return 0
    fi
    if command -v blkid >/dev/null 2>&1; then
        dev="$(blkid -t "PARTUUID=${pu,,}" -o device 2>/dev/null | head -n 1 || true)"
        if [[ -z "$dev" ]]; then
            dev="$(blkid -t "PARTUUID=${pu^^}" -o device 2>/dev/null | head -n 1 || true)"
        fi
        if [[ -n "$dev" && -b "$dev" ]]; then
            printf '%s' "$dev"
            return 0
        fi
    fi
    return 1
}

extract_entry_loader_and_opts() {
    local entry_line="$1"
    local loader="" opts="" raw_tail="" first_token="" trimmed_loader=""
    local pattern='File\(([^)]*)\)(.*)$'
    local hd_pattern='HD\([^)]*\)/([\\/].*)$'
    if [[ "$entry_line" =~ $pattern ]]; then
        loader="${BASH_REMATCH[1]}"
        opts="${BASH_REMATCH[2]:-}"
    elif [[ "$entry_line" =~ $hd_pattern ]]; then
        raw_tail="${BASH_REMATCH[1]}"
        if [[ "$raw_tail" == *$'\t'* ]]; then
            loader="${raw_tail%%$'\t'*}"
            opts="${raw_tail#*$'\t'}"
        elif [[ "$raw_tail" =~ ^(.+\.[Ee][Ff][Ii])([[:space:]]+(.*))?$ ]]; then
            loader="${BASH_REMATCH[1]}"
            opts="${BASH_REMATCH[3]:-}"
        else
            if [[ "$raw_tail" =~ ^([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
                first_token="${BASH_REMATCH[1]}"
                opts="${BASH_REMATCH[2]:-}"
            else
                first_token="$raw_tail"
                opts=""
            fi
            if [[ "$raw_tail" =~ ^(.+)[[:space:]]+([A-Za-z0-9_.-]+=.*|rw|ro|quiet|splash|--)(.*)$ ]]; then
                trimmed_loader="${BASH_REMATCH[1]}"
                if [[ "$trimmed_loader" != *"="* ]]; then
                    loader="$trimmed_loader"
                    opts="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
                else
                    loader="$first_token"
                fi
            elif [[ "$raw_tail" != *"="* ]]; then
                loader="${raw_tail%"${raw_tail##*[![:space:]]}"}"
                opts=""
            else
                loader="$first_token"
            fi
        fi
    fi
    printf '%s\t%s' "$loader" "$opts"
}

detect_current_efistub() {
    local output current_id line current_line="" active="0" loader="" opts="" partuuid="" base="" device fstype normalized_loader loader_info_file loader_info="" is_sdboot_info=0 parsed_pair sdboot_line="" sdboot_id=""
    BOOT_MODE=""
    EFISTUB_STATUS="Not verified"
    EFISTUB_REASON=""
    EFISTUB_PARTUUID=""
    EFISTUB_LOADER=""
    EFISTUB_OPTS=""
    if [[ ! -d /sys/firmware/efi || ! -d /sys/firmware/efi/efivars ]]; then
        EFISTUB_REASON="The system is not currently booted in UEFI mode."
        return 1
    fi
    loader_info_file="/sys/firmware/efi/efivars/LoaderInfo-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    if [[ -r "$loader_info_file" ]]; then
        loader_info="$(tr -d '\0' < "$loader_info_file" 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)"
        if [[ "$loader_info" == *systemd-boot* ]]; then
            is_sdboot_info=1
        elif [[ "$loader_info" == *grub* || "$loader_info" == *refind* ]]; then
            EFISTUB_REASON="The current boot path uses an unsupported boot manager or chainloader instead of direct EFISTUB or systemd-boot."
            return 1
        fi
    fi
    EFI_BIN="$(resolve_binary efibootmgr 2>/dev/null || true)"
    if [[ -z "$EFI_BIN" ]]; then
        EFISTUB_REASON="efibootmgr is unavailable, so the current firmware boot path cannot be verified."
        return 1
    fi
    output="$("$EFI_BIN" -v 2>/dev/null || true)"
    if [[ -z "$output" && EUID -ne 0 ]]; then
        output="$(sudo -n "$EFI_BIN" -v 2>/dev/null || true)"
    fi
    current_id="$(printf '%s\n' "$output" | awk -F': *' '/^BootCurrent:/ {gsub(/[^0-9A-Fa-f]/, "", $2); print toupper($2); exit}')"
    if [[ ! "$current_id" =~ ^[[:xdigit:]]{4}$ ]]; then
        EFISTUB_REASON="The firmware did not report a readable BootCurrent entry."
        return 1
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ ^Boot${current_id}(\*)?[[:space:]]*(.*)$ ]]; then
            current_line="$line"
            [[ -n "${BASH_REMATCH[1]:-}" ]] && active="1"
            break
        fi
    done <<< "$output"
    if [[ -z "$current_line" || "$active" != "1" ]]; then
        EFISTUB_REASON="The current firmware entry Boot${current_id} could not be verified as active."
        return 1
    fi
    parsed_pair="$(extract_entry_loader_and_opts "$current_line")"
    loader="${parsed_pair%%$'\t'*}"
    opts="${parsed_pair#*$'\t'}"
    if [[ "$current_line" =~ [Gg][Pp][Tt],([[:xdigit:]-]{36}) ]]; then
        partuuid="${BASH_REMATCH[1]}"
    fi
    loader="${loader//\\//}"
    while [[ "$loader" == *"//"* ]]; do
        loader="${loader//\/\//\/}"
    done
    normalized_loader="${loader,,}"
    base="${normalized_loader##*/}"
    if [[ "$base" == systemd-bootx64.efi || "$base" == systemd-bootaa64.efi || "$base" == systemd-bootia32.efi || "$is_sdboot_info" == "1" ]]; then
        if [[ "$base" != systemd-bootx64.efi && "$base" != systemd-bootaa64.efi && "$base" != systemd-bootia32.efi ]]; then
            while IFS= read -r line; do
                if [[ "$line" =~ ^Boot([[:xdigit:]]{4})\*[[:space:]]+.*[Ss][Yy][Ss][Tt][Ee][Mm][Dd]-[Bb][Oo][Oo][Tt]([Xx]64|[Aa][Aa]64|[Ii][Aa]32)\.[Ee][Ff][Ii] ]]; then
                    sdboot_id="${BASH_REMATCH[1]^^}"
                    sdboot_line="$line"
                    break
                fi
            done <<< "$output"
            if [[ -z "$sdboot_line" ]]; then
                EFISTUB_REASON="systemd-boot is active, but no active UEFI NVRAM entry for systemd-boot was found."
                return 1
            fi
            current_id="$sdboot_id"
            current_line="$sdboot_line"
            parsed_pair="$(extract_entry_loader_and_opts "$current_line")"
            loader="${parsed_pair%%$'\t'*}"
            opts="${parsed_pair#*$'\t'}"
            loader="${loader//\\//}"
            while [[ "$loader" == *"//"* ]]; do
                loader="${loader//\/\//\/}"
            done
            partuuid=""
            if [[ "$current_line" =~ [Gg][Pp][Tt],([[:xdigit:]-]{36}) ]]; then
                partuuid="${BASH_REMATCH[1]}"
            fi
        fi
        device=""
        if [[ -n "$partuuid" ]]; then
            device="$(resolve_partuuid_device "$partuuid" || true)"
        fi
        if [[ -z "$loader" || -z "$partuuid" || -z "$device" ]]; then
            EFISTUB_REASON="Boot${current_id} does not resolve to an existing GPT-backed systemd-boot EFI image."
            return 1
        fi
        fstype="$(lsblk -dnro FSTYPE "$device" 2>/dev/null | head -n 1 || true)"
        if [[ -z "$fstype" ]]; then
            fstype="$(blkid -o value -s TYPE "$device" 2>/dev/null | head -n 1 || true)"
        fi
        case "${fstype,,}" in
            vfat|fat|fat32) ;;
            *)
                EFISTUB_REASON="The systemd-boot image is not on a recognized FAT EFI partition. Detected filesystem: ${fstype:-unknown}."
                return 1
                ;;
        esac
        BOOT_MODE="systemd-boot"
        EFISTUB_PARTUUID="${partuuid,,}"
        EFISTUB_LOADER="$loader"
        EFISTUB_OPTS="$opts"
        EFISTUB_STATUS="Preliminary"
        EFISTUB_REASON="Boot${current_id} points to systemd-boot (${loader}) on PARTUUID=${partuuid}."
        return 0
    fi
    device=""
    if [[ -n "$partuuid" ]]; then
        device="$(resolve_partuuid_device "$partuuid" || true)"
    fi
    if [[ -z "$loader" || -z "$partuuid" || -z "$device" ]]; then
        EFISTUB_REASON="Boot${current_id} does not resolve to an existing GPT-backed EFI image."
        return 1
    fi
    fstype="$(lsblk -dnro FSTYPE "$device" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$fstype" ]]; then
        fstype="$(blkid -o value -s TYPE "$device" 2>/dev/null | head -n 1 || true)"
    fi
    case "${fstype,,}" in
        vfat|fat|fat32) ;;
        *)
            EFISTUB_REASON="The current EFI-stub image is not on a recognized FAT EFI partition. Detected filesystem: ${fstype:-unknown}."
            return 1
            ;;
    esac
    case "$base" in
        shim*.efi|grub*.efi|refind*.efi|systemd-boot*.efi|bootx64.efi|bootaa64.efi|bootia32.efi|bootmgfw.efi|boot.efi|opencore*.efi|clover*.efi)
            EFISTUB_REASON="The current boot path uses a boot manager or chainloader instead of direct EFISTUB or systemd-boot."
            return 1
            ;;
    esac
    BOOT_MODE="efistub"
    EFISTUB_PARTUUID="${partuuid,,}"
    EFISTUB_LOADER="$loader"
    EFISTUB_OPTS="$opts"
    EFISTUB_STATUS="Preliminary"
    EFISTUB_REASON="Boot${current_id} points directly to ${loader} on PARTUUID=${partuuid}."
    return 0
}

read_u16_le() {
    local file="$1"
    local offset="$2"
    local -a bytes=()
    mapfile -t bytes < <(od -An -tu1 -j"$offset" -N2 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
    if (( ${#bytes[@]} != 2 )); then
        return 1
    fi
    printf '%d' $(( bytes[0] + (bytes[1] << 8) ))
}

read_u32_le() {
    local file="$1"
    local offset="$2"
    local -a bytes=()
    mapfile -t bytes < <(od -An -tu1 -j"$offset" -N4 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
    if (( ${#bytes[@]} != 4 )); then
        return 1
    fi
    printf '%d' $(( bytes[0] + (bytes[1] << 8) + (bytes[2] << 16) + (bytes[3] << 24) ))
}

inspect_pe_sections() {
    local file="$1"
    local pe_offset="$2"
    local size="$3"
    local num_sections opt_header_size section_table_offset idx sec_off sec_name raw_size raw_ptr
    num_sections="$(read_u16_le "$file" $((pe_offset + 6)) || printf '0')"
    opt_header_size="$(read_u16_le "$file" $((pe_offset + 20)) || printf '0')"
    section_table_offset=$((pe_offset + 24 + opt_header_size))
    (( num_sections > 0 && num_sections <= 64 )) || return 0
    for ((idx = 0; idx < num_sections; idx++)); do
        sec_off=$((section_table_offset + idx * 40))
        (( sec_off + 24 <= size )) || break
        sec_name="$(dd if="$file" bs=1 skip="$sec_off" count=8 2>/dev/null | tr -d '\000' || true)"
        raw_size="$(read_u32_le "$file" $((sec_off + 16)) || printf '0')"
        raw_ptr="$(read_u32_le "$file" $((sec_off + 20)) || printf '0')"
        printf '%s:%s:%s\n' "$sec_name" "$raw_ptr" "$raw_size"
    done
}

verify_current_efistub_file() {
    local device relative temporary size pe_offset pe_signature setup_magic zboot_magic arm64_magic riscv_magic zboot_comp kernel_offset kernel_version mnt loaded_from_mount=0 sections strings_dump cmdline_now opt_token matched_opts=0 resolved_mount_file part found linux_sec_line linux_ptr linux_size inner_setup_magic inner_zboot_magic inner_arm64_magic inner_riscv_magic
    local -a parts=()
    device="$(resolve_partuuid_device "$EFISTUB_PARTUUID" || true)"
    relative="${EFISTUB_LOADER//\\//}"
    while [[ "$relative" == *"//"* ]]; do
        relative="${relative//\/\//\/}"
    done
    relative="${relative#/}"
    [[ -b "$device" && -n "$relative" ]] || return 1
    [[ "$relative" =~ ^[A-Za-z0-9._/+@\ -]+$ ]] || return 1
    case "/$relative/" in
        */../*) return 1 ;;
    esac
    temporary="$(mktemp)" || return 1
    mnt="$(findmnt -rn -o TARGET "$device" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$mnt" && -d "$mnt" ]]; then
        if [[ -r "$mnt/$relative" ]]; then
            if cp -f "$mnt/$relative" "$temporary" 2>/dev/null; then
                loaded_from_mount=1
            fi
        else
            resolved_mount_file="$mnt"
            IFS='/' read -ra parts <<< "$relative"
            for part in "${parts[@]}"; do
                [[ -z "$part" ]] && continue
                found="$(find "$resolved_mount_file" -maxdepth 1 -iname "$part" 2>/dev/null | head -n 1 || true)"
                if [[ -z "$found" ]]; then
                    resolved_mount_file=""
                    break
                fi
                resolved_mount_file="$found"
            done
            if [[ -n "$resolved_mount_file" && -r "$resolved_mount_file" ]]; then
                if cp -f "$resolved_mount_file" "$temporary" 2>/dev/null; then
                    loaded_from_mount=1
                fi
            fi
        fi
    fi
    if (( loaded_from_mount == 0 )); then
        if (( EUID == 0 )); then
            if ! MTOOLS_SKIP_CHECK=1 "$MCOPY_BIN" -n -i "$device" "::/$relative" - > "$temporary" 2>/dev/null; then
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI image '${EFISTUB_LOADER}' could not be read from PARTUUID=${EFISTUB_PARTUUID}."
                return 1
            fi
        elif [[ -x "$HELPER_PATH" ]]; then
            if ! sudo -n "$HELPER_PATH" read "$EFISTUB_PARTUUID" "$relative" > "$temporary" 2>/dev/null; then
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI image '${EFISTUB_LOADER}' could not be read through the privileged EFI reader helper."
                return 1
            fi
        else
            if ! sudo -n env MTOOLS_SKIP_CHECK=1 "$MCOPY_BIN" -n -i "$device" "::/$relative" - > "$temporary" 2>/dev/null; then
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI image '${EFISTUB_LOADER}' could not be read from PARTUUID=${EFISTUB_PARTUUID} without a password prompt."
                return 1
            fi
        fi
    fi
    size="$(wc -c < "$temporary" | tr -d '[:space:]')"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1024 )); then
        rm -f "$temporary"
        EFISTUB_REASON="The current EFI image is empty or too small to be a valid EFI executable."
        return 1
    fi
    if [[ "$(od -An -tx1 -N2 "$temporary" 2>/dev/null | tr -d '[:space:]')" != "4d5a" ]]; then
        rm -f "$temporary"
        EFISTUB_REASON="The current firmware image does not have a valid PE/COFF DOS header."
        return 1
    fi
    pe_offset="$(read_u32_le "$temporary" 60 || printf '0')"
    if (( pe_offset < 64 || pe_offset + 24 > size )); then
        rm -f "$temporary"
        EFISTUB_REASON="The current EFI image has an invalid or out-of-range PE header offset."
        return 1
    fi
    pe_signature="$(od -An -tx1 -j "$pe_offset" -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$pe_signature" != "50450000" ]]; then
        rm -f "$temporary"
        EFISTUB_REASON="The current EFI image does not contain a valid PE/COFF signature."
        return 1
    fi
    if [[ "$BOOT_MODE" == "systemd-boot" ]]; then
        strings_dump="$(tr -d '\000' < "$temporary" 2>/dev/null || true)"
        rm -f "$temporary"
        if ! printf '%s' "$strings_dump" | grep -aEq 'systemd-boot'; then
            EFISTUB_REASON="The target EFI binary at ${EFISTUB_LOADER} could not be verified as systemd-boot."
            return 1
        fi
        EFISTUB_STATUS="Confirmed"
        EFISTUB_REASON="BootCurrent resolves to a readable systemd-boot binary at ${EFISTUB_LOADER} on PARTUUID=${EFISTUB_PARTUUID}."
        return 0
    fi
    sections="$(inspect_pe_sections "$temporary" "$pe_offset" "$size")"
    setup_magic="$(od -An -tx1 -j514 -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
    zboot_magic="$(od -An -tx1 -j4 -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
    arm64_magic="$(od -An -tx1 -j56 -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
    riscv_magic="$(od -An -tx1 -j56 -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
    kernel_version=""
    linux_sec_line="$(printf '%s\n' "$sections" | grep -E '^\.linux:[0-9]+:[0-9]+$' | head -n 1 || true)"
    if [[ -n "$linux_sec_line" ]]; then
        IFS=':' read -r _ linux_ptr linux_size <<< "$linux_sec_line"
        if (( linux_ptr > 0 && linux_size >= 1024 && linux_ptr + linux_size <= size )); then
            inner_setup_magic="$(od -An -tx1 -j $((linux_ptr + 514)) -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
            inner_zboot_magic="$(od -An -tx1 -j $((linux_ptr + 4)) -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
            inner_arm64_magic="$(od -An -tx1 -j $((linux_ptr + 56)) -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
            inner_riscv_magic="$(od -An -tx1 -j $((linux_ptr + 56)) -N4 "$temporary" 2>/dev/null | tr -d '[:space:]')"
            if [[ "$inner_setup_magic" == "48647253" ]]; then
                kernel_offset="$(read_u16_le "$temporary" $((linux_ptr + 526)) || printf '0')"
                if (( kernel_offset > 0 && linux_ptr + kernel_offset + 512 < size )); then
                    kernel_version="$(dd if="$temporary" bs=1 skip=$((linux_ptr + kernel_offset + 512)) count=96 2>/dev/null | tr -d '\000' | awk '{print $1}' || true)"
                fi
            elif [[ "$inner_zboot_magic" == "7a696d67" ]]; then
                zboot_comp="$(dd if="$temporary" bs=1 skip=$((linux_ptr + 24)) count=8 2>/dev/null | tr -d '\000' | tr '[:upper:]' '[:lower:]' || true)"
                case "$zboot_comp" in
                    gzip|zstd|lz4|lzma|lzo|xzkern|uncomp)
                        kernel_version="$(uname -r)"
                        ;;
                esac
            elif [[ "$inner_arm64_magic" == "41524d64" || "$inner_riscv_magic" == "52534305" ]]; then
                kernel_version="$(uname -r)"
            fi
            if [[ -z "$kernel_version" ]]; then
                kernel_version="$(tail -c +$((linux_ptr + 1)) "$temporary" 2>/dev/null | head -c "$linux_size" | tr -d '\000' | grep -aoE 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -n 1 | awk '{print $3}' || true)"
                [[ -n "$kernel_version" ]] || kernel_version="$(uname -r)"
            fi
        else
            rm -f "$temporary"
            EFISTUB_REASON="The current UKI image has an invalid embedded .linux section."
            return 1
        fi
    elif printf '%s\n' "$sections" | grep -Eqx '\.(osrel|initrd|cmdline)'; then
        rm -f "$temporary"
        EFISTUB_REASON="The current PE image contains UKI metadata sections without a valid .linux kernel payload."
        return 1
    elif [[ "$setup_magic" == "48647253" ]]; then
        kernel_offset="$(read_u16_le "$temporary" 526 || printf '0')"
        if (( kernel_offset > 0 && kernel_offset + 512 < size )); then
            kernel_version="$(dd if="$temporary" bs=1 skip=$((kernel_offset + 512)) count=96 2>/dev/null | tr -d '\000' | awk '{print $1}' || true)"
        fi
        if [[ ! "$kernel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            rm -f "$temporary"
            EFISTUB_REASON="The current PE image does not contain a verifiable Linux kernel setup-header version."
            return 1
        fi
    elif [[ "$zboot_magic" == "7a696d67" ]]; then
        zboot_comp="$(dd if="$temporary" bs=1 skip=24 count=8 2>/dev/null | tr -d '\000' | tr '[:upper:]' '[:lower:]' || true)"
        case "$zboot_comp" in
            gzip|zstd|lz4|lzma|lzo|xzkern|uncomp)
                kernel_version="$(uname -r)"
                ;;
            *)
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI zboot image has an unrecognized compression header."
                return 1
                ;;
        esac
    elif [[ "$arm64_magic" == "41524d64" || "$riscv_magic" == "52534305" ]]; then
        kernel_version="$(uname -r)"
    else
        strings_dump="$(tr -d '\000' < "$temporary" 2>/dev/null || true)"
        if printf '%s' "$strings_dump" | grep -aEq 'GNU GRUB|grub_efi_|rEFInd|systemd-boot|shim_lock|bootmgfw\.pdb'; then
            rm -f "$temporary"
            EFISTUB_REASON="The current PE image is a boot manager or chainloader, not a direct Linux EFISTUB kernel image."
            return 1
        fi
        if printf '%s' "$strings_dump" | grep -aEq 'EFI stub:|efi_pe_entry|Linux version [0-9]+\.[0-9]+\.[0-9]+'; then
            kernel_version="$(printf '%s' "$strings_dump" | grep -aoE 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -n 1 | awk '{print $3}' || true)"
            [[ -n "$kernel_version" ]] || kernel_version="$(uname -r)"
        else
            cmdline_now="$(cat /proc/cmdline 2>/dev/null || true)"
            for opt_token in $EFISTUB_OPTS; do
                if [[ "$opt_token" == *=* && "$cmdline_now" == *"$opt_token"* ]]; then
                    matched_opts=1
                    break
                fi
            done
            if (( matched_opts == 1 )); then
                kernel_version="$(uname -r)"
            else
                rm -f "$temporary"
                EFISTUB_REASON="The current PE image is not a direct Linux EFISTUB kernel image."
                return 1
            fi
        fi
    fi
    rm -f "$temporary"
    EFISTUB_STATUS="Confirmed"
    EFISTUB_REASON="BootCurrent resolves to a readable Linux EFI-stub image (${kernel_version}) at ${EFISTUB_LOADER} on PARTUUID=${EFISTUB_PARTUUID}."
    return 0
}

prepare_dependencies() {
    if [[ ! -d /sys/firmware/efi ]]; then
        say "${RED}[!] Multi Boot requires UEFI mode. Installation stopped.${RESET}"
        return 1
    fi
    if ! resolve_binary efibootmgr >/dev/null 2>&1; then
        if ! install_package efibootmgr; then
            say "${RED}[!] Unable to install efibootmgr. Installation stopped.${RESET}"
            return 1
        fi
    fi
    EFI_BIN="$(resolve_binary efibootmgr 2>/dev/null || true)"
    if [[ -z "$EFI_BIN" ]]; then
        say "${RED}[!] efibootmgr is still unavailable. Installation stopped.${RESET}"
        return 1
    fi
    if ! detect_current_efistub; then
        say "${RED}[!] Boot verification failed: ${EFISTUB_REASON}${RESET}"
        say "${RED}Multi Boot can only be installed while booted via direct EFISTUB or systemd-boot. GRUB, rEFInd, and shim are not accepted as the current boot path.${RESET}"
        say "${RED}Installation stopped. No Multi Boot files or sudoers rules were changed.${RESET}"
        return 1
    fi
    BOOTCTL_BIN="$(resolve_binary bootctl 2>/dev/null || true)"
    if [[ "$BOOT_MODE" == "systemd-boot" && -z "$BOOTCTL_BIN" ]]; then
        say "${RED}[!] bootctl is required for systemd-boot support, but it is unavailable. Installation stopped.${RESET}"
        return 1
    fi
    if ! install_package mtools; then
        say "${RED}[!] Unable to install mtools. Installation stopped.${RESET}"
        return 1
    fi
    MCOPY_BIN="$(resolve_binary mcopy 2>/dev/null || true)"
    MDIR_BIN="$(resolve_binary mdir 2>/dev/null || true)"
    if [[ -z "$MCOPY_BIN" || -z "$MDIR_BIN" ]]; then
        say "${RED}[!] mcopy and mdir are required. Installation stopped.${RESET}"
        return 1
    fi
    if ! verify_current_efistub_file; then
        say "${RED}[!] Boot verification failed: ${EFISTUB_REASON}${RESET}"
        say "${RED}Multi Boot only supports a verified direct EFISTUB kernel or systemd-boot manager. Installation stopped. No Multi Boot files or sudoers rules were changed.${RESET}"
        return 1
    fi
    if [[ "$BOOT_MODE" == "systemd-boot" ]]; then
        say "${GREEN}[+] systemd-boot confirmed: ${EFISTUB_REASON}${RESET}"
    else
        say "${GREEN}[+] Direct EFISTUB boot confirmed: ${EFISTUB_REASON}${RESET}"
    fi
    SYSTEMCTL_BIN="$(resolve_binary systemctl 2>/dev/null || true)"
    [[ -d /run/systemd/system ]] || SYSTEMCTL_BIN=""
    REBOOT_BIN="$(resolve_binary reboot 2>/dev/null || true)"
    VISUDO_BIN="$(resolve_binary visudo 2>/dev/null || true)"
    if [[ -z "$VISUDO_BIN" ]]; then
        say "${YELLOW}[!] visudo is missing. Installing the sudo package for secure sudoers validation.${RESET}"
        if ! install_package sudo; then
            say "${RED}[!] Unable to install sudo. visudo is required to validate the sudoers configuration.${RESET}"
            return 1
        fi
        VISUDO_BIN="$(resolve_binary visudo 2>/dev/null || true)"
    fi
    if [[ -z "$VISUDO_BIN" ]]; then
        say "${RED}[!] visudo is still unavailable. Installation stopped.${RESET}"
        return 1
    fi
}

create_efi_reader_helper() {
    local temporary
    temporary="$(mktemp)"
    printf '%b\n' '\043!/usr/bin/env bash' > "$temporary"
    cat >> "$temporary" <<EOF_HELPER
set -Eeuo pipefail
export MTOOLS_SKIP_CHECK=1
MCOPY_BIN=$(printf '%q' "$MCOPY_BIN")
MDIR_BIN=$(printf '%q' "$MDIR_BIN")
if (( \$# != 3 )); then
    exit 2
fi
operation="\$1"
partuuid="\${2,,}"
relative="\${3//\\\\//}"
relative="\${relative#/}"
[[ "\$partuuid" =~ ^[[:xdigit:]-]{36}$ ]] || exit 2
[[ "\$relative" =~ ^[A-Za-z0-9._/+@\ -]+$ ]] || exit 2
case "/\$relative/" in
    */../*) exit 2 ;;
esac
device="/dev/disk/by-partuuid/\$partuuid"
[[ -b "\$device" ]] || exit 1
case "\$operation" in
    exists)
        [[ -x "\$MDIR_BIN" ]] || exit 1
        parent="\${relative%/*}"
        basename="\${relative##*/}"
        if [[ "\$parent" == "\$relative" ]]; then
            parent=""
        fi
        if [[ -n "\$parent" ]]; then
            listing="\$("\$MDIR_BIN" -b -i "\$device" "::/\$parent" 2>/dev/null)" || exit 1
        else
            listing="\$("\$MDIR_BIN" -b -i "\$device" ::/ 2>/dev/null)" || exit 1
        fi
        printf '%s\\n' "\$listing" | grep -Fxi -- "\$basename" >/dev/null
        ;;
    read)
        [[ -x "\$MCOPY_BIN" ]] || exit 1
        exec "\$MCOPY_BIN" -n -i "\$device" "::/\$relative" -
        ;;
    *)
        exit 2
        ;;
esac
EOF_HELPER
    if ! bash -n "$temporary"; then
        rm -f "$temporary"
        say "${RED}[!] The EFI reader helper failed syntax validation.${RESET}"
        return 1
    fi
    if ! run_root install -d -m 755 -o root -g root "$LIBEXEC_DIR"; then
        rm -f "$temporary"
        return 1
    fi
    if ! run_root install -m 755 -o root -g root "$temporary" "$HELPER_PATH"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    return 0
}

create_sudoers_rule() {
    local temporary visudo_output su_bad_lines other_bad_lines candidate real_candidate seen_paths="|" commands=""
    local -a efi_bins=() systemctl_bins=() reboot_bins=() bootctl_bins=()
    temporary="$(mktemp)"
    local boot_id_pattern="[0123456789abcdefABCDEF][0123456789abcdefABCDEF][0123456789abcdefABCDEF][0123456789abcdefABCDEF]"
    for candidate in "$EFI_BIN" /usr/bin/efibootmgr /usr/sbin/efibootmgr /bin/efibootmgr /sbin/efibootmgr; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
            seen_paths+="${candidate}|"
            efi_bins+=("$candidate")
        fi
        real_candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
        if [[ -n "$real_candidate" && -x "$real_candidate" && "$seen_paths" != *"|${real_candidate}|"* ]]; then
            seen_paths+="${real_candidate}|"
            efi_bins+=("$real_candidate")
        fi
    done
    if (( ${#efi_bins[@]} == 0 )); then
        rm -f "$temporary"
        say "${RED}[!] No usable efibootmgr binary was found.${RESET}"
        return 1
    fi
    for candidate in "${efi_bins[@]}"; do
        commands+="${candidate}, ${candidate} -v, ${candidate} -n ${boot_id_pattern}, ${candidate} --bootnext ${boot_id_pattern}, ${candidate} -N, ${candidate} --delete-bootnext, "
    done
    commands+="${HELPER_PATH} *"
    seen_paths="|"
    if [[ -n "$SYSTEMCTL_BIN" ]]; then
        for candidate in "$SYSTEMCTL_BIN" /usr/bin/systemctl /bin/systemctl /usr/sbin/systemctl /sbin/systemctl; do
            [[ -n "$candidate" && -x "$candidate" ]] || continue
            if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
                seen_paths+="${candidate}|"
                systemctl_bins+=("$candidate")
            fi
            real_candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
            if [[ -n "$real_candidate" && -x "$real_candidate" && "$seen_paths" != *"|${real_candidate}|"* ]]; then
                seen_paths+="${real_candidate}|"
                systemctl_bins+=("$real_candidate")
            fi
        done
        for candidate in "${systemctl_bins[@]}"; do
            commands+=", ${candidate} reboot, ${candidate} reboot -f, ${candidate} reboot --no-block, ${candidate} reboot -f --no-block"
        done
    fi
    seen_paths="|"
    if [[ -n "$REBOOT_BIN" ]]; then
        for candidate in "$REBOOT_BIN" /usr/sbin/reboot /sbin/reboot /usr/bin/reboot /bin/reboot; do
            [[ -n "$candidate" && -x "$candidate" ]] || continue
            if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
                seen_paths+="${candidate}|"
                reboot_bins+=("$candidate")
            fi
            real_candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
            if [[ -n "$real_candidate" && -x "$real_candidate" && "$seen_paths" != *"|${real_candidate}|"* ]]; then
                seen_paths+="${real_candidate}|"
                reboot_bins+=("$real_candidate")
            fi
        done
        for candidate in "${reboot_bins[@]}"; do
            commands+=", ${candidate}, ${candidate} -f"
        done
    fi
    if (( ${#systemctl_bins[@]} == 0 && ${#reboot_bins[@]} == 0 )); then
        rm -f "$temporary"
        say "${RED}[!] No supported reboot command was found.${RESET}"
        return 1
    fi
    seen_paths="|"
    if [[ -n "$BOOTCTL_BIN" ]]; then
        for candidate in "$BOOTCTL_BIN" /usr/bin/bootctl /bin/bootctl /usr/sbin/bootctl /sbin/bootctl; do
            [[ -n "$candidate" && -x "$candidate" ]] || continue
            if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
                seen_paths+="${candidate}|"
                bootctl_bins+=("$candidate")
            fi
            real_candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
            if [[ -n "$real_candidate" && -x "$real_candidate" && "$seen_paths" != *"|${real_candidate}|"* ]]; then
                seen_paths+="${real_candidate}|"
                bootctl_bins+=("$real_candidate")
            fi
        done
        for candidate in "${bootctl_bins[@]}"; do
            commands+=", ${candidate} set-oneshot *"
        done
    fi
    printf '%s ALL=(root) NOPASSWD: %s\n' "$TARGET_USER" "$commands" > "$temporary"
    if ! visudo_output="$(run_root "$VISUDO_BIN" -cf "$temporary" 2>&1)"; then
        rm -f "$temporary"
        say "${RED}[!] The sudoers rule failed visudo validation: ${visudo_output}${RESET}"
        return 1
    fi
    if ! run_root install -d -m 755 -o root -g root "$SUDOERS_DIR"; then
        rm -f "$temporary"
        return 1
    fi
    if ! run_root install -m 440 -o root -g root "$temporary" "$SUDOERS_PATH"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    if ! visudo_output="$(run_root "$VISUDO_BIN" -cf "$SUDOERS_PATH" 2>&1)"; then
        run_root rm -f "$SUDOERS_PATH"
        say "${RED}[!] The installed sudoers rule failed validation: ${visudo_output}${RESET}"
        return 1
    fi
    if ! visudo_output="$(run_root "$VISUDO_BIN" -c 2>&1)"; then
        su_bad_lines="$(printf '%s\n' "$visudo_output" | grep -F "$SUDOERS_PATH" | grep -Fv ': parsed OK' || true)"
        if [[ -n "$su_bad_lines" ]]; then
            run_root rm -f "$SUDOERS_PATH"
            say "${RED}[!] The active sudoers configuration failed validation: ${su_bad_lines}${RESET}"
            return 1
        fi
        other_bad_lines="$(printf '%s\n' "$visudo_output" | grep -Fv ': parsed OK' | tr '\n' ' ' || true)"
        say "${YELLOW}[!] Warning: An unrelated sudoers file reported an issue (${other_bad_lines}), but ${SUDOERS_PATH} is valid.${RESET}"
    fi
    if [[ -f /etc/sudoers ]] && ! run_root grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d/?([[:space:]]|$)' /etc/sudoers 2>/dev/null; then
        say "${YELLOW}[!] Warning: /etc/sudoers does not appear to include /etc/sudoers.d; passwordless sudo may require enabling @includedir /etc/sudoers.d.${RESET}"
    fi
}

write_user_file() {
    local source="$1"
    local destination="$2"
    local mode="${3:-644}"
    if ! mkdir -p "$(dirname "$destination")"; then
        return 1
    fi
    if ! cat > "$destination" <<< "$source"; then
        return 1
    fi
    if (( EUID == 0 )) && ! chown "$TARGET_USER:$TARGET_GROUP" "$(dirname "$destination")" "$destination"; then
        return 1
    fi
    chmod "$mode" "$destination"
}

append_unique_line() {
    local file="$1"
    local line="$2"
    local marker="${3:-}"
    mkdir -p "$(dirname "$file")" || return 1
    touch "$file" || return 1
    if (( EUID == 0 )) && ! chown "$TARGET_USER:$TARGET_GROUP" "$file"; then
        return 1
    fi
    if ! grep -Fqx -- "$line" "$file"; then
        printf '%s\n' "$line" >> "$file" || return 1
        [[ -n "$marker" ]] && record_added_directive "$marker"
    fi
    if (( EUID == 0 )) && ! chown "$TARGET_USER:$TARGET_GROUP" "$file"; then
        return 1
    fi
}

record_added_directive() {
    local marker="$1"
    mkdir -p "$STATE_DIR" || return 1
    touch "$STATE_FILE" || return 1
    if ! grep -Fqx -- "$marker" "$STATE_FILE"; then
        printf '%s\n' "$marker" >> "$STATE_FILE" || return 1
    fi
    if (( EUID == 0 )); then
        chown "$TARGET_USER:$TARGET_GROUP" "$STATE_DIR" "$STATE_FILE" || return 1
    fi
}

prepend_unique_line() {
    local file="$1"
    local line="$2"
    local marker="${3:-}"
    local temporary
    mkdir -p "$(dirname "$file")" || return 1
    touch "$file" || return 1
    if ! grep -Fqx -- "$line" "$file"; then
        temporary="$(mktemp)" || return 1
        if ! printf '%s\n' "$line" > "$temporary" || ! cat "$file" >> "$temporary" || ! cat "$temporary" > "$file"; then
            rm -f "$temporary"
            return 1
        fi
        rm -f "$temporary"
        [[ -n "$marker" ]] && record_added_directive "$marker"
    fi
    if (( EUID == 0 )) && ! chown "$TARGET_USER:$TARGET_GROUP" "$file"; then
        return 1
    fi
}

remove_exact_line() {
    local file="$1"
    local line="$2"
    local temporary
    [[ -f "$file" ]] || return 0
    temporary="$(mktemp)" || return 1
    if ! awk -v target="$line" '$0 != target' "$file" > "$temporary" || ! cat "$temporary" > "$file"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    if (( EUID == 0 )) && ! chown "$TARGET_USER:$TARGET_GROUP" "$file"; then
        return 1
    fi
}

configure_shells() {
    local fish_function fish_completion zsh_completion bash_completion nu_completion profile_file bashrc zshrc nu_config fish_history timestamp target configured_list=""
    local -a targets=()
    mapfile -t targets < <("$BIN_PATH" --complete 2>/dev/null || true)

    if command -v fish >/dev/null 2>&1 || [[ -d "$FISH_DIR" ]]; then
        fish_function="function boot --wraps=$BIN_PATH --description 'Multi Boot UEFI switcher'
    command $BIN_PATH \$argv
end"
        fish_completion="complete -c boot -f
complete -c boot -s h -l help -d 'Show detected operating systems and commands'
complete -c boot -s l -l list -d 'List detected boot targets'
complete -c boot -s t -l test -d 'Test a boot target without rebooting'
complete -c boot -s f -l force -d 'Force close desktop applications and reboot'
complete -c boot -a '($BIN_PATH --complete 2>/dev/null | string escape --no-quoted)'"
        write_user_file "$fish_function" "$FISH_FUNC_DIR/boot.fish" || return 1
        write_user_file "$fish_completion" "$FISH_COMP_DIR/boot.fish" || return 1
        mkdir -p "$FISH_DATA_DIR" || return 1
        fish_history="$FISH_DATA_DIR/fish_history"
        touch "$fish_history" || return 1
        timestamp="$(date +%s)"
        for target in "${targets[@]:-}"; do
            [[ -n "$target" ]] || continue
            local history_command="boot '$target'"
            if ! grep -Fq -- "- cmd: $history_command" "$fish_history"; then
                printf -- "- cmd: %s\n  when: %s\n" "$history_command" "$timestamp" >> "$fish_history" || return 1
            fi
        done
        if (( EUID == 0 )); then
            chown "$TARGET_USER:$TARGET_GROUP" "$fish_history" || return 1
        fi
        configured_list+="Fish, "
    fi

    if command -v zsh >/dev/null 2>&1 || [[ -f "$TARGET_HOME/.zshrc" || -d "$TARGET_HOME/.zsh" ]]; then
        zsh_completion="_boot() {
    local -a targets options
    targets=(\${(@f)\$(command $BIN_PATH --complete 2>/dev/null)})
    options=('-h:Show help' '-l:List boot targets' '-t:Test without rebooting' '-f:Force reboot')
    _describe 'boot options' options
    _describe 'boot targets' targets
}
compdef _boot boot"
        write_user_file "$zsh_completion" "$ZSH_COMP_DIR/_boot" || return 1
        zshrc="$TARGET_HOME/.zshrc"
        prepend_unique_line "$zshrc" "fpath=(\"$ZSH_COMP_DIR\" \$fpath)" zsh-fpath || return 1
        append_unique_line "$zshrc" 'autoload -Uz compinit && compinit' zsh-compinit || return 1
        append_unique_line "$zshrc" 'compdef _boot boot' zsh-compdef || return 1
        configured_list+="Zsh, "
    fi

    if command -v bash >/dev/null 2>&1 || [[ -f "$TARGET_HOME/.bashrc" ]]; then
        bash_completion="_boot_complete() {
    local current=\"\${COMP_WORDS[COMP_CWORD]}\" candidate word prefix=\"\"
    local index
    local -a options typed
    options=(-h --help -l --list -t --test -f --force)
    typed=()
    COMPREPLY=()
    if (( COMP_CWORD == 1 )); then
        for candidate in \"\${options[@]}\"; do
            [[ \"\$candidate\" == \"\$current\"* ]] && COMPREPLY+=(\"\$candidate\")
        done
    fi
    for ((index=1; index<COMP_CWORD; index++)); do
        word=\"\${COMP_WORDS[index]}\"
        case \"\$word\" in
            -f|--force|-t|--test) ;;
            *) typed+=(\"\$word\") ;;
        esac
    done
    if (( \${#typed[@]} > 0 )); then
        prefix=\"\${typed[*]} \"
    fi
    prefix+=\"\$current\"
    while IFS= read -r candidate; do
        [[ \"\$candidate\" == \"\$prefix\"* ]] || continue
        if (( \${#typed[@]} > 0 )); then
            candidate=\"\${candidate#\"\${typed[*]} \"}\"
        fi
        COMPREPLY+=(\"\$candidate\")
    done < <(command $BIN_PATH --complete 2>/dev/null)
}
complete -F _boot_complete boot"
        write_user_file "$bash_completion" "$BASH_COMP_DIR/boot" || return 1
        bashrc="$TARGET_HOME/.bashrc"
        append_unique_line "$bashrc" "[[ -r \"\$HOME/.local/share/bash-completion/completions/boot\" ]] && source \"\$HOME/.local/share/bash-completion/completions/boot\"" bash-completion || return 1
        configured_list+="Bash, "
    fi

    if command -v nu >/dev/null 2>&1 || [[ -d "$NU_DIR" ]]; then
        nu_completion="def 'nu-complete boot' [] {
    ^$BIN_PATH --complete | lines
}
export extern boot [...args: string@\"nu-complete boot\"]"
        write_user_file "$nu_completion" "$NU_DIR/boot.nu" || return 1
        nu_config="$NU_DIR/config.nu"
        append_unique_line "$nu_config" 'source ~/.config/nushell/boot.nu' nu-source || return 1
        configured_list+="Nushell, "
    fi

    profile_file="$TARGET_HOME/.profile"
    if ! grep -Fq '/usr/local/bin' "$profile_file" 2>/dev/null; then
        append_unique_line "$profile_file" 'export PATH="/usr/local/bin:$PATH"' profile-path || return 1
    fi
    say "${GREEN}[+] Configured ${configured_list}and POSIX/TTY PATH.${RESET}"
    if [[ "$configured_list" == *"Fish"* ]]; then
        say "${GREEN}[+] Fish inline suggestions use Fish autosuggestions and the seeded command history.${RESET}"
    fi
}

print_restart_notice() {
    say "${GREEN}Installation completed successfully.${RESET}"
    say "${YELLOW}Please restart your Terminal or start a new login session.${RESET}"
}

do_install() {
    local action="${1:-install}"
    local first_confirmation second_confirmation
    if [[ "$action" == "repair" ]]; then
        say "${BLUE}[*] Preparing Multi Boot repair.${RESET}"
        first_confirmation="Repair Multi Boot for ${TARGET_USER}? (y/n)"
        second_confirmation="This will replace the core command, revalidate the boot path, refresh passwordless UEFI permissions, and rebuild shell integrations. Continue? (y/n)"
    else
        say "${BLUE}[*] Preparing Multi Boot installation.${RESET}"
        first_confirmation="Install Multi Boot for ${TARGET_USER}? (y/n)"
        second_confirmation="This will install a system-wide boot command and configure passwordless UEFI boot and reboot operations. Continue? (y/n)"
    fi
    if ! validate_source; then
        return 1
    fi
    if ! confirm_twice "$first_confirmation" "$second_confirmation"; then
        say "${YELLOW}Operation cancelled.${RESET}"
        return 0
    fi
    if (( EUID != 0 )); then
        if ! command -v sudo >/dev/null 2>&1; then
            say "${RED}[!] sudo is required for system installation.${RESET}"
            return 1
        fi
        sudo -v || return 1
    fi
    if ! prepare_dependencies; then
        return 1
    fi
    say "${GREEN}[+] Boot environment requirement passed.${RESET}"
    if ! create_efi_reader_helper; then
        say "${RED}[!] Failed to install the restricted EFI reader helper.${RESET}"
        return 1
    fi
    if ! create_sudoers_rule; then
        run_root rm -f "$HELPER_PATH"
        return 1
    fi
    if ! run_root install -d -m 755 -o root -g root "$BIN_DIR"; then
        run_root rm -f "$SUDOERS_PATH" "$HELPER_PATH"
        say "${RED}[!] Failed to create the system binary directory.${RESET}"
        return 1
    fi
    if ! run_root install -m 755 -o root -g root "$SRC_SCRIPT" "$BIN_PATH"; then
        run_root rm -f "$SUDOERS_PATH" "$HELPER_PATH"
        say "${RED}[!] Failed to install the boot command.${RESET}"
        return 1
    fi
    say "${GREEN}[+] Installed $BIN_PATH.${RESET}"
    if ! configure_shells; then
        say "${YELLOW}[!] The core command is installed, but one or more shell integrations could not be configured.${RESET}"
        return 1
    fi
    print_restart_notice
}

do_remove() {
    if [[ ! -e "$BIN_PATH" && ! -e "$SUDOERS_PATH" && ! -e "$HELPER_PATH" \
        && ! -e "$FISH_FUNC_DIR/boot.fish" && ! -e "$FISH_COMP_DIR/boot.fish" \
        && ! -e "$ZSH_COMP_DIR/_boot" && ! -e "$BASH_COMP_DIR/boot" \
        && ! -e "$NU_DIR/boot.nu" && ! -e "$STATE_FILE" ]]; then
        say "${YELLOW}Multi Boot is not installed.${RESET}"
        return 0
    fi
    if ! confirm_twice "Remove Multi Boot from this system? (y/n)" "This will remove the core command, privileged helper, sudoers rule, and shell integrations. Continue? (y/n)"; then
        say "${YELLOW}Removal cancelled.${RESET}"
        return 0
    fi
    if ! run_root rm -f "$BIN_PATH" "$HELPER_PATH" "$SUDOERS_PATH"; then
        say "${RED}[!] Failed to remove system files. Check your administrator permissions.${RESET}"
        return 1
    fi
    if ! rm -f "$FISH_FUNC_DIR/boot.fish" "$FISH_COMP_DIR/boot.fish" "$ZSH_COMP_DIR/_boot" "$BASH_COMP_DIR/boot" "$NU_DIR/boot.nu"; then
        say "${RED}[!] Failed to remove one or more shell integration files.${RESET}"
        return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'zsh-fpath' "$STATE_FILE"; then
        remove_exact_line "$TARGET_HOME/.zshrc" "fpath=(\"$ZSH_COMP_DIR\" \$fpath)" || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'zsh-compinit' "$STATE_FILE"; then
        remove_exact_line "$TARGET_HOME/.zshrc" 'autoload -Uz compinit && compinit' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'zsh-compdef' "$STATE_FILE"; then
        remove_exact_line "$TARGET_HOME/.zshrc" 'compdef _boot boot' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'bash-completion' "$STATE_FILE"; then
        remove_exact_line "$TARGET_HOME/.bashrc" '[[ -r "$HOME/.local/share/bash-completion/completions/boot" ]] && source "$HOME/.local/share/bash-completion/completions/boot"' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'nu-source' "$STATE_FILE"; then
        remove_exact_line "$NU_DIR/config.nu" 'source ~/.config/nushell/boot.nu' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'profile-path' "$STATE_FILE"; then
        remove_exact_line "$TARGET_HOME/.profile" 'export PATH="/usr/local/bin:$PATH"' || return 1
    fi
    rm -f "$STATE_FILE"
    say "${GREEN}Multi Boot was removed.${RESET}"
    say "${YELLOW}Please restart your Terminal or start a new login session.${RESET}"
}

show_efistub_status() {
    local label="EFISTUB"
    if ! detect_current_efistub; then
        say "${RED}[!] Boot Path: ${EFISTUB_REASON}${RESET}"
        return 1
    fi
    [[ "$BOOT_MODE" == "systemd-boot" ]] && label="systemd-boot"
    MCOPY_BIN="$(resolve_binary mcopy 2>/dev/null || true)"
    MDIR_BIN="$(resolve_binary mdir 2>/dev/null || true)"
    if [[ -z "$MCOPY_BIN" || -z "$MDIR_BIN" ]]; then
        say "${YELLOW}[!] ${label}: ${EFISTUB_REASON} Image verification is unavailable because mtools is missing.${RESET}"
        return 0
    fi
    if verify_current_efistub_file; then
        say "${GREEN}[+] ${label}: ${EFISTUB_REASON}${RESET}"
    else
        say "${RED}[!] ${label}: ${EFISTUB_REASON}${RESET}"
        return 1
    fi
}

do_status() {
    local state
    say "${BLUE}Multi Boot Status${RESET}"
    state="$(installation_state)"
    case "$state" in
        Installed) say "${GREEN}[+] Installation: Complete${RESET}" ;;
        Incomplete) say "${YELLOW}[!] Installation: Incomplete${RESET}" ;;
        *) say "${RED}[-] Installation: Not installed${RESET}" ;;
    esac
    if [[ -x "$BIN_PATH" ]]; then
        say "${GREEN}[+] Core: Installed at ${BIN_PATH}${RESET}"
    else
        say "${RED}[-] Core: Missing${RESET}"
    fi
    if [[ -f "$SUDOERS_PATH" ]]; then
        if [[ -z "$VISUDO_BIN" ]]; then
            VISUDO_BIN="$(resolve_binary visudo 2>/dev/null || true)"
        fi
        if [[ -n "$VISUDO_BIN" ]]; then
            if run_root "$VISUDO_BIN" -cf "$SUDOERS_PATH" >/dev/null 2>&1; then
                say "${GREEN}[+] Sudoers: Valid${RESET}"
            else
                say "${RED}[-] Sudoers: Invalid${RESET}"
            fi
        else
            say "${YELLOW}[!] Sudoers: Present, but visudo is unavailable${RESET}"
        fi
    else
        say "${RED}[-] Sudoers: Not configured${RESET}"
    fi
    [[ -x "$HELPER_PATH" ]] && say "${GREEN}[+] EFI reader helper: Installed${RESET}" || say "${RED}[-] EFI reader helper: Missing${RESET}"
    [[ -x "$(resolve_binary efibootmgr 2>/dev/null || true)" ]] && say "${GREEN}[+] efibootmgr: Available${RESET}" || say "${RED}[-] efibootmgr: Missing${RESET}"
    [[ -x "$(resolve_binary mcopy 2>/dev/null || true)" && -x "$(resolve_binary mdir 2>/dev/null || true)" ]] && say "${GREEN}[+] mtools: Available${RESET}" || say "${RED}[-] mtools: Missing${RESET}"
    show_efistub_status || true
    if [[ -x "$BIN_PATH" ]]; then
        "$BIN_PATH" -l || true
    fi
}

show_menu() {
    while true; do
        printf '\033[2J\033[H'
        say "${BOLD:-}${GREEN}Multi Boot Management${RESET}"
        local state
        state="$(installation_state)"
        case "$state" in
            Installed) say "Status: ${GREEN}Installed${RESET}" ;;
            Incomplete) say "Status: ${YELLOW}Incomplete${RESET}" ;;
            *) say "Status: ${RED}Not installed${RESET}" ;;
        esac
        say "User: ${CYAN}${TARGET_USER}${RESET}"
        printf '\n'
        say "1) Install"
        say "2) Remove"
        say "3) Status"
        say "4) Repair"
        say "5) Exit"
        printf '\nSelect an option [1-5]: '
        local choice
        read -r choice || return 0
        case "$choice" in
            1)
                do_install || true
                printf '\nPress Enter to return to the menu.'
                read -r _ || true
                ;;
            2)
                do_remove || true
                printf '\nPress Enter to return to the menu.'
                read -r _ || true
                ;;
            3)
                do_status || true
                printf '\nPress Enter to return to the menu.'
                read -r _ || true
                ;;
            4)
                do_install repair || true
                printf '\nPress Enter to return to the menu.'
                read -r _ || true
                ;;
            5)
                return 0
                ;;
            *)
                say "${RED}Invalid option. Please select a number from 1 to 5.${RESET}"
                sleep 1
                ;;
        esac
    done
}

if [[ "${1:-}" == --remove || "${1:-}" == --uninstall ]]; then
    do_remove
    exit $?
fi

if [[ ! -t 0 ]]; then
    say "${RED}This installer requires an interactive terminal.${RESET}"
    exit 1
fi

show_menu
