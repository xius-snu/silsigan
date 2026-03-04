import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../models/transcript_session.dart';
import '../../providers/recording_provider.dart';
import '../../providers/target_language_provider.dart';
import '../../providers/transcript_provider.dart';
import '../../providers/translation_provider.dart';
import '../../providers/session_history_provider.dart';
import '../../services/audio_service.dart';
import '../../services/soniox_realtime_service.dart';
import '../../services/database_service.dart';
import '../../utils/constants.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/record_button.dart';
import '../widgets/save_discard_row.dart';
import '../widgets/status_bar.dart';

class MainScreen extends ConsumerStatefulWidget {
  const MainScreen({super.key});

  @override
  ConsumerState<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends ConsumerState<MainScreen> {
  final AudioService _audioService = AudioService();
  final SonioxRealtimeService _sonioxService = SonioxRealtimeService();

  @override
  void dispose() {
    _audioService.dispose();
    _sonioxService.disconnect();
    super.dispose();
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Microphone Required'),
            content: const Text(
              'This app needs microphone access to transcribe Korean speech. '
              'Please enable it in Settings.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppSettings();
                },
                child: const Text('Settings'),
              ),
            ],
          ),
        );
      }
      return;
    }

    // Clear previous session data
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(koreanHistoryProvider.notifier).state = [];
    ref.read(vietnameseDraftProvider.notifier).state = '';
    ref.read(vietnameseHistoryProvider.notifier).state = [];

    final targetLanguage = ref.read(targetLanguageProvider);

    // Set up Soniox transcription callbacks
    _sonioxService.onTranscriptionDraft = (draft) {
      ref.read(koreanDraftProvider.notifier).state = draft;
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
      if (transcript.isNotEmpty) {
        ref.read(koreanHistoryProvider.notifier).update(
          (state) => [...state, transcript],
        );
        // Korean target: copy transcription to translation panel
        if (targetLanguage == TargetLanguage.korean) {
          ref.read(vietnameseHistoryProvider.notifier).update(
            (state) => [...state, transcript],
          );
        }
      }
      ref.read(koreanDraftProvider.notifier).state = '';
    };

    // Set up Soniox translation callbacks (used when target != Korean)
    _sonioxService.onTranslationDraft = (draft) {
      ref.read(vietnameseDraftProvider.notifier).state = draft;
    };

    _sonioxService.onTranslationCompleted = (translation) {
      if (translation.isNotEmpty) {
        ref.read(vietnameseHistoryProvider.notifier).update(
          (state) => [...state, translation],
        );
      }
      ref.read(vietnameseDraftProvider.notifier).state = '';
    };

    _sonioxService.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transcription error: $error')),
        );
      }
    };

    // Set up audio callback
    _audioService.onAudioChunk = (bytes) {
      _sonioxService.sendAudio(bytes);
    };

    try {
      await _sonioxService.connect(targetLanguageCode: targetLanguage.code);
      await _audioService.start();
      ref.read(recordingStateProvider.notifier).state =
          RecordingState.recording;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    await _audioService.stop();
    _sonioxService.finalize();
    await _sonioxService.disconnect();
    ref.read(recordingStateProvider.notifier).state =
        RecordingState.postRecording;
  }

  Future<void> _saveSession() async {
    final koreanHistory = ref.read(koreanHistoryProvider);
    final vietnameseHistory = ref.read(vietnameseHistoryProvider);

    if (koreanHistory.isEmpty && vietnameseHistory.isEmpty) return;

    final koreanFull = koreanHistory.join('\n');
    final vietnameseFull = vietnameseHistory.join('\n');

    final session = TranscriptSession(
      createdAt: DateTime.now().toIso8601String(),
      koreanFull: koreanFull,
      vietnameseFull: vietnameseFull,
      koreanPreview: koreanFull.length > AppConstants.previewMaxLength
          ? koreanFull.substring(0, AppConstants.previewMaxLength)
          : koreanFull,
      vietnamesePreview: vietnameseFull.length > AppConstants.previewMaxLength
          ? vietnameseFull.substring(0, AppConstants.previewMaxLength)
          : vietnameseFull,
    );

    try {
      await DatabaseService.instance.insertSession(session);
      ref.invalidate(sessionHistoryProvider);
      _resetState();
      if (mounted) {
        Navigator.pushNamed(context, '/history');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Save failed — try again'),
            action: SnackBarAction(label: 'Retry', onPressed: _saveSession),
          ),
        );
      }
    }
  }

  void _discardSession() {
    _resetState();
  }

  void _resetState() {
    ref.read(recordingStateProvider.notifier).state = RecordingState.idle;
    ref.read(koreanDraftProvider.notifier).state = '';
    ref.read(koreanHistoryProvider.notifier).state = [];
    ref.read(vietnameseDraftProvider.notifier).state = '';
    ref.read(vietnameseHistoryProvider.notifier).state = [];
  }

  @override
  Widget build(BuildContext context) {
    final recordingState = ref.watch(recordingStateProvider);
    final koreanDraft = ref.watch(koreanDraftProvider);
    final koreanHistory = ref.watch(koreanHistoryProvider);
    final vietnameseDraft = ref.watch(vietnameseDraftProvider);
    final vietnameseHistory = ref.watch(vietnameseHistoryProvider);

    final targetLanguage = ref.watch(targetLanguageProvider);

    final isRecordingOrProcessing =
        recordingState == RecordingState.recording ||
            recordingState == RecordingState.processing;
    final isPostRecording = recordingState == RecordingState.postRecording;
    final hasContent =
        koreanHistory.isNotEmpty || vietnameseHistory.isNotEmpty;

    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header: Title + Status
            Padding(
              padding: const EdgeInsets.only(
                left: AppConstants.panelPaddingH,
                top: 17,
                bottom: 12,
                right: AppConstants.panelPaddingH,
              ),
              child: Row(
                children: [
                  const Text(
                    'Silsigan',
                    style: TextStyle(
                      fontSize: AppConstants.titleFontSize,
                      fontWeight: FontWeight.w600,
                      color: AppConstants.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  StatusBar(state: recordingState),
                ],
              ),
            ),

            // Transcription Panel
            Expanded(
              child: TranscriptPanel(
                history: koreanHistory,
                draft: koreanDraft,
                label: 'Transcription',
                showCursor:
                    isRecordingOrProcessing && koreanDraft.isNotEmpty,
                roundedTop: true,
              ),
            ),

            // Divider
            Container(
              height: 5,
              color: AppConstants.dividerColor,
            ),

            // Translation Panel
            Expanded(
              child: TranscriptPanel(
                history: vietnameseHistory,
                draft: vietnameseDraft,
                label: 'Translation',
                showEllipsis: isRecordingOrProcessing && vietnameseDraft.isNotEmpty,
              ),
            ),

            // Bottom Controls Area
            Container(
              color: AppConstants.bgColor,
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                children: [
                  // Language Selector Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: AppConstants.langBoxWidth,
                        height: AppConstants.langBoxHeight,
                        decoration: BoxDecoration(
                          color: AppConstants.panelColor,
                          borderRadius: BorderRadius.circular(
                            AppConstants.langBoxRadius,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: const Text(
                          'Any',
                          style: TextStyle(
                            fontSize: AppConstants.langFontSize,
                            color: AppConstants.textPrimary,
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Icon(
                          Icons.arrow_forward,
                          size: 27,
                          color: AppConstants.textPrimary,
                        ),
                      ),
                      PopupMenuButton<TargetLanguage>(
                        enabled: !isRecordingOrProcessing,
                        onSelected: (lang) {
                          ref.read(targetLanguageProvider.notifier).state = lang;
                        },
                        offset: const Offset(0, -160),
                        itemBuilder: (context) => TargetLanguage.values
                            .map(
                              (lang) => PopupMenuItem<TargetLanguage>(
                                value: lang,
                                child: Row(
                                  children: [
                                    Expanded(child: Text(lang.displayName)),
                                    if (lang == targetLanguage)
                                      const Icon(Icons.check, size: 18),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                        child: Container(
                          width: AppConstants.langBoxWidth,
                          height: AppConstants.langBoxHeight,
                          decoration: BoxDecoration(
                            color: AppConstants.panelColor,
                            borderRadius: BorderRadius.circular(
                              AppConstants.langBoxRadius,
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            targetLanguage.displayName,
                            style: const TextStyle(
                              fontSize: AppConstants.langFontSize,
                              color: AppConstants.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),

                  const SizedBox(height: 32),

                  // Action Buttons Row
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // History Button
                      BottomSideButton(
                        icon: Icons.history,
                        backgroundColor: AppConstants.historyButtonColor,
                        onTap: () =>
                            Navigator.pushNamed(context, '/history'),
                      ),
                      const SizedBox(width: 40),

                      // Mic / Stop Button
                      RecordButton(
                        state: recordingState,
                        onStart: isPostRecording
                            ? () {
                                _discardSession();
                                _startRecording();
                              }
                            : _startRecording,
                        onStop: _stopRecording,
                      ),
                      const SizedBox(width: 40),

                      // Save / Check Button
                      BottomSideButton(
                        icon: Icons.check,
                        backgroundColor: hasContent
                            ? AppConstants.saveButtonActiveColor
                            : AppConstants.saveButtonColor,
                        onTap: (isPostRecording && hasContent)
                            ? _saveSession
                            : null,
                      ),
                    ],
                  ),

                  const SizedBox(height: 30),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
