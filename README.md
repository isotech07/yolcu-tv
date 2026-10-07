# YolcuTV

**Ana özellik: telefon ekranını araç ekranına (Tesla / tarayıcılı araçlar) yansıtma.**
Ek olarak M3U / Xtream oynatıcı ve kanal yayını. Tek Flutter kod tabanı; iOS ve Android.

## Ekran yansıtma — Android'de deneme (Windows)

Yansıtma telefonda çalışır; Windows masaüstü sürümünde bu özellik yoktur.

1. **Android Studio**'yu kurun, bir kez açıp kurulum sihirbazını bitirin (Android SDK iner).
   Sonra PowerShell'de: `flutter doctor --android-licenses` (hepsine `y`).
2. Telefonda: Ayarlar → Telefon hakkında → **Yapım numarası**'na 7 kez dokunun →
   Geliştirici seçenekleri → **USB hata ayıklama**'yı açın. Telefonu USB ile bağlayın, izni onaylayın.
3. Proje klasöründe:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tool\android_kurulum.ps1
   flutter run
   ```
4. Uygulamada **Araç ekranı → Yansıtmayı başlat**. Android'in "ekranınız kaydedilecek" iznini onaylayın.
5. **Tesla olmadan test:** Bilgisayar ve telefon aynı Wi-Fi'deyken bilgisayarın Chrome'unda
   uygulamanın gösterdiği adresi açın (`http://192.168.x.x:8080`). Telefon ekranı orada görünür.

### Nasıl çalışıyor

```
Telefon ekranı → MediaProjection → donanım H.264 kodlayıcı (Kotlin)
   → Flutter EventChannel → yerel sunucu /ws-ekran (WebSocket)
   → araç tarayıcısı: jmuxer → Media Source Extensions → <video>
```

- Kodlama telefonun donanım kodlayıcısında yapılır; işlemci yükü ve ısınma düşüktür.
- Kalite: Tasarruf (960p, 2 Mbps), Dengeli (1280p, 4 Mbps), Yüksek (1920p, 8 Mbps).
- Yeni bağlanan ekran ilk anahtar kareyi bekler (en fazla ~1 sn); telefon döndürülünce çözücü otomatik yeniden kurulur.
- Ses telefondan / aracın Bluetooth'undan gelir. DRM'li uygulamalar (Netflix vb.) siyah görünür.
- Dosyalar: `tool/android/ScreenCaptureService.kt`, `tool/android/MainActivity.kt`,
  `lib/services/screen_mirror.dart`, `assets/web/ekran.html`.

## iPhone sürümü – Codemagic ile (Mac gerekmez)

### Nasıl çalışıyor

```
iPhone ekranı → ReplayKit yayın uzantısı (ayrı süreç)
   → VideoToolbox donanım H.264 → uzantı içindeki sunucu :8090
   → araç tarayıcısı: aynı ekran.html + jmuxer
```

- iOS başka uygulamaya geçildiğinde ana uygulamayı askıya alır; bu yüzden görüntüyü uzantı kendisi sunar.
  Araçta açılacak adres: **http://172.20.10.1:8090** (iPhone erişim noktası adresi).
- Uzantı sabit "Dengeli" kalitede çalışır (1280p, 4 Mbps).
- Yön: iPhone görüntüyü hep dikey verir; yan çevrilince tarayıcı döndürür.
  Görüntü ters çıkarsa `tool/ios/Broadcast/SampleHandler.swift` içinde 90 ile -90'ı yer değiştirin.
- Dosyalar: `tool/ios/Broadcast/*` (uzantı), `tool/ios/Runner/YolcuMirrorBridge.swift` (Flutter köprüsü),
  `tool/ios/add_broadcast_extension.rb` (Xcode projesine uzantıyı Mac'siz ekleyen betik),
  `codemagic.yaml` (derleme).

### Ücretsiz deneme: Sideloadly ile (Apple Developer hesabı gerekmez)

1. Codemagic'te **iOS → İmzasız IPA** iş akışını başlatın; bitince **Artifacts**'tan `YolcuTV-imzasiz.ipa` dosyasını indirin.
2. Windows'ta Apple'ın sitesinden indirilen (Microsoft Store sürümü **olmayan**) **iTunes** ve **iCloud**'u kurun.
   Store sürümleri yüklüyse önce kaldırın.
3. **Sideloadly**'yi resmi sitesinden (sideloadly.io) indirip kurun.
4. iPhone'u USB ile bağlayın, telefonda "Bu bilgisayara güvenilsin mi?" → **Güven**.
5. IPA dosyasını Sideloadly'ye sürükleyin, Apple ID'nizi girin → **Start**. (Sideloadly Apple yapımı değildir;
   bu yüzden yedek bir Apple ID kullanmak daha güvenlidir.)
6. iPhone'da: Ayarlar → Genel → **VPN ve Aygıt Yönetimi** → Apple ID'niz → **Güven**.
7. iPhone'da: Ayarlar → Gizlilik ve Güvenlik → **Geliştirici Modu** → aç → telefon yeniden başlar → **Aç**.

Ücretsiz Apple ID ile kurulan uygulama **7 gün** çalışır; sonra aynı adımlarla yeniden kurulur
(Sideloadly'nin otomatik yenileme özelliği de var). Uygulama 2 uygulama kimliği kullanır (uygulama + uzantı);
ücretsiz hesapta 7 günde en fazla 10 kimlik oluşturulabilir.

### Kalıcı test ve App Store: TestFlight (ücretli hesap) — bir kerelik kurulum

**1. Apple Developer Program** – developer.apple.com/programs/enroll (yıllık 99 USD, onay 1–2 gün).

**2. İki paket kimliği (Bundle ID)** – developer.apple.com/account → Certificates, Identifiers & Profiles →
Identifiers → **+** → App IDs → App → Description: `YolcuTV`, Bundle ID: Explicit `com.yolcutv.yolcuTv` →
Continue → Register. Aynısını uzantı için tekrarlayın: Description `YolcuTV Broadcast`,
Bundle ID `com.yolcutv.yolcuTv.Broadcast`. Ek yetenek (capability) işaretlemeyin.

**3. App Store Connect'te uygulama kaydı** – appstoreconnect.apple.com → Uygulamalar → **+** → Yeni Uygulama →
iOS, ad (App Store'da benzersiz olmalı), dil Türkçe, Bundle ID: yukarıdaki, SKU: yolcutv.

**4. API anahtarı** – App Store Connect → Kullanıcılar ve Erişim → Entegrasyonlar → App Store Connect API.
İlk seferde **Erişim İste**'ye (Request Access) tıklayıp onaylayın. Ekip Anahtarları → **+** → ad: `Codemagic`,
erişim: **App Manager** → oluştur. `.p8` dosyasını indirin (yalnızca bir kez indirilebilir).
**Issuer ID** ve **Key ID** değerlerini not edin.

**5. Sertifika anahtarı** – Git Bash'te (PowerShell değil):
```bash
ssh-keygen -t rsa -b 2048 -m PEM -f ~/yolcutv_sertifika -q -N ""
cat ~/yolcutv_sertifika | clip
```
İkinci komut anahtarın tamamını (BEGIN/END satırları dahil) panoya kopyalar. Dosyayı güvenli bir yerde
saklayın ve **asla depoya yüklemeyin**.

**6. Kod GitHub'da** – github.com/isotech07/yolcu-tv (`main` dalı). Codemagic kodu doğrudan buradan çeker.

**7. Codemagic** – codemagic.io'ya GitHub hesabıyla girin → **Add application** → `yolcu-tv` → Flutter App.
- Hesap (veya ekip) ayarlarındaki **Integrations** bölümü → **Developer Portal** → **Connect**
  (daha önce anahtar eklediyseniz **Manage keys → Add key**): **App Store Connect API key name** alanına
  tam olarak `YolcuTV` yazın (codemagic.yaml ile aynı), Issuer ID, Key ID ve `.p8` dosyasını girin → Save.
- Uygulamanın **Environment variables** sekmesi: ad `CERTIFICATE_PRIVATE_KEY`, değer 5. adımda panoya
  kopyalanan metin (Ctrl+V), grup `ios_imza`, **Secret** işaretli → Add.

**8. Derleme** – Codemagic'te **Start new build** → dal `main` → iş akışı **iOS → TestFlight**.
İlk derleme 15–25 dakika sürer. Derleme yalnızca App Store Connect'e yükler; Apple beta incelemesi gerekmez.

**9. iPhone'a kurulum** – App Store Connect → YolcuTV → **TestFlight** → **İç Test** (Internal Testing) yanındaki
**+** → grup adı `Ekip`, **otomatik dağıtım** işaretli → Oluştur → **Test kullanıcıları** → **+** → kendinizi seçin.
Yüklenen derleme Apple tarafından işlendikten sonra (genelde 10–30 dk) gruba kendiliğinden gelir.
iPhone'a App Store'dan **TestFlight** uygulamasını indirip aynı Apple ID ile girin → YolcuTV → **Yükle**.
TestFlight kurulumu için Geliştirici Modu gerekmez.

**10. Deneme** – iPhone'da Kişisel Erişim Noktası'nı açın, Tesla'yı bu ağa bağlayın → YolcuTV →
**Yansıtmayı başlat** → açılan pencerede **YolcuTV Yansıtma** → **Yayını Başlat** →
Tesla tarayıcısında `http://172.20.10.1:8090`.

### Android APK'yı da Codemagic'te alabilirsiniz

Aynı depoda **Android → APK** iş akışını başlatın; bittiğinde **Artifacts** bölümünden `app-release.apk`
dosyasını indirip telefona kurun. Android Studio kurmanız gerekmez.

### Derleme hata verirse

Codemagic'teki kırmızı adımın günlüğünü (log) ve **Artifacts** altındaki `xcodebuild` günlüklerini paylaşın.

## Bu sürümde neler var

| Özellik | Durum |
|---|---|
| M3U/M3U8 bağlantısı, cihazdan dosya | ✅ |
| Toleranslı ayrıştırıcı (başlıksız liste, EXTVLCOPT, `url\|User-Agent=`, göreli adres, HTML/JSON uyarısı) | ✅ |
| `get.php?username=…` linkini otomatik Xtream'e çevirme | ✅ |
| Xtream Codes girişi, kategoriler, abonelik bitiş tarihi | ✅ |
| EPG (XMLTV, .gz dahil) — "şimdi oynayan" | ✅ |
| Gruplar, arama, favoriler, son izlenenler | ✅ |
| Telefonda oynatıcı (MKV, HEVC, DTS, altyazı — libmpv) | ✅ |
| **Tesla / tarayıcılı araç ekranına aktarım** (yansıtma değil) | ✅ |
| Araç ekranından ve telefondan kanal seçimi, duraklat, kanal geç | ✅ |
| Yolcu güvenlik uyarısı | ✅ |
| Xtream VOD / dizi, QR ile ekleme, abonelik (RevenueCat), CarPlay | Faz 2 (aşağıda) |

## Klasör yapısı

```
lib/
  main.dart                  Giriş, tema
  models/                    Channel, Playlist
  services/
    net.dart                 İndirme, gzip, Türkçe hata mesajları
    m3u_parser.dart          M3U ayrıştırıcı
    xtream_client.dart       Xtream Codes API
    epg_service.dart         XMLTV yayın akışı
    car_server.dart          Araç ekranı sunucusu (web + proxy + WebSocket)
  state/app_state.dart       Listeler, kanallar, favoriler, kayıt
  screens/                   Listeler, Kanallar, Oynatıcı, Araç ekranı
  widgets/channel_logo.dart
assets/web/
  index.html                 Tesla ekranındaki oynatıcı
  hls.min.js, mpegts.js      Pakete gömülü (internetsiz de çalışır)
test/m3u_parser_test.dart
tool/setup_platforms.sh      iOS/Android izinlerini ekler
```

## Kurulum

Gerekenler: Flutter 3.27+ (stable), Xcode 16+ (iOS için, macOS'ta), Android Studio.

```bash
cd yolcu_tv
flutter create --org com.yolcutv --project-name yolcu_tv --platforms ios,android .
bash tool/setup_platforms.sh
flutter pub get
flutter test               # ayrıştırıcı testleri
flutter run                # bağlı cihazda çalıştır
```

`flutter create` mevcut `lib/`, `pubspec.yaml` dosyalarına dokunmaz; sadece `ios/` ve `android/` klasörlerini oluşturur.

### Betik çalışmazsa elle eklenecek ayarlar

**iOS — `ios/Runner/Info.plist`**
```xml
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
<key>NSLocalNetworkUsageDescription</key>
<string>Araç ekranının telefonunuza bağlanabilmesi için yerel ağ erişimi gerekir.</string>
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
```

**Android — `android/app/src/main/AndroidManifest.xml`**
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<application android:usesCleartextTraffic="true" ...>
```

## Bilgisayarda deneme (telefon ve Tesla olmadan)

Uygulama Windows ve macOS'ta masaüstü programı olarak da çalışır. Araç sunucusu
bilgisayarda açılır; Chrome'da `http://localhost:8080` adresi "sahte Tesla ekranı" olur.

```bash
# Windows
flutter create --org com.yolcutv --project-name yolcu_tv --platforms windows .
# macOS
flutter create --org com.yolcutv --project-name yolcu_tv --platforms macos . && bash tool/setup_platforms.sh

flutter pub get
flutter run -d windows     # veya: -d macos
```

Deneme listesi: `tool/test.m3u` → Listeler → Liste ekle → Cihazdan dosya seç.

## Araç ekranı nasıl çalışıyor

```
Tesla tarayıcısı ──Wi-Fi──▶ Telefon (hotspot) :8080 ──4G/5G──▶ IPTV sunucusu
      │                           │
      │  /            web oynatıcı │
      │  /api/channels kanal listesi
      │  /proxy       yayın aktarımı (başlıklar, CORS, HLS adres yeniden yazımı)
      │  /ws          anlık kumanda (telefon ⇄ araç)
```

Telefon videoyu çözmez, sadece baytları aktarır. Rakibin ekran yansıtma yönteminden
çok daha az ısınır ve pil harcar; görüntü kalitesi kaynağın kalitesindedir.

Tarayıcıda oynatma sırası: kanal türüne göre hls.js → mpegts.js → yerel `<video>`;
biri başarısız olursa sıradakine geçer. Tarayıcı sesli otomatik oynatmayı engellerse
video sessiz başlar ve "Sesi aç" düğmesi çıkar.

## İlk gerçek araç testi (en önemli adım)

1. Uygulamayı telefona kurun, bir liste ekleyin, telefonda bir kanalın oynadığını doğrulayın.
2. Telefonda hotspot'u açın. Tesla'yı bu Wi-Fi'ye bağlayın.
3. Uygulamada **Araç ekranı** sekmesinde anahtarı açın. iPhone'da adres genelde `http://172.20.10.1:8080` olur.
4. Tesla tarayıcısında adresi açın, kanal seçin.

Kontrol listesi:
- [ ] Sayfa açılıyor mu? (Açılmıyorsa Tesla yerel IP'lere erişimi kısıtlıyor olabilir → aşağıdaki "B planı")
- [ ] HLS (.m3u8) kanal oynuyor mu?
- [ ] TS (.ts) kanal oynuyor mu?
- [ ] Ses açılıyor mu?
- [ ] 30 dakika kesintisiz oynuyor mu? Telefon sıcaklığı ve pil tüketimi nasıl?
- [ ] Telefon ekranı kilitlenirse / uygulama arka plana alınırsa ne oluyor?

**B planı (Tesla yerel IP'yi engellerse):** Kendi alan adınızda bir alt alan
(ör. `arac.markaniz.com`) DNS kaydını `172.20.10.1`'e yönlendirip bu alan için
alınmış TLS sertifikasını uygulamaya gömerek HTTPS sunmak. Bu, Faz 1.5 işidir;
önce yukarıdaki testin sonucunu görmek gerekiyor.

## Bilinen sınırlar

- **iOS arka plan:** Uygulama arka plana alınırsa iOS sunucuyu birkaç saniye içinde askıya alır. Yayın sırasında uygulama açık kalmalı (ekran kilidi otomatik kapatılıyor).
- **Android arka plan:** Uzun süreli arka plan için ön plan servisi (foreground service) eklenecek — Faz 2.
- **HEVC/H.265 kanallar** Tesla tarayıcısında büyük ihtimalle oynamaz (tarayıcı kısıtı); telefonda oynar. Sayfa bu durumda açık bir mesaj gösterir.
- **Tesla sürüş sırasında** tarayıcıda videoyu kısıtlar; ürün park/şarj/yolcu senaryosu için tasarlandı.
- Bu kod bu ortamda derlenmedi (Flutter SDK yoktu). İlk `flutter run`'da çıkabilecek küçük API sürümü uyumsuzlukları beklenmelidir.

## Faz 2 yol haritası

1. **Abonelik:** RevenueCat (`purchases_flutter`) + açık "Ücretsiz / Pro" ekranı. Öneri: ücretsizde 1 liste ve telefonda izleme; Pro'da araç ekranı, sınırsız liste, EPG.
2. **Xtream VOD ve diziler**, kaldığın yerden devam.
3. **QR ile liste ekleme** (`mobile_scanner`).
4. **CarPlay ses modu** (iOS): radyo ve kanal sesi için `CPListTemplate`. Apple'dan CarPlay audio yetkisi (entitlement) başvurusu gerekir — hemen başvurun, onay haftalar sürebilir.
5. **AirPlay video** (iOS): libmpv AirPlay desteklemez. iOS'ta AVPlayer tabanlı ikinci bir oynatma yolu eklenecek; böylece destekleyen araçlarda park halinde CarPlay ekranında ve Apple TV'de video açılır.
6. **Ekran yansıtma (Pro):** iOS ReplayKit Broadcast Extension, Android MediaProjection → WebRTC. Kalite/FPS ayarlı.
7. **Android ön plan servisi**, ebeveyn kilidi, kanal gizleme/sıralama, iPad düzeni.

## Mağaza notları (tekrar)

- Ekran görüntülerinde gerçek kanal logosu, maç veya film görüntüsü kullanmayın.
- Uygulamaya hazır liste veya örnek bağlantı koymayın.
- Apple inceleme notuna kendi sunucunuzdaki telifsiz bir test listesi ve Tesla demo videosu ekleyin.
- Uygulama adında "Tesla", "CarPlay" veya "IPTV" marka gibi kullanılmasın.
