import 'dart:typed_data';
import 'dart:ui' show Size;
import 'package:camera/camera.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// "Oku" komutuyla tetiklenen OCR servisi.
///
/// Google ML Kit'in Latin script tanıyıcısını kullanıyor — Türkçe'nin
/// Ç/Ğ/İ/Ö/Ş/Ü karakterleri Latin kapsamında olduğu için ek bir dil
/// paketi gerekmiyor, tamamen çevrimdışı çalışıyor.
///
/// ÖNEMLİ SINIRLAMA (bkz. teknoloji karar raporu Bölüm 6):
/// Sahne metni (tabela, ürün etiketi gibi düz belge olmayan metin) OCR
/// doğruluğu gerçek dünyada %70-85 civarında kalıyor. Bu yüzden
/// kullanıcıya "emin değilim, tekrar okutun" gibi bir geri bildirim
/// mekanizması eklenmeli (bu görevde: boş/çok kısa sonuçta kullanıcıyı
/// bilgilendiriyoruz).
class OcrService {
  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);

  /// Kameradan gelen ham CameraImage'ı ML Kit'in InputImage formatına
  /// çevirip metni okur. Ham piksel işleme bizim tarafımızda yok —
  /// ML Kit CameraImage planlarını doğrudan kabul ediyor.
  Future<String?> readText(
    CameraImage cameraImage,
    CameraDescription cameraDescription,
  ) async {
    final inputImage = _toInputImage(cameraImage, cameraDescription);
    if (inputImage == null) return null;

    final result = await _recognizer.processImage(inputImage);
    final text = result.text.trim();

    if (text.isEmpty) return null;
    return text;
  }

  InputImage? _toInputImage(
    CameraImage cameraImage,
    CameraDescription cameraDescription,
  ) {
    // Tüm plane byte'larını tek buffer'da birleştir.
    final allBytes = <int>[];
    for (final plane in cameraImage.planes) {
      allBytes.addAll(plane.bytes);
    }

    // Android arka kamera genelde 90 derece döndürülmüş sensör
    // çıktısı verir (dik tutulan telefon). Bu varsayılan; ekran ters
    // görünürse burada rotation0deg/rotation270deg denenmeli.
    final rotation = InputImageRotation.rotation90deg;

    final format =
        InputImageFormatValue.fromRawValue(cameraImage.format.raw) ??
            InputImageFormat.nv21;

    final metadata = InputImageMetadata(
      size: Size(cameraImage.width.toDouble(), cameraImage.height.toDouble()),
      rotation: rotation,
      format: format,
      bytesPerRow: cameraImage.planes.first.bytesPerRow,
    );

    return InputImage.fromBytes(
      bytes: Uint8List.fromList(allBytes),
      metadata: metadata,
    );
  }

  void dispose() {
    _recognizer.close();
  }
}