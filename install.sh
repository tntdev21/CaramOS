#!/usr/bin/env bash
# CaramOS one-liner installer — download ISO, verify SHA256, write USB
# Usage: curl -fsSL https://raw.githubusercontent.com/VN-Linux-Family/CaramOS/main/install.sh | bash
set -euo pipefail

readonly GITHUB_API="https://api.github.com/repos/VN-Linux-Family/CaramOS/releases/latest"
readonly RELEASE_PAGE="https://github.com/VN-Linux-Family/CaramOS/releases/latest"
readonly ISO_DIR="${HOME}/Downloads/caramos-iso"
readonly MIN_FREE_KB=$((3584 * 1024))   # 3.5 GB in KiB

OS_KIND="" SHA_CMD="" LIST_USB_CMD="" EJECT_CMD=""
ISO_URL="" SHA256SUMS_URL="" VERSION="" ISO_NAME="" ISO_PATH=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  _R='\033[0;31m' _Y='\033[1;33m' _G='\033[0;32m' _C='\033[0;36m' _0='\033[0m'
else
  _R='' _Y='' _G='' _C='' _0=''
fi
info() { printf "${_C}[INFO]${_0}      %s\n" "$*"; }
warn() { printf "${_Y}[CẢNH BÁO]${_0} %s\n" "$*"; }
err()  { printf "${_R}[LỖI]${_0}      %s\n" "$*" >&2; }
ok()   { printf "${_G}[OK]${_0}        %s\n" "$*"; }

# ── Arg parsing ─────────────────────────────────────────────────────────────
LOCAL_ISO=""

print_help() {
  printf "Usage: bash install.sh [OPTIONS]\n\n"
  printf "Options:\n"
  printf "  --local <path>    Dùng ISO local thay vì tải từ GitHub Releases (cho test/dev)\n"
  printf "  -h, --help        Hiện trợ giúp\n\n"
  printf "Mặc định: tải ISO latest từ GitHub Releases của VN-Linux-Family/CaramOS.\n"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL_ISO="${2:-}"; shift 2 ;;
    --local=*) LOCAL_ISO="${1#--local=}"; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) err "Unknown arg: $1"; exit 1 ;;
  esac
done

detect_os() {
  local kernel; kernel=$(uname -s)
  case "$kernel" in
    Linux)
      OS_KIND="Linux"; SHA_CMD="sha256sum"
      LIST_USB_CMD="lsblk -dpno NAME,SIZE,MODEL"; EJECT_CMD="eject" ;;
    Darwin)
      OS_KIND="macOS"; SHA_CMD="shasum -a 256"
      LIST_USB_CMD="diskutil list external"; EJECT_CMD="diskutil eject" ;;
    *)
      err "Hệ điều hành '$kernel' chưa được hỗ trợ. Chỉ hỗ trợ Linux và macOS."
      return 1 ;;
  esac
  info "Hệ điều hành: $OS_KIND"
}

check_deps() {
  local missing=0 deps=(curl dd)
  [[ "$OS_KIND" == "Linux" ]] && deps+=(sha256sum) || deps+=(shasum)
  for cmd in "${deps[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "Thiếu lệnh: $cmd"
      [[ "$OS_KIND" == "Linux" ]] && warn "  → sudo apt install $cmd" || warn "  → brew install $cmd"
      missing=1
    fi
  done
  [[ $missing -ne 0 ]] && { err "Vui lòng cài đặt lệnh còn thiếu rồi chạy lại."; return 1; }
  ok "Tất cả công cụ cần thiết đã có."
}

ensure_iso_dir() {
  mkdir -p "$ISO_DIR"; info "Thư mục lưu ISO: $ISO_DIR"
  # df -k: 1KiB blocks — portable on Linux and macOS
  local avail_kb; avail_kb=$(df -k "$ISO_DIR" | awk 'NR==2 {print $4}')
  if [[ -z "$avail_kb" || "$avail_kb" -lt "$MIN_FREE_KB" ]]; then
    err "Không đủ dung lượng. Cần ít nhất 3.5 GB, hiện có ~$(( ${avail_kb:-0} / 1024 / 1024 )) GB."
    return 1
  fi
  ok "Dung lượng đĩa trống đủ."
}

# Security: only allow downloads from github.com or objects.githubusercontent.com
_validate_url() {
  printf '%s' "$1" | grep -qE 'https://(github\.com|objects\.githubusercontent\.com)/' && return 0
  err "URL không hợp lệ: $1"; return 1
}

fetch_release_meta() {
  info "Đang lấy thông tin phiên bản mới nhất từ GitHub..."
  local meta
  if ! meta=$(curl -fsSL --retry 3 "$GITHUB_API" 2>/dev/null); then
    err "Không thể kết nối GitHub API. Kiểm tra mạng hoặc mở:"
    warn "  $RELEASE_PAGE"
    return 1
  fi

  # Parse with grep+sed — no jq required
  ISO_URL=$(printf '%s' "$meta" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]+\.iso"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  SHA256SUMS_URL=$(printf '%s' "$meta" \
    | grep -oE '"browser_download_url":[[:space:]]*"[^"]+SHA256SUMS[^"]*"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')
  VERSION=$(printf '%s' "$meta" \
    | grep -oE '"tag_name":[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"$/\1/')

  if [[ -z "$ISO_URL" || -z "$SHA256SUMS_URL" || -z "$VERSION" ]]; then
    err "Không thể phân tích release (API rate limit 60/h?). Tải thủ công:"
    warn "  $RELEASE_PAGE"
    return 1
  fi

  _validate_url "$ISO_URL"        || return 1
  _validate_url "$SHA256SUMS_URL" || return 1

  ISO_NAME=$(basename "$ISO_URL")
  ISO_PATH="${ISO_DIR}/${ISO_NAME}"
  ok "Phiên bản: $VERSION  |  ISO: $ISO_NAME"
}

download_iso() {
  info "Đang tải SHA256SUMS..."
  curl -fsSL --retry 3 -o "${ISO_DIR}/SHA256SUMS" "$SHA256SUMS_URL" \
    || { err "Tải SHA256SUMS thất bại. Kiểm tra kết nối mạng."; return 1; }
  info "Đang tải ISO $ISO_NAME (tự động tiếp tục nếu bị ngắt)..."
  # -C - resumes from already-downloaded bytes
  if ! curl -C - -fL --retry 3 --progress-bar -o "$ISO_PATH" "$ISO_URL"; then
    err "Tải ISO thất bại sau 3 lần thử."; warn "  Tải thủ công: $RELEASE_PAGE"; return 1
  fi
  ok "Tải ISO hoàn tất: $ISO_PATH"
}

verify_iso() {
  local attempt=${1:-0}
  if [ "$attempt" -ge 2 ]; then
    err "Xác minh thất bại 2 lần liên tiếp, dừng cài đặt."
    exit 1
  fi
  info "Đang xác minh checksum SHA256..."
  local result=0
  # Subshell cd so relative paths in SHA256SUMS resolve correctly
  (
    cd "$ISO_DIR"
    if [[ "$OS_KIND" == "Linux" ]]; then
      sha256sum -c SHA256SUMS --ignore-missing
    else
      # macOS shasum lacks --ignore-missing; extract the relevant line manually
      local line; line=$(grep "$ISO_NAME" SHA256SUMS 2>/dev/null || true)
      [[ -z "$line" ]] && { echo "Không tìm thấy checksum cho $ISO_NAME" >&2; exit 1; }
      printf '%s\n' "$line" | shasum -a 256 -c
    fi
  ) || result=$?

  if [[ $result -ne 0 ]]; then
    err "Xác minh checksum thất bại! File ISO có thể bị hỏng."
    local answer="y"
    if [[ -t 0 ]]; then
      printf "${_Y}Xóa file hỏng và tải lại? [Y/n]: ${_0}"
      read -r answer || true
    fi
    if [[ "${answer:-y}" =~ ^[Nn] ]]; then
      warn "Bỏ qua. File hỏng vẫn còn tại: $ISO_PATH"
      return 1
    fi
    rm -f "$ISO_PATH"
    info "Đã xóa file hỏng. Đang tải lại..."
    download_iso
    verify_iso $(( attempt + 1 ))
    return $?
  fi

  ok "Checksum hợp lệ. ISO không bị lỗi."
}

# Phase 2 runtime vars
USB_LIST=() SYSTEM_DISK="" USB_DEV="" USB_DEV_SIZE="" USB_DEV_MODEL="" USB_DEV_LABEL=""

_get_system_disk() {
  if [[ "$OS_KIND" == "Linux" ]]; then
    SYSTEM_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
  else
    SYSTEM_DISK=$(diskutil info / 2>/dev/null | grep "Part of Whole" | awk '{print $NF}' || echo "disk0")
  fi
}

list_usb_devices() {
  USB_LIST=()
  printf "\n${_C}%-4s %-20s %-14s %-10s %s${_0}\n" "#" "TÊN (LABEL)" "THIẾT BỊ" "DUNG LƯỢNG" "MODEL"
  printf "%s\n" "-------------------------------------------------------------------------"
  local idx=0
  if [[ "$OS_KIND" == "Linux" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name size tran rm model
      # MODEL ở cuối để hứng phần còn lại (model có thể chứa khoảng trắng)
      read -r name size tran rm model <<< "$line"
      [[ "$tran" != "usb" || "$rm" != "1" ]] && continue
      # Volume label: lấy partition đầu tiên có LABEL non-empty
      local label
      label=$(lsblk -nlo LABEL "/dev/$name" 2>/dev/null | awk 'NF{print; exit}')
      [[ -z "$label" ]] && label="(trống)"
      idx=$(( idx + 1 ))
      USB_LIST+=("${name}:${size}:${label}:${model}")
      printf "%-4s %-20s %-14s %-10s %s\n" "$idx" "$label" "/dev/$name" "$size" "$model"
    done < <(lsblk -d -no NAME,SIZE,TRAN,RM,MODEL 2>/dev/null)
  else
    while IFS= read -r line; do
      # Line format on macOS: "/dev/disk5 (external, physical):"
      local disk; disk=$(printf '%s' "$line" | grep -oE 'disk[0-9]+' | head -1 || true)
      [[ -z "$disk" ]] && continue
      local dinfo; dinfo=$(diskutil info "/dev/$disk" 2>/dev/null || true)
      local size; size=$(printf '%s' "$dinfo" | grep "Disk Size" | awk '{print $3,$4}')
      local model; model=$(printf '%s' "$dinfo" | grep "Device / Media Name" | cut -d: -f2 | xargs)
      # Volume label: tìm partition đầu có Volume Name
      local label=""
      local p
      for p in $(diskutil list "/dev/$disk" 2>/dev/null | awk '/^ *[0-9]+:/ {print $NF}' | grep -E "^${disk}s[0-9]+$"); do
        local vname; vname=$(diskutil info "/dev/$p" 2>/dev/null | awk -F: '/Volume Name/ {sub(/^ +/,"",$2); print $2; exit}')
        if [[ -n "$vname" && "$vname" != "Not applicable (no file system)" ]]; then
          label="$vname"; break
        fi
      done
      [[ -z "$label" ]] && label="(trống)"
      idx=$(( idx + 1 ))
      USB_LIST+=("${disk}:${size}:${label}:${model}")
      printf "%-4s %-20s %-14s %-10s %s\n" "$idx" "$label" "/dev/$disk" "$size" "$model"
    done < <(diskutil list external physical 2>/dev/null | grep "^/dev/" || true)
  fi
  printf "%s\n\n" "-------------------------------------------------------------------------"
}

validate_device() {
  local name="$1"
  # Reject path injection: only lowercase letters and digits (e.g. sdb, sdc, disk4, nvme0n1)
  if ! [[ "$name" =~ ^[a-z][a-z0-9]+$ ]]; then
    err "Tên thiết bị không hợp lệ: '$name'. Chỉ chấp nhận dạng sdb, disk4, nvme0n1, ..."; return 1
  fi
  # macOS: /dev/diskN is a character device (-c), Linux: block device (-b). Accept either.
  [[ ! -b "/dev/$name" && ! -c "/dev/$name" ]] && { err "Thiết bị /dev/$name không tồn tại."; return 1; }
  [[ -n "$SYSTEM_DISK" && "$name" == "$SYSTEM_DISK" ]] && {
    err "Đây là ổ cứng hệ thống ($SYSTEM_DISK), từ chối. Vui lòng chọn USB khác."; return 1; }
  local found=0
  for entry in "${USB_LIST[@]}"; do
    [[ "${entry%%:*}" == "$name" ]] || continue
    found=1; USB_DEV_SIZE=$(printf '%s' "$entry" | cut -d: -f2)
    USB_DEV_LABEL=$(printf '%s' "$entry" | cut -d: -f3)
    USB_DEV_MODEL=$(printf '%s' "$entry" | cut -d: -f4-); break
  done
  [[ $found -eq 0 ]] && { err "/dev/$name không nằm trong danh sách USB tháo rời."; return 1; }
  local size_bytes=0
  if [[ "$OS_KIND" == "Linux" ]]; then
    size_bytes=$(blockdev --getsize64 "/dev/$name" 2>/dev/null || echo 0)
  else
    local dinfo; dinfo=$(diskutil info "/dev/$name" 2>/dev/null || true)
    size_bytes=$(printf '%s' "$dinfo" | grep "Disk Size" | grep -oE '\([0-9]+' | tr -d '(' || echo 0)
  fi
  [[ "$size_bytes" -lt 4294967296 ]] && {
    err "USB quá nhỏ: cần ít nhất 4 GB (hiện ~$(( size_bytes / 1073741824 )) GB)."; return 1; }
  return 0
}

prompt_device() {
  while true; do
    printf "${_Y}Gõ tên hoặc đường dẫn thiết bị USB (vd: disk5 hoặc /dev/disk5): ${_0}"
    local input; read -r input || { err "Không đọc được input."; return 1; }
    input="${input// /}"
    # Accept full path /dev/diskN — strip /dev/ prefix
    input="${input#/dev/}"
    validate_device "$input" && USB_DEV="$input" && return 0
    warn "Thử lại."
  done
}

unmount_device_parts() {
  info "Đang ngắt kết nối các phân vùng của /dev/$1..."
  if [[ "$OS_KIND" == "Linux" ]]; then
    lsblk -nlo NAME "/dev/$1" 2>/dev/null | tail -n +2 \
      | xargs -I{} sudo umount "/dev/{}" 2>/dev/null || true
  else
    sudo diskutil unmountDisk "/dev/$1" >/dev/null 2>&1 || true
  fi
  ok "Đã ngắt kết nối."
}

confirm_write() {
  while true; do
    local display="${USB_DEV_LABEL:-/dev/$1}"
    [[ "$display" == "(trống)" ]] && display="/dev/$1"
    printf "\n${_R}⚠️  Sẽ XÓA TOÀN BỘ %s (%s %s).${_0}\n" "$display" "$USB_DEV_SIZE" "$USB_DEV_MODEL"
    printf "${_R}\033[1m   Nhấn Enter để tiếp tục (XÓA), hoặc gõ N để hủy.${_0}\n"
    printf "${_Y}Tiếp tục? [Y/n]: ${_0}"; local ans; read -r ans || ans="Y"; ans="${ans:-Y}"
    case "$ans" in
      [yY]) return 0 ;;
      [nN]) err "Đã hủy. Không có gì bị thay đổi."; return 1 ;;
      *)    warn "Vui lòng nhập Y hoặc N." ;;
    esac
  done
}

_format_eta() {
  # input: seconds (int); output: "Xm Ys" hoặc "Ys"
  local s=$1
  if [[ "$s" -ge 60 ]]; then printf "%dm %02ds" $((s/60)) $((s%60)); else printf "%ds" "$s"; fi
}

_render_progress() {
  # args: bytes_done total_bytes speed_mbps eta_seconds
  local done=$1 total=$2 speed=$3 eta=$4
  local pct="0.000" done_gb total_gb
  # awk dùng để chia float — bash int chia không có thập phân
  [[ "$total" -gt 0 ]] && pct=$(awk -v d="$done" -v t="$total" 'BEGIN{printf "%.3f", d*100/t}')
  done_gb=$(awk -v b="$done" 'BEGIN{printf "%.2f", b/1073741824}')
  total_gb=$(awk -v b="$total" 'BEGIN{printf "%.2f", b/1073741824}')
  # \r overwrite cùng dòng + \033[K xoá phần thừa cuối dòng
  printf "\r\033[K${_C}[GHI]${_0}       %s%% (%s/%s GB), tốc độ %s MB/s, dự kiến xong trong %s" \
    "$pct" "$done_gb" "$total_gb" "$speed" "$(_format_eta "$eta")"
}

write_iso_to_usb() {
  # \033[1;31m = bold red; giữ phong cách [INFO] cyan
  printf "${_C}[INFO]      Đang ghi ISO vào /dev/%s — \033[1;31mKHÔNG rút USB\033[0m${_C} trong lúc ghi...${_0}\n" "$1"
  local total_bytes target sig
  if [[ "$OS_KIND" == "Linux" ]]; then
    total_bytes=$(stat -c%s "$ISO_PATH"); target="/dev/$1"; sig="USR1"
  else
    total_bytes=$(stat -f%z "$ISO_PATH"); target="/dev/r${1}"; sig="INFO"
  fi
  local tmpf; tmpf=$(mktemp -t carambos-dd.XXXXXX)
  # Linux dd: bs=4M; macOS dd: bs=4m
  local bs="4M"; [[ "$OS_KIND" != "Linux" ]] && bs="4m"
  local extra=""; [[ "$OS_KIND" == "Linux" ]] && extra="conv=fsync"
  # shellcheck disable=SC2086
  sudo dd if="$ISO_PATH" of="$target" bs="$bs" $extra 2>"$tmpf" &
  local sudo_pid=$!
  # PID thật của dd là con của sudo; signal phải gửi tới dd, không phải sudo
  # Thử pgrep -P trước; macOS đôi khi không thấy child do quyền → fallback pgrep -x dd của user root
  local dd_pid=""
  local tries=0
  while [[ -z "$dd_pid" && "$tries" -lt 30 ]]; do
    sleep 0.1
    dd_pid=$(pgrep -P "$sudo_pid" -x dd 2>/dev/null | head -1 || true)
    if [[ -z "$dd_pid" ]]; then
      # Fallback: tìm dd process gần nhất đang ghi vào target
      dd_pid=$(sudo pgrep -nx dd 2>/dev/null | head -1 || true)
    fi
    tries=$((tries+1))
  done
  [[ -z "$dd_pid" ]] && dd_pid="$sudo_pid"
  local prev_bytes=0 prev_t shown=0
  # date +%s.%N hỗ trợ trên Linux; macOS BSD date không có %N → dùng python/perl fallback
  if date +%s.%N 2>/dev/null | grep -q '\.'; then
    prev_t=$(date +%s.%N)
    _NOW_CMD='date +%s.%N'
  elif command -v python3 >/dev/null 2>&1; then
    _NOW_CMD='python3 -c "import time;print(time.time())"'
    prev_t=$(eval "$_NOW_CMD")
  else
    _NOW_CMD='date +%s'
    prev_t=$(eval "$_NOW_CMD")
  fi
  # 2 nhịp: % refresh nhanh 0.02s; speed/ETA tính + cache mỗi ~2s (bytes thay đổi nhanh nhưng tốc độ ổn định)
  local cached_speed=0 cached_eta=0
  local SPEED_INTERVAL=3
  while kill -0 "$sudo_pid" 2>/dev/null; do
    sleep 0.02
    sudo kill -"$sig" "$dd_pid" 2>/dev/null || true
    local line bytes_done
    line=$(grep -aE '^[0-9]+ bytes' "$tmpf" 2>/dev/null | tail -1 || true)
    [[ -z "$line" ]] && continue
    bytes_done=$(printf '%s' "$line" | awk '{print $1}')
    [[ -z "$bytes_done" || ! "$bytes_done" =~ ^[0-9]+$ ]] && continue
    [[ "$bytes_done" -eq 0 ]] && continue
    local now dt_int
    now=$(eval "$_NOW_CMD")
    dt_int=$(awk -v p="$prev_t" -v n="$now" 'BEGIN{printf "%d", n-p}')
    # Tính speed + ETA: ngay lần đầu (chưa hiển thị) HOẶC khi đã đủ SPEED_INTERVAL giây từ lần cập nhật trước
    if [[ "$shown" -eq 0 || "$dt_int" -ge "$SPEED_INTERVAL" ]]; then
      local db remain
      db=$(( bytes_done - prev_bytes ))
      cached_speed=$(awk -v db="$db" -v p="$prev_t" -v n="$now" 'BEGIN{dt=n-p; if(dt<0.05)dt=0.05; printf "%d", db/dt/1048576}')
      [[ "$cached_speed" -lt 1 && "$bytes_done" -gt "$prev_bytes" ]] && cached_speed=1
      remain=$(( total_bytes - bytes_done ))
      if [[ "$cached_speed" -gt 0 ]]; then cached_eta=$(( remain / 1048576 / cached_speed )); else cached_eta=0; fi
      prev_bytes=$bytes_done; prev_t=$now
    fi
    _render_progress "$bytes_done" "$total_bytes" "$cached_speed" "$cached_eta"
    shown=1
  done
  wait "$sudo_pid" || { [[ "$shown" -eq 1 ]] && printf "\n"; rm -f "$tmpf"; err "dd thất bại."; return 1; }
  # Line cuối: chỉ % + dung lượng, bỏ speed/ETA vì đã xong
  local total_gb; total_gb=$(awk -v b="$total_bytes" 'BEGIN{printf "%.2f", b/1073741824}')
  printf "\r\033[K${_C}[GHI]${_0}       100%% (%s/%s GB)\n" "$total_gb" "$total_gb"
  rm -f "$tmpf"
  sync; ok "Ghi ISO hoàn tất."
}

verify_usb_write() {
  info "Đang xác minh dữ liệu USB (1 MB đầu)..."
  local iso_head usb_head
  iso_head=$(head -c 1048576 "$ISO_PATH" | $SHA_CMD | awk '{print $1}')
  usb_head=$(sudo head -c 1048576 "/dev/$1" | $SHA_CMD | awk '{print $1}')
  [[ "$iso_head" == "$usb_head" ]] || { err "Xác minh USB thất bại! Dữ liệu ghi không khớp ISO."; return 1; }
  ok "Xác minh thành công — USB ghi đúng."
}

eject_device() {
  info "Đang eject /dev/$1..."
  if [[ "$OS_KIND" == "Linux" ]]; then
    command -v udisksctl >/dev/null 2>&1 \
      && sudo udisksctl power-off -b "/dev/$1" >/dev/null 2>&1 && ok "Đã eject." && return 0
    sync; command -v eject >/dev/null 2>&1 \
      && sudo eject "/dev/$1" >/dev/null 2>&1 && ok "Đã eject." && return 0
    warn "Không tự eject được. Vui lòng rút USB ra bằng tay."
  else
    sudo diskutil eject "/dev/$1" >/dev/null 2>&1 && ok "Đã eject." \
      || warn "Không tự eject được. Vui lòng rút USB ra bằng tay."
  fi
}

print_boot_guide() {
  printf "\n${_G}╔══════════════════════════════════════════════╗${_0}\n"
  printf   "${_G}║     HƯỚNG DẪN KHỞI ĐỘNG TỪ USB               ║${_0}\n"
  printf   "${_G}╚══════════════════════════════════════════════╝${_0}\n"
  printf "1. Cắm USB vào máy tính cần cài CaramOS.\n"
  printf "2. Khởi động lại, nhấn phím vào Boot Menu:\n"
  printf "   • ${_Y}F12${_0} — Dell, Lenovo, Asus, Acer\n"
  printf "   • ${_Y}F2 / F10${_0} — HP, Samsung\n"
  printf "   • ${_Y}Del / Esc${_0} — nhiều main board desktop\n"
  printf "3. Chọn thiết bị USB trong Boot Menu.\n"
  printf "4. Chọn '${_C}Thử CaramOS${_0}' (live) hoặc '${_C}Cài đặt CaramOS${_0}'.\n\n"
}

prompt_cleanup_iso() {
  if [[ -n "$LOCAL_ISO" ]]; then
    info "Bỏ qua prompt cleanup (ISO local của bạn)"
    return 0
  fi
  printf "${_Y}Xóa ISO %s để tiết kiệm dung lượng? [y/N]: ${_0}" "$ISO_NAME"
  local ans; read -r ans || ans="N"; ans="${ans:-N}"
  if [[ "$ans" =~ ^[yY]$ ]]; then rm "$ISO_PATH" && ok "Đã xóa $ISO_PATH"
  else info "Giữ lại ISO: $ISO_PATH"; fi
}

# --- main: full flow (Phase 1: download+verify; Phase 2: USB write) -----------
main() {
  info "=== CaramOS Installer ==="
  detect_os; check_deps

  # Guardrail: detect USB + user xác nhận chọn device TRƯỚC khi tải/verify ISO.
  # Lý do: tránh user tải 3GB rồi mới phát hiện không có USB.
  _get_system_disk
  while true; do
    info "Quét thiết bị USB đang kết nối..."
    list_usb_devices
    if [[ ${#USB_LIST[@]} -eq 0 ]]; then
      err "Không tìm thấy USB nào đang kết nối."
      warn "Vui lòng cắm USB (≥ 4GB) rồi nhấn Enter để quét lại (hoặc Ctrl+C để thoát)..."
      read -r _ || true; continue
    fi
    prompt_device && break
  done
  confirm_write "$USB_DEV"
  ok "Đã xác nhận USB: /dev/$USB_DEV"

  if [[ -n "$LOCAL_ISO" ]]; then
    [[ -f "$LOCAL_ISO" ]] || { err "ISO không tồn tại: $LOCAL_ISO"; exit 1; }
    ISO_PATH="$(cd "$(dirname "$LOCAL_ISO")" && pwd)/$(basename "$LOCAL_ISO")"
    ISO_NAME="$(basename "$LOCAL_ISO")"
    info "Sử dụng ISO local: $ISO_PATH (bỏ qua download + SHA256 verify)"
    warn "⚠️  Đang ở chế độ DEV — chỉ dùng ISO bạn tự build/tin tưởng"
  else
    ensure_iso_dir
    fetch_release_meta; download_iso; verify_iso
  fi
  ok "✓ ISO sẵn sàng: $ISO_PATH"

  unmount_device_parts "$USB_DEV"
  write_iso_to_usb "$USB_DEV"
  verify_usb_write "$USB_DEV"
  eject_device "$USB_DEV"
  print_boot_guide
  prompt_cleanup_iso
}

main "$@"
