import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../providers/recording_provider.dart';
import '../../services/audio_service.dart';
import '../../services/session_relay_service.dart';
import '../../services/soniox_realtime_service.dart';
import '../../services/user_service.dart';
import '../../utils/constants.dart';
import '../widgets/record_button.dart';
import '../widgets/transcript_panel.dart';

class LiveSessionScreen extends StatefulWidget {
  final String sessionId;
  final String partnerLanguage;
  final String myLanguage;
  final String partnerFriendCode;

  const LiveSessionScreen({
    super.key,
    required this.sessionId,
    required this.partnerLanguage,
    required this.myLanguage,
    required this.partnerFriendCode,
  });

  @override
  State<LiveSessionScreen> createState() => _LiveSessionScreenState();
}

class _LiveSessionScreenState extends State<LiveSessionScreen> {
  final AudioService _audioService = AudioService();
  final SonioxRealtimeService _sonioxService = SonioxRealtimeService();
  final SessionRelayService _relayService = SessionRelayService();

  String _myDraft = '';
  List<String> _myHistory = [];
  Timer? _myNewLineTimer;

  String _partnerDraft = '';
  List<String> _partnerHistory = [];
  Timer? _partnerNewLineTimer;

  bool _isRecording = false;
  bool _partnerRecording = false;
  bool _sessionEnded = false;

  bool get _sameLanguage =>
      widget.partnerLanguage == widget.myLanguage;

  @override
  void initState() {
    super.initState();
    _connectRelay();
  }

  @override
  void dispose() {
    _myNewLineTimer?.cancel();
    _partnerNewLineTimer?.cancel();
    _audioService.dispose();
    _sonioxService.disconnect();
    _relayService.disconnect();
    super.dispose();
  }

  Future<void> _connectRelay() async {
    _relayService.onPartnerTranslationDraft = (text) {
      if (mounted) setState(() => _partnerDraft = text);
    };

    _relayService.onPartnerTranslationCompleted = (text) {
      if (text.isEmpty || !mounted) return;
      _partnerNewLineTimer?.cancel();
      setState(() {
        if (_partnerHistory.isEmpty) {
          _partnerHistory = [text];
        } else {
          final updated = List<String>.from(_partnerHistory);
          updated.last = '${updated.last} $text';
          _partnerHistory = updated;
        }
        _partnerDraft = '';
      });
      _partnerNewLineTimer = Timer(
        const Duration(milliseconds: AppConstants.newLinePauseMs),
        () {
          if (mounted) setState(() => _partnerHistory = [..._partnerHistory, '']);
        },
      );
    };

    _relayService.onPartnerRecordingState = (recording) {
      if (mounted) setState(() => _partnerRecording = recording);
    };

    _relayService.onSessionEnded = () => _handleSessionEnd(byPartner: true);
    _relayService.onPartnerDisconnected =
        () => _handleSessionEnd(byPartner: true);

    await _relayService.connect(
      sessionId: widget.sessionId,
      userId: UserService.instance.userId!,
    );
  }

  Future<void> _startRecording() async {
    final status = await Permission.microphone.request();
    if (!status.isGranted) return;

    setState(() => _myDraft = '');

    _sonioxService.onTranscriptionDraft = (draft) {
      if (mounted) setState(() => _myDraft = draft);
    };

    _sonioxService.onTranscriptionCompleted = (transcript) {
      if (transcript.isNotEmpty && mounted) {
        _myNewLineTimer?.cancel();
        setState(() {
          if (_myHistory.isEmpty) {
            _myHistory = [transcript];
          } else {
            final updated = List<String>.from(_myHistory);
            updated.last = '${updated.last} $transcript';
            _myHistory = updated;
          }
          _myDraft = '';
        });
        _myNewLineTimer = Timer(
          const Duration(milliseconds: AppConstants.newLinePauseMs),
          () {
            if (mounted) setState(() => _myHistory = [..._myHistory, '']);
          },
        );

        // Same language: copy transcription as translation for partner
        if (_sameLanguage) {
          _relayService.sendTranslationCompleted(transcript);
        }
      }
    };

    _sonioxService.onTranslationDraft = (draft) {
      _relayService.sendTranslationDraft(draft);
    };

    _sonioxService.onTranslationCompleted = (translation) {
      if (translation.isNotEmpty) {
        _relayService.sendTranslationCompleted(translation);
      }
    };

    _sonioxService.onError = (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Transcription error: $error')),
        );
      }
    };

    _audioService.onAudioChunk = (bytes) {
      _sonioxService.sendAudio(bytes);
    };

    try {
      await _sonioxService.connect(
        targetLanguageCode: widget.partnerLanguage,
        forceTranslation: true,
        languageHint: widget.myLanguage,
      );
      await _audioService.start();
      setState(() => _isRecording = true);
      _relayService.sendRecordingState(true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start recording: $e')),
        );
      }
    }
  }

  Future<void> _stopRecording() async {
    _myNewLineTimer?.cancel();
    await _audioService.stop();
    _sonioxService.finalize();
    await _sonioxService.disconnect();
    setState(() => _isRecording = false);
    _relayService.sendRecordingState(false);
  }

  Future<void> _endSession() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End Session'),
        content: const Text('End this translation session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      _relayService.sendEndSession();
      _handleSessionEnd(byPartner: false);
    }
  }

  void _handleSessionEnd({required bool byPartner}) {
    if (_sessionEnded) return;
    _sessionEnded = true;

    _myNewLineTimer?.cancel();
    _partnerNewLineTimer?.cancel();

    if (_isRecording) {
      _audioService.stop();
      _sonioxService.disconnect();
    }
    _relayService.disconnect();

    if (mounted) {
      if (byPartner) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Partner ended the session')),
        );
      }
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) _endSession();
      },
      child: Scaffold(
        backgroundColor: AppConstants.bgColor,
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
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
                      'Live Session',
                      style: TextStyle(
                        fontSize: AppConstants.titleFontSize,
                        fontWeight: FontWeight.w600,
                        color: AppConstants.textPrimary,
                      ),
                    ),
                    if (_partnerRecording) ...[
                      const SizedBox(width: 10),
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.green,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                    const Spacer(),
                    GestureDetector(
                      onTap: _endSession,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'End',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.red.shade700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // YOU panel
              Expanded(
                child: TranscriptPanel(
                  history: _myHistory,
                  draft: _myDraft,
                  label: 'You',
                  showCursor: _isRecording && _myDraft.isNotEmpty,
                  roundedTop: true,
                ),
              ),

              Container(height: 5, color: AppConstants.dividerColor),

              // PARTNER panel
              Expanded(
                child: TranscriptPanel(
                  history: _partnerHistory,
                  draft: _partnerDraft,
                  label: 'Partner (${widget.partnerFriendCode})',
                  showEllipsis:
                      _partnerRecording && _partnerDraft.isNotEmpty,
                ),
              ),

              // Mic button
              Container(
                color: AppConstants.bgColor,
                padding: const EdgeInsets.symmetric(vertical: 30),
                child: Center(
                  child: RecordButton(
                    state: _isRecording
                        ? RecordingState.recording
                        : RecordingState.idle,
                    onStart: _startRecording,
                    onStop: _stopRecording,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
