import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

class UpdateInfo {
  final String latestVersion;
  final String updateUrl;
  final bool forceUpdate;

  UpdateInfo({
    required this.latestVersion,
    required this.updateUrl,
    required this.forceUpdate,
  });
}

class UpdateService {
  static const _versionUrl =
      'https://raw.githubusercontent.com/xius-snu/silsigan/master/version.json';

  /// Returns [UpdateInfo] if an update is available, null otherwise.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http
          .get(Uri.parse(_versionUrl))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final latestVersion = data['latest_version'] as String? ?? '';
      final updateUrl = data['update_url'] as String? ?? '';
      final forceUpdate = data['force_update'] as bool? ?? false;

      if (latestVersion.isEmpty || updateUrl.isEmpty) return null;

      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      if (_isNewer(latestVersion, currentVersion)) {
        return UpdateInfo(
          latestVersion: latestVersion,
          updateUrl: updateUrl,
          forceUpdate: forceUpdate,
        );
      }
      return null;
    } catch (_) {
      return null; // Fail silently — don't block the app
    }
  }

  /// Returns true if [remote] is newer than [local].
  /// Compares semver segments numerically: 1.0.3 > 1.0.2, 1.1.0 > 1.0.9
  static bool _isNewer(String remote, String local) {
    final remoteParts = remote.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final localParts = local.split('.').map((s) => int.tryParse(s) ?? 0).toList();

    final len = remoteParts.length > localParts.length
        ? remoteParts.length
        : localParts.length;

    for (int i = 0; i < len; i++) {
      final r = i < remoteParts.length ? remoteParts[i] : 0;
      final l = i < localParts.length ? localParts[i] : 0;
      if (r > l) return true;
      if (r < l) return false;
    }
    return false;
  }
}
