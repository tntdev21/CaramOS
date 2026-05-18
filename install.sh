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

detect_os() {
  local kernel; kernel=$(uname -s)
  case "$kernel" in
    Linux)
      OS_KIND="Linux"; SHA_CMD="sha256sum"
      LIST_USB_CMD="lsblk -dpno NAME,SIZE,MODEL"; EJECT_CMD="eject" ;;
    Darwin)
      OS_KIND="Darwin"; SHA_CMD="shasum -a 256"
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
USB_LIST=() SYSTEM_DISK="" USB_DEV="" USB_DEV_SIZE="" USB_DEV_MODEL=""

_get_system_disk() {
  if [[ "$OS_KIND" == "Linux" ]]; then
    SYSTEM_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null || true)
  else
    SYSTEM_DISK=$(diskutil info / 2>/dev/null | grep "Part of Whole" | awk '{print $NF}' || echo "disk0")
  fi
}

list_usb_devices() {
  USB_LIST=()
  printf "\n${_C}%-4s %-12s %-10s %s${_0}\n" "#" "THIẾT BỊ" "DUNG LƯỢNG" "MODEL"
  printf "%s\n" "--------------------------------------------"
  local idx=0
  if [[ "$OS_KIND" == "Linux" ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      local name size tran rm model
      # MODEL ở cuối để hứng toàn bộ phần còn lại (xử lý model có khoảng trắng, vd "SanDisk Ultra Fit")
      read -r name size tran rm model <<< "$line"
      [[ "$tran" != "usb" || "$rm" != "1" ]] && continue
      idx=$(( idx + 1 ))
      USB_LIST+=("${name}:${size}:${model}")
      printf "%-4s %-12s %-10s %s\n" "$idx" "/dev/$name" "$size" "$model"
    done < <(lsblk -d -no NAME,SIZE,TRAN,RM,MODEL 2>/dev/null)
  else
    while IFS= read -r line; do
      local disk; disk=$(printf '%s' "$line" | grep -oE 'disk[0-9]+$' | head -1 || true)
      [[ -z "$disk" ]] && continue
      local dinfo; dinfo=$(diskutil info "/dev/$disk" 2>/dev/null || true)
      local size; size=$(printf '%s' "$dinfo" | grep "Disk Size" | awk '{print $3,$4}')
      local model; model=$(printf '%s' "$dinfo" | grep "Device / Media Name" | cut -d: -f2 | xargs)
      idx=$(( idx + 1 ))
      USB_LIST+=("${disk}:${size}:${model}")
      printf "%-4s %-12s %-10s %s\n" "$idx" "/dev/$disk" "$size" "$model"
    done < <(diskutil list external physical 2>/dev/null | grep "^/dev/" || true)
  fi
  printf "%s\n\n" "--------------------------------------------"
}

validate_device() {
  local name="$1"
  # Reject path injection: only lowercase letters and digits (e.g. sdb, sdc, disk4, nvme0n1)
  if ! [[ "$name" =~ ^[a-z][a-z0-9]+$ ]]; then
    err "Tên thiết bị không hợp lệ: '$name'. Chỉ chấp nhận dạng sdb, disk4, nvme0n1, ..."; return 1
  fi
  [[ ! -b "/dev/$name" ]] && { err "Thiết bị /dev/$name không tồn tại."; return 1; }
  [[ -n "$SYSTEM_DISK" && "$name" == "$SYSTEM_DISK" ]] && {
    err "Đây là ổ cứng hệ thống ($SYSTEM_DISK), từ chối. Vui lòng chọn USB khác."; return 1; }
  local found=0
  for entry in "${USB_LIST[@]}"; do
    [[ "${entry%%:*}" == "$name" ]] || continue
    found=1; USB_DEV_SIZE=$(printf '%s' "$entry" | cut -d: -f2)
    USB_DEV_MODEL=$(printf '%s' "$entry" | cut -d: -f3-); break
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
    printf "${_Y}Gõ tên thiết bị USB (vd: sdb hoặc disk4): ${_0}"
    local input; read -r input || { err "Không đọc được input."; return 1; }
    input="${input// /}"
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
    sudo diskutil unmountDisk "/dev/$1" 2>/dev/null || true
  fi
  ok "Đã ngắt kết nối."
}

confirm_write() {
  while true; do
    printf "\n${_R}⚠️  Sẽ XÓA TOÀN BỘ /dev/%s (%s %s).${_0}\n" "$1" "$USB_DEV_SIZE" "$USB_DEV_MODEL"
    printf "${_Y}Tiếp tục? [y/N]: ${_0}"; local ans; read -r ans || ans="N"; ans="${ans:-N}"
    case "$ans" in
      [yY]) return 0 ;;
      [nN]) err "Đã hủy. Không có gì bị thay đổi."; return 1 ;;
      *)    warn "Vui lòng nhập y hoặc N." ;;
    esac
  done
}

write_iso_to_usb() {
  info "Đang ghi ISO vào /dev/$1 — KHÔNG rút USB trong lúc ghi..."
  if [[ "$OS_KIND" == "Linux" ]]; then
    sudo dd if="$ISO_PATH" of="/dev/$1" bs=4M status=progress conv=fsync
  else
    # macOS: raw device /dev/rdiskN is ~10x faster than /dev/diskN; no status=progress flag
    info "Đang ghi USB, vui lòng chờ (có thể mất vài phút)..."
    sudo dd if="$ISO_PATH" of="/dev/r${1}" bs=4m
  fi
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
      && sudo udisksctl power-off -b "/dev/$1" 2>/dev/null && ok "Đã eject." && return 0
    sync; command -v eject >/dev/null 2>&1 \
      && sudo eject "/dev/$1" 2>/dev/null && ok "Đã eject." && return 0
    warn "Không tự eject được. Vui lòng rút USB ra bằng tay."
  else
    sudo diskutil eject "/dev/$1" 2>/dev/null && ok "Đã eject." \
      || warn "Không tự eject được. Vui lòng rút USB ra bằng tay."
  fi
}

print_boot_guide() {
  printf "\n${_G}╔══════════════════════════════════════════════╗${_0}\n"
  printf   "${_G}║     HƯỚNG DẪN KHỞI ĐỘNG TỪ USB              ║${_0}\n"
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
  printf "${_Y}Xóa ISO %s để tiết kiệm dung lượng? [y/N]: ${_0}" "$ISO_NAME"
  local ans; read -r ans || ans="N"; ans="${ans:-N}"
  if [[ "$ans" =~ ^[yY]$ ]]; then rm "$ISO_PATH" && ok "Đã xóa $ISO_PATH"
  else info "Giữ lại ISO: $ISO_PATH"; fi
}

# --- main: full flow (Phase 1: download+verify; Phase 2: USB write) -----------
main() {
  info "=== CaramOS Installer ==="
  detect_os; check_deps; ensure_iso_dir
  fetch_release_meta; download_iso; verify_iso
  ok "✓ ISO sẵn sàng: $ISO_PATH"

  _get_system_disk
  while true; do
    info "Quét thiết bị USB đang kết nối..."
    list_usb_devices
    if [[ ${#USB_LIST[@]} -eq 0 ]]; then
      warn "Không tìm thấy USB nào. Cắm USB rồi nhấn Enter để quét lại..."
      read -r _ || true; continue
    fi
    prompt_device && break
  done

  unmount_device_parts "$USB_DEV"
  confirm_write "$USB_DEV"
  write_iso_to_usb "$USB_DEV"
  verify_usb_write "$USB_DEV"
  eject_device "$USB_DEV"
  print_boot_guide
  prompt_cleanup_iso
}

main "$@"
