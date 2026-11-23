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
SYS_STATE_DIR=/var/lib/multiboot
SYS_MANIFEST="$SYS_STATE_DIR/system-files.manifest"

SYS_PROFILE_SH=/etc/profile.d/multiboot.sh
SYS_PROFILE_CSH=/etc/profile.d/multiboot.csh
SYS_BASH_COMP_DIR=/usr/local/share/bash-completion/completions
SYS_BASH_COMP="$SYS_BASH_COMP_DIR/boot"
SYS_ZSH_COMP_DIR=/usr/local/share/zsh/site-functions
SYS_ZSH_COMP="$SYS_ZSH_COMP_DIR/_boot"
SYS_FISH_FUNC_DIR=/usr/share/fish/vendor_functions.d
SYS_FISH_FUNC="$SYS_FISH_FUNC_DIR/boot.fish"
SYS_FISH_COMP_DIR=/usr/share/fish/vendor_completions.d
SYS_FISH_COMP="$SYS_FISH_COMP_DIR/boot.fish"

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
        PASSWD_RECORD="$(awk -F: -v uid="$TARGET_USER" '$3 == uid { print; exit }' /etc/passwd 2>/dev/null || true)"
    else
        PASSWD_RECORD="$(awk -F: -v user="$TARGET_USER" '$1 == user { print; exit }' /etc/passwd 2>/dev/null || true)"
    fi
fi
if [[ -z "$PASSWD_RECORD" ]]; then
    printf '%s\n' "Unable to resolve the target user account."
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
if [[ "$TARGET_HOME" != "/" ]]; then
    TARGET_HOME="${TARGET_HOME%/}"
fi
if [[ "$TARGET_HOME" == *$'\n'* || "$TARGET_HOME" == *$'\r'* ]]; then
    printf '%s\n' "Invalid control characters in target user home directory path."
    exit 1
fi

HOME_PREFIX="$TARGET_HOME"
[[ "$HOME_PREFIX" == "/" ]] && HOME_PREFIX=""

FISH_DIR="$HOME_PREFIX/.config/fish"
FISH_FUNC_DIR="$FISH_DIR/functions"
FISH_COMP_DIR="$FISH_DIR/completions"
FISH_DATA_DIR="$HOME_PREFIX/.local/share/fish"
ZSH_COMP_DIR="$HOME_PREFIX/.zsh/completions"
BASH_COMP_DIR="$HOME_PREFIX/.local/share/bash-completion/completions"
NU_DIR="$HOME_PREFIX/.config/nushell"
ELVISH_DIR="$HOME_PREFIX/.config/elvish"
ELVISH_LIB_DIR="$ELVISH_DIR/lib"
XONSH_DIR="$HOME_PREFIX/.config/xonsh"
XONSH_RCD_DIR="$XONSH_DIR/rc.d"
PWSH_DIR="$HOME_PREFIX/.config/powershell"
OILS_DIR="$HOME_PREFIX/.config/oils"
ION_DIR="$HOME_PREFIX/.config/ion"
STATE_DIR="$HOME_PREFIX/.local/share/multiboot"
STATE_FILE="$STATE_DIR/installed-directives"
CACHE_DIR="$HOME_PREFIX/.cache/multiboot"

BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[1;31m'
GREEN=$'\033[1;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[1;34m'
CYAN=$'\033[1;36m'
RESET=$'\033[0m'

APT_UPDATED=0
SUDO_AUTHENTICATED=0
ALLOW_ROOT_VERIFY=0
AUTO_YES=0
EFI_BIN=""
MCOPY_BIN=""
MDIR_BIN=""
PYTHON_BIN=""
SYSTEMCTL_BIN=""
BOOTCTL_BIN=""
GRUB_REBOOT_BIN=""
REBOOT_BIN=""
VISUDO_BIN=""
EFISTUB_STATUS="Not verified"
EFISTUB_REASON=""
EFISTUB_PARTUUID=""
EFISTUB_LOADER=""
EFISTUB_OPTS=""
_ACTIVE_CLEANUP_DIR=""

declare -A BIN_CACHE=()
declare -A DETECTED_SHELLS=()

cleanup_active_state() {
    if [[ -n "${_ACTIVE_CLEANUP_DIR:-}" && -d "$_ACTIVE_CLEANUP_DIR" ]]; then
        rm -rf "$_ACTIVE_CLEANUP_DIR" 2>/dev/null || true
    fi
    _ACTIVE_CLEANUP_DIR=""
    if (( EUID != 0 && SUDO_AUTHENTICATED == 1 )); then
        sudo -k 2>/dev/null || true
        SUDO_AUTHENTICATED=0
    fi
}

trap cleanup_active_state EXIT INT TERM HUP

say() {
    printf '%b\n' "$*"
}

authenticate_root() {
    if (( EUID == 0 )); then
        return 0
    fi
    if ! command -v sudo >/dev/null 2>&1; then
        say "${RED}[!] sudo is required for privileged system operations.${RESET}"
        return 1
    fi
    if sudo -v; then
        SUDO_AUTHENTICATED=1
        return 0
    fi
    return 1
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
    local resolved current owner gid group mode
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
                gid="$(stat -L -c '%g' "$current" 2>/dev/null || printf '1')"
                group="$(stat -L -c '%G' "$current" 2>/dev/null || printf '')"
            else
                mode="$(stat -c '%a' "$current" 2>/dev/null || printf '777')"
                gid="$(stat -c '%g' "$current" 2>/dev/null || printf '1')"
                group="$(stat -c '%G' "$current" 2>/dev/null || printf '')"
            fi
            (( (8#$mode & 8#0002) == 0 )) || return 1
            if (( (8#$mode & 8#0020) != 0 )); then
                if [[ "$gid" != "0" && !( "$current" == /usr/local* && "$group" == "staff" ) ]]; then
                    return 1
                fi
            fi
            [[ "$current" == "/" ]] && break
            current="$(dirname "$current")"
        done
    done
    return 0
}

resolve_binary() {
    local name="$1"
    if [[ -n "${BIN_CACHE[$name]+x}" ]]; then
        [[ -n "${BIN_CACHE[$name]}" ]] || return 1
        printf '%s' "${BIN_CACHE[$name]}"
        return 0
    fi
    local path="" dir="" seen="|"
    local -a search_dirs=("/usr/bin" "/usr/sbin" "/bin" "/sbin" "/usr/local/bin" "/usr/local/sbin" "/run/current-system/sw/bin" "/nix/var/nix/profiles/default/bin")
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
            BIN_CACHE[$name]="$path"
            printf '%s' "$path"
            return 0
        fi
    done
    BIN_CACHE[$name]=""
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
        cmd_str="${cmd_str% }"
        "$su_bin" -s "$bash_bin" "$TARGET_USER" -c "$cmd_str"
        return $?
    fi
    return 1
}

detect_all_shells() {
    DETECTED_SHELLS=()
    local line bin base dir
    local -a shell_names=(bash zsh fish nu elvish xonsh pwsh tcsh csh ksh ksh93 mksh oksh pdksh dash ash osh ysh ion murex)
    local -a extra_dirs=("/bin" "/usr/bin" "/usr/local/bin" "/sbin" "/usr/sbin" "/opt/homebrew/bin" "/home/linuxbrew/.linuxbrew/bin" "/run/current-system/sw/bin" "/nix/var/nix/profiles/default/bin" "$HOME_PREFIX/.nix-profile/bin" "$HOME_PREFIX/.local/bin" "$HOME_PREFIX/.cargo/bin")

    if [[ -n "$TARGET_SHELL" ]]; then
        base="${TARGET_SHELL##*/}"
        case "$base" in
            bash|zsh|fish|nu|elvish|xonsh|pwsh|tcsh|csh|ksh|ksh93|mksh|oksh|pdksh|dash|ash|osh|ysh|ion|murex|sh)
                DETECTED_SHELLS["$base"]="$TARGET_SHELL"
                ;;
        esac
    fi

    if [[ -r /etc/shells ]]; then
        while IFS= read -r line; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [[ -n "$line" && -x "$line" ]] || continue
            base="${line##*/}"
            DETECTED_SHELLS["$base"]="$line"
        done < /etc/shells
    fi

    for base in "${shell_names[@]}"; do
        if [[ -z "${DETECTED_SHELLS[$base]+x}" ]]; then
            bin="$(command -v "$base" 2>/dev/null || true)"
            if [[ -n "$bin" && -x "$bin" ]]; then
                DETECTED_SHELLS["$base"]="$bin"
                continue
            fi
            for dir in "${extra_dirs[@]}"; do
                if [[ -x "$dir/$base" ]]; then
                    DETECTED_SHELLS["$base"]="$dir/$base"
                    break
                fi
            done
        fi
    done

    [[ -f "$HOME_PREFIX/.bashrc" || -f "$HOME_PREFIX/.bash_profile" || -f "$HOME_PREFIX/.bash_login" || -d "$BASH_COMP_DIR" ]] && DETECTED_SHELLS["bash"]="${DETECTED_SHELLS[bash]:-/bin/bash}"
    [[ -f "$HOME_PREFIX/.zshrc" || -f "$HOME_PREFIX/.zprofile" || -f "$HOME_PREFIX/.zshenv" || -d "$HOME_PREFIX/.zsh" ]] && DETECTED_SHELLS["zsh"]="${DETECTED_SHELLS[zsh]:-/bin/zsh}"
    [[ -d "$FISH_DIR" ]] && DETECTED_SHELLS["fish"]="${DETECTED_SHELLS[fish]:-/usr/bin/fish}"
    [[ -d "$NU_DIR" ]] && DETECTED_SHELLS["nu"]="${DETECTED_SHELLS[nu]:-/usr/bin/nu}"
    [[ -d "$ELVISH_DIR" ]] && DETECTED_SHELLS["elvish"]="${DETECTED_SHELLS[elvish]:-/usr/bin/elvish}"
    [[ -f "$HOME_PREFIX/.xonshrc" || -d "$XONSH_DIR" ]] && DETECTED_SHELLS["xonsh"]="${DETECTED_SHELLS[xonsh]:-/usr/bin/xonsh}"
    [[ -d "$PWSH_DIR" ]] && DETECTED_SHELLS["pwsh"]="${DETECTED_SHELLS[pwsh]:-/usr/bin/pwsh}"
    [[ -f "$HOME_PREFIX/.tcshrc" ]] && DETECTED_SHELLS["tcsh"]="${DETECTED_SHELLS[tcsh]:-/bin/tcsh}"
    [[ -f "$HOME_PREFIX/.cshrc" ]] && DETECTED_SHELLS["csh"]="${DETECTED_SHELLS[csh]:-/bin/csh}"
    [[ -f "$HOME_PREFIX/.kshrc" ]] && DETECTED_SHELLS["ksh"]="${DETECTED_SHELLS[ksh]:-/bin/ksh}"
    [[ -f "$HOME_PREFIX/.mkshrc" ]] && DETECTED_SHELLS["mksh"]="${DETECTED_SHELLS[mksh]:-/bin/mksh}"
    [[ -d "$OILS_DIR" ]] && DETECTED_SHELLS["osh"]="${DETECTED_SHELLS[osh]:-/usr/bin/osh}"
    [[ -d "$ION_DIR" ]] && DETECTED_SHELLS["ion"]="${DETECTED_SHELLS[ion]:-/usr/bin/ion}"
    [[ -f "$HOME_PREFIX/.murex_profile" || -f "$HOME_PREFIX/.murex_preload" ]] && DETECTED_SHELLS["murex"]="${DETECTED_SHELLS[murex]:-/usr/bin/murex}"
}

has_shell_family() {
    local family="$1"
    case "$family" in
        bash) [[ -n "${DETECTED_SHELLS[bash]+x}" ]] ;;
        zsh) [[ -n "${DETECTED_SHELLS[zsh]+x}" ]] ;;
        fish) [[ -n "${DETECTED_SHELLS[fish]+x}" ]] ;;
        nu) [[ -n "${DETECTED_SHELLS[nu]+x}" ]] ;;
        elvish) [[ -n "${DETECTED_SHELLS[elvish]+x}" ]] ;;
        xonsh) [[ -n "${DETECTED_SHELLS[xonsh]+x}" ]] ;;
        pwsh) [[ -n "${DETECTED_SHELLS[pwsh]+x}" ]] ;;
        tcsh) [[ -n "${DETECTED_SHELLS[tcsh]+x}" || -n "${DETECTED_SHELLS[csh]+x}" ]] ;;
        ksh) [[ -n "${DETECTED_SHELLS[ksh]+x}" || -n "${DETECTED_SHELLS[ksh93]+x}" || -n "${DETECTED_SHELLS[mksh]+x}" || -n "${DETECTED_SHELLS[oksh]+x}" || -n "${DETECTED_SHELLS[pdksh]+x}" ]] ;;
        oils) [[ -n "${DETECTED_SHELLS[osh]+x}" || -n "${DETECTED_SHELLS[ysh]+x}" ]] ;;
        ion) [[ -n "${DETECTED_SHELLS[ion]+x}" ]] ;;
        murex) [[ -n "${DETECTED_SHELLS[murex]+x}" ]] ;;
        posix) [[ -n "${DETECTED_SHELLS[dash]+x}" || -n "${DETECTED_SHELLS[ash]+x}" || -n "${DETECTED_SHELLS[sh]+x}" ]] ;;
        *) return 1 ;;
    esac
}

format_detected_shells_list() {
    detect_all_shells
    local out=""
    has_shell_family bash && out+="Bash, "
    has_shell_family zsh && out+="Zsh, "
    has_shell_family fish && out+="Fish, "
    has_shell_family nu && out+="Nushell, "
    has_shell_family elvish && out+="Elvish, "
    has_shell_family xonsh && out+="Xonsh, "
    has_shell_family pwsh && out+="PowerShell, "
    has_shell_family tcsh && out+="Tcsh/Csh, "
    has_shell_family ksh && out+="Ksh/Mksh, "
    has_shell_family oils && out+="Oils (osh/ysh), "
    has_shell_family ion && out+="Ion, "
    has_shell_family murex && out+="Murex, "
    has_shell_family posix && out+="POSIX (sh/dash/ash), "
    if [[ -n "$out" ]]; then
        printf '%s' "${out%, }"
    else
        printf 'POSIX sh'
    fi
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
    grep -Fq 'create-uefi-entry' "$HELPER_PATH" 2>/dev/null || return 1
    visudo_check="$(resolve_binary visudo 2>/dev/null || true)"
    if (( EUID == 0 )) || [[ -r "$SUDOERS_PATH" ]]; then
        [[ -f "$SUDOERS_PATH" && -s "$SUDOERS_PATH" ]] || return 1
        grep -Fq "$HELPER_PATH" "$SUDOERS_PATH" 2>/dev/null || return 1
        if grep -Eq 'NOPASSWD|timestamp_timeout|set-oneshot \*' "$SUDOERS_PATH" 2>/dev/null; then
            return 1
        fi
        if [[ -n "$visudo_check" ]]; then
            "$visudo_check" -cf "$SUDOERS_PATH" >/dev/null 2>&1 || return 1
        fi
    elif [[ -x "$SUDOERS_DIR" ]]; then
        [[ -f "$SUDOERS_PATH" ]] || return 1
        sudoers_meta="$(stat -c '%u:%g:%a' "$SUDOERS_PATH" 2>/dev/null || true)"
        [[ "$sudoers_meta" == "0:0:440" || "$sudoers_meta" == "0:0:400" ]] || return 1
        if command -v sudo >/dev/null 2>&1 && [[ -n "$visudo_check" ]]; then
            if sudo -n true >/dev/null 2>&1; then
                sudo -n "$visudo_check" -cf "$SUDOERS_PATH" >/dev/null 2>&1 || return 1
            fi
        fi
    else
        [[ -d "$SUDOERS_DIR" && -f "$SYS_MANIFEST" ]] || return 1
        if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
            sudo -n test -s "$SUDOERS_PATH" >/dev/null 2>&1 || return 1
            if [[ -n "$visudo_check" ]]; then
                sudo -n "$visudo_check" -cf "$SUDOERS_PATH" >/dev/null 2>&1 || return 1
            fi
        fi
    fi
    detect_all_shells
    if has_shell_family fish; then
        [[ -f "$FISH_FUNC_DIR/boot.fish" && -f "$FISH_COMP_DIR/boot.fish" ]] || return 1
    fi
    if has_shell_family zsh; then
        [[ -f "$ZSH_COMP_DIR/_boot" ]] || return 1
    fi
    if has_shell_family bash; then
        [[ -f "$BASH_COMP_DIR/boot" ]] || return 1
    fi
    if has_shell_family nu; then
        [[ -f "$NU_DIR/boot.nu" ]] || return 1
    fi
    if has_shell_family elvish; then
        [[ -f "$ELVISH_LIB_DIR/boot.elv" ]] || return 1
    fi
    if has_shell_family xonsh; then
        [[ -f "$XONSH_RCD_DIR/boot.xsh" ]] || return 1
    fi
    return 0
}

installation_state() {
    if is_installed; then
        printf 'Installed'
    elif [[ -e "$BIN_PATH" || -e "$HELPER_PATH" || -e "$SUDOERS_PATH" || -e "$STATE_FILE" || -e "$SYS_MANIFEST" ]]; then
        printf 'Incomplete'
    else
        printf 'Not installed'
    fi
}

confirm_twice() {
    local first="$1"
    local second="$2"
    local answer=""
    if (( AUTO_YES == 1 )); then
        return 0
    fi
    say "${YELLOW}${first}${RESET}"
    printf '> '
    read -r answer || return 1
    [[ "${answer,,}" == y || "${answer,,}" == yes ]] || return 1
    say "${RED}${second}${RESET}"
    printf '> '
    read -r answer || return 1
    [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

confirm_once() {
    local prompt="$1"
    local answer=""
    if (( AUTO_YES == 1 )); then
        return 0
    fi
    say "${YELLOW}${prompt}${RESET}"
    printf '> '
    read -r answer || return 1
    [[ "${answer,,}" == y || "${answer,,}" == yes ]]
}

has_pm() {
    command -v "$1" >/dev/null 2>&1 || resolve_binary "$1" >/dev/null 2>&1
}

detect_distro_id() {
    local os_id=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(awk -F= '/^ID=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
    fi
    printf '%s' "${os_id:-linux}"
}

detect_package_manager() {
    local os_id="" os_like=""
    if [[ -r /etc/os-release ]]; then
        os_id="$(awk -F= '/^ID=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
        os_like="$(awk -F= '/^ID_LIKE=/ {gsub(/["'\'']/, "", $2); print tolower($2); exit}' /etc/os-release 2>/dev/null || true)"
    fi
    if has_pm rpm-ostree && [[ -f /run/ostree-booted ]]; then
        printf 'rpm-ostree'
        return 0
    fi
    case " $os_id $os_like " in
        *" debian "*|*" ubuntu "*|*" linuxmint "*|*" pop "*|*" kali "*|*" elementary "*|*" zorin "*|*" neon "*|*" tuxedo "*)
            if has_pm apt-get; then printf 'apt-get'; return 0; fi ;;
        *" arch "*|*" manjaro "*|*" endeavouros "*|*" cachyos "*|*" garuda "*|*" artix "*)
            if has_pm pacman; then printf 'pacman'; return 0; fi ;;
        *" fedora "*|*" rhel "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*|*" nobara "*|*" bazzite "*)
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
        *" nixos "*)
            if has_pm nix-env; then printf 'nix-env'; return 0; fi ;;
        *" solus "*)
            if has_pm eopkg; then printf 'eopkg'; return 0; fi ;;
        *" clear-linux-os "*)
            if has_pm swupd; then printf 'swupd'; return 0; fi ;;
        *" slackware "*)
            if has_pm slackpkg; then printf 'slackpkg'; return 0; fi ;;
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
    elif has_pm eopkg; then
        printf 'eopkg'
    elif has_pm swupd; then
        printf 'swupd'
    elif has_pm nix-env; then
        printf 'nix-env'
    elif has_pm slackpkg; then
        printf 'slackpkg'
    else
        return 1
    fi
}

map_distro_package_name() {
    local logical_pkg="$1"
    local pm="$2"
    case "$logical_pkg" in
        efibootmgr)
            case "$pm" in
                emerge) printf 'sys-boot/efibootmgr' ;;
                nix-env) printf 'nixpkgs.efibootmgr' ;;
                *) printf 'efibootmgr' ;;
            esac
            ;;
        mtools)
            case "$pm" in
                emerge) printf 'sys-fs/mtools' ;;
                nix-env) printf 'nixpkgs.mtools' ;;
                *) printf 'mtools' ;;
            esac
            ;;
        python3)
            case "$pm" in
                pacman) printf 'python' ;;
                emerge) printf 'dev-lang/python' ;;
                nix-env) printf 'nixpkgs.python3' ;;
                swupd) printf 'python3-basic' ;;
                *) printf 'python3' ;;
            esac
            ;;
        sudo)
            case "$pm" in
                emerge) printf 'app-admin/sudo' ;;
                nix-env) printf 'nixpkgs.sudo' ;;
                *) printf 'sudo' ;;
            esac
            ;;
        util-linux)
            case "$pm" in
                emerge) printf 'sys-apps/util-linux' ;;
                nix-env) printf 'nixpkgs.util-linux' ;;
                *) printf 'util-linux' ;;
            esac
            ;;
        *)
            printf '%s' "$logical_pkg"
            ;;
    esac
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
        python3)
            resolve_binary python3 >/dev/null 2>&1
            ;;
        sudo)
            resolve_binary visudo >/dev/null 2>&1
            ;;
        util-linux)
            resolve_binary lsblk >/dev/null 2>&1 && resolve_binary blkid >/dev/null 2>&1 && resolve_binary findmnt >/dev/null 2>&1
            ;;
        *)
            return 0
            ;;
    esac
}

install_single_package() {
    local logical_pkg="$1"
    local pm="$2"
    local distro_pkg
    distro_pkg="$(map_distro_package_name "$logical_pkg" "$pm")"
    if package_binaries_ready "$logical_pkg"; then
        say "${GREEN}[+] ${logical_pkg} is already installed and verified.${RESET}"
        return 0
    fi
    say "${YELLOW}[*] Installing ${logical_pkg} (package: ${distro_pkg}, manager: ${pm})...${RESET}"
    case "$pm" in
        apt-get)
            if ! run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$distro_pkg" >/dev/null 2>&1; then
                if (( APT_UPDATED == 0 )); then
                    run_root apt-get update -qq >/dev/null 2>&1 || true
                    APT_UPDATED=1
                fi
                run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$distro_pkg" || return 1
            fi
            if ! package_binaries_ready "$logical_pkg"; then
                run_root env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y --no-install-recommends "$distro_pkg" || return 1
            fi
            ;;
        pacman)
            run_root pacman -S --needed --noconfirm "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root pacman -S --noconfirm "$distro_pkg" || return 1
            fi
            ;;
        dnf)
            run_root dnf install -y "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root dnf reinstall -y "$distro_pkg" || return 1
            fi
            ;;
        rpm-ostree)
            run_root rpm-ostree install --idempotent --apply-live "$distro_pkg" || run_root rpm-ostree install --idempotent "$distro_pkg" || return 1
            ;;
        zypper)
            run_root zypper --non-interactive install -y "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root zypper --non-interactive install -f -y "$distro_pkg" || return 1
            fi
            ;;
        xbps-install)
            run_root xbps-install -Sy "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root xbps-install -fy "$distro_pkg" || return 1
            fi
            ;;
        apk)
            run_root apk add "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root apk fix "$distro_pkg" || return 1
            fi
            ;;
        yum)
            run_root yum install -y "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root yum reinstall -y "$distro_pkg" || return 1
            fi
            ;;
        emerge)
            run_root emerge --noreplace "$distro_pkg" || return 1
            if ! package_binaries_ready "$logical_pkg"; then
                run_root emerge "$distro_pkg" || return 1
            fi
            ;;
        eopkg)
            run_root eopkg install -y "$distro_pkg" || return 1
            ;;
        swupd)
            run_root swupd bundle-add "$distro_pkg" || return 1
            ;;
        nix-env)
            nix-env -iA "$distro_pkg" || return 1
            ;;
        slackpkg)
            run_root slackpkg -batch=on -default_answer=y install "$distro_pkg" || return 1
            ;;
        *)
            return 1
            ;;
    esac
    BIN_CACHE=()
    package_binaries_ready "$logical_pkg"
}

do_dependencies() {
    local pm distro_id pkg distro_pkg failed=0 missing_count=0
    local -a required_pkgs=(efibootmgr mtools python3 sudo util-linux)
    local -a missing_pkgs=()

    say "${BOLD}${BLUE}Multi Boot Required Dependencies${RESET}"
    distro_id="$(detect_distro_id)"
    pm="$(detect_package_manager 2>/dev/null || true)"
    say "Distribution   : ${CYAN}${distro_id}${RESET}"
    say "Package manager: ${CYAN}${pm:-not detected}${RESET}"
    printf '\n'

    for pkg in "${required_pkgs[@]}"; do
        distro_pkg="$(map_distro_package_name "$pkg" "${pm:-unknown}")"
        if package_binaries_ready "$pkg"; then
            say "  ${GREEN}[OK]${RESET}      ${pkg} (${distro_pkg})"
        else
            say "  ${RED}[MISSING]${RESET} ${pkg} (${distro_pkg})"
            missing_pkgs+=("$pkg")
            missing_count=$(( missing_count + 1 ))
        fi
    done

    printf '\n'
    if (( missing_count == 0 )); then
        say "${GREEN}[+] All required dependencies are already installed and verified.${RESET}"
        return 0
    fi

    if [[ -z "$pm" ]]; then
        say "${RED}[!] No supported package manager was found on this system.${RESET}"
        say "${YELLOW}Please install these packages manually: ${missing_pkgs[*]}${RESET}"
        return 1
    fi

    if ! confirm_once "Install ${missing_count} missing required package(s) (${missing_pkgs[*]}) using ${pm}? (y/n)"; then
        say "${YELLOW}Dependency installation cancelled.${RESET}"
        return 0
    fi

    if [[ "$pm" != "nix-env" ]]; then
        authenticate_root || return 1
    fi

    for pkg in "${missing_pkgs[@]}"; do
        if ! install_single_package "$pkg" "$pm"; then
            say "${RED}[!] Failed to install or verify ${pkg}.${RESET}"
            failed=1
        else
            say "${GREEN}[+] Verified ${pkg}.${RESET}"
        fi
    done

    cleanup_active_state
    if (( failed != 0 )); then
        say "${RED}[!] One or more dependencies failed to install. Check your network or package repository configuration.${RESET}"
        return 1
    fi
    say "${GREEN}[+] All required dependencies are now installed and ready.${RESET}"
    return 0
}

verify_dependencies_present() {
    local missing_list=""
    if [[ ! -d /sys/firmware/efi ]]; then
        say "${RED}[!] Multi Boot requires UEFI mode. Installation stopped.${RESET}"
        return 1
    fi
    EFI_BIN="$(resolve_binary efibootmgr 2>/dev/null || true)"
    [[ -z "$EFI_BIN" ]] && missing_list+="efibootmgr, "
    MCOPY_BIN="$(resolve_binary mcopy 2>/dev/null || true)"
    MDIR_BIN="$(resolve_binary mdir 2>/dev/null || true)"
    [[ -z "$MCOPY_BIN" || -z "$MDIR_BIN" ]] && missing_list+="mtools (mcopy/mdir), "
    PYTHON_BIN="$(resolve_binary python3 2>/dev/null || true)"
    [[ -z "$PYTHON_BIN" ]] && missing_list+="python3, "
    VISUDO_BIN="$(resolve_binary visudo 2>/dev/null || true)"
    [[ -z "$VISUDO_BIN" ]] && missing_list+="sudo (visudo), "
    if ! resolve_binary lsblk >/dev/null 2>&1 || ! resolve_binary blkid >/dev/null 2>&1 || ! resolve_binary findmnt >/dev/null 2>&1; then
        missing_list+="util-linux (lsblk/blkid/findmnt), "
    fi

    if [[ -n "$missing_list" ]]; then
        say "${RED}[!] Missing required dependencies: ${missing_list%, }.${RESET}"
        say "${YELLOW}Automatic package installation during Install is disabled.${RESET}"
        say "${CYAN}Please select 'Install Required Dependencies' from the main menu (or run './install.sh --deps') first.${RESET}"
        return 1
    fi

    SYSTEMCTL_BIN="$(resolve_binary systemctl 2>/dev/null || true)"
    [[ -d /run/systemd/system ]] || SYSTEMCTL_BIN=""
    BOOTCTL_BIN="$(resolve_binary bootctl 2>/dev/null || true)"
    GRUB_REBOOT_BIN="$(resolve_binary grub-reboot 2>/dev/null || resolve_binary grub2-reboot 2>/dev/null || true)"
    REBOOT_BIN="$(resolve_binary reboot 2>/dev/null || true)"
    return 0
}

validate_source() {
    if [[ ! -f "$SRC_SCRIPT" || ! -s "$SRC_SCRIPT" ]]; then
        say "${RED}[!] The boot script was not found beside install.sh (${SRC_SCRIPT}).${RESET}"
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
        if [[ "$loader_info" == *systemd-boot* || "$loader_info" == *grub* || "$loader_info" == *refind* || "$loader_info" == *clover* || "$loader_info" == *opencore* || "$loader_info" == *limine* ]]; then
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
                    if [[ "$raw_tail" =~ ^(.+)[[:space:]]+([A-Za-z0-9_.-]+=.*|(rw|ro|quiet|splash|debug|single|rescue|emergency|nomodeset|nowatchdog|--)([[:space:]].*)?)$ ]]; then
                        trimmed_loader="${BASH_REMATCH[1]}"
                        if [[ "$trimmed_loader" != *"="* ]]; then
                            loader="$trimmed_loader"
                            opts="${BASH_REMATCH[2]}"
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
        shim*.efi|grub*.efi|refind*.efi|systemd-boot*.efi|limine*.efi|bootx64.efi|bootaa64.efi|bootia32.efi|bootmgfw.efi|bootmgr.efi|boot.efi|opencore*.efi|clover*.efi|fwupd*.efi|mmx64.efi|mmaa64.efi|mokmanager*.efi|shell*.efi|memtest*.efi)
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
    local b0 b1 extra
    read -r b0 b1 extra < <(od -An -tu1 -j"$offset" -N2 "$file" 2>/dev/null || true)
    [[ -n "${b0:-}" && -n "${b1:-}" && -z "${extra:-}" ]] || return 1
    printf '%d' $(( b0 | (b1 << 8) ))
}

read_u32_le() {
    local file="$1"
    local offset="$2"
    local b0 b1 b2 b3 extra
    read -r b0 b1 b2 b3 extra < <(od -An -tu1 -j"$offset" -N4 "$file" 2>/dev/null || true)
    [[ -n "${b0:-}" && -n "${b1:-}" && -n "${b2:-}" && -n "${b3:-}" && -z "${extra:-}" ]] || return 1
    printf '%d' $(( b0 | (b1 << 8) | (b2 << 16) | (b3 << 24) ))
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
    local rel_re='^[A-Za-z0-9._/+@ -]+$'
    local -a parts=() mount_candidates=()
    device="$(resolve_partuuid_device "$EFISTUB_PARTUUID" || true)"
    real_device="$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")"
    relative="${EFISTUB_LOADER//\\//}"
    while [[ "$relative" == *"//"* ]]; do
        relative="${relative//\/\//\/}"
    done
    relative="${relative#/}"
    [[ -b "$real_device" && -n "$relative" ]] || return 1
    [[ "$relative" =~ $rel_re ]] || return 1
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
                EFISTUB_REASON="The current EFI-stub image '${EFISTUB_LOADER}' could not be read without root privileges."
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
    elif printf '%s\n' "$sections" | grep -Eq '^\.(osrel|initrd|cmdline):[0-9]+:[0-9]+$'; then
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
        if printf '%s' "$strings_dump" | grep -aEq 'GNU GRUB|grub_efi_|rEFInd|systemd-boot|shim_lock|bootmgfw\.pdb|OpenCore|Clover|Limine'; then
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

create_efi_reader_helper() {
    local temporary bash_bin lsblk_bin blkid_bin findmnt_bin efibootmgr_bin bootctl_bin grub_reboot_bin mount_bin umount_bin
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
    grub_reboot_bin="$(resolve_binary grub-reboot 2>/dev/null || resolve_binary grub2-reboot 2>/dev/null || true)"
    mount_bin="$(resolve_binary mount 2>/dev/null || true)"
    umount_bin="$(resolve_binary umount 2>/dev/null || true)"
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
export MTOOLS_SKIP_CHECK=1
MCOPY_BIN=$(printf '%q' "$MCOPY_BIN")
MDIR_BIN=$(printf '%q' "$MDIR_BIN")
LSBLK_BIN=$(printf '%q' "$lsblk_bin")
BLKID_BIN=$(printf '%q' "$blkid_bin")
FINDMNT_BIN=$(printf '%q' "$findmnt_bin")
EFIBOOTMGR_BIN=$(printf '%q' "$efibootmgr_bin")
BOOTCTL_BIN=$(printf '%q' "$bootctl_bin")
GRUB_REBOOT_BIN=$(printf '%q' "$grub_reboot_bin")
MOUNT_BIN=$(printf '%q' "$mount_bin")
UMOUNT_BIN=$(printf '%q' "$umount_bin")
TARGET_UID=$(printf '%q' "$TARGET_UID")

resolve_gpt_device() {
    local partuuid="\$1"
    local expected_type="\$2"
    local device real_device match_count parttype fstype
    [[ "\$partuuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$ ]] || return 1
    device="/dev/disk/by-partuuid/\$partuuid"
    [[ -b "\$device" ]] || return 1
    real_device="\$(readlink -f "\$device" 2>/dev/null || true)"
    [[ -n "\$real_device" && -b "\$real_device" ]] || return 1
    case "\$real_device" in
        /dev/loop*|/dev/ram*|/dev/zram*|/dev/nbd*) return 1 ;;
    esac
    if [[ -n "\$BLKID_BIN" && -x "\$BLKID_BIN" ]]; then
        match_count="\$("\$BLKID_BIN" -t "PARTUUID=\$partuuid" -o device 2>/dev/null | sed '/^\$/d' | wc -l | tr -d '[:space:]')"
        if [[ "\$match_count" =~ ^[0-9]+\$ ]] && (( match_count > 1 )); then
            return 1
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
    if [[ "\$expected_type" == "esp" ]]; then
        [[ "\$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || return 1
        case "\$fstype" in
            vfat|fat|fat32|msdos) ;;
            *) return 1 ;;
        esac
    else
        return 1
    fi
    printf '%s' "\$real_device"
}

validate_esp_block_device() {
    local dev="\$1"
    local real_dev parttype fstype
    [[ -b "\$dev" ]] || return 1
    real_dev="\$(readlink -f "\$dev" 2>/dev/null || true)"
    [[ -n "\$real_dev" && -b "\$real_dev" ]] || return 1
    parttype=""
    fstype=""
    if [[ -n "\$LSBLK_BIN" && -x "\$LSBLK_BIN" ]]; then
        parttype="\$("\$LSBLK_BIN" -dnro PARTTYPE "\$real_dev" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
        fstype="\$("\$LSBLK_BIN" -dnro FSTYPE "\$real_dev" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
    fi
    if [[ -z "\$parttype" && -n "\$BLKID_BIN" && -x "\$BLKID_BIN" ]]; then
        parttype="\$("\$BLKID_BIN" -o value -s PART_ENTRY_TYPE "\$real_dev" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
    fi
    if [[ -z "\$fstype" && -n "\$BLKID_BIN" && -x "\$BLKID_BIN" ]]; then
        fstype="\$("\$BLKID_BIN" -o value -s TYPE "\$real_dev" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
    fi
    [[ "\$parttype" == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]] || return 1
    case "\$fstype" in
        vfat|fat|fat32|msdos) ;;
        *) return 1 ;;
    esac
    printf '%s' "\$real_dev"
}

is_authorized_esp() {
    local partuuid="\$1"
    local real_device="\$2"
    local target_mnt
    if [[ -n "\$EFIBOOTMGR_BIN" && -x "\$EFIBOOTMGR_BIN" ]]; then
        if "\$EFIBOOTMGR_BIN" -v 2>/dev/null | grep -Eiq "^Boot[0-9A-Fa-f]{4}\\*?[[:space:]].*HD\\([0-9]+,GPT,\${partuuid},"; then
            return 0
        fi
    fi
    if [[ -n "\$FINDMNT_BIN" && -x "\$FINDMNT_BIN" ]]; then
        while IFS= read -r target_mnt; do
            case "\$target_mnt" in
                /efi|/boot/efi|/boot)
                    return 0
                    ;;
            esac
        done < <("\$FINDMNT_BIN" -rn -S "\$real_device" -o TARGET 2>/dev/null || true)
    fi
    return 1
}

if (( \$# < 1 )); then
    exit 2
fi
operation="\$1"

if [[ "\$operation" == "set-oneshot" ]]; then
    (( \$# == 2 )) || exit 2
    entry_id="\$2"
    [[ "\$entry_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\$ ]] || exit 2
    [[ -n "\$BOOTCTL_BIN" && -x "\$BOOTCTL_BIN" ]] || exit 1
    exec "\$BOOTCTL_BIN" set-oneshot "\$entry_id"
fi

if [[ "\$operation" == "clear-oneshot" ]]; then
    (( \$# == 1 )) || exit 2
    [[ -n "\$BOOTCTL_BIN" && -x "\$BOOTCTL_BIN" ]] || exit 1
    exec "\$BOOTCTL_BIN" set-oneshot ""
fi

if [[ "\$operation" == "set-grub-oneshot" ]]; then
    (( \$# == 2 )) || exit 2
    grub_entry="\$2"
    [[ -n "\$GRUB_REBOOT_BIN" && -x "\$GRUB_REBOOT_BIN" ]] || exit 1
    if [[ -z "\$grub_entry" ]]; then
        exec "\$GRUB_REBOOT_BIN" ""
    fi
    grub_re='^[A-Za-z0-9._:>+/ ()-]{1,256}\$'
    [[ "\$grub_entry" != -* && "\$grub_entry" =~ \$grub_re ]] || exit 2
    exec "\$GRUB_REBOOT_BIN" -- "\$grub_entry"
fi

if [[ "\$operation" == "create-uefi-entry" ]]; then
    (( \$# == 5 )) || exit 2
    disk_dev="\$2"
    part_num="\$3"
    entry_label="\$4"
    efi_loader="\$5"
    part_re='^[1-9][0-9]{0,2}\$'
    label_re='^[A-Za-z0-9._()+/ -]{1,96}\$'
    loader_re='^\\[A-Za-z0-9._\\+/-]+\.[Ee][Ff][Ii]\$'
    [[ -b "\$disk_dev" && "\$disk_dev" == /dev/* ]] || exit 2
    [[ "\$part_num" =~ \$part_re ]] || exit 2
    [[ "\$entry_label" =~ \$label_re ]] || exit 2
    [[ "\$efi_loader" =~ \$loader_re ]] || exit 2
    [[ -n "\$EFIBOOTMGR_BIN" && -x "\$EFIBOOTMGR_BIN" ]] || exit 1
    exec "\$EFIBOOTMGR_BIN" -c -d "\$disk_dev" -p "\$part_num" -L "\$entry_label" -l "\$efi_loader"
fi

if [[ "\$operation" == "remove-uefi-entry" ]]; then
    (( \$# == 2 )) || exit 2
    boot_id="\${2^^}"
    [[ "\$boot_id" =~ ^[0-9A-F]{4}\$ ]] || exit 2
    [[ -n "\$EFIBOOTMGR_BIN" && -x "\$EFIBOOTMGR_BIN" ]] || exit 1
    exec "\$EFIBOOTMGR_BIN" -b "\$boot_id" -B
fi

if [[ "\$operation" == "write-efivar" ]]; then
    (( \$# == 3 )) || exit 2
    var_path="\$2"
    src_file="\$3"
    case "\$var_path" in
        /sys/firmware/efi/efivars/PreviousBoot-36d08fa7-cf0b-42f5-8f14-68df73ed3740|/sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f) ;;
        *) exit 2 ;;
    esac
    [[ -f "\$src_file" && ! -L "\$src_file" && -s "\$src_file" ]] || exit 2
    file_sz="\$(wc -c < "\$src_file" | tr -d '[:space:]')"
    [[ "\$file_sz" =~ ^[0-9]+\$ ]] && (( file_sz >= 6 && file_sz <= 516 )) || exit 2
    src_uid="\$(stat -c '%u' "\$src_file" 2>/dev/null || printf '99999')"
    [[ "\$src_uid" == "0" || "\$src_uid" == "\$TARGET_UID" ]] || exit 2
    chattr -i "\$var_path" 2>/dev/null || true
    exec cp -f -- "\$src_file" "\$var_path"
fi

if [[ "\$operation" == "mount-esp" ]]; then
    (( \$# == 3 )) || exit 2
    esp_dev="\$(validate_esp_block_device "\$2")" || exit 2
    mnt_dir="\$3"
    [[ -d "\$mnt_dir" && ! -L "\$mnt_dir" && "\$mnt_dir" == /tmp/* ]] || exit 2
    mnt_uid="\$(stat -c '%u' "\$mnt_dir" 2>/dev/null || printf '99999')"
    [[ "\$mnt_uid" == "0" || "\$mnt_uid" == "\$TARGET_UID" ]] || exit 2
    [[ -n "\$MOUNT_BIN" && -x "\$MOUNT_BIN" ]] || exit 1
    exec "\$MOUNT_BIN" -t vfat -o rw,umask=0077 "\$esp_dev" "\$mnt_dir"
fi

if [[ "\$operation" == "umount-esp" ]]; then
    (( \$# == 2 )) || exit 2
    mnt_dir="\$2"
    [[ -d "\$mnt_dir" && ! -L "\$mnt_dir" && "\$mnt_dir" == /tmp/* ]] || exit 2
    [[ -n "\$UMOUNT_BIN" && -x "\$UMOUNT_BIN" ]] || exit 1
    exec "\$UMOUNT_BIN" -- "\$mnt_dir"
fi

if [[ "\$operation" == "esp-mkdir" ]]; then
    (( \$# == 2 )) || exit 2
    target_dir="\$2"
    case "\$target_dir" in
        /efi/EFI/multiboot-win-*|/boot/efi/EFI/multiboot-win-*|/boot/EFI/multiboot-win-*|/tmp/*/EFI/multiboot-win-*) ;;
        *) exit 2 ;;
    esac
    case "/\$target_dir/" in
        */../*) exit 2 ;;
    esac
    exec mkdir -p -- "\$target_dir"
fi

if [[ "\$operation" == "esp-copy" ]]; then
    (( \$# == 3 )) || exit 2
    src_file="\$2"
    dst_file="\$3"
    [[ -f "\$src_file" && ! -L "\$src_file" ]] || exit 2
    case "\$dst_file" in
        /efi/EFI/multiboot-win-*|/boot/efi/EFI/multiboot-win-*|/boot/EFI/multiboot-win-*|/tmp/*/EFI/multiboot-win-*) ;;
        *) exit 2 ;;
    esac
    case "/\$dst_file/" in
        */../*) exit 2 ;;
    esac
    exec cp -f -- "\$src_file" "\$dst_file"
fi

if [[ "\$operation" == "clean-win-isolated" ]]; then
    (( \$# == 1 )) || exit 2
    for base_esp in /efi /boot/efi /boot; do
        if [[ -d "\$base_esp/EFI" ]]; then
            for iso_dir in "\$base_esp/EFI"/multiboot-win-*; do
                if [[ -d "\$iso_dir" && ! -L "\$iso_dir" ]]; then
                    rm -rf -- "\$iso_dir" 2>/dev/null || true
                fi
            done
        fi
    done
    if [[ -n "\$EFIBOOTMGR_BIN" && -x "\$EFIBOOTMGR_BIN" ]]; then
        while IFS= read -r boot_hex; do
            [[ "\$boot_hex" =~ ^[0-9A-Fa-f]{4}\$ ]] || continue
            "\$EFIBOOTMGR_BIN" -b "\$boot_hex" -B >/dev/null 2>&1 || true
        done < <("\$EFIBOOTMGR_BIN" -v 2>/dev/null | awk 'tolower(\$0) ~ /\\\\efi\\\\multiboot-win-[0-9a-f]+\\\\bootmgfw\.efi/ { if (match(\$0, /^Boot([0-9A-Fa-f]{4})/, m)) print m[1] }')
    fi
    exit 0
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
rel_re='^[A-Za-z0-9._/+@ -]+\$'
[[ -n "\$relative" && "\$relative" =~ \$rel_re ]] || exit 2
case "/\$relative/" in
    */../*|*/./*) exit 2 ;;
esac
lower_rel="\${relative,,}"
case "\$lower_rel" in
    *.efi|*.uki|*.img|*.cpio|*.gz|*.zst|*.lz4|*.xz|*.conf|*.nsh|bcd|*/bcd|*.bcd|vmlinuz*|*/vmlinuz*|vmlinux*|*/vmlinux*|bzimage*|*/bzimage*|linux|*/linux|linux-*|*/linux-*|kernel|*/kernel|kernel-*|*/kernel-*|image|*/image|image-*|*/image-*) ;;
    *) exit 2 ;;
esac
real_device="\$(resolve_gpt_device "\$partuuid" "esp")" || exit 1
is_authorized_esp "\$partuuid" "\$real_device" || exit 1
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
        printf '%s\\n' "\$listing" | sed -E 's#^.*/##' | grep -Fxi -- "\$basename" >/dev/null
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
    commands+="${HELPER_PATH} exists *, ${HELPER_PATH} read *, ${HELPER_PATH} set-oneshot [A-Za-z0-9]*, ${HELPER_PATH} clear-oneshot, ${HELPER_PATH} set-grub-oneshot *, ${HELPER_PATH} create-uefi-entry *, ${HELPER_PATH} remove-uefi-entry ${boot_id_pattern}, ${HELPER_PATH} write-efivar *, ${HELPER_PATH} mount-esp *, ${HELPER_PATH} umount-esp *, ${HELPER_PATH} esp-mkdir *, ${HELPER_PATH} esp-copy *, ${HELPER_PATH} clean-win-isolated"
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
    local has_l_flag=0
    while (( $# > 0 )); do
        case "$1" in
            -n|--non-interactive)
                sudo_opts+=("$1")
                shift
                ;;
            -l)
                has_l_flag=1
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
    if (( ${#cmd_args[@]} == 0 )); then
        command sudo "${sudo_opts[@]}"
        return $?
    fi
    local cmd_base="${cmd_args[0]##*/}"
    if (( ${#cmd_args[@]} == 3 )) && [[ "$cmd_base" == "bootctl" && "${cmd_args[1]}" == "set-oneshot" ]]; then
        if [[ -z "${cmd_args[2]}" ]]; then
            command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read clear-oneshot
            return $?
        fi
        if [[ "${cmd_args[2]}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
            command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read set-oneshot "${cmd_args[2]}"
            return $?
        fi
        return 2
    fi
    if (( ${#cmd_args[@]} == 2 )) && [[ "$cmd_base" == "grub-reboot" || "$cmd_base" == "grub2-reboot" ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read set-grub-oneshot "${cmd_args[1]}"
        return $?
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 10 )) && [[ "$cmd_base" == "efibootmgr" && "${cmd_args[1]}" == "-c" && "${cmd_args[2]}" == "-d" && "${cmd_args[4]}" == "-p" && "${cmd_args[6]}" == "-L" && "${cmd_args[8]}" == "-l" ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read create-uefi-entry "${cmd_args[3]}" "${cmd_args[5]}" "${cmd_args[7]}" "${cmd_args[9]}"
        return $?
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 3 )) && [[ "$cmd_base" == "chattr" && "${cmd_args[1]}" == "-i" && "${cmd_args[2]}" == /sys/firmware/efi/efivars/* ]]; then
        return 0
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 4 )) && [[ "$cmd_base" == "cp" && "${cmd_args[1]}" == "-f" && "${cmd_args[3]}" == /sys/firmware/efi/efivars/* ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read write-efivar "${cmd_args[3]}" "${cmd_args[2]}"
        return $?
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 5 )) && [[ "$cmd_base" == "mount" && "${cmd_args[1]}" == "-t" && "${cmd_args[2]}" == "vfat" ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read mount-esp "${cmd_args[3]}" "${cmd_args[4]}"
        return $?
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 2 )) && [[ "$cmd_base" == "umount" ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read umount-esp "${cmd_args[1]}"
        return $?
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 3 )) && [[ "$cmd_base" == "mkdir" && "${cmd_args[1]}" == "-p" && "${cmd_args[2]}" == *"/EFI/multiboot-win-"* ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read esp-mkdir "${cmd_args[2]}"
        return $?
    fi
    if (( has_l_flag == 0 && ${#cmd_args[@]} == 4 )) && [[ "$cmd_base" == "cp" && "${cmd_args[1]}" == "-f" && "${cmd_args[3]}" == *"/EFI/multiboot-win-"* ]]; then
        command sudo "${sudo_opts[@]}" /usr/local/libexec/multiboot-efi-read esp-copy "${cmd_args[2]}" "${cmd_args[3]}"
        return $?
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

record_system_manifest() {
    local entry="$1"
    local temporary
    run_root install -d -m 755 -o root -g root "$SYS_STATE_DIR" || return 1
    if run_root test -f "$SYS_MANIFEST" 2>/dev/null; then
        if run_root grep -Fqx -- "$entry" "$SYS_MANIFEST" 2>/dev/null; then
            return 0
        fi
    fi
    temporary="$(mktemp)" || return 1
    if run_root test -f "$SYS_MANIFEST" 2>/dev/null; then
        run_root cat "$SYS_MANIFEST" > "$temporary" 2>/dev/null || true
    fi
    printf '%s\n' "$entry" >> "$temporary"
    run_root install -m 644 -o root -g root "$temporary" "$SYS_MANIFEST" || {
        rm -f "$temporary"
        return 1
    }
    rm -f "$temporary"
}

write_system_file() {
    local content="$1"
    local dest="$2"
    local mode="${3:-644}"
    local dest_dir temporary
    dest_dir="$(dirname "$dest")"
    temporary="$(mktemp)" || return 1
    printf '%s\n' "$content" > "$temporary"
    if ! run_root install -d -m 755 -o root -g root "$dest_dir"; then
        rm -f "$temporary"
        return 1
    fi
    if ! run_root install -m "$mode" -o root -g root "$temporary" "$dest"; then
        rm -f "$temporary"
        return 1
    fi
    rm -f "$temporary"
    record_system_manifest "$dest"
}

install_system_wide_shell_hooks() {
    local sys_profile_sh sys_profile_csh sys_bash_comp sys_zsh_comp sys_fish_func sys_fish_comp

    sys_profile_sh='case ":$PATH:" in
    *:/usr/local/bin:*) ;;
    *) export PATH="/usr/local/bin:$PATH" ;;
esac'

    sys_profile_csh='if ( "$path" !~ */usr/local/bin* ) then
    set path = ( /usr/local/bin $path )
endif
if ( $?tcsh ) then
    complete boot '\''p/*/`/usr/local/bin/boot --complete`/'\''
endif'

    sys_bash_comp='_boot_complete() {
    local current="${COMP_WORDS[COMP_CWORD]}" word unescaped prefix="" quote_mode="none"
    local index i ch
    local -a options typed
    options=(-h --help -l --list -t --test --check -f --force -s --split-windows)
    typed=()
    COMPREPLY=()
    for ((index=1; index<COMP_CWORD; index++)); do
        word="${COMP_WORDS[index]}"
        case "$word" in
            -h|--help|-l|--list|-s|--split-windows)
                return 0
                ;;
            -f|--force|-t|--test|--check)
                ;;
            *)
                typed+=("$word")
                ;;
        esac
    done
    if (( COMP_CWORD == 1 )) && [[ -z "$current" || "$current" == -* ]]; then
        for word in "${options[@]}"; do
            [[ "$word" == "$current"* ]] && COMPREPLY+=("$word")
        done
        [[ "$current" == -* ]] && return 0
    fi
    if (( ${#typed[@]} > 0 )); then
        prefix="${typed[*]} "
    fi
    prefix+="$current"
    if [[ "$prefix" == \"* ]]; then
        quote_mode="double"
        prefix="${prefix:1}"
    elif [[ "$prefix" == '\''* ]]; then
        quote_mode="single"
        prefix="${prefix:1}"
    fi
    unescaped=""
    if [[ "$quote_mode" == "none" ]]; then
        for ((i=0; i<${#prefix}; i++)); do
            ch="${prefix:i:1}"
            if [[ "$ch" == "\\" && $((i + 1)) -lt ${#prefix} ]]; then
                i=$((i + 1))
                unescaped+="${prefix:i:1}"
            else
                unescaped+="$ch"
            fi
        done
    else
        unescaped="$prefix"
    fi
    local prior_unescaped=""
    if (( ${#typed[@]} > 0 )); then
        local prior_raw="${typed[*]} "
        for ((i=0; i<${#prior_raw}; i++)); do
            ch="${prior_raw:i:1}"
            if [[ "$ch" == "\\" && $((i + 1)) -lt ${#prior_raw} ]]; then
                i=$((i + 1))
                prior_unescaped+="${prior_raw:i:1}"
            else
                prior_unescaped+="$ch"
            fi
        done
    fi
    local candidate escaped_candidate
    while IFS= read -r candidate; do
        [[ "$candidate" == "$unescaped"* ]] || continue
        if [[ -n "$prior_unescaped" ]]; then
            candidate="${candidate#"$prior_unescaped"}"
        fi
        if [[ "$quote_mode" == "none" ]]; then
            printf -v escaped_candidate '\''%q'\'' "$candidate"
            COMPREPLY+=("$escaped_candidate")
        else
            COMPREPLY+=("$candidate")
        fi
    done < <(command /usr/local/bin/boot --complete 2>/dev/null)
}
complete -F _boot_complete boot'

    sys_zsh_comp='#compdef boot
_boot() {
    local -a targets options
    targets=(${(@f)$(command /usr/local/bin/boot --complete 2>/dev/null)})
    options=('\''-h:Show help'\'' '\''-l:List boot targets'\'' '\''-t:Test without rebooting'\'' '\''-f:Force reboot'\'' '\''-s:Split merged Windows BCD entries'\'')
    _describe '\''boot options'\'' options
    _describe '\''boot targets'\'' targets
}
_boot "$@"'

    sys_fish_func='function boot --wraps=/usr/local/bin/boot --description "Multi Boot UEFI switcher"
    command /usr/local/bin/boot $argv
end'

    sys_fish_comp='complete -c boot -f
complete -c boot -s h -l help -d "Show detected operating systems and commands"
complete -c boot -s l -l list -d "List detected boot targets"
complete -c boot -s t -l test -d "Test a boot target without rebooting"
complete -c boot -s f -l force -d "Force close desktop applications and reboot"
complete -c boot -s s -l split-windows -d "Split merged Windows BCD entries"
complete -c boot -a "(/usr/local/bin/boot --complete 2>/dev/null | string escape --no-quoted)"'

    if [[ -d /etc/profile.d ]]; then
        write_system_file "$sys_profile_sh" "$SYS_PROFILE_SH" 644 || {
            say "${RED}[!] Failed to install ${SYS_PROFILE_SH}.${RESET}"
            return 1
        }
        write_system_file "$sys_profile_csh" "$SYS_PROFILE_CSH" 644 || {
            say "${RED}[!] Failed to install ${SYS_PROFILE_CSH}.${RESET}"
            return 1
        }
    fi
    write_system_file "$sys_bash_comp" "$SYS_BASH_COMP" 644 || {
        say "${RED}[!] Failed to install ${SYS_BASH_COMP}.${RESET}"
        return 1
    }
    write_system_file "$sys_zsh_comp" "$SYS_ZSH_COMP" 644 || {
        say "${RED}[!] Failed to install ${SYS_ZSH_COMP}.${RESET}"
        return 1
    }
    write_system_file "$sys_fish_func" "$SYS_FISH_FUNC" 644 || {
        say "${RED}[!] Failed to install ${SYS_FISH_FUNC}.${RESET}"
        return 1
    }
    write_system_file "$sys_fish_comp" "$SYS_FISH_COMP" 644 || {
        say "${RED}[!] Failed to install ${SYS_FISH_COMP}.${RESET}"
        return 1
    }
}

validate_safe_user_path() {
    local target="$1"
    local expect_kind="${2:-any}"
    local rel current owner resolved_target resolved_owner
    local -a components=()
    if [[ -z "$TARGET_HOME" || "$TARGET_HOME" != /* || ! -d "$TARGET_HOME" || -L "$TARGET_HOME" ]]; then
        say "${RED}[!] Target home directory is invalid or missing: ${TARGET_HOME:-empty}.${RESET}"
        return 1
    fi
    if [[ "$TARGET_USER" != "root" ]]; then
        owner="$(stat -c '%u' "$TARGET_HOME" 2>/dev/null || printf '0')"
        if [[ "$owner" != "$TARGET_UID" ]]; then
            say "${RED}[!] Home directory ${TARGET_HOME} is owned by UID ${owner}, expected UID ${TARGET_UID}.${RESET}"
            return 1
        fi
    fi
    if [[ "$target" == "$TARGET_HOME" ]]; then
        if [[ "$expect_kind" == "file" ]]; then
            say "${RED}[!] Expected regular file at ${target}.${RESET}"
            return 1
        fi
        return 0
    fi
    if [[ "$target" != "$HOME_PREFIX/"* ]]; then
        say "${RED}[!] Refusing path outside target home directory: ${target}.${RESET}"
        return 1
    fi
    rel="${target#"$HOME_PREFIX"/}"
    if [[ -z "$rel" ]]; then
        say "${RED}[!] Empty relative path under ${TARGET_HOME}.${RESET}"
        return 1
    fi
    IFS='/' read -ra components <<< "$rel"
    current="$HOME_PREFIX"
    local last_idx=$(( ${#components[@]} - 1 ))
    local idx part
    for ((idx = 0; idx <= last_idx; idx++)); do
        part="${components[idx]}"
        if [[ -z "$part" || "$part" == "." || "$part" == ".." ]]; then
            say "${RED}[!] Invalid path component in ${target}.${RESET}"
            return 1
        fi
        current="$current/$part"
        if [[ -L "$current" ]]; then
            if (( idx == last_idx )) && [[ "$expect_kind" == "file" && -f "$current" ]]; then
                resolved_target="$(readlink -f "$current" 2>/dev/null || true)"
                if [[ -n "$resolved_target" && -f "$resolved_target" ]]; then
                    if [[ "$TARGET_USER" == "root" ]]; then
                        return 0
                    fi
                    resolved_owner="$(stat -c '%u' "$resolved_target" 2>/dev/null || printf '0')"
                    if [[ "$resolved_owner" == "$TARGET_UID" ]]; then
                        return 0
                    fi
                fi
            fi
            say "${RED}[!] Refusing to follow symbolic link at ${current}.${RESET}"
            return 1
        fi
        if [[ -e "$current" ]]; then
            if (( idx < last_idx )); then
                if [[ ! -d "$current" ]]; then
                    say "${RED}[!] Expected directory at ${current}, but found a non-directory.${RESET}"
                    return 1
                fi
            else
                case "$expect_kind" in
                    dir)
                        if [[ ! -d "$current" ]]; then
                            say "${RED}[!] Expected directory at ${current}.${RESET}"
                            return 1
                        fi
                        ;;
                    file)
                        if [[ ! -f "$current" ]]; then
                            say "${RED}[!] Expected regular file at ${current}.${RESET}"
                            return 1
                        fi
                        ;;
                    any)
                        if [[ ! -d "$current" && ! -f "$current" ]]; then
                            say "${RED}[!] Unsupported file type at ${current}.${RESET}"
                            return 1
                        fi
                        ;;
                esac
            fi
            if [[ "$TARGET_USER" != "root" ]]; then
                owner="$(stat -c '%u' "$current" 2>/dev/null || printf '0')"
                if [[ "$owner" != "$TARGET_UID" ]]; then
                    if [[ "$owner" == "0" ]] && (( EUID == 0 || SUDO_AUTHENTICATED == 1 )); then
                        run_root chown -h "$TARGET_UID:$TARGET_GID" "$current" 2>/dev/null || true
                        owner="$(stat -c '%u' "$current" 2>/dev/null || printf '0')"
                    fi
                    if [[ "$owner" != "$TARGET_UID" ]]; then
                        say "${RED}[!] Ownership mismatch at ${current} (owned by UID ${owner}, expected UID ${TARGET_UID}).${RESET}"
                        return 1
                    fi
                fi
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
    [[ "$dir" == "$TARGET_HOME" ]] && return 0
    rel="${dir#"$HOME_PREFIX"/}"
    IFS='/' read -ra components <<< "$rel"
    current="$HOME_PREFIX"
    for part in "${components[@]}"; do
        current="$current/$part"
        if [[ -L "$current" ]]; then
            say "${RED}[!] Refusing to follow symbolic link at ${current}.${RESET}"
            return 1
        fi
        if [[ ! -e "$current" ]]; then
            if ! run_as_target_user mkdir "$current"; then
                say "${RED}[!] Failed to create directory ${current} as user ${TARGET_USER}.${RESET}"
                return 1
            fi
            if [[ -L "$current" ]]; then
                say "${RED}[!] Symbolic link detected after creating ${current}.${RESET}"
                return 1
            fi
            if (( EUID == 0 )); then
                chown -h "$TARGET_UID:$TARGET_GID" "$current" 2>/dev/null || true
            fi
        else
            if [[ ! -d "$current" || -L "$current" ]]; then
                say "${RED}[!] Invalid directory entry at ${current}.${RESET}"
                return 1
            fi
            if [[ "$TARGET_USER" != "root" ]]; then
                owner="$(stat -c '%u' "$current" 2>/dev/null || printf '0')"
                if [[ "$owner" != "$TARGET_UID" ]]; then
                    say "${RED}[!] Ownership mismatch at ${current} (owned by UID ${owner}, expected UID ${TARGET_UID}).${RESET}"
                    return 1
                fi
            fi
        fi
    done
    return 0
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
    temporary="$(run_as_target_user mktemp "$STATE_DIR/.multiboot.XXXXXX")" || {
        say "${RED}[!] Failed to create temporary state file in ${STATE_DIR}.${RESET}"
        return 1
    }
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

write_user_file() {
    local source="$1"
    local destination="$2"
    local mode="${3:-644}"
    local marker="${4:-}"
    local dest_dir temporary actual_dest
    validate_safe_user_path "$destination" "file" || return 1
    actual_dest="$destination"
    if [[ -L "$destination" ]]; then
        actual_dest="$(readlink -f "$destination")"
    fi
    dest_dir="$(dirname "$actual_dest")"
    if [[ -n "$marker" && -f "$actual_dest" ]]; then
        if ! grep -Fqx -- "file:$marker" "$STATE_FILE" 2>/dev/null; then
            ensure_safe_user_dir "$STATE_DIR" || return 1
            validate_safe_user_path "$STATE_DIR/backup-$marker" "file" || return 1
            if [[ ! -e "$STATE_DIR/backup-$marker" ]]; then
                run_as_target_user cp -P -- "$actual_dest" "$STATE_DIR/backup-$marker" || return 1
            fi
        fi
    fi
    if [[ "$destination" == "$actual_dest" ]]; then
        ensure_safe_user_dir "$dest_dir" || return 1
        validate_safe_user_path "$destination" "file" || return 1
    fi
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || {
        say "${RED}[!] Failed to create temporary file in ${dest_dir}.${RESET}"
        return 1
    }
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
    if ! run_as_target_user mv -Tf "$temporary" "$actual_dest"; then
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
    local dest_dir temporary file_mode="644" existed_before=0 actual_file
    validate_safe_user_path "$file" "file" || return 1
    actual_file="$file"
    if [[ -L "$file" ]]; then
        actual_file="$(readlink -f "$file")"
    fi
    dest_dir="$(dirname "$actual_file")"
    if [[ "$file" == "$actual_file" ]]; then
        ensure_safe_user_dir "$dest_dir" || return 1
        validate_safe_user_path "$file" "file" || return 1
    fi
    if [[ -f "$actual_file" ]]; then
        existed_before=1
        file_mode="$(stat -c '%a' "$actual_file" 2>/dev/null || printf '644')"
        if grep -Fqx -- "$line" "$actual_file"; then
            return 0
        fi
    fi
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || {
        say "${RED}[!] Failed to create temporary file in ${dest_dir}.${RESET}"
        return 1
    }
    if (( existed_before == 1 )); then
        if ! run_as_target_user cp -- "$actual_file" "$temporary"; then
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
    if ! run_as_target_user mv -Tf "$temporary" "$actual_file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if (( existed_before == 0 )); then
        record_added_directive "created:$file" || return 1
    fi
    [[ -n "$marker" ]] && record_added_directive "$marker"
}

prepend_unique_line() {
    local file="$1"
    local line="$2"
    local marker="${3:-}"
    local temporary dest_dir file_mode="644" existed_before=0 actual_file
    validate_safe_user_path "$file" "file" || return 1
    actual_file="$file"
    if [[ -L "$file" ]]; then
        actual_file="$(readlink -f "$file")"
    fi
    dest_dir="$(dirname "$actual_file")"
    if [[ "$file" == "$actual_file" ]]; then
        ensure_safe_user_dir "$dest_dir" || return 1
        validate_safe_user_path "$file" "file" || return 1
    fi
    if [[ -f "$actual_file" ]]; then
        existed_before=1
        file_mode="$(stat -c '%a' "$actual_file" 2>/dev/null || printf '644')"
        if grep -Fqx -- "$line" "$actual_file"; then
            return 0
        fi
    fi
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || {
        say "${RED}[!] Failed to create temporary file in ${dest_dir}.${RESET}"
        return 1
    }
    if ! printf '%s\n' "$line" | run_as_target_user tee "$temporary" >/dev/null; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if (( existed_before == 1 )); then
        if ! run_as_target_user tee -a "$temporary" < "$actual_file" >/dev/null; then
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
    if ! run_as_target_user mv -Tf "$temporary" "$actual_file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
    if (( existed_before == 0 )); then
        record_added_directive "created:$file" || return 1
    fi
    [[ -n "$marker" ]] && record_added_directive "$marker"
}

remove_exact_line() {
    local file="$1"
    local line="$2"
    local temporary dest_dir file_mode="644" actual_file
    [[ -e "$file" ]] || return 0
    validate_safe_user_path "$file" "file" || return 1
    actual_file="$file"
    if [[ -L "$file" ]]; then
        actual_file="$(readlink -f "$file")"
    fi
    [[ -f "$actual_file" ]] || return 0
    dest_dir="$(dirname "$actual_file")"
    file_mode="$(stat -c '%a' "$actual_file" 2>/dev/null || printf '644')"
    temporary="$(run_as_target_user mktemp "$dest_dir/.multiboot.XXXXXX")" || return 1
    if ! TARGET_LINE="$line" awk '$0 != ENVIRON["TARGET_LINE"]' "$actual_file" | run_as_target_user tee "$temporary" >/dev/null; then
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
    if ! run_as_target_user mv -Tf "$temporary" "$actual_file"; then
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 1
    fi
}

cleanup_created_empty_dotfile() {
    local file="$1"
    [[ -f "$file" && ! -L "$file" ]] || return 0
    validate_safe_user_path "$file" "file" || return 0
    if grep -Fqx -- "created:$file" "$STATE_FILE" 2>/dev/null; then
        if [[ -z "$(tr -d '[:space:]' < "$file" 2>/dev/null || true)" ]]; then
            run_as_target_user rm -f -- "$file" 2>/dev/null || true
        fi
    fi
}

scrub_fish_history() {
    local fish_history="$FISH_DATA_DIR/fish_history"
    local temporary file_mode="644"
    [[ -f "$fish_history" && ! -L "$fish_history" ]] || return 0
    validate_safe_user_path "$fish_history" "file" || return 0
    file_mode="$(stat -c '%a' "$fish_history" 2>/dev/null || printf '644')"
    temporary="$(run_as_target_user mktemp "$FISH_DATA_DIR/.multiboot.XXXXXX")" || return 0
    awk '
        /^- cmd: boot '\''.*'\''$/ { skip=1; next }
        skip==1 && /^  when: [0-9]+$/ { skip=0; next }
        { skip=0; print }
    ' "$fish_history" | run_as_target_user tee "$temporary" >/dev/null || {
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
        return 0
    }
    run_as_target_user chmod "$file_mode" "$temporary" >/dev/null 2>&1 || true
    run_as_target_user mv -Tf "$temporary" "$fish_history" >/dev/null 2>&1 || {
        run_as_target_user rm -f "$temporary" >/dev/null 2>&1 || true
    }
}

configure_shells() {
    local fish_function fish_completion zsh_completion bash_completion nu_completion elvish_module xonsh_module pwsh_block tcsh_block ksh_block oils_block ion_block murex_block
    local profile_file bashrc zshrc nu_config elvish_rc pwsh_profile tcshrc cshrc kshrc mkshrc oshrc yshrc ionrc murex_profile shrc
    local fish_history fish_hist_tmp fish_hist_mode="644" timestamp target configured_list="" zsh_single_quoted_dir escaped_target history_command
    local -a targets=()

    detect_all_shells
    install_system_wide_shell_hooks || return 1
    mapfile -t targets < <("$BIN_PATH" --complete 2>/dev/null || true)

    if has_shell_family fish; then
        fish_function="function boot --wraps=$BIN_PATH --description 'Multi Boot UEFI switcher'
    command $BIN_PATH \$argv
end"
        fish_completion="complete -c boot -f
complete -c boot -s h -l help -d 'Show detected operating systems and commands'
complete -c boot -s l -l list -d 'List detected boot targets'
complete -c boot -s t -l test -d 'Test a boot target without rebooting'
complete -c boot -s f -l force -d 'Force close desktop applications and reboot'
complete -c boot -s s -l split-windows -d 'Split merged Windows BCD entries'
complete -c boot -a '($BIN_PATH --complete 2>/dev/null | string escape --no-quoted)'"
        write_user_file "$fish_function" "$FISH_FUNC_DIR/boot.fish" 644 "fish-func" || {
            say "${RED}[!] Failed while configuring Fish function.${RESET}"
            return 1
        }
        write_user_file "$fish_completion" "$FISH_COMP_DIR/boot.fish" 644 "fish-comp" || {
            say "${RED}[!] Failed while configuring Fish completion.${RESET}"
            return 1
        }
        ensure_safe_user_dir "$FISH_DATA_DIR" || {
            say "${RED}[!] Failed while preparing Fish data directory.${RESET}"
            return 1
        }
        fish_history="$FISH_DATA_DIR/fish_history"
        validate_safe_user_path "$fish_history" "file" || {
            say "${RED}[!] Failed while validating Fish history path.${RESET}"
            return 1
        }
        if [[ -f "$fish_history" ]]; then
            fish_hist_mode="$(stat -c '%a' "$fish_history" 2>/dev/null || printf '644')"
        fi
        fish_hist_tmp="$(run_as_target_user mktemp "$FISH_DATA_DIR/.multiboot.XXXXXX")" || {
            say "${RED}[!] Failed while creating temporary Fish history file.${RESET}"
            return 1
        }
        if [[ -f "$fish_history" ]]; then
            if ! run_as_target_user cp -- "$fish_history" "$fish_hist_tmp"; then
                run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
                say "${RED}[!] Failed while copying Fish history.${RESET}"
                return 1
            fi
        fi
        timestamp="$(date +%s)"
        for target in "${targets[@]:-}"; do
            target="${target//$'\r'/}"
            [[ -n "$target" ]] || continue
            escaped_target="${target//\'/\'\\\'\'}"
            history_command="boot '$escaped_target'"
            if ! grep -Fq -- "- cmd: $history_command" "$fish_hist_tmp"; then
                if ! printf -- "- cmd: %s\n  when: %s\n" "$history_command" "$timestamp" | run_as_target_user tee -a "$fish_hist_tmp" >/dev/null; then
                    run_as_target_user rm -f "$fish_hist_tmp" >/dev/null 2>&1 || true
                    say "${RED}[!] Failed while updating Fish history.${RESET}"
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
            say "${RED}[!] Failed while replacing Fish history.${RESET}"
            return 1
        fi
        configured_list+="Fish, "
    fi

    if has_shell_family zsh; then
        zsh_completion="_boot() {
    local -a targets options
    targets=(\${(@f)\$(command $BIN_PATH --complete 2>/dev/null)})
    options=('-h:Show help' '-l:List boot targets' '-t:Test without rebooting' '-f:Force reboot' '-s:Split merged Windows BCD entries')
    _describe 'boot options' options
    _describe 'boot targets' targets
}
compdef _boot boot"
        write_user_file "$zsh_completion" "$ZSH_COMP_DIR/_boot" 644 "zsh-comp" || {
            say "${RED}[!] Failed while configuring Zsh completion.${RESET}"
            return 1
        }
        zshrc="$HOME_PREFIX/.zshrc"
        zsh_single_quoted_dir="'${ZSH_COMP_DIR//\'/\'\\\'\'}'"
        prepend_unique_line "$zshrc" "fpath=(${zsh_single_quoted_dir} \$fpath)" zsh-fpath || {
            say "${RED}[!] Failed while updating ${zshrc} (fpath).${RESET}"
            return 1
        }
        append_unique_line "$zshrc" 'autoload -Uz compinit && compinit' zsh-compinit || {
            say "${RED}[!] Failed while updating ${zshrc} (compinit).${RESET}"
            return 1
        }
        append_unique_line "$zshrc" 'compdef _boot boot' zsh-compdef || {
            say "${RED}[!] Failed while updating ${zshrc} (compdef).${RESET}"
            return 1
        }
        configured_list+="Zsh, "
    fi

    if has_shell_family bash; then
        bash_completion="_boot_complete() {
    local current=\"\${COMP_WORDS[COMP_CWORD]}\" word unescaped prefix=\"\" quote_mode=\"none\"
    local index i ch
    local -a options typed
    options=(-h --help -l --list -t --test --check -f --force -s --split-windows)
    typed=()
    COMPREPLY=()
    for ((index=1; index<COMP_CWORD; index++)); do
        word=\"\${COMP_WORDS[index]}\"
        case \"\$word\" in
            -h|--help|-l|--list|-s|--split-windows)
                return 0
                ;;
            -f|--force|-t|--test|--check)
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
        write_user_file "$bash_completion" "$BASH_COMP_DIR/boot" 644 "bash-comp" || {
            say "${RED}[!] Failed while configuring Bash completion.${RESET}"
            return 1
        }
        bashrc="$HOME_PREFIX/.bashrc"
        append_unique_line "$bashrc" '[[ -r "$HOME/.local/share/bash-completion/completions/boot" ]] && source "$HOME/.local/share/bash-completion/completions/boot"' bash-completion || {
            say "${RED}[!] Failed while updating ${bashrc}.${RESET}"
            return 1
        }
        configured_list+="Bash, "
    fi

    if has_shell_family nu; then
        nu_completion="def 'nu-complete boot' [] {
    ^$BIN_PATH --complete | lines
}
export extern boot [...args: string@\"nu-complete boot\"]"
        write_user_file "$nu_completion" "$NU_DIR/boot.nu" 644 "nu-comp" || return 1
        nu_config="$NU_DIR/config.nu"
        append_unique_line "$nu_config" 'source ~/.config/nushell/boot.nu' nu-source || return 1
        configured_list+="Nushell, "
    fi

    if has_shell_family elvish; then
        elvish_module="use str
set edit:completion:arg-completer[boot] = {|@args|
    var flags = ['-h' '--help' '-l' '--list' '-t' '--test' '-f' '--force' '-s' '--split-windows']
    for f \$flags { put \$f }
    try {
        for line [($BIN_PATH --complete 2>/dev/null | str:split \"\n\" (slurp))] {
            if (not (eq \$line '')) { put \$line }
        }
    } catch _ { }
}"
        write_user_file "$elvish_module" "$ELVISH_LIB_DIR/boot.elv" 644 "elvish-comp" || return 1
        elvish_rc="$ELVISH_DIR/rc.elv"
        append_unique_line "$elvish_rc" 'use boot' elvish-use || return 1
        configured_list+="Elvish, "
    fi

    if has_shell_family xonsh; then
        xonsh_module="import subprocess
from xonsh.completers.tools import contextual_command_completer

@contextual_command_completer
def _multiboot_completer(context):
    if not context.args or context.args[0].value != 'boot':
        return None
    opts = {'-h', '--help', '-l', '--list', '-t', '--test', '-f', '--force', '-s', '--split-windows'}
    try:
        out = subprocess.check_output(['$BIN_PATH', '--complete'], text=True, stderr=subprocess.DEVNULL)
        for line in out.splitlines():
            if line.strip():
                opts.add(line.strip())
    except Exception:
        pass
    return {c for c in opts if c.startswith(context.prefix)}

completer add multiboot _multiboot_completer start"
        write_user_file "$xonsh_module" "$XONSH_RCD_DIR/boot.xsh" 644 "xonsh-comp" || return 1
        configured_list+="Xonsh, "
    fi

    if has_shell_family pwsh; then
        pwsh_profile="$PWSH_DIR/Microsoft.PowerShell_profile.ps1"
        pwsh_block="Register-ArgumentCompleter -Native -CommandName boot -ScriptBlock { param(\$wordToComplete, \$commandAst, \$cursorPosition) @('-h','--help','-l','--list','-t','--test','-f','--force','-s','--split-windows') + (& '$BIN_PATH' --complete 2>\$null) | Where-Object { \$_ -like \"\$wordToComplete*\" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new(\$_, \$_, 'ParameterValue', \$_) } }"
        append_unique_line "$pwsh_profile" "$pwsh_block" pwsh-comp || return 1
        configured_list+="PowerShell, "
    fi

    if has_shell_family tcsh; then
        tcsh_block="complete boot 'p/*/\`/usr/local/bin/boot --complete\`/'"
        if [[ -f "$HOME_PREFIX/.tcshrc" || -n "${DETECTED_SHELLS[tcsh]+x}" ]]; then
            tcshrc="$HOME_PREFIX/.tcshrc"
            append_unique_line "$tcshrc" 'if ( "$path" !~ */usr/local/bin* ) set path = ( /usr/local/bin $path )' tcsh-path || return 1
            append_unique_line "$tcshrc" "$tcsh_block" tcsh-comp || return 1
        fi
        if [[ -f "$HOME_PREFIX/.cshrc" || -n "${DETECTED_SHELLS[csh]+x}" ]]; then
            cshrc="$HOME_PREFIX/.cshrc"
            append_unique_line "$cshrc" 'if ( "$path" !~ */usr/local/bin* ) set path = ( /usr/local/bin $path )' csh-path || return 1
        fi
        configured_list+="Tcsh/Csh, "
    fi

    if has_shell_family ksh; then
        ksh_block='case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac'
        if [[ -f "$HOME_PREFIX/.kshrc" || -n "${DETECTED_SHELLS[ksh]+x}" || -n "${DETECTED_SHELLS[ksh93]+x}" ]]; then
            kshrc="$HOME_PREFIX/.kshrc"
            append_unique_line "$kshrc" "$ksh_block" ksh-path || return 1
        fi
        if [[ -f "$HOME_PREFIX/.mkshrc" || -n "${DETECTED_SHELLS[mksh]+x}" ]]; then
            mkshrc="$HOME_PREFIX/.mkshrc"
            append_unique_line "$mkshrc" "$ksh_block" mksh-path || return 1
        fi
        configured_list+="Ksh/Mksh, "
    fi

    if has_shell_family oils; then
        oils_block='case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac'
        oshrc="$OILS_DIR/oshrc"
        yshrc="$OILS_DIR/yshrc"
        append_unique_line "$oshrc" "$oils_block" osh-path || return 1
        append_unique_line "$yshrc" "$oils_block" ysh-path || return 1
        configured_list+="Oils, "
    fi

    if has_shell_family ion; then
        ion_block='export PATH = "/usr/local/bin:${PATH}"'
        ionrc="$ION_DIR/initrc"
        append_unique_line "$ionrc" "$ion_block" ion-path || return 1
        configured_list+="Ion, "
    fi

    if has_shell_family murex; then
        murex_profile="$HOME_PREFIX/.murex_profile"
        murex_block='autocomplete set boot %[{ Dynamic: ({ /usr/local/bin/boot --complete }) }]'
        append_unique_line "$murex_profile" "$murex_block" murex-comp || return 1
        configured_list+="Murex, "
    fi

    profile_file="$HOME_PREFIX/.profile"
    validate_safe_user_path "$profile_file" "file" || {
        say "${RED}[!] Failed while validating ${profile_file}.${RESET}"
        return 1
    }
    if ! grep -Fq '/usr/local/bin' "$profile_file" 2>/dev/null; then
        append_unique_line "$profile_file" 'export PATH="/usr/local/bin:$PATH"' profile-path || {
            say "${RED}[!] Failed while updating ${profile_file}.${RESET}"
            return 1
        }
    fi
    if [[ -f "$HOME_PREFIX/.shrc" ]]; then
        shrc="$HOME_PREFIX/.shrc"
        if ! grep -Fq '/usr/local/bin' "$shrc" 2>/dev/null; then
            append_unique_line "$shrc" 'export PATH="/usr/local/bin:$PATH"' shrc-path || {
                say "${RED}[!] Failed while updating ${shrc}.${RESET}"
                return 1
            }
        fi
    fi

    if [[ -n "$configured_list" ]]; then
        say "${GREEN}[+] Configured user shells: ${configured_list}and POSIX/TTY PATH.${RESET}"
    else
        say "${GREEN}[+] Configured POSIX/TTY PATH.${RESET}"
    fi
    say "${GREEN}[+] Installed system-wide vendor shell completions and /etc/profile.d hooks for future shell switches.${RESET}"
}

do_sync_shells() {
    if [[ ! -x "$BIN_PATH" ]]; then
        say "${RED}[!] Multi Boot is not installed yet. Run Install first.${RESET}"
        return 1
    fi
    authenticate_root || return 1
    if ! configure_shells; then
        cleanup_active_state
        say "${RED}[!] Failed to synchronize shell integrations.${RESET}"
        return 1
    fi
    cleanup_active_state
    say "${GREEN}[+] All detected shells have been synchronized.${RESET}"
}

print_restart_notice() {
    say "${GREEN}Installation completed successfully.${RESET}"
    say "${YELLOW}Please restart your Terminal or start a new login session.${RESET}"
}

remove_empty_user_dirs() {
    local dir
    local -a candidate_dirs=(
        "$FISH_FUNC_DIR"
        "$FISH_COMP_DIR"
        "$FISH_DIR"
        "$ZSH_COMP_DIR"
        "$HOME_PREFIX/.zsh"
        "$BASH_COMP_DIR"
        "$HOME_PREFIX/.local/share/bash-completion"
        "$NU_DIR"
        "$ELVISH_LIB_DIR"
        "$ELVISH_DIR"
        "$XONSH_RCD_DIR"
        "$XONSH_DIR"
        "$PWSH_DIR"
        "$OILS_DIR"
        "$ION_DIR"
    )
    for dir in "${candidate_dirs[@]}"; do
        if [[ -d "$dir" && ! -L "$dir" ]]; then
            validate_safe_user_path "$dir" "dir" 2>/dev/null || continue
            run_as_target_user rmdir "$dir" 2>/dev/null || true
        fi
    done
}

cleanup_user_shell_artifacts() {
    local -a user_file_pairs=(
        "$FISH_FUNC_DIR/boot.fish|fish-func"
        "$FISH_COMP_DIR/boot.fish|fish-comp"
        "$ZSH_COMP_DIR/_boot|zsh-comp"
        "$BASH_COMP_DIR/boot|bash-comp"
        "$NU_DIR/boot.nu|nu-comp"
        "$ELVISH_LIB_DIR/boot.elv|elvish-comp"
        "$XONSH_RCD_DIR/boot.xsh|xonsh-comp"
    )
    local pair target_file marker_name
    for pair in "${user_file_pairs[@]}"; do
        target_file="${pair%%|*}"
        marker_name="${pair#*|}"
        if [[ -e "$target_file" || -L "$target_file" ]]; then
            validate_safe_user_path "$target_file" "file" || return 1
            if [[ -f "$STATE_DIR/backup-$marker_name" && ! -L "$STATE_DIR/backup-$marker_name" ]]; then
                validate_safe_user_path "$STATE_DIR/backup-$marker_name" "file" || return 1
                run_as_target_user mv -Tf -- "$STATE_DIR/backup-$marker_name" "$target_file" || return 1
            elif grep -Fqx "file:$marker_name" "$STATE_FILE" 2>/dev/null || grep -Fq "$BIN_PATH" "$target_file" 2>/dev/null; then
                run_as_target_user rm -f -- "$target_file" || return 1
            else
                say "${YELLOW}[!] Preserved pre-existing file not created by Multi Boot: ${target_file}${RESET}"
            fi
        fi
    done

    local zsh_single_quoted_dir="'${ZSH_COMP_DIR//\'/\'\\\'\'}'"
    remove_exact_line "$HOME_PREFIX/.zshrc" "fpath=(${zsh_single_quoted_dir} \$fpath)" || return 1
    remove_exact_line "$HOME_PREFIX/.zshrc" "fpath=(\"$ZSH_COMP_DIR\" \$fpath)" || return 1
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'zsh-compinit' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.zshrc" 'autoload -Uz compinit && compinit' || return 1
    fi
    remove_exact_line "$HOME_PREFIX/.zshrc" 'compdef _boot boot' || return 1

    remove_exact_line "$HOME_PREFIX/.bashrc" '[[ -r "$HOME/.local/share/bash-completion/completions/boot" ]] && source "$HOME/.local/share/bash-completion/completions/boot"' || return 1
    remove_exact_line "$NU_DIR/config.nu" 'source ~/.config/nushell/boot.nu' || return 1
    remove_exact_line "$ELVISH_DIR/rc.elv" 'use boot' || return 1
    remove_exact_line "$PWSH_DIR/Microsoft.PowerShell_profile.ps1" "Register-ArgumentCompleter -Native -CommandName boot -ScriptBlock { param(\$wordToComplete, \$commandAst, \$cursorPosition) @('-h','--help','-l','--list','-t','--test','-f','--force','-s','--split-windows') + (& '$BIN_PATH' --complete 2>\$null) | Where-Object { \$_ -like \"\$wordToComplete*\" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new(\$_, \$_, 'ParameterValue', \$_) } }" || return 1
    remove_exact_line "$HOME_PREFIX/.tcshrc" "complete boot 'p/*/\`/usr/local/bin/boot --complete\`/'" || return 1
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'tcsh-path' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.tcshrc" 'if ( "$path" !~ */usr/local/bin* ) set path = ( /usr/local/bin $path )' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'csh-path' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.cshrc" 'if ( "$path" !~ */usr/local/bin* ) set path = ( /usr/local/bin $path )' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'ksh-path' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.kshrc" 'case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'mksh-path' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.mkshrc" 'case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'osh-path' "$STATE_FILE"; then
        remove_exact_line "$OILS_DIR/oshrc" 'case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'ysh-path' "$STATE_FILE"; then
        remove_exact_line "$OILS_DIR/yshrc" 'case ":$PATH:" in *:/usr/local/bin:*) ;; *) export PATH="/usr/local/bin:$PATH" ;; esac' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'ion-path' "$STATE_FILE"; then
        remove_exact_line "$ION_DIR/initrc" 'export PATH = "/usr/local/bin:${PATH}"' || return 1
    fi
    remove_exact_line "$HOME_PREFIX/.murex_profile" 'autocomplete set boot %[{ Dynamic: ({ /usr/local/bin/boot --complete }) }]' || return 1
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'profile-path' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.profile" 'export PATH="/usr/local/bin:$PATH"' || return 1
    fi
    if [[ -f "$STATE_FILE" ]] && grep -Fqx 'shrc-path' "$STATE_FILE"; then
        remove_exact_line "$HOME_PREFIX/.shrc" 'export PATH="/usr/local/bin:$PATH"' || return 1
    fi

    scrub_fish_history

    local dotfile
    for dotfile in "$HOME_PREFIX/.zshrc" "$HOME_PREFIX/.bashrc" "$NU_DIR/config.nu" "$ELVISH_DIR/rc.elv" "$PWSH_DIR/Microsoft.PowerShell_profile.ps1" "$HOME_PREFIX/.tcshrc" "$HOME_PREFIX/.cshrc" "$HOME_PREFIX/.kshrc" "$HOME_PREFIX/.mkshrc" "$OILS_DIR/oshrc" "$OILS_DIR/yshrc" "$ION_DIR/initrc" "$HOME_PREFIX/.murex_profile" "$HOME_PREFIX/.profile" "$HOME_PREFIX/.shrc"; do
        cleanup_created_empty_dotfile "$dotfile"
    done

    if [[ -e "$STATE_DIR" ]]; then
        validate_safe_user_path "$STATE_DIR" "dir" || return 1
        run_as_target_user rm -rf -- "$STATE_DIR" 2>/dev/null || true
    fi
    if [[ -e "$CACHE_DIR" ]]; then
        validate_safe_user_path "$CACHE_DIR" "dir" || return 1
        run_as_target_user rm -rf -- "$CACHE_DIR" 2>/dev/null || true
    fi

    remove_empty_user_dirs
}

remove_system_wide_shell_hooks() {
    local sys_file
    local -a sys_files=(
        "$SYS_PROFILE_SH"
        "$SYS_PROFILE_CSH"
        "$SYS_BASH_COMP"
        "$SYS_ZSH_COMP"
        "$SYS_FISH_FUNC"
        "$SYS_FISH_COMP"
        "$SYS_MANIFEST"
    )
    if run_root test -f "$SYS_MANIFEST" 2>/dev/null; then
        while IFS= read -r sys_file; do
            [[ -n "$sys_file" && "$sys_file" == /* ]] || continue
            run_root rm -f -- "$sys_file" 2>/dev/null || true
        done < <(run_root cat "$SYS_MANIFEST" 2>/dev/null || true)
    fi
    for sys_file in "${sys_files[@]}"; do
        run_root rm -f -- "$sys_file" 2>/dev/null || true
    done
    run_root rmdir "$SYS_STATE_DIR" 2>/dev/null || true
    run_root rmdir "$SYS_BASH_COMP_DIR" 2>/dev/null || true
    run_root rmdir "/usr/local/share/bash-completion" 2>/dev/null || true
    run_root rmdir "$SYS_ZSH_COMP_DIR" 2>/dev/null || true
    run_root rmdir "/usr/local/share/zsh" 2>/dev/null || true
    run_root rmdir "$SYS_FISH_FUNC_DIR" 2>/dev/null || true
    run_root rmdir "$SYS_FISH_COMP_DIR" 2>/dev/null || true
    run_root rmdir "/usr/share/fish" 2>/dev/null || true
    run_root rmdir "$LIBEXEC_DIR" 2>/dev/null || true
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
    if (( had_bin == 0 && had_helper == 0 && had_sudoers == 0 )); then
        remove_system_wide_shell_hooks
    fi
}

do_install() {
    local action="${1:-install}"
    local first_confirmation second_confirmation backup_dir=""
    local exists_helper=0 had_helper=0 exists_sudoers=0 had_sudoers=0 exists_bin=0 had_bin=0
    if [[ "$action" == "repair" ]]; then
        say "${BLUE}[*] Preparing Multi Boot repair.${RESET}"
        first_confirmation="Repair Multi Boot for ${TARGET_USER}? (y/n)"
        second_confirmation="This will replace the core command, revalidate EFISTUB, refresh sudo UEFI permissions, and rebuild all shell integrations. Continue? (y/n)"
    else
        say "${BLUE}[*] Preparing Multi Boot installation.${RESET}"
        first_confirmation="Install Multi Boot for ${TARGET_USER}? (y/n)"
        second_confirmation="This will install the system-wide boot command and configure password-authenticated UEFI boot permissions across all detected shells. Continue? (y/n)"
    fi
    if ! validate_source; then
        return 1
    fi
    if ! verify_dependencies_present; then
        return 1
    fi
    if ! confirm_twice "$first_confirmation" "$second_confirmation"; then
        say "${YELLOW}Operation cancelled.${RESET}"
        return 0
    fi
    authenticate_root || return 1
    ALLOW_ROOT_VERIFY=1
    if ! detect_current_efistub; then
        ALLOW_ROOT_VERIFY=0
        cleanup_active_state
        say "${RED}[!] EFISTUB verification failed: ${EFISTUB_REASON}${RESET}"
        say "${RED}Multi Boot can only be installed while a Linux kernel is booted directly through EFISTUB.${RESET}"
        return 1
    fi
    if ! verify_current_efistub_file; then
        ALLOW_ROOT_VERIFY=0
        cleanup_active_state
        say "${RED}[!] EFISTUB verification failed: ${EFISTUB_REASON}${RESET}"
        say "${RED}Multi Boot only supports a directly loaded Linux EFISTUB kernel.${RESET}"
        return 1
    fi
    ALLOW_ROOT_VERIFY=0
    say "${GREEN}[+] Direct EFISTUB boot confirmed: ${EFISTUB_REASON}${RESET}"

    backup_dir="$(mktemp -d)" || {
        cleanup_active_state
        return 1
    }
    _ACTIVE_CLEANUP_DIR="$backup_dir"
    if run_root test -e "$HELPER_PATH" 2>/dev/null; then
        exists_helper=1
        if ! run_root cat "$HELPER_PATH" > "$backup_dir/helper" 2>/dev/null; then
            cleanup_active_state
            say "${RED}[!] Failed to back up existing helper before modification. Installation stopped.${RESET}"
            return 1
        fi
        had_helper=1
    fi
    if run_root test -e "$SUDOERS_PATH" 2>/dev/null; then
        exists_sudoers=1
        if ! run_root cat "$SUDOERS_PATH" > "$backup_dir/sudoers" 2>/dev/null; then
            cleanup_active_state
            say "${RED}[!] Failed to back up existing sudoers rule before modification. Installation stopped.${RESET}"
            return 1
        fi
        had_sudoers=1
    fi
    if run_root test -e "$BIN_PATH" 2>/dev/null; then
        exists_bin=1
        if ! run_root cat "$BIN_PATH" > "$backup_dir/bin" 2>/dev/null; then
            cleanup_active_state
            say "${RED}[!] Failed to back up existing boot command before modification. Installation stopped.${RESET}"
            return 1
        fi
        had_bin=1
    fi
    if ! create_efi_reader_helper; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        cleanup_active_state
        say "${RED}[!] Failed to install the restricted EFI reader helper.${RESET}"
        return 1
    fi
    if ! create_sudoers_rule; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        cleanup_active_state
        say "${RED}[!] Failed to install the sudoers rule.${RESET}"
        return 1
    fi
    if ! run_root install -d -m 755 -o root -g root "$BIN_DIR"; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        cleanup_active_state
        say "${RED}[!] Failed to create the system binary directory.${RESET}"
        return 1
    fi
    if ! install_boot_binary; then
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        cleanup_active_state
        say "${RED}[!] Failed to install the boot command.${RESET}"
        return 1
    fi
    say "${GREEN}[+] Installed $BIN_PATH.${RESET}"
    if ! configure_shells; then
        if (( had_bin == 0 && had_helper == 0 && had_sudoers == 0 )); then
            cleanup_user_shell_artifacts >/dev/null 2>&1 || true
        fi
        rollback_system_files "$backup_dir" "$exists_bin" "$had_bin" "$exists_helper" "$had_helper" "$exists_sudoers" "$had_sudoers"
        cleanup_active_state
        say "${RED}[!] Failed to configure shell integrations; rolled back system files.${RESET}"
        return 1
    fi
    cleanup_active_state
    print_restart_notice
}

do_remove() {
    local has_sys=0 check_path check_dir sys_backup_dir=""
    local exists_bin=0 had_bin=0 exists_helper=0 had_helper=0 exists_sudoers=0 had_sudoers=0
    local -a sys_remaining=()

    if [[ ! -e "$BIN_PATH" && ! -e "$SUDOERS_PATH" && ! -e "$HELPER_PATH" \
        && ! -e "$SYS_MANIFEST" && ! -e "$SYS_PROFILE_SH" && ! -e "$SYS_PROFILE_CSH" \
        && ! -e "$SYS_BASH_COMP" && ! -e "$SYS_ZSH_COMP" && ! -e "$SYS_FISH_FUNC" && ! -e "$SYS_FISH_COMP" \
        && ! -e "$FISH_FUNC_DIR/boot.fish" && ! -e "$FISH_COMP_DIR/boot.fish" \
        && ! -e "$ZSH_COMP_DIR/_boot" && ! -e "$BASH_COMP_DIR/boot" \
        && ! -e "$NU_DIR/boot.nu" && ! -e "$ELVISH_LIB_DIR/boot.elv" && ! -e "$XONSH_RCD_DIR/boot.xsh" \
        && ! -e "$STATE_DIR" && ! -e "$CACHE_DIR" ]]; then
        say "${YELLOW}Multi Boot is not installed.${RESET}"
        return 0
    fi

    if ! confirm_twice "Remove Multi Boot completely from this system? (y/n)" "This will purge the core command, privileged helper, sudoers rule, isolated Windows BCD entries, and all user/system shell integrations with zero leftover files. Continue? (y/n)"; then
        say "${YELLOW}Removal cancelled.${RESET}"
        return 0
    fi

    if [[ -e "$BIN_PATH" || -e "$HELPER_PATH" || -e "$SUDOERS_PATH" || -e "$SYS_MANIFEST" \
        || -e "$SYS_PROFILE_SH" || -e "$SYS_PROFILE_CSH" || -e "$SYS_BASH_COMP" \
        || -e "$SYS_ZSH_COMP" || -e "$SYS_FISH_FUNC" || -e "$SYS_FISH_COMP" \
        || ( -d "$SUDOERS_DIR" && ! -x "$SUDOERS_DIR" ) ]]; then
        has_sys=1
    fi

    if (( EUID != 0 )); then
        for check_path in "$FISH_FUNC_DIR/boot.fish" "$FISH_COMP_DIR/boot.fish" "$ZSH_COMP_DIR/_boot" "$BASH_COMP_DIR/boot" "$NU_DIR/boot.nu" "$ELVISH_LIB_DIR/boot.elv" "$XONSH_RCD_DIR/boot.xsh" "$STATE_FILE"; do
            if [[ -e "$check_path" || -L "$check_path" ]]; then
                check_dir="$(dirname "$check_path")"
                if [[ ! -w "$check_dir" ]]; then
                    say "${RED}[!] Insufficient permissions to modify ${check_dir}. Removal stopped before making changes.${RESET}"
                    return 1
                fi
            fi
        done
        for check_path in "$HOME_PREFIX/.zshrc" "$HOME_PREFIX/.bashrc" "$NU_DIR/config.nu" "$ELVISH_DIR/rc.elv" "$PWSH_DIR/Microsoft.PowerShell_profile.ps1" "$HOME_PREFIX/.tcshrc" "$HOME_PREFIX/.cshrc" "$HOME_PREFIX/.kshrc" "$HOME_PREFIX/.mkshrc" "$OILS_DIR/oshrc" "$OILS_DIR/yshrc" "$ION_DIR/initrc" "$HOME_PREFIX/.murex_profile" "$HOME_PREFIX/.profile" "$HOME_PREFIX/.shrc"; do
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
        authenticate_root || return 1
        if run_root test -x "$HELPER_PATH" 2>/dev/null; then
            run_root "$HELPER_PATH" clean-win-isolated >/dev/null 2>&1 || true
        fi
        sys_backup_dir="$(mktemp -d)" || {
            cleanup_active_state
            return 1
        }
        _ACTIVE_CLEANUP_DIR="$sys_backup_dir"
        if run_root test -e "$BIN_PATH" 2>/dev/null; then
            exists_bin=1
            run_root cat "$BIN_PATH" > "$sys_backup_dir/bin" 2>/dev/null && had_bin=1 || true
        fi
        if run_root test -e "$HELPER_PATH" 2>/dev/null; then
            exists_helper=1
            run_root cat "$HELPER_PATH" > "$sys_backup_dir/helper" 2>/dev/null && had_helper=1 || true
        fi
        if run_root test -e "$SUDOERS_PATH" 2>/dev/null; then
            exists_sudoers=1
            run_root cat "$SUDOERS_PATH" > "$sys_backup_dir/sudoers" 2>/dev/null && had_sudoers=1 || true
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
            cleanup_active_state
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
        remove_system_wide_shell_hooks
        cleanup_active_state
    fi

    cleanup_user_shell_artifacts || return 1

    say "${GREEN}Multi Boot was completely removed with zero leftover files.${RESET}"
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
    local state pm_detected distro_detected shells_summary="" sb_var sb_val="Unknown"
    say "${BOLD}${BLUE}Multi Boot System & Installation Status${RESET}"
    state="$(installation_state)"
    case "$state" in
        Installed) say "${GREEN}[+] Installation: Complete${RESET}" ;;
        Incomplete) say "${YELLOW}[!] Installation: Incomplete${RESET}" ;;
        *) say "${RED}[-] Installation: Not installed${RESET}" ;;
    esac
    distro_detected="$(detect_distro_id)"
    pm_detected="$(detect_package_manager 2>/dev/null || printf 'unknown')"
    say "${BLUE}[*] Distribution / PM: ${distro_detected} (${pm_detected})${RESET}"

    sb_var="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    if [[ -r "$sb_var" ]]; then
        sb_val="$(od -An -tu1 -j4 -N1 "$sb_var" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$sb_val" == "1" ]]; then
            say "${YELLOW}[*] Secure Boot: Enabled${RESET}"
        elif [[ "$sb_val" == "0" ]]; then
            say "${GREEN}[*] Secure Boot: Disabled${RESET}"
        fi
    fi

    if [[ -x "$BIN_PATH" ]]; then
        say "${GREEN}[+] Core: Installed at ${BIN_PATH}${RESET}"
    else
        say "${RED}[-] Core: Missing${RESET}"
    fi
    if [[ -z "$VISUDO_BIN" ]]; then
        VISUDO_BIN="$(resolve_binary visudo 2>/dev/null || true)"
    fi
    if (( EUID == 0 )) || [[ -r "$SUDOERS_PATH" ]]; then
        if [[ -f "$SUDOERS_PATH" ]]; then
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
            say "${RED}[-] Sudoers: Not configured${RESET}"
        fi
    elif [[ -x "$SUDOERS_DIR" ]]; then
        if [[ -f "$SUDOERS_PATH" ]]; then
            local sudoers_meta
            sudoers_meta="$(stat -c '%u:%g:%a' "$SUDOERS_PATH" 2>/dev/null || true)"
            if [[ "$sudoers_meta" == "0:0:440" || "$sudoers_meta" == "0:0:400" ]]; then
                say "${GREEN}[+] Sudoers: Installed with secure permissions (0440 root:root)${RESET}"
            else
                say "${RED}[-] Sudoers: Unexpected ownership/permissions (${sudoers_meta})${RESET}"
            fi
        else
            say "${RED}[-] Sudoers: Not configured${RESET}"
        fi
    elif [[ -d "$SUDOERS_DIR" && -f "$SYS_MANIFEST" ]]; then
        say "${GREEN}[+] Sudoers: Installed (protected inside 0750 /etc/sudoers.d)${RESET}"
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
    if [[ -x "$(resolve_binary python3 2>/dev/null || true)" ]]; then
        say "${GREEN}[+] python3: Available${RESET}"
    else
        say "${RED}[-] python3: Missing ($(diagnose_binary python3))${RESET}"
    fi

    say "${BLUE}[*] Detected system shells: $(format_detected_shells_list)${RESET}"
    [[ -f "$FISH_FUNC_DIR/boot.fish" && -f "$FISH_COMP_DIR/boot.fish" ]] && shells_summary+="Fish, "
    [[ -f "$ZSH_COMP_DIR/_boot" ]] && shells_summary+="Zsh, "
    [[ -f "$BASH_COMP_DIR/boot" ]] && shells_summary+="Bash, "
    [[ -f "$NU_DIR/boot.nu" ]] && shells_summary+="Nushell, "
    [[ -f "$ELVISH_LIB_DIR/boot.elv" ]] && shells_summary+="Elvish, "
    [[ -f "$XONSH_RCD_DIR/boot.xsh" ]] && shells_summary+="Xonsh, "
    [[ -f "$SYS_BASH_COMP" && -f "$SYS_ZSH_COMP" && -f "$SYS_FISH_FUNC" ]] && shells_summary+="System-wide hooks, "
    if [[ -n "$shells_summary" ]]; then
        say "${GREEN}[+] Configured shells: ${shells_summary%, }${RESET}"
    else
        say "${RED}[-] Configured shells: None${RESET}"
    fi
    show_efistub_status || true
}

pause_menu() {
    printf '\n'
    printf 'Press Enter to return to the menu.'
    read -r _ || true
}

show_menu() {
    local choice=""
    while true; do
        printf '\n'
        say "${BOLD}${CYAN}Multi Boot Management${RESET}"
        say "Status : ${BOLD}$(installation_state)${RESET}"
        say "User   : ${TARGET_USER} ($(id -un))"
        say "Shells : $(format_detected_shells_list)"
        printf '\n'
        printf '1) Install\n'
        printf '2) Install Required Dependencies\n'
        printf '3) Remove / Uninstall\n'
        printf '4) Status\n'
        printf '5) Repair\n'
        printf '6) Sync All Shells\n'
        printf '7) Exit\n'
        printf '\n'
        printf 'Select an option [1-7]: '
        if ! read -r choice; then
            break
        fi
        case "$choice" in
            1) do_install install || true; pause_menu ;;
            2) do_dependencies || true; pause_menu ;;
            3) do_remove || true; pause_menu ;;
            4) do_status || true; pause_menu ;;
            5) do_install repair || true; pause_menu ;;
            6) do_sync_shells || true; pause_menu ;;
            7|q|Q|exit|EXIT) break ;;
            *) say "${RED}Invalid option.${RESET}" ;;
        esac
    done
}

usage() {
    cat <<'EOF_USAGE'
Usage: ./install.sh [OPTION]

Options:
  --install        Install Multi Boot (interactive confirmation)
  --deps           Check and install required dependencies
  --remove         Remove Multi Boot completely
  --status         Show installation and EFISTUB status
  --repair         Reinstall and repair Multi Boot components
  --sync-shells    Re-apply Multi Boot integration to all detected shells
  -y, --yes        Skip confirmation prompts
  -h, --help       Show this help message
EOF_USAGE
}

main() {
    local mode=""
    while (( $# > 0 )); do
        case "$1" in
            --install) mode="install" ;;
            --deps|--dependencies) mode="deps" ;;
            --remove|--uninstall) mode="remove" ;;
            --status) mode="status" ;;
            --repair) mode="repair" ;;
            --sync-shells) mode="sync" ;;
            -y|--yes) AUTO_YES=1 ;;
            -h|--help) usage; return 0 ;;
            *)
                say "${RED}Unknown argument: $1${RESET}"
                usage
                return 1
                ;;
        esac
        shift
    done

    case "$mode" in
        install) do_install install ;;
        deps) do_dependencies ;;
        remove) do_remove ;;
        status) do_status ;;
        repair) do_install repair ;;
        sync) do_sync_shells ;;
        "") show_menu ;;
    esac
}

main "$@"
