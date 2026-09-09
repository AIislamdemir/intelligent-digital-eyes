import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'screens/camera_screen.dart';

/// Uygulama genelinde kullanılacak kamera listesi (main() içinde doldurulur).
List<CameraDescription> availableCamerasList = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    availableCamerasList = await availableCameras();
  } catch (e) {
    // Kamera bulunamadıysa uygulama yine de açılsın, ekranda hata gösterilir.
    debugPrint('Kamera listesi alınamadı: $e');
  }

  runApp(const AccessAIApp());
}

class AccessAIApp extends StatelessWidget {
  const AccessAIApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AccessAI',
      debugShowCheckedModeBanner: false,
      // Yüksek kontrast + büyük dokunma alanları: erişilebilirlik önceliği.
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blueAccent,
        useMaterial3: true,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(fontSize: 20),
          bodyMedium: TextStyle(fontSize: 18),
        ),
      ),
      home: const CameraScreen(),
    );
  }
}