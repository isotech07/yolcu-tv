#!/usr/bin/env bash
# `flutter create` sonrası iOS ve Android ayarlarını ekler.
# Kullanım: proje klasöründe  ->  bash tool/setup_platforms.sh
set -euo pipefail

PLIST="ios/Runner/Info.plist"
MANIFEST="android/app/src/main/AndroidManifest.xml"

# ---------------- iOS ----------------
if [[ -f "$PLIST" ]]; then
  if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    PB=/usr/libexec/PlistBuddy
    $PB -c "Delete :NSAppTransportSecurity" "$PLIST" 2>/dev/null || true
    # IPTV yayınlarının çoğu düz HTTP; oynatıcı ve liste indirme için gerekli.
    $PB -c "Add :NSAppTransportSecurity dict" "$PLIST"
    $PB -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$PLIST"

    $PB -c "Delete :NSLocalNetworkUsageDescription" "$PLIST" 2>/dev/null || true
    $PB -c "Add :NSLocalNetworkUsageDescription string Araç ekranının telefonunuza bağlanabilmesi için yerel ağ erişimi gerekir." "$PLIST"

    $PB -c "Delete :UIBackgroundModes" "$PLIST" 2>/dev/null || true
    $PB -c "Add :UIBackgroundModes array" "$PLIST"
    $PB -c "Add :UIBackgroundModes:0 string audio" "$PLIST"

    $PB -c "Set :CFBundleDisplayName YolcuTV" "$PLIST" 2>/dev/null || \
      $PB -c "Add :CFBundleDisplayName string YolcuTV" "$PLIST"

    # Standart HTTPS dışında şifreleme yok: TestFlight her derlemede sormasın.
    $PB -c "Delete :ITSAppUsesNonExemptEncryption" "$PLIST" 2>/dev/null || true
    $PB -c "Add :ITSAppUsesNonExemptEncryption bool false" "$PLIST"
    echo "iOS Info.plist güncellendi."
  else
    echo "UYARI: PlistBuddy yok (macOS değil). iOS ayarlarını README'deki gibi elle ekleyin."
  fi
fi

# ---------------- Android ----------------
if [[ -f "$MANIFEST" ]]; then
  python3 - "$MANIFEST" <<'PY'
import sys, re, glob, os
path = sys.argv[1]
s = open(path, encoding="utf-8").read()
perms = [
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.ACCESS_WIFI_STATE",
    "android.permission.WAKE_LOCK",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_MEDIA_PROJECTION",
    "android.permission.POST_NOTIFICATIONS",
]
for p in perms:
    if p not in s:
        s = s.replace("<application", f'<uses-permission android:name="{p}"/>\n    <application', 1)
if "usesCleartextTraffic" not in s:
    s = s.replace("<application", '<application\n        android:usesCleartextTraffic="true"', 1)
if "ScreenCaptureService" not in s:
    s = s.replace("</application>", '    <service\n            android:name=".ScreenCaptureService"\n            android:exported="false"\n            android:foregroundServiceType="mediaProjection"/>\n    </application>', 1)
s = re.sub(r'android:label="[^"]*"', 'android:label="YolcuTV"', s, count=1)
open(path, "w", encoding="utf-8").write(s)

# Kotlin dosyaları
main = (glob.glob("android/app/src/main/**/MainActivity.kt", recursive=True) +
        glob.glob("android/app/src/main/**/MainActivity.java", recursive=True))[0]
pkg = re.search(r"^\s*package\s+([\w.]+)", open(main, encoding="utf-8").read(), re.M).group(1)
d = os.path.dirname(main)
if main.endswith(".java"):
    os.remove(main)
for f in ("MainActivity.kt", "ScreenCaptureService.kt"):
    src = open(os.path.join("tool", "android", f), encoding="utf-8").read()
    src = re.sub(r"^package\s+[\w.]+", "package " + pkg, src, count=1, flags=re.M)
    open(os.path.join(d, f), "w", encoding="utf-8").write(src)
print("Android ayarları ve ekran yansıtma dosyaları eklendi.")
PY
fi

# ---------------- macOS (bilgisayarda deneme) ----------------
# Sandbox içinde sunucu açabilmek, internete çıkabilmek ve dosya seçebilmek için.
for ENT in macos/Runner/DebugProfile.entitlements macos/Runner/Release.entitlements; do
  if [[ -f "$ENT" ]] && command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
    for KEY in com.apple.security.network.server com.apple.security.network.client com.apple.security.files.user-selected.read-only; do
      /usr/libexec/PlistBuddy -c "Delete :$KEY" "$ENT" 2>/dev/null || true
      /usr/libexec/PlistBuddy -c "Add :$KEY bool true" "$ENT"
    done
    echo "$ENT güncellendi."
  fi
done

echo "Bitti. Şimdi: flutter pub get && flutter run"
