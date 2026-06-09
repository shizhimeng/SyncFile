import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '../models/transfer_item.dart';
import '../theme/app_theme.dart';
import '../services/voice_service.dart';

class TransferView extends StatefulWidget {
  const TransferView({super.key});

  @override
  State<TransferView> createState() => _TransferViewState();
}

class _TransferViewState extends State<TransferView> with SingleTickerProviderStateMixin {
  int _activeTab = 0; // 0: 我发送的, 1: 我收到的
  int _sentSubTab = 0; // 0: 发送成功, 1: 发送中, 2: 发送失败
  int _lastSentSubTab = 0; // 记录上一次的发送子 tab 索引
  int _receivedSubTab = 0; // 0: 已完成, 1: 正在传输, 2: 传输失败
  int _lastReceivedSubTab = 0; // 记录上一次的子 tab 索引，用于决定滑动方向
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    // 进度条微呼吸脉冲控制器
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);
    final voiceService = Provider.of<VoiceService>(context);

    // 过滤发送与接收历史
    final sentItems = controller.transferHistory.where((element) => element.direction == 'sent').toList();
    final receivedItems = controller.transferHistory.where((element) => element.direction == 'received').toList();

    return Scaffold(
      appBar: AppBar(
        title: _buildTabsHeader(),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined, color: AppTheme.outline),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('清空历史记录'),
                  content: const Text('确定要清空所有的传输历史记录吗？此操作不可恢复。'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () {
                        controller.clearAllTransferHistory();
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已清空所有传输历史记录')),
                        );
                      },
                      child: const Text('确定', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
            },
            tooltip: '清空所有历史',
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (Widget child, Animation<double> animation) {
            final bool isIncoming = child.key == ValueKey(_activeTab == 0 ? 'sent' : 'received');
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
                  key: const ValueKey('sent'),
                  child: _buildSentItemsTab(sentItems, controller, voiceService),
                )
              : KeyedSubtree(
                  key: const ValueKey('received'),
                  child: _buildReceivedItemsTab(receivedItems, controller, voiceService),
                ),
        ),
      ),
    );
  }

  // 顶层双标签切换
  Widget _buildTabsHeader() {
    return Container(
      width: 240,
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
            left: _activeTab == 0 ? 2 : 120,
            top: 2,
            bottom: 2,
            width: 118,
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
                        fontSize: 13,
                        fontWeight: _activeTab == 0 ? FontWeight.bold : FontWeight.normal,
                        color: _activeTab == 0 ? AppTheme.primary : AppTheme.onSurfaceVariant,
                      ),
                      child: const Text('我发送的'),
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
                        fontSize: 13,
                        fontWeight: _activeTab == 1 ? FontWeight.bold : FontWeight.normal,
                        color: _activeTab == 1 ? AppTheme.primary : AppTheme.onSurfaceVariant,
                      ),
                      child: const Text('我收到的'),
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

  // 我发送的分栏 Tab 面板
  Widget _buildSentItemsTab(
    List<TransferItem> sentItems,
    AppController controller,
    VoiceService voiceService,
  ) {
    // 过滤任务类型
    final completedItems = sentItems.where((element) => element.status == 'success').toList();
    final activeItems = sentItems.where((element) => element.status == 'transferring' || element.status == 'waiting' || element.status == 'queued').toList();
    final failedItems = sentItems.where((element) => element.status.startsWith('failed') || element.status == 'rejected').toList();

    return Column(
      children: [
        // 子 Tab 选择滑块区 (带平滑滑动背景胶囊)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double width = constraints.maxWidth;
              final double tabWidth = (width - 4) / 3;
              return Container(
                height: 38,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(19),
                ),
                child: Stack(
                  children: [
                    // 滑动背景胶囊
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOut,
                      left: 2 + _sentSubTab * tabWidth,
                      top: 2,
                      bottom: 2,
                      width: tabWidth,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(17),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x10000000),
                              blurRadius: 4,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 前台按钮
                    Row(
                      children: [
                        _buildSentSubTabButton(0, '发送成功', completedItems.length),
                        _buildSentSubTabButton(1, '发送中', activeItems.length),
                        _buildSentSubTabButton(2, '发送失败', failedItems.length),
                      ],
                    ),
                  ],
                ),
              );
            }
          ),
        ),
        const SizedBox(height: 8),
        // Tab 列表切换区 (带平滑缓慢切换动效)
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            transitionBuilder: (Widget child, Animation<double> animation) {
              final String childKey = (child.key as ValueKey<String>).value;
              final int childIndex = childKey == 'completed' ? 0 : (childKey == 'active' ? 1 : 2);
              
              final bool isAscending = _sentSubTab >= _lastSentSubTab;
              final bool isIncoming = childIndex == _sentSubTab;
              
              double beginX = isAscending ? 1.0 : -1.0;
              if (!isIncoming) {
                beginX = -beginX;
              }
              
              return SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(beginX, 0.0),
                  end: Offset.zero,
                ).animate(animation),
                child: FadeTransition(
                  opacity: animation,
                  child: child,
                ),
              );
            },
            child: _sentSubTab == 0
                ? KeyedSubtree(
                    key: const ValueKey('completed'),
                    child: _buildSubTabList(completedItems, '当前没有发送成功的传输记录', controller, voiceService),
                  )
                : _sentSubTab == 1
                    ? KeyedSubtree(
                        key: const ValueKey('active'),
                        child: _buildSubTabList(activeItems, '当前没有正在发送的任务', controller, voiceService),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('failed'),
                        child: _buildSubTabList(failedItems, '当前没有发送失败的传输记录', controller, voiceService),
                      ),
          ),
        ),
      ],
    );
  }

  // 构建发送子 Tab 按钮
  Widget _buildSentSubTabButton(int index, String label, int count) {
    final bool isActive = _sentSubTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_sentSubTab != index) {
            setState(() {
              _lastSentSubTab = _sentSubTab;
              _sentSubTab = index;
            });
          }
        },
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOut,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: isActive ? Colors.white : AppTheme.onSurfaceVariant,
                ),
                child: Text(label),
              ),
              if (count > 0) ...[
                const SizedBox(width: 4),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isActive ? Colors.white.withOpacity(0.25) : AppTheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isActive ? Colors.white : AppTheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 构建高保真传输卡片 (支持折叠与状态渲染)
  Widget _buildTransferCard(TransferItem item, AppController controller, VoiceService voiceService) {
    final bool isSuccess = item.status == 'success';
    final bool isFailed = item.status.startsWith('failed');
    final bool isWaiting = item.status == 'waiting';
    final bool isTransferring = item.status == 'transferring';

    // 默认图标配对
    IconData fileIcon = Icons.description;
    Color iconBgColor = AppTheme.primary.withOpacity(0.1);
    Color iconColor = AppTheme.primary;

    if (item.type == 'image') {
      fileIcon = Icons.image;
      iconBgColor = const Color(0xFFE2DFFF).withOpacity(0.4);
      iconColor = const Color(0xFF4C4ACA);
    } else if (item.type == 'voice') {
      fileIcon = Icons.mic;
      iconBgColor = AppTheme.secondaryContainer.withOpacity(0.2);
      iconColor = AppTheme.secondary;
    } else if (item.type == 'text') {
      fileIcon = Icons.text_fields;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0, top: 4.0),
      child: Container(
        decoration: AppTheme.glassCardDecoration(color: Colors.white),
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // 第一排: 客户端主体和任务细节
            Row(
              children: [
                // 专属大头像圈
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBgColor,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(fileIcon, color: iconColor, size: 20),
                ),
                
                const SizedBox(width: 12),
                
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${item.direction == 'sent' ? '发往' : '来自'} ${item.peerName} • ${item.formattedSize}',
                        style: const TextStyle(color: AppTheme.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                
                // 右侧状态文本或按纽
                _buildActionOrStatus(item, controller, voiceService),
              ],
            ),

                // 第二排: 如果是传输中，展示脉冲式的进度条和速度指标
                if (isTransferring) ...[
                  const SizedBox(height: 12),
                  Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            '传输中 • ${item.speed.toStringAsFixed(1)} MB/s',
                            style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.bold),
                          ),
                          Text(
                            '${(item.progress * 100).toInt()}%',
                            style: const TextStyle(fontSize: 11, color: AppTheme.primary, fontWeight: FontWeight.bold),
                          )
                        ],
                      ),
                      const SizedBox(height: 6),
                      FadeTransition(
                        // 实现 CSS 中的 progress-pulse 闪烁发光呼吸
                        opacity: _pulseController.drive(Tween(begin: 0.6, end: 1.0)),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: LinearProgressIndicator(
                            value: item.progress,
                            backgroundColor: AppTheme.surfaceContainerHighest,
                            color: AppTheme.primary,
                            minHeight: 6,
                          ),
                        ),
                      )
                    ],
                  )
                ],

                // 队列排队等待
                if (isWaiting) ...[
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('正在等待对方接受握手连接...', style: TextStyle(fontSize: 11, color: AppTheme.outline)),
                      Container(
                        width: 12,
                        height: 12,
                        margin: const EdgeInsets.only(right: 6),
                        child: const CircularProgressIndicator(strokeWidth: 2, color: AppTheme.outline),
                      )
                    ],
                  )
            ]
          ],
        ),
      ),
    );
  }

  // 右侧状态栏解析器
  Widget _buildActionOrStatus(TransferItem item, AppController controller, VoiceService voiceService) {
    if (item.status == 'transferring' || item.status == 'waiting') {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            icon: const Icon(Icons.stop_circle_outlined, color: Colors.redAccent, size: 20),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('终止传输'),
                  content: const Text('确定要终止当前的传输吗？'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消'),
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent),
                      onPressed: () {
                        controller.cancelTransfer(item.id, item.peerId);
                        Navigator.pop(context);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('已终止传输')),
                        );
                      },
                      child: const Text('确定', style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
            },
            tooltip: '终止传输',
          ),
        ],
      );
    }

    if (item.status == 'success') {
      if (item.type == 'text') {
        return ElevatedButton(
          onPressed: () => _viewTextContentDialog(item.name),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.surfaceContainer,
            foregroundColor: AppTheme.primary,
            elevation: 0,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            minimumSize: Size.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: const Text('查看', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
        );
      }
      
      if (item.type == 'voice' && item.direction == 'received') {
        final isPlaying = voiceService.isPlaying(item.id);
        return CircleAvatar(
          radius: 16,
          backgroundColor: AppTheme.surfaceContainerHigh,
          child: IconButton(
            padding: EdgeInsets.zero,
            icon: Icon(
              isPlaying ? Icons.pause : Icons.play_arrow,
              color: AppTheme.primary,
              size: 18,
            ),
            onPressed: () {
              // 触发语音播放
              int sec = int.tryParse(item.content ?? '10') ?? 10;
              voiceService.startPlayback(item.id, sec);
            },
          ),
        );
      }

      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, color: AppTheme.secondary, size: 18),
          SizedBox(width: 4),
          Text(
            '成功',
            style: TextStyle(color: AppTheme.secondary, fontWeight: FontWeight.bold, fontSize: 12),
          )
        ],
      );
    }

    if (item.status == 'rejected') {
      return const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.block, color: Colors.orange, size: 16),
          SizedBox(width: 6),
          Text('对方拒绝', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      );
    }

    if (item.status.startsWith('failed')) {
      final String reason = item.status.contains(':') ? item.status.split(':').last : '失败';
      final bool isSent = item.direction == 'sent';
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isSent) ...[
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              icon: const Icon(Icons.refresh, color: AppTheme.primary, size: 20),
              onPressed: () => controller.retryTransfer(item),
              tooltip: '重试此任务',
            ),
            const SizedBox(width: 6),
          ],
          Text(reason, style: TextStyle(color: Colors.amber[700], fontWeight: FontWeight.bold, fontSize: 12)),
        ],
      );
    }

    if (item.status == 'queued') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(color: AppTheme.surfaceContainer, borderRadius: BorderRadius.circular(10)),
        child: const Text('队列中', style: TextStyle(fontSize: 10, color: AppTheme.onSurfaceVariant)),
      );
    }

    return const SizedBox();
  }

  // 我收到的分栏 Tab 面板
  Widget _buildReceivedItemsTab(
    List<TransferItem> receivedItems,
    AppController controller,
    VoiceService voiceService,
  ) {
    // 过滤任务类型
    final completedItems = receivedItems.where((element) => element.status == 'success').toList();
    final activeItems = receivedItems.where((element) => element.status == 'transferring' || element.status == 'waiting' || element.status == 'queued').toList();
    final failedItems = receivedItems.where((element) => element.status.startsWith('failed') || element.status == 'rejected').toList();

    return Column(
      children: [
        // 子 Tab 选择滑块区 (带平滑滑动背景胶囊)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8.0),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final double width = constraints.maxWidth;
              final double tabWidth = (width - 4) / 3;
              return Container(
                height: 38,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(19),
                ),
                child: Stack(
                  children: [
                    // 滑动背景胶囊
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOut,
                      left: 2 + _receivedSubTab * tabWidth,
                      top: 2,
                      bottom: 2,
                      width: tabWidth,
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.primary,
                          borderRadius: BorderRadius.circular(17),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x10000000),
                              blurRadius: 4,
                              offset: Offset(0, 2),
                            ),
                          ],
                        ),
                      ),
                    ),
                    // 前台按钮
                    Row(
                      children: [
                        _buildSubTabButton(0, '已完成', completedItems.length),
                        _buildSubTabButton(1, '正在传输', activeItems.length),
                        _buildSubTabButton(2, '传输失败', failedItems.length),
                      ],
                    ),
                  ],
                ),
              );
            }
          ),
        ),
        const SizedBox(height: 8),
        // Tab 列表切换区 (带平滑缓慢切换动效)
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            switchInCurve: Curves.easeInOut,
            switchOutCurve: Curves.easeInOut,
            transitionBuilder: (Widget child, Animation<double> animation) {
              final String childKey = (child.key as ValueKey<String>).value;
              final int childIndex = childKey == 'completed' ? 0 : (childKey == 'active' ? 1 : 2);
              
              final bool isAscending = _receivedSubTab >= _lastReceivedSubTab;
              final bool isIncoming = childIndex == _receivedSubTab;
              
              double beginX = isAscending ? 1.0 : -1.0;
              if (!isIncoming) {
                beginX = -beginX;
              }
              
              return SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(beginX, 0.0),
                  end: Offset.zero,
                ).animate(animation),
                child: FadeTransition(
                  opacity: animation,
                  child: child,
                ),
              );
            },
            child: _receivedSubTab == 0
                ? KeyedSubtree(
                    key: const ValueKey('completed'),
                    child: _buildSubTabList(completedItems, '当前没有已完成的传输记录', controller, voiceService),
                  )
                : _receivedSubTab == 1
                    ? KeyedSubtree(
                        key: const ValueKey('active'),
                        child: _buildSubTabList(activeItems, '当前没有正在传输的任务', controller, voiceService),
                      )
                    : KeyedSubtree(
                        key: const ValueKey('failed'),
                        child: _buildSubTabList(failedItems, '当前没有失败的传输记录', controller, voiceService),
                      ),
          ),
        ),
      ],
    );
  }

  // 构建子 Tab 按钮
  Widget _buildSubTabButton(int index, String label, int count) {
    final bool isActive = _receivedSubTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          if (_receivedSubTab != index) {
            setState(() {
              _lastReceivedSubTab = _receivedSubTab;
              _receivedSubTab = index;
            });
          }
        },
        child: Container(
          color: Colors.transparent,
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeInOut,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                  color: isActive ? Colors.white : AppTheme.onSurfaceVariant,
                ),
                child: Text(label),
              ),
              if (count > 0) ...[
                const SizedBox(width: 4),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: isActive ? Colors.white.withOpacity(0.25) : AppTheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isActive ? Colors.white : AppTheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // 构建子 Tab 列表
  Widget _buildSubTabList(
    List<TransferItem> items,
    String emptyText,
    AppController controller,
    VoiceService voiceService,
  ) {
    if (items.isEmpty) {
      return Center(
        child: Text(
          emptyText,
          style: TextStyle(color: AppTheme.outline.withOpacity(0.5), fontSize: 13),
        ),
      );
    }
    return ListView.builder(
      physics: const BouncingScrollPhysics(),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return _buildDismissibleItem(item, controller, voiceService);
      },
    );
  }

  // 独立滑动手势删除辅助包装器
  Widget _buildDismissibleItem(TransferItem item, AppController controller, VoiceService voiceService) {
    return Dismissible(
      key: Key(item.id),
      direction: DismissDirection.endToStart,
      background: Container(
        margin: const EdgeInsets.only(bottom: 12.0, top: 4.0),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          color: Colors.redAccent.shade200,
          borderRadius: BorderRadius.circular(16),
        ),
        alignment: Alignment.centerRight,
        child: const Icon(
          Icons.delete_outline,
          color: Colors.white,
          size: 24,
        ),
      ),
      onDismissed: (direction) {
        controller.deleteTransferRecord(item.id);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已删除接收记录: ${item.name}'),
          ),
        );
      },
      child: _buildTransferCard(item, controller, voiceService),
    );
  }

  // 弹窗查看文本历史
  void _viewTextContentDialog(String text) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('收到文本消息'),
          content: Container(
            constraints: const BoxConstraints(maxHeight: 200),
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(fontSize: 14, height: 1.4),
              ),
            ),
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primary, foregroundColor: Colors.white),
              child: const Text('好'),
            )
          ],
        );
      },
    );
  }
}
