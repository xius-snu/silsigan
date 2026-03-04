import 'package:flutter_riverpod/flutter_riverpod.dart';

final vietnameseDraftProvider = StateProvider<String>((ref) => '');

final vietnameseHistoryProvider = StateProvider<List<String>>((ref) => []);
