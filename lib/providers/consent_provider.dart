import 'package:shared_preferences/shared_preferences.dart';

/// Whether the user has accepted the data-processing disclosure that must be
/// shown before any audio is sent to our transcription/translation provider.
///
/// Apple guidelines 5.1.1(i) / 5.1.2(i) require explicit, informed consent
/// *before* personal data (the user's voice) is shared with a third-party AI
/// service. This flag gates the entire app: until it's true, no recording
/// screen — and therefore no audio streaming — is reachable.
const _consentKey = 'data_sharing_consent_v1';

Future<bool> loadDataSharingConsent() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getBool(_consentKey) ?? false;
}

Future<void> saveDataSharingConsent(bool accepted) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(_consentKey, accepted);
}
