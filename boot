#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
export MTOOLS_SKIP_CHECK=1
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_CYAN=$'\033[1;36m'
MAX_TARGETS=10
EFI_READ_HELPER=/usr/local/libexec/multiboot-efi-read

resolve_tool_path() {
    local name="$1"
    local found=""
    found="$(command -v "$name" 2>/dev/null || true)"
    if [[ -n "$found" && -x "$found" ]]; then
        printf '%s' "$found"
        return 0
    fi
    for found in "/usr/bin/$name" "/usr/sbin/$name" "/bin/$name" "/sbin/$name" "/usr/local/bin/$name" "/usr/local/sbin/$name"; do
        if [[ -x "$found" ]]; then
            printf '%s' "$found"
            return 0
        fi
    done
    return 1
}

EFI_BIN="$(resolve_tool_path efibootmgr 2>/dev/null || true)"
BOOTCTL_BIN="$(resolve_tool_path bootctl 2>/dev/null || true)"
SYSTEMCTL_BIN="$(resolve_tool_path systemctl 2>/dev/null || true)"
[[ -d /run/systemd/system ]] || SYSTEMCTL_BIN=""

TARGET_BACKENDS=()
TARGET_IDS=()
TARGET_ACTIVE=()
TARGET_LABELS=()
TARGET_LOADERS=()
TARGET_PARTUUIDS=()
TARGET_OPTIONS=()
TARGET_FAMILIES=()
TARGET_FLAVORS=()
TARGET_NAMES=()
TARGET_VERSIONS=()
SDBOOT_MANAGER_ID=""
SDBOOT_MANAGER_ACTIVE="0"
BOOT_CURRENT_ID=""
SDBOOT_CURRENT_ID=""
EFI_OUTPUT=""

print_success() {
    printf '%s\n' "${C_GREEN}Success:${C_RESET} $*"
}

print_failed() {
    printf '%s\n' "${C_RED}Failed:${C_RESET} $*" >&2
}

get_partuuid_device() {
    local uuid="${1,,}"
    local dev=""
    [[ "$uuid" =~ ^[[:xdigit:]-]{36}$ ]] || return 1
    if [[ -e "/dev/disk/by-partuuid/$uuid" ]]; then
        printf '%s' "/dev/disk/by-partuuid/$uuid"
        return 0
    fi
    if [[ -e "/dev/disk/by-partuuid/${uuid^^}" ]]; then
        printf '%s' "/dev/disk/by-partuuid/${uuid^^}"
        return 0
    fi
    if command -v blkid >/dev/null 2>&1; then
        dev="$(blkid -t "PARTUUID=$uuid" -o device 2>/dev/null | head -n 1 || true)"
        [[ -z "$dev" ]] && dev="$(blkid -t "PARTUUID=${uuid^^}" -o device 2>/dev/null | head -n 1 || true)"
        if [[ -n "$dev" && -b "$dev" ]]; then
            printf '%s' "$dev"
            return 0
        fi
    fi
    return 1
}

get_partition_type() {
    local device="$1"
    local type=""
    type="$(lsblk -dnro FSTYPE "$device" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$type" ]] && command -v blkid >/dev/null 2>&1; then
        type="$(blkid -o value -s TYPE "$device" 2>/dev/null | head -n 1 || true)"
    fi
    if [[ -z "$type" ]]; then
        local parttype
        parttype="$(lsblk -dnro PARTTYPE "$device" 2>/dev/null | tr '[:upper:]' '[:lower:]' | head -n 1 || true)"
        case "$parttype" in
            7c3457ef-0000-11aa-aa11-00306543ecac) type="apfs" ;;
            48465300-0000-11aa-aa11-00306543ecac) type="hfsplus" ;;
        esac
    fi
    printf '%s' "${type,,}"
}

find_esp_mounts() {
    local mountpoint fstype
    local -A seen=()
    for mountpoint in /efi /boot/efi /boot; do
        if [[ -d "$mountpoint" && ( -d "$mountpoint/EFI" || -d "$mountpoint/efi" || -d "$mountpoint/loader/entries" ) ]]; then
            if [[ -z "${seen[$mountpoint]+x}" ]]; then
                seen[$mountpoint]=1
                printf '%s\n' "$mountpoint"
            fi
        fi
    done
    if command -v findmnt >/dev/null 2>&1; then
        while IFS= read -r mountpoint; do
            [[ -n "$mountpoint" && -d "$mountpoint" ]] || continue
            if [[ -z "${seen[$mountpoint]+x}" ]]; then
                seen[$mountpoint]=1
                printf '%s\n' "$mountpoint"
            fi
        done < <(findmnt -rn -t vfat,fat,msdos -o TARGET 2>/dev/null || true)
    elif [[ -r /proc/mounts ]]; then
        while read -r _ mountpoint fstype _; do
            case "${fstype,,}" in
                vfat|fat|msdos)
                    if [[ -d "$mountpoint" && -z "${seen[$mountpoint]+x}" ]]; then
                        seen[$mountpoint]=1
                        printf '%s\n' "$mountpoint"
                    fi
                    ;;
            esac
        done < /proc/mounts
    fi
}

find_partition_mount() {
    local device="$1"
    local real_device target
    real_device="$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")"
    if command -v findmnt >/dev/null 2>&1; then
        target="$(findmnt -rn -S "$real_device" -o TARGET 2>/dev/null | head -n 1 || true)"
        if [[ -n "$target" ]]; then
            printf '%s' "$target"
            return 0
        fi
    fi
    if [[ -r /proc/mounts ]]; then
        while read -r src target _; do
            if [[ "$(readlink -f "$src" 2>/dev/null || printf '%s' "$src")" == "$real_device" ]]; then
                printf '%s' "$target"
                return 0
            fi
        done < /proc/mounts
    fi
}

resolve_case_insensitive_file() {
    local root="$1"
    local relative="${2//\\//}"
    relative="${relative#/}"
    [[ -n "$relative" ]] || return 1
    local current="$root"
    local component found
    local -a components=()
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        found="$(find "$current" -mindepth 1 -maxdepth 1 -iname "$component" -print -quit 2>/dev/null || true)"
        [[ -n "$found" ]] || return 1
        current="$found"
    done
    [[ -f "$current" && -s "$current" ]] || return 1
    printf '%s' "$current"
}

resolve_esp_file() {
    local partuuid="${1:-}"
    local relative="$2"
    local device mountpoint resolved
    [[ -n "$relative" ]] || return 1
    if [[ -n "$partuuid" ]]; then
        device="$(get_partuuid_device "$partuuid" 2>/dev/null || true)"
        [[ -n "$device" ]] || return 1
        mountpoint="$(find_partition_mount "$device")"
        if [[ -n "$mountpoint" && -d "$mountpoint" ]]; then
            resolved="$(resolve_case_insensitive_file "$mountpoint" "$relative" 2>/dev/null || true)"
            if [[ -n "$resolved" ]]; then
                printf '%s' "$resolved"
                return 0
            fi
        fi
        return 1
    fi
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        resolved="$(resolve_case_insensitive_file "$mountpoint" "$relative" 2>/dev/null || true)"
        if [[ -n "$resolved" ]]; then
            printf '%s' "$resolved"
            return 0
        fi
    done < <(find_esp_mounts)
    if [[ -d /boot ]]; then
        resolved="$(resolve_case_insensitive_file "/boot" "$relative" 2>/dev/null || true)"
        if [[ -n "$resolved" ]]; then
            printf '%s' "$resolved"
            return 0
        fi
    fi
    return 1
}

run_efi_reader() {
    if [[ ! -x "$EFI_READ_HELPER" ]]; then
        return 1
    fi
    if (( EUID == 0 )); then
        "$EFI_READ_HELPER" "$@"
    else
        sudo -n "$EFI_READ_HELPER" "$@"
    fi
}

entry_file_exists() {
    local partuuid="$1"
    local relative="${2//\\//}"
    local resolved probe_bytes=""
    [[ -n "$relative" ]] || return 1
    resolved="$(resolve_esp_file "$partuuid" "$relative" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
        return 0
    fi
    [[ -n "$partuuid" ]] || return 1
    [[ "$relative" == /* ]] || relative="/$relative"
    if run_efi_reader exists "$partuuid" "$relative" >/dev/null 2>&1; then
        return 0
    fi
    probe_bytes="$(run_efi_reader read "$partuuid" "$relative" </dev/null 2>/dev/null | head -c 1 | wc -c | tr -d '[:space:]' || true)"
    [[ "$probe_bytes" == "1" ]]
}

copy_entry_file() {
    local partuuid="$1"
    local relative="${2//\\//}"
    local destination="$3"
    local resolved
    [[ -n "$relative" ]] || return 1
    resolved="$(resolve_esp_file "$partuuid" "$relative" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
        cp -- "$resolved" "$destination"
        return $?
    fi
    [[ -n "$partuuid" ]] || return 1
    [[ "$relative" == /* ]] || relative="/$relative"
    run_efi_reader read "$partuuid" "$relative" > "$destination"
}

extract_product_version() {
    local file="$1"
    local result=""
    if command -v strings >/dev/null 2>&1; then
        result="$(strings -el -n 4 "$file" 2>/dev/null | tr '\n' ' ' | grep -oiE '(ProductVersion|FileVersion)[^0-9]{0,32}[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
        if [[ -z "$result" ]]; then
            result="$(strings -a -n 4 "$file" 2>/dev/null | tr '\n' ' ' | grep -oiE '(ProductVersion|FileVersion)[^0-9]{0,32}[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
        fi
    fi
    if [[ -z "$result" ]]; then
        result="$(tr -d '\000' < "$file" 2>/dev/null | grep -aoiE '(ProductVersion|FileVersion)[^0-9]{0,32}[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)"
    fi
    printf '%s' "$result"
}

get_kernel_image_version() {
    local file="$1"
    local offset version size dos_magic pe_offset pe_sig num_sec opt_size sec_table idx sec_off sec_name raw_size raw_ptr inner_magic inner_off
    local -a b=()
    [[ -s "$file" ]] || return 1
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge 1024 ]] || return 1
    dos_magic="$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$dos_magic" == "4d5a" ]]; then
        mapfile -t b < <(od -An -tu1 -j60 -N4 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
        if (( ${#b[@]} == 4 )); then
            pe_offset=$(( b[0] + (b[1] << 8) + (b[2] << 16) + (b[3] << 24) ))
            if (( pe_offset >= 64 && pe_offset + 24 <= size )); then
                pe_sig="$(od -An -tx1 -j"$pe_offset" -N4 "$file" 2>/dev/null | tr -d '[:space:]' || true)"
                if [[ "$pe_sig" == "50450000" ]]; then
                    mapfile -t b < <(od -An -tu1 -j$((pe_offset + 6)) -N2 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
                    num_sec=$(( ${b[0]:-0} + (${b[1]:-0} << 8) ))
                    mapfile -t b < <(od -An -tu1 -j$((pe_offset + 20)) -N2 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
                    opt_size=$(( ${b[0]:-0} + (${b[1]:-0} << 8) ))
                    sec_table=$((pe_offset + 24 + opt_size))
                    if (( num_sec > 0 && num_sec <= 64 )); then
                        for ((idx = 0; idx < num_sec; idx++)); do
                            sec_off=$((sec_table + idx * 40))
                            (( sec_off + 24 <= size )) || break
                            sec_name="$(dd if="$file" bs=1 skip="$sec_off" count=8 2>/dev/null | tr -d '\000' || true)"
                            if [[ "$sec_name" == ".linux" ]]; then
                                mapfile -t b < <(od -An -tu1 -j$((sec_off + 16)) -N4 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
                                raw_size=$(( ${b[0]:-0} + (${b[1]:-0} << 8) + (${b[2]:-0} << 16) + (${b[3]:-0} << 24) ))
                                mapfile -t b < <(od -An -tu1 -j$((sec_off + 20)) -N4 "$file" 2>/dev/null | tr -s ' ' '\n' | sed '/^$/d')
                                raw_ptr=$(( ${b[0]:-0} + (${b[1]:-0} << 8) + (${b[2]:-0} << 16) + (${b[3]:-0} << 24) ))
                                if (( raw_ptr > 0 && raw_size >= 1024 && raw_ptr + raw_size <= size )); then
                                    inner_magic="$(od -An -tx1 -j$((raw_ptr + 514)) -N4 "$file" 2>/dev/null | tr -d '[:space:]' || true)"
                                    if [[ "$inner_magic" == "48647253" ]]; then
                                        inner_off="$(od -An -tu2 -j$((raw_ptr + 526)) -N2 "$file" 2>/dev/null | tr -d ' ' || true)"
                                        if [[ "$inner_off" =~ ^[0-9]+$ && "$inner_off" -gt 0 && $((raw_ptr + inner_off + 512)) -lt "$size" ]]; then
                                            version="$(dd if="$file" bs=1 skip=$((raw_ptr + inner_off + 512)) count=96 2>/dev/null | tr -d '\000' | awk '{print $1}' || true)"
                                            if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                                                printf '%s' "$version"
                                                return 0
                                            fi
                                        fi
                                    fi
                                    version="$(tail -c +$((raw_ptr + 1)) "$file" 2>/dev/null | head -c "$raw_size" | tr -d '\000' | grep -aoE 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -n 1 | awk '{print $3}' || true)"
                                    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
                                        printf '%s' "$version"
                                        return 0
                                    fi
                                fi
                            fi
                        done
                    fi
                fi
            fi
        fi
    fi
    offset="$(od -An -tu2 -j 526 -N 2 "$file" 2>/dev/null | tr -d ' ' || true)"
    if [[ "$offset" =~ ^[0-9]+$ && "$offset" -gt 0 && "$offset" -lt 65536 && $((offset + 512)) -lt "$size" ]]; then
        version="$(dd if="$file" bs=1 skip=$((offset + 512)) count=96 2>/dev/null | tr -d '\000' | awk '{print $1}' || true)"
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            printf '%s' "$version"
            return 0
        fi
    fi
    version="$(head -c 2097152 "$file" 2>/dev/null | tr -d '\000' | grep -aoE 'Linux version [0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*' | head -n 1 | awk '{print $3}' || true)"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf '%s' "$version"
        return 0
    fi
    return 1
}

version_from_kernel_name() {
    local name="${1##*/}"
    name="${name%.efi}"
    name="${name%.EFI}"
    if [[ "$name" =~ ([0-9]+\.[0-9]+\.[0-9]+([-._][[:alnum:]_.+-]+)?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

get_windows_version() {
    local partuuid="$1"
    local loader="$2"
    local temporary version
    temporary="$(mktemp)"
    if copy_entry_file "$partuuid" "$loader" "$temporary" 2>/dev/null; then
        version="$(extract_product_version "$temporary")"
        rm -f -- "$temporary"
        printf '%s' "$version"
        return 0
    fi
    rm -f -- "$temporary"
    return 1
}

get_linux_version() {
    local partuuid="$1"
    local loader="$2"
    local temporary resolved version
    resolved="$(resolve_esp_file "$partuuid" "$loader" 2>/dev/null || true)"
    if [[ -n "$resolved" ]]; then
        version="$(get_kernel_image_version "$resolved" 2>/dev/null || true)"
    elif [[ -n "$partuuid" && -x "$EFI_READ_HELPER" ]]; then
        temporary="$(mktemp)"
        if copy_entry_file "$partuuid" "$loader" "$temporary" 2>/dev/null; then
            version="$(get_kernel_image_version "$temporary" 2>/dev/null || true)"
        fi
        rm -f -- "$temporary"
    fi
    if [[ -n "${version:-}" ]]; then
        printf '%s' "$version"
        return 0
    fi
    version="$(version_from_kernel_name "$loader" 2>/dev/null || true)"
    if [[ -n "$version" ]]; then
        printf '%s' "$version"
        return 0
    fi
    return 1
}

normalize_query() {
    local query="${1,,}"
    query="${query//_/ }"
    query="${query//\\/ }"
    query="${query# }"
    query="${query% }"
    while [[ "$query" == *'  '* ]]; do
        query="${query//  / }"
    done
    case "$query" in
        win|windows) query="windows" ;;
        winxp|windowsxp|windows-xp) query="windows xp" ;;
        winvista|windowsvista|windows-vista) query="windows vista" ;;
        win7|windows7|windows-7) query="windows 7" ;;
        win8.1|windows8.1|windows-8.1) query="windows 8.1" ;;
        win8|windows8|windows-8) query="windows 8" ;;
        win10|windows10|windows-10) query="windows 10" ;;
        win11|windows11|windows-11) query="windows 11" ;;
    esac
    for flavor in zen tkg lts hardened cachyos xanmod rt lowlatency liquorix bore mainline ck pf clear cfs tuxedo generic fallback; do
        query="${query//linux-$flavor/linux $flavor}"
        query="${query//linux_$flavor/linux $flavor}"
    done
    printf '%s' "$query"
}

classify_linux_loader() {
    local loader="${1,,}"
    loader="${loader//\\//}"
    local label="${2,,}"
    local base="${loader##*/}"
    local stem="${base%.efi}"
    stem="${stem%.uki}"
    local token="-${stem//_/-}-"
    local label_token=" ${label//_/ } "
    local is_fallback=0
    local flavor=""
    if [[ "$token" == *"-fallback-"* || "$label_token" == *" fallback "* || "$label_token" == *"(fallback)"* ]]; then
        is_fallback=1
    fi
    if [[ "$token" == *"-zen-"* || "$label_token" == *" zen "* || "$label_token" == *"(zen)"* ]]; then
        flavor="zen"
    elif [[ "$token" == *"-tkg-"* || "$label_token" == *" tkg "* || "$label_token" == *"(tkg)"* ]]; then
        flavor="tkg"
    elif [[ "$token" == *"-rt-lts-"* || "$token" == *"-lts-rt-"* ]]; then
        flavor="rt lts"
    elif [[ "$token" == *"-lts-"* || "$label_token" == *" lts "* || "$label_token" == *"(lts)"* ]]; then
        flavor="lts"
    elif [[ "$token" == *"-hardened-"* || "$label_token" == *" hardened "* || "$label_token" == *"(hardened)"* ]]; then
        flavor="hardened"
    elif [[ "$token" == *"-cachyos-bore-"* ]]; then
        flavor="cachyos bore"
    elif [[ "$token" == *"-cachyos-lto-"* ]]; then
        flavor="cachyos lto"
    elif [[ "$token" == *"-cachyos-eevdf-"* ]]; then
        flavor="cachyos eevdf"
    elif [[ "$token" == *"-cachyos-"* || "$label_token" == *" cachyos "* || "$label_token" == *"(cachyos)"* ]]; then
        flavor="cachyos"
    elif [[ "$token" == *"-xanmod-"* || "$label_token" == *" xanmod "* || "$label_token" == *"(xanmod)"* ]]; then
        flavor="xanmod"
    elif [[ "$token" == *"-lowlatency-"* || "$label_token" == *" lowlatency "* ]]; then
        flavor="lowlatency"
    elif [[ "$token" == *"-liquorix-"* || "$label_token" == *" liquorix "* ]]; then
        flavor="liquorix"
    elif [[ "$token" == *"-bore-"* || "$label_token" == *" bore "* ]]; then
        flavor="bore"
    elif [[ "$token" == *"-mainline-"* || "$label_token" == *" mainline "* ]]; then
        flavor="mainline"
    elif [[ "$token" == *"-ck-"* || "$label_token" == *" ck "* ]]; then
        flavor="ck"
    elif [[ "$token" == *"-pf-"* || "$label_token" == *" pf "* ]]; then
        flavor="pf"
    elif [[ "$token" == *"-clear-"* || "$label_token" == *" clear "* ]]; then
        flavor="clear"
    elif [[ "$token" == *"-cfs-"* || "$label_token" == *" cfs "* ]]; then
        flavor="cfs"
    elif [[ "$token" == *"-tuxedo-"* || "$label_token" == *" tuxedo "* ]]; then
        flavor="tuxedo"
    elif [[ "$token" == *"-rt-"* || "$token" == *"-realtime-"* || "$label_token" == *" real-time "* || "$label_token" == *" realtime "* || "$label_token" == *" linux rt "* ]]; then
        flavor="rt"
    else
        case "$base" in
            vmlinuz*|bzimage*|linux|linux.efi|linux-*.efi|*-linux.efi|*-linux-*.efi|kernel.efi|kernel-*.efi|image.efi|*.uki)
                flavor="default"
                ;;
            *)
                if [[ "$loader" == *"/efi/linux/"* ]]; then
                    flavor="default"
                elif [[ "$label_token" == *" linux "* || "$label_token" == *" arch "* || "$label_token" == *" ubuntu "* || "$label_token" == *" debian "* || "$label_token" == *" fedora "* || "$label_token" == *" opensuse "* || "$label_token" == *" gentoo "* || "$label_token" == *" nixos "* || "$label_token" == *" void "* || "$label_token" == *" alpine "* || "$label_token" == *" manjaro "* || "$label_token" == *" endeavour"* || "$label_token" == *" garuda "* || "$label_token" == *" steamos "* ]]; then
                    flavor="default"
                else
                    return 1
                fi
                ;;
        esac
    fi
    if (( is_fallback == 1 )); then
        if [[ "$flavor" == "default" ]]; then
            flavor="fallback"
        else
            flavor="$flavor fallback"
        fi
    fi
    printf '%s' "$flavor"
}

classify_linux_version() {
    local version="${1,,}"
    local label="${2,,}"
    local vtoken="-${version//_/-}-"
    local ltoken=" ${label//_/ } "
    if [[ "$vtoken" == *"-zen"* || "$ltoken" == *" zen "* || "$ltoken" == *"(zen)"* ]]; then
        printf 'zen'; return 0
    elif [[ "$vtoken" == *"-tkg"* || "$ltoken" == *" tkg "* || "$ltoken" == *"(tkg)"* ]]; then
        printf 'tkg'; return 0
    elif [[ "$vtoken" == *"-lts"* || "$ltoken" == *" lts "* || "$ltoken" == *"(lts)"* ]]; then
        printf 'lts'; return 0
    elif [[ "$vtoken" == *"-hardened"* || "$ltoken" == *" hardened "* || "$ltoken" == *"(hardened)"* ]]; then
        printf 'hardened'; return 0
    elif [[ "$vtoken" == *"-cachyos"* || "$ltoken" == *" cachyos "* || "$ltoken" == *"(cachyos)"* ]]; then
        printf 'cachyos'; return 0
    elif [[ "$vtoken" == *"-xanmod"* || "$ltoken" == *" xanmod "* || "$ltoken" == *"(xanmod)"* ]]; then
        printf 'xanmod'; return 0
    elif [[ "$vtoken" == *"-lowlatency"* || "$ltoken" == *" lowlatency "* ]]; then
        printf 'lowlatency'; return 0
    elif [[ "$vtoken" == *"-liquorix"* || "$ltoken" == *" liquorix "* ]]; then
        printf 'liquorix'; return 0
    elif [[ "$vtoken" == *"-bore"* || "$ltoken" == *" bore "* ]]; then
        printf 'bore'; return 0
    elif [[ "$vtoken" == *"-mainline"* || "$ltoken" == *" mainline "* ]]; then
        printf 'mainline'; return 0
    elif [[ "$vtoken" == *"-ck-"* || "$ltoken" == *" ck "* ]]; then
        printf 'ck'; return 0
    elif [[ "$vtoken" == *"-pf-"* || "$ltoken" == *" pf "* ]]; then
        printf 'pf'; return 0
    elif [[ "$vtoken" == *"-clear"* || "$ltoken" == *" clear "* ]]; then
        printf 'clear'; return 0
    elif [[ "$vtoken" == *"-cfs"* || "$ltoken" == *" cfs "* ]]; then
        printf 'cfs'; return 0
    elif [[ "$vtoken" == *"-tuxedo"* || "$ltoken" == *" tuxedo "* ]]; then
        printf 'tuxedo'; return 0
    elif [[ "$vtoken" == *"-rt-"* || "$vtoken" == *"-rt"* || "$vtoken" == *"realtime"* || "$ltoken" == *" real-time "* || "$ltoken" == *" realtime "* || "$ltoken" == *" linux rt "* ]]; then
        printf 'rt'; return 0
    fi
    return 1
}

classify_mac_name() {
    local label="${1,,}"
    case "$label" in
        *tahoe*) printf 'macos tahoe' ;;
        *sequoia*) printf 'macos sequoia' ;;
        *sonoma*) printf 'macos sonoma' ;;
        *ventura*) printf 'macos ventura' ;;
        *monterey*) printf 'macos monterey' ;;
        *'big sur'*) printf 'macos big sur' ;;
        *catalina*) printf 'macos catalina' ;;
        *mojave*) printf 'macos mojave' ;;
        *'high sierra'*) printf 'macos high sierra' ;;
        *) printf 'macos' ;;
    esac
}

map_windows_version() {
    local version="$1"
    local major minor build
    [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 1
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    build="${BASH_REMATCH[3]}"
    if [[ "$major" == "5" && "$minor" == "1" ]]; then
        printf 'windows xp'
    elif [[ "$major" == "6" && "$minor" == "0" ]]; then
        printf 'windows vista'
    elif [[ "$major" == "6" && "$minor" == "1" ]]; then
        printf 'windows 7'
    elif [[ "$major" == "6" && "$minor" == "2" ]]; then
        printf 'windows 8'
    elif [[ "$major" == "6" && "$minor" == "3" ]]; then
        printf 'windows 8.1'
    elif [[ "$major" == "10" && "$build" -ge 22000 ]]; then
        printf 'windows 11'
    elif [[ "$major" == "10" && "$build" -lt 22000 ]]; then
        printf 'windows 10'
    else
        return 1
    fi
}

decode_efi_options() {
    local raw="$1"
    local trimmed="${raw#"${raw%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [[ -n "$trimmed" ]] || return 0
    if [[ "${trimmed,,}" == 57494e444f575300* || "${trimmed,,}" == 570049004e0044004f0057005300* ]]; then
        return 0
    fi
    if [[ "$trimmed" =~ ^(([0-9a-fA-F]{2}00)+)([0-9a-fA-F]{2})?$ ]]; then
        local hex="${BASH_REMATCH[1],,}"
        local idx len=${#hex} byte_hex val decoded="" ch
        for ((idx = 0; idx < len; idx += 4)); do
            byte_hex="${hex:idx:2}"
            [[ "$byte_hex" == "00" ]] && continue
            val=$((16#$byte_hex))
            if (( val >= 32 && val <= 126 )); then
                printf -v ch "\\x$byte_hex"
                decoded+="$ch"
            elif (( val == 9 || val == 10 || val == 13 )); then
                decoded+=" "
            fi
        done
        decoded="${decoded#"${decoded%%[![:space:]]*}"}"
        decoded="${decoded%"${decoded##*[![:space:]]}"}"
        printf '%s' "$decoded"
        return 0
    fi
    if [[ "$trimmed" =~ ^[0-9a-fA-F]{16,}$ ]]; then
        return 0
    fi
    printf '%s' "$trimmed"
}

split_uefi_path_and_options() {
    local raw_tail="$1"
    local out_loader="" out_opts="" first_token="" trimmed_loader=""
    if [[ "$raw_tail" == *$'\t'* ]]; then
        out_loader="${raw_tail%%$'\t'*}"
        out_opts="${raw_tail#*$'\t'}"
    elif [[ "$raw_tail" =~ ^(.+\.[Ee][Ff][Ii])(.*)$ ]]; then
        out_loader="${BASH_REMATCH[1]}"
        out_opts="${BASH_REMATCH[2]:-}"
    elif [[ "$raw_tail" =~ (([2-7][0-9a-fA-F]00){3,}([0-9a-fA-F]{2}00)*([0-9a-fA-F]{2})*)$ ]]; then
        out_opts="${BASH_REMATCH[1]}"
        out_loader="${raw_tail%"$out_opts"}"
    elif [[ "$raw_tail" =~ (57494e444f575300[0-9a-fA-F]*)$ ]]; then
        out_opts="${BASH_REMATCH[1]}"
        out_loader="${raw_tail%"$out_opts"}"
    else
        if [[ "$raw_tail" =~ ^([^[:space:]]+)[[:space:]]*(.*)$ ]]; then
            first_token="${BASH_REMATCH[1]}"
            out_opts="${BASH_REMATCH[2]:-}"
        else
            first_token="$raw_tail"
            out_opts=""
        fi
        if [[ "$raw_tail" =~ ^(.+)[[:space:]]+([A-Za-z0-9_.-]+=.*|rw|ro|quiet|splash|--)(.*)$ ]]; then
            trimmed_loader="${BASH_REMATCH[1]}"
            if [[ "$trimmed_loader" != *"="* ]]; then
                out_loader="$trimmed_loader"
                out_opts="${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
            else
                out_loader="$first_token"
            fi
        elif [[ "$raw_tail" != *"="* ]]; then
            out_loader="${raw_tail%"${raw_tail##*[![:space:]]}"}"
            out_opts=""
        else
            out_loader="$first_token"
        fi
    fi
    out_loader="${out_loader//\\//}"
    while [[ "$out_loader" == *"//"* ]]; do
        out_loader="${out_loader//\/\//\/}"
    done
    out_opts="$(decode_efi_options "$out_opts")"
    printf '%s\t%s' "$out_loader" "$out_opts"
}

add_target() {
    local backend="$1"
    local id="$2"
    local active="$3"
    local label="$4"
    local loader="$5"
    local partuuid="$6"
    local options="$7"
    local family="$8"
    local flavor="$9"
    local name="${10}"
    local version="${11}"
    local i
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ "${TARGET_LOADERS[i],,}" == "${loader,,}" && "${TARGET_PARTUUIDS[i],,}" == "${partuuid,,}" ]]; then
            if [[ "${TARGET_BACKENDS[i]}" == "$backend" && "${TARGET_OPTIONS[i]}" == "$options" ]]; then
                if [[ "$active" == "1" && "${TARGET_ACTIVE[i]}" != "1" ]]; then
                    TARGET_IDS[i]="$id"
                    TARGET_ACTIVE[i]="$active"
                    TARGET_LABELS[i]="$label"
                    TARGET_OPTIONS[i]="$options"
                fi
                return 0
            elif [[ "${TARGET_BACKENDS[i]}" == "uefi" && "$backend" == "sdboot" ]]; then
                return 0
            fi
        fi
    done
    (( ${#TARGET_IDS[@]} < MAX_TARGETS )) || return 0
    TARGET_BACKENDS+=("$backend")
    TARGET_IDS+=("$id")
    TARGET_ACTIVE+=("$active")
    TARGET_LABELS+=("${label//$'\n'/ }")
    TARGET_LOADERS+=("$loader")
    TARGET_PARTUUIDS+=("$partuuid")
    TARGET_OPTIONS+=("$options")
    TARGET_FAMILIES+=("$family")
    TARGET_FLAVORS+=("$flavor")
    TARGET_NAMES+=("$name")
    TARGET_VERSIONS+=("$version")
}

get_efi_output() {
    local output=""
    if [[ -n "$EFI_BIN" ]]; then
        if (( EUID == 0 )); then
            output="$("$EFI_BIN" -v 2>/dev/null || true)"
        else
            output="$(sudo -n "$EFI_BIN" -v 2>/dev/null || "$EFI_BIN" -v 2>/dev/null || true)"
        fi
    fi
    printf '%s' "$output"
}

get_sdboot_current_entry() {
    local efivar="/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    if [[ -r "$efivar" ]]; then
        tail -c +5 "$efivar" 2>/dev/null | tr -d '\000' || true
    fi
}

parse_uefi_entries() {
    local line id active rest label loader partuuid options base flavor version name family raw_tail split_pair
    local file_pattern='File\(([^)]*)\)'
    local hd_pattern='HD\([^)]*\)/([\\/].*)$'
    EFI_OUTPUT="$(get_efi_output)"
    BOOT_CURRENT_ID="$(printf '%s\n' "$EFI_OUTPUT" | awk -F': *' '/^BootCurrent:/ {gsub(/[^0-9A-Fa-f]/, "", $2); print toupper($2); exit}')"
    while IFS= read -r line; do
        [[ "$line" =~ ^Boot([[:xdigit:]]{4})(\*)?[[:space:]]+(.*)$ ]] || continue
        id="${BASH_REMATCH[1]^^}"
        active="0"
        [[ -n "${BASH_REMATCH[2]:-}" ]] && active="1"
        rest="${BASH_REMATCH[3]}"
        loader=""
        partuuid=""
        options=""
        if [[ "$rest" =~ $file_pattern ]]; then
            loader="${BASH_REMATCH[1]//\\//}"
            options="$(printf '%s' "$rest" | sed -E 's/^.*File\([^)]*\)[[:space:]]*//')"
            options="$(decode_efi_options "$options")"
        elif [[ "$rest" =~ $hd_pattern ]]; then
            raw_tail="${BASH_REMATCH[1]}"
            split_pair="$(split_uefi_path_and_options "$raw_tail")"
            loader="${split_pair%%$'\t'*}"
            options="${split_pair#*$'\t'}"
        fi
        while [[ "$loader" == *"//"* ]]; do
            loader="${loader//\/\//\/}"
        done
        if [[ "$rest" =~ [Gg][Pp][Tt],([[:xdigit:]-]{36}) ]]; then
            partuuid="${BASH_REMATCH[1],,}"
        fi
        label="$(printf '%s' "$rest" | sed -E 's/[[:space:]]+(HD|PciRoot|VenHw|VenMedia|Acpi|Fv|MemoryMapped|URI|Usb|Ata|Scsi|NVMe|Sata|CDROM|Floppy|MAC|IPv4|IPv6)\(.*$//')"
        label="${label:-UEFI Entry}"
        [[ -n "$loader" ]] || continue
        base="${loader##*/}"
        base="${base,,}"
        if [[ "$base" == systemd-bootx64.efi || "$base" == systemd-bootaa64.efi || "$base" == systemd-bootia32.efi ]]; then
            if [[ "$active" == "1" || -z "$SDBOOT_MANAGER_ID" ]]; then
                SDBOOT_MANAGER_ID="$id"
                SDBOOT_MANAGER_ACTIVE="$active"
            fi
            continue
        fi
        case "$base" in
            shim*.efi|grub*.efi|refind*.efi|bootx64.efi|bootaa64.efi|bootia32.efi|fwupd*.efi|mmx64.efi|mmaa64.efi|mokmanager*.efi|shell*.efi|memtest*.efi)
                continue
                ;;
        esac
        family=""
        flavor=""
        name=""
        version=""
        if [[ "$base" == bootmgfw.efi || "$base" == bootmgr.efi ]]; then
            family="windows"
            version="$(get_windows_version "$partuuid" "$loader" 2>/dev/null || true)"
            name="$(map_windows_version "$version" 2>/dev/null || true)"
            if [[ -z "$name" ]]; then
                case "${label,,}" in
                    *"windows 11"*) name="windows 11" ;;
                    *"windows 10"*) name="windows 10" ;;
                    *"windows 8.1"*) name="windows 8.1" ;;
                    *"windows 8"*) name="windows 8" ;;
                    *"windows 7"*) name="windows 7" ;;
                    *) name="windows unknown" ;;
                esac
            fi
        elif [[ "$base" == boot.efi || "$base" == opencore.efi || "$base" == opencore*.efi || "$base" == clover*.efi || "${label,,}" == *macos* || "${label,,}" == *"mac os"* || "${label,,}" == *"os x"* || "${label,,}" == *opencore* || "${label,,}" == *clover* ]]; then
            family="macos"
            name="$(classify_mac_name "$label")"
        else
            flavor="$(classify_linux_loader "$loader" "$label" 2>/dev/null || true)"
            if [[ -n "$flavor" ]]; then
                family="linux"
                version="$(get_linux_version "$partuuid" "$loader" 2>/dev/null || true)"
                if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                    local detected_flavor
                    detected_flavor="$(classify_linux_version "$version" "$label" 2>/dev/null || true)"
                    if [[ -n "$detected_flavor" ]]; then
                        if [[ "$flavor" == "fallback" ]]; then
                            flavor="$detected_flavor fallback"
                        else
                            flavor="$detected_flavor"
                        fi
                    fi
                fi
                if [[ "$flavor" == "default" ]]; then
                    name="linux"
                else
                    name="linux $flavor"
                fi
            fi
        fi
        [[ -n "$family" ]] || continue
        add_target uefi "$id" "$active" "$label" "$loader" "$partuuid" "$options" "$family" "${flavor:-unknown}" "$name" "$version"
        if (( ${#TARGET_IDS[@]} >= MAX_TARGETS )); then
            break
        fi
    done <<< "$EFI_OUTPUT"
}

parse_bootctl_entries() {
    [[ -n "$BOOTCTL_BIN" && -n "$SDBOOT_MANAGER_ID" ]] || return 0
    local list_out line cur_id="" cur_title="" cur_linux="" cur_efi="" cur_opts=""
    list_out="$("$BOOTCTL_BIN" list 2>/dev/null || true)"
    [[ -n "$list_out" ]] || return 0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
            if [[ -n "$cur_id" && -n "${cur_linux:-$cur_efi}" ]]; then
                local loader="${cur_linux:-$cur_efi}" base flavor name version family detected_flavor
                base="${loader##*/}"
                base="${base,,}"
                family=""
                flavor="unknown"
                version=""
                if [[ "$cur_id" == "auto-windows" || "$base" == bootmgfw.efi ]]; then
                    family="windows"
                    version="$(get_windows_version "" "$loader" 2>/dev/null || true)"
                    name="$(map_windows_version "$version" 2>/dev/null || true)"
                    [[ -n "$name" ]] || name="windows unknown"
                elif [[ "$cur_id" == "auto-osx" || "$base" == boot.efi ]]; then
                    family="macos"
                    name="$(classify_mac_name "$cur_title")"
                else
                    flavor="$(classify_linux_loader "$loader" "$cur_title" 2>/dev/null || true)"
                    if [[ -n "$flavor" ]]; then
                        family="linux"
                        version="$(get_linux_version "" "$loader" 2>/dev/null || true)"
                        if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                            detected_flavor="$(classify_linux_version "$version" "$cur_title" 2>/dev/null || true)"
                            if [[ -n "$detected_flavor" ]]; then
                                [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                            fi
                        fi
                        [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
                    fi
                fi
                if [[ -n "$family" ]]; then
                    add_target sdboot "$cur_id" "$SDBOOT_MANAGER_ACTIVE" "${cur_title:-$cur_id}" "$loader" "" "$cur_opts" "$family" "$flavor" "$name" "$version"
                fi
            fi
            cur_id="${BASH_REMATCH[1]}"
            cur_title=""
            cur_linux=""
            cur_efi=""
            cur_opts=""
        elif [[ "$line" =~ ^[[:space:]]*title:[[:space:]]*(.+)$ ]]; then
            cur_title="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*linux:[[:space:]]*(.+)$ ]]; then
            cur_linux="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*efi:[[:space:]]*(.+)$ ]]; then
            cur_efi="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*options:[[:space:]]*(.+)$ ]]; then
            cur_opts="${BASH_REMATCH[1]}"
        fi
    done <<< "$list_out"
    if [[ -n "$cur_id" && -n "${cur_linux:-$cur_efi}" ]]; then
        local loader="${cur_linux:-$cur_efi}" base flavor name version family detected_flavor
        base="${loader##*/}"
        base="${base,,}"
        family=""
        flavor="unknown"
        version=""
        if [[ "$cur_id" == "auto-windows" || "$base" == bootmgfw.efi ]]; then
            family="windows"
            version="$(get_windows_version "" "$loader" 2>/dev/null || true)"
            name="$(map_windows_version "$version" 2>/dev/null || true)"
            [[ -n "$name" ]] || name="windows unknown"
        elif [[ "$cur_id" == "auto-osx" || "$base" == boot.efi ]]; then
            family="macos"
            name="$(classify_mac_name "$cur_title")"
        else
            flavor="$(classify_linux_loader "$loader" "$cur_title" 2>/dev/null || true)"
            if [[ -n "$flavor" ]]; then
                family="linux"
                version="$(get_linux_version "" "$loader" 2>/dev/null || true)"
                if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                    detected_flavor="$(classify_linux_version "$version" "$cur_title" 2>/dev/null || true)"
                    if [[ -n "$detected_flavor" ]]; then
                        [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                    fi
                fi
                [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
            fi
        fi
        if [[ -n "$family" ]]; then
            add_target sdboot "$cur_id" "$SDBOOT_MANAGER_ACTIVE" "${cur_title:-$cur_id}" "$loader" "" "$cur_opts" "$family" "$flavor" "$name" "$version"
        fi
    fi
}

parse_systemd_boot_entries() {
    local mountpoint directory file id title linux_image efi_image loader options initrd_line flavor name version source partuuid base family detected_flavor uki_dir uki_file win_boot
    local -a initrds=()
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        source=""
        if command -v findmnt >/dev/null 2>&1; then
            source="$(findmnt -rn -T "$mountpoint" -o SOURCE 2>/dev/null | head -n 1 || true)"
        fi
        source="${source%%\[*}"
        partuuid=""
        if [[ -n "$source" ]] && command -v blkid >/dev/null 2>&1; then
            partuuid="$(blkid -s PARTUUID -o value "$source" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
        fi
        directory="$mountpoint/loader/entries"
        if [[ -d "$directory" ]]; then
            for file in "$directory"/*.conf; do
                [[ -f "$file" ]] || continue
                id="${file##*/}"
                title="$(awk 'tolower($1)=="title" { $1=""; sub(/^[[:space:]]+/,""); print; exit }' "$file")"
                linux_image="$(awk 'tolower($1)=="linux" { print $2; exit }' "$file")"
                efi_image="$(awk 'tolower($1)=="efi" { print $2; exit }' "$file")"
                options="$(awk 'tolower($1)=="options" { $1=""; sub(/^[[:space:]]+/,""); out = (out ? out " " $0 : $0) } END { print out }' "$file")"
                mapfile -t initrds < <(awk 'tolower($1)=="initrd" { print $2 }' "$file")
                for initrd_line in "${initrds[@]:-}"; do
                    [[ -n "$initrd_line" ]] && options+=" initrd=$initrd_line"
                done
                loader="${linux_image:-$efi_image}"
                [[ -n "$loader" ]] || continue
                base="${loader##*/}"
                base="${base,,}"
                family=""
                flavor="unknown"
                version=""
                if [[ "$base" == bootmgfw.efi || "$base" == bootmgr.efi ]]; then
                    family="windows"
                    version="$(get_windows_version "$partuuid" "$loader" 2>/dev/null || true)"
                    name="$(map_windows_version "$version" 2>/dev/null || true)"
                    [[ -n "$name" ]] || name="windows unknown"
                elif [[ "$base" == boot.efi || "$base" == opencore.efi || "$base" == opencore*.efi || "$base" == clover*.efi || "${title,,}" == *macos* || "${title,,}" == *"mac os"* || "${title,,}" == *"os x"* || "${title,,}" == *opencore* || "${title,,}" == *clover* ]]; then
                    family="macos"
                    name="$(classify_mac_name "$title")"
                else
                    flavor="$(classify_linux_loader "$loader" "$title" 2>/dev/null || true)"
                    [[ -n "$flavor" ]] || continue
                    family="linux"
                    version="$(get_linux_version "$partuuid" "$loader" 2>/dev/null || true)"
                    if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                        detected_flavor="$(classify_linux_version "$version" "$title" 2>/dev/null || true)"
                        if [[ -n "$detected_flavor" ]]; then
                            if [[ "$flavor" == "fallback" ]]; then
                                flavor="$detected_flavor fallback"
                            else
                                flavor="$detected_flavor"
                            fi
                        fi
                    fi
                    if [[ "$flavor" == "default" ]]; then
                        name="linux"
                    else
                        name="linux $flavor"
                    fi
                fi
                add_target sdboot "$id" "$SDBOOT_MANAGER_ACTIVE" "${title:-$id}" "$loader" "$partuuid" "$options" "$family" "$flavor" "$name" "$version"
                (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
            done
        fi
        if [[ -n "$SDBOOT_MANAGER_ID" ]]; then
            uki_dir="$(find "$mountpoint" -maxdepth 2 -type d -ipath "$mountpoint/EFI/Linux" 2>/dev/null | head -n 1 || true)"
            if [[ -n "$uki_dir" && -d "$uki_dir" ]]; then
                for uki_file in "$uki_dir"/*.efi "$uki_dir"/*.uki; do
                    [[ -f "$uki_file" ]] || continue
                    id="${uki_file##*/}"
                    loader="/EFI/Linux/$id"
                    flavor="$(classify_linux_loader "$loader" "$id" 2>/dev/null || true)"
                    [[ -n "$flavor" ]] || continue
                    version="$(get_linux_version "$partuuid" "$loader" 2>/dev/null || true)"
                    if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                        detected_flavor="$(classify_linux_version "$version" "$id" 2>/dev/null || true)"
                        if [[ -n "$detected_flavor" ]]; then
                            [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                        fi
                    fi
                    [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
                    add_target sdboot "$id" "$SDBOOT_MANAGER_ACTIVE" "$id" "$loader" "$partuuid" "" "linux" "$flavor" "$name" "$version"
                    (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
                done
            fi
            win_boot="$(resolve_case_insensitive_file "$mountpoint" "EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null || true)"
            if [[ -n "$win_boot" ]]; then
                version="$(get_windows_version "$partuuid" "/EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null || true)"
                name="$(map_windows_version "$version" 2>/dev/null || true)"
                [[ -n "$name" ]] || name="windows unknown"
                add_target sdboot "auto-windows" "$SDBOOT_MANAGER_ACTIVE" "Windows Boot Manager" "/EFI/Microsoft/Boot/bootmgfw.efi" "$partuuid" "" "windows" "unknown" "$name" "$version"
                (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
            fi
        fi
    done < <(find_esp_mounts)
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_bootctl_entries
    fi
}

scan_targets() {
    TARGET_BACKENDS=()
    TARGET_IDS=()
    TARGET_ACTIVE=()
    TARGET_LABELS=()
    TARGET_LOADERS=()
    TARGET_PARTUUIDS=()
    TARGET_OPTIONS=()
    TARGET_FAMILIES=()
    TARGET_FLAVORS=()
    TARGET_NAMES=()
    TARGET_VERSIONS=()
    SDBOOT_MANAGER_ID=""
    SDBOOT_MANAGER_ACTIVE="0"
    BOOT_CURRENT_ID=""
    SDBOOT_CURRENT_ID="$(get_sdboot_current_entry)"
    parse_uefi_entries
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_systemd_boot_entries
    fi
}

show_help() {
    local i display badge entry_tag
    printf '%b\n' "${C_BOLD}${C_CYAN}INSTALLED OS AND KERNELS (${#TARGET_IDS[@]}/${MAX_TARGETS})${C_RESET}"
    if (( ${#TARGET_IDS[@]} == 0 )); then
        printf '  %b\n' "${C_DIM}No supported boot entries detected.${C_RESET}"
    else
        for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
            display="${TARGET_NAMES[i]}"
            [[ -n "${TARGET_VERSIONS[i]}" ]] && display+=" ${TARGET_VERSIONS[i]}"
            badge=""
            if [[ "${TARGET_BACKENDS[i]}" == "uefi" && -n "$BOOT_CURRENT_ID" && "${TARGET_IDS[i]}" == "$BOOT_CURRENT_ID" ]]; then
                badge=" ${C_YELLOW}[CURRENT]${C_RESET}"
            elif [[ "${TARGET_BACKENDS[i]}" == "sdboot" && -n "$SDBOOT_CURRENT_ID" && "${TARGET_IDS[i]}" == "$SDBOOT_CURRENT_ID" ]]; then
                badge=" ${C_YELLOW}[CURRENT]${C_RESET}"
            elif [[ "${TARGET_FAMILIES[i]}" == "linux" ]] && is_current_kernel_target "$i"; then
                badge=" ${C_YELLOW}[CURRENT]${C_RESET}"
            fi
            if [[ "${TARGET_BACKENDS[i]}" == "uefi" ]]; then
                entry_tag="Boot${TARGET_IDS[i]} | UEFI"
            else
                entry_tag="${TARGET_IDS[i]} | sd-boot"
            fi
            printf '  %b%b %b\n' "${C_GREEN}${display}${C_RESET}" "$badge" "${C_DIM}(${entry_tag})${C_RESET}"
        done
    fi
    printf '\n%b\n' "${C_BOLD}${C_CYAN}COMMANDS${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot <OS_NAME>${C_RESET}" "${C_DIM}Reboot once into the selected OS or kernel${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -f <OS_NAME>${C_RESET}" "${C_DIM}Close open apps immediately and force reboot${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -t <OS_NAME>${C_RESET}" "${C_DIM}Verify boot image, partition, and sudo permissions${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -l${C_RESET}          " "${C_DIM}Show detailed boot target table and paths${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -h${C_RESET}          " "${C_DIM}Show installed targets and available commands${C_RESET}"
}

show_list() {
    local i display status current_tag dev_info fstype_info
    printf '%b\n' "${C_BOLD}${C_CYAN}DETECTED BOOT TARGETS (${#TARGET_IDS[@]}/${MAX_TARGETS})${C_RESET}"
    if (( ${#TARGET_IDS[@]} == 0 )); then
        printf '  %b\n' "${C_DIM}No supported boot entries detected.${C_RESET}"
        return 0
    fi
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        display="${TARGET_NAMES[i]}"
        [[ -n "${TARGET_VERSIONS[i]}" ]] && display+=" ${TARGET_VERSIONS[i]}"
        if [[ "${TARGET_ACTIVE[i]}" == "1" ]]; then
            status="${C_GREEN}[ACTIVE]${C_RESET}"
        else
            status="${C_RED}[INACTIVE]${C_RESET}"
        fi
        current_tag=""
        if [[ "${TARGET_BACKENDS[i]}" == "uefi" && -n "$BOOT_CURRENT_ID" && "${TARGET_IDS[i]}" == "$BOOT_CURRENT_ID" ]]; then
            current_tag=" ${C_YELLOW}[CURRENT]${C_RESET}"
        elif [[ "${TARGET_BACKENDS[i]}" == "sdboot" && -n "$SDBOOT_CURRENT_ID" && "${TARGET_IDS[i]}" == "$SDBOOT_CURRENT_ID" ]]; then
            current_tag=" ${C_YELLOW}[CURRENT]${C_RESET}"
        elif [[ "${TARGET_FAMILIES[i]}" == "linux" ]] && is_current_kernel_target "$i"; then
            current_tag=" ${C_YELLOW}[CURRENT]${C_RESET}"
        fi
        printf '\n  %b %b  %b%b\n' "${C_DIM}[$((i + 1))]${C_RESET}" "${C_BOLD}${C_GREEN}${display}${C_RESET}" "$status" "$current_tag"
        if [[ "${TARGET_BACKENDS[i]}" == "uefi" ]]; then
            printf '      %bEntry   :%b Boot%s (UEFI NVRAM) — %s\n' "$C_DIM" "$C_RESET" "${TARGET_IDS[i]}" "${TARGET_LABELS[i]}"
        else
            printf '      %bEntry   :%b %s (systemd-boot) — %s\n' "$C_DIM" "$C_RESET" "${TARGET_IDS[i]}" "${TARGET_LABELS[i]}"
        fi
        printf '      %bLoader  :%b %s\n' "$C_DIM" "$C_RESET" "${TARGET_LOADERS[i]}"
        if [[ -n "${TARGET_PARTUUIDS[i]}" ]]; then
            dev_info="$(get_partuuid_device "${TARGET_PARTUUIDS[i]}" 2>/dev/null || true)"
            fstype_info=""
            [[ -n "$dev_info" ]] && fstype_info="$(get_partition_type "$dev_info" 2>/dev/null || true)"
            if [[ -n "$fstype_info" ]]; then
                printf '      %bDevice  :%b PARTUUID=%s (%s)\n' "$C_DIM" "$C_RESET" "${TARGET_PARTUUIDS[i]}" "$fstype_info"
            else
                printf '      %bDevice  :%b PARTUUID=%s\n' "$C_DIM" "$C_RESET" "${TARGET_PARTUUIDS[i]}"
            fi
        fi
        if [[ -n "${TARGET_OPTIONS[i]// /}" ]]; then
            printf '      %bOptions :%b %s\n' "$C_DIM" "$C_RESET" "${TARGET_OPTIONS[i]}"
        fi
    done
}

completion_targets() {
    local i candidate
    local -A counts=()
    for ((i=0; i<${#TARGET_NAMES[@]}; i++)); do
        counts["${TARGET_NAMES[i]}"]=$(( ${counts["${TARGET_NAMES[i]}"]:-0} + 1 ))
    done
    {
        for ((i=0; i<${#TARGET_NAMES[@]}; i++)); do
            candidate="${TARGET_NAMES[i]}"
            if (( ${counts["$candidate"]} > 1 )) && [[ -n "${TARGET_VERSIONS[i]}" ]]; then
                candidate+=" ${TARGET_VERSIONS[i]}"
            fi
            printf '%s\n' "$candidate"
        done
        for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
            if [[ "${TARGET_BACKENDS[i]}" == "uefi" ]]; then
                printf 'Boot%s\n' "${TARGET_IDS[i]}"
            else
                printf '%s\n' "${TARGET_IDS[i]}"
            fi
        done
    } | awk '!seen[$0]++'
}

match_target() {
    local query="$1"
    local normalized name_with_version loader_base loader_stem i
    local id_match=-1 id_matches=0 full_match=-1 full_matches=0 plain_match=-1 plain_matches=0 alias_match=-1 alias_matches=0
    local -a alias_candidates=()
    MATCH_AMBIGUOUS_LIST=""
    normalized="$(normalize_query "$query")"
    if [[ "$normalized" =~ ^[1-9][0-9]*$ ]] && (( normalized >= 1 && normalized <= ${#TARGET_IDS[@]} )); then
        MATCH_INDEX=$((normalized - 1))
        return 0
    fi
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ "${TARGET_IDS[i],,}" == "${normalized,,}" || "boot${TARGET_IDS[i],,}" == "${normalized,,}" ]]; then
            id_match="$i"
            ((id_matches+=1))
        fi
        name_with_version="${TARGET_NAMES[i]}"
        [[ -n "${TARGET_VERSIONS[i]}" ]] && name_with_version+=" ${TARGET_VERSIONS[i]}"
        if [[ -n "${TARGET_VERSIONS[i]}" && "$(normalize_query "$name_with_version")" == "$normalized" ]]; then
            full_match="$i"
            ((full_matches+=1))
        fi
        if [[ "$(normalize_query "${TARGET_NAMES[i]}")" == "$normalized" ]]; then
            plain_match="$i"
            ((plain_matches+=1))
        fi
        loader_base="${TARGET_LOADERS[i]##*/}"
        loader_stem="${loader_base%.efi}"
        loader_stem="${loader_stem%.EFI}"
        if [[ "${TARGET_FLAVORS[i]}" != "default" && "${TARGET_FLAVORS[i]}" != "unknown" && "${TARGET_FLAVORS[i]}" == "$normalized" ]]; then
            alias_match="$i"
            ((alias_matches+=1))
            alias_candidates+=("${TARGET_NAMES[i]} (${TARGET_IDS[i]})")
        elif [[ "${TARGET_FAMILIES[i]}" == "$normalized" ]]; then
            alias_match="$i"
            ((alias_matches+=1))
            alias_candidates+=("${TARGET_NAMES[i]} (${TARGET_IDS[i]})")
        elif [[ "${TARGET_LABELS[i],,}" == "${normalized,,}" || "${loader_base,,}" == "${normalized,,}" || "${loader_stem,,}" == "${normalized,,}" ]]; then
            alias_match="$i"
            ((alias_matches+=1))
            alias_candidates+=("${TARGET_NAMES[i]} (${TARGET_IDS[i]})")
        elif [[ "${TARGET_NAMES[i]}" == "windows unknown" && "$normalized" == windows* ]]; then
            alias_match="$i"
            ((alias_matches+=1))
            alias_candidates+=("${TARGET_NAMES[i]} (${TARGET_IDS[i]})")
        fi
    done
    if (( id_matches == 1 )); then
        MATCH_INDEX="$id_match"
        return 0
    elif (( id_matches > 1 )); then
        MATCH_AMBIGUOUS=1
        return 2
    fi
    if (( full_matches == 1 )); then
        MATCH_INDEX="$full_match"
        return 0
    elif (( full_matches > 1 )); then
        MATCH_AMBIGUOUS=1
        return 2
    fi
    if (( plain_matches == 1 )); then
        MATCH_INDEX="$plain_match"
        return 0
    elif (( plain_matches > 1 )); then
        MATCH_AMBIGUOUS=1
        return 2
    fi
    if (( alias_matches == 1 )); then
        MATCH_INDEX="$alias_match"
        return 0
    elif (( alias_matches > 1 )); then
        MATCH_AMBIGUOUS=1
        local candidate
        for candidate in "${alias_candidates[@]}"; do
            [[ -n "$MATCH_AMBIGUOUS_LIST" ]] && MATCH_AMBIGUOUS_LIST+=", "
            MATCH_AMBIGUOUS_LIST+="$candidate"
        done
        return 2
    fi
    return 1
}

check_sudo_capabilities() {
    local id="$1"
    local backend="$2"
    local partuuid="$3"
    local loader="$4"
    if (( EUID == 0 )); then
        return 0
    fi
    [[ -n "$EFI_BIN" ]] || return 1
    sudo -n "$EFI_BIN" -v >/dev/null 2>&1 || return 1
    if [[ "$backend" == "sdboot" ]]; then
        sudo -n -l "$EFI_BIN" --bootnext "$SDBOOT_MANAGER_ID" >/dev/null 2>&1 || sudo -n -l "$EFI_BIN" -n "$SDBOOT_MANAGER_ID" >/dev/null 2>&1 || return 1
    else
        sudo -n -l "$EFI_BIN" --bootnext "$id" >/dev/null 2>&1 || sudo -n -l "$EFI_BIN" -n "$id" >/dev/null 2>&1 || return 1
    fi
    if [[ -n "$SYSTEMCTL_BIN" ]]; then
        sudo -n -l "$SYSTEMCTL_BIN" reboot >/dev/null 2>&1 || return 1
        sudo -n -l "$SYSTEMCTL_BIN" reboot -f >/dev/null 2>&1 || return 1
    else
        local reboot_bin
        reboot_bin="$(resolve_tool_path reboot 2>/dev/null || true)"
        [[ -n "$reboot_bin" ]] || return 1
        sudo -n -l "$reboot_bin" >/dev/null 2>&1 || return 1
        sudo -n -l "$reboot_bin" -f >/dev/null 2>&1 || return 1
    fi
    if [[ "$backend" == "sdboot" ]]; then
        [[ -n "$BOOTCTL_BIN" ]] || return 1
        sudo -n -l "$BOOTCTL_BIN" set-oneshot "$id" >/dev/null 2>&1 || return 1
    fi
    if [[ -n "$partuuid" && -n "$loader" ]]; then
        if ! resolve_esp_file "$partuuid" "$loader" >/dev/null 2>&1; then
            [[ -x "$EFI_READ_HELPER" ]] || return 1
            sudo -n -l "$EFI_READ_HELPER" read "$partuuid" "$loader" >/dev/null 2>&1 || sudo -n -l "$EFI_READ_HELPER" exists "$partuuid" "$loader" >/dev/null 2>&1 || return 1
        fi
    fi
    return 0
}

verify_target() {
    local index="$1"
    local backend="${TARGET_BACKENDS[index]}"
    local id="${TARGET_IDS[index]}"
    local active="${TARGET_ACTIVE[index]}"
    local label="${TARGET_LABELS[index]}"
    local loader="${TARGET_LOADERS[index]}"
    local partuuid="${TARGET_PARTUUIDS[index]}"
    local options="${TARGET_OPTIONS[index]}"
    local family="${TARGET_FAMILIES[index]}"
    local fstype=""
    local device=""
    local initrd_path=""
    local initrd_value=""
    local -a initrds=() split_initrds=()
    if [[ ! -d /sys/firmware/efi ]]; then
        print_failed "The system is not running in UEFI mode."
        return 1
    fi
    if [[ "$active" != "1" ]]; then
        print_failed "Boot${id} (${label}) is inactive in UEFI NVRAM."
        return 1
    fi
    if [[ "$backend" == "uefi" ]]; then
        if [[ -z "$EFI_BIN" ]]; then
            print_failed "efibootmgr is not installed."
            return 1
        fi
        if (( EUID != 0 )) && ! sudo -n "$EFI_BIN" -v >/dev/null 2>&1; then
            print_failed "Passwordless sudo access to efibootmgr is not configured."
            return 1
        fi
    elif [[ "$backend" == "sdboot" ]]; then
        if [[ -z "$BOOTCTL_BIN" || -z "$SDBOOT_MANAGER_ID" || "$SDBOOT_MANAGER_ACTIVE" != "1" ]]; then
            print_failed "No active systemd-boot firmware entry is available."
            return 1
        fi
        if ! "$BOOTCTL_BIN" list 2>/dev/null | awk -v target="$id" '/^[[:space:]]*id:/ { sub(/^[^:]*:[[:space:]]*/, ""); if ($0 == target) found=1 } END { exit !found }'; then
            print_failed "The systemd-boot entry '${id}' is not currently listed by bootctl."
            return 1
        fi
    fi
    if [[ -z "$partuuid" ]]; then
        if [[ "$backend" == "uefi" ]]; then
            print_failed "Boot${id} does not contain a GPT PARTUUID."
            return 1
        fi
    else
        device="$(get_partuuid_device "$partuuid" 2>/dev/null || true)"
        if [[ -z "$device" ]]; then
            print_failed "Target partition PARTUUID=${partuuid} does not exist on this system."
            return 1
        fi
        fstype="$(get_partition_type "$device")"
    fi
    if [[ "$family" == "macos" ]]; then
        if [[ "$fstype" != "apfs" && "$fstype" != "hfsplus" && "$fstype" != "hfs" && "$fstype" != "vfat" && "$fstype" != "fat" && "$fstype" != "fat32" ]]; then
            print_failed "The macOS boot partition filesystem could not be verified as APFS, HFS+, or FAT."
            return 1
        fi
        if ! entry_file_exists "$partuuid" "$loader"; then
            if [[ "$fstype" == "apfs" || "$fstype" == "hfsplus" || "$fstype" == "hfs" ]]; then
                print_failed "The macOS EFI file '${loader}' could not be inspected. Mount the target volume read-only or provide filesystem support before testing it."
            else
                print_failed "The macOS EFI file '${loader}' was not found on ${partuuid}."
            fi
            return 1
        fi
    elif [[ "$backend" == "sdboot" ]]; then
        if [[ -n "$partuuid" ]]; then
            case "$fstype" in
                vfat|fat|fat32|ext4|ext3|ext2|btrfs|xfs) ;;
                *)
                    print_failed "The target boot partition is not recognized as a supported filesystem. Detected filesystem: ${fstype:-unknown}."
                    return 1
                    ;;
            esac
        fi
        if [[ -z "$loader" ]] || ! entry_file_exists "$partuuid" "$loader"; then
            print_failed "The boot image '${loader:-unknown}' is missing or inaccessible on PARTUUID=${partuuid:-ESP}."
            return 1
        fi
    else
        if [[ "$fstype" != "vfat" && "$fstype" != "fat" && "$fstype" != "fat32" ]]; then
            print_failed "The target EFI partition is not recognized as FAT. Detected filesystem: ${fstype:-unknown}."
            return 1
        fi
        if [[ -z "$loader" ]] || ! entry_file_exists "$partuuid" "$loader"; then
            print_failed "The EFI image '${loader:-unknown}' is missing or inaccessible on PARTUUID=${partuuid}."
            return 1
        fi
    fi
    while [[ "$options" =~ initrd=([^[:space:]]+) ]]; do
        initrd_value="${BASH_REMATCH[1]}"
        options="${options#*initrd=}"
        IFS=',' read -r -a split_initrds <<< "$initrd_value"
        for initrd_path in "${split_initrds[@]}"; do
            initrd_path="${initrd_path%\"}"
            initrd_path="${initrd_path#\"}"
            [[ -n "$initrd_path" ]] && initrds+=("$initrd_path")
        done
    done
    if (( ${#initrds[@]} > 0 )); then
        for initrd_path in "${initrds[@]}"; do
            if ! entry_file_exists "$partuuid" "$initrd_path"; then
                print_failed "The initramfs '${initrd_path}' is missing or inaccessible on PARTUUID=${partuuid:-ESP}."
                return 1
            fi
        done
    fi
    if ! check_sudo_capabilities "$id" "$backend" "$partuuid" "$loader"; then
        print_failed "Passwordless sudo permissions are incomplete for setting the next boot and rebooting."
        return 1
    fi
    local checks="UEFI, NVRAM, PARTUUID, boot image, and privilege checks"
    if (( ${#initrds[@]} > 0 )); then
        checks="UEFI, NVRAM, PARTUUID, boot image, initramfs, and privilege checks"
    fi
    print_success "'${label}' (${TARGET_NAMES[index]}${TARGET_VERSIONS[index]:+ ${TARGET_VERSIONS[index]}}) passed ${checks}."
    return 0
}

get_running_kernel_identity() {
    local cmdline=""
    cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    printf '%s\n%s' "$(uname -r 2>/dev/null || true)" "$cmdline"
}

is_current_kernel_target() {
    local index="$1"
    local running_version="$(uname -r 2>/dev/null || true)"
    local cmdline="$(cat /proc/cmdline 2>/dev/null || true)"
    local target_version="${TARGET_VERSIONS[index]}"
    local normalized_loader="${TARGET_LOADERS[index]//\\//}"
    local loader_base="${normalized_loader##*/}"
    local cmd_token=""
    if [[ -n "$target_version" ]]; then
        [[ "$running_version" == "$target_version" ]] && return 0
        return 1
    fi
    if [[ "$cmdline" =~ (BOOT_IMAGE|initrd)=([^[:space:]]+) ]]; then
        cmd_token="${BASH_REMATCH[2]##*/}"
        if [[ -n "$loader_base" && "${cmd_token,,}" == "${loader_base,,}" ]]; then
            return 0
        fi
    fi
    if [[ -z "$target_version" && "${TARGET_FLAVORS[index]}" != "default" && "${TARGET_FLAVORS[index]}" != "unknown" ]]; then
        if [[ "${running_version,,}" == *"${TARGET_FLAVORS[index],,}"* ]]; then
            return 0
        fi
    fi
    return 1
}

get_protected_processes() {
    local process="$$"
    local parent=""
    local -A seen=()
    while [[ "$process" =~ ^[0-9]+$ && "$process" -gt 1 && -z "${seen[$process]+x}" ]]; do
        seen[$process]=1
        printf '%s\n' "$process"
        parent="$(ps -o ppid= -p "$process" 2>/dev/null | tr -d ' ' || true)"
        process="$parent"
    done
}

kill_desktop_applications() {
    local unit pid process_name process_scope
    local -A protected=() protected_scopes=()
    while IFS= read -r pid; do
        if [[ "$pid" =~ ^[0-9]+$ ]]; then
            protected[$pid]=1
            process_scope="$(awk -F/ '{for(i=1;i<=NF;i++) if ($i ~ /\.scope$/) s=$i} END {print s}' "/proc/$pid/cgroup" 2>/dev/null || true)"
            [[ -n "$process_scope" ]] && protected_scopes[$process_scope]=1
        fi
    done < <(get_protected_processes)
    if command -v systemctl >/dev/null 2>&1 && systemctl --user list-units --type=scope --all --no-legend --plain >/dev/null 2>&1; then
        while IFS= read -r unit; do
            [[ "$unit" == app-*\.scope || "$unit" == flatpak-*\.scope ]] || continue
            [[ -n "${protected_scopes[$unit]+x}" ]] && continue
            systemctl --user kill --kill-who=all --signal=SIGKILL "$unit" >/dev/null 2>&1 || true
        done < <(systemctl --user list-units --type=scope --all --no-legend --plain 2>/dev/null | awk '{print $1}')
    fi
    local -a window_pids=()
    if command -v wmctrl >/dev/null 2>&1; then
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] && window_pids+=("$pid")
        done < <(wmctrl -lp 2>/dev/null | awk '$3 ~ /^[0-9]+$/ {print $3}')
    fi
    if command -v hyprctl >/dev/null 2>&1; then
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] && window_pids+=("$pid")
        done < <(hyprctl clients -j 2>/dev/null | grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
    fi
    if command -v swaymsg >/dev/null 2>&1; then
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[0-9]+$ ]] && window_pids+=("$pid")
        done < <(swaymsg -t get_tree 2>/dev/null | grep -oE '"pid"[[:space:]]*:[[:space:]]*[0-9]+' | awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}')
    fi
    if (( ${#window_pids[@]} > 0 )); then
        mapfile -t window_pids < <(printf '%s\n' "${window_pids[@]}" | sort -un)
    fi
    for pid in "${window_pids[@]:-}"; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        [[ -n "${protected[$pid]+x}" ]] && continue
        [[ "$pid" -eq 1 ]] && continue
        process_name="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
        case "${process_name,,}" in
            sddm|sddm-helper|sddm-greeter|gdm|gdm3|gdm-session-worker|gdm-wayland-session|lightdm|lightdm-gtk-greeter|lxdm|greetd|tuigreet|display-manager|systemd|systemd-logind|dbus-daemon|dbus-broker|polkitd|gnome-shell|mutter|plasmashell|kwin|kwin_wayland|kwin_x11|hyprland|sway|weston|cosmic-comp|xfwm4|openbox|labwc|river|wayfire|cage|cinnamon|mate-session|xfce4-session|lxqt-session|lxsession|xorg|xwayland|bash|zsh|fish|nu|sh)
                continue
                ;;
        esac
        kill -KILL "$pid" >/dev/null 2>&1 || true
    done
}

request_reboot() {
    local force="$1"
    if [[ -n "$SYSTEMCTL_BIN" ]]; then
        if (( EUID == 0 )); then
            if [[ "$force" == "1" ]]; then
                "$SYSTEMCTL_BIN" reboot -f
            else
                "$SYSTEMCTL_BIN" reboot
            fi
        else
            if [[ "$force" == "1" ]]; then
                sudo -n "$SYSTEMCTL_BIN" reboot -f
            else
                sudo -n "$SYSTEMCTL_BIN" reboot
            fi
        fi
    else
        local reboot_bin
        reboot_bin="$(resolve_tool_path reboot 2>/dev/null || true)"
        [[ -n "$reboot_bin" ]] || return 1
        if (( EUID == 0 )); then
            if [[ "$force" == "1" ]]; then "$reboot_bin" -f; else "$reboot_bin"; fi
        else
            if [[ "$force" == "1" ]]; then sudo -n "$reboot_bin" -f; else sudo -n "$reboot_bin"; fi
        fi
    fi
}

set_next_boot() {
    local index="$1"
    local backend="${TARGET_BACKENDS[index]}"
    local id="${TARGET_IDS[index]}"
    if [[ "$backend" == "uefi" ]]; then
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$id" || "$EFI_BIN" -n "$id"
        else
            sudo -n "$EFI_BIN" --bootnext "$id" || sudo -n "$EFI_BIN" -n "$id"
        fi
        return $?
    fi
    if (( EUID == 0 )); then
        "$BOOTCTL_BIN" set-oneshot "$id" || return 1
        "$EFI_BIN" --bootnext "$SDBOOT_MANAGER_ID" || "$EFI_BIN" -n "$SDBOOT_MANAGER_ID" || {
            "$BOOTCTL_BIN" set-oneshot "" >/dev/null 2>&1 || true
            return 1
        }
    else
        sudo -n "$BOOTCTL_BIN" set-oneshot "$id" || return 1
        sudo -n "$EFI_BIN" --bootnext "$SDBOOT_MANAGER_ID" || sudo -n "$EFI_BIN" -n "$SDBOOT_MANAGER_ID" || {
            sudo -n "$BOOTCTL_BIN" set-oneshot "" >/dev/null 2>&1 || true
            return 1
        }
    fi
}

parse_arguments() {
    HELP_MODE=0
    TEST_MODE=0
    LIST_MODE=0
    FORCE_MODE=0
    COMPLETE_MODE=0
    local -a positional=()
    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                HELP_MODE=1
                ;;
            -l|--list)
                LIST_MODE=1
                ;;
            -t|--test|--check)
                TEST_MODE=1
                ;;
            -f|--force)
                FORCE_MODE=1
                ;;
            --complete)
                COMPLETE_MODE=1
                ;;
            --)
                shift
                while (( $# > 0 )); do
                    positional+=("$1")
                    shift
                done
                break
                ;;
            *)
                positional+=("$1")
                ;;
        esac
        shift
    done
    POSITIONAL_ARGS=("${positional[@]}")
}

parse_arguments "$@"
scan_targets

if (( COMPLETE_MODE == 1 )); then
    completion_targets
    exit 0
fi

if (( HELP_MODE == 1 )); then
    show_help
    exit 0
fi

if (( LIST_MODE == 1 )); then
    show_list
    exit 0
fi

if (( TEST_MODE == 1 && FORCE_MODE == 1 )); then
    print_failed "Test mode and force mode cannot be used together."
    exit 2
fi

TARGET_QUERY="${POSITIONAL_ARGS[*]:-}"
if [[ -z "$TARGET_QUERY" ]]; then
    show_help
    exit 1
fi

MATCH_INDEX=-1
MATCH_AMBIGUOUS=0
MATCH_AMBIGUOUS_LIST=""
if ! match_target "$TARGET_QUERY"; then
    if (( MATCH_AMBIGUOUS == 1 )); then
        if [[ -n "$MATCH_AMBIGUOUS_LIST" ]]; then
            print_failed "More than one entry matches '${TARGET_QUERY}': ${MATCH_AMBIGUOUS_LIST}. Specify the full name, kernel version, or boot entry ID."
        else
            print_failed "More than one entry matches '${TARGET_QUERY}'. Specify the kernel version or boot entry ID."
        fi
    else
        AVAILABLE_LIST=""
        for ((_i=0; _i<${#TARGET_NAMES[@]}; _i++)); do
            [[ -n "$AVAILABLE_LIST" ]] && AVAILABLE_LIST+=", "
            AVAILABLE_LIST+="${TARGET_NAMES[_i]}"
        done
        if [[ -n "$AVAILABLE_LIST" ]]; then
            print_failed "No exact boot target was found for '${TARGET_QUERY}'. Available: ${AVAILABLE_LIST}."
        else
            print_failed "No exact boot target was found for '${TARGET_QUERY}'."
        fi
    fi
    exit 1
fi

if (( TEST_MODE == 1 )); then
    verify_target "$MATCH_INDEX"
    exit $?
fi

if [[ "${TARGET_FAMILIES[MATCH_INDEX]}" == "linux" ]] && is_current_kernel_target "$MATCH_INDEX"; then
    if [[ -z "$BOOT_CURRENT_ID" || "${TARGET_IDS[MATCH_INDEX]}" == "$BOOT_CURRENT_ID" ]]; then
        printf '%b\n' "${C_YELLOW}You are already running ${TARGET_NAMES[MATCH_INDEX]} (${TARGET_VERSIONS[MATCH_INDEX]:-$(uname -r)}).${C_RESET}"
        exit 0
    fi
fi

if ! verify_target "$MATCH_INDEX"; then
    exit 1
fi

DISPLAY_VERSION=""
[[ -n "${TARGET_VERSIONS[MATCH_INDEX]}" ]] && DISPLAY_VERSION=" (${TARGET_VERSIONS[MATCH_INDEX]})"
if (( FORCE_MODE == 1 )); then
    printf '%b' "${C_RED}Force boot${C_RESET} into ${C_BOLD}${C_CYAN}${TARGET_NAMES[MATCH_INDEX]}${DISPLAY_VERSION}${C_RESET} [${TARGET_IDS[MATCH_INDEX]}]? (${C_GREEN}y${C_RESET}/${C_RED}n${C_RESET}): "
else
    printf '%b' "Boot into ${C_BOLD}${C_CYAN}${TARGET_NAMES[MATCH_INDEX]}${DISPLAY_VERSION}${C_RESET} [${TARGET_IDS[MATCH_INDEX]}]? (${C_GREEN}y${C_RESET}/${C_RED}n${C_RESET}): "
fi
if ! read -r CONFIRM; then
    printf '%b\n' "${C_DIM}Boot cancelled.${C_RESET}"
    exit 0
fi
if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
    printf '%b\n' "${C_DIM}Boot cancelled.${C_RESET}"
    exit 0
fi

if ! set_next_boot "$MATCH_INDEX"; then
    print_failed "The firmware refused to set the next boot target. No reboot was requested."
    exit 1
fi

if (( FORCE_MODE == 1 )); then
    trap '' HUP INT TERM
    kill_desktop_applications
    if request_reboot 1; then
        exit 0
    fi
else
    if request_reboot 0; then
        exit 0
    fi
fi

if [[ "${TARGET_BACKENDS[MATCH_INDEX]}" == "uefi" ]]; then
    if (( EUID == 0 )); then
        "$EFI_BIN" --delete-bootnext >/dev/null 2>&1 || "$EFI_BIN" -N >/dev/null 2>&1 || true
    else
        sudo -n "$EFI_BIN" --delete-bootnext >/dev/null 2>&1 || sudo -n "$EFI_BIN" -N >/dev/null 2>&1 || true
    fi
else
    if (( EUID == 0 )); then
        "$BOOTCTL_BIN" set-oneshot "" >/dev/null 2>&1 || true
        "$EFI_BIN" --delete-bootnext >/dev/null 2>&1 || "$EFI_BIN" -N >/dev/null 2>&1 || true
    else
        sudo -n "$BOOTCTL_BIN" set-oneshot "" >/dev/null 2>&1 || true
        sudo -n "$EFI_BIN" --delete-bootnext >/dev/null 2>&1 || sudo -n "$EFI_BIN" -N >/dev/null 2>&1 || true
    fi
fi
print_failed "The next boot target was set, but the reboot request failed. The pending boot selection was cleared when possible."
exit 1
