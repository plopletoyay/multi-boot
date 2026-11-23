#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"
export MTOOLS_SKIP_CHECK=1

BOOT_SCRIPT_VERSION="2.2.0"
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_RED=$'\033[1;31m'
C_GREEN=$'\033[1;32m'
C_YELLOW=$'\033[1;33m'
C_BLUE=$'\033[1;34m'
C_CYAN=$'\033[1;36m'

MAX_TARGETS="${BOOT_MAX_TARGETS:-64}"
EFI_READ_HELPER=/usr/local/libexec/multiboot-efi-read

resolve_tool_path() {
    local name="$1"
    local found=""
    found="$(command -v "$name" 2>/dev/null || true)"
    if [[ -n "$found" && -x "$found" ]]; then
        printf '%s' "$found"
        return 0
    fi
    for found in "/usr/bin/$name" "/usr/sbin/$name" "/bin/$name" "/sbin/$name" "/usr/local/bin/$name" "/usr/local/sbin/$name" "/run/current-system/sw/bin/$name"; do
        if [[ -x "$found" ]]; then
            printf '%s' "$found"
            return 0
        fi
    done
    return 1
}

EFI_BIN="$(resolve_tool_path efibootmgr 2>/dev/null || true)"
BOOTCTL_BIN="$(resolve_tool_path bootctl 2>/dev/null || true)"
GRUB_REBOOT_BIN="$(resolve_tool_path grub-reboot 2>/dev/null || resolve_tool_path grub2-reboot 2>/dev/null || true)"
PYTHON_BIN="$(resolve_tool_path python3 2>/dev/null || true)"
SYSTEMCTL_BIN="$(resolve_tool_path systemctl 2>/dev/null || true)"
NTFSCAT_BIN="$(resolve_tool_path ntfscat 2>/dev/null || true)"
DEBUGFS_BIN="$(resolve_tool_path debugfs 2>/dev/null || true)"
[[ -d /run/systemd/system ]] || SYSTEMCTL_BIN=""

TARGET_BACKENDS=()
TARGET_IDS=()
TARGET_ACTIVE=()
TARGET_DEFAULT=()
TARGET_LABELS=()
TARGET_LOADERS=()
TARGET_PARTUUIDS=()
TARGET_OPTIONS=()
TARGET_FAMILIES=()
TARGET_FLAVORS=()
TARGET_NAMES=()
TARGET_VERSIONS=()
TARGET_DISTROS=()
TARGET_EXTRA=()

SDBOOT_MANAGER_ID=""
SDBOOT_MANAGER_ACTIVE="0"
GRUB_MANAGER_ID=""
GRUB_MANAGER_ACTIVE="0"
GRUB_MANAGER_PARTUUID=""
GRUB_MANAGER_LOADER=""
REFIND_MANAGER_ID=""
REFIND_MANAGER_ACTIVE="0"
REFIND_MANAGER_PARTUUID=""
REFIND_MANAGER_LOADER=""
LIMINE_MANAGER_ID=""
LIMINE_MANAGER_ACTIVE="0"
BOOT_CURRENT_ID=""
BOOT_NEXT_ID=""
BOOT_ORDER_STR=""
SDBOOT_CURRENT_ID=""
EFI_OUTPUT=""

declare -A ROOT_OS_CACHE=()
declare -A WINDOWS_OS_CACHE=()
declare -A UKI_META_CACHE=()
declare -A TEMP_RO_MOUNT_CACHE=()
declare -a TEMP_CLEANUP_DIRS=()
declare -a TEMP_CLEANUP_MOUNTS=()

cleanup_boot_temp() {
    local m d
    for m in "${TEMP_CLEANUP_MOUNTS[@]:-}"; do
        [[ -n "$m" ]] || continue
        if (( EUID == 0 )); then
            umount "$m" 2>/dev/null || true
        else
            sudo -n umount "$m" 2>/dev/null || true
        fi
    done
    for d in "${TEMP_CLEANUP_DIRS[@]:-}"; do
        [[ -n "$d" && -d "$d" ]] && rm -rf -- "$d" 2>/dev/null || true
    done
}

trap cleanup_boot_temp EXIT

print_success() {
    printf '%s\n' "${C_GREEN}Success:${C_RESET} $*"
}

print_failed() {
    printf '%s\n' "${C_RED}Failed:${C_RESET} $*" >&2
}

print_info() {
    printf '%s\n' "${C_CYAN}Info:${C_RESET} $*"
}

print_warn() {
    printf '%s\n' "${C_YELLOW}Warning:${C_RESET} $*"
}

kv_get() {
    local blob="$1"
    local key="$2"
    local line
    while IFS= read -r line; do
        if [[ "$line" == "${key}="* ]]; then
            printf '%s' "${line#*=}"
            return 0
        fi
    done <<< "$blob"
    return 1
}

normalize_efi_relpath() {
    local rel="${1//\\//}"
    rel="${rel#"${rel%%[![:space:]]*}"}"
    rel="${rel%"${rel##*[![:space:]]}"}"
    [[ -n "$rel" ]] || return 1
    while [[ "$rel" == *"//"* ]]; do
        rel="${rel//\/\//\/}"
    done
    [[ "$rel" == /* ]] || rel="/$rel"
    printf '%s' "$rel"
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
        if [[ -z "$dev" && $EUID -ne 0 ]]; then
            dev="$(sudo -n blkid -t "PARTUUID=$uuid" -o device 2>/dev/null | head -n 1 || true)"
            [[ -z "$dev" ]] && dev="$(sudo -n blkid -t "PARTUUID=${uuid^^}" -o device 2>/dev/null | head -n 1 || true)"
        fi
        if [[ -n "$dev" && -b "$dev" ]]; then
            printf '%s' "$dev"
            return 0
        fi
    fi
    return 1
}

resolve_root_spec_device() {
    local spec="$1"
    local dev="" val=""
    spec="${spec%\"}"
    spec="${spec#\"}"
    [[ -n "$spec" ]] || return 1
    case "$spec" in
        UUID=*)
            val="${spec#UUID=}"
            [[ -e "/dev/disk/by-uuid/$val" ]] && { printf '%s' "/dev/disk/by-uuid/$val"; return 0; }
            if command -v blkid >/dev/null 2>&1; then
                dev="$(blkid -t "UUID=$val" -o device 2>/dev/null | head -n 1 || true)"
                [[ -b "$dev" ]] && { printf '%s' "$dev"; return 0; }
            fi
            ;;
        PARTUUID=*)
            val="${spec#PARTUUID=}"
            get_partuuid_device "$val" && return 0
            ;;
        LABEL=*)
            val="${spec#LABEL=}"
            [[ -e "/dev/disk/by-label/$val" ]] && { printf '%s' "/dev/disk/by-label/$val"; return 0; }
            if command -v blkid >/dev/null 2>&1; then
                dev="$(blkid -t "LABEL=$val" -o device 2>/dev/null | head -n 1 || true)"
                [[ -b "$dev" ]] && { printf '%s' "$dev"; return 0; }
            fi
            ;;
        PARTLABEL=*)
            val="${spec#PARTLABEL=}"
            [[ -e "/dev/disk/by-partlabel/$val" ]] && { printf '%s' "/dev/disk/by-partlabel/$val"; return 0; }
            ;;
        /dev/*)
            [[ -b "$spec" ]] && { printf '%s' "$spec"; return 0; }
            ;;
    esac
    return 1
}

get_partition_type() {
    local device="$1"
    local type=""
    type="$(lsblk -dnro FSTYPE "$device" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$type" ]] && command -v blkid >/dev/null 2>&1; then
        type="$(blkid -o value -s TYPE "$device" 2>/dev/null | head -n 1 || true)"
        if [[ -z "$type" && $EUID -ne 0 ]]; then
            type="$(sudo -n blkid -o value -s TYPE "$device" 2>/dev/null | head -n 1 || true)"
        fi
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

get_partition_label() {
    local device="$1"
    local lbl=""
    lbl="$(lsblk -dnro LABEL "$device" 2>/dev/null | head -n 1 || true)"
    [[ -z "$lbl" ]] && lbl="$(lsblk -dnro PARTLABEL "$device" 2>/dev/null | head -n 1 || true)"
    if [[ -z "$lbl" ]] && command -v blkid >/dev/null 2>&1; then
        lbl="$(blkid -o value -s LABEL "$device" 2>/dev/null | head -n 1 || true)"
        [[ -z "$lbl" ]] && lbl="$(blkid -o value -s PARTLABEL "$device" 2>/dev/null | head -n 1 || true)"
    fi
    printf '%s' "$lbl"
}

find_esp_mounts() {
    local mountpoint fstype canon
    local -A seen=()
    for mountpoint in /efi /boot/efi /boot; do
        if [[ -d "$mountpoint" ]]; then
            canon="$(readlink -f "$mountpoint" 2>/dev/null || printf '%s' "$mountpoint")"
            if [[ -z "${seen[$canon]+x}" ]]; then
                seen[$canon]=1
                printf '%s\n' "$mountpoint"
            fi
        fi
    done
    if command -v findmnt >/dev/null 2>&1; then
        while IFS= read -r mountpoint; do
            [[ -n "$mountpoint" && -d "$mountpoint" ]] || continue
            canon="$(readlink -f "$mountpoint" 2>/dev/null || printf '%s' "$mountpoint")"
            if [[ -z "${seen[$canon]+x}" ]]; then
                seen[$canon]=1
                printf '%s\n' "$mountpoint"
            fi
        done < <(findmnt -rn -t vfat,fat,msdos -o TARGET 2>/dev/null || true)
    elif [[ -r /proc/mounts ]]; then
        while read -r _ mountpoint fstype _; do
            case "${fstype,,}" in
                vfat|fat|msdos)
                    if [[ -d "$mountpoint" ]]; then
                        canon="$(readlink -f "$mountpoint" 2>/dev/null || printf '%s' "$mountpoint")"
                        if [[ -z "${seen[$canon]+x}" ]]; then
                            seen[$canon]=1
                            printf '%s\n' "$mountpoint"
                        fi
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
    if [[ -n "${TEMP_RO_MOUNT_CACHE[$real_device]+x}" && -d "${TEMP_RO_MOUNT_CACHE[$real_device]}" ]]; then
        printf '%s' "${TEMP_RO_MOUNT_CACHE[$real_device]}"
        return 0
    fi
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

mount_readonly_temp() {
    local device="$1"
    local fstype="${2:-}"
    local real_device
    real_device="$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")"
    if [[ -n "${TEMP_RO_MOUNT_CACHE[$real_device]+x}" ]]; then
        [[ -n "${TEMP_RO_MOUNT_CACHE[$real_device]}" ]] || return 1
        printf '%s' "${TEMP_RO_MOUNT_CACHE[$real_device]}"
        return 0
    fi
    local tmp_mnt
    tmp_mnt="$(mktemp -d)"
    TEMP_CLEANUP_DIRS+=("$tmp_mnt")
    local mounted=0
    if (( EUID == 0 )); then
        if [[ "$fstype" == "ntfs" ]]; then
            mount -t ntfs3 -o ro,norecover "$real_device" "$tmp_mnt" 2>/dev/null && mounted=1 || true
            (( mounted == 0 )) && mount -t ntfs-3g -o ro "$real_device" "$tmp_mnt" 2>/dev/null && mounted=1 || true
        fi
        (( mounted == 0 )) && mount -o ro "$real_device" "$tmp_mnt" 2>/dev/null && mounted=1 || true
    else
        if [[ "$fstype" == "ntfs" ]]; then
            sudo -n mount -t ntfs3 -o ro,norecover "$real_device" "$tmp_mnt" 2>/dev/null && mounted=1 || true
            (( mounted == 0 )) && sudo -n mount -t ntfs-3g -o ro "$real_device" "$tmp_mnt" 2>/dev/null && mounted=1 || true
        fi
        (( mounted == 0 )) && sudo -n mount -o ro "$real_device" "$tmp_mnt" 2>/dev/null && mounted=1 || true
    fi
    if (( mounted == 1 )); then
        TEMP_CLEANUP_MOUNTS+=("$tmp_mnt")
        TEMP_RO_MOUNT_CACHE["$real_device"]="$tmp_mnt"
        printf '%s' "$tmp_mnt"
        return 0
    fi
    TEMP_RO_MOUNT_CACHE["$real_device"]=""
    return 1
}

resolve_case_insensitive_file() {
    local root="$1"
    local relative="${2//\\//}"
    relative="${relative#/}"
    [[ -n "$relative" && -d "$root" ]] || return 1
    local current="$root"
    local component entry base matched
    local -a components=()
    local prev_nullglob prev_dotglob
    prev_nullglob="$(shopt -p nullglob || true)"
    prev_dotglob="$(shopt -p dotglob || true)"
    shopt -s nullglob
    shopt -u dotglob
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        [[ -n "$component" ]] || continue
        matched=""
        if [[ -e "$current/$component" ]]; then
            matched="$current/$component"
        else
            for entry in "$current"/*; do
                base="${entry##*/}"
                if [[ "${base,,}" == "${component,,}" ]]; then
                    matched="$entry"
                    break
                fi
            done
        fi
        if [[ -z "$matched" ]]; then
            eval "$prev_nullglob"
            eval "$prev_dotglob"
            return 1
        fi
        current="$matched"
    done
    eval "$prev_nullglob"
    eval "$prev_dotglob"
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
            if [[ -n "$resolved" && -r "$resolved" ]]; then
                printf '%s' "$resolved"
                return 0
            fi
        fi
        return 1
    fi
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        resolved="$(resolve_case_insensitive_file "$mountpoint" "$relative" 2>/dev/null || true)"
        if [[ -n "$resolved" && -r "$resolved" ]]; then
            printf '%s' "$resolved"
            return 0
        fi
    done < <(find_esp_mounts)
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
    local relative
    relative="$(normalize_efi_relpath "$2" 2>/dev/null || true)"
    [[ -n "$relative" ]] || return 1
    if resolve_esp_file "$partuuid" "$relative" >/dev/null 2>&1; then
        return 0
    fi
    [[ -n "$partuuid" ]] || return 1
    if run_efi_reader exists "$partuuid" "$relative" >/dev/null 2>&1; then
        return 0
    fi
    local probe_bytes=""
    probe_bytes="$(run_efi_reader read "$partuuid" "$relative" </dev/null 2>/dev/null | head -c 1 | wc -c | tr -d '[:space:]' || true)"
    [[ "$probe_bytes" == "1" ]]
}

copy_entry_file() {
    local partuuid="$1"
    local relative
    relative="$(normalize_efi_relpath "$2" 2>/dev/null || true)"
    local destination="$3"
    local resolved
    [[ -n "$relative" ]] || return 1
    resolved="$(resolve_esp_file "$partuuid" "$relative" 2>/dev/null || true)"
    if [[ -n "$resolved" && -r "$resolved" ]]; then
        cp -- "$resolved" "$destination" 2>/dev/null && [[ -s "$destination" ]] && return 0
    fi
    [[ -n "$partuuid" ]] || return 1
    run_efi_reader read "$partuuid" "$relative" > "$destination" 2>/dev/null && [[ -s "$destination" ]]
}

extract_pe_details() {
    local file="$1"
    [[ -s "$file" ]] || return 1
    if [[ -n "$PYTHON_BIN" ]]; then
        "$PYTHON_BIN" - "$file" << 'PYEOF' 2>/dev/null && return 0
import struct, sys, re

path = sys.argv[1]
with open(path, "rb") as f:
    data = f.read()

if len(data) < 64 or data[:2] != b"MZ":
    sys.exit(1)

pe_off = struct.unpack_from("<I", data, 0x3C)[0]
if pe_off + 24 > len(data) or data[pe_off:pe_off+4] != b"PE\x00\x00":
    sys.exit(1)

num_sec = struct.unpack_from("<H", data, pe_off + 6)[0]
opt_size = struct.unpack_from("<H", data, pe_off + 20)[0]
sec_off = pe_off + 24 + opt_size

rsrc_blob = b""
osrel_blob = b""
cmdline_blob = b""
uname_blob = b""

for i in range(num_sec):
    off = sec_off + i * 40
    if off + 40 > len(data):
        break
    name = data[off:off+8].rstrip(b"\x00").decode("latin1", errors="ignore")
    raw_size, raw_ptr = struct.unpack_from("<II", data, off + 16)
    if raw_ptr > 0 and raw_size > 0 and raw_ptr + raw_size <= len(data):
        chunk = data[raw_ptr:raw_ptr+raw_size]
        if name == ".rsrc":
            rsrc_blob = chunk
        elif name == ".osrel":
            osrel_blob = chunk
        elif name == ".cmdline":
            cmdline_blob = chunk
        elif name == ".uname":
            uname_blob = chunk

fixed_ver = ""
str_kv = {}

def read_u16z(buf, pos, limit):
    end = pos
    while end + 1 < limit and buf[end:end+2] != b"\x00\x00":
        end += 2
    txt = buf[pos:end].decode("utf-16le", errors="ignore")
    nxt = end + 2 if end + 2 <= limit else limit
    nxt = (nxt + 3) & ~3
    return txt, nxt

def parse_version_strings(buf, start, end):
    pos = start
    while pos + 6 <= end:
        wlen, wvlen, wtype = struct.unpack_from("<HHH", buf, pos)
        if wlen < 6 or pos + wlen > end:
            break
        node_end = pos + wlen
        key, val_pos = read_u16z(buf, pos + 6, node_end)
        if wtype == 1 and wvlen > 0 and val_pos < node_end:
            max_bytes = min(wvlen * 2, node_end - val_pos)
            val = buf[val_pos:val_pos+max_bytes].decode("utf-16le", errors="ignore").rstrip("\x00").strip()
            if key and val:
                str_kv[key] = val
        elif key in ("StringFileInfo", "StringTable") or (len(key) == 8 and all(c in "0123456789abcdefABCDEF" for c in key)):
            parse_version_strings(buf, val_pos, node_end)
        pos = (node_end + 3) & ~3

search_space = rsrc_blob if rsrc_blob else data
sig_utf16 = "VS_VERSION_INFO".encode("utf-16le")
idx = search_space.find(sig_utf16)
if idx != -1 and idx >= 6:
    vs_start = idx - 6
    vs_len = struct.unpack_from("<H", search_space, vs_start)[0]
    vs_end = min(len(search_space), vs_start + vs_len) if vs_len >= 40 else len(search_space)
    magic_pos = search_space.find(b"\xbd\x04\xef\xfe", idx, idx + 128)
    if magic_pos != -1 and magic_pos + 52 <= len(search_space):
        _, _, f_ms, f_ls, p_ms, p_ls = struct.unpack_from("<IIIIII", search_space, magic_pos)
        pmaj, pmin = (p_ms >> 16) & 0xFFFF, p_ms & 0xFFFF
        pbld, prev = (p_ls >> 16) & 0xFFFF, p_ls & 0xFFFF
        if pmaj > 0:
            fixed_ver = f"{pmaj}.{pmin}.{pbld}.{prev}"
        else:
            fmaj, fmin = (f_ms >> 16) & 0xFFFF, f_ms & 0xFFFF
            fbld, frev = (f_ls >> 16) & 0xFFFF, f_ls & 0xFFFF
            if fmaj > 0:
                fixed_ver = f"{fmaj}.{fmin}.{fbld}.{frev}"
        children_pos = (magic_pos + 52 + 3) & ~3
        parse_version_strings(search_space, children_pos, vs_end)

prod_ver = str_kv.get("ProductVersion", "")
file_ver = str_kv.get("FileVersion", "")
prod_name = str_kv.get("ProductName", "")
file_desc = str_kv.get("FileDescription", "")

os_id = ""
os_pretty = ""
os_ver_id = ""
if osrel_blob:
    os_txt = osrel_blob.decode("utf-8", errors="ignore")
    for line in os_txt.splitlines():
        line = line.strip()
        if line.startswith("ID="):
            os_id = line[3:].strip().strip('"').strip("'").lower()
        elif line.startswith("PRETTY_NAME="):
            os_pretty = line[12:].strip().strip('"').strip("'")
        elif line.startswith("VERSION_ID="):
            os_ver_id = line[11:].strip().strip('"').strip("'")

cmd_txt = ""
if cmdline_blob:
    cmd_txt = cmdline_blob.rstrip(b"\x00").decode("utf-8", errors="ignore").replace("\n", " ").strip()

uname_txt = ""
if uname_blob:
    uname_txt = uname_blob.rstrip(b"\x00").decode("utf-8", errors="ignore").strip()

loader_sig = ""
low_data = data[:min(len(data), 1048576)].lower()
if b"systemd-boot" in low_data:
    loader_sig = "systemd-boot"
elif b"grub" in low_data and (b"grub_prefix" in low_data or b"gnu grub" in low_data or b"grub.cfg" in low_data):
    loader_sig = "grub"
elif b"refind" in low_data:
    loader_sig = "refind"
elif b"limine" in low_data:
    loader_sig = "limine"
elif b"opencore" in low_data:
    loader_sig = "opencore"
elif b"clover" in low_data:
    loader_sig = "clover"

best_ver = fixed_ver
if not best_ver:
    for cand in (prod_ver, file_ver):
        m = re.search(r"(\d+\.\d+\.\d+(?:\.\d+)?)", cand)
        if m:
            best_ver = m.group(1)
            break

print(f"VERSION={best_ver}")
print(f"PRODUCT_NAME={prod_name}")
print(f"FILE_DESC={file_desc}")
print(f"OS_ID={os_id}")
print(f"OS_PRETTY={os_pretty}")
print(f"OS_VER_ID={os_ver_id}")
print(f"CMDLINE={cmd_txt}")
print(f"UNAME={uname_txt}")
print(f"LOADER_SIG={loader_sig}")
PYEOF
    fi
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
    printf 'VERSION=%s\nPRODUCT_NAME=\nFILE_DESC=\nOS_ID=\nOS_PRETTY=\nOS_VER_ID=\nCMDLINE=\nUNAME=\nLOADER_SIG=\n' "$result"
}

get_uki_metadata() {
    local partuuid="$1"
    local loader="$2"
    local norm_loader
    norm_loader="$(normalize_efi_relpath "$loader" 2>/dev/null || printf '%s' "$loader")"
    local cache_key="${partuuid,,}|${norm_loader,,}"
    if [[ -n "${UKI_META_CACHE[$cache_key]+x}" ]]; then
        [[ -n "${UKI_META_CACHE[$cache_key]}" ]] || return 1
        printf '%s' "${UKI_META_CACHE[$cache_key]}"
        return 0
    fi
    local resolved temporary details=""
    resolved="$(resolve_esp_file "$partuuid" "$norm_loader" 2>/dev/null || true)"
    if [[ -n "$resolved" && -r "$resolved" ]]; then
        details="$(extract_pe_details "$resolved" 2>/dev/null || true)"
    elif [[ -n "$partuuid" ]]; then
        temporary="$(mktemp)"
        if copy_entry_file "$partuuid" "$norm_loader" "$temporary" 2>/dev/null; then
            details="$(extract_pe_details "$temporary" 2>/dev/null || true)"
        fi
        rm -f -- "$temporary"
    fi
    UKI_META_CACHE["$cache_key"]="$details"
    [[ -n "$details" ]] || return 1
    printf '%s' "$details"
}

extract_product_version() {
    local file="$1"
    local details
    details="$(extract_pe_details "$file" 2>/dev/null || true)"
    kv_get "$details" "VERSION" || true
}

identify_efi_manager_type() {
    local partuuid="$1"
    local loader="$2"
    local details
    details="$(get_uki_metadata "$partuuid" "$loader" 2>/dev/null || true)"
    kv_get "$details" "LOADER_SIG" || true
}

get_kernel_image_version() {
    local file="$1"
    local pre_uname="${2:-}"
    local offset version size dos_magic pe_offset pe_sig num_sec opt_size sec_table idx sec_off sec_name raw_size raw_ptr inner_magic inner_off uki_uname
    local -a b=()
    [[ -s "$file" ]] || return 1
    if [[ "$pre_uname" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf '%s' "$pre_uname"
        return 0
    fi
    size="$(wc -c < "$file" | tr -d '[:space:]')"
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge 1024 ]] || return 1
    dos_magic="$(od -An -tx1 -N2 "$file" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$dos_magic" == "4d5a" ]]; then
        uki_uname="$(extract_pe_details "$file" 2>/dev/null | awk '{ idx = index($0, "="); if (idx > 0 && substr($0, 1, idx - 1) == "UNAME") { print substr($0, idx + 1); exit } }' || true)"
        if [[ "$uki_uname" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            printf '%s' "$uki_uname"
            return 0
        fi
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
    name="${name%.uki}"
    name="${name%.UKI}"
    if [[ "$name" =~ ([0-9]+\.[0-9]+\.[0-9]+([-._][[:alnum:]_.+-]+)?) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

windows_release_tag() {
    local build="$1"
    case "$build" in
        10240) printf '1507' ;;
        10586) printf '1511' ;;
        14393) printf '1607' ;;
        15063) printf '1703' ;;
        16299) printf '1709' ;;
        17134) printf '1803' ;;
        17763) printf '1809' ;;
        18362) printf '1903' ;;
        18363) printf '1909' ;;
        19041) printf '2004' ;;
        19042) printf '20H2' ;;
        19043) printf '21H1' ;;
        19044) printf '21H2' ;;
        19045) printf '22H2' ;;
        22000) printf '21H2' ;;
        22621) printf '22H2' ;;
        22631) printf '23H2' ;;
        26100) printf '24H2' ;;
        26200) printf '25H2' ;;
        *)
            if [[ "$build" =~ ^[0-9]+$ && "$build" -ge 27000 ]]; then
                printf 'Canary'
            fi
            ;;
    esac
}

normalize_windows_edition() {
    local ed="${1,,}"
    case "$ed" in
        professional|pro) printf 'pro' ;;
        professionalworkstation) printf 'pro for workstations' ;;
        professionaleducation) printf 'pro education' ;;
        core|home) printf 'home' ;;
        corecountryspecific|coresinglelanguage) printf 'home' ;;
        enterprise) printf 'enterprise' ;;
        enterprises) printf 'enterprise ltsc' ;;
        education) printf 'education' ;;
        serverstandard*) printf 'standard' ;;
        serverdatacenter*) printf 'datacenter' ;;
        *) printf '' ;;
    esac
}

map_windows_version() {
    local version="$1"
    local hint="${2,,}"
    local edition_raw="${3:-}"
    local inst_type="${4,,}"
    local ver_source="${5:-os}"
    local major="" minor="" build="" ed_tag=""
    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        major="${BASH_REMATCH[1]}"
        minor="${BASH_REMATCH[2]}"
        build="${BASH_REMATCH[3]}"
    fi
    ed_tag="$(normalize_windows_edition "$edition_raw")"
    local is_server=0
    if [[ "$inst_type" == "server" || "$hint" == *server* ]]; then
        is_server=1
    fi
    local base_name=""
    if [[ "$ver_source" == "loader" ]]; then
        if [[ "$hint" == *"windows 10"* && "$hint" != *"windows 11"* ]]; then
            base_name="windows 10"
        elif [[ "$hint" == *"windows 11"* && "$hint" != *"windows 10"* ]]; then
            base_name="windows 11"
        elif [[ "$hint" == *"windows 8.1"* ]]; then
            base_name="windows 8.1"
        elif [[ "$hint" == *"windows 8"* ]]; then
            base_name="windows 8"
        elif [[ "$hint" == *"windows 7"* ]]; then
            base_name="windows 7"
        fi
    fi
    if [[ -z "$base_name" && -n "$major" ]]; then
        if [[ "$major" == "5" && "$minor" == "1" ]]; then
            base_name="windows xp"
        elif [[ "$major" == "5" && "$minor" == "2" ]]; then
            if (( is_server == 1 )); then base_name="windows server 2003"; else base_name="windows xp"; fi
        elif [[ "$major" == "6" && "$minor" == "0" ]]; then
            if (( is_server == 1 )); then base_name="windows server 2008"; else base_name="windows vista"; fi
        elif [[ "$major" == "6" && "$minor" == "1" ]]; then
            if (( is_server == 1 )); then base_name="windows server 2008 r2"; else base_name="windows 7"; fi
        elif [[ "$major" == "6" && "$minor" == "2" ]]; then
            if (( is_server == 1 )); then base_name="windows server 2012"; else base_name="windows 8"; fi
        elif [[ "$major" == "6" && "$minor" == "3" ]]; then
            if (( is_server == 1 )); then base_name="windows server 2012 r2"; else base_name="windows 8.1"; fi
        elif [[ "$major" == "10" ]]; then
            if [[ "$hint" == *"server 2025"* || ( $is_server -eq 1 && "$build" -ge 26000 ) ]]; then
                base_name="windows server 2025"
            elif [[ "$hint" == *"server 2022"* || ( $is_server -eq 1 && "$build" -ge 20348 && "$build" -lt 26000 ) ]]; then
                base_name="windows server 2022"
            elif [[ "$hint" == *"server 2019"* || ( $is_server -eq 1 && "$build" -ge 17763 && "$build" -lt 20348 ) ]]; then
                base_name="windows server 2019"
            elif [[ "$hint" == *"server 2016"* || ( $is_server -eq 1 && "$build" -ge 14393 && "$build" -lt 17763 ) ]]; then
                base_name="windows server 2016"
            elif (( build >= 22000 )); then
                base_name="windows 11"
            else
                base_name="windows 10"
            fi
        fi
    fi
    [[ -n "$base_name" ]] || return 1
    if [[ -n "$ed_tag" && "$base_name" != *"$ed_tag"* ]]; then
        printf '%s %s' "$base_name" "$ed_tag"
    else
        printf '%s' "$base_name"
    fi
}

extract_windows_file_from_device() {
    local device="$1"
    local mountpoint="$2"
    local rel_path="$3"
    local out_file="$4"
    local ntfs_rel="/${rel_path#/}"
    ntfs_rel="${ntfs_rel//\\//}"
    if [[ -n "$mountpoint" && -d "$mountpoint" ]]; then
        local resolved
        resolved="$(resolve_case_insensitive_file "$mountpoint" "$ntfs_rel" 2>/dev/null || true)"
        if [[ -n "$resolved" && -s "$resolved" && -r "$resolved" ]]; then
            cp -- "$resolved" "$out_file" 2>/dev/null && [[ -s "$out_file" ]] && return 0
        fi
    fi
    if [[ -n "$NTFSCAT_BIN" && -b "$device" ]]; then
        if (( EUID == 0 )); then
            "$NTFSCAT_BIN" "$device" "$ntfs_rel" > "$out_file" 2>/dev/null && [[ -s "$out_file" ]] && return 0
        else
            sudo -n "$NTFSCAT_BIN" "$device" "$ntfs_rel" > "$out_file" 2>/dev/null && [[ -s "$out_file" ]] && return 0
        fi
    fi
    return 1
}

find_windows_candidate_devices() {
    local line name fstype parttype
    command -v lsblk >/dev/null 2>&1 || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        name=""
        fstype=""
        parttype=""
        if [[ "$line" =~ NAME=\"([^\"]*)\" ]]; then name="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ FSTYPE=\"([^\"]*)\" ]]; then fstype="${BASH_REMATCH[1]}"; fi
        if [[ "$line" =~ PARTTYPE=\"([^\"]*)\" ]]; then parttype="${BASH_REMATCH[1]}"; fi
        [[ -n "$name" ]] || continue
        [[ "$name" == /dev/* ]] || name="/dev/$name"
        [[ -b "$name" ]] || continue
        case "${fstype,,}" in
            ntfs|fuseblk)
                printf '%s\n' "$name"
                ;;
            "")
                case "${parttype,,}" in
                    ebd0a0a2-b9e5-4433-87c0-68b6b72699c7)
                        printf '%s\n' "$name"
                        ;;
                esac
                ;;
        esac
    done < <(lsblk -P -pnro NAME,FSTYPE,PARTTYPE 2>/dev/null || true)
}

inspect_windows_os_partition() {
    local win_partuuid="$1"
    local sysroot="${2:-\\Windows}"
    local clean_sysroot="${sysroot//\\//}"
    clean_sysroot="${clean_sysroot#/}"
    [[ -n "$clean_sysroot" ]] || clean_sysroot="Windows"

    local cache_key="${win_partuuid,,}|${clean_sysroot,,}"
    if [[ -n "${WINDOWS_OS_CACHE[$cache_key]+x}" ]]; then
        [[ -n "${WINDOWS_OS_CACHE[$cache_key]}" ]] || return 1
        printf '%s' "${WINDOWS_OS_CACHE[$cache_key]}"
        return 0
    fi

    local device="" mountpoint="" tmp_work=""
    if [[ -n "$win_partuuid" ]]; then
        device="$(get_partuuid_device "$win_partuuid" 2>/dev/null || true)"
    fi

    if [[ -z "$device" ]]; then
        local cand cand_mnt probe_tmp
        probe_tmp="$(mktemp)"
        while IFS= read -r cand; do
            [[ -b "$cand" ]] || continue
            cand_mnt="$(find_partition_mount "$cand")"
            if [[ -z "$cand_mnt" && -z "$NTFSCAT_BIN" ]]; then
                cand_mnt="$(mount_readonly_temp "$cand" "ntfs" 2>/dev/null || true)"
            fi
            if extract_windows_file_from_device "$cand" "$cand_mnt" "${clean_sysroot}/System32/ntoskrnl.exe" "$probe_tmp" || \
               extract_windows_file_from_device "$cand" "$cand_mnt" "${clean_sysroot}/System32/config/SOFTWARE" "$probe_tmp"; then
                device="$cand"
                mountpoint="$cand_mnt"
                break
            fi
        done < <(find_windows_candidate_devices)
        rm -f -- "$probe_tmp"
    fi

    if [[ -z "$device" || ! -b "$device" ]]; then
        WINDOWS_OS_CACHE["$cache_key"]=""
        return 1
    fi
    [[ -n "$mountpoint" ]] || mountpoint="$(find_partition_mount "$device")"

    tmp_work="$(mktemp -d)"
    TEMP_CLEANUP_DIRS+=("$tmp_work")

    local got_kernel=0 got_hive=0
    if extract_windows_file_from_device "$device" "$mountpoint" "${clean_sysroot}/System32/ntoskrnl.exe" "$tmp_work/ntoskrnl.exe" || \
       extract_windows_file_from_device "$device" "$mountpoint" "${clean_sysroot}/System32/winload.efi" "$tmp_work/ntoskrnl.exe"; then
        got_kernel=1
    fi

    if extract_windows_file_from_device "$device" "$mountpoint" "${clean_sysroot}/System32/config/SOFTWARE" "$tmp_work/SOFTWARE"; then
        got_hive=1
    fi

    if (( got_kernel == 0 && got_hive == 0 )) && [[ -z "$mountpoint" ]]; then
        local ro_mnt
        ro_mnt="$(mount_readonly_temp "$device" "ntfs" 2>/dev/null || true)"
        if [[ -n "$ro_mnt" && -d "$ro_mnt" ]]; then
            mountpoint="$ro_mnt"
            if extract_windows_file_from_device "$device" "$mountpoint" "${clean_sysroot}/System32/ntoskrnl.exe" "$tmp_work/ntoskrnl.exe" || \
               extract_windows_file_from_device "$device" "$mountpoint" "${clean_sysroot}/System32/winload.efi" "$tmp_work/ntoskrnl.exe"; then
                got_kernel=1
            fi
            if extract_windows_file_from_device "$device" "$mountpoint" "${clean_sysroot}/System32/config/SOFTWARE" "$tmp_work/SOFTWARE"; then
                got_hive=1
            fi
        fi
    fi

    local ver_found="" prod_found="" disp_ver="" ubr_found="" edition_found="" inst_type=""
    if (( got_kernel == 1 || got_hive == 1 )) && [[ -n "$PYTHON_BIN" ]]; then
        local combined_win_info
        combined_win_info="$("$PYTHON_BIN" - "$tmp_work/ntoskrnl.exe" "$tmp_work/SOFTWARE" << 'PYEOF' 2>/dev/null || true
import os, struct, sys

pe_path = sys.argv[1]
hive_path = sys.argv[2]

pe_ver = ""
pe_prod = ""

if os.path.isfile(pe_path) and os.path.getsize(pe_path) >= 64:
    with open(pe_path, "rb") as f:
        pdata = f.read()
    if pdata[:2] == b"MZ":
        pe_off = struct.unpack_from("<I", pdata, 0x3C)[0]
        if pe_off + 24 <= len(pdata) and pdata[pe_off:pe_off+4] == b"PE\x00\x00":
            num_sec = struct.unpack_from("<H", pdata, pe_off + 6)[0]
            opt_size = struct.unpack_from("<H", pdata, pe_off + 20)[0]
            sec_off = pe_off + 24 + opt_size
            rsrc_blob = b""
            for i in range(num_sec):
                off = sec_off + i * 40
                if off + 40 > len(pdata):
                    break
                name = pdata[off:off+8].rstrip(b"\x00").decode("latin1", errors="ignore")
                raw_size, raw_ptr = struct.unpack_from("<II", pdata, off + 16)
                if name == ".rsrc" and raw_ptr > 0 and raw_size > 0 and raw_ptr + raw_size <= len(pdata):
                    rsrc_blob = pdata[raw_ptr:raw_ptr+raw_size]
                    break
            space = rsrc_blob if rsrc_blob else pdata
            sig_u16 = "VS_VERSION_INFO".encode("utf-16le")
            idx = space.find(sig_u16)
            if idx != -1 and idx >= 6:
                vs_start = idx - 6
                vs_len = struct.unpack_from("<H", space, vs_start)[0]
                vs_end = min(len(space), vs_start + vs_len) if vs_len >= 40 else len(space)
                magic_pos = space.find(b"\xbd\x04\xef\xfe", idx, idx + 128)
                if magic_pos != -1 and magic_pos + 52 <= len(space):
                    _, _, f_ms, f_ls, p_ms, p_ls = struct.unpack_from("<IIIIII", space, magic_pos)
                    pmaj, pmin = (p_ms >> 16) & 0xFFFF, p_ms & 0xFFFF
                    pbld, prev = (p_ls >> 16) & 0xFFFF, p_ls & 0xFFFF
                    if pmaj > 0:
                        pe_ver = f"{pmaj}.{pmin}.{pbld}.{prev}"
                    else:
                        fmaj, fmin = (f_ms >> 16) & 0xFFFF, f_ms & 0xFFFF
                        fbld, frev = (f_ls >> 16) & 0xFFFF, f_ls & 0xFFFF
                        if fmaj > 0:
                            pe_ver = f"{fmaj}.{fmin}.{fbld}.{frev}"
                    str_kv = {}
                    def read_u16z(buf, pos, limit):
                        end = pos
                        while end + 1 < limit and buf[end:end+2] != b"\x00\x00":
                            end += 2
                        txt = buf[pos:end].decode("utf-16le", errors="ignore")
                        nxt = end + 2 if end + 2 <= limit else limit
                        return txt, (nxt + 3) & ~3
                    def walk_tbl(buf, start, end):
                        pos = start
                        while pos + 6 <= end:
                            wlen, wvlen, wtype = struct.unpack_from("<HHH", buf, pos)
                            if wlen < 6 or pos + wlen > end:
                                break
                            nend = pos + wlen
                            key, vpos = read_u16z(buf, pos + 6, nend)
                            if wtype == 1 and wvlen > 0 and vpos < nend:
                                val = buf[vpos:vpos+min(wvlen*2, nend-vpos)].decode("utf-16le", errors="ignore").rstrip("\x00").strip()
                                if key and val:
                                    str_kv[key] = val
                            elif key in ("StringFileInfo", "StringTable") or (len(key) == 8 and all(c in "0123456789abcdefABCDEF" for c in key)):
                                walk_tbl(buf, vpos, nend)
                            pos = (nend + 3) & ~3
                    walk_tbl(space, (magic_pos + 52 + 3) & ~3, vs_end)
                    pe_prod = str_kv.get("ProductName", "")

vals = {}
if os.path.isfile(hive_path) and os.path.getsize(hive_path) >= 4096:
    with open(hive_path, "rb") as f:
        data = f.read()
    if data[:4] == b"regf":
        n = len(data)
        def read_cell(offset):
            if offset <= 0 or offset == 0xFFFFFFFF or 4096 + offset + 4 > n:
                return b""
            size = abs(struct.unpack_from("<i", data, 4096 + offset)[0])
            if size < 4 or 4096 + offset + size > n:
                return b""
            return data[4096 + offset + 4 : 4096 + offset + size]
        def parse_nk(offset):
            cell = read_cell(offset)
            if len(cell) < 76 or cell[:2] != b"nk":
                return None
            _, _, _, _, sub_cnt, _, sub_list_off, _, val_cnt, val_list_off = struct.unpack_from("<HQIIIIIIII", cell, 2)
            name_len = struct.unpack_from("<H", cell, 72)[0]
            name = cell[76:76+name_len].decode("latin1", errors="ignore")
            return {"name": name, "sub_cnt": sub_cnt, "sub_list_off": sub_list_off, "val_cnt": val_cnt, "val_list_off": val_list_off}
        def iter_subkeys(nk):
            if not nk or nk["sub_cnt"] <= 0 or nk["sub_list_off"] <= 0 or nk["sub_list_off"] == 0xFFFFFFFF:
                return []
            lcell = read_cell(nk["sub_list_off"])
            if len(lcell) < 4:
                return []
            sig = lcell[:2]
            cnt = struct.unpack_from("<H", lcell, 2)[0]
            res = []
            if sig in (b"lf", b"lh"):
                for i in range(cnt):
                    if 4 + i * 8 + 4 <= len(lcell):
                        sk = parse_nk(struct.unpack_from("<I", lcell, 4 + i * 8)[0])
                        if sk:
                            res.append(sk)
            elif sig == b"li":
                for i in range(cnt):
                    if 4 + i * 4 + 4 <= len(lcell):
                        sk = parse_nk(struct.unpack_from("<I", lcell, 4 + i * 4)[0])
                        if sk:
                            res.append(sk)
            elif sig == b"ri":
                for i in range(cnt):
                    if 4 + i * 4 + 4 <= len(lcell):
                        sub_l = read_cell(struct.unpack_from("<I", lcell, 4 + i * 4)[0])
                        if len(sub_l) >= 4 and sub_l[:2] in (b"lf", b"lh", b"li"):
                            step = 8 if sub_l[:2] in (b"lf", b"lh") else 4
                            scnt = struct.unpack_from("<H", sub_l, 2)[0]
                            for j in range(scnt):
                                if 4 + j * step + 4 <= len(sub_l):
                                    sk = parse_nk(struct.unpack_from("<I", sub_l, 4 + j * step)[0])
                                    if sk:
                                        res.append(sk)
            return res
        def get_values(nk):
            out = {}
            if not nk or nk["val_cnt"] <= 0 or nk["val_list_off"] <= 0 or nk["val_list_off"] == 0xFFFFFFFF:
                return out
            vlist = read_cell(nk["val_list_off"])
            for i in range(nk["val_cnt"]):
                if i * 4 + 4 > len(vlist):
                    break
                vcell = read_cell(struct.unpack_from("<I", vlist, i * 4)[0])
                if len(vcell) < 20 or vcell[:2] != b"vk":
                    continue
                name_len, data_len, data_off, vtype, _, _ = struct.unpack_from("<HIIIHH", vcell, 2)
                vname = vcell[20:20+name_len].decode("latin1", errors="ignore") if name_len > 0 else "(default)"
                if data_len & 0x80000000:
                    raw = struct.pack("<I", data_off)[:data_len & 0x7FFFFFFF]
                else:
                    raw = read_cell(data_off)[:data_len]
                if vtype == 4 and len(raw) >= 4:
                    out[vname] = str(struct.unpack_from("<I", raw, 0)[0])
                elif vtype in (1, 2):
                    out[vname] = raw.decode("utf-16le", errors="ignore").rstrip("\x00").strip()
            return out
        cur = parse_nk(struct.unpack_from("<I", data, 0x24)[0])
        for part in ("microsoft", "windows nt", "currentversion"):
            cur = next((sk for sk in iter_subkeys(cur) if sk["name"].lower() == part), None)
            if not cur:
                break
        if cur:
            vals = get_values(cur)

print(f"PE_VERSION={pe_ver}")
print(f"PE_PRODUCT_NAME={pe_prod}")
for k in ("ProductName", "DisplayVersion", "ReleaseId", "CurrentBuildNumber", "UBR", "EditionID", "InstallationType", "CurrentMajorVersionNumber", "CurrentMinorVersionNumber"):
    print(f"{k}={vals.get(k, '')}")
PYEOF
)"
        if [[ -n "$combined_win_info" ]]; then
            ver_found="$(kv_get "$combined_win_info" "PE_VERSION" || true)"
            prod_found="$(kv_get "$combined_win_info" "PE_PRODUCT_NAME" || true)"
            local r_prod r_disp r_rel r_build r_ubr r_ed r_inst r_maj r_min
            r_prod="$(kv_get "$combined_win_info" "ProductName" || true)"
            r_disp="$(kv_get "$combined_win_info" "DisplayVersion" || true)"
            r_rel="$(kv_get "$combined_win_info" "ReleaseId" || true)"
            r_build="$(kv_get "$combined_win_info" "CurrentBuildNumber" || true)"
            r_ubr="$(kv_get "$combined_win_info" "UBR" || true)"
            r_ed="$(kv_get "$combined_win_info" "EditionID" || true)"
            r_inst="$(kv_get "$combined_win_info" "InstallationType" || true)"
            r_maj="$(kv_get "$combined_win_info" "CurrentMajorVersionNumber" || true)"
            r_min="$(kv_get "$combined_win_info" "CurrentMinorVersionNumber" || true)"
            [[ -n "$r_prod" ]] && prod_found="$r_prod"
            disp_ver="${r_disp:-$r_rel}"
            ubr_found="$r_ubr"
            edition_found="$r_ed"
            inst_type="$r_inst"
            if [[ -n "$r_build" && "$r_build" =~ ^[0-9]+$ ]]; then
                local maj_num="${r_maj:-10}"
                local min_num="${r_min:-0}"
                if [[ -n "$ubr_found" && "$ubr_found" =~ ^[0-9]+$ ]]; then
                    ver_found="${maj_num}.${min_num}.${r_build}.${ubr_found}"
                elif [[ -z "$ver_found" || "$ver_found" != *".$r_build."* ]]; then
                    ver_found="${maj_num}.${min_num}.${r_build}.0"
                fi
            fi
        fi
    elif (( got_kernel == 1 )) && [[ -s "$tmp_work/ntoskrnl.exe" ]]; then
        ver_found="$(extract_product_version "$tmp_work/ntoskrnl.exe" 2>/dev/null || true)"
    fi

    if [[ -z "${ver_found:-}" && -z "${prod_found:-}" ]]; then
        WINDOWS_OS_CACHE["$cache_key"]=""
        return 1
    fi
    local packed_win
    printf -v packed_win 'VERSION=%s\nPRODUCT_NAME=%s\nDISPLAY_VERSION=%s\nEDITION_ID=%s\nINST_TYPE=%s\nDEV_PATH=%s' \
        "${ver_found:-}" "${prod_found:-}" "${disp_ver:-}" "${edition_found:-}" "${inst_type:-}" "${device:-}"
    WINDOWS_OS_CACHE["$cache_key"]="$packed_win"
    printf '%s' "$packed_win"
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

format_windows_display_version() {
    local raw_ver="$1"
    local explicit_disp="${2:-}"
    local build="" tag=""
    if [[ "$raw_ver" =~ ^[0-9]+\.[0-9]+\.([0-9]+) ]]; then
        build="${BASH_REMATCH[1]}"
        tag="${explicit_disp:-$(windows_release_tag "$build")}"
    fi
    if [[ -n "$tag" && -n "$raw_ver" ]]; then
        printf '%s (%s)' "$tag" "$raw_ver"
    elif [[ -n "$raw_ver" ]]; then
        printf '%s' "$raw_ver"
    elif [[ -n "$tag" ]]; then
        printf '%s' "$tag"
    fi
}

parse_windows_bcd_entries() {
    local esp_partuuid="$1"
    local bcd_rel="/EFI/Microsoft/Boot/BCD"
    local tmp_bcd
    tmp_bcd="$(mktemp)"
    if ! copy_entry_file "$esp_partuuid" "$bcd_rel" "$tmp_bcd" 2>/dev/null || [[ ! -s "$tmp_bcd" ]]; then
        rm -f -- "$tmp_bcd"
        return 1
    fi
    if [[ -z "$PYTHON_BIN" ]]; then
        rm -f -- "$tmp_bcd"
        return 1
    fi
    "$PYTHON_BIN" - "$tmp_bcd" << 'PYEOF' 2>/dev/null
import struct, sys, uuid, re

with open(sys.argv[1], "rb") as f:
    data = f.read()

if len(data) < 4096 or data[:4] != b"regf":
    sys.exit(1)

n = len(data)

def read_cell(offset):
    if offset <= 0 or offset == 0xFFFFFFFF or 4096 + offset + 4 > n:
        return b""
    size = abs(struct.unpack_from("<i", data, 4096 + offset)[0])
    if size < 4 or 4096 + offset + size > n:
        return b""
    return data[4096 + offset + 4 : 4096 + offset + size]

def parse_nk(offset):
    cell = read_cell(offset)
    if len(cell) < 76 or cell[:2] != b"nk":
        return None
    flags, _, _, _, sub_cnt, _, sub_list_off, _, val_cnt, val_list_off = struct.unpack_from("<HQIIIIIIII", cell, 2)
    name_len = struct.unpack_from("<H", cell, 72)[0]
    name = cell[76:76+name_len].decode("latin1", errors="ignore")
    return {
        "offset": offset,
        "name": name,
        "sub_cnt": sub_cnt,
        "sub_list_off": sub_list_off,
        "val_cnt": val_cnt,
        "val_list_off": val_list_off,
    }

def iter_subkeys(nk):
    if not nk or nk["sub_cnt"] <= 0 or nk["sub_list_off"] <= 0 or nk["sub_list_off"] == 0xFFFFFFFF:
        return []
    lcell = read_cell(nk["sub_list_off"])
    if len(lcell) < 4:
        return []
    sig = lcell[:2]
    cnt = struct.unpack_from("<H", lcell, 2)[0]
    res = []
    if sig in (b"lf", b"lh"):
        for i in range(cnt):
            if 4 + i * 8 + 4 <= len(lcell):
                off = struct.unpack_from("<I", lcell, 4 + i * 8)[0]
                sk = parse_nk(off)
                if sk:
                    res.append(sk)
    elif sig == b"li":
        for i in range(cnt):
            if 4 + i * 4 + 4 <= len(lcell):
                off = struct.unpack_from("<I", lcell, 4 + i * 4)[0]
                sk = parse_nk(off)
                if sk:
                    res.append(sk)
    elif sig == b"ri":
        for i in range(cnt):
            if 4 + i * 4 + 4 <= len(lcell):
                sub_off = struct.unpack_from("<I", lcell, 4 + i * 4)[0]
                sub_l = read_cell(sub_off)
                if len(sub_l) >= 4 and sub_l[:2] in (b"lf", b"lh", b"li"):
                    step = 8 if sub_l[:2] in (b"lf", b"lh") else 4
                    scnt = struct.unpack_from("<H", sub_l, 2)[0]
                    for j in range(scnt):
                        if 4 + j * step + 4 <= len(sub_l):
                            off = struct.unpack_from("<I", sub_l, 4 + j * step)[0]
                            sk = parse_nk(off)
                            if sk:
                                res.append(sk)
    return res

def get_values(nk):
    vals = {}
    if not nk or nk["val_cnt"] <= 0 or nk["val_list_off"] <= 0 or nk["val_list_off"] == 0xFFFFFFFF:
        return vals
    vlist = read_cell(nk["val_list_off"])
    for i in range(nk["val_cnt"]):
        if i * 4 + 4 > len(vlist):
            break
        voff = struct.unpack_from("<I", vlist, i * 4)[0]
        vcell = read_cell(voff)
        if len(vcell) < 20 or vcell[:2] != b"vk":
            continue
        name_len, data_len, data_off, vtype, flags, _ = struct.unpack_from("<HIIIHH", vcell, 2)
        vname = vcell[20:20+name_len].decode("latin1", errors="ignore") if name_len > 0 else "(default)"
        if data_len & 0x80000000:
            rlen = data_len & 0x7FFFFFFF
            raw = struct.pack("<I", data_off)[:rlen]
        else:
            raw = read_cell(data_off)[:data_len]
        vals[vname] = (vtype, raw)
    return vals

def extract_device_info(blob):
    if len(blob) < 0x14:
        return 0, ""
    dev_type = struct.unpack_from("<I", blob, 0x10)[0]
    part_uuid = ""
    if dev_type == 2 and len(blob) >= 0x34:
        part_type = struct.unpack_from("<I", blob, 0x30)[0]
        if part_type == 0:
            raw_guid = blob[0x20:0x30]
            if raw_guid != b"\x00" * 16:
                part_uuid = str(uuid.UUID(bytes_le=raw_guid)).lower()
    return dev_type, part_uuid

root_off = struct.unpack_from("<I", data, 0x24)[0]
root_nk = parse_nk(root_off)
objects_nk = next((sk for sk in iter_subkeys(root_nk) if sk["name"].lower() == "objects"), None)
if not objects_nk:
    sys.exit(1)

bootmgr_guid = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
display_order = []
default_obj = ""
entries = {}

for obj_nk in iter_subkeys(objects_nk):
    guid = obj_nk["name"].lower()
    obj_type = 0
    elems_nk = None
    for sub in iter_subkeys(obj_nk):
        if sub["name"].lower() == "description":
            dvals = get_values(sub)
            if "Type" in dvals and len(dvals["Type"][1]) >= 4:
                obj_type = struct.unpack_from("<I", dvals["Type"][1], 0)[0]
        elif sub["name"].lower() == "elements":
            elems_nk = sub
    if not elems_nk:
        continue
    elem_map = {}
    for el_nk in iter_subkeys(elems_nk):
        evals = get_values(el_nk)
        if "Element" in evals:
            elem_map[el_nk["name"].lower()] = evals["Element"][1]
    if guid == bootmgr_guid:
        if "24000001" in elem_map:
            txt = elem_map["24000001"].decode("utf-16le", errors="ignore")
            display_order = [g.lower() for g in re.findall(r"\{[0-9a-fA-F-]{36}\}", txt)]
        if "23000003" in elem_map:
            txt = elem_map["23000003"].decode("utf-16le", errors="ignore")
            m = re.search(r"\{[0-9a-fA-F-]{36}\}", txt)
            if m:
                default_obj = m.group(0).lower()
    elif obj_type == 0x10200003:
        desc = ""
        if "12000004" in elem_map:
            desc = elem_map["12000004"].decode("utf-16le", errors="ignore").rstrip("\x00").strip()
        app_path = ""
        if "12000002" in elem_map:
            app_path = elem_map["12000002"].decode("utf-16le", errors="ignore").rstrip("\x00").strip()
        sys_root = ""
        if "22000002" in elem_map:
            sys_root = elem_map["22000002"].decode("utf-16le", errors="ignore").rstrip("\x00").strip()
        winpe_flag = 0
        if "46000010" in elem_map and len(elem_map["46000010"]) >= 1:
            winpe_flag = elem_map["46000010"][0]
        app_dev_type = 0
        if "11000001" in elem_map:
            app_dev_type, _ = extract_device_info(elem_map["11000001"])
        os_dev_type = 0
        part_uuid = ""
        if "21000001" in elem_map:
            os_dev_type, part_uuid = extract_device_info(elem_map["21000001"])
        desc_low = desc.lower()
        is_recovery = (
            winpe_flag != 0
            or app_dev_type == 1
            or os_dev_type == 1
            or "recovery environment" in desc_low
            or "winre" in desc_low
            or ".wim" in app_path.lower()
        )
        if is_recovery:
            continue
        entries[guid] = {
            "guid": guid,
            "desc": desc or "Windows",
            "app_path": app_path or r"\Windows\system32\winload.efi",
            "sys_root": sys_root or r"\Windows",
            "part_uuid": part_uuid,
        }

if display_order:
    ordered_guids = [g for g in display_order if g in entries]
    if not ordered_guids:
        ordered_guids = list(entries.keys())
else:
    ordered_guids = list(entries.keys())

for g in ordered_guids:
    e = entries[g]
    is_def = "1" if g == default_obj else "0"
    print(f"{e['guid']}|{is_def}|{e['desc']}|{e['part_uuid']}|{e['sys_root']}|{e['app_path']}")
PYEOF
    local rc=$?
    rm -f -- "$tmp_bcd"
    return $rc
}

create_isolated_windows_boot() {
    local esp_partuuid="$1"
    local target_guid="${2,,}"
    local target_label="$3"
    [[ -n "$esp_partuuid" && "$target_guid" =~ ^\{[0-9a-f-]{36}\}$ ]] || return 1
    [[ -n "$PYTHON_BIN" ]] || return 1
    local short_id="${target_guid//[\{\}-]/}"
    short_id="${short_id:0:8}"
    local iso_rel_dir="/EFI/multiboot-win-${short_id}"
    local iso_rel_efi="${iso_rel_dir}/bootmgfw.efi"
    local esp_dev esp_mnt temp_mnt=""
    esp_dev="$(get_partuuid_device "$esp_partuuid" 2>/dev/null || true)"
    esp_mnt=""
    [[ -n "$esp_dev" ]] && esp_mnt="$(find_partition_mount "$esp_dev")"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    if ! copy_entry_file "$esp_partuuid" "/EFI/Microsoft/Boot/bootmgfw.efi" "$tmp_dir/bootmgfw.efi" 2>/dev/null; then
        rm -rf -- "$tmp_dir"
        return 1
    fi
    if ! copy_entry_file "$esp_partuuid" "/EFI/Microsoft/Boot/BCD" "$tmp_dir/BCD" 2>/dev/null; then
        rm -rf -- "$tmp_dir"
        return 1
    fi

    if ! "$PYTHON_BIN" - "$tmp_dir/BCD" "$target_guid" << 'PYEOF' 2>/dev/null
import struct, sys

bcd_path = sys.argv[1]
target_guid = sys.argv[2].lower()

with open(bcd_path, "rb") as f:
    data = bytearray(f.read())

if len(data) < 4096 or data[:4] != b"regf":
    sys.exit(1)

n = len(data)

def read_cell_span(offset):
    if offset <= 0 or offset == 0xFFFFFFFF or 4096 + offset + 4 > n:
        return None
    size = abs(struct.unpack_from("<i", data, 4096 + offset)[0])
    if size < 4 or 4096 + offset + size > n:
        return None
    return (4096 + offset + 4, size - 4)

def parse_nk(offset):
    span = read_cell_span(offset)
    if not span:
        return None
    start, length = span
    cell = data[start:start+length]
    if len(cell) < 76 or cell[:2] != b"nk":
        return None
    _, _, _, _, sub_cnt, _, sub_list_off, _, val_cnt, val_list_off = struct.unpack_from("<HQIIIIIIII", cell, 2)
    name_len = struct.unpack_from("<H", cell, 72)[0]
    name = cell[76:76+name_len].decode("latin1", errors="ignore")
    return {"name": name, "sub_cnt": sub_cnt, "sub_list_off": sub_list_off, "val_cnt": val_cnt, "val_list_off": val_list_off}

def iter_subkeys(nk):
    if not nk or nk["sub_cnt"] <= 0 or nk["sub_list_off"] <= 0 or nk["sub_list_off"] == 0xFFFFFFFF:
        return []
    span = read_cell_span(nk["sub_list_off"])
    if not span:
        return []
    start, length = span
    lcell = data[start:start+length]
    sig = lcell[:2]
    cnt = struct.unpack_from("<H", lcell, 2)[0]
    res = []
    if sig in (b"lf", b"lh"):
        for i in range(cnt):
            if 4 + i * 8 + 4 <= len(lcell):
                off = struct.unpack_from("<I", lcell, 4 + i * 8)[0]
                sk = parse_nk(off)
                if sk:
                    res.append(sk)
    elif sig == b"li":
        for i in range(cnt):
            if 4 + i * 4 + 4 <= len(lcell):
                off = struct.unpack_from("<I", lcell, 4 + i * 4)[0]
                sk = parse_nk(off)
                if sk:
                    res.append(sk)
    return res

def get_element_span(nk):
    if not nk or nk["val_cnt"] <= 0 or nk["val_list_off"] <= 0 or nk["val_list_off"] == 0xFFFFFFFF:
        return None
    vspan = read_cell_span(nk["val_list_off"])
    if not vspan:
        return None
    vlist = data[vspan[0]:vspan[0]+vspan[1]]
    for i in range(nk["val_cnt"]):
        if i * 4 + 4 > len(vlist):
            break
        voff = struct.unpack_from("<I", vlist, i * 4)[0]
        vk_span = read_cell_span(voff)
        if not vk_span:
            continue
        vcell = data[vk_span[0]:vk_span[0]+vk_span[1]]
        if len(vcell) < 20 or vcell[:2] != b"vk":
            continue
        name_len, data_len, data_off, vtype, flags, _ = struct.unpack_from("<HIIIHH", vcell, 2)
        vname = vcell[20:20+name_len].decode("latin1", errors="ignore")
        if vname == "Element":
            if data_len & 0x80000000:
                return ("inline", vk_span[0] + 8, data_len & 0x7FFFFFFF)
            dspan = read_cell_span(data_off)
            if dspan:
                return ("cell", dspan[0], min(dspan[1], data_len))
    return None

root_off = struct.unpack_from("<I", data, 0x24)[0]
root_nk = parse_nk(root_off)
objects_nk = next((sk for sk in iter_subkeys(root_nk) if sk["name"].lower() == "objects"), None)
if not objects_nk:
    sys.exit(1)

bootmgr_nk = next((sk for sk in iter_subkeys(objects_nk) if sk["name"].lower() == "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"), None)
if not bootmgr_nk:
    sys.exit(1)

elems_nk = next((sk for sk in iter_subkeys(bootmgr_nk) if sk["name"].lower() == "elements"), None)
if not elems_nk:
    sys.exit(1)

guid_u16 = (target_guid + "\x00").encode("utf-16le")
multi_u16 = (target_guid + "\x00\x00").encode("utf-16le")

patched = False
for el_nk in iter_subkeys(elems_nk):
    ename = el_nk["name"].lower()
    espan = get_element_span(el_nk)
    if not espan:
        continue
    mode, pos, length = espan
    if ename == "23000003" and mode == "cell" and length >= len(guid_u16):
        data[pos:pos+length] = b"\x00" * length
        data[pos:pos+len(guid_u16)] = guid_u16
        patched = True
    elif ename == "24000001" and mode == "cell" and length >= len(multi_u16):
        data[pos:pos+length] = b"\x00" * length
        data[pos:pos+len(multi_u16)] = multi_u16
        patched = True
    elif ename == "26000020" and length >= 1:
        data[pos:pos+length] = b"\x00" * length
    elif ename == "25000004" and length >= 4:
        data[pos:pos+length] = b"\x00" * length

if not patched:
    sys.exit(1)

csum = 0
for off in range(0, 0x1FC, 4):
    val = struct.unpack_from("<I", data, off)[0]
    csum ^= val
if csum == 0:
    csum = 1
elif csum == 0xFFFFFFFF:
    csum = 0xFFFFFFFE
struct.pack_into("<I", data, 0x1FC, csum)

with open(bcd_path, "wb") as f:
    f.write(data)
PYEOF
    then
        rm -rf -- "$tmp_dir"
        return 1
    fi

    if [[ -z "$esp_mnt" && -b "$esp_dev" ]]; then
        temp_mnt="$(mktemp -d)"
        if (( EUID == 0 )); then
            mount -t vfat "$esp_dev" "$temp_mnt" 2>/dev/null && esp_mnt="$temp_mnt" || true
        else
            sudo -n mount -t vfat "$esp_dev" "$temp_mnt" 2>/dev/null && esp_mnt="$temp_mnt" || true
        fi
    fi

    local write_ok=0
    if [[ -n "$esp_mnt" && -d "$esp_mnt" ]]; then
        local target_dir="$esp_mnt$iso_rel_dir"
        if (( EUID == 0 )); then
            if mkdir -p "$target_dir" && cp -f "$tmp_dir/bootmgfw.efi" "$target_dir/bootmgfw.efi" && cp -f "$tmp_dir/BCD" "$target_dir/BCD"; then
                write_ok=1
                if [[ -d "$esp_mnt/EFI/Microsoft/Boot/en-US" ]]; then
                    mkdir -p "$target_dir/en-US" 2>/dev/null || true
                    cp -f "$esp_mnt/EFI/Microsoft/Boot/en-US/bootmgfw.efi.mui" "$target_dir/en-US/" 2>/dev/null || true
                fi
            fi
        else
            if sudo -n mkdir -p "$target_dir" 2>/dev/null && sudo -n cp -f "$tmp_dir/bootmgfw.efi" "$target_dir/bootmgfw.efi" 2>/dev/null && sudo -n cp -f "$tmp_dir/BCD" "$target_dir/BCD" 2>/dev/null; then
                write_ok=1
                if [[ -d "$esp_mnt/EFI/Microsoft/Boot/en-US" ]]; then
                    sudo -n mkdir -p "$target_dir/en-US" 2>/dev/null || true
                    sudo -n cp -f "$esp_mnt/EFI/Microsoft/Boot/en-US/bootmgfw.efi.mui" "$target_dir/en-US/" 2>/dev/null || true
                fi
            elif mkdir -p "$target_dir" 2>/dev/null && cp -f "$tmp_dir/bootmgfw.efi" "$target_dir/bootmgfw.efi" 2>/dev/null && cp -f "$tmp_dir/BCD" "$target_dir/BCD" 2>/dev/null; then
                write_ok=1
            fi
        fi
    fi
    if (( write_ok == 0 )) && [[ -x "$EFI_READ_HELPER" ]]; then
        if run_efi_reader esp-write-isolated "$esp_partuuid" "$short_id" "$tmp_dir/bootmgfw.efi" "$tmp_dir/BCD" >/dev/null 2>&1; then
            write_ok=1
        fi
    fi

    if [[ -n "$temp_mnt" ]]; then
        if (( EUID == 0 )); then
            umount "$temp_mnt" 2>/dev/null || true
        else
            sudo -n umount "$temp_mnt" 2>/dev/null || true
        fi
        rmdir "$temp_mnt" 2>/dev/null || true
    fi
    rm -rf -- "$tmp_dir"

    (( write_ok == 1 )) || return 1

    local existing_id=""
    local efi_win_path="${iso_rel_efi//\//\\}"
    existing_id="$(EFI_SEARCH_PATH="$efi_win_path" EFI_SEARCH_PU="$esp_partuuid" awk '
        BEGIN { p = tolower(ENVIRON["EFI_SEARCH_PATH"]); pu = tolower(ENVIRON["EFI_SEARCH_PU"]) }
        /^Boot[0-9A-Fa-f]{4}/ {
            low = tolower($0)
            if (index(low, p) > 0 && (pu == "" || index(low, pu) > 0)) {
                print toupper(substr($0, 5, 4))
                exit
            }
        }
    ' <<< "$(get_efi_output)")"
    if [[ -n "$existing_id" ]]; then
        printf '%s' "$existing_id"
        return 0
    fi

    [[ -n "$EFI_BIN" && -b "$esp_dev" ]] || return 1
    local disk_dev part_num
    disk_dev="/dev/$(lsblk -dnro PKNAME "$esp_dev" 2>/dev/null | head -n 1 || true)"
    part_num="$(cat "/sys/class/block/${esp_dev##*/}/partition" 2>/dev/null || true)"
    if [[ -z "$part_num" && "$esp_dev" =~ ([0-9]+)$ ]]; then
        part_num="${BASH_REMATCH[1]}"
    fi
    [[ -b "$disk_dev" && "$part_num" =~ ^[0-9]+$ ]] || return 1

    if (( EUID == 0 )); then
        "$EFI_BIN" -c -d "$disk_dev" -p "$part_num" -L "$target_label" -l "$efi_win_path" >/dev/null 2>&1 || return 1
    else
        sudo -n "$EFI_BIN" -c -d "$disk_dev" -p "$part_num" -L "$target_label" -l "$efi_win_path" >/dev/null 2>&1 || \
            run_efi_reader create-uefi-entry "$disk_dev" "$part_num" "$target_label" "$efi_win_path" >/dev/null 2>&1 || return 1
    fi

    EFI_OUTPUT=""
    existing_id="$(EFI_SEARCH_PATH="$efi_win_path" awk '
        BEGIN { p = tolower(ENVIRON["EFI_SEARCH_PATH"]) }
        /^Boot[0-9A-Fa-f]{4}/ {
            if (index(tolower($0), p) > 0) {
                print toupper(substr($0, 5, 4))
                exit
            }
        }
    ' <<< "$(get_efi_output)")"
    [[ -n "$existing_id" ]] || return 1
    printf '%s' "$existing_id"
}

clean_isolated_windows_entries() {
    local removed=0 id mountpoint dir
    while IFS= read -r id; do
        [[ "$id" =~ ^[0-9A-Fa-f]{4}$ ]] || continue
        if (( EUID == 0 )); then
            "$EFI_BIN" -b "$id" -B >/dev/null 2>&1 && ((removed+=1)) || true
        else
            sudo -n "$EFI_BIN" -b "$id" -B >/dev/null 2>&1 && ((removed+=1)) || \
                run_efi_reader remove-uefi-entry "$id" >/dev/null 2>&1 && ((removed+=1)) || true
        fi
    done < <(awk '
        /^Boot[0-9A-Fa-f]{4}/ {
            if (index(tolower($0), "\\efi\\multiboot-win-") > 0) {
                print toupper(substr($0, 5, 4))
            }
        }
    ' <<< "$(get_efi_output)")
    EFI_OUTPUT=""
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" && -d "$mountpoint/EFI" ]] || continue
        for dir in "$mountpoint"/EFI/multiboot-win-*; do
            [[ -d "$dir" ]] || continue
            if (( EUID == 0 )); then
                rm -rf -- "$dir" 2>/dev/null || true
            else
                sudo -n rm -rf -- "$dir" 2>/dev/null || rm -rf -- "$dir" 2>/dev/null || \
                    run_efi_reader esp-rm-isolated "$dir" >/dev/null 2>&1 || true
            fi
        done
    done < <(find_esp_mounts)
    print_success "Cleaned up ${removed} isolated Windows UEFI entries and ESP directories."
}

get_linux_version() {
    local partuuid="$1"
    local loader="$2"
    local pre_uname="${3:-}"
    local temporary resolved version
    if [[ "$pre_uname" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
        printf '%s' "$pre_uname"
        return 0
    fi
    resolved="$(resolve_esp_file "$partuuid" "$loader" 2>/dev/null || true)"
    if [[ -n "$resolved" && -r "$resolved" ]]; then
        version="$(get_kernel_image_version "$resolved" 2>/dev/null || true)"
    elif [[ -n "$partuuid" ]]; then
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

normalize_distro_id() {
    local id="${1,,}"
    id="${id#\"}"
    id="${id%\"}"
    id="${id#\'}"
    id="${id%\'}"
    case "$id" in
        arch|archlinux) printf 'arch' ;;
        cachyos) printf 'cachyos' ;;
        endeavouros) printf 'endeavouros' ;;
        manjaro|manjaro-arm) printf 'manjaro' ;;
        garuda) printf 'garuda' ;;
        artix) printf 'artix' ;;
        ubuntu) printf 'ubuntu' ;;
        debian) printf 'debian' ;;
        linuxmint|mint) printf 'mint' ;;
        pop|popos|pop_os) printf 'popos' ;;
        kali) printf 'kali' ;;
        elementary) printf 'elementary' ;;
        zorin) printf 'zorin' ;;
        neon) printf 'neon' ;;
        fedora) printf 'fedora' ;;
        nobara) printf 'nobara' ;;
        bazzite) printf 'bazzite' ;;
        rhel) printf 'rhel' ;;
        rocky) printf 'rocky' ;;
        almalinux|alma) printf 'almalinux' ;;
        centos) printf 'centos' ;;
        opensuse*|sles) printf 'opensuse' ;;
        nixos) printf 'nixos' ;;
        gentoo) printf 'gentoo' ;;
        void) printf 'void' ;;
        alpine) printf 'alpine' ;;
        solus) printf 'solus' ;;
        steamos) printf 'steamos' ;;
        slackware) printf 'slackware' ;;
        clear-linux-os|clearlinux) printf 'clearlinux' ;;
        tuxedo) printf 'tuxedo' ;;
        mx|mxlinux) printf 'mx' ;;
        *) printf '%s' "$id" ;;
    esac
}

inspect_root_os_release() {
    local options="$1"
    local fallback_partuuid="${2:-}"
    local root_spec="" subvol="" dev="" real_dev="" mnt="" osrel_txt=""
    if [[ "$options" =~ root=([^[:space:]]+) ]]; then
        root_spec="${BASH_REMATCH[1]}"
        dev="$(resolve_root_spec_device "$root_spec" 2>/dev/null || true)"
    fi
    if [[ -z "$dev" && -n "$fallback_partuuid" ]]; then
        dev="$(get_partuuid_device "$fallback_partuuid" 2>/dev/null || true)"
    fi
    [[ -n "$dev" && -b "$dev" ]] || return 1

    if [[ "$options" =~ subvol=([^[:space:],]+) ]]; then
        subvol="${BASH_REMATCH[1]}"
        subvol="${subvol#/}"
    fi

    real_dev="$(readlink -f "$dev" 2>/dev/null || printf '%s' "$dev")"
    local cache_key="${real_dev}|${subvol}"
    if [[ -n "${ROOT_OS_CACHE[$cache_key]+x}" ]]; then
        [[ -n "${ROOT_OS_CACHE[$cache_key]}" ]] || return 1
        printf '%s' "${ROOT_OS_CACHE[$cache_key]}"
        return 0
    fi

    mnt="$(find_partition_mount "$real_dev")"
    if [[ -n "$mnt" && -d "$mnt" ]]; then
        local prefix="$mnt"
        [[ -n "$subvol" && -d "$mnt/$subvol" ]] && prefix="$mnt/$subvol"
        if [[ -r "$prefix/etc/os-release" ]]; then
            osrel_txt="$(cat "$prefix/etc/os-release" 2>/dev/null || true)"
        elif [[ -r "$prefix/usr/lib/os-release" ]]; then
            osrel_txt="$(cat "$prefix/usr/lib/os-release" 2>/dev/null || true)"
        fi
    fi

    local fstype
    fstype="$(get_partition_type "$real_dev")"
    if [[ -z "$osrel_txt" && -n "$DEBUGFS_BIN" && ( "$fstype" == "ext4" || "$fstype" == "ext3" || "$fstype" == "ext2" ) ]]; then
        if (( EUID == 0 )); then
            osrel_txt="$("$DEBUGFS_BIN" -R "cat /etc/os-release" "$real_dev" 2>/dev/null || "$DEBUGFS_BIN" -R "cat /usr/lib/os-release" "$real_dev" 2>/dev/null || true)"
        else
            osrel_txt="$(sudo -n "$DEBUGFS_BIN" -R "cat /etc/os-release" "$real_dev" 2>/dev/null || sudo -n "$DEBUGFS_BIN" -R "cat /usr/lib/os-release" "$real_dev" 2>/dev/null || true)"
        fi
    fi

    if [[ -z "$osrel_txt" && -z "$mnt" && "$fstype" != "vfat" && "$fstype" != "fat" && "$fstype" != "ntfs" ]]; then
        local ro_mnt
        ro_mnt="$(mount_readonly_temp "$real_dev" "$fstype" 2>/dev/null || true)"
        if [[ -n "$ro_mnt" && -d "$ro_mnt" ]]; then
            local prefix="$ro_mnt"
            [[ -n "$subvol" && -d "$ro_mnt/$subvol" ]] && prefix="$ro_mnt/$subvol"
            if [[ -r "$prefix/etc/os-release" ]]; then
                osrel_txt="$(cat "$prefix/etc/os-release" 2>/dev/null || true)"
            elif [[ -r "$prefix/usr/lib/os-release" ]]; then
                osrel_txt="$(cat "$prefix/usr/lib/os-release" 2>/dev/null || true)"
            fi
        fi
    fi

    if [[ -z "$osrel_txt" ]]; then
        ROOT_OS_CACHE["$cache_key"]=""
        return 1
    fi

    local raw_id="" ver_id="" pretty=""
    raw_id="$(awk '{ idx = index($0, "="); if (idx > 0 && substr($0, 1, idx - 1) == "ID") { v = substr($0, idx + 1); gsub(/["'\'']/, "", v); print tolower(v); exit } }' <<< "$osrel_txt")"
    ver_id="$(awk '{ idx = index($0, "="); if (idx > 0 && substr($0, 1, idx - 1) == "VERSION_ID") { v = substr($0, idx + 1); gsub(/["'\'']/, "", v); print v; exit } }' <<< "$osrel_txt")"
    pretty="$(awk '{ idx = index($0, "="); if (idx > 0 && substr($0, 1, idx - 1) == "PRETTY_NAME") { v = substr($0, idx + 1); gsub(/["'\'']/, "", v); print v; exit } }' <<< "$osrel_txt")"
    local norm_id
    norm_id="$(normalize_distro_id "$raw_id")"
    local part_lbl
    part_lbl="$(get_partition_label "$real_dev" 2>/dev/null || true)"
    [[ -n "$part_lbl" ]] || part_lbl="${real_dev##*/}"

    local packed="${norm_id}|${ver_id}|${pretty}|${part_lbl}"
    ROOT_OS_CACHE["$cache_key"]="$packed"
    printf '%s' "$packed"
    return 0
}

detect_linux_distro() {
    local loader="${1,,}"
    local label="${2,,}"
    local version="${3,,}"
    local partuuid="${4:-}"
    local options="${5:-}"
    local uki_os_id="${6:-}"
    local combined="$loader $label $version"
    local os_id="" root_meta=""

    root_meta="$(inspect_root_os_release "$options" "$partuuid" 2>/dev/null || true)"
    if [[ -n "$root_meta" ]]; then
        os_id="${root_meta%%|*}"
        if [[ -n "$os_id" ]]; then
            printf '%s' "$os_id"
            return 0
        fi
    fi

    if [[ -n "$uki_os_id" ]]; then
        os_id="$(normalize_distro_id "$uki_os_id")"
        if [[ -n "$os_id" ]]; then
            printf '%s' "$os_id"
            return 0
        fi
    fi

    case "$combined" in
        *cachyos*) printf 'cachyos' ;;
        *endeavouros*|*endeavour*) printf 'endeavouros' ;;
        *manjaro*) printf 'manjaro' ;;
        *garuda*) printf 'garuda' ;;
        *artix*) printf 'artix' ;;
        *arch*|*-arch[0-9]*) printf 'arch' ;;
        *pop_os*|*pop-os*|*"pop!_os"*) printf 'popos' ;;
        *linuxmint*|*"linux mint"*|*mint*) printf 'mint' ;;
        *kali*) printf 'kali' ;;
        *elementary*) printf 'elementary' ;;
        *zorin*) printf 'zorin' ;;
        *"kde neon"*|*neon*) printf 'neon' ;;
        *tuxedo*) printf 'tuxedo' ;;
        *ubuntu*) printf 'ubuntu' ;;
        *debian*|*+deb[0-9]*|*-amd64*) printf 'debian' ;;
        *nobara*) printf 'nobara' ;;
        *bazzite*) printf 'bazzite' ;;
        *fedora*|*.fc[0-9]*) printf 'fedora' ;;
        *rocky*) printf 'rocky' ;;
        *almalinux*|*alma*) printf 'almalinux' ;;
        *centos*) printf 'centos' ;;
        *rhel*|*"red hat"*|*.el[0-9]*) printf 'rhel' ;;
        *opensuse*|*suse*|*tumbleweed*|*leap*) printf 'opensuse' ;;
        *nixos*|*nix-store*) printf 'nixos' ;;
        *gentoo*|*genkernel*) printf 'gentoo' ;;
        *void*) printf 'void' ;;
        *alpine*) printf 'alpine' ;;
        *solus*) printf 'solus' ;;
        *steamos*|*holoiso*|*chimeraos*) printf 'steamos' ;;
        *slackware*) printf 'slackware' ;;
        *clearlinux*|*clear-linux*) printf 'clearlinux' ;;
        *) printf '' ;;
    esac
}

macos_marketing_name() {
    local ver="$1"
    local label="${2,,}"
    if [[ "$ver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        local maj="${BASH_REMATCH[1]}"
        local min="${BASH_REMATCH[2]}"
        case "$maj" in
            26) printf 'macos tahoe'; return 0 ;;
            15) printf 'macos sequoia'; return 0 ;;
            14) printf 'macos sonoma'; return 0 ;;
            13) printf 'macos ventura'; return 0 ;;
            12) printf 'macos monterey'; return 0 ;;
            11) printf 'macos big sur'; return 0 ;;
            10)
                case "$min" in
                    15) printf 'macos catalina'; return 0 ;;
                    14) printf 'macos mojave'; return 0 ;;
                    13) printf 'macos high sierra'; return 0 ;;
                    12) printf 'macos sierra'; return 0 ;;
                esac
                ;;
        esac
    fi
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

detect_macos_details() {
    local partuuid="$1"
    local loader="$2"
    local label="$3"
    local prod_ver="" build_ver="" extra_tag="" mnt="" plist_file=""

    local -a search_roots=()
    if [[ -n "$partuuid" ]]; then
        local dev
        dev="$(get_partuuid_device "$partuuid" 2>/dev/null || true)"
        [[ -n "$dev" ]] && mnt="$(find_partition_mount "$dev")"
        [[ -n "$mnt" && -d "$mnt" ]] && search_roots+=("$mnt")
    fi
    if [[ -r /proc/mounts ]]; then
        local _src target fstype _rest
        while read -r _src target fstype _rest; do
            case "${fstype,,}" in
                apfs|hfsplus|hfs)
                    [[ -d "$target" ]] && search_roots+=("$target")
                    ;;
            esac
        done < /proc/mounts
    fi

    local root candidate
    for root in "${search_roots[@]:-}"; do
        [[ -n "$root" && -d "$root" ]] || continue
        if [[ -r "$root/System/Library/CoreServices/SystemVersion.plist" ]]; then
            plist_file="$root/System/Library/CoreServices/SystemVersion.plist"
            break
        fi
        for candidate in "$root"/*/System/Library/CoreServices/SystemVersion.plist; do
            if [[ -r "$candidate" ]]; then
                plist_file="$candidate"
                break 2
            fi
        done
    done

    if [[ -n "$plist_file" && -r "$plist_file" ]]; then
        prod_ver="$(awk '/<key>ProductVersion<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$plist_file" 2>/dev/null || true)"
        build_ver="$(awk '/<key>ProductBuildVersion<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$plist_file" 2>/dev/null || true)"
    fi

    local resolved
    resolved="$(resolve_esp_file "$partuuid" "$loader" 2>/dev/null || true)"
    if [[ -n "$resolved" && -r "$resolved" ]]; then
        if [[ "${loader,,}" == *opencore* ]]; then
            local oc_ver
            oc_ver="$(tr -d '\000' < "$resolved" 2>/dev/null | grep -aoE '(REL|DBG)-[0-9]{3}-[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -n 1 || true)"
            [[ -n "$oc_ver" ]] && extra_tag="OpenCore ${oc_ver}"
            local oc_cfg
            oc_cfg="$(resolve_esp_file "$partuuid" "/EFI/OC/config.plist" 2>/dev/null || true)"
            if [[ -n "$oc_cfg" && -r "$oc_cfg" ]]; then
                local smbios
                smbios="$(awk '/<key>SystemProductName<\/key>/{getline; gsub(/.*<string>|<\/string>.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit}' "$oc_cfg" 2>/dev/null || true)"
                [[ -n "$smbios" ]] && extra_tag="${extra_tag:+$extra_tag | }${smbios}"
            fi
        elif [[ "${loader,,}" == *clover* ]]; then
            local cl_ver
            cl_ver="$(tr -d '\000' < "$resolved" 2>/dev/null | grep -aoE 'Clover revision: [0-9]+' | head -n 1 | awk '{print "Clover r"$3}' || true)"
            [[ -n "$cl_ver" ]] && extra_tag="$cl_ver"
        fi
    fi

    local mac_name
    mac_name="$(macos_marketing_name "$prod_ver" "$label")"
    local mac_ver=""
    if [[ -n "$prod_ver" && -n "$build_ver" ]]; then
        mac_ver="${prod_ver} (${build_ver})"
    elif [[ -n "$prod_ver" ]]; then
        mac_ver="$prod_ver"
    fi
    if [[ -n "$extra_tag" ]]; then
        mac_ver="${mac_ver:+$mac_ver | }${extra_tag}"
    fi
    printf '%s|%s' "$mac_name" "$mac_ver"
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
        winserver2025|server2025|windows-server-2025) query="windows server 2025" ;;
        winserver2022|server2022|windows-server-2022) query="windows server 2022" ;;
        winserver2019|server2019|windows-server-2019) query="windows server 2019" ;;
        winserver2016|server2016|windows-server-2016) query="windows server 2016" ;;
        pop|pop-os|pop_os|"pop!_os") query="popos" ;;
        "linux mint"|linuxmint) query="mint" ;;
        "arch linux") query="arch" ;;
        "fedora linux") query="fedora" ;;
        "opensuse tumbleweed"|"opensuse leap") query="opensuse" ;;
        tahoe|"macos 26") query="macos tahoe" ;;
        sequoia|"macos 15") query="macos sequoia" ;;
        sonoma|"macos 14") query="macos sonoma" ;;
        ventura|"macos 13") query="macos ventura" ;;
        monterey|"macos 12") query="macos monterey" ;;
        "big sur"|"macos 11") query="macos big sur" ;;
        catalina|"macos 10.15") query="macos catalina" ;;
    esac
    for flavor in zen tkg lts hardened cachyos xanmod rt lowlatency liquorix bore mainline ck pf clear cfs tuxedo generic fallback virt edge huge; do
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
    if [[ "$token" == *"-fallback-"* || "$label_token" == *" fallback "* || "$label_token" == *"(fallback)"* || "$label_token" == *" rescue "* || "$token" == *"-rescue-"* ]]; then
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
    elif [[ "$token" == *"-virt-"* || "$label_token" == *" virt "* ]]; then
        flavor="virt"
    elif [[ "$token" == *"-edge-"* || "$label_token" == *" edge "* ]]; then
        flavor="edge"
    elif [[ "$token" == *"-huge-"* || "$label_token" == *" huge "* ]]; then
        flavor="huge"
    elif [[ "$token" == *"-rt-"* || "$token" == *"-realtime-"* || "$label_token" == *" real-time "* || "$label_token" == *" realtime "* || "$label_token" == *" linux rt "* ]]; then
        flavor="rt"
    else
        case "$base" in
            vmlinuz*|bzimage*|linux|linux.efi|linux-*.efi|*-linux.efi|*-linux-*.efi|kernel|kernel-*|kernel.efi|kernel-*.efi|image.efi|*.uki)
                flavor="default"
                ;;
            *)
                if [[ "$loader" == *"/efi/linux/"* || "$loader" == *"/efi/nixos/"* || "$loader" == *"/efi/pop_os"* || "$loader" == *"/efi/com.solus-project/"* ]]; then
                    flavor="default"
                elif [[ "$label_token" == *" linux "* || "$label_token" == *" arch "* || "$label_token" == *" ubuntu "* || "$label_token" == *" debian "* || "$label_token" == *" fedora "* || "$label_token" == *" opensuse "* || "$label_token" == *" gentoo "* || "$label_token" == *" nixos "* || "$label_token" == *" void "* || "$label_token" == *" alpine "* || "$label_token" == *" manjaro "* || "$label_token" == *" endeavour"* || "$label_token" == *" garuda "* || "$label_token" == *" steamos "* || "$label_token" == *" mint "* || "$label_token" == *" pop!_os "* || "$label_token" == *" kali "* || "$label_token" == *" rocky "* || "$label_token" == *" alma"* || "$label_token" == *" centos "* || "$label_token" == *" nobara "* || "$label_token" == *" bazzite "* || "$label_token" == *" solus "* || "$label_token" == *" slackware "* ]]; then
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
    local out_loader="" out_opts=""
    if [[ "$raw_tail" == *$'\t'* ]]; then
        out_loader="${raw_tail%%$'\t'*}"
        out_opts="${raw_tail#*$'\t'}"
    elif [[ "$raw_tail" =~ ^(.+\.[Ee][Ff][Ii])(.*)$ ]]; then
        out_loader="${BASH_REMATCH[1]}"
        out_opts="${BASH_REMATCH[2]:-}"
    elif [[ "$raw_tail" =~ ^(.+\.[Uu][Kk][Ii])(.*)$ ]]; then
        out_loader="${BASH_REMATCH[1]}"
        out_opts="${BASH_REMATCH[2]:-}"
    elif [[ "$raw_tail" =~ (([0-7][0-9a-fA-F]00){3,}([0-9a-fA-F]{2}00)*([0-9a-fA-F]{2})*)$ ]]; then
        out_opts="${BASH_REMATCH[1]}"
        out_loader="${raw_tail%"$out_opts"}"
    elif [[ "$raw_tail" =~ (57494e444f575300[0-9a-fA-F]*)$ ]]; then
        out_opts="${BASH_REMATCH[1]}"
        out_loader="${raw_tail%"$out_opts"}"
    elif [[ "$raw_tail" =~ ^([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
        out_loader="${BASH_REMATCH[1]}"
        out_opts="${BASH_REMATCH[2]}"
    else
        out_loader="${raw_tail%"${raw_tail##*[![:space:]]}"}"
        out_opts=""
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
    local distro="${12:-}"
    local extra="${13:-}"
    local is_def="${14:-0}"
    local i
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ "${TARGET_BACKENDS[i]}" == "$backend" && "${TARGET_IDS[i]}" == "$id" ]]; then
            return 0
        fi
        if [[ "$backend" != "winbcd" && "${TARGET_BACKENDS[i]}" != "winbcd" ]]; then
            if [[ "${TARGET_LOADERS[i],,}" == "${loader,,}" && "${TARGET_PARTUUIDS[i],,}" == "${partuuid,,}" && "${TARGET_OPTIONS[i]}" == "$options" ]]; then
                if [[ "${TARGET_BACKENDS[i]}" == "$backend" ]]; then
                    if [[ "$active" == "1" && "${TARGET_ACTIVE[i]}" != "1" ]]; then
                        TARGET_IDS[i]="$id"
                        TARGET_ACTIVE[i]="$active"
                        TARGET_LABELS[i]="$label"
                        TARGET_OPTIONS[i]="$options"
                        TARGET_DEFAULT[i]="$is_def"
                    fi
                    return 0
                elif [[ "${TARGET_BACKENDS[i]}" == "uefi" ]]; then
                    return 0
                fi
            fi
        fi
    done
    (( ${#TARGET_IDS[@]} < MAX_TARGETS )) || return 0
    TARGET_BACKENDS+=("$backend")
    TARGET_IDS+=("$id")
    TARGET_ACTIVE+=("$active")
    TARGET_DEFAULT+=("$is_def")
    TARGET_LABELS+=("${label//$'\n'/ }")
    TARGET_LOADERS+=("$loader")
    TARGET_PARTUUIDS+=("$partuuid")
    TARGET_OPTIONS+=("$options")
    TARGET_FAMILIES+=("$family")
    TARGET_FLAVORS+=("$flavor")
    TARGET_NAMES+=("$name")
    TARGET_VERSIONS+=("$version")
    TARGET_DISTROS+=("$distro")
    TARGET_EXTRA+=("$extra")
}

disambiguate_duplicate_targets() {
    local i total=${#TARGET_IDS[@]}
    local -A sig_counts=()
    local sig root_meta part_lbl short_dev
    for ((i=0; i<total; i++)); do
        sig="${TARGET_NAMES[i]}|${TARGET_VERSIONS[i]}"
        sig_counts["$sig"]=$(( ${sig_counts["$sig"]:-0} + 1 ))
    done
    for ((i=0; i<total; i++)); do
        sig="${TARGET_NAMES[i]}|${TARGET_VERSIONS[i]}"
        if (( ${sig_counts["$sig"]} > 1 )); then
            part_lbl=""
            if [[ "${TARGET_FAMILIES[i]}" == "linux" ]]; then
                root_meta="$(inspect_root_os_release "${TARGET_OPTIONS[i]}" "${TARGET_PARTUUIDS[i]}" 2>/dev/null || true)"
                if [[ -n "$root_meta" ]]; then
                    part_lbl="${root_meta##*|}"
                fi
            fi
            if [[ -z "$part_lbl" && -n "${TARGET_PARTUUIDS[i]}" ]]; then
                short_dev="$(get_partuuid_device "${TARGET_PARTUUIDS[i]}" 2>/dev/null || true)"
                if [[ -n "$short_dev" ]]; then
                    part_lbl="$(get_partition_label "$short_dev" 2>/dev/null || true)"
                    [[ -n "$part_lbl" ]] || part_lbl="$(readlink -f "$short_dev" 2>/dev/null | awk -F'/' '{print $NF}')"
                fi
            fi
            if [[ -n "$part_lbl" ]]; then
                if [[ -n "${TARGET_VERSIONS[i]}" ]]; then
                    TARGET_VERSIONS[i]="${TARGET_VERSIONS[i]} [${part_lbl}]"
                else
                    TARGET_VERSIONS[i]="[${part_lbl}]"
                fi
            fi
        fi
    done
}

register_windows_targets_from_esp() {
    local esp_partuuid="$1"
    local default_uefi_id="$2"
    local default_active="$3"
    local default_label="$4"
    local default_loader="$5"
    local bcd_lines=""
    bcd_lines="$(parse_windows_bcd_entries "$esp_partuuid" 2>/dev/null || true)"
    local -a entries=()
    if [[ -n "$bcd_lines" ]]; then
        mapfile -t entries <<< "$bcd_lines"
    fi
    if (( ${#entries[@]} >= 2 )); then
        local entry_line guid is_def desc win_part sys_root app_path part_info win_ver win_prod win_disp win_ed win_inst os_name display_ver short_guid iso_loader iso_existing_id part_lbl ver_src
        for entry_line in "${entries[@]}"; do
            IFS='|' read -r guid is_def desc win_part sys_root app_path <<< "$entry_line"
            [[ -n "$guid" ]] || continue
            win_ver=""
            win_prod=""
            win_disp=""
            win_ed=""
            win_inst=""
            ver_src="os"
            part_info="$(inspect_windows_os_partition "$win_part" "$sys_root" 2>/dev/null || true)"
            if [[ -n "$part_info" ]]; then
                win_ver="$(kv_get "$part_info" "VERSION" || true)"
                win_prod="$(kv_get "$part_info" "PRODUCT_NAME" || true)"
                win_disp="$(kv_get "$part_info" "DISPLAY_VERSION" || true)"
                win_ed="$(kv_get "$part_info" "EDITION_ID" || true)"
                win_inst="$(kv_get "$part_info" "INST_TYPE" || true)"
            fi
            if [[ -z "$win_ver" ]]; then
                win_ver="$(get_windows_version "$esp_partuuid" "$default_loader" 2>/dev/null || true)"
                ver_src="loader"
            fi
            os_name="$(map_windows_version "$win_ver" "$win_prod $desc $default_label" "$win_ed" "$win_inst" "$ver_src" 2>/dev/null || true)"
            if [[ -z "$os_name" ]]; then
                case "${win_prod,,} ${desc,,} ${default_label,,}" in
                    *"windows 10"*) os_name="windows 10" ;;
                    *"windows 11"*) os_name="windows 11" ;;
                    *"windows server 2025"*) os_name="windows server 2025" ;;
                    *"windows server 2022"*) os_name="windows server 2022" ;;
                    *"windows server 2019"*) os_name="windows server 2019" ;;
                    *"windows server 2016"*) os_name="windows server 2016" ;;
                    *"windows 8.1"*) os_name="windows 8.1" ;;
                    *"windows 8"*) os_name="windows 8" ;;
                    *"windows 7"*) os_name="windows 7" ;;
                    *) os_name="windows unknown" ;;
                esac
            fi
            if [[ "$ver_src" == "loader" && "$os_name" == "windows 10"* && "$win_ver" =~ ^10\.0\.([0-9]+) && "${BASH_REMATCH[1]}" -ge 22000 ]]; then
                display_ver=""
            else
                display_ver="$(format_windows_display_version "$win_ver" "$win_disp")"
            fi
            if [[ -n "$win_part" ]]; then
                local wdev
                wdev="$(get_partuuid_device "$win_part" 2>/dev/null || true)"
                part_lbl=""
                [[ -n "$wdev" ]] && part_lbl="$(get_partition_label "$wdev" 2>/dev/null || true)"
                [[ -z "$part_lbl" && -n "$wdev" ]] && part_lbl="$(readlink -f "$wdev" 2>/dev/null | awk -F'/' '{print $NF}')"
                if [[ -n "$part_lbl" ]]; then
                    display_ver="${display_ver:+$display_ver | }${part_lbl}:${sys_root}"
                else
                    display_ver="${display_ver:+$display_ver | }${sys_root}"
                fi
            elif [[ -n "$sys_root" && "${sys_root,,}" != "\\windows" ]]; then
                display_ver="${display_ver:+$display_ver | }${sys_root}"
            fi
            short_guid="${guid//[\{\}-]/}"
            short_guid="${short_guid:0:8}"
            iso_loader="/EFI/multiboot-win-${short_guid}/bootmgfw.efi"
            iso_existing_id=""
            iso_existing_id="$(EFI_SEARCH_PATH="\\efi\\multiboot-win-${short_guid}\\bootmgfw.efi" awk '
                BEGIN { p = tolower(ENVIRON["EFI_SEARCH_PATH"]) }
                /^Boot[0-9A-Fa-f]{4}/ {
                    if (index(tolower($0), p) > 0) {
                        print toupper(substr($0, 5, 4))
                        exit
                    }
                }
            ' <<< "$EFI_OUTPUT")"
            if [[ -n "$iso_existing_id" ]] && entry_file_exists "$esp_partuuid" "$iso_loader"; then
                add_target uefi "$iso_existing_id" "1" "${desc} (${sys_root})" "$iso_loader" "$esp_partuuid" "" "windows" "bcd-isolated" "$os_name" "$display_ver" "windows" "${guid}|${win_part}|${sys_root}" "$is_def"
            else
                add_target winbcd "bcd-${short_guid}" "$default_active" "${desc} (${sys_root})" "$default_loader" "$esp_partuuid" "" "windows" "bcd-merged" "$os_name" "$display_ver" "windows" "${guid}|${win_part}|${sys_root}" "$is_def"
            fi
        done
        return 0
    fi

    local win_part="" sys_root="\\Windows" desc="$default_label" win_ver="" win_prod="" win_disp="" win_ed="" win_inst="" os_name="" display_ver="" ver_src="os" is_def="1"
    if (( ${#entries[@]} == 1 )); then
        IFS='|' read -r _ is_def desc win_part sys_root _ <<< "${entries[0]}"
    fi
    local part_info
    part_info="$(inspect_windows_os_partition "$win_part" "$sys_root" 2>/dev/null || true)"
    if [[ -n "$part_info" ]]; then
        win_ver="$(kv_get "$part_info" "VERSION" || true)"
        win_prod="$(kv_get "$part_info" "PRODUCT_NAME" || true)"
        win_disp="$(kv_get "$part_info" "DISPLAY_VERSION" || true)"
        win_ed="$(kv_get "$part_info" "EDITION_ID" || true)"
        win_inst="$(kv_get "$part_info" "INST_TYPE" || true)"
    fi
    if [[ -z "$win_ver" ]]; then
        win_ver="$(get_windows_version "$esp_partuuid" "$default_loader" 2>/dev/null || true)"
        ver_src="loader"
    fi
    os_name="$(map_windows_version "$win_ver" "$win_prod $desc $default_label" "$win_ed" "$win_inst" "$ver_src" 2>/dev/null || true)"
    if [[ -z "$os_name" ]]; then
        case "${win_prod,,} ${desc,,} ${default_label,,}" in
            *"windows 10"*) os_name="windows 10" ;;
            *"windows 11"*) os_name="windows 11" ;;
            *"windows server 2025"*) os_name="windows server 2025" ;;
            *"windows server 2022"*) os_name="windows server 2022" ;;
            *"windows server 2019"*) os_name="windows server 2019" ;;
            *"windows server 2016"*) os_name="windows server 2016" ;;
            *"windows 8.1"*) os_name="windows 8.1" ;;
            *"windows 8"*) os_name="windows 8" ;;
            *"windows 7"*) os_name="windows 7" ;;
            *) os_name="windows unknown" ;;
        esac
    fi
    if [[ "$ver_src" == "loader" && "$os_name" == "windows 10"* && "$win_ver" =~ ^10\.0\.([0-9]+) && "${BASH_REMATCH[1]}" -ge 22000 ]]; then
        display_ver=""
    else
        display_ver="$(format_windows_display_version "$win_ver" "$win_disp")"
    fi
    if [[ -n "$default_uefi_id" ]]; then
        add_target uefi "$default_uefi_id" "$default_active" "${desc:-$default_label}" "$default_loader" "$esp_partuuid" "" "windows" "unknown" "$os_name" "$display_ver" "windows" "" "$is_def"
    else
        add_target sdboot "auto-windows" "$SDBOOT_MANAGER_ACTIVE" "${desc:-Windows Boot Manager}" "$default_loader" "$esp_partuuid" "" "windows" "unknown" "$os_name" "$display_ver" "windows" "" "$is_def"
    fi
}

get_efi_output() {
    if [[ -n "$EFI_OUTPUT" ]]; then
        printf '%s' "$EFI_OUTPUT"
        return 0
    fi
    local output=""
    if [[ -n "$EFI_BIN" ]]; then
        if (( EUID == 0 )); then
            output="$("$EFI_BIN" -v 2>/dev/null || true)"
        else
            output="$(sudo -n "$EFI_BIN" -v 2>/dev/null || "$EFI_BIN" -v 2>/dev/null || true)"
        fi
    fi
    EFI_OUTPUT="$output"
    printf '%s' "$output"
}

get_sdboot_current_entry() {
    local efivar="/sys/firmware/efi/efivars/LoaderEntrySelected-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    if [[ -r "$efivar" ]]; then
        tail -c +5 "$efivar" 2>/dev/null | tr -d '\000' || true
    fi
}

parse_uefi_entries() {
    local line id active rest label loader partuuid options base flavor version name family raw_tail split_pair distro uki_meta uki_cmd uki_uname uki_os_id first_boot_id=""
    local file_pattern='File\(([^)]*)\)'
    local hd_pattern='HD\([^)]*\)/([\\/].*)$'
    EFI_OUTPUT=""
    EFI_OUTPUT="$(get_efi_output)"
    BOOT_CURRENT_ID="$(awk -F': *' '/^BootCurrent:/ {gsub(/[^0-9A-Fa-f]/, "", $2); print toupper($2); exit}' <<< "$EFI_OUTPUT")"
    BOOT_NEXT_ID="$(awk -F': *' '/^BootNext:/ {gsub(/[^0-9A-Fa-f]/, "", $2); print toupper($2); exit}' <<< "$EFI_OUTPUT")"
    BOOT_ORDER_STR="$(awk -F': *' '/^BootOrder:/ {print $2; exit}' <<< "$EFI_OUTPUT")"
    first_boot_id="${BOOT_ORDER_STR%%,*}"
    first_boot_id="${first_boot_id//[^0-9A-Fa-f]/}"
    first_boot_id="${first_boot_id^^}"
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
        label="$(printf '%s' "$rest" | sed -E 's/[[:space:]]+(HD|PciRoot|VenHw|VenMedia|Acpi|Fv|FvVol|FvFile|Offset|MediaPath|MemoryMapped|URI|Usb|Ata|Scsi|NVMe|Sata|CDROM|Floppy|MAC|IPv4|IPv6)\(.*$//')"
        label="${label:-UEFI Entry}"
        [[ -n "$loader" ]] || continue
        base="${loader##*/}"
        base="${base,,}"

        if [[ "$base" == bootx64.efi || "$base" == bootaa64.efi || "$base" == bootia32.efi ]]; then
            local mgr_sig
            mgr_sig="$(identify_efi_manager_type "$partuuid" "$loader" 2>/dev/null || true)"
            case "$mgr_sig" in
                systemd-boot)
                    if [[ "$active" == "1" || -z "$SDBOOT_MANAGER_ID" ]]; then
                        SDBOOT_MANAGER_ID="$id"; SDBOOT_MANAGER_ACTIVE="$active"
                    fi
                    ;;
                grub)
                    if [[ "$active" == "1" || -z "$GRUB_MANAGER_ID" ]]; then
                        GRUB_MANAGER_ID="$id"; GRUB_MANAGER_ACTIVE="$active"
                        GRUB_MANAGER_PARTUUID="$partuuid"; GRUB_MANAGER_LOADER="$loader"
                    fi
                    ;;
                refind)
                    if [[ "$active" == "1" || -z "$REFIND_MANAGER_ID" ]]; then
                        REFIND_MANAGER_ID="$id"; REFIND_MANAGER_ACTIVE="$active"
                        REFIND_MANAGER_PARTUUID="$partuuid"; REFIND_MANAGER_LOADER="$loader"
                    fi
                    ;;
                limine)
                    if [[ "$active" == "1" || -z "$LIMINE_MANAGER_ID" ]]; then
                        LIMINE_MANAGER_ID="$id"; LIMINE_MANAGER_ACTIVE="$active"
                    fi
                    ;;
            esac
            continue
        fi

        if [[ "$base" == systemd-bootx64.efi || "$base" == systemd-bootaa64.efi || "$base" == systemd-bootia32.efi ]]; then
            if [[ "$active" == "1" || -z "$SDBOOT_MANAGER_ID" ]]; then
                SDBOOT_MANAGER_ID="$id"
                SDBOOT_MANAGER_ACTIVE="$active"
            fi
            continue
        fi
        if [[ "$base" == grubx64.efi || "$base" == grubaa64.efi || "$base" == grubia32.efi || "$base" == shimx64.efi || "$base" == shimaa64.efi ]]; then
            if [[ "$active" == "1" || -z "$GRUB_MANAGER_ID" ]]; then
                GRUB_MANAGER_ID="$id"
                GRUB_MANAGER_ACTIVE="$active"
                GRUB_MANAGER_PARTUUID="$partuuid"
                GRUB_MANAGER_LOADER="$loader"
            fi
            continue
        fi
        if [[ "$base" == refind_x64.efi || "$base" == refind_aa64.efi || "$base" == refind_ia32.efi || "$base" == refind*.efi ]]; then
            if [[ "$active" == "1" || -z "$REFIND_MANAGER_ID" ]]; then
                REFIND_MANAGER_ID="$id"
                REFIND_MANAGER_ACTIVE="$active"
                REFIND_MANAGER_PARTUUID="$partuuid"
                REFIND_MANAGER_LOADER="$loader"
            fi
            continue
        fi
        if [[ "$base" == limine*.efi ]]; then
            if [[ "$active" == "1" || -z "$LIMINE_MANAGER_ID" ]]; then
                LIMINE_MANAGER_ID="$id"
                LIMINE_MANAGER_ACTIVE="$active"
            fi
            continue
        fi
        case "$base" in
            fwupd*.efi|mmx64.efi|mmaa64.efi|mokmanager*.efi|shell*.efi|memtest*.efi)
                continue
                ;;
        esac
        if [[ "${loader,,}" == *"/efi/multiboot-win-"*"/bootmgfw.efi" ]]; then
            continue
        fi
        family=""
        flavor=""
        name=""
        version=""
        distro=""
        local is_def="0"
        [[ -n "$first_boot_id" && "$id" == "$first_boot_id" ]] && is_def="1"
        if [[ "$base" == bootmgfw.efi || "$base" == bootmgr.efi ]]; then
            register_windows_targets_from_esp "$partuuid" "$id" "$active" "$label" "$loader"
            continue
        elif [[ "$base" == boot.efi || "$base" == opencore.efi || "$base" == opencore*.efi || "$base" == clover*.efi || "${label,,}" == *macos* || "${label,,}" == *"mac os"* || "${label,,}" == *"os x"* || "${label,,}" == *opencore* || "${label,,}" == *clover* ]]; then
            family="macos"
            local mac_info
            mac_info="$(detect_macos_details "$partuuid" "$loader" "$label" 2>/dev/null || true)"
            name="${mac_info%%|*}"
            version="${mac_info#*|}"
            [[ -n "$name" ]] || name="macos"
            distro="macos"
        else
            flavor="$(classify_linux_loader "$loader" "$label" 2>/dev/null || true)"
            if [[ -n "$flavor" ]]; then
                family="linux"
                uki_cmd=""
                uki_uname=""
                uki_os_id=""
                if [[ "${loader,,}" == *.efi || "${loader,,}" == *.uki ]]; then
                    uki_meta="$(get_uki_metadata "$partuuid" "$loader" 2>/dev/null || true)"
                    if [[ -n "$uki_meta" ]]; then
                        uki_cmd="$(kv_get "$uki_meta" "CMDLINE" || true)"
                        uki_uname="$(kv_get "$uki_meta" "UNAME" || true)"
                        uki_os_id="$(kv_get "$uki_meta" "OS_ID" || true)"
                        [[ -z "$options" && -n "$uki_cmd" ]] && options="$uki_cmd"
                    fi
                fi
                version="$(get_linux_version "$partuuid" "$loader" "$uki_uname" 2>/dev/null || true)"
                distro="$(detect_linux_distro "$loader" "$label" "$version" "$partuuid" "$options" "$uki_os_id" 2>/dev/null || true)"
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
                if [[ -n "$distro" ]]; then
                    if [[ "$flavor" == "default" ]]; then
                        name="$distro linux"
                    else
                        name="$distro linux $flavor"
                    fi
                else
                    if [[ "$flavor" == "default" ]]; then
                        name="linux"
                    else
                        name="linux $flavor"
                    fi
                fi
            fi
        fi
        [[ -n "$family" ]] || continue
        add_target uefi "$id" "$active" "$label" "$loader" "$partuuid" "$options" "$family" "${flavor:-unknown}" "$name" "$version" "$distro" "" "$is_def"
        if (( ${#TARGET_IDS[@]} >= MAX_TARGETS )); then
            break
        fi
    done <<< "$EFI_OUTPUT"
}

process_bootctl_record() {
    local cur_id="$1"
    local cur_title="$2"
    local cur_linux="$3"
    local cur_efi="$4"
    local cur_opts="$5"
    local cur_partuuid="$6"
    local cur_def="${7:-0}"
    [[ -n "$cur_id" && -n "${cur_linux:-$cur_efi}" ]] || return 0
    local loader="${cur_linux:-$cur_efi}" base flavor name version family detected_flavor distro uki_meta uki_uname uki_os_id
    base="${loader##*/}"
    base="${base,,}"
    family=""
    flavor="unknown"
    version=""
    distro=""
    if [[ "$cur_id" == "auto-windows" || "$base" == bootmgfw.efi ]]; then
        register_windows_targets_from_esp "$cur_partuuid" "" "$SDBOOT_MANAGER_ACTIVE" "${cur_title:-Windows Boot Manager}" "$loader"
        return 0
    elif [[ "$cur_id" == "auto-osx" || "$base" == boot.efi ]]; then
        family="macos"
        local mac_info
        mac_info="$(detect_macos_details "$cur_partuuid" "$loader" "$cur_title" 2>/dev/null || true)"
        name="${mac_info%%|*}"
        version="${mac_info#*|}"
        [[ -n "$name" ]] || name="macos"
        distro="macos"
    else
        flavor="$(classify_linux_loader "$loader" "$cur_title" 2>/dev/null || true)"
        if [[ -n "$flavor" ]]; then
            family="linux"
            uki_uname=""
            uki_os_id=""
            if [[ "${loader,,}" == *.efi || "${loader,,}" == *.uki ]]; then
                uki_meta="$(get_uki_metadata "$cur_partuuid" "$loader" 2>/dev/null || true)"
                if [[ -n "$uki_meta" ]]; then
                    uki_uname="$(kv_get "$uki_meta" "UNAME" || true)"
                    uki_os_id="$(kv_get "$uki_meta" "OS_ID" || true)"
                    if [[ -z "$cur_opts" ]]; then
                        cur_opts="$(kv_get "$uki_meta" "CMDLINE" || true)"
                    fi
                fi
            fi
            version="$(get_linux_version "$cur_partuuid" "$loader" "$uki_uname" 2>/dev/null || true)"
            distro="$(detect_linux_distro "$loader" "$cur_title" "$version" "$cur_partuuid" "$cur_opts" "$uki_os_id" 2>/dev/null || true)"
            if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                detected_flavor="$(classify_linux_version "$version" "$cur_title" 2>/dev/null || true)"
                if [[ -n "$detected_flavor" ]]; then
                    [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                fi
            fi
            if [[ -n "$distro" ]]; then
                [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
            else
                [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
            fi
        fi
    fi
    if [[ -n "$family" ]]; then
        add_target sdboot "$cur_id" "$SDBOOT_MANAGER_ACTIVE" "${cur_title:-$cur_id}" "$loader" "$cur_partuuid" "$cur_opts" "$family" "$flavor" "$name" "$version" "$distro" "" "$cur_def"
    fi
}

parse_bootctl_entries() {
    [[ -n "$BOOTCTL_BIN" && -n "$SDBOOT_MANAGER_ID" ]] || return 0
    local list_out line cur_id="" cur_title="" cur_linux="" cur_efi="" cur_opts="" cur_partuuid="" cur_def="0"
    list_out="$("$BOOTCTL_BIN" list 2>/dev/null || true)"
    [[ -n "$list_out" ]] || return 0
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*id:[[:space:]]*(.+)$ ]]; then
            process_bootctl_record "$cur_id" "$cur_title" "$cur_linux" "$cur_efi" "$cur_opts" "$cur_partuuid" "$cur_def"
            cur_id="${BASH_REMATCH[1]}"
            cur_title=""
            cur_linux=""
            cur_efi=""
            cur_opts=""
            cur_partuuid=""
            cur_def="0"
        elif [[ "$line" =~ ^[[:space:]]*is-default:[[:space:]]*yes ]]; then
            cur_def="1"
        elif [[ "$line" =~ ^[[:space:]]*title:[[:space:]]*(.+)$ ]]; then
            cur_title="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*linux:[[:space:]]*(.+)$ ]]; then
            cur_linux="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*efi:[[:space:]]*(.+)$ ]]; then
            cur_efi="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*options:[[:space:]]*(.+)$ ]]; then
            cur_opts="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^[[:space:]]*source:[[:space:]]*(.+)$ ]]; then
            local src_path="${BASH_REMATCH[1]}"
            if [[ -e "$src_path" ]] && command -v findmnt >/dev/null 2>&1; then
                local src_dev
                src_dev="$(findmnt -rn -T "$src_path" -o SOURCE 2>/dev/null | head -n 1 || true)"
                src_dev="${src_dev%%\[*}"
                if [[ -n "$src_dev" ]] && command -v blkid >/dev/null 2>&1; then
                    cur_partuuid="$(blkid -s PARTUUID -o value "$src_dev" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
                fi
            fi
        fi
    done <<< "$list_out"
    process_bootctl_record "$cur_id" "$cur_title" "$cur_linux" "$cur_efi" "$cur_opts" "$cur_partuuid" "$cur_def"
}

parse_systemd_boot_entries() {
    local mountpoint directory file dropin id title linux_image efi_image loader options initrd_line flavor name version source partuuid base family detected_flavor uki_dir uki_file win_boot distro uki_meta uki_uname uki_os_id
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
        if [[ -d "$directory" && -n "$SDBOOT_MANAGER_ID" ]]; then
            for file in "$directory"/*.conf; do
                [[ -f "$file" ]] || continue
                id="${file##*/}"
                title="$(awk 'tolower($1)=="title" { $1=""; sub(/^[[:space:]]+/,""); print; exit }' "$file")"
                linux_image="$(awk 'tolower($1)=="linux" { print $2; exit }' "$file")"
                efi_image="$(awk 'tolower($1)=="efi" { print $2; exit }' "$file")"
                options="$(awk 'tolower($1)=="options" { $1=""; sub(/^[[:space:]]+/,""); out = (out ? out " " $0 : $0) } END { print out }' "$file")"
                mapfile -t initrds < <(awk 'tolower($1)=="initrd" { print $2 }' "$file")
                if [[ -d "${file}.d" ]]; then
                    for dropin in "${file}.d"/*.conf; do
                        [[ -f "$dropin" ]] || continue
                        local d_opts
                        d_opts="$(awk 'tolower($1)=="options" { $1=""; sub(/^[[:space:]]+/,""); out = (out ? out " " $0 : $0) } END { print out }' "$dropin")"
                        [[ -n "$d_opts" ]] && options="${options:+$options }${d_opts}"
                    done
                fi
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
                distro=""
                if [[ "$base" == bootmgfw.efi || "$base" == bootmgr.efi ]]; then
                    register_windows_targets_from_esp "$partuuid" "" "$SDBOOT_MANAGER_ACTIVE" "${title:-Windows Boot Manager}" "$loader"
                    continue
                elif [[ "$base" == boot.efi || "$base" == opencore.efi || "$base" == opencore*.efi || "$base" == clover*.efi || "${title,,}" == *macos* || "${title,,}" == *"mac os"* || "${title,,}" == *"os x"* || "${title,,}" == *opencore* || "${title,,}" == *clover* ]]; then
                    family="macos"
                    local mac_info
                    mac_info="$(detect_macos_details "$partuuid" "$loader" "$title" 2>/dev/null || true)"
                    name="${mac_info%%|*}"
                    version="${mac_info#*|}"
                    [[ -n "$name" ]] || name="macos"
                    distro="macos"
                else
                    flavor="$(classify_linux_loader "$loader" "$title" 2>/dev/null || true)"
                    [[ -n "$flavor" ]] || continue
                    family="linux"
                    uki_uname=""
                    uki_os_id=""
                    if [[ "${loader,,}" == *.efi || "${loader,,}" == *.uki ]]; then
                        uki_meta="$(get_uki_metadata "$partuuid" "$loader" 2>/dev/null || true)"
                        if [[ -n "$uki_meta" ]]; then
                            uki_uname="$(kv_get "$uki_meta" "UNAME" || true)"
                            uki_os_id="$(kv_get "$uki_meta" "OS_ID" || true)"
                            if [[ -z "$options" ]]; then
                                options="$(kv_get "$uki_meta" "CMDLINE" || true)"
                            fi
                        fi
                    fi
                    version="$(get_linux_version "$partuuid" "$loader" "$uki_uname" 2>/dev/null || true)"
                    distro="$(detect_linux_distro "$loader" "$title $id" "$version" "$partuuid" "$options" "$uki_os_id" 2>/dev/null || true)"
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
                    if [[ -n "$distro" ]]; then
                        [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
                    else
                        [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
                    fi
                fi
                add_target sdboot "$id" "$SDBOOT_MANAGER_ACTIVE" "${title:-$id}" "$loader" "$partuuid" "$options" "$family" "$flavor" "$name" "$version" "$distro" "" "0"
                (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
            done
        fi
        if [[ -n "$SDBOOT_MANAGER_ID" ]]; then
            uki_dir=""
            local d1 d2
            for d1 in "$mountpoint"/*; do
                [[ -d "$d1" && "${d1##*/}" =~ ^[Ee][Ff][Ii]$ ]] || continue
                for d2 in "$d1"/*; do
                    if [[ -d "$d2" && "${d2##*/}" =~ ^[Ll][Ii][Nn][Uu][Xx]$ ]]; then
                        uki_dir="$d2"
                        break 2
                    fi
                done
            done
            if [[ -n "$uki_dir" && -d "$uki_dir" ]]; then
                for uki_file in "$uki_dir"/*.efi "$uki_dir"/*.uki; do
                    [[ -f "$uki_file" ]] || continue
                    id="${uki_file##*/}"
                    loader="/EFI/Linux/$id"
                    flavor="$(classify_linux_loader "$loader" "$id" 2>/dev/null || true)"
                    [[ -n "$flavor" ]] || continue
                    local uki_cmd=""
                    uki_uname=""
                    uki_os_id=""
                    uki_meta="$(get_uki_metadata "$partuuid" "$loader" 2>/dev/null || true)"
                    if [[ -n "$uki_meta" ]]; then
                        uki_cmd="$(kv_get "$uki_meta" "CMDLINE" || true)"
                        uki_uname="$(kv_get "$uki_meta" "UNAME" || true)"
                        uki_os_id="$(kv_get "$uki_meta" "OS_ID" || true)"
                    fi
                    version="$(get_linux_version "$partuuid" "$loader" "$uki_uname" 2>/dev/null || true)"
                    distro="$(detect_linux_distro "$loader" "$id" "$version" "$partuuid" "$uki_cmd" "$uki_os_id" 2>/dev/null || true)"
                    if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                        detected_flavor="$(classify_linux_version "$version" "$id" 2>/dev/null || true)"
                        if [[ -n "$detected_flavor" ]]; then
                            [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                        fi
                    fi
                    if [[ -n "$distro" ]]; then
                        [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
                    else
                        [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
                    fi
                    add_target sdboot "$id" "$SDBOOT_MANAGER_ACTIVE" "$id" "$loader" "$partuuid" "$uki_cmd" "linux" "$flavor" "$name" "$version" "$distro" "" "0"
                    (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
                done
            fi
            win_boot="$(resolve_case_insensitive_file "$mountpoint" "EFI/Microsoft/Boot/bootmgfw.efi" 2>/dev/null || true)"
            if [[ -n "$win_boot" ]]; then
                register_windows_targets_from_esp "$partuuid" "" "$SDBOOT_MANAGER_ACTIVE" "Windows Boot Manager" "/EFI/Microsoft/Boot/bootmgfw.efi"
                (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
            fi
        fi
    done < <(find_esp_mounts)
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_bootctl_entries
    fi
}

parse_grub_entries() {
    [[ -n "$GRUB_MANAGER_ID" && -n "$GRUB_REBOOT_BIN" ]] || return 0
    local cfg_path="" candidate
    for candidate in /boot/grub/grub.cfg /boot/grub2/grub.cfg /efi/EFI/*/grub.cfg /boot/efi/EFI/*/grub.cfg; do
        if [[ -r "$candidate" ]]; then
            cfg_path="$candidate"
            break
        fi
    done
    [[ -n "$cfg_path" ]] || return 0
    local grub_partuuid="" grub_dev=""
    if command -v findmnt >/dev/null 2>&1; then
        grub_dev="$(findmnt -rn -T "$cfg_path" -o SOURCE 2>/dev/null | head -n 1 || true)"
        grub_dev="${grub_dev%%\[*}"
        if [[ -n "$grub_dev" ]] && command -v blkid >/dev/null 2>&1; then
            grub_partuuid="$(blkid -s PARTUUID -o value "$grub_dev" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
        fi
    fi

    if grep -q 'blscfg' "$cfg_path" 2>/dev/null && [[ -d /boot/loader/entries ]]; then
        local file id title linux_image options flavor name version distro detected_flavor
        for file in /boot/loader/entries/*.conf; do
            [[ -f "$file" ]] || continue
            id="${file##*/}"
            id="${id%.conf}"
            title="$(awk 'tolower($1)=="title" { $1=""; sub(/^[[:space:]]+/,""); print; exit }' "$file")"
            linux_image="$(awk 'tolower($1)=="linux" { print $2; exit }' "$file")"
            options="$(awk 'tolower($1)=="options" { $1=""; sub(/^[[:space:]]+/,""); out = (out ? out " " $0 : $0) } END { print out }' "$file")"
            [[ -n "$linux_image" ]] || continue
            flavor="$(classify_linux_loader "$linux_image" "$title" 2>/dev/null || true)"
            [[ -n "$flavor" ]] || flavor="default"
            version="$(get_linux_version "$grub_partuuid" "$linux_image" 2>/dev/null || version_from_kernel_name "$linux_image" 2>/dev/null || true)"
            distro="$(detect_linux_distro "$linux_image" "$title $id" "$version" "$grub_partuuid" "$options" 2>/dev/null || true)"
            if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                detected_flavor="$(classify_linux_version "$version" "$title" 2>/dev/null || true)"
                if [[ -n "$detected_flavor" ]]; then
                    [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                fi
            fi
            if [[ -n "$distro" ]]; then
                [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
            else
                [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
            fi
            add_target grub "$id" "$GRUB_MANAGER_ACTIVE" "${title:-$id}" "$linux_image" "$grub_partuuid" "$options" "linux" "$flavor" "$name" "$version" "$distro" "$cfg_path" "0"
            (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
        done
    fi

    [[ -n "$PYTHON_BIN" ]] || return 0
    local parsed_lines
    parsed_lines="$("$PYTHON_BIN" - "$cfg_path" << 'PYEOF' 2>/dev/null || true
import re, sys

with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as f:
    lines = f.readlines()

stack = []
brace_depth = 0
in_entry = False
cur_title = ""
cur_id = ""
cur_linux = ""
cur_chain = ""
cur_opts = ""

def flush():
    global cur_title, cur_id, cur_linux, cur_chain, cur_opts
    if not cur_title:
        return
    low = cur_title.lower()
    if any(skip in low for skip in ("uefi firmware", "system setup", "memory test", "memtest")):
        cur_title = cur_id = cur_linux = cur_chain = cur_opts = ""
        return
    ident = cur_id if cur_id else cur_title
    if stack:
        prefix = ">".join(s[1] if s[1] else s[0] for s in stack)
        full_id = f"{prefix}>{ident}"
    else:
        full_id = ident
    loader = cur_linux or cur_chain or "/boot/grub/grub.cfg"
    print(f"{full_id}|{cur_title}|{loader}|{cur_opts}")
    cur_title = cur_id = cur_linux = cur_chain = cur_opts = ""

for raw in lines:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    sm = re.match(r"""^submenu\s+(['"])(.*?)\1(.*)$""", line)
    if sm and "{" in line:
        title = sm.group(2)
        rest = sm.group(3)
        idm = re.search(r"""(?:--id|\$menuentry_id_option)\s+(['"]?)([^\s'"{}]+)\1""", rest)
        sid = idm.group(2) if idm else ""
        brace_depth += line.count("{") - line.count("}")
        stack.append((title, sid, brace_depth))
        continue
    em = re.match(r"""^menuentry\s+(['"])(.*?)\1(.*)$""", line)
    if em and "{" in line:
        if in_entry:
            flush()
        in_entry = True
        cur_title = em.group(2)
        rest = em.group(3)
        idm = re.search(r"""(?:--id|\$menuentry_id_option)\s+(['"]?)([^\s'"{}]+)\1""", rest)
        cur_id = idm.group(2) if idm else ""
        brace_depth += line.count("{") - line.count("}")
        continue
    if in_entry:
        lm = re.match(r"""^(?:linux|linux16|linuxefi)\s+(\S+)(.*)$""", line)
        if lm:
            cur_linux = lm.group(1)
            cur_opts = lm.group(2).strip()
        cm = re.match(r"""^chainloader\s+(\S+)""", line)
        if cm:
            cur_chain = cm.group(1)
    opens = line.count("{")
    closes = line.count("}")
    brace_depth += opens - closes
    if closes > 0:
        if in_entry:
            flush()
            in_entry = False
        while stack and brace_depth < stack[-1][2]:
            stack.pop()
PYEOF
)"
    [[ -n "$parsed_lines" ]] || return 0
    local gid gtitle gloader gopts flavor name version distro detected_flavor
    while IFS='|' read -r gid gtitle gloader gopts; do
        [[ -n "$gid" ]] || continue
        if [[ "${gtitle,,}" == *windows* || "${gloader,,}" == *bootmgfw.efi* ]]; then
            continue
        elif [[ "${gtitle,,}" == *macos* || "${gtitle,,}" == *"mac os"* || "${gloader,,}" == *boot.efi* || "${gloader,,}" == *opencore* ]]; then
            local mac_info
            mac_info="$(detect_macos_details "$grub_partuuid" "$gloader" "$gtitle" 2>/dev/null || true)"
            name="${mac_info%%|*}"
            version="${mac_info#*|}"
            [[ -n "$name" ]] || name="macos"
            add_target grub "$gid" "$GRUB_MANAGER_ACTIVE" "$gtitle" "$gloader" "$grub_partuuid" "$gopts" "macos" "unknown" "$name" "$version" "macos" "$cfg_path" "0"
        else
            flavor="$(classify_linux_loader "$gloader" "$gtitle" 2>/dev/null || true)"
            [[ -n "$flavor" ]] || flavor="default"
            version="$(get_linux_version "$grub_partuuid" "$gloader" 2>/dev/null || version_from_kernel_name "$gloader" 2>/dev/null || true)"
            distro="$(detect_linux_distro "$gloader" "$gtitle" "$version" "$grub_partuuid" "$gopts" 2>/dev/null || true)"
            if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                detected_flavor="$(classify_linux_version "$version" "$gtitle" 2>/dev/null || true)"
                if [[ -n "$detected_flavor" ]]; then
                    [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                fi
            fi
            if [[ -n "$distro" ]]; then
                [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
            else
                [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
            fi
            add_target grub "$gid" "$GRUB_MANAGER_ACTIVE" "$gtitle" "$gloader" "$grub_partuuid" "$gopts" "linux" "$flavor" "$name" "$version" "$distro" "$cfg_path" "0"
        fi
        (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
    done <<< "$parsed_lines"
}

parse_refind_entries() {
    [[ -n "$REFIND_MANAGER_ID" && -n "$PYTHON_BIN" ]] || return 0
    local mountpoint conf_file source partuuid
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        conf_file="$(resolve_case_insensitive_file "$mountpoint" "EFI/refind/refind.conf" 2>/dev/null || true)"
        [[ -n "$conf_file" ]] || continue
        source=""
        if command -v findmnt >/dev/null 2>&1; then
            source="$(findmnt -rn -T "$mountpoint" -o SOURCE 2>/dev/null | head -n 1 || true)"
        fi
        source="${source%%\[*}"
        partuuid=""
        if [[ -n "$source" ]] && command -v blkid >/dev/null 2>&1; then
            partuuid="$(blkid -s PARTUUID -o value "$source" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
        fi
        local refind_lines
        refind_lines="$("$PYTHON_BIN" - "$conf_file" << 'PYEOF' 2>/dev/null || true
import re, sys

with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as f:
    lines = f.readlines()

in_menu = False
title = ""
loader = ""
opts = ""
disabled = False

for raw in lines:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    m = re.match(r"""^menuentry\s+(['"])(.*?)\1""", line)
    if m:
        in_menu = True
        title = m.group(2)
        loader = ""
        opts = ""
        disabled = False
        continue
    if in_menu:
        if line == "}":
            if title and loader and not disabled:
                print(f"{title}|{loader}|{opts}")
            in_menu = False
            continue
        if line == "disabled":
            disabled = True
        lm = re.match(r"""^loader\s+(\S+)""", line)
        if lm:
            loader = lm.group(1).strip('"').strip("'")
        om = re.match(r"""^options\s+(['"]?)(.*?)\1$""", line)
        if om:
            opts = om.group(2)
PYEOF
)"
        [[ -n "$refind_lines" ]] || continue
        local rtitle rloader ropts flavor name version distro detected_flavor
        while IFS='|' read -r rtitle rloader ropts; do
            [[ -n "$rtitle" && -n "$rloader" ]] || continue
            if [[ "${rloader,,}" == *bootmgfw.efi* || "${rtitle,,}" == *windows* ]]; then
                continue
            elif [[ "${rloader,,}" == *boot.efi* || "${rtitle,,}" == *macos* ]]; then
                local mac_info
                mac_info="$(detect_macos_details "$partuuid" "$rloader" "$rtitle" 2>/dev/null || true)"
                name="${mac_info%%|*}"
                version="${mac_info#*|}"
                [[ -n "$name" ]] || name="macos"
                add_target refind "$rtitle" "$REFIND_MANAGER_ACTIVE" "$rtitle" "$rloader" "$partuuid" "$ropts" "macos" "unknown" "$name" "$version" "macos" "" "0"
            else
                flavor="$(classify_linux_loader "$rloader" "$rtitle" 2>/dev/null || true)"
                [[ -n "$flavor" ]] || flavor="default"
                version="$(get_linux_version "$partuuid" "$rloader" 2>/dev/null || true)"
                distro="$(detect_linux_distro "$rloader" "$rtitle" "$version" "$partuuid" "$ropts" 2>/dev/null || true)"
                if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                    detected_flavor="$(classify_linux_version "$version" "$rtitle" 2>/dev/null || true)"
                    if [[ -n "$detected_flavor" ]]; then
                        [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                    fi
                fi
                if [[ -n "$distro" ]]; then
                    [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
                else
                    [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
                fi
                add_target refind "$rtitle" "$REFIND_MANAGER_ACTIVE" "$rtitle" "$rloader" "$partuuid" "$ropts" "linux" "$flavor" "$name" "$version" "$distro" "" "0"
            fi
            (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
        done <<< "$refind_lines"
    done < <(find_esp_mounts)
}

parse_limine_entries() {
    [[ -n "$PYTHON_BIN" ]] || return 0
    local mountpoint conf_file source partuuid
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        conf_file=""
        for rel in "limine.conf" "limine/limine.conf" "EFI/limine/limine.conf" "limine.cfg" "limine/limine.cfg" "EFI/limine/limine.cfg"; do
            conf_file="$(resolve_case_insensitive_file "$mountpoint" "$rel" 2>/dev/null || true)"
            [[ -n "$conf_file" ]] && break
        done
        [[ -n "$conf_file" ]] || continue
        source=""
        if command -v findmnt >/dev/null 2>&1; then
            source="$(findmnt -rn -T "$mountpoint" -o SOURCE 2>/dev/null | head -n 1 || true)"
        fi
        source="${source%%\[*}"
        partuuid=""
        if [[ -n "$source" ]] && command -v blkid >/dev/null 2>&1; then
            partuuid="$(blkid -s PARTUUID -o value "$source" 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]' || true)"
        fi
        local limine_lines
        limine_lines="$("$PYTHON_BIN" - "$conf_file" << 'PYEOF' 2>/dev/null || true
import re, sys

with open(sys.argv[1], "r", encoding="utf-8", errors="ignore") as f:
    lines = f.readlines()

entries = []
cur = None

for raw in lines:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if line.startswith("/") or line.startswith(":"):
        if cur and cur.get("title") and cur.get("path"):
            entries.append(cur)
        title = line.lstrip("/:").strip()
        cur = {"title": title, "proto": "", "path": "", "cmdline": ""}
        continue
    if cur is None:
        continue
    kv = re.match(r"""^([A-Za-z0-9_]+)\s*[:=]\s*(.+)$""", line)
    if kv:
        k = kv.group(1).lower()
        v = kv.group(2).strip()
        if k == "protocol":
            cur["proto"] = v.lower()
        elif k in ("path", "kernel_path", "image_path"):
            v = re.sub(r"^boot\(\):/?", "/", v)
            cur["path"] = v
        elif k in ("cmdline", "kernel_cmdline"):
            cur["cmdline"] = v

if cur and cur.get("title") and cur.get("path"):
    entries.append(cur)

for idx, e in enumerate(entries, 1):
    if e["proto"] in ("efi", "chainload", "linux") or e["path"].lower().endswith((".efi", ".uki")):
        print(f"limine-{idx}|{e['title']}|{e['path']}|{e['cmdline']}")
PYEOF
)"
        [[ -n "$limine_lines" ]] || continue
        local lid ltitle lpath lcmd flavor name version distro detected_flavor
        while IFS='|' read -r lid ltitle lpath lcmd; do
            [[ -n "$lid" && -n "$lpath" ]] || continue
            if [[ "${lpath,,}" == *bootmgfw.efi* || "${ltitle,,}" == *windows* ]]; then
                continue
            fi
            flavor="$(classify_linux_loader "$lpath" "$ltitle" 2>/dev/null || true)"
            [[ -n "$flavor" ]] || flavor="default"
            version="$(get_linux_version "$partuuid" "$lpath" 2>/dev/null || true)"
            distro="$(detect_linux_distro "$lpath" "$ltitle" "$version" "$partuuid" "$lcmd" 2>/dev/null || true)"
            if [[ "$flavor" == "default" || "$flavor" == "fallback" ]]; then
                detected_flavor="$(classify_linux_version "$version" "$ltitle" 2>/dev/null || true)"
                if [[ -n "$detected_flavor" ]]; then
                    [[ "$flavor" == "fallback" ]] && flavor="$detected_flavor fallback" || flavor="$detected_flavor"
                fi
            fi
            if [[ -n "$distro" ]]; then
                [[ "$flavor" == "default" ]] && name="$distro linux" || name="$distro linux $flavor"
            else
                [[ "$flavor" == "default" ]] && name="linux" || name="linux $flavor"
            fi
            add_target limine_efi "$lid" "1" "$ltitle" "$lpath" "$partuuid" "$lcmd" "linux" "$flavor" "$name" "$version" "$distro" "" "0"
            (( ${#TARGET_IDS[@]} >= MAX_TARGETS )) && return 0
        done <<< "$limine_lines"
    done < <(find_esp_mounts)
}

scan_targets() {
    TARGET_BACKENDS=()
    TARGET_IDS=()
    TARGET_ACTIVE=()
    TARGET_DEFAULT=()
    TARGET_LABELS=()
    TARGET_LOADERS=()
    TARGET_PARTUUIDS=()
    TARGET_OPTIONS=()
    TARGET_FAMILIES=()
    TARGET_FLAVORS=()
    TARGET_NAMES=()
    TARGET_VERSIONS=()
    TARGET_DISTROS=()
    TARGET_EXTRA=()
    SDBOOT_MANAGER_ID=""
    SDBOOT_MANAGER_ACTIVE="0"
    GRUB_MANAGER_ID=""
    GRUB_MANAGER_ACTIVE="0"
    GRUB_MANAGER_PARTUUID=""
    GRUB_MANAGER_LOADER=""
    REFIND_MANAGER_ID=""
    REFIND_MANAGER_ACTIVE="0"
    REFIND_MANAGER_PARTUUID=""
    REFIND_MANAGER_LOADER=""
    LIMINE_MANAGER_ID=""
    LIMINE_MANAGER_ACTIVE="0"
    BOOT_CURRENT_ID=""
    BOOT_NEXT_ID=""
    BOOT_ORDER_STR=""
    SDBOOT_CURRENT_ID="$(get_sdboot_current_entry)"
    parse_uefi_entries
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_systemd_boot_entries
    fi
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_grub_entries
    fi
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_refind_entries
    fi
    if (( ${#TARGET_IDS[@]} < MAX_TARGETS )); then
        parse_limine_entries
    fi
    disambiguate_duplicate_targets
}

format_backend_badge() {
    local idx="$1"
    case "${TARGET_BACKENDS[idx]}" in
        uefi)
            if [[ "${TARGET_FLAVORS[idx]}" == "bcd-isolated" ]]; then
                printf 'Boot%s | UEFI-WinDirect' "${TARGET_IDS[idx]}"
            else
                printf 'Boot%s | UEFI' "${TARGET_IDS[idx]}"
            fi
            ;;
        winbcd)
            printf '%s | WinBCD-Split' "${TARGET_IDS[idx]}"
            ;;
        sdboot)
            printf '%s | sd-boot' "${TARGET_IDS[idx]}"
            ;;
        grub)
            printf '%s | GRUB2' "${TARGET_IDS[idx]}"
            ;;
        refind)
            printf '%s | rEFInd' "${TARGET_IDS[idx]}"
            ;;
        limine_efi)
            printf '%s | Limine-EFISTUB' "${TARGET_IDS[idx]}"
            ;;
        *)
            printf '%s | %s' "${TARGET_IDS[idx]}" "${TARGET_BACKENDS[idx]}"
            ;;
    esac
}

show_status() {
    local running_os="" running_kernel=""
    running_kernel="$(uname -r 2>/dev/null || true)"
    if [[ -r /etc/os-release ]]; then
        running_os="$(awk '{ idx = index($0, "="); if (idx > 0 && substr($0, 1, idx - 1) == "PRETTY_NAME") { v = substr($0, idx + 1); gsub(/["'\'']/, "", v); print v; exit } }' /etc/os-release 2>/dev/null || true)"
    fi
    printf '%b\n' "${C_BOLD}${C_CYAN}SYSTEM & UEFI BOOT STATUS${C_RESET}"
    printf '  %bCurrent OS    :%b %s (Kernel %s)\n' "$C_DIM" "$C_RESET" "${running_os:-Linux}" "$running_kernel"
    printf '  %bBootCurrent   :%b %s\n' "$C_DIM" "$C_RESET" "${BOOT_CURRENT_ID:+Boot$BOOT_CURRENT_ID}${BOOT_CURRENT_ID:-N/A}"
    printf '  %bBootNext      :%b %s\n' "$C_DIM" "$C_RESET" "${BOOT_NEXT_ID:+${C_YELLOW}Boot$BOOT_NEXT_ID (Pending)${C_RESET}}${BOOT_NEXT_ID:-None}"
    printf '  %bBootOrder     :%b %s\n' "$C_DIM" "$C_RESET" "${BOOT_ORDER_STR:-N/A}"
    local sd_oneshot="/sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    if [[ -r "$sd_oneshot" ]]; then
        local sd_val
        sd_val="$(tail -c +5 "$sd_oneshot" 2>/dev/null | tr -d '\000' || true)"
        [[ -n "$sd_val" ]] && printf '  %bsd-boot Next  :%b %b%s%b\n' "$C_DIM" "$C_RESET" "$C_YELLOW" "$sd_val" "$C_RESET"
    fi
    printf '\n%b\n' "${C_BOLD}${C_CYAN}DETECTED BOOTLOADERS${C_RESET}"
    [[ -n "$SDBOOT_MANAGER_ID" ]] && printf '  %b• systemd-boot%b (Boot%s)\n' "$C_GREEN" "$C_RESET" "$SDBOOT_MANAGER_ID"
    [[ -n "$GRUB_MANAGER_ID" ]] && printf '  %b• GRUB2%b (Boot%s)\n' "$C_GREEN" "$C_RESET" "$GRUB_MANAGER_ID"
    [[ -n "$REFIND_MANAGER_ID" ]] && printf '  %b• rEFInd%b (Boot%s)\n' "$C_GREEN" "$C_RESET" "$REFIND_MANAGER_ID"
    [[ -n "$LIMINE_MANAGER_ID" ]] && printf '  %b• Limine%b (Boot%s)\n' "$C_GREEN" "$C_RESET" "$LIMINE_MANAGER_ID"
    printf '  %b• Direct EFISTUB / NVRAM%b (%s total targets)\n' "$C_GREEN" "$C_RESET" "${#TARGET_IDS[@]}"
}

show_json() {
    if [[ -z "$PYTHON_BIN" ]]; then
        print_failed "python3 is required for JSON output."
        return 1
    fi
    local i
    local -a rows=()
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ -n "${DISTRO_FILTER:-}" && "${TARGET_DISTROS[i],,}" != "${DISTRO_FILTER,,}" ]]; then
            continue
        fi
        local is_cur="false"
        if [[ "${TARGET_BACKENDS[i]}" == "uefi" && -n "$BOOT_CURRENT_ID" && "${TARGET_IDS[i]}" == "$BOOT_CURRENT_ID" ]]; then
            is_cur="true"
        elif [[ "${TARGET_BACKENDS[i]}" == "sdboot" && -n "$SDBOOT_CURRENT_ID" && "${TARGET_IDS[i]}" == "$SDBOOT_CURRENT_ID" ]]; then
            is_cur="true"
        elif [[ "${TARGET_FAMILIES[i]}" == "linux" ]] && is_current_kernel_target "$i"; then
            is_cur="true"
        fi
        rows+=("$((i + 1))"$'\t'"${TARGET_BACKENDS[i]}"$'\t'"${TARGET_IDS[i]}"$'\t'"${TARGET_ACTIVE[i]}"$'\t'"${TARGET_DEFAULT[i]}"$'\t'"$is_cur"$'\t'"${TARGET_FAMILIES[i]}"$'\t'"${TARGET_DISTROS[i]}"$'\t'"${TARGET_FLAVORS[i]}"$'\t'"${TARGET_NAMES[i]}"$'\t'"${TARGET_VERSIONS[i]}"$'\t'"${TARGET_LABELS[i]}"$'\t'"${TARGET_LOADERS[i]}"$'\t'"${TARGET_PARTUUIDS[i]}"$'\t'"${TARGET_OPTIONS[i]}")
    done
    printf '%s\n' "${rows[@]:-}" | "$PYTHON_BIN" - "$BOOT_SCRIPT_VERSION" "$BOOT_CURRENT_ID" "$BOOT_NEXT_ID" "$BOOT_ORDER_STR" << 'PYEOF'
import json, sys

ver, cur_id, next_id, order_str = sys.argv[1:5]
targets = []
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    while len(parts) < 15:
        parts.append("")
    idx, backend, tid, active, is_def, is_cur, family, distro, flavor, name, tver, label, loader, partuuid, opts = parts[:15]
    targets.append({
        "index": int(idx),
        "backend": backend,
        "id": tid,
        "active": active == "1",
        "default": is_def == "1",
        "current": is_cur == "true",
        "family": family,
        "distro": distro or None,
        "flavor": flavor or None,
        "name": name,
        "version": tver or None,
        "label": label,
        "loader": loader,
        "partuuid": partuuid or None,
        "options": opts or None,
    })

out = {
    "version": ver,
    "boot_current": cur_id or None,
    "boot_next": next_id or None,
    "boot_order": [x for x in order_str.split(",") if x],
    "count": len(targets),
    "targets": targets,
}
print(json.dumps(out, indent=2))
PYEOF
}

show_help() {
    local i display badge entry_tag shown=0
    printf '%b\n' "${C_BOLD}${C_CYAN}INSTALLED OS AND KERNELS (${#TARGET_IDS[@]}/${MAX_TARGETS})${C_RESET}"
    if (( ${#TARGET_IDS[@]} == 0 )); then
        printf '  %b\n' "${C_DIM}No supported boot entries detected.${C_RESET}"
    else
        for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
            if [[ -n "${DISTRO_FILTER:-}" && "${TARGET_DISTROS[i],,}" != "${DISTRO_FILTER,,}" ]]; then
                continue
            fi
            ((shown+=1))
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
            entry_tag="$(format_backend_badge "$i")"
            printf '  %b %b%b %b\n' "${C_DIM}[$((i + 1))]${C_RESET}" "${C_GREEN}${display}${C_RESET}" "$badge" "${C_DIM}(${entry_tag})${C_RESET}"
        done
        if (( shown == 0 )); then
            printf '  %b\n' "${C_DIM}No entries match distro filter '${DISTRO_FILTER}'.${C_RESET}"
        fi
    fi
    printf '\n%b\n' "${C_BOLD}${C_CYAN}COMMANDS & OPTIONS${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot <OS_NAME|INDEX>${C_RESET}   " "${C_DIM}Reboot once into the selected OS or kernel${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -y <OS_NAME>${C_RESET}      " "${C_DIM}Skip confirmation prompt and reboot immediately${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -f <OS_NAME>${C_RESET}      " "${C_DIM}Close open apps immediately and force reboot${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -i${C_RESET}                " "${C_DIM}Interactive menu to pick a boot target by number${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -D | --default${C_RESET}    " "${C_DIM}Reboot into the firmware/BCD default OS target${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -d <DISTRO> [TARGET]${C_RESET}" "${C_DIM}Filter or select a specific Linux distro${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -t <OS_NAME>${C_RESET}      " "${C_DIM}Verify boot image, partition, and sudo permissions${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -n <OS_NAME>${C_RESET}      " "${C_DIM}Dry-run: preview execution plan without rebooting${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -p${C_RESET}                " "${C_DIM}Show current UEFI BootCurrent, BootNext, and bootloaders${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -c${C_RESET}                " "${C_DIM}Clear any pending one-shot boot selection${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -w${C_RESET}                " "${C_DIM}Reboot directly into UEFI Firmware / BIOS setup${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -s${C_RESET}                " "${C_DIM}Split merged Windows BCD entries into direct UEFI entries${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -u${C_RESET}                " "${C_DIM}Clean up isolated multiboot-win-* UEFI entries${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -l${C_RESET}                " "${C_DIM}Show detailed boot target table, root devices, and paths${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -j | --json${C_RESET}       " "${C_DIM}Output detected boot targets and status in JSON format${C_RESET}"
    printf '  %b   %b\n' "${C_GREEN}boot -h${C_RESET}                " "${C_DIM}Show installed targets and available commands${C_RESET}"
}

show_list() {
    local i display status current_tag dev_info fstype_info backend_desc root_meta
    printf '%b\n' "${C_BOLD}${C_CYAN}DETECTED BOOT TARGETS (${#TARGET_IDS[@]}/${MAX_TARGETS})${C_RESET}"
    if (( ${#TARGET_IDS[@]} == 0 )); then
        printf '  %b\n' "${C_DIM}No supported boot entries detected.${C_RESET}"
        return 0
    fi
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ -n "${DISTRO_FILTER:-}" && "${TARGET_DISTROS[i],,}" != "${DISTRO_FILTER,,}" ]]; then
            continue
        fi
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
        case "${TARGET_BACKENDS[i]}" in
            uefi) backend_desc="UEFI NVRAM (Boot${TARGET_IDS[i]})" ;;
            winbcd) backend_desc="Windows BCD Direct Split (${TARGET_IDS[i]})" ;;
            sdboot) backend_desc="systemd-boot (${TARGET_IDS[i]})" ;;
            grub) backend_desc="GRUB2 One-Shot (${TARGET_IDS[i]})" ;;
            refind) backend_desc="rEFInd One-Shot (${TARGET_IDS[i]})" ;;
            limine_efi) backend_desc="Limine EFISTUB Direct (${TARGET_IDS[i]})" ;;
            *) backend_desc="${TARGET_BACKENDS[i]} (${TARGET_IDS[i]})" ;;
        esac
        printf '      %bEntry   :%b %s - %s\n' "$C_DIM" "$C_RESET" "$backend_desc" "${TARGET_LABELS[i]}"
        printf '      %bLoader  :%b %s\n' "$C_DIM" "$C_RESET" "${TARGET_LOADERS[i]}"
        if [[ -n "${TARGET_PARTUUIDS[i]}" ]]; then
            dev_info="$(get_partuuid_device "${TARGET_PARTUUIDS[i]}" 2>/dev/null || true)"
            fstype_info=""
            [[ -n "$dev_info" ]] && fstype_info="$(get_partition_type "$dev_info" 2>/dev/null || true)"
            if [[ -n "$fstype_info" ]]; then
                printf '      %bESP/Boot:%b PARTUUID=%s (%s)\n' "$C_DIM" "$C_RESET" "${TARGET_PARTUUIDS[i]}" "$fstype_info"
            else
                printf '      %bESP/Boot:%b PARTUUID=%s\n' "$C_DIM" "$C_RESET" "${TARGET_PARTUUIDS[i]}"
            fi
        fi
        if [[ "${TARGET_FAMILIES[i]}" == "linux" ]]; then
            root_meta="$(inspect_root_os_release "${TARGET_OPTIONS[i]}" "${TARGET_PARTUUIDS[i]}" 2>/dev/null || true)"
            if [[ -n "$root_meta" ]]; then
                local r_id r_ver r_pretty r_lbl
                IFS='|' read -r r_id r_ver r_pretty r_lbl <<< "$root_meta"
                printf '      %bDistro  :%b %s (Root: %s)\n' "$C_DIM" "$C_RESET" "${r_pretty:-$r_id}" "$r_lbl"
            fi
        fi
        if [[ -n "${TARGET_EXTRA[i]}" && ( "${TARGET_BACKENDS[i]}" == "winbcd" || "${TARGET_FLAVORS[i]}" == "bcd-isolated" ) ]]; then
            local w_guid w_part w_root
            IFS='|' read -r w_guid w_part w_root <<< "${TARGET_EXTRA[i]}"
            printf '      %bWinBCD  :%b GUID=%s | SystemRoot=%s%s\n' "$C_DIM" "$C_RESET" "$w_guid" "$w_root" "${w_part:+ | Part=$w_part}"
        fi
        if [[ -n "${TARGET_OPTIONS[i]}" ]]; then
            printf '      %bOptions :%b %s\n' "$C_DIM" "$C_RESET" "${TARGET_OPTIONS[i]}"
        fi
    done
}

is_current_kernel_target() {
    local idx="$1"
    [[ "${TARGET_FAMILIES[idx]}" == "linux" ]] || return 1
    local running_rel
    running_rel="$(uname -r 2>/dev/null || true)"
    [[ -n "$running_rel" && "${TARGET_VERSIONS[idx]}" == "$running_rel" ]] || return 1
    local opts="${TARGET_OPTIONS[idx]}"
    if [[ "$opts" =~ root=([^[:space:]]+) ]]; then
        local target_dev cur_dev
        target_dev="$(resolve_root_spec_device "${BASH_REMATCH[1]}" 2>/dev/null || true)"
        cur_dev="$(findmnt -rn -T / -o SOURCE 2>/dev/null | head -n 1 || true)"
        cur_dev="${cur_dev%%\[*}"
        if [[ -n "$target_dev" && -n "$cur_dev" ]]; then
            [[ "$(readlink -f "$target_dev" 2>/dev/null)" == "$(readlink -f "$cur_dev" 2>/dev/null)" ]] || return 1
        fi
    fi
    return 0
}

check_sudo_capabilities() {
    local backend="$1"
    (( EUID == 0 )) && return 0
    command -v sudo >/dev/null 2>&1 || return 1
    if [[ "$backend" == "uefi" ]]; then
        sudo -n -l "$EFI_BIN" --bootnext 0000 >/dev/null 2>&1 || sudo -n -l "$EFI_BIN" -n 0000 >/dev/null 2>&1 || sudo -n -l "$EFI_BIN" >/dev/null 2>&1 || return 1
    elif [[ "$backend" == "winbcd" || "$backend" == "limine_efi" ]]; then
        sudo -n -l "$EFI_BIN" --bootnext 0000 >/dev/null 2>&1 || sudo -n -l "$EFI_BIN" -n 0000 >/dev/null 2>&1 || sudo -n -l "$EFI_BIN" >/dev/null 2>&1 || return 1
    elif [[ "$backend" == "sdboot" ]]; then
        sudo -n -l "$BOOTCTL_BIN" set-oneshot x >/dev/null 2>&1 || sudo -n -l "$BOOTCTL_BIN" >/dev/null 2>&1 || return 1
    elif [[ "$backend" == "grub" ]]; then
        sudo -n -l "$GRUB_REBOOT_BIN" 0 >/dev/null 2>&1 || sudo -n -l "$GRUB_REBOOT_BIN" >/dev/null 2>&1 || return 1
    elif [[ "$backend" == "refind" ]]; then
        [[ -x "$EFI_READ_HELPER" ]] && sudo -n -l "$EFI_READ_HELPER" >/dev/null 2>&1 || sudo -n -l /usr/bin/python3 >/dev/null 2>&1 || true
    fi
    if [[ -n "$SYSTEMCTL_BIN" ]]; then
        sudo -n -l "$SYSTEMCTL_BIN" reboot >/dev/null 2>&1 || sudo -n -l "$SYSTEMCTL_BIN" >/dev/null 2>&1 || return 1
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
    local checks="entry"
    if [[ "$backend" == "uefi" ]]; then
        [[ -n "$EFI_BIN" ]] || { print_failed "efibootmgr is not available."; return 1; }
        [[ "$active" == "1" ]] || { print_failed "UEFI entry Boot${id} (${label}) is inactive."; return 1; }
        checks+=", active"
    elif [[ "$backend" == "winbcd" ]]; then
        [[ -n "$EFI_BIN" ]] || { print_failed "efibootmgr is not available."; return 1; }
        [[ -n "$PYTHON_BIN" ]] || { print_failed "python3 is required for BCD isolation."; return 1; }
        [[ -n "$partuuid" ]] || { print_failed "Windows BCD entry ${id} has no ESP PARTUUID."; return 1; }
        entry_file_exists "$partuuid" "/EFI/Microsoft/Boot/BCD" || { print_failed "Windows BCD store /EFI/Microsoft/Boot/BCD not found on ESP."; return 1; }
        checks+=", winbcd, bcd-store"
    elif [[ "$backend" == "sdboot" ]]; then
        [[ -n "$SDBOOT_MANAGER_ID" ]] || { print_failed "systemd-boot is not registered in UEFI."; return 1; }
        [[ "$SDBOOT_MANAGER_ACTIVE" == "1" ]] || { print_failed "systemd-boot Boot${SDBOOT_MANAGER_ID} is inactive."; return 1; }
        [[ -n "$BOOTCTL_BIN" ]] || { print_failed "bootctl is not available."; return 1; }
        checks+=", sd-boot"
    elif [[ "$backend" == "grub" ]]; then
        [[ -n "$GRUB_MANAGER_ID" ]] || { print_failed "GRUB2 is not registered in UEFI."; return 1; }
        [[ "$GRUB_MANAGER_ACTIVE" == "1" ]] || { print_failed "GRUB2 Boot${GRUB_MANAGER_ID} is inactive."; return 1; }
        [[ -n "$GRUB_REBOOT_BIN" ]] || { print_failed "grub-reboot is not available."; return 1; }
        checks+=", grub2"
    elif [[ "$backend" == "refind" ]]; then
        [[ -n "$REFIND_MANAGER_ID" ]] || { print_failed "rEFInd is not registered in UEFI."; return 1; }
        [[ "$REFIND_MANAGER_ACTIVE" == "1" ]] || { print_failed "rEFInd Boot${REFIND_MANAGER_ID} is inactive."; return 1; }
        checks+=", refind"
    elif [[ "$backend" == "limine_efi" ]]; then
        [[ -n "$EFI_BIN" ]] || { print_failed "efibootmgr is not available."; return 1; }
        checks+=", limine-efistub"
    fi
    if [[ -n "$partuuid" ]]; then
        local dev fstype
        dev="$(get_partuuid_device "$partuuid" 2>/dev/null || true)"
        [[ -n "$dev" ]] || { print_failed "Boot partition PARTUUID=${partuuid} was not found."; return 1; }
        fstype="$(get_partition_type "$dev")"
        [[ -n "$fstype" ]] || { print_failed "Could not read filesystem type of ${dev}."; return 1; }
        checks+=", part(${fstype})"
    fi
    if [[ "$backend" != "grub" ]]; then
        entry_file_exists "$partuuid" "$loader" || { print_failed "Boot image '${loader}' not found on ESP."; return 1; }
        checks+=", image"
    fi
    if [[ "$options" =~ initrd=([^[:space:]]+) ]]; then
        local initrd_rel="${BASH_REMATCH[1]}"
        if ! entry_file_exists "$partuuid" "$initrd_rel"; then
            print_warn "Initrd '${initrd_rel}' could not be verified on ESP."
        else
            checks+=", initrd"
        fi
    fi
    if [[ "$options" =~ root=([^[:space:]]+) ]]; then
        local root_spec="${BASH_REMATCH[1]}"
        local root_dev
        root_dev="$(resolve_root_spec_device "$root_spec" 2>/dev/null || true)"
        if [[ -z "$root_dev" ]]; then
            print_warn "Root device '${root_spec}' is not currently visible."
        else
            checks+=", root(${root_dev##*/})"
        fi
    fi
    if (( EUID != 0 )); then
        if ! check_sudo_capabilities "$backend"; then
            print_warn "Non-interactive sudo check did not confirm all privileges; password prompt may appear."
        else
            checks+=", sudo"
        fi
    fi
    print_success "'${label}' (${TARGET_NAMES[index]}${TARGET_VERSIONS[index]:+ ${TARGET_VERSIONS[index]}}) passed ${checks}."
    return 0
}

show_dry_run_plan() {
    local index="$1"
    local backend="${TARGET_BACKENDS[index]}"
    local id="${TARGET_IDS[index]}"
    local display="${TARGET_NAMES[index]}${TARGET_VERSIONS[index]:+ ${TARGET_VERSIONS[index]}}"
    printf '\n%b\n' "${C_BOLD}${C_CYAN}DRY-RUN EXECUTION PLAN${C_RESET}"
    printf '  %bTarget OS   :%b %s\n' "$C_DIM" "$C_RESET" "$display"
    printf '  %bBackend     :%b %s (%s)\n' "$C_DIM" "$C_RESET" "$backend" "$id"
    printf '  %bLoader      :%b %s\n' "$C_DIM" "$C_RESET" "${TARGET_LOADERS[index]}"
    [[ -n "${TARGET_PARTUUIDS[index]}" ]] && printf '  %bESP PARTUUID:%b %s\n' "$C_DIM" "$C_RESET" "${TARGET_PARTUUIDS[index]}"
    if [[ "$backend" == "uefi" ]]; then
        printf '  %bStep 1      :%b %s --bootnext %s\n' "$C_DIM" "$C_RESET" "${EFI_BIN:-efibootmgr}" "$id"
    elif [[ "$backend" == "winbcd" ]]; then
        local w_guid w_part w_root short_g
        IFS='|' read -r w_guid w_part w_root <<< "${TARGET_EXTRA[index]}"
        short_g="${w_guid//[\{\}-]/}"
        short_g="${short_g:0:8}"
        printf '  %bWinBCD GUID :%b %s (SystemRoot=%s)\n' "$C_DIM" "$C_RESET" "$w_guid" "$w_root"
        printf '  %bStep 1      :%b Create isolated Windows Boot Manager in /EFI/multiboot-win-%s/ with single-target BCD\n' "$C_DIM" "$C_RESET" "$short_g"
        printf '  %bStep 2      :%b Register temporary/reusable UEFI entry and execute %s --bootnext <NEW_ID>\n' "$C_DIM" "$C_RESET" "${EFI_BIN:-efibootmgr}"
    elif [[ "$backend" == "sdboot" ]]; then
        printf '  %bStep 1      :%b %s --bootnext %s\n' "$C_DIM" "$C_RESET" "${EFI_BIN:-efibootmgr}" "$SDBOOT_MANAGER_ID"
        printf '  %bStep 2      :%b %s set-oneshot %s\n' "$C_DIM" "$C_RESET" "${BOOTCTL_BIN:-bootctl}" "$id"
    elif [[ "$backend" == "grub" ]]; then
        printf '  %bStep 1      :%b %s --bootnext %s\n' "$C_DIM" "$C_RESET" "${EFI_BIN:-efibootmgr}" "$GRUB_MANAGER_ID"
        printf '  %bStep 2      :%b %s "%s"\n' "$C_DIM" "$C_RESET" "${GRUB_REBOOT_BIN:-grub-reboot}" "$id"
    elif [[ "$backend" == "refind" ]]; then
        printf '  %bStep 1      :%b %s --bootnext %s\n' "$C_DIM" "$C_RESET" "${EFI_BIN:-efibootmgr}" "$REFIND_MANAGER_ID"
        printf '  %bStep 2      :%b Update PreviousBoot efivar to "%s"\n' "$C_DIM" "$C_RESET" "$id"
    elif [[ "$backend" == "limine_efi" ]]; then
        printf '  %bStep 1      :%b Register/reuse direct EFISTUB UEFI entry for %s and set BootNext\n' "$C_DIM" "$C_RESET" "${TARGET_LOADERS[index]}"
    fi
    if (( FORCE_MODE == 1 )); then
        printf '  %bReboot Step :%b %s reboot --force\n' "$C_DIM" "$C_RESET" "${SYSTEMCTL_BIN:-systemctl}"
    else
        printf '  %bReboot Step :%b %s reboot\n' "$C_DIM" "$C_RESET" "${SYSTEMCTL_BIN:-systemctl}"
    fi
    printf '\n'
    print_info "Dry-run complete. No changes were written to NVRAM or disk."
}

set_next_boot() {
    local index="$1"
    local backend="${TARGET_BACKENDS[index]}"
    local id="${TARGET_IDS[index]}"
    if [[ "$backend" == "uefi" ]]; then
        [[ -n "$EFI_BIN" ]] || { print_failed "efibootmgr is not available."; return 1; }
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$id" >/dev/null 2>&1 || "$EFI_BIN" -n "$id" >/dev/null 2>&1 || return 1
        else
            sudo "$EFI_BIN" --bootnext "$id" >/dev/null 2>&1 || sudo "$EFI_BIN" -n "$id" >/dev/null 2>&1 || return 1
        fi
        return 0
    elif [[ "$backend" == "winbcd" ]]; then
        local w_guid w_part w_root iso_id
        IFS='|' read -r w_guid w_part w_root <<< "${TARGET_EXTRA[index]}"
        iso_id="$(create_isolated_windows_boot "${TARGET_PARTUUIDS[index]}" "$w_guid" "${TARGET_LABELS[index]}" 2>/dev/null || true)"
        [[ "$iso_id" =~ ^[0-9A-Fa-f]{4}$ ]] || { print_failed "Could not create isolated Windows UEFI boot entry for ${w_guid}."; return 1; }
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$iso_id" >/dev/null 2>&1 || "$EFI_BIN" -n "$iso_id" >/dev/null 2>&1 || return 1
        else
            sudo "$EFI_BIN" --bootnext "$iso_id" >/dev/null 2>&1 || sudo "$EFI_BIN" -n "$iso_id" >/dev/null 2>&1 || return 1
        fi
        return 0
    elif [[ "$backend" == "sdboot" ]]; then
        [[ -n "$SDBOOT_MANAGER_ID" && -n "$EFI_BIN" && -n "$BOOTCTL_BIN" ]] || return 1
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$SDBOOT_MANAGER_ID" >/dev/null 2>&1 || "$EFI_BIN" -n "$SDBOOT_MANAGER_ID" >/dev/null 2>&1 || return 1
            "$BOOTCTL_BIN" set-oneshot "$id" >/dev/null 2>&1 || return 1
        else
            sudo "$EFI_BIN" --bootnext "$SDBOOT_MANAGER_ID" >/dev/null 2>&1 || sudo "$EFI_BIN" -n "$SDBOOT_MANAGER_ID" >/dev/null 2>&1 || return 1
            sudo "$BOOTCTL_BIN" set-oneshot "$id" >/dev/null 2>&1 || return 1
        fi
        return 0
    elif [[ "$backend" == "grub" ]]; then
        [[ -n "$GRUB_MANAGER_ID" && -n "$EFI_BIN" && -n "$GRUB_REBOOT_BIN" ]] || return 1
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$GRUB_MANAGER_ID" >/dev/null 2>&1 || "$EFI_BIN" -n "$GRUB_MANAGER_ID" >/dev/null 2>&1 || return 1
            "$GRUB_REBOOT_BIN" "$id" >/dev/null 2>&1 || return 1
        else
            sudo "$EFI_BIN" --bootnext "$GRUB_MANAGER_ID" >/dev/null 2>&1 || sudo "$EFI_BIN" -n "$GRUB_MANAGER_ID" >/dev/null 2>&1 || return 1
            sudo "$GRUB_REBOOT_BIN" "$id" >/dev/null 2>&1 || return 1
        fi
        return 0
    elif [[ "$backend" == "refind" ]]; then
        [[ -n "$REFIND_MANAGER_ID" && -n "$EFI_BIN" ]] || return 1
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$REFIND_MANAGER_ID" >/dev/null 2>&1 || "$EFI_BIN" -n "$REFIND_MANAGER_ID" >/dev/null 2>&1 || return 1
        else
            sudo "$EFI_BIN" --bootnext "$REFIND_MANAGER_ID" >/dev/null 2>&1 || sudo "$EFI_BIN" -n "$REFIND_MANAGER_ID" >/dev/null 2>&1 || return 1
        fi
        local refind_var="/sys/firmware/efi/efivars/PreviousBoot-36d08fa7-cf0b-42f5-8f14-68df73ed3740"
        if [[ -n "$PYTHON_BIN" ]]; then
            local tmp_var
            tmp_var="$(mktemp)"
            "$PYTHON_BIN" - "$tmp_var" "$id" << 'PYEOF'
import struct, sys
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<I", 7))
    f.write((sys.argv[2] + "\x00").encode("utf-16le"))
PYEOF
            if (( EUID == 0 )); then
                chattr -i "$refind_var" 2>/dev/null || true
                cp -f "$tmp_var" "$refind_var" 2>/dev/null || true
            else
                sudo chattr -i "$refind_var" 2>/dev/null || true
                sudo cp -f "$tmp_var" "$refind_var" 2>/dev/null || true
            fi
            rm -f -- "$tmp_var"
        fi
        return 0
    elif [[ "$backend" == "limine_efi" ]]; then
        [[ -n "$EFI_BIN" ]] || return 1
        local esp_dev disk_dev part_num efi_win_path existing_id
        esp_dev="$(get_partuuid_device "${TARGET_PARTUUIDS[index]}" 2>/dev/null || true)"
        [[ -b "$esp_dev" ]] || return 1
        efi_win_path="$(normalize_efi_relpath "${TARGET_LOADERS[index]}" 2>/dev/null || true)"
        efi_win_path="${efi_win_path//\//\\}"
        existing_id="$(EFI_SEARCH_PATH="$efi_win_path" awk '
            BEGIN { p = tolower(ENVIRON["EFI_SEARCH_PATH"]) }
            /^Boot[0-9A-Fa-f]{4}/ {
                if (index(tolower($0), p) > 0) {
                    print toupper(substr($0, 5, 4))
                    exit
                }
            }
        ' <<< "$(get_efi_output)")"
        if [[ -z "$existing_id" ]]; then
            disk_dev="/dev/$(lsblk -dnro PKNAME "$esp_dev" 2>/dev/null | head -n 1 || true)"
            part_num="$(cat "/sys/class/block/${esp_dev##*/}/partition" 2>/dev/null || true)"
            [[ -b "$disk_dev" && "$part_num" =~ ^[0-9]+$ ]] || return 1
            if (( EUID == 0 )); then
                "$EFI_BIN" -c -d "$disk_dev" -p "$part_num" -L "${TARGET_LABELS[index]}" -l "$efi_win_path" -u "${TARGET_OPTIONS[index]}" >/dev/null 2>&1 || return 1
            else
                sudo "$EFI_BIN" -c -d "$disk_dev" -p "$part_num" -L "${TARGET_LABELS[index]}" -l "$efi_win_path" -u "${TARGET_OPTIONS[index]}" >/dev/null 2>&1 || return 1
            fi
            EFI_OUTPUT=""
            existing_id="$(EFI_SEARCH_PATH="$efi_win_path" awk '
                BEGIN { p = tolower(ENVIRON["EFI_SEARCH_PATH"]) }
                /^Boot[0-9A-Fa-f]{4}/ {
                    if (index(tolower($0), p) > 0) {
                        print toupper(substr($0, 5, 4))
                        exit
                    }
                }
            ' <<< "$(get_efi_output)")"
        fi
        [[ -n "$existing_id" ]] || return 1
        if (( EUID == 0 )); then
            "$EFI_BIN" --bootnext "$existing_id" >/dev/null 2>&1 || "$EFI_BIN" -n "$existing_id" >/dev/null 2>&1 || return 1
        else
            sudo "$EFI_BIN" --bootnext "$existing_id" >/dev/null 2>&1 || sudo "$EFI_BIN" -n "$existing_id" >/dev/null 2>&1 || return 1
        fi
        return 0
    fi
    return 1
}

clear_next_boot() {
    local cleared=0
    if [[ -n "$EFI_BIN" ]]; then
        if (( EUID == 0 )); then
            "$EFI_BIN" --delete-bootnext >/dev/null 2>&1 && cleared=1 || "$EFI_BIN" -N >/dev/null 2>&1 && cleared=1 || true
        else
            sudo "$EFI_BIN" --delete-bootnext >/dev/null 2>&1 && cleared=1 || sudo "$EFI_BIN" -N >/dev/null 2>&1 && cleared=1 || true
        fi
    fi
    local sd_oneshot="/sys/firmware/efi/efivars/LoaderEntryOneShot-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f"
    if [[ -e "$sd_oneshot" ]]; then
        if (( EUID == 0 )); then
            chattr -i "$sd_oneshot" 2>/dev/null || true
            rm -f -- "$sd_oneshot" 2>/dev/null && cleared=1 || true
        else
            sudo chattr -i "$sd_oneshot" 2>/dev/null || true
            sudo rm -f -- "$sd_oneshot" 2>/dev/null && cleared=1 || true
        fi
    fi
    if [[ -n "$GRUB_REBOOT_BIN" ]] && command -v grub-editenv >/dev/null 2>&1; then
        local grubenv=""
        for candidate in /boot/grub/grubenv /boot/grub2/grubenv /efi/EFI/*/grubenv /boot/efi/EFI/*/grubenv; do
            [[ -f "$candidate" ]] && { grubenv="$candidate"; break; }
        done
        if [[ -n "$grubenv" ]]; then
            if (( EUID == 0 )); then
                grub-editenv "$grubenv" unset next_entry 2>/dev/null && cleared=1 || true
            else
                sudo grub-editenv "$grubenv" unset next_entry 2>/dev/null && cleared=1 || true
            fi
        fi
    fi
    if (( cleared == 1 )); then
        print_success "Cleared pending one-shot boot selection."
    else
        print_info "No active one-shot boot selection found or already clear."
    fi
}

reboot_to_firmware() {
    if [[ -n "$SYSTEMCTL_BIN" ]]; then
        if (( EUID == 0 )); then
            "$SYSTEMCTL_BIN" reboot --firmware-setup && return 0
        else
            sudo "$SYSTEMCTL_BIN" reboot --firmware-setup && return 0
        fi
    fi
    if [[ -n "$EFI_BIN" ]]; then
        if (( EUID == 0 )); then
            "$EFI_BIN" --indicate-firmware-setup >/dev/null 2>&1 || true
        else
            sudo "$EFI_BIN" --indicate-firmware-setup >/dev/null 2>&1 || true
        fi
        trigger_reboot
        return $?
    fi
    print_failed "Neither systemctl nor efibootmgr supports firmware setup indication on this system."
    return 1
}

split_all_windows_bcd() {
    local i split_cnt=0
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ "${TARGET_BACKENDS[i]}" == "winbcd" ]]; then
            local w_guid w_part w_root iso_id
            IFS='|' read -r w_guid w_part w_root <<< "${TARGET_EXTRA[i]}"
            iso_id="$(create_isolated_windows_boot "${TARGET_PARTUUIDS[i]}" "$w_guid" "${TARGET_LABELS[i]}" 2>/dev/null || true)"
            if [[ "$iso_id" =~ ^[0-9A-Fa-f]{4}$ ]]; then
                print_success "Split '${TARGET_NAMES[i]}${TARGET_VERSIONS[i]:+ ${TARGET_VERSIONS[i]}}' (${w_guid}) -> UEFI Boot${iso_id}"
                ((split_cnt+=1))
            else
                print_failed "Failed to split Windows BCD entry ${w_guid}."
            fi
        fi
    done
    if (( split_cnt == 0 )); then
        print_info "No merged multi-OS Windows BCD entries needed splitting."
    fi
}

terminate_user_applications() {
    local my_pid=$$
    local parent_pid=$PPID
    local session_leader
    session_leader="$(ps -o sid= -p "$my_pid" 2>/dev/null | tr -d ' ' || true)"
    if command -v loginctl >/dev/null 2>&1 && [[ -n "${XDG_SESSION_ID:-}" ]]; then
        loginctl terminate-session "$XDG_SESSION_ID" >/dev/null 2>&1 || true
    fi
    if command -v pkill >/dev/null 2>&1; then
        local uid
        uid="$(id -u)"
        if (( uid >= 1000 )); then
            local pid comm sid
            while read -r pid sid comm; do
                [[ "$pid" =~ ^[0-9]+$ ]] || continue
                (( pid == my_pid || pid == parent_pid )) && continue
                [[ -n "$session_leader" && "$sid" == "$session_leader" ]] && continue
                case "$comm" in
                    systemd|dbus-daemon|dbus-broker|sshd|bash|zsh|fish|sh|sudo|su|login) continue ;;
                esac
                kill -TERM "$pid" 2>/dev/null || true
            done < <(ps -u "$uid" -o pid=,sid=,comm= 2>/dev/null || true)
            sleep 0.5
            while read -r pid sid comm; do
                [[ "$pid" =~ ^[0-9]+$ ]] || continue
                (( pid == my_pid || pid == parent_pid )) && continue
                [[ -n "$session_leader" && "$sid" == "$session_leader" ]] && continue
                case "$comm" in
                    systemd|dbus-daemon|dbus-broker|sshd|bash|zsh|fish|sh|sudo|su|login) continue ;;
                esac
                kill -KILL "$pid" 2>/dev/null || true
            done < <(ps -u "$uid" -o pid=,sid=,comm= 2>/dev/null || true)
        fi
    fi
}

trigger_reboot() {
    sync 2>/dev/null || true
    if (( FORCE_MODE == 1 )); then
        terminate_user_applications
        if [[ -n "$SYSTEMCTL_BIN" ]]; then
            if (( EUID == 0 )); then
                "$SYSTEMCTL_BIN" reboot --force --no-block && return 0
                "$SYSTEMCTL_BIN" reboot --force && return 0
            else
                sudo "$SYSTEMCTL_BIN" reboot --force --no-block && return 0
                sudo "$SYSTEMCTL_BIN" reboot --force && return 0
            fi
        fi
        if command -v reboot >/dev/null 2>&1; then
            if (( EUID == 0 )); then
                reboot -f && return 0
            else
                sudo reboot -f && return 0
            fi
        fi
    else
        if [[ -n "$SYSTEMCTL_BIN" ]]; then
            if (( EUID == 0 )); then
                "$SYSTEMCTL_BIN" reboot && return 0
            else
                sudo "$SYSTEMCTL_BIN" reboot && return 0
            fi
        fi
        if command -v shutdown >/dev/null 2>&1; then
            if (( EUID == 0 )); then
                shutdown -r now && return 0
            else
                sudo shutdown -r now && return 0
            fi
        fi
        if command -v reboot >/dev/null 2>&1; then
            if (( EUID == 0 )); then
                reboot && return 0
            else
                sudo reboot && return 0
            fi
        fi
    fi
    return 1
}

suggest_similar_targets() {
    local query="$1"
    [[ -n "$PYTHON_BIN" ]] || return 0
    local i
    local -a candidates=()
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ -n "${DISTRO_FILTER:-}" && "${TARGET_DISTROS[i],,}" != "${DISTRO_FILTER,,}" ]]; then
            continue
        fi
        local disp="${TARGET_NAMES[i]}"
        [[ -n "${TARGET_VERSIONS[i]}" ]] && disp+=" ${TARGET_VERSIONS[i]}"
        candidates+=("$((i + 1))"$'\t'"$disp"$'\t'"${TARGET_LABELS[i]}")
    done
    (( ${#candidates[@]} > 0 )) || return 0
    printf '%s\n' "${candidates[@]}" | "$PYTHON_BIN" - "$query" << 'PYEOF' 2>/dev/null || true
import difflib, sys

q = sys.argv[1].lower().strip()
items = []
for raw in sys.stdin:
    parts = raw.rstrip("\n").split("\t")
    if len(parts) >= 2:
        items.append((parts[0], parts[1], parts[2] if len(parts) > 2 else ""))

scored = []
for idx, disp, lbl in items:
    r1 = difflib.SequenceMatcher(None, q, disp.lower()).ratio()
    r2 = difflib.SequenceMatcher(None, q, lbl.lower()).ratio()
    best = max(r1, r2)
    if best >= 0.42:
        scored.append((best, f"[{idx}] {disp}"))

scored.sort(key=lambda x: -x[0])
if scored:
    print(", ".join(x[1] for x in scored[:3]))
PYEOF
}

select_default_target() {
    MATCH_INDEX=-1
    MATCH_AMBIGUOUS=0
    MATCH_CANDIDATES=()
    local i fallback_idx=-1
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ -n "${DISTRO_FILTER:-}" && "${TARGET_DISTROS[i],,}" != "${DISTRO_FILTER,,}" ]]; then
            continue
        fi
        if [[ "${TARGET_DEFAULT[i]}" == "1" ]]; then
            MATCH_INDEX=$i
            return 0
        fi
        if (( fallback_idx == -1 )); then
            fallback_idx=$i
        fi
    done
    if (( fallback_idx != -1 )); then
        MATCH_INDEX=$fallback_idx
        return 0
    fi
    return 1
}

match_target() {
    local raw_query="$1"
    local normalized
    normalized="$(normalize_query "$raw_query")"
    MATCH_INDEX=-1
    MATCH_AMBIGUOUS=0
    MATCH_CANDIDATES=()
    local -a id_matches=()
    local -a full_matches=()
    local -a plain_matches=()
    local -a partial_matches=()
    local i display name version label id backend distro flavor
    if [[ "$raw_query" =~ ^[0-9]+$ ]]; then
        local idx=$((10#$raw_query - 1))
        if (( idx >= 0 && idx < ${#TARGET_IDS[@]} )); then
            if [[ -z "${DISTRO_FILTER:-}" || "${TARGET_DISTROS[idx],,}" == "${DISTRO_FILTER,,}" ]]; then
                MATCH_INDEX=$idx
                return 0
            fi
        fi
    fi
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        if [[ -n "${DISTRO_FILTER:-}" && "${TARGET_DISTROS[i],,}" != "${DISTRO_FILTER,,}" ]]; then
            continue
        fi
        backend="${TARGET_BACKENDS[i]}"
        id="${TARGET_IDS[i],,}"
        name="${TARGET_NAMES[i],,}"
        version="${TARGET_VERSIONS[i],,}"
        label="${TARGET_LABELS[i],,}"
        distro="${TARGET_DISTROS[i],,}"
        flavor="${TARGET_FLAVORS[i],,}"
        display="$name"
        [[ -n "$version" ]] && display+=" $version"
        if [[ "${raw_query,,}" == "$id" || "${raw_query,,}" == "boot$id" ]]; then
            id_matches+=("$i")
            continue
        fi
        if [[ "$normalized" == "$display" || "${raw_query,,}" == "$label" ]]; then
            full_matches+=("$i")
            continue
        fi
        if [[ "$normalized" == "$name" || ( -n "$distro" && "$normalized" == "$distro" && "$flavor" == "default" ) ]]; then
            plain_matches+=("$i")
            continue
        fi
        if [[ -n "$normalized" && ( "$display" == *"$normalized"* || "$label" == *"$normalized"* || "$version" == *"$normalized"* || "$flavor" == *"$normalized"* ) ]]; then
            partial_matches+=("$i")
        fi
    done
    if (( ${#id_matches[@]} == 1 )); then
        MATCH_INDEX="${id_matches[0]}"
        return 0
    elif (( ${#id_matches[@]} > 1 )); then
        MATCH_AMBIGUOUS=1
        MATCH_CANDIDATES=("${id_matches[@]}")
        return 1
    fi
    if (( ${#full_matches[@]} == 1 )); then
        MATCH_INDEX="${full_matches[0]}"
        return 0
    elif (( ${#full_matches[@]} > 1 )); then
        MATCH_AMBIGUOUS=1
        MATCH_CANDIDATES=("${full_matches[@]}")
        return 1
    fi
    if (( ${#plain_matches[@]} == 1 )); then
        MATCH_INDEX="${plain_matches[0]}"
        return 0
    elif (( ${#plain_matches[@]} > 1 )); then
        MATCH_AMBIGUOUS=1
        MATCH_CANDIDATES=("${plain_matches[@]}")
        return 1
    fi
    if (( ${#partial_matches[@]} == 1 )); then
        MATCH_INDEX="${partial_matches[0]}"
        return 0
    elif (( ${#partial_matches[@]} > 1 )); then
        MATCH_AMBIGUOUS=1
        MATCH_CANDIDATES=("${partial_matches[@]}")
        return 1
    fi
    return 1
}

format_match_candidates() {
    local idx text=""
    for idx in "${MATCH_CANDIDATES[@]}"; do
        [[ -n "$text" ]] && text+=", "
        text+="[#$((idx + 1))] ${TARGET_NAMES[idx]}"
        [[ -n "${TARGET_VERSIONS[idx]}" ]] && text+=" ${TARGET_VERSIONS[idx]}"
        text+=" [${TARGET_IDS[idx]}]"
    done
    printf '%s' "$text"
}

print_completions() {
    local i display
    printf '%s\n' "-h" "--help" "-v" "--version" "-l" "--list" "-t" "--test" "-f" "--force" "-y" "--yes" "-n" "--dry-run" "-p" "--status" "-c" "--clear" "-w" "--firmware" "-s" "--split-windows" "-u" "--cleanup-windows" "-d" "--distro" "-i" "--interactive" "-D" "--default" "-j" "--json"
    for ((i=0; i<${#TARGET_IDS[@]}; i++)); do
        display="${TARGET_NAMES[i]}"
        [[ -n "${TARGET_VERSIONS[i]}" ]] && display+=" ${TARGET_VERSIONS[i]}"
        printf '%s\n' "$display"
        printf '%s\n' "${TARGET_NAMES[i]}"
        printf '%s\n' "$((i + 1))"
    done
}

HELP_MODE=0
VERSION_MODE=0
LIST_MODE=0
TEST_MODE=0
FORCE_MODE=0
AUTO_YES=0
DRY_RUN_MODE=0
STATUS_MODE=0
CLEAR_MODE=0
FIRMWARE_MODE=0
SPLIT_WIN_MODE=0
CLEAN_WIN_MODE=0
COMPLETE_MODE=0
INTERACTIVE_MODE=0
DEFAULT_MODE=0
JSON_MODE=0
DISTRO_FILTER=""
POSITIONAL_ARGS=()

while (( $# > 0 )); do
    case "$1" in
        -h|--help) HELP_MODE=1; shift ;;
        -v|--version) VERSION_MODE=1; shift ;;
        -l|--list) LIST_MODE=1; shift ;;
        -t|--test) TEST_MODE=1; shift ;;
        -f|--force) FORCE_MODE=1; AUTO_YES=1; shift ;;
        -y|--yes) AUTO_YES=1; shift ;;
        -n|--dry-run) DRY_RUN_MODE=1; shift ;;
        -p|--status) STATUS_MODE=1; shift ;;
        -c|--clear) CLEAR_MODE=1; shift ;;
        -w|--firmware) FIRMWARE_MODE=1; shift ;;
        -s|--split-windows) SPLIT_WIN_MODE=1; shift ;;
        -u|--cleanup-windows) CLEAN_WIN_MODE=1; shift ;;
        -i|--interactive) INTERACTIVE_MODE=1; shift ;;
        -D|--default) DEFAULT_MODE=1; shift ;;
        -j|--json) JSON_MODE=1; shift ;;
        -d|--distro)
            shift
            if (( $# == 0 )); then
                print_failed "Option -d|--distro requires a Linux distribution name."
                exit 1
            fi
            DISTRO_FILTER="$(normalize_distro_id "$1")"
            shift
            ;;
        --distro=*)
            DISTRO_FILTER="$(normalize_distro_id "${1#--distro=}")"
            shift
            ;;
        --complete) COMPLETE_MODE=1; shift ;;
        --) shift; POSITIONAL_ARGS+=("$@"); break ;;
        -*)
            opts="${1#-}"
            [[ -n "$opts" ]] || { print_failed "Invalid empty option '-'"; exit 1; }
            for ((idx=0; idx<${#opts}; idx++)); do
                ch="${opts:idx:1}"
                case "$ch" in
                    h) HELP_MODE=1 ;;
                    v) VERSION_MODE=1 ;;
                    l) LIST_MODE=1 ;;
                    t) TEST_MODE=1 ;;
                    f) FORCE_MODE=1; AUTO_YES=1 ;;
                    y) AUTO_YES=1 ;;
                    n) DRY_RUN_MODE=1 ;;
                    p) STATUS_MODE=1 ;;
                    c) CLEAR_MODE=1 ;;
                    w) FIRMWARE_MODE=1 ;;
                    s) SPLIT_WIN_MODE=1 ;;
                    u) CLEAN_WIN_MODE=1 ;;
                    i) INTERACTIVE_MODE=1 ;;
                    D) DEFAULT_MODE=1 ;;
                    j) JSON_MODE=1 ;;
                    *) print_failed "Unknown option '-$ch'. Run 'boot -h' for usage."; exit 1 ;;
                esac
            done
            shift
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done

if (( VERSION_MODE == 1 )); then
    printf 'boot %s\n' "$BOOT_SCRIPT_VERSION"
    exit 0
fi

if (( CLEAR_MODE == 1 )); then
    clear_next_boot
    exit 0
fi

if (( FIRMWARE_MODE == 1 )); then
    if (( DRY_RUN_MODE == 1 )); then
        print_info "Dry-run: would indicate UEFI Firmware / BIOS setup and reboot."
        exit 0
    fi
    if (( AUTO_YES == 0 )); then
        printf 'Reboot directly into UEFI Firmware / BIOS setup? [y/N] '
        read -r REPLY
        if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
            print_info "Cancelled."
            exit 0
        fi
    fi
    reboot_to_firmware || exit 1
    exit 0
fi

if (( CLEAN_WIN_MODE == 1 )); then
    clean_isolated_windows_entries
    exit 0
fi

scan_targets

if (( COMPLETE_MODE == 1 )); then
    print_completions
    exit 0
fi

if (( JSON_MODE == 1 )); then
    show_json
    exit 0
fi

if (( STATUS_MODE == 1 )); then
    show_status
    exit 0
fi

if (( SPLIT_WIN_MODE == 1 )); then
    split_all_windows_bcd
    exit 0
fi

if (( LIST_MODE == 1 )); then
    show_list
    exit 0
fi

if (( HELP_MODE == 1 )); then
    show_help
    exit 0
fi

if (( INTERACTIVE_MODE == 1 )); then
    show_help
    printf '\n'
    if (( ${#TARGET_IDS[@]} == 0 )); then
        print_failed "No boot targets available for selection."
        exit 1
    fi
    printf 'Select boot target [1-%s] (or q to cancel): ' "${#TARGET_IDS[@]}"
    read -r REPLY
    if [[ "$REPLY" =~ ^[Qq]$ || -z "$REPLY" ]]; then
        print_info "Cancelled."
        exit 0
    fi
    POSITIONAL_ARGS=("$REPLY")
fi

TARGET_QUERY="${POSITIONAL_ARGS[*]:-}"

if (( DEFAULT_MODE == 1 )); then
    if ! select_default_target; then
        print_failed "No default boot target found."
        exit 1
    fi
else
    if [[ -z "$TARGET_QUERY" ]]; then
        show_help
        exit 0
    fi
    if (( ${#TARGET_IDS[@]} == 0 )); then
        print_failed "No bootable OS or kernel entries found."
        exit 1
    fi
    if ! match_target "$TARGET_QUERY"; then
        if (( MATCH_AMBIGUOUS == 1 )); then
            print_failed "More than one entry matches '${TARGET_QUERY}': $(format_match_candidates). Specify the full name, kernel version, index number, or boot entry ID."
        else
            suggestion="$(suggest_similar_targets "$TARGET_QUERY")"
            if [[ -n "$suggestion" ]]; then
                print_failed "No installed OS or kernel matches '${TARGET_QUERY}'. Did you mean: ${suggestion}? Run 'boot -h' to see available targets."
            else
                print_failed "No installed OS or kernel matches '${TARGET_QUERY}'. Run 'boot -h' to see available targets."
            fi
        fi
        exit 1
    fi
fi

if (( TEST_MODE == 1 )); then
    verify_target "$MATCH_INDEX"
    exit $?
fi

if (( DRY_RUN_MODE == 1 )); then
    verify_target "$MATCH_INDEX" || exit 1
    show_dry_run_plan "$MATCH_INDEX"
    exit 0
fi

TARGET_DISPLAY="${TARGET_NAMES[MATCH_INDEX]}"
[[ -n "${TARGET_VERSIONS[MATCH_INDEX]}" ]] && TARGET_DISPLAY+=" ${TARGET_VERSIONS[MATCH_INDEX]}"

if (( AUTO_YES == 0 )); then
    if (( FORCE_MODE == 1 )); then
        printf 'Force reboot into %s (%s) now (unsaved app data will be lost)? [y/N] ' "$TARGET_DISPLAY" "${TARGET_LABELS[MATCH_INDEX]}"
    else
        printf 'Reboot into %s (%s)? [y/N] ' "$TARGET_DISPLAY" "${TARGET_LABELS[MATCH_INDEX]}"
    fi
    read -r REPLY
    if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi
fi

if ! set_next_boot "$MATCH_INDEX"; then
    print_failed "Could not configure next boot entry for '${TARGET_DISPLAY}'."
    exit 1
fi

print_success "Configured next boot to ${TARGET_DISPLAY}."

if ! trigger_reboot; then
    print_failed "Boot target was set, but system reboot failed."
    exit 1
fi
