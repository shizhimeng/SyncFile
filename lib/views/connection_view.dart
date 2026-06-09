import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:uuid/uuid.dart';
import '../controllers/app_controller.dart';
import '../models/device_info.dart';
import '../models/transfer_item.dart';
import '../theme/app_theme.dart';
import '../services/voice_service.dart';
import 'chat_history_view.dart';
import 'package:permission_handler/permission_handler.dart';

class ConnectionView extends StatefulWidget {
  const ConnectionView({super.key});

  @override
  State<ConnectionView> createState() => _ConnectionViewState();
}

class _ConnectionViewState extends State<ConnectionView>
    with TickerProviderStateMixin {
  int _activeTab = 0; // 0: 已连接, 1: 邀请信息, 2: 历史关系
  bool _isDrawerExpanded = false;
  final List<String> _selectedDevicePids = [];

  // 语音录制辅助状态
  bool _isRecordingPopupVisible = false;

  late AnimationController _dragController;

  void _toggleDrawer(bool expand) {
    setState(() {
      _isDrawerExpanded = expand;
    });
    if (expand) {
      _dragController.forward();
    } else {
      _dragController.reverse();
    }
  }

  @override
  void initState() {
    super.initState();
    _dragController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _dragController.addListener(() {
      setState(() {});
    });
    // 默认勾选所有已连接设备
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = Provider.of<AppController>(context, listen: false);
      setState(() {
        _selectedDevicePids.addAll(
          controller.connectedDevices.map((e) => e.id),
        );
      });
    });
  }

  @override
  void dispose() {
    _dragController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    final voiceService = Provider.of<VoiceService>(context);

    // 同步勾选框数据，防止后台设备掉线后引用失效
    _selectedDevicePids.removeWhere(
      (pid) => !controller.connectedDevices.any((e) => e.id == pid),
    );

    return Scaffold(
      appBar: AppBar(
        title: _buildTabsHeader(),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: Stack(
        children: [
          // 1. 主页面区域
          Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeInOut,
                    switchOutCurve: Curves.easeInOut,
                    transitionBuilder: (Widget child, Animation<double> animation) {
                      final bool isIncoming = child.key == ValueKey(_activeTab == 0 ? 'connected' : 'history');
                      double beginX = _activeTab == 0 ? -1.0 : 1.0;
                      if (!isIncoming) {
                        beginX = -beginX;
                      }
                      return SlideTransition(
                        position: Tween<Offset>(
                          begin: Offset(beginX, 0.0),
                          end: Offset.zero,
                        ).animate(animation),
                        child: child,
                      );
                    },
                    child: _activeTab == 0
                        ? KeyedSubtree(
                            key: const ValueKey('connected'),
                            child: _buildConnectedTab(controller),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('history'),
                            child: _buildHistoryTab(controller),
                          ),
                  ),
                ),
              ),
              // 为底部留出高度
              SizedBox(height: 190 + (_dragController.value * 220)),
            ],
          ),

          // 2. 黑色遮罩层 (抽屉展开时，虚化并加黑背景)
          if (_dragController.value > 0)
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  _toggleDrawer(false);
                },
                child: Container(
                  color: Colors.black.withOpacity(_dragController.value * 0.3),
                ),
              ),
            ),

          // 3. 统一的滑动操作面板：上滑清单，下滑上传类型
          _buildPersistentFooter(controller, voiceService),

          // 4. 录音中拟真弹窗层
          if (_isRecordingPopupVisible)
            _buildRecordingModal(voiceService, controller),
        ],
      ),
    );
  }

  // 1. 自定义精美顶栏 Tab 控制器 (二分段: 已连接与连接历史)
  Widget _buildTabsHeader() {
    return Container(
      width: 220,
      height: 40,
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        children: [
          // 滑动白色背景气泡
          AnimatedPositioned(
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeInOut,
            left: _activeTab == 0 ? 2 : 110,
            top: 2,
            bottom: 2,
            width: 108,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(18),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x0A000000),
                    blurRadius: 4,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
            ),
          ),
          // 前台文字与手势
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _activeTab = 0),
                  child: Container(
                    color: Colors.transparent,
                    alignment: Alignment.center,
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _activeTab == 0
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: _activeTab == 0
                            ? AppTheme.primary
                            : AppTheme.onSurfaceVariant,
                      ),
                      child: const Text('已连接'),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: GestureDetector(
                  onTap: () => setState(() => _activeTab = 1),
                  child: Container(
                    color: Colors.transparent,
                    alignment: Alignment.center,
                    child: AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: _activeTab == 1
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: _activeTab == 1
                            ? AppTheme.primary
                            : AppTheme.onSurfaceVariant,
                      ),
                      child: const Text('连接历史'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // 2. 已连接设备标签页
  Widget _buildConnectedTab(AppController controller) {
    if (controller.connectedDevices.isEmpty) {
      return _buildEmptyState(
        Icons.devices_other,
        '当前没有已连接的设备',
        '在 "扫描" 页发现设备后，点击设备卡片建立局域网连接。',
      );
    }

    final isAllSelected =
        _selectedDevicePids.length == controller.connectedDevices.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 全选操作栏
        Row(
          children: [
            Checkbox(
              value: isAllSelected,
              activeColor: AppTheme.primary,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(4),
              ),
              onChanged: (val) {
                setState(() {
                  _selectedDevicePids.clear();
                  if (val == true) {
                    _selectedDevicePids.addAll(
                      controller.connectedDevices.map((e) => e.id),
                    );
                  }
                });
              },
            ),
            const Text(
              '选择全部',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: controller.connectedDevices.length,
            itemBuilder: (context, index) {
              final device = controller.connectedDevices[index];
              final isChecked = _selectedDevicePids.contains(device.id);

              IconData osIcon = Icons.phone_iphone;
              if (device.os == 'windows') osIcon = Icons.desktop_windows;
              if (device.os == 'macos') osIcon = Icons.laptop_mac;

              return Padding(
                padding: const EdgeInsets.only(bottom: 10.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    leading: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: isChecked,
                          activeColor: AppTheme.primary,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(4),
                          ),
                          onChanged: (val) {
                            setState(() {
                              if (val == true) {
                                _selectedDevicePids.add(device.id);
                              } else {
                                _selectedDevicePids.remove(device.id);
                              }
                            });
                          },
                        ),
                        Container(
                          width: 40,
                          height: 40,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                            boxShadow: [
                              BoxShadow(
                                color: Color(0x06000000),
                                blurRadius: 4,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                          child: device.avatar != null && device.avatar!.isNotEmpty
                              ? ClipOval(
                                  child: Image.memory(
                                    base64Decode(device.avatar!),
                                    fit: BoxFit.cover,
                                    gaplessPlayback: true,
                                    errorBuilder: (context, error, stackTrace) => Icon(
                                      osIcon,
                                      color: AppTheme.primary,
                                      size: 20,
                                    ),
                                  ),
                                )
                              : Icon(
                                  osIcon,
                                  color: AppTheme.primary,
                                  size: 20,
                                ),
                        ),
                      ],
                    ),
                    title: Text(
                      device.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    subtitle: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'PID: ${device.id}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: 'JetBrains Mono',
                              color: AppTheme.outline,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          width: 4,
                          height: 4,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.secondary,
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          '在线',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.secondary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton(
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('断开连接'),
                                content: Text('您确定要断开与设备 "${device.name}" 的连接通道吗？'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text(
                                      '取消',
                                      style: TextStyle(color: AppTheme.outline),
                                    ),
                                  ),
                                  ElevatedButton(
                                    onPressed: () {
                                      controller.disconnectDevice(device.id);
                                      Navigator.pop(context);
                                    },
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.red,
                                      foregroundColor: Colors.white,
                                    ),
                                    child: const Text('断开'),
                                  ),
                                ],
                              ),
                            );
                          },
                          child: const Text(
                            '断开',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const Icon(
                          Icons.chevron_right,
                          color: AppTheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    onTap: () {
                      // 点击直接进入该设备的历史往来聊天流
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => ChatHistoryView(device: device),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // 3. 邀请信息标签页
  Widget _buildInvitationsTab(AppController controller) {
    if (controller.incomingInvitations.isEmpty) {
      return _buildEmptyState(
        Icons.mail_outline,
        '当前无入站连接邀请',
        '当局域网其它端尝试与您共享数据时，握手邀请信息会在此处呈现。',
      );
    }

    return ListView.builder(
      itemCount: controller.incomingInvitations.length,
      itemBuilder: (context, index) {
        final invite = controller.incomingInvitations[index];
        final senderPid = invite['senderPid'] ?? '未知 PID';
        final senderName = invite['senderName'] ?? '其它客户端';
        final List<dynamic> items = invite['items'] ?? [];

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: AppTheme.glassCardDecoration(color: Colors.white),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppTheme.primary.withOpacity(0.1),
                    child: const Icon(
                      Icons.tablet_android,
                      color: AppTheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          senderName,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          'PID: $senderPid',
                          style: const TextStyle(
                            color: AppTheme.outline,
                            fontSize: 11,
                            fontFamily: 'JetBrains Mono',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '准备与您共享 ${items.length} 个文件：\n- ${items.isNotEmpty ? items.first['name'] : "未知文件"}',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => controller.acceptInvitation(senderPid),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: const Text('接受'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => controller.rejectInvitation(senderPid),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.outlineVariant),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        foregroundColor: AppTheme.onSurface,
                      ),
                      child: const Text('拒绝'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // 【新增：连接历史标签页】
  Widget _buildHistoryTab(AppController controller) {
    final history = controller.connectedDevicesHistory;
    if (history.isEmpty) {
      return _buildEmptyState(
        Icons.history_toggle_off,
        '无连接历史记录',
        '曾经成功与您建立过局域网直连的设备关系链会在此处沉淀记录。',
      );
    }

    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: history.length,
      itemBuilder: (context, index) {
        final item = history[index];
        final String peerPid = item['id'] ?? '';
        final String peerName = item['name'] ?? '未知设备';
        final String peerOs = item['os'] ?? 'windows';
        final String? peerAvatar = item['avatar'];
        final bool isCurrentlyConnected = item['is_connected'] == 1;
        final String lastTimeStr = item['last_connected_time'] ?? '';

        String formattedTime = '';
        if (lastTimeStr.isNotEmpty) {
          try {
            final dt = DateTime.parse(lastTimeStr);
            formattedTime = '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
          } catch (_) {
            formattedTime = lastTimeStr;
          }
        }

        IconData osIcon = Icons.phone_iphone;
        if (peerOs == 'windows') osIcon = Icons.desktop_windows;
        if (peerOs == 'macos') osIcon = Icons.laptop_mac;
        if (peerOs == 'android') osIcon = Icons.phone_android;

        return Dismissible(
          key: Key('history_$peerPid'),
          direction: DismissDirection.endToStart,
          background: Container(
            margin: const EdgeInsets.only(bottom: 12.0, top: 4.0),
            padding: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: Colors.redAccent.shade200,
              borderRadius: BorderRadius.circular(16),
            ),
            alignment: Alignment.centerRight,
            child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
          ),
          onDismissed: (_) {
            controller.deleteConnectedDeviceRecord(peerPid);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('已删除设备 $peerName 的连接历史关系')),
            );
          },
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10.0),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
              ),
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                leading: Container(
                  width: 44,
                  height: 44,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [BoxShadow(color: Color(0x06000000), blurRadius: 4, offset: Offset(0, 2))],
                  ),
                  child: peerAvatar != null && peerAvatar.isNotEmpty
                      ? ClipOval(child: Image.memory(base64Decode(peerAvatar), fit: BoxFit.cover, gaplessPlayback: true))
                      : Icon(osIcon, color: AppTheme.primary, size: 22),
                ),
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        peerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isCurrentlyConnected ? AppTheme.secondary.withOpacity(0.1) : Colors.grey.shade200,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        isCurrentlyConnected ? '稳定连接中' : '已断开',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: isCurrentlyConnected ? AppTheme.secondary : Colors.grey.shade600,
                        ),
                      ),
                    ),
                  ],
                ),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 4),
                    Text(
                      'PID: $peerPid',
                      style: const TextStyle(fontSize: 10, fontFamily: 'JetBrains Mono', color: AppTheme.outline),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '上次连接时间: $formattedTime',
                      style: const TextStyle(fontSize: 11, color: AppTheme.onSurfaceVariant),
                    ),
                  ],
                ),
                trailing: isCurrentlyConnected
                    ? const Icon(Icons.check, color: AppTheme.secondary)
                    : IconButton(
                        icon: const Icon(Icons.link, color: AppTheme.primary),
                        onPressed: () async {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('正在尝试重新发起与 $peerName 的局域网握手...')),
                          );
                          int devIdx = controller.discoveredDevices.indexWhere((element) => element.id == peerPid);
                          if (devIdx != -1) {
                            DeviceInfo device = controller.discoveredDevices[devIdx];
                            bool success = await controller.requestConnection(device);
                            if (success) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('重新发起连接握手成功！'), backgroundColor: AppTheme.secondary),
                              );
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('重新连接失败，对方可能未开启雷达或已切断 Wi-Fi。'), backgroundColor: Colors.red),
                              );
                            }
                          } else {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('重新连接失败，目标设备在局域网内不在线（未发出广播）。'), backgroundColor: Colors.red),
                            );
                          }
                        },
                        tooltip: '重新发起连接',
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  // 4. 空列表占位
  Widget _buildEmptyState(IconData icon, String title, String subtitle) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 56, color: AppTheme.outline.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32.0),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.onSurfaceVariant,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // 待发送队列：文本展示气泡
  Widget _buildStagedTextBubble(TransferItem item, AppController controller) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.outlineVariant.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.text_fields, color: AppTheme.primary, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.edit, size: 16, color: AppTheme.primary),
            onPressed: () {
              final textEdit = TextEditingController(
                text: item.content ?? item.name,
              );
              showDialog(
                context: context,
                builder: (context) {
                  return AlertDialog(
                    title: const Text('修改待发送的文本'),
                    content: TextField(
                      controller: textEdit,
                      maxLines: 4,
                      decoration: const InputDecoration(
                        hintText: '输入新文本...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text(
                          '取消',
                          style: TextStyle(color: AppTheme.outline),
                        ),
                      ),
                      ElevatedButton(
                        onPressed: () {
                          if (textEdit.text.trim().isNotEmpty) {
                            controller.updatePendingSendText(
                              item.id,
                              textEdit.text.trim(),
                            );
                          }
                          Navigator.pop(context);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('确认'),
                      ),
                    ],
                  );
                },
              );
            },
          ),
          const SizedBox(width: 8),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.close, size: 16, color: AppTheme.outline),
            onPressed: () => controller.removeFromSendQueue(item.id),
          ),
        ],
      ),
    );
  }

  // 待发送队列：小文件或语音徽章
  Widget _buildStagedBadge(TransferItem item, AppController controller) {
    final bool isVoice = item.type == 'voice';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: isVoice
            ? AppTheme.primary.withOpacity(0.1)
            : AppTheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isVoice
              ? AppTheme.primary.withOpacity(0.3)
              : AppTheme.outlineVariant.withOpacity(0.5),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isVoice ? Icons.play_arrow : Icons.description,
            color: isVoice ? AppTheme.primary : AppTheme.onSurfaceVariant,
            size: 14,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Container(
              constraints: const BoxConstraints(maxWidth: 100),
              child: Text(
                item.name,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: isVoice ? AppTheme.primary : AppTheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => controller.removeFromSendQueue(item.id),
            child: Icon(
              Icons.close,
              size: 12,
              color: isVoice ? AppTheme.primary : AppTheme.outline,
            ),
          ),
        ],
      ),
    );
  }

  // 6. 工具底座栏 (上滑显示待发送清单，下滑显示上传文件类型)
  Widget _buildPersistentFooter(
    AppController controller,
    VoiceService voiceService,
  ) {
    final fileCount = controller.pendingSendQueue
        .where((e) => e.type == 'file')
        .length;
    final imageCount = controller.pendingSendQueue
        .where((e) => e.type == 'image')
        .length;
    final voiceCount = controller.pendingSendQueue
        .where((e) => e.type == 'voice')
        .length;
    final textCount = controller.pendingSendQueue
        .where((e) => e.type == 'text')
        .length;
    final totalCount = controller.pendingSendQueue.length;
    final panelHeight = 190.0 + (_dragController.value * 220.0);

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        height: panelHeight,
        decoration: BoxDecoration(
          color: AppTheme.surface.withOpacity(0.95),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          border: Border(
            top: BorderSide(color: AppTheme.outlineVariant.withOpacity(0.4)),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 20,
              offset: Offset(0, -6),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Stack(
          children: [
            IgnorePointer(
              ignoring: _dragController.value < 0.5,
              child: Opacity(
                opacity: _dragController.value,
                child: _buildPendingSendPanel(controller, totalCount),
              ),
            ),
            IgnorePointer(
              ignoring: _dragController.value > 0.5,
              child: Opacity(
                opacity: 1.0 - _dragController.value,
                child: _buildUploadTypePanel(
                  controller: controller,
                  voiceService: voiceService,
                  fileCount: fileCount,
                  imageCount: imageCount,
                  voiceCount: voiceCount,
                  textCount: textCount,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingSendPanel(AppController controller, int totalCount) {
    return Column(
      children: [
        Expanded(
          child: controller.pendingSendQueue.isEmpty
              ? Center(
                  child: Text(
                    '无待发送内容',
                    style: TextStyle(
                      color: AppTheme.outline.withOpacity(0.6),
                      fontSize: 13,
                    ),
                  ),
                )
              : Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          '待发送清单',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        TextButton(
                          onPressed: () => controller.clearSendQueue(),
                          child: const Text(
                            '清空',
                            style: TextStyle(color: AppTheme.outline),
                          ),
                        ),
                      ],
                    ),
                    Expanded(
                      child: ListView(
                        physics: const BouncingScrollPhysics(),
                        children: [
                          ...controller.pendingSendQueue
                              .where((e) => e.type == 'text')
                              .map((item) {
                                return _buildStagedTextBubble(item, controller);
                              }),
                          if (controller.pendingSendQueue.any(
                            (e) => e.type != 'text',
                          )) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: controller.pendingSendQueue
                                  .where((e) => e.type != 'text')
                                  .map((item) {
                                    return _buildStagedBadge(item, controller);
                                  })
                                  .toList(),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        if (_selectedDevicePids.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10.0),
            child: Row(
              children: [
                const Icon(Icons.devices, color: AppTheme.secondary, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '目标设备: ${_selectedDevicePids.length} 台 (${_getSelectedDeviceNames(controller)})',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        Row(
          children: [
            Expanded(
              flex: 4,
              child: _buildSendQueueButton(controller, totalCount),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 1,
              child: InkWell(
                onTap: () => _toggleDrawer(false),
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceContainerLow,
                    border: Border.all(
                      color: AppTheme.outlineVariant.withOpacity(0.5),
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: const Text(
                    '返回',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: AppTheme.outline,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildUploadTypePanel({
    required AppController controller,
    required VoiceService voiceService,
    required int fileCount,
    required int imageCount,
    required int voiceCount,
    required int textCount,
  }) {
    return SingleChildScrollView(
      physics: const ClampingScrollPhysics(),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildFooterAction(
                  icon: Icons.description,
                  label: '文件',
                  badgeCount: fileCount,
                  onTap: () => _pickLocalFiles(controller),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildFooterAction(
                  icon: Icons.image,
                  label: '图片',
                  badgeCount: imageCount,
                  onTap: () => _pickLocalImages(controller),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildFooterAction(
                  icon: Icons.mic,
                  label: '语音',
                  badgeCount: voiceCount,
                  onTap: () {
                    setState(() {
                      _isRecordingPopupVisible = true;
                    });
                    voiceService.startRecording();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildFooterAction(
                  icon: Icons.text_fields,
                  label: '文本',
                  badgeCount: textCount,
                  onTap: () => _promptTextInput(controller),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: _buildSendQueueButton(
                  controller,
                  controller.pendingSendQueue.length,
                  compactLabel: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: InkWell(
                  onTap: () => _toggleDrawer(true),
                  borderRadius: BorderRadius.circular(14),
                  child: Container(
                    height: 52,
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceContainerLow,
                      border: Border.all(
                        color: AppTheme.outlineVariant.withOpacity(0.5),
                      ),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '查看发送清单',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSendQueueButton(
    AppController controller,
    int totalCount, {
    bool compactLabel = false,
  }) {
    final bool canSend = totalCount > 0 && _selectedDevicePids.isNotEmpty;
    return InkWell(
      onTap: canSend ? () => _performQueueSending(controller) : null,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: double.infinity,
        height: compactLabel ? 52 : 48,
        decoration: BoxDecoration(
          gradient: canSend ? AppTheme.primaryGradient : null,
          color: canSend ? null : AppTheme.outlineVariant.withOpacity(0.4),
          borderRadius: BorderRadius.circular(14),
          boxShadow: canSend
              ? [
                  BoxShadow(
                    color: AppTheme.primary.withOpacity(0.3),
                    blurRadius: compactLabel ? 16 : 12,
                    offset: Offset(0, compactLabel ? 6 : 4),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          compactLabel
              ? '发送'
              : totalCount == 0
              ? '待发送清单为空'
              : _selectedDevicePids.isEmpty
              ? '请选择接收设备'
              : '确认发送 ($totalCount 项内容)',
          style: TextStyle(
            color: canSend ? Colors.white : AppTheme.outline,
            fontWeight: FontWeight.bold,
            fontSize: compactLabel ? 16 : 15,
            letterSpacing: compactLabel ? 2 : 0,
          ),
        ),
      ),
    );
  }

  // 获取选中设备名称拼接串
  String _getSelectedDeviceNames(AppController controller) {
    List<String> names = [];
    for (var pid in _selectedDevicePids) {
      int idx = controller.connectedDevices.indexWhere(
        (element) => element.id == pid,
      );
      if (idx != -1) {
        names.add(controller.connectedDevices[idx].name);
      }
    }
    return names.join(', ');
  }

  // 工具底栏子按钮组件
  Widget _buildFooterAction({
    required IconData icon,
    required String label,
    int badgeCount = 0,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.outlineVariant.withOpacity(0.2)),
        ),
        child: Column(
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(icon, color: AppTheme.primary, size: 24),
                if (badgeCount > 0)
                  Positioned(
                    top: -6,
                    right: -6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 2,
                      ),
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppTheme.primary,
                      ),
                      child: Text(
                        '$badgeCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: AppTheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 7. 语音录制模态弹窗面板 (高质感脉冲设计)
  Widget _buildRecordingModal(
    VoiceService voiceService,
    AppController controller,
  ) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.5),
        alignment: Alignment.center,
        child: Container(
          width: 260,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '正在录音...',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 24),

              // 录音动画扩散波纹
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.primary.withOpacity(0.1),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.mic, color: AppTheme.primary, size: 36),
              ),
              const SizedBox(height: 16),

              // 录制计时器
              Text(
                '00:${voiceService.recordDuration.toString().padLeft(2, '0')}',
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
              const SizedBox(height: 24),

              // 停止/保存录音
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () async {
                        String? p = await voiceService.stopRecording();
                        if (p != null) {
                          // 生成并加入队列
                          final dur = voiceService.recordDuration;
                          controller.addToSendQueue(
                            TransferItem(
                              id: const Uuid().v4(),
                              name: '语音备忘录_$dur".m4a',
                              size: 32768, // 32KB
                              type: 'voice',
                              path: p,
                              content: '$dur', // 音频时长保存在 content 中
                              direction: 'sent',
                              timestamp: DateTime.now(),
                              peerId: '',
                              peerName: '',
                            ),
                          );
                        }
                        setState(() {
                          _isRecordingPopupVisible = false;
                        });
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      child: const Text('完成'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        voiceService.stopRecording(); // 仅丢弃
                        setState(() {
                          _isRecordingPopupVisible = false;
                        });
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.outlineVariant),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        foregroundColor: Colors.red,
                      ),
                      child: const Text('取消'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ================= 动作执行 =================

  // 1. 调用 OS 选择文件并推入暂存队列
  void _pickLocalFiles(AppController controller) async {
    if (Platform.isAndroid) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('发送文件失败：需要授权“管理所有文件权限”才能读取外部存储文件。'), backgroundColor: Colors.red),
          );
          return;
        }
      }
    }

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
      );

      if (result != null) {
        for (var file in result.files) {
          if (file.path != null) {
            bool isImg = [
              'jpg',
              'jpeg',
              'png',
              'gif',
              'webp',
            ].contains(file.extension?.toLowerCase());
            controller.addToSendQueue(
              TransferItem(
                id: const Uuid().v4(),
                name: file.name,
                size: file.size,
                type: isImg ? 'image' : 'file',
                path: file.path,
                direction: 'sent',
                timestamp: DateTime.now(),
                peerId: '',
                peerName: '',
              ),
            );
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文件选择出错: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // 调用 OS 选择图片并推入暂存队列
  void _pickLocalImages(AppController controller) async {
    if (Platform.isAndroid) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('发送图片失败：需要授权“管理所有文件权限”才能读取外部图片。'), backgroundColor: Colors.red),
          );
          return;
        }
      }
    }

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: FileType.image,
      );

      if (result != null) {
        for (var file in result.files) {
          if (file.path != null) {
            controller.addToSendQueue(
              TransferItem(
                id: const Uuid().v4(),
                name: file.name,
                size: file.size,
                type: 'image',
                path: file.path,
                direction: 'sent',
                timestamp: DateTime.now(),
                peerId: '',
                peerName: '',
              ),
            );
          }
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('图片选择出错: $e'), backgroundColor: Colors.red),
      );
    }
  }

  // 2. 弹出文字框录入文本
  void _promptTextInput(AppController controller) {
    final textEdit = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('输入待发送的文本'),
          content: TextField(
            controller: textEdit,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: '在这里输入或粘贴你想发送的信息...',
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                '取消',
                style: TextStyle(color: AppTheme.outline),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                if (textEdit.text.trim().isNotEmpty) {
                  controller.addToSendQueue(
                    TransferItem(
                      id: const Uuid().v4(),
                      name: textEdit.text.trim(),
                      size: textEdit.text.trim().length,
                      type: 'text',
                      content: textEdit.text.trim(),
                      direction: 'sent',
                      timestamp: DateTime.now(),
                      peerId: '',
                      peerName: '',
                    ),
                  );
                }
                Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('暂存'),
            ),
          ],
        );
      },
    );
  }

  // 3. 执行发送
  void _performQueueSending(AppController controller) async {
    if (controller.pendingSendQueue.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('发送暂存队列为空，请先添加文件或文本。')));
      return;
    }

    if (_selectedDevicePids.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先勾选上方需要发送的目标设备！')));
      return;
    }

    // 如果待发送队列里包含需要物理 IO 读取的文件或图片，必须通过 Android 管理所有文件权限检测
    final hasPhysicalFiles = controller.pendingSendQueue.any((e) => e.type == 'file' || e.type == 'image');
    if (Platform.isAndroid && hasPhysicalFiles) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
        if (!status.isGranted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('传输终止：发送物理文件必须授权“管理所有文件权限”。'), backgroundColor: Colors.red),
          );
          return;
        }
      }
    }

    // 执行群发
    controller.sendQueueToDevices(_selectedDevicePids);

    // 收回抽屉并弹窗提示
    _toggleDrawer(false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已向选中的 ${_selectedDevicePids.length} 个设备发起传输任务'),
        backgroundColor: AppTheme.secondary,
      ),
    );
  }
}
