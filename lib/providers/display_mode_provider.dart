import 'package:flutter_riverpod/flutter_riverpod.dart';

enum DisplayMode { lineByLine, split }

final displayModeProvider =
    StateProvider<DisplayMode>((ref) => DisplayMode.lineByLine);
