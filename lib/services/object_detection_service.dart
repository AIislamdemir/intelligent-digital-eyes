import 'dart:async';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'coco_labels_tr.dart';

/// Tek bir algılama sonucu: sınıf adı, güven skoru ve kabaca konum.
class Detection {
  final String labelTr;
  final double confidence;
  final String position; // 'solunuzda', 'önünüzde', 'sağınızda'
  Detection(this.labelTr, this.confidence, this.position);
}

/// YOLO26-N (ONNX, 320x320 giriş) modelini cihaz üstünde çalıştırır.
///
/// Tasarım kararı: her kamera karesinde değil, `runOnFrame` dışarıdan
/// kontrollü aralıklarla (örn. 700-1000ms'de bir) çağrılmalı — bkz.
/// teknoloji karar raporu Bölüm 2 (hibrit mimari, sürekli çıkarım değil).
class ObjectDetectionService {
  static const int inputSize = 320;
  static const double confidenceThreshold = 0.45;

  OrtSession? _session;
  bool get isReady => _session != null;

  /// Modeli yükler. `modelBytes`, camera_screen.dart içinde
  /// `rootBundle.load('assets/models/yolo26n.onnx')` ile okunup buraya
  /// verilir (bu servis widget bağlamından bağımsız kalsın diye).
  Future<void> loadModelFromBytes(Uint8List modelBytes) async {
    OrtEnv.instance.init();
    final sessionOptions = OrtSessionOptions();
    _session = OrtSession.fromBuffer(modelBytes, sessionOptions);
  }

  /// Kameradan gelen ham CameraImage'ı (YUV420) alır, YOLO26-N ile
  /// işler, eşiği geçen en güvenilir 1-2 algılamayı döndürür.
  Future<List<Detection>> runOnFrame(CameraImage cameraImage) async {
    final session = _session;
    if (session == null) return [];

    // 1) YUV420 -> RGB dönüşümü (image paketiyle)
    final rgbImage = _convertYUV420ToImage(cameraImage);

    // 2) 320x320'e resize + letterbox yok (basitlik için doğrudan resize)
    final resized = img.copyResize(rgbImage, width: inputSize, height: inputSize);

    // 3) Float32 [1,3,320,320], 0-1 normalize, CHW sırası
    final inputTensorData = Float32List(1 * 3 * inputSize * inputSize);
    int idx = 0;
    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resized.getPixel(x, y);
          final value = c == 0 ? pixel.r : (c == 1 ? pixel.g : pixel.b);
          inputTensorData[idx++] = value / 255.0;
        }
      }
    }

    final inputOrt = OrtValueTensor.createTensorWithDataList(
      inputTensorData,
      [1, 3, inputSize, inputSize],
    );

    final inputs = {'images': inputOrt};
    final runOptions = OrtRunOptions();
    final outputs = session.run(runOptions, inputs);
    inputOrt.release();
    runOptions.release();

    // Çıktı şekli: [1, 84, 2100] -> 4 kutu koordinatı + 80 sınıf skoru
    final rawOutput = outputs.first?.value as List;
    final flat = (rawOutput[0] as List); // [84, 2100]

    final detections = <Detection>[];
    double bestConf = 0;
    int bestClass = -1;
    double bestX = 0;

    final numBoxes = (flat[0] as List).length; // 2100
    for (int i = 0; i < numBoxes; i++) {
      double maxClsScore = 0;
      int maxClsIdx = -1;
      for (int c = 0; c < 80; c++) {
        final score = (flat[4 + c] as List)[i] as double;
        if (score > maxClsScore) {
          maxClsScore = score;
          maxClsIdx = c;
        }
      }
      if (maxClsScore > bestConf) {
        bestConf = maxClsScore;
        bestClass = maxClsIdx;
        bestX = (flat[0] as List)[i] as double; // normalize edilmemiş x-center
      }
    }

    for (final o in outputs) {
      o?.release();
    }

    if (bestConf >= confidenceThreshold && bestClass >= 0) {
      final label = cocoLabelsTr[bestClass] ?? 'bilinmeyen nesne';
      final position = _positionFromX(bestX);
      detections.add(Detection(label, bestConf, position));
    }

    return detections;
  }

  String _positionFromX(double xCenter) {
    // xCenter, 320px giriş uzayında; 3 bölgeye ayır.
    if (xCenter < inputSize * 0.33) return 'solunuzda';
    if (xCenter > inputSize * 0.66) return 'sağınızda';
    return 'önünüzde';
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
    OrtEnv.instance.release();
  }
}