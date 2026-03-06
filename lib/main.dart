import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/user_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserService.instance.init();
  runApp(
    const ProviderScope(
      child: SilsiganApp(),
    ),
  );
}
