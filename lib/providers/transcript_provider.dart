import 'package:flutter_riverpod/flutter_riverpod.dart';

final koreanDraftProvider = StateProvider<String>((ref) => '');

final koreanHistoryProvider = StateProvider<List<String>>((ref) => []);
