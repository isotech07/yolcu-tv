# YolcuTV - Android kurulumu (Windows PowerShell)
# Kullanım (proje klasöründe):
#   powershell -ExecutionPolicy Bypass -File tool\android_kurulum.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
$utf8 = New-Object System.Text.UTF8Encoding $false   # BOM'suz UTF-8

# 1) Android klasörü yoksa oluştur
if (-not (Test-Path "android\app\src\main\AndroidManifest.xml")) {
    Write-Host "Android projesi oluşturuluyor..." -ForegroundColor Yellow
    flutter create --org com.yolcutv --project-name yolcu_tv --platforms android .
}

# 2) MainActivity'nin yerini ve paket adını bul
$main = Get-ChildItem -Recurse -Path "android\app\src\main" -Include "MainActivity.kt", "MainActivity.java" | Select-Object -First 1
if (-not $main) { throw "MainActivity bulunamadı. 'flutter create' çıktısını kontrol edin." }
$pkg = (Select-String -Path $main.FullName -Pattern '^\s*package\s+([\w\.]+)').Matches[0].Groups[1].Value
$dir = $main.DirectoryName
if ($main.Extension -eq ".java") {
    # Eski Java şablonu: Kotlin dosyamızı aynı pakete koyup Java olanı kaldır.
    Remove-Item $main.FullName
}
Write-Host "Paket: $pkg" -ForegroundColor Cyan

# 3) Kotlin dosyalarını kopyala (paket adını projeye uyarla)
foreach ($f in @("MainActivity.kt", "ScreenCaptureService.kt")) {
    $src = [IO.File]::ReadAllText((Join-Path $root "tool\android\$f"), $utf8)
    $src = [regex]::Replace($src, '^package\s+[\w\.]+', "package $pkg", 'Multiline')
    [IO.File]::WriteAllText((Join-Path $dir $f), $src, $utf8)
    Write-Host "  $f kopyalandı"
}

# 4) AndroidManifest.xml: izinler, düz HTTP, ekran yakalama servisi
$mf = Join-Path $root "android\app\src\main\AndroidManifest.xml"
$x = [IO.File]::ReadAllText($mf, $utf8)
$perms = @(
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.WAKE_LOCK",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
    "android.permission.POST_NOTIFICATIONS"
)
foreach ($p in $perms) {
    if ($x -notmatch [regex]::Escape($p)) {
        $x = $x.Replace("<application", "<uses-permission android:name=`"$p`"/>`n    <application")
    }
}
if ($x -notmatch "usesCleartextTraffic") {
    $x = $x.Replace("<application", "<application`n        android:usesCleartextTraffic=`"true`"")
}
if ($x -notmatch "ScreenCaptureService") {
    $service = "    <service`n            android:name=`".ScreenCaptureService`"`n            android:exported=`"false`"`n            android:foregroundServiceType=`"mediaProjection`"/>`n    </application>"
    $x = $x.Replace("</application>", $service)
}
$labelRe = [regex]'android:label="[^"]*"'
$x = $labelRe.Replace($x, 'android:label="YolcuTV"', 1)
[IO.File]::WriteAllText($mf, $x, $utf8)
Write-Host "AndroidManifest.xml güncellendi" -ForegroundColor Green

Write-Host ""
Write-Host "Hazır. Telefonu USB ile bağlayıp şunu çalıştırın:" -ForegroundColor Green
Write-Host "  flutter run"
