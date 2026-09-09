import 'package:flutter_tts/flutter_tts.dart';

/// AccessAI'ın sesli geri bildirim katmanını sarmalayan basit servis.
///
/// Şu an native (Android/iOS) TTS motorunu kullanıyor — çevrimdışı çalışır,
/// ek model indirmez. İleride Piper gibi daha doğal-sesli çevrimdışı bir
/// motora geçilebilir (bkz. teknoloji karar raporu, Bölüm 8).
class TtsService {
  final FlutterTts _tts = FlutterTts();
  bool _isSpeaking = false;

  Future<void> init() async {
    await _tts.setLanguage('tr-TR');
    await _tts.setSpeechRate(0.5); // 0.0-1.0 arası; net anlaşılırlık için orta hız
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);

    _tts.setStartHandler(() => _isSpeaking = true);
    _tts.setCompletionHandler(() => _isSpeaking = false);
    _tts.setErrorHandler((msg) => _isSpeaking = false);
  }

  /// Konuşurken yeni bir istek gelirse öncekini keser — kullanıcıyı bilgi
  /// yığınıyla boğmamak için (bkz. rapor Bölüm 16: Adaptif Sesli Geri Bildirim).
  Future<void> speak(String text) async {
    if (_isSpeaking) {
      await _tts.stop();
    }
    await _tts.speak(text);
  }

  Future<void> dispose() async {
    await _tts.stop();
  }
}