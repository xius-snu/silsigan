import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../utils/constants.dart';

/// First-launch disclosure + consent screen.
///
/// Shown before the app is usable so the user is told, in plain language,
/// what data leaves the device, who it goes to, and can grant permission
/// before any audio is streamed. Required by Apple guidelines 5.1.1(i) /
/// 5.1.2(i) for sharing personal data with a third-party AI service.
///
/// The face of the screen describes the recipient generically ("a third-party
/// AI service"); the specific provider name is kept one tap away, behind the
/// "Learn more" reveal and in the linked privacy policy, so it isn't front and
/// center while still being disclosed.
class ConsentScreen extends StatefulWidget {
  const ConsentScreen({super.key, required this.onAccepted});

  /// Called after the user taps "Agree & Continue". The caller persists the
  /// consent flag and swaps in the main screen.
  final VoidCallback onAccepted;

  @override
  State<ConsentScreen> createState() => _ConsentScreenState();
}

class _ConsentScreenState extends State<ConsentScreen> {
  static const _privacyUrl = 'https://xius-snu.github.io/silsigan/privacy';
  // Third-party processor's own privacy policy. Linked (not named) so the
  // recipient stays identifiable for compliance without putting the vendor
  // name in our copy.
  static const _providerPrivacyUrl =
      'https://soniox.com/policies/privacy-policy';

  bool _detailsExpanded = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(26, 40, 26, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Silsigan',
                      style: TextStyle(
                        fontSize: AppConstants.titleFontSize,
                        fontWeight: FontWeight.w700,
                        color: AppConstants.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Before you start',
                      style: TextStyle(
                        fontSize: 16,
                        color: AppConstants.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 28),
                    _buildDisclosureCard(),
                    const SizedBox(height: 16),
                    _buildLearnMore(),
                    const SizedBox(height: 18),
                    _buildPrivacyRow(),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(26, 8, 26, 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: widget.onAccepted,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.micButtonColor,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Agree & Continue',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDisclosureCard() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 8),
      decoration: BoxDecoration(
        color: AppConstants.panelColor,
        borderRadius: BorderRadius.circular(AppConstants.panelBorderRadius),
        border: Border.all(color: const Color(0xFFE2E2E2)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DisclosureItem(
            icon: Icons.mic_none_rounded,
            title: 'What we send',
            body:
                'When you record, your voice audio and the text transcribed '
                'from it are streamed off your device to be processed in real '
                'time.',
          ),
          _DisclosureItem(
            icon: Icons.cloud_outlined,
            title: 'Who receives it',
            body:
                'Audio is sent through our secure server to a third-party AI '
                'service, which processes it in real time and does not store '
                'it afterward.',
          ),
          _DisclosureItem(
            icon: Icons.verified_user_outlined,
            title: 'Your choice',
            body:
                'Nothing is sent until you tap the microphone. Audio '
                'recordings you save stay on your device. By continuing you '
                'agree to this processing.',
            isLast: true,
          ),
        ],
      ),
    );
  }

  /// Unobtrusive expander that reveals the specific provider name for users
  /// who want the detail. Kept off the main card so it isn't front and center.
  Widget _buildLearnMore() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _detailsExpanded = !_detailsExpanded),
          child: Row(
            children: [
              Icon(
                _detailsExpanded
                    ? Icons.expand_less_rounded
                    : Icons.expand_more_rounded,
                size: 18,
                color: Colors.grey[600],
              ),
              const SizedBox(width: 4),
              Text(
                'Which service processes my audio?',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.grey[600],
                ),
              ),
            ],
          ),
        ),
        AnimatedCrossFade(
          duration: const Duration(milliseconds: 180),
          crossFadeState: _detailsExpanded
              ? CrossFadeState.showSecond
              : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(left: 22, top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Speech recognition is handled by a third-party AI '
                  'service. Audio is processed in real time and is not '
                  'stored after processing.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.4,
                    color: Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: () => launchUrl(
                    Uri.parse(_providerPrivacyUrl),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text(
                    "View the provider's privacy policy",
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppConstants.textPrimary,
                      fontWeight: FontWeight.w600,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPrivacyRow() {
    return GestureDetector(
      onTap: () => launchUrl(
        Uri.parse(_privacyUrl),
        mode: LaunchMode.externalApplication,
      ),
      child: Row(
        children: [
          Text(
            'Read our ',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const Text(
            'Privacy Policy',
            style: TextStyle(
              fontSize: 13,
              color: AppConstants.textPrimary,
              fontWeight: FontWeight.w600,
              decoration: TextDecoration.underline,
            ),
          ),
          Text(
            ' to learn more.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
        ],
      ),
    );
  }
}

class _DisclosureItem extends StatelessWidget {
  const _DisclosureItem({
    required this.icon,
    required this.title,
    required this.body,
    this.isLast = false,
  });

  final IconData icon;
  final String title;
  final String body;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: isLast ? 14 : 22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: AppConstants.textPrimary),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppConstants.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  body,
                  style: const TextStyle(
                    fontSize: 13.5,
                    height: 1.4,
                    color: AppConstants.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
