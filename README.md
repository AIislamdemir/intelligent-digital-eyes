# AccessAI — Faz 1 İskelet

Bu, teknoloji karar raporunda belirlenen Faz 1'in ilk parçası: **Flutter proje iskeleti + kamera entegrasyonu**. Henüz AI (YOLO26-N, derinlik, OCR) yok — sadece kamera açılıp canlı görüntü gösteriyor ve TTS ile "hazır" diyor. Bir sonraki adımda bu iskelete gerçek algı katmanı eklenecek.

## Neden burada `flutter run` çalıştıramadım

Bu ortamın ağ erişimi Flutter SDK / pub.dev indirmeye kapalı, mobil emülatör de yok. Bu yüzden kodu senin için yazdım; aşağıdaki adımlarla **kendi bilgisayarında** çalıştırman gerekiyor.

## Kurulum Adımları

### 1. Flutter SDK kurulu değilse
https://docs.flutter.dev/get-started/install adresinden işletim sistemine uygun sürümü kur, sonra terminalde doğrula:
```bash
flutter doctor
```
Android Studio veya bir gerçek Android telefon (USB hata ayıklama açık) gerekecek.

### 2. Bu klasörü kendi bilgisayarına kopyala
Bu proje `accessai/` klasörü altında hazır. Klasörü indirip kendi makinene taşı, içine gir:
```bash
cd accessai
```

### 3. Flutter projesini bu iskelete göre tamamla
Bu klasörde sadece `pubspec.yaml` ve `lib/` var — Android/iOS native proje dosyaları eksik (onları `flutter create` otomatik üretir, biz onları elle yazmadık çünkü platforma özgü binary/config dosyaları içeriyor). Şunu çalıştır:
```bash
flutter create --project-name accessai --org com.accessai .
```
Bu komut mevcut `lib/` ve `pubspec.yaml` dosyalarına DOKUNMAZ, sadece eksik `android/`, `ios/` gibi platform klasörlerini tamamlar.

### 4. Kamera iznini Android manifestine ekle
`android/AndroidManifest_permissions_EKLE.xml` dosyasındaki izin satırlarını,
`android/app/src/main/AndroidManifest.xml` içine `<application>` etiketinden ÖNCE yapıştır.

### 5. Bağımlılıkları indir ve çalıştır
```bash
flutter pub get
flutter run
```
Telefonunu USB ile bağlı tut (veya emülatör aç). Uygulama açılınca kamera izni isteyecek, izin verince canlı önizleme gelecek ve "AccessAI hazır" diyecek.

## Proje Yapısı
```
accessai/
├── lib/
│   ├── main.dart                 # Giriş noktası, tema, kamera listesi başlatma
│   ├── screens/
│   │   └── camera_screen.dart    # Ana ekran: izin, önizleme, "Çevreyi Tarif Et" butonu
│   └── services/
│       └── tts_service.dart      # Türkçe sesli geri bildirim sarmalayıcısı
├── pubspec.yaml
└── android/
    └── AndroidManifest_permissions_EKLE.xml   # kopyalanacak izin satırları
```

## Bir Sonraki Adım (Faz 1 - Görev 2)
`camera_screen.dart` içindeki `_onDescribeTapped()` fonksiyonu şu an yer tutucu.
Sıradaki görev: YOLO26-N modelini TFLite'a çevirip bu fonksiyonun native tarafta
tek bir kareyi işleyip sonuç döndürmesini sağlamak (platform channel üzerinden).

## Sorun Yaşarsan
- `flutter doctor` çıktısını paylaş, birlikte çözelim.
- Kamera izni reddedilirse: telefon Ayarlar → Uygulamalar → AccessAI → İzinler'den elle açılabilir.