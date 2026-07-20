import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:webview_master_app/config/app_config.dart';

/// Plays a looping ringtone for incoming order alerts.
///
/// Intended to be instantiated fresh in whichever isolate needs it
/// (main app isolate, FCM background handler isolate, overlay isolate)
/// since each isolate has its own plugin instances.
class RingtonePlayer {
  RingtonePlayer();

  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Timer? _autoStopTimer;

  /// Maximum time the ringtone is allowed to loop before auto-stopping,
  /// in case the user never interacts with the notification/overlay.
  static const Duration _maxRingDuration = Duration(seconds: 60);

  /// Start looping the order ringtone. Safe to call multiple times - a
  /// second call while already playing is a no-op.
  Future<void> play() async {
    if (_isPlaying) {
      debugPrint('🔔 RINGTONE START skipped - already playing');
      return;
    }
    _isPlaying = true;
    debugPrint('🔔 RINGTONE START - loading ${AppConfig.orderRingtoneAsset}');

    try {
      await _player.setReleaseMode(ReleaseMode.loop);
      // stop() may have been called while we were awaiting — abort if so.
      if (!_isPlaying) {
        debugPrint('🔕 RINGTONE START aborted after setReleaseMode - stop() was called');
        return;
      }
      await _player.setAudioContext(AudioContext(
        android: AudioContextAndroid(
          isSpeakerphoneOn: true,
          stayAwake: true,
          contentType: AndroidContentType.sonification,
          usageType: AndroidUsageType.alarm,
          audioFocus: AndroidAudioFocus.gainTransient,
        ),
        iOS: AudioContextIOS(
          category: AVAudioSessionCategory.playback,
          options: const {AVAudioSessionOptions.mixWithOthers},
        ),
      ));
      if (!_isPlaying) {
        debugPrint('🔕 RINGTONE START aborted after setAudioContext - stop() was called');
        return;
      }
      await _player.play(AssetSource(AppConfig.orderRingtoneAsset));
      // If stop() arrived while _player.play() was executing, kill it now.
      if (!_isPlaying) {
        debugPrint('🔕 RINGTONE START aborted after play() - stop() was called, stopping player');
        await _player.stop();
        return;
      }
      debugPrint('🔔 RINGTONE START - playback started successfully (loop)');

      _autoStopTimer?.cancel();
      _autoStopTimer = Timer(_maxRingDuration, () {
        debugPrint('🔕 RINGTONE STOP - auto-stop timer (${_maxRingDuration.inSeconds}s) elapsed');
        stop();
      });
    } catch (e) {
      debugPrint('❌ RingtonePlayer.play error: $e');
      _isPlaying = false;
    }
  }

  /// Stop the ringtone if it is playing. Safe to call even if not playing.
  Future<void> stop() async {
    _autoStopTimer?.cancel();
    _autoStopTimer = null;

    if (!_isPlaying) {
      debugPrint('🔕 RINGTONE STOP skipped - not playing');
      return;
    }
    _isPlaying = false;

    try {
      await _player.stop();
      debugPrint('🔕 RINGTONE STOP - playback stopped successfully');
    } catch (e) {
      debugPrint('❌ RingtonePlayer.stop error: $e');
    }
  }

  /// Release underlying resources. Call when the player is no longer needed.
  Future<void> dispose() async {
    _autoStopTimer?.cancel();
    try {
      await _player.dispose();
    } catch (_) {}
  }
}
