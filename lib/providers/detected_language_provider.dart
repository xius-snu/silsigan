import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Detected source language ISO code from Soniox language identification.
/// null = not yet detected (shows "Any").
final detectedLanguageProvider = StateProvider<String?>((ref) => null);

const languageDisplayNames = <String, String>{
  'ko': 'Korean',
  'en': 'English',
  'vi': 'Vietnamese',
  'tr': 'Turkish',
  'ja': 'Japanese',
  'zh': 'Chinese',
  'es': 'Spanish',
  'fr': 'French',
  'de': 'German',
  'ru': 'Russian',
  'ar': 'Arabic',
  'pt': 'Portuguese',
  'hi': 'Hindi',
  'th': 'Thai',
  'id': 'Indonesian',
  'ms': 'Malay',
  'tl': 'Filipino',
  'it': 'Italian',
  'nl': 'Dutch',
  'pl': 'Polish',
  'uk': 'Ukrainian',
  'sv': 'Swedish',
  'da': 'Danish',
  'no': 'Norwegian',
  'fi': 'Finnish',
  'cs': 'Czech',
  'ro': 'Romanian',
  'hu': 'Hungarian',
  'el': 'Greek',
  'he': 'Hebrew',
  'bn': 'Bengali',
  'ur': 'Urdu',
  'fa': 'Persian',
  'sw': 'Swahili',
  'my': 'Burmese',
  'km': 'Khmer',
  'lo': 'Lao',
  'ne': 'Nepali',
  'si': 'Sinhala',
  'ta': 'Tamil',
  'te': 'Telugu',
  'ml': 'Malayalam',
  'kn': 'Kannada',
  'gu': 'Gujarati',
  'mr': 'Marathi',
  'pa': 'Punjabi',
};

String languageDisplayName(String code) {
  return languageDisplayNames[code] ?? code.toUpperCase();
}
