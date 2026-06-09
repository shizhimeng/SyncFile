import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '../models/device_info.dart';
import '../models/transfer_item.dart';
import '../theme/app_theme.dart';
import '../services/voice_service.dart';

class ChatHistoryView extends StatefulWidget {
  final DeviceInfo device;
  const ChatHistoryView({super.key, required this.device});

  @override
  State<ChatHistoryView> createState() => _ChatHistoryViewState();
}

class _ChatHistoryViewState extends State<ChatHistoryView> {
  // 用于让声波振幅产生随时间变化的跳跃，还原 HTML 动效
  final List<double> _voiceWaveformHeights = List.filled(15, 6.0);
  Timer? _waveTimer;

  @override
  void initState() {
    super.initState();
    // 监听语音播放服务并驱动声波跳动
    _waveTimer = Timer.periodic(const Duration(milliseconds: 150), (timer) {
      final voice = Provider.of<VoiceService>(context, listen: false);
      // 只有在某个音频正处于播放状态下时，才随机晃动声波条
      bool isPlayingAny = voice.isPlaying(widget.device.id);
                          
      if (isPlayingAny) {
        setState(() {
          for (int i = 0; i < _voiceWaveformHeights.length; i++) {
            _voiceWaveformHeights[i] = 4.0 + Random().nextDouble() * 20.0;
          }
        });
      } else {
        // 静止状态，恢复初始微小声波高度
        setState(() {
          for (int i = 0; i < _voiceWaveformHeights.length; i++) {
            _voiceWaveformHeights[i] = 6.0;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _waveTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    final voiceService = Provider.of<VoiceService>(context);

    // 筛选与本设备的所有往来传输历史
    final peerTransfers = controller.transferHistory
        .where((element) => element.peerId == widget.device.id)
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.device.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
        centerTitle: true,
        backgroundColor: Colors.white,
        elevation: 0.5,
        foregroundColor: AppTheme.onSurface,
      ),
      body: Column(
        children: [
          // 第一排: 客户端主体和任务细节栏
          _buildActiveDeviceBar(),
          
          // 聊天时间线展示区
          Expanded(
            child: ListView(
              reverse: true, // 类似聊天室，底部为最新
              padding: const EdgeInsets.all(16),
              physics: const BouncingScrollPhysics(),
              children: [
                // 1. 最下部最新实时局域网传输的内容
                ...peerTransfers.map((item) => _buildTransferTimelineItem(item, voiceService, controller)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 1. 顶部当前活动设备标签条
  Widget _buildActiveDeviceBar() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppTheme.outlineVariant.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.primary.withOpacity(0.08),
            ),
            child: const Icon(Icons.laptop_windows, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.device.name,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                ),
                Row(
                  children: [
                    const Text(
                      'ACTIVE DEVICE',
                      style: TextStyle(
                        color: AppTheme.primary,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(width: 4, height: 4, decoration: const BoxDecoration(shape: BoxShape.circle, color: AppTheme.secondary)),
                    const SizedBox(width: 4),
                    const Text('连接正常', style: TextStyle(color: AppTheme.secondary, fontSize: 10, fontWeight: FontWeight.bold)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 2. 渲染新发起的局域网套接字实时任务卡片 (支持滑动单条删除)
  Widget _buildTransferTimelineItem(TransferItem item, VoiceService voiceService, AppController controller) {
    final bool isSent = item.direction == 'sent';
    
    return Dismissible(
      key: Key('transfer_timeline_${item.id}'),
      direction: DismissDirection.horizontal,
      background: Container(
        margin: const EdgeInsets.only(bottom: 16.0),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.redAccent),
      ),
      secondaryBackground: Container(
        margin: const EdgeInsets.only(bottom: 16.0),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.1),
          borderRadius: BorderRadius.circular(18),
        ),
        child: const Icon(Icons.delete_outline, color: Colors.redAccent),
      ),
      onDismissed: (_) {
        controller.deleteTransferRecord(item.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已删除传输历史: ${item.name}'),
            duration: const Duration(seconds: 1),
            backgroundColor: AppTheme.onSurface,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Align(
          alignment: isSent ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            constraints: const BoxConstraints(maxWidth: 300),
            decoration: AppTheme.glassCardDecoration(
              color: isSent ? AppTheme.primaryContainer.withOpacity(0.05) : Colors.white,
              radius: 18,
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      item.type == 'text'
                          ? Icons.text_fields
                          : item.type == 'voice'
                              ? Icons.mic
                              : Icons.description,
                      color: AppTheme.primary,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(item.formattedSize, style: const TextStyle(color: AppTheme.outline, fontSize: 10)),
                    _buildTransferStatusLabel(item, voiceService),
                  ],
                )
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTransferStatusLabel(TransferItem item, VoiceService voiceService) {
    if (item.status == 'success') {
      if (item.type == 'voice') {
        final isPlaying = voiceService.isPlaying(item.id);
        return CircleAvatar(
          radius: 12,
          backgroundColor: AppTheme.primary.withOpacity(0.1),
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(isPlaying ? Icons.pause : Icons.play_arrow, size: 14, color: AppTheme.primary),
            onPressed: () => voiceService.startPlayback(item.id, int.tryParse(item.content ?? '5') ?? 5),
          ),
        );
      }
      return const Icon(Icons.check_circle, color: AppTheme.secondary, size: 16);
    }
    if (item.status.startsWith('failed')) {
      return const Icon(Icons.error, color: AppTheme.error, size: 16);
    }
    return const SizedBox(
      width: 12,
      height: 12,
      child: CircularProgressIndicator(strokeWidth: 1.5, color: AppTheme.primary),
    );
  }
}
