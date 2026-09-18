import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import '../services/tts_service.dart';
import '../services/object_detection_service.dart';
import '../services/depth_estimation_service.dart';

/// AccessAI'ın ana ekranı.
///
/// Faz 1 - Görev 2: YOLO26-N artık gerçek zamanlı çalışıyor.
/// Tasarım kararı: her kamera karesinde DEĞİL, ~900ms'de bir kare
/// işleniyor (bkz. teknoloji karar raporu Bölüm 2 — sürekli VLM/CV
/// çalıştırmak yerine kontrollü örnekleme, pil ve gecikme için).
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  final TtsService _tts = TtsService();
  final ObjectDetectionService _detector = ObjectDetectionService();
  final DepthEstimationService _depthService = DepthEstimationService();

  bool _permissionGranted = false;
  bool _cameraReady = false;
  bool _modelReady = false;
  bool _depthReady = false;
  bool _detectionActive = false; // "Çevreyi Tarif Et" açık/kapalı
  bool _isProcessingFrame = false;
  String _statusMessage = 'Başlatılıyor...';

  Timer? _detectionTimer;
  // Her etiket için ayrı "en son ne zaman söylendi" hafızası — böylece
  // örn. "insan" 2 saniye önce söylendiyse susturulur ama aynı anda yeni
  // görünen "sandalye" yine de söylenir (bkz. rapor Bölüm 10).
  final Map<String, DateTime> _lastSpokenAtByLabel = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    await _tts.init();
    await _loadModel();
    await _requestPermissionsAndStartCamera();
  }

  Future<void> _loadModel() async {
    try {
      await _detector.loadModel(assetPath: 'assets/models/yolo26n.onnx');
      if (mounted) setState(() => _modelReady = true);
    } catch (e) {
      debugPrint('Nesne algılama modeli yüklenemedi: $e');
    }
    try {
      await _depthService.loadModel(
        assetPath: 'assets/models/fused_model_uint8_256.onnx',
      );
      _depthReady = true;
    } catch (e) {
      debugPrint('Derinlik modeli yüklenemedi (mesafesiz devam edilecek): $e');
      // Kritik değil: derinlik modeli yüklenemezse sistem sadece konum
      // söylemeye devam eder, mesafe bilgisi olmadan (kademeli bozulma).
    }
  }

  Future<void> _requestPermissionsAndStartCamera() async {
    final cameraStatus = await Permission.camera.request();

    if (!cameraStatus.isGranted) {
      setState(() {
        _permissionGranted = false;
        _statusMessage =
            'Kamera izni verilmedi. AccessAI\'nın çalışması için kamera izni gereklidir.';
      });
      await _tts.speak(
          'Kamera izni verilmedi. Uygulamanın çalışması için ayarlardan kamera iznini açmanız gerekiyor.');
      return;
    }

    setState(() => _permissionGranted = true);
    await _startCamera();
  }

  Future<void> _startCamera() async {
    if (availableCamerasList.isEmpty) {
      setState(() => _statusMessage = 'Kamera bulunamadı.');
      await _tts.speak('Cihazda kullanılabilir bir kamera bulunamadı.');
      return;
    }

    final backCamera = availableCamerasList.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => availableCamerasList.first,
    );

    final controller = CameraController(
      backCamera,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );

    try {
      await controller.initialize();
      if (!mounted) return;
      setState(() {
        _controller = controller;
        _cameraReady = true;
        _statusMessage = 'Kamera hazır.';
      });
      await _tts.speak('AccessAI hazır. Çevrenizi anlamak için ekrana dokunun.');
    } catch (e) {
      setState(() => _statusMessage = 'Kamera başlatılamadı: $e');
      await _tts.speak('Kamera başlatılırken bir hata oluştu.');
    }
  }

  /// "Çevreyi Tarif Et" butonuna basınca sürekli algılamayı aç/kapat.
  Future<void> _onDescribeTapped() async {
    if (!_cameraReady) return;

    if (!_modelReady) {
      await _tts.speak(
          'Nesne algılama modeli henüz hazır değil, lütfen birkaç saniye bekleyin.');
      return;
    }

    setState(() => _detectionActive = !_detectionActive);

    if (_detectionActive) {
      await _tts.speak('Çevre algılama açık.');
      _startDetectionLoop();
    } else {
      await _tts.speak('Çevre algılama kapalı.');
      _detectionTimer?.cancel();
    }
  }

  void _startDetectionLoop() {
    _detectionTimer?.cancel();
    _detectionTimer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      _processFrame();
    });
  }

  Future<void> _processFrame() async {
    final controller = _controller;
    if (controller == null || _isProcessingFrame || !_detectionActive) return;

    _isProcessingFrame = true;
    try {
      // startImageStream yerine periyodik tek-kare yaklaşımı: basitlik ve
      // pil tüketimi için. V2'de gerçek stream + arka plan izole edilebilir.
      await controller.startImageStream((CameraImage image) async {
        await controller.stopImageStream();
        final detections = await _detector.runOnFrame(image);
        await _handleDetections(detections, image);
      });
    } catch (e) {
      debugPrint('Kare işleme hatası: $e');
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _handleDetections(
    List<Detection> detections,
    CameraImage sourceImage,
  ) async {
    if (detections.isEmpty) return;

    final now = DateTime.now();

    // Temporal consistency: her nesneyi kendi 4 saniyelik susturma
    // penceresine göre filtrele (rapor Bölüm 10 — "Araba. Araba. Araba."
    // önleme, ama artık nesne bazlı, tek etiket bazlı değil).
    final toSpeak = detections.where((d) {
      final last = _lastSpokenAtByLabel[d.labelTr];
      final tooSoon =
          last != null && now.difference(last) < const Duration(seconds: 4);
      return !tooSoon;
    }).toList();

    if (toSpeak.isEmpty) return;

    for (final d in toSpeak) {
      _lastSpokenAtByLabel[d.labelTr] = now;
    }

    // Derinlik şu an devre dışı (Faz 1 - Görev 3 ertelendi), ama
    // _depthReady true olursa ilk nesne için mesafe eklemeye devam eder.
    final parts = <String>[];
    for (final d in toSpeak) {
      String part = '${d.labelTr} ${d.position}';
      if (_depthReady && d == toSpeak.first) {
        try {
          final distanceLabel = await _depthService.estimateDistanceLabel(
            sourceImage,
            focusXRatio: d.xRatio,
            focusYRatio: d.yRatio,
          );
          if (distanceLabel != null) part = '$part, $distanceLabel';
        } catch (e) {
          debugPrint('Derinlik tahmini başarısız, mesafesiz devam: $e');
        }
      }
      parts.add(part);
    }

    // Örnek: "solunuzda insan, önünüzde sandalye, sağınızda kapı"
    await _tts.speak(parts.join(', '));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _detectionTimer?.cancel();
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detectionTimer?.cancel();
    _controller?.dispose();
    _detector.dispose();
    _depthService.dispose();
    _tts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: _cameraReady && _controller != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  CameraPreview(_controller!),
                  if (!_modelReady)
                    const Positioned(
                      top: 16,
                      left: 16,
                      right: 16,
                      child: LinearProgressIndicator(),
                    ),
                  Positioned(
                    bottom: 32,
                    left: 24,
                    right: 24,
                    child: Semantics(
                      label: _detectionActive
                          ? 'Çevre algılama açık. Kapatmak için dokunun.'
                          : 'Çevreyi tarif et. Dokunarak etkinleştirin.',
                      button: true,
                      child: ElevatedButton(
                        onPressed: _onDescribeTapped,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(72),
                          textStyle: const TextStyle(fontSize: 22),
                          backgroundColor:
                              _detectionActive ? Colors.green : null,
                        ),
                        child: Text(_detectionActive
                            ? 'Algılama Açık (Durdur)'
                            : 'Çevreyi Tarif Et'),
                      ),
                    ),
                  ),
                ],
              )
            : Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (!_permissionGranted || !_cameraReady)
                        const CircularProgressIndicator(),
                      const SizedBox(height: 16),
                      Text(
                        _statusMessage,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
