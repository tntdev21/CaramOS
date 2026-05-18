#Requires -Version 5.1
# CaramOS Windows Installer — tải ISO, xác minh SHA256, ghi USB qua Rufus portable.
# PowerShell 5.1+, self-elevate UAC, tiếng Việt mọi message user-facing.
param(
    [string]$Local = ""
)

$ErrorActionPreference = 'Stop'

function Show-Help {
    Write-Host @"
Usage: .\install.ps1 [-Local <path>]

Options:
  -Local <path>    Dùng ISO local thay vì tải từ GitHub Releases (cho test/dev)
"@ -ForegroundColor Cyan
}

function Write-Info([string]$Msg)  { Write-Host $Msg -ForegroundColor Cyan }
function Write-Warn([string]$Msg)  { Write-Host $Msg -ForegroundColor Yellow }

function Set-Utf8Encoding {
    [Console]::OutputEncoding = [Text.UTF8Encoding]::new()
    $global:OutputEncoding   = [Text.UTF8Encoding]::new()
}

function Assert-Admin {
    $p = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host "Cần quyền Administrator. Đang yêu cầu nâng quyền..." -ForegroundColor Yellow
        Start-Process powershell -Verb RunAs `
            -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File",$PSCommandPath
        exit
    }
}

function Assert-SafeUrl([string]$Url) {
    $ok = $Url.StartsWith('https://github.com/') -or
          $Url.StartsWith('https://api.github.com/') -or
          $Url.StartsWith('https://objects.githubusercontent.com/')
    if (-not $ok) { throw "URL không được phép: $Url" }
}

function Get-ReleaseMeta {
    Write-Host "Đang lấy thông tin phiên bản mới nhất..." -ForegroundColor Cyan
    $r       = Invoke-RestMethod 'https://api.github.com/repos/VN-Linux-Family/CaramOS/releases/latest'
    $isoA    = $r.assets | Where-Object { $_.name -like '*.iso' } | Select-Object -First 1
    $shaA    = $r.assets | Where-Object { $_.name -eq 'SHA256SUMS' } | Select-Object -First 1
    if (-not $isoA) { throw "Không tìm thấy file ISO trong release $($r.tag_name)" }
    if (-not $shaA) { throw "Không tìm thấy SHA256SUMS trong release $($r.tag_name)" }
    Assert-SafeUrl $isoA.browser_download_url
    Assert-SafeUrl $shaA.browser_download_url
    return [PSCustomObject]@{
        IsoUrl  = $isoA.browser_download_url
        ShaUrl  = $shaA.browser_download_url
        Tag     = $r.tag_name
        IsoName = $isoA.name
    }
}

function New-IsoDir {
    $dir = Join-Path $env:USERPROFILE 'Downloads\caramos-iso'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Test-FreeSpace([string]$Dir) {
    $drive  = Split-Path -Qualifier $Dir
    $letter = $drive.TrimEnd(':')
    $psd    = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
    if ($psd) {
        # PSDrive.Free luôn trả bytes trên FileSystem provider — dùng thẳng, không nhân thêm
        $free = $psd.Free
    } else {
        $wmi  = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='$drive'" -ErrorAction SilentlyContinue
        if (-not $wmi) { Write-Host "Bỏ qua kiểm tra dung lượng." -ForegroundColor Yellow; return }
        $free = $wmi.FreeSpace
    }
    if ($free -lt 3.5GB) {
        $gb = [math]::Round($free/1GB,1)
        throw "Dung lượng trống không đủ: ${gb} GB. Cần ít nhất 3.5 GB."
    }
    Write-Host "Dung lượng trống: OK" -ForegroundColor Green
}

function Save-Iso([string]$Url, [string]$Destination) {
    if (Test-Path $Destination) {
        Write-Host "ISO đã tồn tại: $Destination — bỏ qua tải xuống." -ForegroundColor Yellow
        return
    }
    Write-Host "Đang tải ISO: $Url" -ForegroundColor Cyan
    try {
        Start-BitsTransfer -Source $Url -Destination $Destination -DisplayName "Tải CaramOS ISO"
        Write-Host "Tải xong (BITS)." -ForegroundColor Green
    } catch {
        Write-Host "BITS không khả dụng — chuyển sang Invoke-WebRequest..." -ForegroundColor Yellow
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
        Write-Host "Tải xong." -ForegroundColor Green
    }
}

function Test-IsoChecksum([string]$ShaUrl, [string]$IsoPath, [string]$IsoName, [string]$IsoDir) {
    $shaFile = Join-Path $IsoDir 'SHA256SUMS'
    Write-Host "Đang tải SHA256SUMS..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ShaUrl -OutFile $shaFile -UseBasicParsing
    $expected = $null
    foreach ($line in (Get-Content $shaFile)) {
        if ($line -match [regex]::Escape($IsoName)) {
            $expected = ($line -split '\s+')[0].ToUpper(); break
        }
    }
    if (-not $expected) { throw "Không tìm thấy checksum cho $IsoName trong SHA256SUMS" }
    Write-Host "Đang kiểm tra SHA256..." -ForegroundColor Cyan
    $actual = (Get-FileHash -Path $IsoPath -Algorithm SHA256).Hash.ToUpper()
    if ($actual -ne $expected) {
        Write-Host "CHECKSUM KHÔNG KHỚP!`n  Dự kiến : $expected`n  Thực tế : $actual" -ForegroundColor Red
        $ans = Read-Host "File có thể bị hỏng. Xóa và tải lại? [y/N]"
        if ($ans -match '^[Yy]$') { Remove-Item $IsoPath -Force; throw "Đã xóa ISO hỏng. Vui lòng chạy lại." }
        throw "Checksum không khớp. Hủy cài đặt."
    }
    Write-Host "Checksum OK." -ForegroundColor Green
}

function Save-Rufus([string]$IsoDir) {
    $url  = 'https://github.com/pbatard/rufus/releases/download/v4.5/rufus-4.5p.exe'
    $path = Join-Path $IsoDir 'rufus-4.5p.exe'
    if (Test-Path $path) { Write-Host "Rufus đã có trong cache." -ForegroundColor Yellow; return $path }
    Assert-SafeUrl $url
    Write-Host "Đang tải Rufus 4.5 portable..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $url -OutFile $path -UseBasicParsing
    Write-Host "Rufus đã tải xong." -ForegroundColor Green
    return $path
}

function Get-UsbDisks {
    return @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -ge 4GB })
}

function Show-UsbTable($Disks) {
    Write-Host "`nDanh sách USB khả dụng:" -ForegroundColor Cyan
    Write-Host ("{0,-4} {1,-8} {2,-10} {3}" -f "#","Disk #","Dung lượng","Tên thiết bị")
    Write-Host ("-" * 55)
    $i = 1
    foreach ($d in $Disks) {
        $gb = [math]::Round($d.Size/1GB,1)
        Write-Host ("{0,-4} {1,-8} {2,-10} {3}" -f $i,$d.Number,"${gb} GB",$d.FriendlyName)
        $i++
    }
    Write-Host ""
}

function Read-DiskChoice($Disks) {
    $list  = @($Disks)
    $count = $list.Count
    while ($true) {
        $in = Read-Host "Nhập số thứ tự USB muốn ghi (1-$count)"
        $n  = 0
        if ([int]::TryParse($in,[ref]$n) -and $n -ge 1 -and $n -le $count) { return $list[$n-1] }
        Write-Host "Lựa chọn không hợp lệ. Vui lòng nhập số từ 1 đến $count." -ForegroundColor Red
    }
}

function Confirm-Write($Disk) {
    $gb  = [math]::Round($Disk.Size/1GB,1)
    $msg = "CẢNH BÁO: Toàn bộ dữ liệu trên USB '$($Disk.FriendlyName)' (${gb} GB, Disk $($Disk.Number)) sẽ bị XÓA VĨNH VIỄN!`n`nBạn có chắc muốn tiếp tục không?"
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $r = [System.Windows.Forms.MessageBox]::Show($msg,"Cảnh báo — CaramOS Installer",
             [System.Windows.Forms.MessageBoxButtons]::YesNo,
             [System.Windows.Forms.MessageBoxIcon]::Warning)
        return ($r -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        Write-Host "`n$msg" -ForegroundColor Yellow
        return ((Read-Host "Tiếp tục? [y/N]") -match '^[Yy]$')
    }
}

function Invoke-RufusWrite([string]$RufusExe, [string]$IsoPath) {
    Write-Host "`nĐang mở Rufus..." -ForegroundColor Cyan
    & $RufusExe -i $IsoPath
    Write-Host "Rufus đã mở. Chọn USB rồi nhấn START. Đóng Rufus khi xong." -ForegroundColor Yellow
    Wait-Process -Name "rufus*" -ErrorAction SilentlyContinue
    Write-Host "Rufus đã đóng." -ForegroundColor Green
}

function Show-BootGuide {
    Write-Host "`n=== HƯỚNG DẪN KHỞI ĐỘNG TỪ USB ===" -ForegroundColor Cyan
    Write-Host "Khởi động lại và nhấn phím tương ứng khi logo hãng xuất hiện:`n"
    Write-Host "  Dell     : F12 (Boot Menu) / F2 (BIOS)"
    Write-Host "  HP       : F9 (Boot Menu) / F10 / Esc"
    Write-Host "  Lenovo   : F12 (Boot Menu) / F1/F2 (BIOS)"
    Write-Host "  Asus     : F8 (Boot Menu) / Del/F2 (BIOS)"
    Write-Host "  Acer     : F12 (Boot Menu) / Del/F2 (BIOS)"
    Write-Host "  MSI      : F11 (Boot Menu) / Del (BIOS)"
    Write-Host "  Gigabyte : F12 (Boot Menu) / Del (BIOS)"
    Write-Host "  Surface  : Giữ nút Giảm âm khi bật nguồn"
    Write-Host ""
}

function Remove-IsoPrompt([string]$IsoPath) {
    if ($Local) {
        Write-Host "Bỏ qua cleanup ISO local" -ForegroundColor Gray
        return
    }
    if ((Read-Host "Xóa ISO để tiết kiệm dung lượng? [y/N]") -match '^[Yy]$') {
        Remove-Item $IsoPath -Force
        Write-Host "Đã xóa: $IsoPath" -ForegroundColor Green
    } else {
        Write-Host "Giữ lại ISO tại: $IsoPath" -ForegroundColor Gray
    }
}

# ── MAIN ────────────────────────────────────────────────────────────────────
Assert-Admin
Set-Utf8Encoding

Write-Host "`n╔══════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host  "║        CaramOS — Trình cài đặt USB        ║" -ForegroundColor Cyan
Write-Host  "╚══════════════════════════════════════════╝`n" -ForegroundColor Cyan

try {
    if ($Local) {
        if (-not (Test-Path $Local)) { throw "ISO không tồn tại: $Local" }
        $isoPath = (Resolve-Path $Local).Path
        $isoName = Split-Path $Local -Leaf
        Write-Info "Sử dụng ISO local: $isoPath (bỏ qua download + SHA256)"
        Write-Warn "Đang ở chế độ DEV — chỉ dùng ISO bạn tự build/tin tưởng"
    } else {
        $meta = Get-ReleaseMeta
        Write-Host "Phiên bản: $($meta.Tag)  |  ISO: $($meta.IsoName)" -ForegroundColor Green
        $isoDir  = New-IsoDir
        Write-Host "Thư mục lưu: $isoDir"
        Test-FreeSpace -Dir $isoDir
        $isoPath = Join-Path $isoDir $meta.IsoName
        Save-Iso         -Url $meta.IsoUrl -Destination $isoPath
        Test-IsoChecksum -ShaUrl $meta.ShaUrl -IsoPath $isoPath -IsoName $meta.IsoName -IsoDir $isoDir
        $isoName = $meta.IsoName
    }
    $rufusExe = Save-Rufus -IsoDir (Split-Path $isoPath -Parent)

    # Vòng lặp chọn USB
    $chosen = $null
    while ($true) {
        $usbs = Get-UsbDisks
        if ($usbs.Count -eq 0) {
            Write-Host "Không tìm thấy USB nào >= 4GB. Cắm USB rồi nhấn Enter để thử lại." -ForegroundColor Yellow
            Read-Host | Out-Null; continue
        }
        Show-UsbTable -Disks $usbs
        $chosen = Read-DiskChoice -Disks $usbs
        break
    }
    $gb = [math]::Round($chosen.Size/1GB,1)
    Write-Host "Đã chọn: Disk $($chosen.Number) — $($chosen.FriendlyName) (${gb} GB)" -ForegroundColor Green

    if (-not (Confirm-Write -Disk $chosen)) {
        Write-Host "Đã hủy. Không có thay đổi nào." -ForegroundColor Yellow; exit 0
    }

    Invoke-RufusWrite -RufusExe $rufusExe -IsoPath $isoPath
    Show-BootGuide
    Remove-IsoPrompt -IsoPath $isoPath

    Write-Host "Hoàn tất! Chúc bạn cài đặt CaramOS thành công.`n" -ForegroundColor Green

} catch {
    Write-Host "`nLỗi: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Quá trình cài đặt bị gián đoạn." -ForegroundColor Red
    exit 1
}
