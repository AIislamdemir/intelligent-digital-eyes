import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import '../main.dart';
import '../services/tts_service.dart';

/// AccessAI'ın ana ekranı.
///
/// Bu aşamada (Faz 1) sadece:
///  - Kamera izni ister
///  - Canlı kamera önizlemesi gösterir
///  - Ekrana dokununca TTS ile geri bildirim verir (AI entegrasyonu için yer tutucu)
///
/// YOLO26-N / derinlik / OCR entegrasyonu bir sonraki adımda buraya bir
/// "FrameProcessor" olarak eklenecek (native platform channel üzerinden).
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  final TtsService _tts = TtsService();

  bool _permissionGranted = false;
  bool _cameraReady = false;
  String _statusMessage = 'Başlatılıyor...';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    await _tts.init();
    await _requestPermissionsAndStartCamera();
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

    // Arka (dünyaya bakan) kamerayı tercih et.
    final backCamera = availableCamerasList.firstWhere(
      (cam) => cam.lensDirection == CameraLensDirection.back,
      orElse: () => availableCamerasList.first,
    );

    final controller = CameraController(
      backCamera,
      ResolutionPreset.medium, // MVP: hız için orta çözünürlük yeterli
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420, // native inference için uygun format
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

  /// Yer tutucu: gerçek algı (YOLO26-N + derinlik) entegre edilene kadar
  /// kullanıcıya sistemin çalıştığını doğrulayan bir sesli yanıt verir.
  Future<void> _onDescribeTapped() async {
    if (!_cameraReady) return;
    await _tts.speak(
        'Sahne analizi henüz bağlı değil. Bu, yapay zeka algı katmanının ekleneceği yerdir.');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
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
                  Positioned(
                    bottom: 32,
                    left: 24,
                    right: 24,
                    child: Semantics(
                      label: 'Çevreyi tarif et. Dokunarak etkinleştirin.',
                      button: true,
                      child: ElevatedButton(
                        onPressed: _onDescribeTapped,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size.fromHeight(72),
                          textStyle: const TextStyle(fontSize: 22),
                        ),
                        child: const Text('Çevreyi Tarif Et'),
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