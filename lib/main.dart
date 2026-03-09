import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'services/user_service.dart';
import 'services/background_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  BackgroundService.init();
  await UserService.instance.init();
  UserService.instance.reportActivity('app_open');
  runApp(
    const ProviderScope(
      child: SilsiganApp(),
    ),
  );
}
