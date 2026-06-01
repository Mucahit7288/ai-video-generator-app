import 'package:google_generative_ai/google_generative_ai.dart';

class GeminiService {
  final String _apiKey = "AIzaSyBt8OGgQ4O1zjHb_EwXqDG92BllZUqE0nM";

  static const String _systemInstruction =
      "Sen yaratıcı bir hikaye yazarısın. "
      "Kullanıcının verdiği fikirden yola çıkarak kısa ve etkileyici bir hikaye yaz.\n\n"
      "ÇIKTI FORMATI — Bu kurallara kesinlikle uy, hiç sapma:\n"
      "1. İlk satır YALNIZCA şu şekilde olmalı: BAŞLIK: [hikayenin başlığı]\n"
      "2. İkinci satır YALNIZCA şu şekilde olmalı: HİKAYE: [hikayenin tamamı]\n"
      "3. Bu iki satırdan önce veya sonra hiçbir açıklama, selamlama, not veya ek metin yazma.\n"
      "4. Başlık tek satır olmalı, hikaye ise birden fazla paragraf içerebilir.\n\n"
      "ÖRNEK ÇIKTI:\n"
      "BAŞLIK: Yıldızların Altında\n"
      "HİKAYE: O gece gökyüzü hiç bu kadar net olmamıştı...";

  Future<Map<String, String>> generateStory(String userPrompt) async {
    try {
      final model = GenerativeModel(
        model: 'gemini-3.5-flash',
        apiKey: _apiKey,
        systemInstruction: Content.system(_systemInstruction),
      );

      final prompt = Content.text(userPrompt);
      final response = await model.generateContent([prompt]);
      final rawText = response.text;

      if (rawText == null || rawText.trim().isEmpty) {
        return {
          'title': 'Hata',
          'content':
              'Yapay zekadan boş bir yanıt alındı. Lütfen tekrar deneyin.',
        };
      }

      return _parseResponse(rawText);
    } on GenerativeAIException catch (e) {
      return {
        'title': 'API Hatası',
        'content': 'Gemini API\'ye bağlanırken bir hata oluştu: ${e.message}',
      };
    } catch (e) {
      return {
        'title': 'Beklenmeyen Hata',
        'content': 'Hikaye üretilirken beklenmeyen bir hata oluştu: $e',
      };
    }
  }

  Map<String, String> _parseResponse(String rawText) {
    try {
      final text = rawText.trim();

      // --- Strateji 1: Standart format (BAŞLIK: ... HİKAYE: ...) ---
      final titleMatch = RegExp(
        r'BAŞLIK\s*:\s*(.+?)(?=\nHİKAYE\s*:|\r\nHİKAYE\s*:)',
        dotAll: true,
        caseSensitive: false,
      ).firstMatch(text);

      final storyMatch = RegExp(
        r'HİKAYE\s*:\s*([\s\S]+)',
        caseSensitive: false,
      ).firstMatch(text);

      if (titleMatch != null && storyMatch != null) {
        final title = titleMatch.group(1)?.trim() ?? '';
        final content = storyMatch.group(1)?.trim() ?? '';
        return {
          'title': title.isNotEmpty ? title : _extractFallbackTitle(text),
          'content': content.isNotEmpty ? content : text,
        };
      }

      // --- Strateji 2: Sadece BAŞLIK: var, HİKAYE: etiketi yok ---
      final onlyTitleMatch = RegExp(
        r'BAŞLIK\s*:\s*(.+)',
        caseSensitive: false,
      ).firstMatch(text);

      if (onlyTitleMatch != null) {
        final title = onlyTitleMatch.group(1)?.trim() ?? '';
        // Başlık satırından sonrasını içerik say
        final titleLineEnd = text.indexOf('\n', onlyTitleMatch.end);
        final content = titleLineEnd != -1
            ? text.substring(titleLineEnd).trim()
            : text;
        return {
          'title': title.isNotEmpty ? title : _extractFallbackTitle(text),
          'content': content.isNotEmpty ? content : text,
        };
      }

      // --- Strateji 3: Hiç etiket yok — ilk satırı başlık yap ---
      return _fallbackParse(text);
    } catch (e) {
      return {
        'title': 'Ayrıştırma Hatası',
        'content':
            'Yanıt işlenirken bir hata oluştu: $e\n\nHam yanıt:\n$rawText',
      };
    }
  }

  /// Etiket bulunamadığında ilk satırı (veya ilk 4-5 kelimeyi) başlık yapar.
  Map<String, String> _fallbackParse(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return {'title': 'İsimsiz Hikaye', 'content': text};
    }

    final firstLine = lines.first;

    // İlk satır çok uzunsa (roman gibi başlıyorsa) sadece ilk 4-5 kelimeyi al
    final title = _shortenTitle(firstLine);
    final content = lines.length > 1
        ? lines.skip(1).join('\n\n').trim()
        : text; // tek satırlık yanıtsa tamamını içerik yap

    return {'title': title, 'content': content.isNotEmpty ? content : text};
  }

  /// Verilen metinden kısa bir başlık türetir (maks. 5 kelime).
  String _extractFallbackTitle(String text) {
    final firstLine = text
        .split('\n')
        .firstWhere((l) => l.trim().isNotEmpty, orElse: () => text);
    return _shortenTitle(firstLine.trim());
  }

  /// Gerekirse metni 5 kelimeyle kırpar ve "..." ekler.
  String _shortenTitle(String line) {
    const maxWords = 5;
    final words = line.split(RegExp(r'\s+'));
    if (words.length <= maxWords) return line;
    return '${words.take(maxWords).join(' ')}...';
  }
}
