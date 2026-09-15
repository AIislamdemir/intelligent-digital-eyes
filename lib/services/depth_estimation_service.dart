import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

/// Depth Anything V2 (fused_model_uint8_256.onnx) ile kaba/göreli
/// derinlik tahmini.
///
/// Model formatı ONNX dosyası incelenerek DOĞRULANDI (tahmin değil):
///  - Giriş: UINT8, NHWC [1, 256, 256, 3] — ham RGB piksel, normalize
///    GEREKMİYOR (0-1 ölçekleme yok, ImageNet mean/std yok).
///  - Çıkış: UINT8 [1, 518, 518] — değer ne kadar büyükse (255'e
///    yakınsa) o nokta kameraya o kadar YAKIN.
///
/// ÖNEMLİ SINIRLAMA (bkz. teknoloji karar raporu Bölüm 4):
/// Bu METRİK (gerçek metre) derinlik değil, GÖRELİ derinlik. Bu yüzden
/// kullanıcıya kesin bir sayı ("2.3 metre") söylemiyoruz, sadece
/// "yakın / orta mesafede / uzakta" gibi bantlar kullanıyoruz.
class DepthEstimationService {
  static const int inputSize = 256;
  static const int outputSize = 518;

  OrtSession? _session;
  String? _inputName;
  String? _outputName;

  bool get isReady => _session != null;

  Future<void> loadModel({
    String assetPath = 'assets/models/fused_model_uint8_256.onnx',
  }) async {
    OrtEnv.instance.init();
    final sessionOptions = OrtSessionOptions();

    final rawAsset = await rootBundle.load(assetPath);
    final modelBytes = rawAsset.buffer.asUint8List();

    final session = OrtSession.fromBuffer(modelBytes, sessionOptions);
    _session = session;

    _inputName = session.inputNames.isNotEmpty
        ? session.inputNames.first
        : 'pre-preop-input';
    _outputName = session.outputNames.isNotEmpty
        ? session.outputNames.first
        : 'post-postop-output';
  }

  /// Bir kamera karesindeki, YOLO'nun bulduğu nesnenin merkezindeki kaba
  /// derinliği "yakın / orta mesafe / uzak" olarak döndürür.
  ///
  /// [focusXRatio]/[focusYRatio]: 0.0-1.0 arası, karede hangi bölgeye
  /// bakılacağını belirtir (nesnenin merkezi).
  Future<String?> estimateDistanceLabel(
    CameraImage cameraImage, {
    double focusXRatio = 0.5,
    double focusYRatio = 0.5,
  }) async {
    final session = _session;
    if (session == null || _inputName == null || _outputName == null) {
      return null;
    }

    final rgbImage = _convertYUV420ToImage(cameraImage);
    final resized = img.copyResize(rgbImage, width: inputSize, height: inputSize);

    // NHWC, UINT8, normalize YOK — ham piksel değerleri doğrudan.
    final inputData = Uint8List(1 * inputSize * inputSize * 3);
    int idx = 0;
    for (int y = 0; y < inputSize; y++) {
      for (int x = 0; x < inputSize; x++) {
        final pixel = resized.getPixel(x, y);
        inputData[idx++] = pixel.r.toInt();
        inputData[idx++] = pixel.g.toInt();
        inputData[idx++] = pixel.b.toInt();
      }
    }

    final inputOrt = OrtValueTensor.createTensorWithDataList(
      inputData,
      [1, inputSize, inputSize, 3],
    );

    final inputs = {_inputName!: inputOrt};
    final runOptions = OrtRunOptions();
    final outputs = session.run(runOptions, inputs);
    inputOrt.release();
    runOptions.release();

    final outputTensor = outputs.firstWhere(
      (o) => o != null,
      orElse: () => null,
    );
    if (outputTensor == null) return null;

    // Çıktı: [1, 518, 518], UINT8. Büyük değer = yakın.
    final raw = outputTensor.value as List;
    for (final o in outputs) {
      o?.release();
    }

    final depthMap = raw[0] as List; // [518][518]

    final focusY = (focusYRatio * outputSize).clamp(0, outputSize - 1).toInt();
    final focusX = (focusXRatio * outputSize).clamp(0, outputSize - 1).toInt();
    final focusValue = ((depthMap[focusY] as List)[focusX] as num).toInt();

    // Sabit eşikler yerine, modelin 0-255 aralığını 3 bölgeye ayırıyoruz.
    // (255'e yakın = çok yakın, 0'a yakın = çok uzak — modelin kendi
    // postop normalizasyonu sayesinde kare-kare tutarlı.)
    if (focusValue > 170) return 'yakın';
    if (focusValue > 85) return 'orta mesafede';
    return 'uzakta';
  }

  img.Image _convertYUV420ToImage(CameraImage cameraImage) {
    final width = cameraImage.width;
    final height = cameraImage.height;
    final image = img.Image(width: width, height: height);

    final yPlane = cameraImage.planes[0];
    final uPlane = cameraImage.planes[1];
    final vPlane = cameraImage.planes[2];

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final yIndex = y * yRowStride + x;
        final uvIndex = (y ~/ 2) * uvRowStride + (x ~/ 2) * uvPixelStride;

        final yValue = yPlane.bytes[yIndex];
        final uValue = uPlane.bytes[uvIndex];
        final vValue = vPlane.bytes[uvIndex];

        final r = (yValue + 1.402 * (vValue - 128)).clamp(0, 255).toInt();
        final g = (yValue - 0.344136 * (uValue - 128) - 0.714136 * (vValue - 128))
            .clamp(0, 255)
            .toInt();
        final b = (yValue + 1.772 * (uValue - 128)).clamp(0, 255).toInt();

        image.setPixelRgb(x, y, r, g, b);
      }
    }
    return image;
  }

  void dispose() {
    _session?.release();
  }
}