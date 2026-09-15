import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';
import 'coco_labels_tr.dart';

/// Tek bir algılama sonucu: sınıf adı, güven skoru, kabaca konum ve
/// derinlik modeline aktarmak için 0-1 aralığında normalize edilmiş
/// merkez koordinatları.
class Detection {
  final String labelTr;
  final double confidence;
  final String position; // 'solunuzda', 'önünüzde', 'sağınızda'
  final double xRatio; // 0.0 (sol) - 1.0 (sağ)
  final double yRatio; // 0.0 (üst) - 1.0 (alt)
  Detection(this.labelTr, this.confidence, this.position, this.xRatio, this.yRatio);
}

/// YOLO26-N (ONNX, 320x320 giriş) modelini cihaz üstünde çalıştırır.
///
/// `onnxruntime_v2` paketi kullanılıyor (eski `onnxruntime` paketinin
/// Android SDK 34+ uyumluluğu güncellenmiş sürümü).
///
/// Tasarım kararı: her kamera karesinde değil, dışarıdan (camera_screen.dart)
/// kontrollü aralıklarla (900ms) çağrılmalı — bkz. teknoloji karar raporu
/// Bölüm 2 (hibrit mimari, sürekli çıkarım değil).
class ObjectDetectionService {
  static const int inputSize = 320;
  static const double confidenceThreshold = 0.45;

  OrtSession? _session;
  String? _inputName;
  String? _outputName;

  bool get isReady => _session != null;

  /// Modeli assets içinden yükler.
  Future<void> loadModel({
    String assetPath = 'assets/models/yolo26n.onnx',
  }) async {
    OrtEnv.instance.init();
    final sessionOptions = OrtSessionOptions();

    final rawAsset = await rootBundle.load(assetPath);
    final modelBytes = rawAsset.buffer.asUint8List();

    final session = OrtSession.fromBuffer(modelBytes, sessionOptions);
    _session = session;

    _inputName = session.inputNames.isNotEmpty ? session.inputNames.first : 'images';
    _outputName =
        session.outputNames.isNotEmpty ? session.outputNames.first : 'output0';
  }

  /// Kameradan gelen ham CameraImage'ı (YUV420) alır, YOLO26-N ile
  /// işler, eşiği geçen en güvenilir algılamayı döndürür.
  Future<List<Detection>> runOnFrame(CameraImage cameraImage) async {
    final session = _session;
    if (session == null || _inputName == null || _outputName == null) {
      return [];
    }

    // 1) YUV420 -> RGB dönüşümü
    final rgbImage = _convertYUV420ToImage(cameraImage);

    // 2) 320x320'e resize
    final resized = img.copyResize(rgbImage, width: inputSize, height: inputSize);

    // 3) Float32 [1,3,320,320], 0-1 normalize, CHW sırası
    final inputData = Float32List(1 * 3 * inputSize * inputSize);
    int idx = 0;
    for (int c = 0; c < 3; c++) {
      for (int y = 0; y < inputSize; y++) {
        for (int x = 0; x < inputSize; x++) {
          final pixel = resized.getPixel(x, y);
          final value = c == 0 ? pixel.r : (c == 1 ? pixel.g : pixel.b);
          inputData[idx++] = value / 255.0;
        }
      }
    }

    final inputOrt = OrtValueTensor.createTensorWithDataList(
      inputData,
      [1, 3, inputSize, inputSize],
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

    if (outputTensor == null) return [];

    // Çıktı şekli: [1, 84, 2100] -> 4 kutu koordinatı + 80 sınıf skoru.
    final rawOutput = outputTensor.value as List;
    final channels = (rawOutput[0] as List); // [84][2100]
    final numBoxes = (channels[0] as List).length;

    double bestConf = 0;
    int bestClass = -1;
    double bestX = 0;
    double bestY = 0;

    for (int i = 0; i < numBoxes; i++) {
      double maxClsScore = 0;
      int maxClsIdx = -1;
      for (int c = 0; c < 80; c++) {
        final score = ((channels[4 + c] as List)[i] as num).toDouble();
        if (score > maxClsScore) {
          maxClsScore = score;
          maxClsIdx = c;
        }
      }
      if (maxClsScore > bestConf) {
        bestConf = maxClsScore;
        bestClass = maxClsIdx;
        bestX = ((channels[0] as List)[i] as num).toDouble();
        bestY = ((channels[1] as List)[i] as num).toDouble();
      }
    }

    for (final o in outputs) {
      o?.release();
    }

    if (bestConf >= confidenceThreshold && bestClass >= 0) {
      final label = cocoLabelsTr[bestClass] ?? 'bilinmeyen nesne';
      final position = _positionFromX(bestX);
      final xRatio = (bestX / inputSize).clamp(0.0, 1.0);
      final yRatio = (bestY / inputSize).clamp(0.0, 1.0);
      return [Detection(label, bestConf, position, xRatio, yRatio)];
    }

    return [];
  }

  String _positionFromX(double xCenter) {
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