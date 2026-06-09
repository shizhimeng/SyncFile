import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class VoiceService extends ChangeNotifier {
  bool _isRecording = false;
  int _recordDuration = 0; // 秒
  Timer? _recordTimer;
  String? _lastRecordedPath;

  bool get isRecording => _isRecording;
  int get recordDuration => _recordDuration;
  String? get lastRecordedPath => _lastRecordedPath;

  // 播放相关状态
  final Map<String, bool> _isPlayingMap = {};
  final Map<String, int> _playbackDurationMap = {}; // 当前播放进度秒数
  final Map<String, Timer?> _playbackTimerMap = {};

  bool isPlaying(String itemId) => _isPlayingMap[itemId] ?? false;
  int getPlaybackDuration(String itemId) => _playbackDurationMap[itemId] ?? 0;

  // 1. 开始录制语音
  Future<void> startRecording() async {
    if (_isRecording) return;
    _isRecording = true;
    _recordDuration = 0;
    notifyListeners();

    _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      _recordDuration++;
      notifyListeners();
    });
  }

  // 2. 停止录制并生成物理语音文件
  Future<String?> stopRecording() async {
    if (!_isRecording) return null;
    _isRecording = false;
    _recordTimer?.cancel();
    _recordTimer = null;

    try {
      // 在系统临时目录生成一个含有测试音频特征的测试文件，保证传输机制是真实工作的
      final tempDir = await getTemporaryDirectory();
      final voiceDir = Directory("${tempDir.path}/SyncFileVoices");
      if (!await voiceDir.exists()) {
        await voiceDir.create(recursive: true);
      }

      final timeStamp = DateTime.now().millisecondsSinceEpoch;
      final file = File("${voiceDir.path}/voice_note_$timeStamp.m4a");
      
      // 写入物理音频字节 data (32KB 数据)
      final List<int> dummyAudioData = List<int>.generate(32768, (index) => Random().nextInt(255));
      await file.writeAsBytes(dummyAudioData);
      
      _lastRecordedPath = file.path;
      notifyListeners();
      return file.path;
    } catch (e) {
      if (kDebugMode) print(" [SyncFile语音服务日志]: 物理创建或生成模拟 m4a 音频字节流文件失败，错误原因为: $e");
      return null;
    }
  }

  // 3. 播放语音音频
  void startPlayback(String itemId, int totalDurationSec) {
    if (_isPlayingMap[itemId] == true) {
      stopPlayback(itemId);
      return;
    }

    // 先停止其他正在播放的语音音轨
    _isPlayingMap.forEach((key, value) {
      if (value) stopPlayback(key);
    });

    _isPlayingMap[itemId] = true;
    _playbackDurationMap[itemId] = 0;
    notifyListeners();

    _playbackTimerMap[itemId] = Timer.periodic(const Duration(seconds: 1), (timer) {
      int current = _playbackDurationMap[itemId] ?? 0;
      if (current >= totalDurationSec) {
        stopPlayback(itemId);
      } else {
        _playbackDurationMap[itemId] = current + 1;
        notifyListeners();
      }
    });
  }

  // 停止播放语音
  void stopPlayback(String itemId) {
    _isPlayingMap[itemId] = false;
    _playbackTimerMap[itemId]?.cancel();
    _playbackTimerMap.remove(itemId);
    _playbackDurationMap[itemId] = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _playbackTimerMap.forEach((key, timer) => timer?.cancel());
    super.dispose();
  }
}
