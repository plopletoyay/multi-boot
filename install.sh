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

resolve_initial_target_user() {
    local candidate="" login_uid=""
    if (( EUID != 0 )); then
        id -un 2>/dev/null || printf '%s' "${USER:-$EUID}"
        return 0
    fi
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" && "$SUDO_USER" != "0" ]]; then
        printf '%s' "$SUDO_USER"
        return 0
    fi
    if [[ -n "${DOAS_USER:-}" && "$DOAS_USER" != "root" && "$DOAS_USER" != "0" ]]; then
        printf '%s' "$DOAS_USER"
        return 0
    fi
    if [[ -n "${PKEXEC_UID:-}" && "$PKEXEC_UID" =~ ^[0-9]+$ && "$PKEXEC_UID" != "0" ]]; then
        printf '%s' "$PKEXEC_UID"
        return 0
    fi
    if command -v logname >/dev/null 2>&1; then
        candidate="$(logname 2>/dev/null || true)"
        if [[ -n "$candidate" && "$candidate" != "root" && "$candidate" != "0" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    fi
    if [[ -r /proc/self/loginuid ]]; then
        login_uid="$(tr -d '[:space:]' < /proc/self/loginuid 2>/dev/null || true)"
        if [[ "$login_uid" =~ ^[0-9]+$ && "$login_uid" != "0" && "$login_uid" != "4294967295" ]]; then
            printf '%s' "$login_uid"
            return 0
        fi
    fi
    printf '%s' "${USER:-$(id -un)}"
}

TARGET_USER="$(resolve_initial_target_user)"
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
TARGET_UID="$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f3)"
TARGET_GID="$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f4)"
TARGET_HOME="$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f6)"
TARGET_SHELL="$(printf '%s\n' "$PASSWD_RECORD" | cut -d: -f7)"
TARGET_GROUP="$(id -gn "$TARGET_USER" 2>/dev/null || true)"
if [[ -z "$TARGET_GROUP" ]] && command -v getent >/dev/null 2>&1; then
    TARGET_GROUP="$(getent group "$TARGET_GID" 2>/dev/null | cut -d: -f1 || true)"
fi
[[ -n "$TARGET_GROUP" ]] || TARGET_GROUP="$TARGET_USER"
[[ -n "$TARGET_HOME" ]] || TARGET_HOME="/root"
if [[ "$TARGET_HOME" == *$'\n'* || "$TARGET_HOME" == *$'\r'* ]]; then
    printf '%s\n' "Invalid control characters in target user's home directory path."
    exit 1
fi

FISH_DIR="$TARGET_HOME/.config/fish"
FISH_FUNC_DIR="$FISH_DIR/functions"
FISH_COMP_DIR="$FISH_DIR/completions"
FISH_DATA_DIR="$TARGET_HOME/.local/share/fish"
ZSH_COMP_DIR="$TARGET_HOME/.zsh/completions"
BASH_COMP_DIR="$TARGET_HOME/.local/share/bash-completion/completions"
NU_DIR="$TARGET_HOME/.config/nushell"
STATE_DIR="$TARGET_HOME/.local/share/multiboot"
STATE_FILE="$STATE_DIR/installed-directives"

BOLD=$'\033[1m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
RESET=$'\033[0m'
APT_UPDATED=0
INSTALLED_PACKAGES=()
ALLOW_ROOT_VERIFY=0
EFI_BIN=""
MCOPY_BIN=""
MDIR_BIN=""
SYSTEMCTL_BIN=""
BOOTCTL_BIN=""
REBOOT_BIN=""
VISUDO_BIN=""
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

is_trusted_root_binary() {
    local target="$1"
    local resolved current owner mode
    [[ -n "$target" && "$target" == /* && -f "$target" && -x "$target" ]] || return 1
    resolved="$(readlink -f "$target" 2>/dev/null || true)"
    [[ -n "$resolved" && "$resolved" == /* && -f "$resolved" && -x "$resolved" ]] || return 1
    for current in "$target" "$resolved"; do
        while [[ -n "$current" ]]; do
            [[ -e "$current" || -L "$current" ]] || return 1
            owner="$(stat -c '%u' "$current" 2>/dev/null || printf '1')"
            [[ "$owner" == "0" ]] || return 1
            if [[ -L "$current" ]]; then
                [[ -e "$current" ]] || return 1
                mode="$(stat -L -c '%a' "$current" 2>/dev/null || printf '777')"
            else
                mode="$(stat -c '%a' "$current" 2>/dev/null || printf '777')"
            fi
            (( (8#$mode & 8#0022) == 0 )) || return 1
            [[ "$current" == "/" ]] && break
            current="$(dirname "$current")"
        done
    done
    return 0
}

resolve_binary() {
    local name="$1"
    local path="" dir="" seen="|"
    local -a search_dirs=("/usr/bin" "/usr/sbin" "/bin" "/sbin" "/usr/local/bin" "/usr/local/sbin")
    local -a path_dirs=()
    IFS=':' read -ra path_dirs <<< "${PATH:-}"
    for dir in "${path_dirs[@]}"; do
        [[ -n "$dir" && "$dir" == /* ]] && search_dirs+=("$dir")
    done
    for dir in "${search_dirs[@]}"; do
        [[ "$seen" == *"|${dir}|"* ]] && continue
        seen+="${dir}|"
        path="${dir%/}/$name"
        if is_trusted_root_binary "$path"; then
            printf '%s' "$path"
            return 0
        fi
    done
    return 1
}

diagnose_binary() {
    local name="$1"
    local found_untrusted="" dir="" owner mode
    local -a search_dirs=("/usr/bin" "/usr/sbin" "/bin" "/sbin" "/usr/local/bin" "/usr/local/sbin")
    for dir in "${search_dirs[@]}"; do
        if [[ -e "$dir/$name" || -L "$dir/$name" ]]; then
            found_untrusted="$dir/$name"
            break
        fi
    done
    if [[ -z "$found_untrusted" ]]; then
        found_untrusted="$(command -v "$name" 2>/dev/null || true)"
    fi
    if [[ -z "$found_untrusted" ]]; then
        printf 'not found on system'
        return 0
    fi
    if [[ ! -e "$found_untrusted" ]]; then
        printf 'broken symlink at %s' "$found_untrusted"
        return 0
    fi
    owner="$(stat -c '%u' "$found_untrusted" 2>/dev/null || printf '?')"
    mode="$(stat -L -c '%a' "$found_untrusted" 2>/dev/null || printf '?')"
    printf 'untrusted path %s (uid=%s, mode=%s)' "$found_untrusted" "$owner" "$mode"
}

run_as_target_user() {
    if (( EUID != 0 )) || [[ "$TARGET_UID" == "0" ]]; then
        "$@"
        return $?
    fi
    local runuser_bin su_bin bash_bin cmd_str="" arg
    runuser_bin="$(resolve_binary runuser 2>/dev/null || true)"
    if [[ -n "$runuser_bin" ]]; then
        "$runuser_bin" -u "$TARGET_USER" -- "$@"
        return $?
    fi
    su_bin="$(resolve_binary su 2>/dev/null || true)"
    bash_bin="$(resolve_binary bash 2>/dev/null || printf '/bin/bash')"
    if [[ -n "$su_bin" ]]; then
        for arg in "$@"; do
            cmd_str+="$(printf '%q ' "$arg")"
        done
        "$su_bin" -s "$bash_bin" "$TARGET_USER" -c "$cmd_str"
        return $?
    fi
    return 1
}

target_uses_bash() {
    [[ "${TARGET_SHELL##*/}" == "bash" || -f "$TARGET_HOME/.bashrc" || -f "$TARGET_HOME/.bash_profile" || -f "$TARGET_HOME/.bash_login" || -d "$BASH_COMP_DIR" ]]
}

is_installed() {
    local visudo_check helper_shebang sudoers_meta
    [[ -x "$BIN_PATH" && -s "$BIN_PATH" ]] || return 1
    [[ "$(head -n 1 "$BIN_PATH" 2>/dev/null)" == '#!/usr/bin/env bash' ]] || return 1
    grep -Fq 'sudo -v' "$BIN_PATH" 2>/dev/null || return 1
    bash -n "$BIN_PATH" >/dev/null 2>&1 || return 1
    [[ -x "$HELPER_PATH" && -s "$HELPER_PATH" ]] || return 1
    helper_shebang="$(head -n 1 "$HELPER_PATH" 2>/dev/null || true)"
    [[ "$helper_shebang" =~ ^#!/.*bash$ && "$helper_shebang" != *"/env "* ]] || return 1
    bash -n "$HELPER_PATH" >/dev/null 2>&1 || return 1
    grep -Fq 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b' "$HELPER_PATH" 2>/dev/null || return 1
    grep -Fq 'set-oneshot' "$HELPER_PATH" 2>/dev/null || return 1
    [[ -f "$SUDOERS_PATH" && -s "$SUDOERS_PATH" ]] || return 1
    visudo_check="$(resolve_binary visudo 2>/dev/null || true)"
    if (( EUID == 0 )) || [[ -r "$SUDOERS_PATH" ]]; then
        grep -Fq "$HELPER_PATH" "$SUDOERS_PATH" 2>/dev/null || return 1
        if grep -Eq 'NOPASSWD|timestamp_timeout|set-oneshot \*' "$SUDOERS_PATH" 2>/dev/null; then
            return 1
        fi
        if [[ -n "$visudo_check" ]]; then
            "$visudo_check" -cf "$SUDOERS_PATH" >/dev/null 2>&1 || return 1
        fi
    else
        sudoers_meta="$(stat -c '%u:%g:%a' "$SUDOERS_PATH" 2>/dev/null || true)"
        [[ "$sudoers_meta" == "0:0:440" || "$sudoers_meta" == "0:0:400" ]] || return 1
        if command -v sudo >/dev/null 2>&1 && [[ -n "$visudo_check" ]]; then
            if sudo -n true >/dev/null 2>&1; then
                sudo -n "$visudo_check" -cf "$SUDOERS_PATH" >/dev/null 2>&1 || return 1
            fi
        fi
    fi
    if command -v fish >/dev/null 2>&1 || [[ -d "$FISH_DIR" ]]; then
        [[ -f "$FISH_FUNC_DIR/boot.fish" && -f "$FISH_COMP_DIR/boot.fish" ]] || return 1
    fi
    if command -v zsh >/dev/null 2>&1 || [[ -f "$TARGET_HOME/.zshrc" || -d "$TARGET_HOME/.zsh" ]]; then
        [[ -f "$ZSH_COMP_DIR/_boot" ]] || return 1
    fi
    if target_uses_bash; then
        [[ -f "$BASH_COMP_DIR/boot" ]] || return 1
    fi
    if command -v nu >/dev/null 2>&1 || [[ -d "$NU_DIR" ]]; then
        [[ -f "$NU_DIR/boot.nu" ]] || return 1
    fi
    return 0
}

installation_state() {
    if is_installed; then
        printf 'Installed'
    elif [[ -e "$BIN_PATH" || -e "$HELPER_PATH" || -e "$SUDOERS_PATH" || -e "$STATE_FILE" ]]; then
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

has_pm() {
    command -v "$1" >/dev/null 2>&1 || resolve_binary "$1" >/dev/null 2>&1
}

detect_package_manager() {
    local os_id="" os_like=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(awk -F= '/^ID=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
        os_like="$(awk -F= '/^ID_LIKE=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
    fi
    case " $os_id $os_like " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" kali "*|*" elementary "*|*" zorin "*)
            if has_pm apt-get; then printf 'apt-get'; return 0; fi ;;
        *" arch "*|*" manjaro "*|*" endeavouros "*|*" cachyos "*|*" garuda "*|*" artix "*)
            if has_pm pacman; then printf 'pacman'; return 0; fi ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*)
            if has_pm dnf; then printf 'dnf'; return 0; fi
            if has_pm yum; then printf 'yum'; return 0; fi ;;
        *" suse "*|*" opensuse "*|*" sles "*)
            if has_pm zypper; then printf 'zypper'; return 0; fi ;;
        *" alpine "*)
            if has_pm apk; then printf 'apk'; return 0; fi ;;
        *" void "*)
            if has_pm xbps-install; then printf 'xbps-install'; return 0; fi ;;
        *" gentoo "*)
            if has_pm emerge; then printf 'emerge'; return 0; fi ;;
    esac
    if [[ -f /var/lib/dpkg/status ]] && has_pm apt-get; then
        printf 'apt-get'
    elif [[ -d /var/lib/pacman ]] && has_pm pacman; then
        printf 'pacman'
    elif [[ -d /var/lib/rpm ]] && has_pm dnf; then
        printf 'dnf'
    elif [[ -d /var/lib/rpm ]] && has_pm zypper; then
        printf 'zypper'
    elif [[ -d /etc/apk ]] && has_pm apk; then
        printf 'apk'
    elif [[ -d /var/db/xbps ]] && has_pm xbps-install; then
        printf 'xbps-install'
    elif [[ -d /var/lib/rpm ]] && has_pm yum; then
        printf 'yum'
    elif [[ -d /var/db/pkg ]] && has_pm emerge; then
        printf 'emerge'
    elif has_pm apt-get; then
        printf 'apt-get'
    elif has_pm dnf; then
        printf 'dnf'
    elif has_pm pacman; then
        printf 'pacman'
    elif has_pm zypper; then
        printf 'zypper'
    elif has_pm xbps-install; then
        printf 'xbps-install'
    elif has_pm apk; then
        printf 'apk'
    elif has_pm yum; then
        printf 'yum'
    elif has_pm emerge; then
        printf 'emerge'
    else
        return 1
    fi
}

package_binaries_ready() {
    local package="$1"
    case "$package" in
        efibootmgr)
            resolve_binary efibootmgr >/dev/null 2>&1
            ;;
        mtools)
            resolve_binary mcopy >/dev/null 2>&1 && resolve_binary mdir >/dev/null 2>&1
            ;;
        sudo)
            resolve_binary visudo >/dev/null 2>&1
            ;;
        *)
            return 0
            ;;
    esac
}

install_package() {
    local package="$1"
    local pm=""
    if package_binaries_ready "$package"; then
        say "${GREEN}[+] ${package} is already installed.${RESET}"
        return 0
    fi
    pm="$(detect_package_manager 2>/dev/null || true)"
    if [[ -z "$pm" ]]; then
        say "${RED}[!] No supported package manager was found. Install '${package}' manually.${RESET}"
        return 1
    fi
    say "${YELLOW}[!] Installing package: ${package} (via ${pm})${RESET}"
    case "$pm" in
        apt-get)
            if ! run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package" >/dev/null 2>&1; then
                if (( APT_UPDATED == 0 )); then
                    run_root apt-get update -qq >/dev/null 2>&1 || true
                    APT_UPDATED=1
                fi
                run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package" || return 1
            fi
            if ! package_binaries_ready "$package"; then
                run_root env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y --no-install-recommends "$package" || return 1
            fi
            ;;
        pacman)
            run_root pacman -S --needed --noconfirm "$package" || return 1
            if ! package_binaries_ready "$package"; then
                say "${YELLOW}[!] Package '${package}' is registered in pacman DB but binaries are missing; forcing reinstall.${RESET}"
                run_root pacman -S --noconfirm "$package" || return 1
            fi
            ;;
        dnf)
            run_root dnf install -y "$package" || return 1
            if ! package_binaries_ready "$package"; then
                run_root dnf reinstall -y "$package" || return 1
            fi
            ;;
        zypper)
            run_root zypper --non-interactive install -y "$package" || return 1
            if ! package_binaries_ready "$package"; then
                run_root zypper --non-interactive install -f -y "$package" || return 1
            fi
            ;;
        xbps-install)
            run_root xbps-install -Sy "$package" || return 1
            if ! package_binaries_ready "$package"; then
                run_root xbps-install -fy "$package" || return 1
            fi
            ;;
        apk)
            run_root apk add "$package" || return 1
            if ! package_binaries_ready "$package"; then
                run_root apk fix "$package" || return 1
            fi
            ;;
        yum)
            run_root yum install -y "$package" || return 1
            if ! package_binaries_ready "$package"; then
                run_root yum reinstall -y "$package" || return 1
            fi
            ;;
        emerge)
            run_root emerge --noreplace "$package" || return 1
            if ! package_binaries_ready "$package"; then
                run_root emerge "$package" || return 1
            fi
            ;;
    esac
    INSTALLED_PACKAGES+=("$package")
}

validate_source() {
    if [[ ! -f "$SRC_SCRIPT" || ! -s "$SRC_SCRIPT" ]]; then
        say "${RED}[!] The boot script was not found beside install.sh.${RESET}"
        return 1
    fi
    if head -n 1 "$SRC_SCRIPT" | grep -q $'\r'; then
        say "${RED}[!] The boot script contains Windows CRLF line endings. Convert it to LF first.${RESET}"
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
    if ! grep -Fq -- '--complete' "$SRC_SCRIPT" 2>/dev/null; then
        say "${RED}[!] The boot script does not support the required completion interface.${RESET}"
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

detect_current_efistub() {
    local output current_id line current_line="" found_entry="0" loader="" opts="" partuuid="" base="" pattern hd_pattern raw_tail first_token trimmed_loader device fstype normalized_loader loader_info_file loader_info
    local scan_str chunk byte_hex byte_val ch hex_clean decoded_opts ascii_decoded utf16_pairs ascii_pairs idx
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
        if [[ "$loader_info" == *systemd-boot* || "$loader_info" == *grub* || "$loader_info" == *refind* || "$loader_info" == *clover* || "$loader_info" == *opencore* ]]; then
            EFISTUB_REASON="The current boot path uses a boot manager or chainloader instead of direct EFISTUB."
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
        if [[ -z "$output" ]] && (( ALLOW_ROOT_VERIFY == 1 )); then
            output="$(run_root "$EFI_BIN" -v 2>/dev/null || true)"
        fi
    fi
    current_id="$(printf '%s\n' "$output" | awk -F': *' '/^BootCurrent:/ {gsub(/[^0-9A-Fa-f]/, "", $2); print toupper($2); exit}')"
    if [[ ! "$current_id" =~ ^[[:xdigit:]]{4}$ ]]; then
        EFISTUB_REASON="The firmware did not report a readable BootCurrent entry."
        return 1
    fi
    while IFS= read -r line; do
        if [[ "$line" =~ ^[Bb][Oo][Oo][Tt]${current_id}(\*)?[[:space:]]*(.*)$ ]]; then
            current_line="$line"
            found_entry="1"
            break
        fi
    done <<< "$output"
    if [[ -z "$current_line" || "$found_entry" != "1" ]]; then
        EFISTUB_REASON="The current firmware entry Boot${current_id} could not be found in NVRAM."
        return 1
    fi
    pattern='[Ff][Ii][Ll][Ee]\(([^)]*)\)(.*)$'
    hd_pattern='[Hh][Dd]\([^)]*\)/?([\\/].*)$'
    if [[ "$current_line" =~ $pattern ]]; then
        loader="${BASH_REMATCH[1]}"
        opts="${BASH_REMATCH[2]:-}"
    elif [[ "$current_line" =~ $hd_pattern ]]; then
        raw_tail="${BASH_REMATCH[1]}"
        if [[ "$raw_tail" == *$'\t'* ]]; then
            loader="${raw_tail%%$'\t'*}"
            opts="${raw_tail#*$'\t'}"
        elif [[ "$raw_tail" =~ ^(.+\.([Ee][Ff][Ii]|[Uu][Kk][Ii]))([^/]*)$ ]]; then
            loader="${BASH_REMATCH[1]}"
            opts="${BASH_REMATCH[3]:-}"
        else
            scan_str="$raw_tail"
            if [[ "$scan_str" =~ ^(.*)(0000)$ ]]; then
                scan_str="${BASH_REMATCH[1]}"
            fi
            utf16_pairs=0
            while (( ${#scan_str} >= 4 )); do
                chunk="${scan_str: -4}"
                if [[ "$chunk" =~ ^(09|0[aAdD]|[2-7][0-9a-fA-F])00$ ]]; then
                    scan_str="${scan_str:0:${#scan_str}-4}"
                    utf16_pairs=$((utf16_pairs + 1))
                else
                    break
                fi
            done
            if (( utf16_pairs >= 3 && ${#scan_str} >= 1 )); then
                loader="$scan_str"
                opts="${raw_tail:${#scan_str}}"
            else
                scan_str="$raw_tail"
                if [[ "$scan_str" =~ ^(.*)(00)$ ]]; then
                    scan_str="${BASH_REMATCH[1]}"
                fi
                ascii_pairs=0
                ascii_decoded=""
                while (( ${#scan_str} >= 2 )); do
                    byte_hex="${scan_str: -2}"
                    if [[ "$byte_hex" =~ ^(09|0a|0d|[2-7][0-9a-f])$ ]]; then
                        scan_str="${scan_str:0:${#scan_str}-2}"
                        byte_val=$((16#$byte_hex))
                        if (( byte_val >= 32 && byte_val <= 126 )); then
                            printf -v ch "\\x$byte_hex"
                            ascii_decoded="${ch}${ascii_decoded}"
                        else
                            ascii_decoded=" ${ascii_decoded}"
                        fi
                        ascii_pairs=$((ascii_pairs + 1))
                    else
                        break
                    fi
                done
                if (( ascii_pairs >= 6 && ${#scan_str} >= 1 )) && [[ "$ascii_decoded" =~ (^|[[:space:]])([A-Za-z0-9_.-]+=[^[:space:]]+|rw|ro|quiet|splash|debug|single|rescue|emergency|nomodeset|nowatchdog|--)([[:space:]]|$) ]]; then
                    loader="$scan_str"
                    opts="${raw_tail:${#scan_str}}"
                elif [[ "$raw_tail" =~ ^([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
                    first_token="${BASH_REMATCH[1]}"
                    opts="${BASH_REMATCH[2]:-}"
                    if [[ "$raw_tail" =~ ^(.+)[[:space:]]+([A-Za-z0-9_.-]+=.*|rw|ro|quiet|splash|debug|single|rescue|emergency|nomodeset|nowatchdog|--)(.*)$ ]]; then
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
                else
                    loader="$raw_tail"
                    opts=""
                fi
            fi
        fi
    fi
    opts="${opts#"${opts%%[![:space:]]*}"}"
    opts="${opts%"${opts##*[![:space:]]}"}"
    if [[ "$opts" =~ ^(([0-9a-fA-F]{2}00)+)([0-9a-fA-F]{2})?$ ]]; then
        hex_clean="${BASH_REMATCH[1],,}"
        decoded_opts=""
        for ((idx = 0; idx < ${#hex_clean}; idx += 4)); do
            byte_hex="${hex_clean:idx:2}"
            [[ "$byte_hex" == "00" ]] && continue
            byte_val=$((16#$byte_hex))
            if (( byte_val >= 32 && byte_val <= 126 )); then
                printf -v ch "\\x$byte_hex"
                decoded_opts+="$ch"
            elif (( byte_val == 9 || byte_val == 10 || byte_val == 13 )); then
                decoded_opts+=" "
            fi
        done
        decoded_opts="${decoded_opts#"${decoded_opts%%[![:space:]]*}"}"
        decoded_opts="${decoded_opts%"${decoded_opts##*[![:space:]]}"}"
        opts="$decoded_opts"
    elif [[ "$opts" =~ ^(([0-9a-fA-F]{2}){4,})$ ]]; then
        hex_clean="${BASH_REMATCH[1],,}"
        decoded_opts=""
        for ((idx = 0; idx < ${#hex_clean}; idx += 2)); do
            byte_hex="${hex_clean:idx:2}"
            [[ "$byte_hex" == "00" ]] && continue
            byte_val=$((16#$byte_hex))
            if (( byte_val >= 32 && byte_val <= 126 )); then
                printf -v ch "\\x$byte_hex"
                decoded_opts+="$ch"
            elif (( byte_val == 9 || byte_val == 10 || byte_val == 13 )); then
                decoded_opts+=" "
            fi
        done
        decoded_opts="${decoded_opts#"${decoded_opts%%[![:space:]]*}"}"
        decoded_opts="${decoded_opts%"${decoded_opts##*[![:space:]]}"}"
        opts="$decoded_opts"
    fi
    if [[ "$current_line" =~ [Gg][Pp][Tt],([[:xdigit:]-]{36}) ]]; then
        partuuid="${BASH_REMATCH[1]}"
    fi
    device=""
    if [[ -n "$partuuid" ]]; then
        device="$(resolve_partuuid_device "$partuuid" || true)"
    fi
    if [[ -z "$loader" || -z "$partuuid" || -z "$device" ]]; then
        EFISTUB_REASON="Boot${current_id} does not resolve to an existing GPT-backed EFI image."
        return 1
    fi
    loader="${loader//\\//}"
    while [[ "$loader" == *"//"* ]]; do
        loader="${loader//\/\//\/}"
    done
    normalized_loader="${loader,,}"
    base="${normalized_loader##*/}"
    fstype="$(lsblk -dnro FSTYPE "$device" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$fstype" ]]; then
        fstype="$(blkid -o value -s TYPE "$device" 2>/dev/null | head -n 1 || true)"
    fi
    case "${fstype,,}" in
        vfat|fat|fat32|msdos) ;;
        *)
            EFISTUB_REASON="The current EFI-stub image is not on a recognized FAT EFI partition. Detected filesystem: ${fstype:-unknown}."
            return 1
            ;;
    esac
    case "$base" in
        shim*.efi|grub*.efi|refind*.efi|systemd-boot*.efi|bootx64.efi|bootaa64.efi|bootia32.efi|bootmgfw.efi|bootmgr.efi|boot.efi|opencore*.efi|clover*.efi|fwupd*.efi|mmx64.efi|mmaa64.efi|mokmanager*.efi|shell*.efi|memtest*.efi)
            EFISTUB_REASON="The current boot path uses a boot manager or chainloader instead of direct EFISTUB."
            return 1
            ;;
    esac
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
    awk -v b0="${bytes[0]}" -v b1="${bytes[1]}" -v b2="${bytes[2]}" -v b3="${bytes[3]}" \
        'BEGIN { printf "%.0f", b0 + (b1 * 256) + (b2 * 65536) + (b3 * 16777216) }'
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
    local device real_device relative temporary size pe_offset pe_signature pe_opt_magic pe_subsystem setup_magic zboot_magic arm64_magic riscv_magic zboot_comp kernel_offset kernel_version running_kernel mnt mnt_fstype loaded_from_mount=0 sections strings_dump cmdline_now opt_token matched_opts=0 resolved_mount_file part found linux_sec_line linux_ptr linux_size inner_setup_magic inner_zboot_magic inner_arm64_magic inner_riscv_magic
    local -a parts=() mount_candidates=()
    device="$(resolve_partuuid_device "$EFISTUB_PARTUUID" || true)"
    real_device="$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")"
    relative="${EFISTUB_LOADER//\\//}"
    while [[ "$relative" == *"//"* ]]; do
        relative="${relative//\/\//\/}"
    done
    relative="${relative#/}"
    [[ -b "$real_device" && -n "$relative" ]] || return 1
    [[ "$relative" =~ ^[A-Za-z0-9._/+@\ -]+$ ]] || return 1
    case "/$relative/" in
        */../*) return 1 ;;
    esac
    temporary="$(mktemp)" || return 1
    if command -v findmnt >/dev/null 2>&1; then
        while IFS=$'\t' read -r mnt_fstype mnt; do
            [[ -n "$mnt" && -d "$mnt" ]] || continue
            case "${mnt_fstype,,}" in
                vfat|fat|fat32|msdos) mount_candidates=("$mnt" "${mount_candidates[@]}") ;;
                *) mount_candidates+=("$mnt") ;;
            esac
        done < <(findmnt -rn -S "$real_device" -o FSTYPE,TARGET 2>/dev/null || true)
    fi
    for mnt in "${mount_candidates[@]}"; do
        if [[ -r "$mnt/$relative" ]] && cp -f "$mnt/$relative" "$temporary" 2>/dev/null; then
            loaded_from_mount=1
            break
        fi
        resolved_mount_file="$mnt"
        IFS='/' read -ra parts <<< "$relative"
        for part in "${parts[@]}"; do
            [[ -z "$part" ]] && continue
            found="$(find "$resolved_mount_file" -mindepth 1 -maxdepth 1 -iname "$part" -print -quit 2>/dev/null || true)"
            if [[ -z "$found" ]]; then
                resolved_mount_file=""
                break
            fi
            resolved_mount_file="$found"
        done
        if [[ -n "$resolved_mount_file" && -r "$resolved_mount_file" ]] && cp -f "$resolved_mount_file" "$temporary" 2>/dev/null; then
            loaded_from_mount=1
            break
        fi
        if (( ALLOW_ROOT_VERIFY == 1 && EUID != 0 )); then
            if run_root test -r "$mnt/$relative" 2>/dev/null && run_root cat "$mnt/$relative" > "$temporary" 2>/dev/null; then
                loaded_from_mount=1
                break
            fi
            resolved_mount_file="$mnt"
            for part in "${parts[@]}"; do
                [[ -z "$part" ]] && continue
                found="$(run_root find "$resolved_mount_file" -mindepth 1 -maxdepth 1 -iname "$part" -print -quit 2>/dev/null || true)"
                if [[ -z "$found" ]]; then
                    resolved_mount_file=""
                    break
                fi
                resolved_mount_file="$found"
            done
            if [[ -n "$resolved_mount_file" ]] && run_root test -r "$resolved_mount_file" 2>/dev/null && run_root cat "$resolved_mount_file" > "$temporary" 2>/dev/null; then
                loaded_from_mount=1
                break
            fi
        fi
    done
    if (( loaded_from_mount == 0 )); then
        if (( EUID == 0 )); then
            if ! "$MCOPY_BIN" -n -i "$real_device" "::/$relative" - > "$temporary" 2>/dev/null; then
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI-stub image '${EFISTUB_LOADER}' could not be read from PARTUUID=${EFISTUB_PARTUUID}."
                return 1
            fi
        elif [[ -x "$HELPER_PATH" ]] && sudo -n "$HELPER_PATH" read "$EFISTUB_PARTUUID" "$relative" > "$temporary" 2>/dev/null; then
            :
        elif (( ALLOW_ROOT_VERIFY == 1 )); then
            if ! run_root "$MCOPY_BIN" -n -i "$real_device" "::/$relative" - > "$temporary" 2>/dev/null; then
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI-stub image '${EFISTUB_LOADER}' could not be read from PARTUUID=${EFISTUB_PARTUUID}."
                return 1
            fi
        else
            if ! sudo -n "$MCOPY_BIN" -n -i "$real_device" "::/$relative" - > "$temporary" 2>/dev/null; then
                rm -f "$temporary"
                EFISTUB_REASON="The current EFI-stub image '${EFISTUB_LOADER}' could not be read from PARTUUID=${EFISTUB_PARTUUID} without a password prompt."
                return 1
            fi
        fi
    fi
    size="$(wc -c < "$temporary" | tr -d '[:space:]')"
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1024 )); then
        rm -f "$temporary"
        EFISTUB_REASON="The current EFI-stub image is empty or too small to be a valid EFI executable."
        return 1
    fi
    if [[ "$(od -An -tx1 -N2 "$temporary" 2>/dev/null | tr -d '[:space:]')" != "4d5a" ]]; then
        rm -f "$temporary"
        EFISTUB_REASON="The current firmware image does not have a valid PE/COFF DOS header."
        return 1
    fi
    pe_offset="$(read_u32_le "$temporary" 60 || printf '0')"
    if (( pe_offset < 64 || pe_offset + 96 > size )); then
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
    pe_opt_magic="$(read_u16_le "$temporary" $((pe_offset + 24)) || printf '0')"
    if (( pe_opt_magic != 523 && pe_opt_magic != 267 )); then
        rm -f "$temporary"
        EFISTUB_REASON="The current EFI image does not have a valid PE32/PE32+ optional header."
        return 1
    fi
    pe_subsystem="$(read_u16_le "$temporary" $((pe_offset + 24 + 68)) || printf '0')"
    if (( pe_subsystem != 10 )); then
        rm -f "$temporary"
        EFISTUB_REASON="The current PE image is not a UEFI application (subsystem ${pe_subsystem})."
        return 1
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
        if printf '%s' "$strings_dump" | grep -aEq 'GNU GRUB|grub_efi_|rEFInd|systemd-boot|shim_lock|bootmgfw\.pdb|OpenCore|Clover'; then
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
    running_kernel="$(uname -r 2>/dev/null || true)"
    EFISTUB_STATUS="Confirmed"
    if [[ -n "$running_kernel" && "$kernel_version" == "$running_kernel" ]]; then
        EFISTUB_REASON="BootCurrent resolves to the running Linux EFI-stub kernel (${kernel_version}) at ${EFISTUB_LOADER} on PARTUUID=${EFISTUB_PARTUUID}."
    elif [[ -n "$running_kernel" ]]; then
        EFISTUB_REASON="BootCurrent resolves to a valid Linux EFI-stub kernel (${kernel_version}; currently running ${running_kernel}) at ${EFISTUB_LOADER} on PARTUUID=${EFISTUB_PARTUUID}."
    else
        EFISTUB_REASON="BootCurrent resolves to a readable Linux EFI-stub image (${kernel_version}) at ${EFISTUB_LOADER} on PARTUUID=${EFISTUB_PARTUUID}."
    fi
    return 0
}

prepare_dependencies() {
    INSTALLED_PACKAGES=()
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
        say "${RED}[!] efibootmgr is unavailable ($(diagnose_binary efibootmgr)). Installation stopped.${RESET}"
        return 1
    fi
    if ! detect_current_efistub; then
        say "${RED}[!] EFISTUB verification failed: ${EFISTUB_REASON}${RESET}"
        say "${RED}Multi Boot can only be installed while a Linux kernel is booted directly through EFISTUB. GRUB, rEFInd, shim, and systemd-boot are not accepted as the current boot path.${RESET}"
        if (( ${#INSTALLED_PACKAGES[@]} > 0 )); then
            say "${RED}Installation stopped. No Multi Boot files or sudoers rules were changed (system package(s) installed earlier in this step: ${INSTALLED_PACKAGES[*]}).${RESET}"
        else
            say "${RED}Installation stopped. No system packages, Multi Boot files, or sudoers rules were changed.${RESET}"
        fi
        return 1
    fi
    if ! install_package mtools; then
        say "${RED}[!] Unable to install mtools. Installation stopped.${RESET}"
        return 1
    fi
    MCOPY_BIN="$(resolve_binary mcopy 2>/dev/null || true)"
    MDIR_BIN="$(resolve_binary mdir 2>/dev/null || true)"
    if [[ -z "$MCOPY_BIN" || -z "$MDIR_BIN" ]]; then
        say "${RED}[!] Root-owned system mcopy ($(diagnose_binary mcopy)) and mdir ($(diagnose_binary mdir)) binaries are required. Installation stopped.${RESET}"
        return 1
    fi
    if ! verify_current_efistub_file; then
        say "${RED}[!] EFISTUB verification failed: ${EFISTUB_REASON}${RESET}"
        if (( ${#INSTALLED_PACKAGES[@]} > 0 )); then
            say "${RED}Multi Boot only supports a directly loaded Linux EFISTUB kernel. Installation stopped. No Multi Boot files or sudoers rules were changed (system package(s) installed earlier in this step: ${INSTALLED_PACKAGES[*]}).${RESET}"
        else
            say "${RED}Multi Boot only supports a directly loaded Linux EFISTUB kernel. Installation stopped. No system packages, Multi Boot files, or sudoers rules were changed.${RESET}"
        fi
        return 1
    fi
    say "${GREEN}[+] Direct EFISTUB boot confirmed: ${EFISTUB_REASON}${RESET}"
    SYSTEMCTL_BIN="$(resolve_binary systemctl 2>/dev/null || true)"
    [[ -d /run/systemd/system ]] || SYSTEMCTL_BIN=""
    BOOTCTL_BIN="$(resolve_binary bootctl 2>/dev/null || true)"
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
        say "${RED}[!] visudo is unavailable ($(diagnose_binary visudo)). Installation stopped.${RESET}"
        return 1
    fi
}

create_efi_reader_helper() {
    local temporary bash_bin lsblk_bin blkid_bin findmnt_bin efibootmgr_bin bootctl_bin
    bash_bin="$(resolve_binary bash 2>/dev/null || true)"
    if [[ -z "$bash_bin" ]]; then
        say "${RED}[!] No trusted root-owned bash interpreter was found.${RESET}"
        return 1
    fi
    lsblk_bin="$(resolve_binary lsblk 2>/dev/null || true)"
    blkid_bin="$(resolve_binary blkid 2>/dev/null || true)"
    findmnt_bin="$(resolve_binary findmnt 2>/dev/null || true)"
    efibootmgr_bin="$(resolve_binary efibootmgr 2>/dev/null || true)"
    bootctl_bin="$(resolve_binary bootctl 2>/dev/null || true)"
    if [[ -z "$lsblk_bin" && -z "$blkid_bin" ]]; then
        say "${RED}[!] Neither lsblk nor blkid is available in trusted system paths.${RESET}"
        return 1
    fi
    temporary="$(mktemp)"
    printf '#!%s\n' "$bash_bin" > "$temporary"
    cat >> "$temporary" <<EOF_HELPER
set -Eeuo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin
IFS=\$' \\t\\n'
unalias -a 2>/dev/null || true
export PATH
MCOPY_BIN=$(printf '%q' "$MCOPY_BIN")
MDIR_BIN=$(printf '%q' "$MDIR_BIN")
LSBLK_BIN=$(printf '%q' "$lsblk_bin")
BLKID_BIN=$(printf '%q' "$blkid_bin")
FINDMNT_BIN=$(printf '%q' "$findmnt_bin")
EFIBOOTMGR_BIN=$(printf '%q' "$efibootmgr_bin")
BOOTCTL_BIN=$(printf '%q' "$bootctl_bin")
if (( \$# < 1 )); then
    exit 2
fi
operation="\$1"
if [[ "\$operation" == "set-oneshot" ]]; then
    if (( \$# != 2 )); then
        exit 2
    fi
    entry_id="\$2"
    [[ "\$entry_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\$ ]] || exit 2
    [[ -n "\$BOOTCTL_BIN" && -x "\$BOOTCTL_BIN" ]] || exit 1
    exec "\$BOOTCTL_BIN" set-oneshot "\$entry_id"
fi
if (( \$# != 3 )); then
    exit 2
fi
partuuid="\${2,,}"
relative="\${3//\\\\//}"
while [[ "\$relative" == *"//"* ]]; do
    relative="\${relative//\\/\\//\\/}"
done
relative="\${relative#/}"
[[ "\$partuuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$ ]] || exit 2
[[ -n "\$relative" && "\$relative" =~ ^[A-Za-z0-9._/+@\ -]+\$ ]] || exit 2
case "/\$relative/" in
    */../*|*/./*) exit 2 ;;
esac
lower_rel="\${relative,,}"
case "\$lower_rel" in
    *.efi|*.uki|*.img|*.cpio|*.gz|*.zst|*.lz4|*.xz|*.conf|*.nsh|vmlinuz*|*/vmlinuz*|vmlinux*|*/vmlinux*|bzimage*|*/bzimage*|image|*/image|image-*|*/image-*) ;;
    *) exit 2 ;;
esac
device="/dev/disk/by-partuuid/\$partuuid"
[[ -b "\$device" ]] || exit 1
real_device="\$(readlink -f "\$device" 2>/dev/null || true)"
[[ -n "\$real_device" && -b "\$real_device" ]] || exit 1
case "\$real_device" in
    /dev/loop*|/dev/ram*|/dev/zram*|/dev/nbd*) exit 1 ;;
esac
if [[ -n "\$BLKID_BIN" && -x "\$BLKID_BIN" ]]; then
    match_count="\$("\$BLKID_BIN" -t "PARTUUID=\$partuuid" -o device 2>/dev/null | sed '/^\$/d' | wc -l | tr -d '[:space:]')"
    if [[ "\$match_count" =~ ^[0-9]+\$ ]] && (( match_count > 1 )); then
        exit 1
    fi
fi
parttype=""
fstype=""
if [[ -n "\$LSBLK_BIN" && -x "\$LSBLK_BIN" ]]; then
    parttype="\$("\$LSBLK_BIN" -dnro PARTTYPE "\$real_device" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
    fstype="\$("\$LSBLK_BIN" -dnro FSTYPE "\$real_device" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
fi
if [[ -z "\$parttype" && -n "\$BLKID_BIN" && -x "\$BLKID_BIN" ]]; then
    parttype="\$("\$BLKID_BIN" -o value -s PART_ENTRY_TYPE "\$real_device" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
fi
if [[ -z "\$fstype" && -n "\$BLKID_BIN" && -x "\$BLKID_BIN" ]]; then
    fstype="\$("\$BLKID_BIN" -o value -s TYPE "\$real_device" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
fi
[[ "\$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || exit 1
case "\$fstype" in
    vfat|fat|fat32|msdos) ;;
    *) exit 1 ;;
esac
authorized_esp=0
if [[ -n "\$EFIBOOTMGR_BIN" && -x "\$EFIBOOTMGR_BIN" ]]; then
    if "\$EFIBOOTMGR_BIN" -v 2>/dev/null | grep -Eiq "^Boot[0-9A-Fa-f]{4}\\*?[[:space:]].*HD\\([0-9]+,GPT,\${partuuid},"; then
        authorized_esp=1
    fi
fi
if (( authorized_esp == 0 )) && [[ -n "\$FINDMNT_BIN" && -x "\$FINDMNT_BIN" ]]; then
    while IFS= read -r target_mnt; do
        case "\$target_mnt" in
            /efi|/boot/efi|/boot)
                authorized_esp=1
                break
                ;;
        esac
    done < <("\$FINDMNT_BIN" -rn -S "\$real_device" -o TARGET 2>/dev/null || true)
fi
(( authorized_esp == 1 )) || exit 1
case "\$operation" in
    exists)
        [[ -x "\$MDIR_BIN" ]] || exit 1
        parent="\${relative%/*}"
        basename="\${relative##*/}"
        if [[ "\$parent" == "\$relative" ]]; then
            parent=""
        fi
        if [[ -n "\$parent" ]]; then
            listing="\$("\$MDIR_BIN" -b -i "\$real_device" "::/\$parent" 2>/dev/null)" || exit 1
        else
            listing="\$("\$MDIR_BIN" -b -i "\$real_device" ::/ 2>/dev/null)" || exit 1
        fi
        printf '%s\\n' "\$listing" | grep -Fxi -- "\$basename" >/dev/null
        ;;
    read)
        [[ -x "\$MCOPY_BIN" ]] || exit 1
        exec "\$MCOPY_BIN" -n -i "\$real_device" "::/\$relative" -
        ;;
    *)
        exit 2
        ;;
esac
EOF_HELPER
    if ! "$bash_bin" -n "$temporary"; then
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
    local temporary prev_sudoers="" had_prev_sudoers=0 visudo_output su_bad_lines other_bad_lines candidate real_candidate seen_paths="|" commands=""
    local -a efi_bins=() systemctl_bins=() reboot_bins=()
    temporary="$(mktemp)"
    local boot_id_pattern="[0123456789abcdefABCDEF][0123456789abcdefABCDEF][0123456789abcdefABCDEF][0123456789abcdefABCDEF]"
    for candidate in "$EFI_BIN" /usr/bin/efibootmgr /usr/sbin/efibootmgr /bin/efibootmgr /sbin/efibootmgr; do
        [[ -n "$candidate" ]] && is_trusted_root_binary "$candidate" || continue
        if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
            seen_paths+="${candidate}|"
            efi_bins+=("$candidate")
        fi
        real_candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
        if [[ -n "$real_candidate" ]] && is_trusted_root_binary "$real_candidate" && [[ "$seen_paths" != *"|${real_candidate}|"* ]]; then
            seen_paths+="${real_candidate}|"
            efi_bins+=("$real_candidate")
        fi
    done
    if (( ${#efi_bins[@]} == 0 )); then
        rm -f "$temporary"
        say "${RED}[!] No usable trusted efibootmgr binary was found.${RESET}"
        return 1
    fi
    for candidate in "${efi_bins[@]}"; do
        commands+="${candidate} -v, ${candidate} -n ${boot_id_pattern}, ${candidate} --bootnext ${boot_id_pattern}, ${candidate} -N, ${candidate} --delete-bootnext, "
    done
    commands+="${HELPER_PATH} exists *, ${HELPER_PATH} read *, ${HELPER_PATH} set-oneshot [A-Za-z0-9]*"
    seen_paths="|"
    if [[ -n "$SYSTEMCTL_BIN" ]]; then
        for candidate in "$SYSTEMCTL_BIN" /usr/bin/systemctl /bin/systemctl /usr/sbin/systemctl /sbin/systemctl; do
            [[ -n "$candidate" ]] && is_trusted_root_binary "$candidate" || continue
            if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
                seen_paths+="${candidate}|"
                systemctl_bins+=("$candidate")
            fi
            real_candidate="$(readlink -f "$candidate" 2>/dev/null || true)"
            if [[ -n "$real_candidate" ]] && is_trusted_root_binary "$real_candidate" && [[ "$seen_paths" != *"|${real_candidate}|"* ]]; then
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
            [[ -n "$candidate" ]] && is_trusted_root_binary "$candidate" || continue
            real_candidate="$(readlink -f "$candidate" 2>/dev/null || printf '%s' "$candidate")"
            if [[ "$(basename "$real_candidate")" == "systemctl" ]]; then
                continue
            fi
            if [[ "$seen_paths" != *"|${candidate}|"* ]]; then
                seen_paths+="${candidate}|"
                reboot_bins+=("$candidate")
            fi
            if [[ -n "$real_candidate" ]] && is_trusted_root_binary "$real_candidate" && [[ "$seen_paths" != *"|${real_candidate}|"* ]]; then
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
    printf '%s ALL=(root) %s\n' "$TARGET_USER" "$commands" > "$temporary"
    if ! visudo_output="$(run_root "$VISUDO_BIN" -cf "$temporary" 2>&1)"; then
        rm -f "$temporary"
        say "${RED}[!] The sudoers rule failed visudo validation: ${visudo_output}${RESET}"
        return 1
    fi
    if run_root test -e "$SUDOERS_PATH" 2>/dev/null; then
        prev_sudoers="$(mktemp)"
        if run_root cat "$SUDOERS_PATH" > "$prev_sudoers" 2>/dev/null; then
            had_prev_sudoers=1
        else
            rm -f "$prev_sudoers"
            prev_sudoers=""
        fi
    fi
    if ! run_root install -d -m 755 -o root -g root "$SUDOERS_DIR"; then
        rm -f "$temporary"
        [[ -n "$prev_sudoers" ]] && rm -f "$prev_sudoers"
        return 1
    fi
    if ! run_root install -m 440 -o root -g root "$temporary" "$SUDOERS_PATH"; then
        rm -f "$temporary"
        if (( had_prev_sudoers == 1 )); then
            run_root install -m 440 -o root -g root "$prev_sudoers" "$SUDOERS_PATH" >/dev/null 2>&1 || true
        fi
        [[ -n "$prev_sudoers" ]] && rm -f "$prev_sudoers"
        return 1
    fi
    rm -f "$temporary"
    if ! visudo_output="$(run_root "$VISUDO_BIN" -cf "$SUDOERS_PATH" 2>&1)"; then
        if (( had_prev_sudoers == 1 )); then
            run_root install -m 440 -o root -g root "$prev_sudoers" "$SUDOERS_PATH" >/dev/null 2>&1 || true
        else
            run_root rm -f "$SUDOERS_PATH"
        fi
        [[ -n "$prev_sudoers" ]] && rm -f "$prev_sudoers"
        say "${RED}[!] The installed sudoers rule failed validation: ${visudo_output}${RESET}"
        return 1
    fi
    if ! visudo_output="$(run_root "$VISUDO_BIN" -c 2>&1)"; then
        su_bad_lines="$(printf '%s\n' "$visudo_output" | grep -F "$SUDOERS_PATH" | grep -Fv ': parsed OK' || true)"
        if [[ -n "$su_bad_lines" ]]; then
            if (( had_prev_sudoers == 1 )); then
                run_root install -m 440 -o root -g root "$prev_sudoers" "$SUDOERS_PATH" >/dev/null 2>&1 || true
            else
                run_root rm -f "$SUDOERS_PATH"
            fi
            [[ -n "$prev_sudoers" ]] && rm -f "$prev_sudoers"
            say "${RED}[!] The active sudoers configuration failed validation: ${su_bad_lines}${RESET}"
            return 1
        fi
        other_bad_lines="$(printf '%s\n' "$visudo_output" | grep -Fv ': parsed OK' | tr '\n' ' ' || true)"
        say "${YELLOW}[!] Warning: An unrelated sudoers file reported an issue (${other_bad_lines}), but ${SUDOERS_PATH} is valid.${RESET}"
    fi
    [[ -n "$prev_sudoers" ]] && rm -f "$prev_sudoers"
    if [[ -f /etc/sudoers ]] && ! run_root grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers\.d/?([[:space:]]|$)' /etc/sudoers 2>/dev/null; then
        say "${YELLOW}[!] Warning: /etc/sudoers does not appear to include /etc/sudoers.d; sudo rules may require enabling @includedir /etc/sudoers.d.${RESET}"
    fi
}

install_boot_binary() {
    local temporary
    temporary="$(mktemp)" || return 1
    {
        printf '#!/usr/bin/env bash\n'
        cat <<'EOF_AUTH'
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
if [[ "${1:-}" != "--complete" && "${MULTIBOOT_NO_AUTH:-0}" != "1" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
        command sudo -k 2>/dev/null || true
        command sudo -v || exit 1
        trap 'command sudo -k 2>/dev/null || true' EXIT INT TERM HUP
    fi
fi
sudo() {
    local -a sudo_opts=() cmd_args=()
    while (( $# > 0 )); do
        case "$1" in
            -n|--non-interactive)
                sudo_opts+=("$1")
                shift
                ;;
            --)
                shift
                cmd_args+=("$@")
                break
                ;;
            *)
                cmd_args+=("$@")
                break
                ;;
        esac
    done
    if (( ${#cmd_args[@]} == 3 )) && [[ "${cmd_args[0]}" == "bootctl" || "${cmd_args[0]}" == */bootctl ]] && [[ "${cmd_args[1]}" == "set-oneshot" ]]; then
        if [[ "${cmd_args[2]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
            command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read set-oneshot "${cmd_args[2]}"
            return $?
        fi
        return 2
    fi
    command sudo "${sudo_opts[@]}" "${cmd_args[@]}"
}
EOF_AUTH
        tail -n +2 "$SRC_SCRIPT"
    } > "$temporary" || {
        rm -f "$temporary"
        return 1
    }
    if ! bash -n "$temporary" >/dev/null 2>&1; then
        rm -f "$temporary"
        return 1
    fi
    if ! run_root install -m 755 -o root -g root "$temporary" "$BIN_PATH"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    return 0
}

validate_safe_user_path() {
    local target="$1"
    local expect_kind="${2:-any}"
    local rel current owner
    local -a components=()
    [[ -n "$TARGET_HOME" && "$TARGET_HOME" == /* && -d "$TARGET_HOME" && ! -L "$TARGET_HOME" ]] || return 1
    if [[ "$TARGET_USER" != "root" ]]; then
        owner="$(stat -c '%u' "$TARGET_HOME" 2>/dev/null || printf '0')"
        [[ "$owner" == "$TARGET_UID" ]] || return 1
    fi
    [[ "$target" == "$TARGET_HOME/"* ]] || return 1
    rel="${target#"$TARGET_HOME"/}"
    [[ -n "$rel" ]] || return 1
    IFS='/' read -ra components <<< "$rel"
    current="$TARGET_HOME"
    local last_idx=$(( ${#components[@]} - 1 ))
    local idx part
    for ((idx = 0; idx <= last_idx; idx++)); do
        part="${components[idx]}"
        [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
        current="$current/$part"
        if [[ -L "$current" ]]; then
            say "${RED}[!] Refusing to follow symbolic link at ${current}.${RESET}"
            return 1
        fi
        if [[ -e "$current" ]]; then
            if (( idx < last_idx )); then
                [[ -d "$current" ]] || return 1
            else
                case "$expect_kind" in
                    dir) [[ -d "$current" ]] || return 1 ;;
                    file) [[ -f "$current" ]] || return 1 ;;
                    any) [[ -d "$current" || -f "$current" ]] || return 1 ;;
                esac
            fi
            if [[ "$TARGET_USER" != "root" ]]; then
                owner="$(stat -c '%u' "$current" 2>/dev/null || printf '0')"
                [[ "$owner" == "$TARGET_UID" ]] || return 1
            fi
        fi
    done
    return 0
}

ensure_safe_user_dir() {
    local dir="$1"
    local rel current owner part
    local -a components=()
    validate_safe_user_path "$dir" "dir" || return 1
    rel="${dir#"$TARGET_HOME"/}"
    IFS='/' read -ra components <<< "$rel"
    current="$TARGET_HOME"
    for part in "${components[@]}"; do
        current="$current/$part"
        if [[ -L "$current" ]]; then
            say "${RED}[!] Refusing to follow symbolic link at ${current}.${RESET}"
            return 1
        fi
        if [[ ! -e "$current" ]]; then
            run_as_target_user mkdir "$current" || return 1
            if [[ -L "$current" ]]; then
                say "${RED}[!] Symbolic link detected after creating ${current}.${RESET}"
                return 1
            fi
            if (( EUID == 0 )); then
                chown -h "$TARGET_UID:$TARGET_GID" "$current" 2>/dev/null || true
            fi
        else
            [[ -d "$current" && ! -L "$current" ]] || return 1
            if [[ "$TARGET_USER" != "root" ]]; then
                owner="$(stat -c '%u' "$current" 2>/dev/null || printf '0')"
                [[ "$owner" == "$TARGET_UID" ]] || return 1
            fi
        fi
    done
    return 0
}

write_user_file() {
    local source="$1"
    local destination="$2"
    local mode="${3:-644}"
    local marker="${4:-}"
    local dest_dir temporary
    validate_safe_user_path "$destination" "file" || return 1
    dest_dir="$(dirname "$destination")"
    if [[ -n "$marker" && -f "$destination" && ! -L "$destination" ]]; then
        if ! grep -Fqx -- "file:$marker" "$STATE_FILE" 2>/dev/null; then
            ensure_safe_user_dir "$STATE_DIR" || return 1
            validate_safe_user_path "$STATE_DIR/backup-$marker" "file" || return 1
            if [[ ! -e "$STATE_DIR/backup-$marker" ]]; then
                run_as_target_user cp -P -- "$destination" "$STATE_DIR/backup-$marker" || return 1
            fi
        fi
    fi
    ensure_safe_user_dir "$dest_dir" || return 1
    validate_safe_user_path "$destination" "file" || return 1
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || return 1
    if ! printf '%s\n' "$source" | run_as_target_user tee "$temporary" >/dev/null; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user chmod "$mode" "$temporary"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! validate_safe_user_path "$destination" "file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user mv -Tf "$temporary" "$destination"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if [[ -n "$marker" ]]; then
        record_added_directive "file:$marker" || return 1
    fi
}

append_unique_line() {
    local file="$1"
    local line="$2"
    local marker="${3:-}"
    local dest_dir temporary file_mode="644"
    validate_safe_user_path "$file" "file" || return 1
    dest_dir="$(dirname "$file")"
    ensure_safe_user_dir "$dest_dir" || return 1
    validate_safe_user_path "$file" "file" || return 1
    if [[ -f "$file" ]]; then
        file_mode="$(stat -c '%a' "$file" 2>/dev/null || printf '644')"
        if grep -Fqx -- "$line" "$file"; then
            return 0
        fi
    fi
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || return 1
    if [[ -f "$file" ]]; then
        if ! run_as_target_user cp -- "$file" "$temporary"; then
            run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    if ! printf '%s\n' "$line" | run_as_target_user tee -a "$temporary" >/dev/null; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user chmod "$file_mode" "$temporary"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! validate_safe_user_path "$file" "file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user mv -Tf "$temporary" "$file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    [[ -n "$marker" ]] && record_added_directive "$marker"
}

record_added_directive() {
    local marker="$1"
    local temporary file_mode="644"
    ensure_safe_user_dir "$STATE_DIR" || return 1
    validate_safe_user_path "$STATE_FILE" "file" || return 1
    if [[ -f "$STATE_FILE" ]]; then
        file_mode="$(stat -c '%a' "$STATE_FILE" 2>/dev/null || printf '644')"
        if grep -Fqx -- "$marker" "$STATE_FILE"; then
            return 0
        fi
    fi
    temporary="$(run_as_target_user mktemp "$STATE_DIR/.multiboot.XXXXXX")" || return 1
    if [[ -f "$STATE_FILE" ]]; then
        if ! run_as_target_user cp -- "$STATE_FILE" "$temporary"; then
            run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    if ! printf '%s\n' "$marker" | run_as_target_user tee -a "$temporary" >/dev/null; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user chmod "$file_mode" "$temporary"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! validate_safe_user_path "$STATE_FILE" "file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user mv -Tf "$temporary" "$STATE_FILE"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
}

prepend_unique_line() {
    local file="$1"
    local line="$2"
    local marker="${3:-}"
    local temporary dest_dir file_mode="644"
    validate_safe_user_path "$file" "file" || return 1
    dest_dir="$(dirname "$file")"
    ensure_safe_user_dir "$dest_dir" || return 1
    validate_safe_user_path "$file" "file" || return 1
    if [[ -f "$file" ]]; then
        file_mode="$(stat -c '%a' "$file" 2>/dev/null || printf '644')"
        if grep -Fqx -- "$line" "$file"; then
            return 0
        fi
    fi
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || return 1
    if ! printf '%s\n' "$line" | run_as_target_user tee "$temporary" >/dev/null; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if [[ -f "$file" ]]; then
        if ! run_as_target_user tee -a "$temporary" < "$file" >/dev/null; then
            run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
            return 1
        fi
    fi
    if ! run_as_target_user chmod "$file_mode" "$temporary"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! validate_safe_user_path "$file" "file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user mv -Tf "$temporary" "$file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    [[ -n "$marker" ]] && record_added_directive "$marker"
}

remove_exact_line() {
    local file="$1"
    local line="$2"
    local temporary dest_dir file_mode="644"
    [[ -e "$file" ]] || return 0
    validate_safe_user_path "$file" "file" || return 1
    [[ -f "$file" ]] || return 0
    dest_dir="$(dirname "$file")"
    file_mode="$(stat -c '%a' "$file" 2>/dev/null || printf '644')"
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || return 1
    if ! awk -v target="$line" '$0 != target' "$file" | run_as_target_user tee "$temporary" >/dev/null; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user chmod "$file_mode" "$temporary"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! validate_safe_user_path "$file" "file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if ! run_as_target_user mv -Tf "$temporary" "$file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
}

configure_shells() {
    local fish_function fish_completion zsh_completion bash_completion nu_completion profile_file bashrc zshrc nu_config fish_history fish_hist_tmp fish_hist_mode="644" timestamp target configured_list="" zsh_single_quoted_dir escaped_target
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
        write_user_file "$fish_function" "$FISH_FUNC_DIR/boot.fish" 644 "fish-func" || return 1
        write_user_file "$fish_completion" "$FISH_COMP_DIR/boot.fish" 644 "fish-comp" || return 1
        ensure_safe_user_dir "$FISH_DATA_DIR" || return 1
        fish_history="$FISH_DATA_DIR/fish_history"
        validate_safe_user_path "$fish_history" "file" || return 1
        if [[ -f "$fish_history" ]]; then
            fish_hist_mode="$(stat -c '%a' "$fish_history" 2>/dev/null || printf '644')"
        fi
        fish_hist_tmp="$(run_as_target_user mktemp "$FISH_DATA_DIR/.multiboot.XXXXXX")" || return 1
        if [[ -f "$fish_history" ]]; then
            if ! run_as_target_user cp -- "$fish_history" "$fish_hist_tmp"; then
                run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
                return 1
            fi
        fi
        timestamp="$(date +%s)"
        for target in "${targets[@]:-}"; do
            [[ -n "$target" ]] || continue
            escaped_target="${target//\'/\'\\\'\'}"
            local history_command="boot '$escaped_target'"
            if ! grep -Fq -- "- cmd: $history_command" "$fish_hist_tmp"; then
                if ! printf -- "- cmd: %s\n  when: %s\n" "$history_command" "$timestamp" | run_as_target_user tee -a "$fish_hist_tmp" >/dev/null; then
                    run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
                    return 1
                fi
            fi
        done
        if ! run_as_target_user chmod "$fish_hist_mode" "$fish_hist_tmp"; then
            run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
            return 1
        fi
        if ! validate_safe_user_path "$fish_history" "file"; then
            run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
            return 1
        fi
        if ! run_as_target_user mv -Tf "$fish_hist_tmp" "$fish_history"; then
            run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
            return 1
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
        write_user_file "$zsh_completion" "$ZSH_COMP_DIR/_boot" 644 "zsh-comp" || return 1
        zshrc="$TARGET_HOME/.zshrc"
        zsh_single_quoted_dir="'${ZSH_COMP_DIR//\'/\'\\\'\'}'"
        prepend_unique_line "$zshrc" "fpath=(${zsh_single_quoted_dir} \$fpath)" zsh-fpath || return 1
        append_unique_line "$zshrc" 'autoload -Uz compinit && compinit' zsh-compinit || return 1
        append_unique_line "$zshrc" 'compdef _boot boot' zsh-compdef || return 1
        configured_list+="Zsh, "
    fi

    if target_uses_bash; then
        bash_completion="_boot_complete() {
    local current=\"\${COMP_WORDS[COMP_CWORD]}\" word unescaped prefix=\"\" quote_mode=\"none\"
    local index i ch
    local -a options typed
    options=(-h --help -l --list -t --test -f --force)
    typed=()
    COMPREPLY=()
    for ((index=1; index<COMP_CWORD; index++)); do
        word=\"\${COMP_WORDS[index]}\"
        case \"\$word\" in
            -h|--help|-l|--list)
                return 0
                ;;
            -f|--force|-t|--test)
                ;;
            *)
                typed+=(\"\$word\")
                ;;
        esac
    done
    if (( COMP_CWORD == 1 )) && [[ -z \"\$current\" || \"\$current\" == -* ]]; then
        for word in \"\${options[@]}\"; do
            [[ \"\$word\" == \"\$current\"* ]] && COMPREPLY+=(\"\$word\")
        done
        [[ \"\$current\" == -* ]] && return 0
    fi
    if (( \${#typed[@]} > 0 )); then
        prefix=\"\${typed[*]} \"
    fi
    prefix+=\"\$current\"
    if [[ \"\$prefix\" == \\\"* ]]; then
        quote_mode=\"double\"
        prefix=\"\${prefix:1}\"
    elif [[ \"\$prefix\" == \\'* ]]; then
        quote_mode=\"single\"
        prefix=\"\${prefix:1}\"
    fi
    unescaped=\"\"
    if [[ \"\$quote_mode\" == \"none\" ]]; then
        for ((i=0; i<\${#prefix}; i++)); do
            ch=\"\${prefix:i:1}\"
            if [[ \"\$ch\" == \"\\\\\" && \$((i + 1)) -lt \${#prefix} ]]; then
                i=\$((i + 1))
                unescaped+=\"\${prefix:i:1}\"
            else
                unescaped+=\"\$ch\"
            fi
        done
    else
        unescaped=\"\$prefix\"
    fi
    local prior_unescaped=\"\"
    if (( \${#typed[@]} > 0 )); then
        local prior_raw=\"\${typed[*]} \"
        for ((i=0; i<\${#prior_raw}; i++)); do
            ch=\"\${prior_raw:i:1}\"
            if [[ \"\$ch\" == \"\\\\\" && \$((i + 1)) -lt \${#prior_raw} ]]; then
                i=\$((i + 1))
                prior_unescaped+=\"\${prior_raw:i:1}\"
            else
                prior_unescaped+=\"\$ch\"
            fi
        done
    fi
    local candidate escaped_candidate
    while IFS= read -r candidate; do
        [[ \"\$candidate\" == \"\$unescaped\"* ]] || continue
        if [[ -n \"\$prior_unescaped\" ]]; then
            candidate=\"\${candidate#\"\$prior_unescaped\"}\"
        fi
        if [[ \"\$quote_mode\" == \"none\" ]]; then
            printf -v escaped_candidate '%q' \"\$candidate\"
            COMPREPLY+=(\"\$escaped_candidate\")
        else
            COMPREPLY+=(\"\$candidate\")
        fi
    done < <(command $BIN_PATH --complete 2>/dev/null)
}
complete -F _boot_complete boot"
        write_user_file "$bash_completion" "$BASH_COMP_DIR/boot" 644 "bash-comp" || return 1
        bashrc="$TARGET_HOME/.bashrc"
        append_unique_line "$bashrc" "[[ -r \"\$HOME/.local/share/bash-completion/completions/boot\" ]] && source \"\$HOME/.local/share/bash-completion/completions/boot\"" bash-completion || return 1
        configured_list+="Bash, "
    fi

    if command -v nu >/dev/null 2>&1 || [[ -d "$NU_DIR" ]]; then
        nu_completion="def 'nu-complete boot' [] {
    ^$BIN_PATH --complete | lines
}
export extern boot [...args: string@\"nu-complete boot\"]"
        write_user_file "$nu_completion" "$NU_DIR/boot.nu" 644 "nu-comp" || return 1
        nu_config="$NU_DIR/config.nu"
        append_unique_line "$nu_config" 'source ~/.config/nushell/boot.nu' nu-source || return 1
        configured_list+="Nushell, "
    fi

    profile_file="$TARGET_HOME/.profile"
    validate_safe_user_path "$profile_file" "file" || return 1
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

rollback_system_files() {
    local backup_dir="$1"
    local exists_bin="$2" had_bin="$3"
    local exists_helper="$4" had_helper="$5"
    local exists_sudoers="$6" had_sudoers="$7"
    if (( had_bin == 1 )); then
        run_root install -d -m 755 -o root -g root "$BIN_DIR" >/dev/null 2>&1 || true
        run_root install -m 755 -o root -g root "$backup_dir/bin" "$BIN_PATH" >/dev/null 2>&1 || true
    elif (( exists_bin == 0 )); then
        run_root rm -f "$BIN_PATH" >/dev/null 2>&1 || true
    fi
    if (( had_helper == 1 )); then
        run_root install -d -m 755 -o root -g root "$LIBEXEC_DIR" >/dev/null 2>&1 || true
        run_root install -m 755 -o root -g root "$backup_dir/helper" "$HELPER_PATH" >/dev/null 2>&1 || true
    elif (( exists_helper == 0 )); then
        run_root rm -f "$HELPER_PATH" >/dev/null 2>&1 || true
    fi
    if (( had_sudoers == 1 )); then
        run_root install -d -m 755 -o root -g root "$SUDOERS_DIR" >/dev/null 2>&1 || true
        run_root install -m 440 -o root -g root "$backup_dir/sudoers" "$SUDOERS_PATH" >/dev/null 2>&1 || true
    elif (( exists_sudoers == 0 )); then
        run_root rm -f "$SUDOERS_PATH" >/dev/null 2>&1 || true
    fi
}

do_install() {
    local action="${1:-install}"
    local first_confirmation second_confirmation backup_dir=""
    local exists_helper=0 had_helper=0 exists_sudoers=0 had_sudoers=0 exists_bin=0 had_bin=0
    if [[ "$action" == "repair" ]]; then
        say "${BLUE}[*] Preparing Multi Boot repair.${RESET}"
        first_confirmation="Repair Multi Boot for ${TARGET_USER}? (y/n)"
        second_confirmation="This will replace the core command, revalidate EFISTUB, refresh sudo UEFI permissions, and rebuild shell integrations. Continue? (y/n)"
    else
        say "${BLUE}[*] Preparing Multi Boot installation.${RESET}"
        first_confirmation="Install Multi Boot for ${TARGET_USER}? (y/n)"
        second_confirmation="This will install a system-wide boot command and configure password-authenticated UEFI boot and reboot permissions. Continue? (y/n)"
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
        trap 'sudo -k 2>/dev/null || true; [[ -n "${backup_dir:-}" ]] && rm -rf "$backup_dir"' EXIT INT TERM HUP
    else
        trap '[[ -n "${backup_dir:-}" ]] && rm -rf "$backup_dir"' EXIT INT TERM HUP
    fi
    ALLOW_ROOT_VERIFY=1
    if ! prepare_dependencies; then
        ALLOW_ROOT_VERIFY=0
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        return 1
    fi
    ALLOW_ROOT_VERIFY=0
    say "${GREEN}[+] EFISTUB requirement passed.${RESET}"
    backup_dir="$(mktemp -d)" || {
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        return 1
    }
    if run_root test -e "$HELPER_PATH" 2>/dev/null; then
        exists_helper=1
        if ! run_root cat "$HELPER_PATH" > "$backup_dir/helper" 2>/dev/null; then
            rm -rf "$backup_dir"
            trap - EXIT INT TERM HUP
            (( EUID != 0 )) && sudo -k 2>/dev/null || true
            say "${RED}[!] Failed to back up existing helper before modification. Installation stopped.${RESET}"
            return 1
        fi
        had_helper=1
    fi
    if run_root test -e "$SUDOERS_PATH" 2>/dev/null; then
        exists_sudoers=1
        if ! run_root cat "$SUDOERS_PATH" > "$backup_dir/sudoers" 2>/dev/null; then
            rm -rf "$backup_dir"
            trap - EXIT INT TERM HUP
            (( EUID != 0 )) && sudo -k 2>/dev/null || true
            say "${RED}[!] Failed to back up existing sudoers rule before modification. Installation stopped.${RESET}"
            return 1
        fi
        had_sudoers=1
    fi
    if run_root test -e "$BIN_PATH" 2>/dev/null; then
        exists_bin=1
        if ! run_root cat "$BIN_PATH" > "$backup_dir/bin" 2>/dev/null; then
            rm -rf "$backup_dir"
            trap - EXIT INT TERM HUP
            (( EUID != 0 )) && sudo -k 2>/dev/null || true
            say "${RED}[!] Failed to back up existing boot command before modification. Installation stopped.${RESET}"
            return 1
        fi
        had_bin=1
    fi
    if ! create_efi_reader_helper; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        rm -rf "$backup_dir"
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        say "${RED}[!] Failed to install the restricted EFI reader helper.${RESET}"
        return 1
    fi
    if ! create_sudoers_rule; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        rm -rf "$backup_dir"
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        return 1
    fi
    if ! run_root install -d -m 755 -o root -g root "$BIN_DIR"; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        rm -rf "$backup_dir"
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        say "${RED}[!] Failed to create the system binary directory.${RESET}"
        return 1
    fi
    if ! install_boot_binary; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        rm -rf "$backup_dir"
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        say "${RED}[!] Failed to install the boot command.${RESET}"
        return 1
    fi
    say "${GREEN}[+] Installed $BIN_PATH.${RESET}"
    if ! configure_shells; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        rm -rf "$backup_dir"
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
        say "${RED}[!] Failed to configure shell integrations; rolled back system files.${RESET}"
        return 1
    fi
    rm -rf "$backup_dir"
    trap - EXIT INT TERM HUP
    (( EUID != 0 )) && sudo -k 2>/dev/null || true
    print_restart_notice
}

do_remove() {
    local has_sys=0 check_path check_dir sys_backup_dir=""
    local exists_bin=0 had_bin=0 exists_helper=0 had_helper=0 exists_sudoers=0 had_sudoers=0
    local -a sys_remaining=()
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
    [[ -e "$BIN_PATH" || -e "$HELPER_PATH" || -e "$SUDOERS_PATH" ]] && has_sys=1
    if (( EUID != 0 )); then
        for check_path in "$FISH_FUNC_DIR/boot.fish" "$FISH_COMP_DIR/boot.fish" "$ZSH_COMP_DIR/_boot" "$BASH_COMP_DIR/boot" "$NU_DIR/boot.nu" "$STATE_FILE"; do
            if [[ -e "$check_path" ]]; then
                check_dir="$(dirname "$check_path")"
                if [[ ! -w "$check_dir" ]]; then
                    say "${RED}[!] Insufficient permissions to modify ${check_dir}. Removal stopped before making changes.${RESET}"
                    return 1
                fi
            fi
        done
        for check_path in "$TARGET_HOME/.zshrc" "$TARGET_HOME/.bashrc" "$NU_DIR/config.nu" "$TARGET_HOME/.profile"; do
            if [[ -f "$check_path" ]]; then
                check_dir="$(dirname "$check_path")"
                if [[ ! -w "$check_path" || ! -w "$check_dir" ]]; then
                    say "${RED}[!] Insufficient permissions to update ${check_path}. Removal stopped before making changes.${RESET}"
                    return 1
                fi
            fi
        done
    fi
    if (( has_sys == 1 )); then
        if (( EUID != 0 )); then
            if ! command -v sudo >/dev/null 2>&1; then
                say "${RED}[!] sudo is required to remove system files. Nothing was removed.${RESET}"
                return 1
            fi
            sudo -v || return 1
            trap 'sudo -k 2>/dev/null || true; [[ -n "${sys_backup_dir:-}" ]] && rm -rf "$sys_backup_dir"' EXIT INT TERM HUP
        else
            trap '[[ -n "${sys_backup_dir:-}" ]] && rm -rf "$sys_backup_dir"' EXIT INT TERM HUP
        fi
        sys_backup_dir="$(mktemp -d)" || {
            trap - EXIT INT TERM HUP
            (( EUID != 0 )) && sudo -k 2>/dev/null || true
            return 1
        }
        if run_root test -e "$BIN_PATH" 2>/dev/null; then
            exists_bin=1
            if run_root cat "$BIN_PATH" > "$sys_backup_dir/bin" 2>/dev/null; then
                had_bin=1
            fi
        fi
        if run_root test -e "$HELPER_PATH" 2>/dev/null; then
            exists_helper=1
            if run_root cat "$HELPER_PATH" > "$sys_backup_dir/helper" 2>/dev/null; then
                had_helper=1
            fi
        fi
        if run_root test -e "$SUDOERS_PATH" 2>/dev/null; then
            exists_sudoers=1
            if run_root cat "$SUDOERS_PATH" > "$sys_backup_dir/sudoers" 2>/dev/null; then
                had_sudoers=1
            fi
        fi
        if ! run_root rm -f "$BIN_PATH" "$HELPER_PATH" "$SUDOERS_PATH"; then
            if (( had_bin == 1 )) && ! run_root test -e "$BIN_PATH" 2>/dev/null; then
                run_root install -m 755 -o root -g root "$sys_backup_dir/bin" "$BIN_PATH" >/dev/null 2>&1 || true
            fi
            if (( had_helper == 1 )) && ! run_root test -e "$HELPER_PATH" 2>/dev/null; then
                run_root install -m 755 -o root -g root "$sys_backup_dir/helper" "$HELPER_PATH" >/dev/null 2>&1 || true
            fi
            if (( had_sudoers == 1 )) && ! run_root test -e "$SUDOERS_PATH" 2>/dev/null; then
                run_root install -m 440 -o root -g root "$sys_backup_dir/sudoers" "$SUDOERS_PATH" >/dev/null 2>&1 || true
            fi
            rm -rf "$sys_backup_dir"
            trap - EXIT INT TERM HUP
            (( EUID != 0 )) && sudo -k 2>/dev/null || true
            for check_path in "$BIN_PATH" "$HELPER_PATH" "$SUDOERS_PATH"; do
                run_root test -e "$check_path" 2>/dev/null && sys_remaining+=("$check_path")
            done
            if (( ${#sys_remaining[@]} > 0 )); then
                say "${RED}[!] Failed to remove system files (${sys_remaining[*]}). User files were left untouched.${RESET}"
            else
                say "${RED}[!] Failed to remove system files. User files were left untouched.${RESET}"
            fi
            return 1
        fi
        rm -rf "$sys_backup_dir"
        trap - EXIT INT TERM HUP
        (( EUID != 0 )) && sudo -k 2>/dev/null || true
    fi
    if [[ -e "$FISH_FUNC_DIR/boot.fish" || -L "$FISH_FUNC_DIR/boot.fish" ]]; then
        validate_safe_user_path "$FISH_FUNC_DIR/boot.fish" "file" || return 1
        if [[ -f "$STATE_DIR/backup-fish-func" && ! -L "$STATE_DIR/backup-fish-func" ]]; then
            validate_safe_user_path "$STATE_DIR/backup-fish-func" "file" || return 1
            run_as_target_user mv -Tf -- "$STATE_DIR/backup-fish-func" "$FISH_FUNC_DIR/boot.fish" || return 1
        elif grep -Fqx 'file:fish-func' "$STATE_FILE" 2>/dev/null || grep -Fq "$BIN_PATH" "$FISH_FUNC_DIR/boot.fish" 2>/dev/null; then
            run_as_target_user rm -f -- "$FISH_FUNC_DIR/boot.fish" || return 1
        else
            say "${YELLOW}[!] Preserved pre-existing file not created by Multi Boot: ${FISH_FUNC_DIR}/boot.fish${RESET}"
        fi
    fi
    if [[ -e "$FISH_COMP_DIR/boot.fish" || -L "$FISH_COMP_DIR/boot.fish" ]]; then
        validate_safe_user_path "$FISH_COMP_DIR/boot.fish" "file" || return 1
        if [[ -f "$STATE_DIR/backup-fish-comp" && ! -L "$STATE_DIR/backup-fish-comp" ]]; then
            validate_safe_user_path "$STATE_DIR/backup-fish-comp" "file" || return 1
            run_as_target_user mv -Tf -- "$STATE_DIR/backup-fish-comp" "$FISH_COMP_DIR/boot.fish" || return 1
        elif grep -Fqx 'file:fish-comp' "$STATE_FILE" 2>/dev/null || grep -Fq "$BIN_PATH" "$FISH_COMP_DIR/boot.fish" 2>/dev/null; then
            run_as_target_user rm -f -- "$FISH_COMP_DIR/boot.fish" || return 1
        else
            say "${YELLOW}[!] Preserved pre-existing file not created by Multi Boot: ${FISH_COMP_DIR}/boot.fish${RESET}"
        fi
    fi
    if [[ -e "$ZSH_COMP_DIR/_boot" || -L "$ZSH_COMP_DIR/_boot" ]]; then
        validate_safe_user_path "$ZSH_COMP_DIR/_boot" "file" || return 1
        if [[ -f "$STATE_DIR/backup-zsh-comp" && ! -L "$STATE_DIR/backup-zsh-comp" ]]; then
            validate_safe_user_path "$STATE_DIR/backup-zsh-comp" "file" || return 1
            run_as_target_user mv -Tf -- "$STATE_DIR/backup-zsh-comp" "$ZSH_COMP_DIR/_boot" || return 1
        elif grep -Fqx 'file:zsh-comp' "$STATE_FILE" 2>/dev/null || grep -Fq "$BIN_PATH" "$ZSH_COMP_DIR/_boot" 2>/dev/null; then
            run_as_target_user rm -f -- "$ZSH_COMP_DIR/_boot" || return 1
        else
            say "${YELLOW}[!] Preserved pre-existing file not created by Multi Boot: ${ZSH_COMP_DIR}/_boot${RESET}"
        fi
    fi
    if [[ -e "$BASH_COMP_DIR/boot" || -L "$BASH_COMP_DIR/boot" ]]; then
        validate_safe_user_path "$BASH_COMP_DIR/boot" "file" || return 1
        if [[ -f "$STATE_DIR/backup-bash-comp" && ! -L "$STATE_DIR/backup-bash-comp" ]]; then
            validate_safe_user_path "$STATE_DIR/backup-bash-comp" "file" || return 1
            run_as_target_user mv -Tf -- "$STATE_DIR/backup-bash-comp" "$BASH_COMP_DIR/boot" || return 1
        elif grep -Fqx 'file:bash-comp' "$STATE_FILE" 2>/dev/null || grep -Fq "$BIN_PATH" "$BASH_COMP_DIR/boot" 2>/dev/null; then
            run_as_target_user rm -f -- "$BASH_COMP_DIR/boot" || return 1
        else
            say "${YELLOW}[!] Preserved pre-existing file not created by Multi Boot: ${BASH_COMP_DIR}/boot${RESET}"
        fi
    fi
    if [[ -e "$NU_DIR/boot.nu" || -L "$NU_DIR/boot.nu" ]]; then
        validate_safe_user_path "$NU_DIR/boot.nu" "file" || return 1
        if [[ -f "$STATE_DIR/backup-nu-comp" && ! -L "$STATE_DIR/backup-nu-comp" ]]; then
            validate_safe_user_path "$STATE_DIR/backup-nu-comp" "file" || return 1
            run_as_target_user mv -Tf -- "$STATE_DIR/backup-nu-comp" "$NU_DIR/boot.nu" || return 1
        elif grep -Fqx 'file:nu-comp' "$STATE_FILE" 2>/dev/null || grep -Fq "$BIN_PATH" "$NU_DIR/boot.nu" 2>/dev/null; then
            run_as_target_user rm -f -- "$NU_DIR/boot.nu" || return 1
        else
            say "${YELLOW}[!] Preserved pre-existing file not created by Multi Boot: ${NU_DIR}/boot.nu${RESET}"
        fi
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'zsh-fpath' "$STATE_FILE"; then
        local zsh_single_quoted_dir="'${ZSH_COMP_DIR//\'/\'\\\'\'}'"
        remove_exact_line "$TARGET_HOME/.zshrc" "fpath=(${zsh_single_quoted_dir} \$fpath)" || return 1
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
    if [[ -e "$STATE_DIR" ]]; then
        validate_safe_user_path "$STATE_DIR" "dir" || return 1
        run_as_target_user rm -f -- "$STATE_FILE" "$STATE_DIR/backup-fish-func" "$STATE_DIR/backup-fish-comp" "$STATE_DIR/backup-zsh-comp" "$STATE_DIR/backup-bash-comp" "$STATE_DIR/backup-nu-comp"
        run_as_target_user rmdir "$STATE_DIR" 2>/dev/null || true
    fi
    say "${GREEN}Multi Boot was removed.${RESET}"
    say "${YELLOW}Please restart your Terminal or start a new login session.${RESET}"
}

show_efistub_status() {
    if ! detect_current_efistub; then
        say "${RED}[!] EFISTUB: ${EFISTUB_REASON}${RESET}"
        return 1
    fi
    MCOPY_BIN="$(resolve_binary mcopy 2>/dev/null || true)"
    MDIR_BIN="$(resolve_binary mdir 2>/dev/null || true)"
    if [[ -z "$MCOPY_BIN" || -z "$MDIR_BIN" ]]; then
        say "${YELLOW}[!] EFISTUB: ${EFISTUB_REASON} Image verification is unavailable because mtools is missing.${RESET}"
        return 0
    fi
    if verify_current_efistub_file; then
        say "${GREEN}[+] EFISTUB: ${EFISTUB_REASON}${RESET}"
    else
        say "${RED}[!] EFISTUB: ${EFISTUB_REASON}${RESET}"
        return 1
    fi
}

do_status() {
    local state pm_detected shells_summary=""
    say "${BLUE}Multi Boot Status${RESET}"
    state="$(installation_state)"
    case "$state" in
        Installed) say "${GREEN}[+] Installation: Complete${RESET}" ;;
        Incomplete) say "${YELLOW}[!] Installation: Incomplete${RESET}" ;;
        *) say "${RED}[-] Installation: Not installed${RESET}" ;;
    esac
    pm_detected="$(detect_package_manager 2>/dev/null || printf 'unknown')"
    say "${BLUE}[*] Package manager: ${pm_detected}${RESET}"
    if [[ -x "$BIN_PATH" ]]; then
        say "${GREEN}[+] Core: Installed at ${BIN_PATH}${RESET}"
    else
        say "${RED}[-] Core: Missing${RESET}"
    fi
    if [[ -f "$SUDOERS_PATH" ]]; then
        if [[ -z "$VISUDO_BIN" ]]; then
            VISUDO_BIN="$(resolve_binary visudo 2>/dev/null || true)"
        fi
        if (( EUID == 0 )) || [[ -r "$SUDOERS_PATH" ]]; then
            if [[ -n "$VISUDO_BIN" ]]; then
                if "$VISUDO_BIN" -cf "$SUDOERS_PATH" >/dev/null 2>&1; then
                    if grep -Eq 'NOPASSWD|timestamp_timeout|set-oneshot \*' "$SUDOERS_PATH" 2>/dev/null; then
                        say "${YELLOW}[!] Sudoers: Valid syntax, but contains legacy permissive directives (run Repair)${RESET}"
                    else
                        say "${GREEN}[+] Sudoers: Valid (password-authenticated)${RESET}"
                    fi
                else
                    say "${RED}[-] Sudoers: Invalid${RESET}"
                fi
            else
                say "${YELLOW}[!] Sudoers: Present, but visudo is unavailable${RESET}"
            fi
        else
            local sudoers_meta
            sudoers_meta="$(stat -c '%u:%g:%a' "$SUDOERS_PATH" 2>/dev/null || true)"
            if [[ "$sudoers_meta" == "0:0:440" || "$sudoers_meta" == "0:0:400" ]]; then
                say "${GREEN}[+] Sudoers: Installed with secure permissions (0440 root:root)${RESET}"
            else
                say "${RED}[-] Sudoers: Unexpected ownership/permissions (${sudoers_meta})${RESET}"
            fi
        fi
    else
        say "${RED}[-] Sudoers: Not configured${RESET}"
    fi
    [[ -x "$HELPER_PATH" ]] && say "${GREEN}[+] EFI reader helper: Installed${RESET}" || say "${RED}[-] EFI reader helper: Missing${RESET}"
    if [[ -x "$(resolve_binary efibootmgr 2>/dev/null || true)" ]]; then
        say "${GREEN}[+] efibootmgr: Available${RESET}"
    else
        say "${RED}[-] efibootmgr: Missing ($(diagnose_binary efibootmgr))${RESET}"
    fi
    if [[ -x "$(resolve_binary mcopy 2>/dev/null || true)" && -x "$(resolve_binary mdir 2>/dev/null || true)" ]]; then
        say "${GREEN}[+] mtools: Available${RESET}"
    else
        say "${RED}[-] mtools: Missing (mcopy: $(diagnose_binary mcopy); mdir: $(diagnose_binary mdir))${RESET}"
    fi
    [[ -f "$FISH_FUNC_DIR/boot.fish" && -f "$FISH_COMP_DIR/boot.fish" ]] && shells_summary+="Fish "
    [[ -f "$ZSH_COMP_DIR/_boot" ]] && shells_summary+="Zsh "
    [[ -f "$BASH_COMP_DIR/boot" ]] && shells_summary+="Bash "
    [[ -f "$NU_DIR/boot.nu" ]] && shells_summary+="Nushell "
    if [[ -n "$shells_summary" ]]; then
        say "${GREEN}[+] Shell integrations: ${shells_summary% }${RESET}"
    else
        say "${YELLOW}[-] Shell integrations: None installed${RESET}"
    fi
    show_efistub_status || true
    if [[ -x "$BIN_PATH" ]]; then
        MULTIBOOT_NO_AUTH=1 "$BIN_PATH" -l || true
    fi
}

show_menu() {
    while true; do
        printf '\033[2J\033[H'
        say "${BOLD}${GREEN}Multi Boot Management${RESET}"
        local state
        state="$(installation_state)"
        case "$state" in
            Installed) say "Status: ${GREEN}Installed${RESET}" ;;
            Incomplete) say "Status: ${YELLOW}Incomplete${RESET}" ;;
            *) say "Status: ${RED}Not installed${RESET}" ;;
        esac
        say "User: ${CYAN}${TARGET_USER}${RESET} (${TARGET_GROUP})"
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
