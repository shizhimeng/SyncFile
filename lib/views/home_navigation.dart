import 'dart:ui';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '../theme/app_theme.dart';
import 'scan_view.dart';
import 'connection_view.dart';
import 'transfer_view.dart';
import 'settings_view.dart';

class HomeNavigation extends StatefulWidget {
  const HomeNavigation({super.key});

  @override
  State<HomeNavigation> createState() => _HomeNavigationState();
}

class _HomeNavigationState extends State<HomeNavigation> {
  int _currentIndex = 0;
  bool _isInvitationExpanded = false;
  final ScrollController _invitationScrollController = ScrollController();

  @override
  void dispose() {
    _invitationScrollController.dispose();
    super.dispose();
  }

  final List<Widget> _views = [
    const ScanView(),
    const ConnectionView(),
    const TransferView(),
    const SettingsView(),
  ];

  @override
  Widget build(BuildContext context) {
    // 监听全局状态控制器
    final controller = Provider.of<AppController>(context);

    // 监听全局状态切换指令，用于连接成功后自动从雷达页跳转到连接管理页
    if (controller.requestTabSwitch != null) {
      final targetTab = controller.requestTabSwitch!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _currentIndex = targetTab;
        });
        controller.consumeTabSwitch();
      });
    }

    // 有设备断线时主动发送 SnackBar 提醒
    if (controller.lastDisconnectAlert != null) {
      final alertMsg = controller.lastDisconnectAlert!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(alertMsg),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        controller.clearDisconnectAlert();
      });
    }

    return Scaffold(
      extendBody: true, // 允许页面内容延伸到毛玻璃底栏下方，呈现极致的悬浮穿透感
      body: Stack(
        children: [
          // 主页面内容，由于底部导航栏占高，留有适当 Padding
          Padding(
            padding: MediaQuery.of(context).padding.bottom == 0
                ? const EdgeInsets.only(bottom: 88)
                : const EdgeInsets.only(bottom: 104),
            child: _views[_currentIndex],
          ),
          
          // 悬浮式极高规格的邀请弹窗提醒 (当收到局域网其它端发送邀请时显示)
          if (controller.incomingInvitations.isNotEmpty)
            _buildInvitationOverlay(controller),

          // 悬浮式高颜值的连接申请侧边栏抽屉 (当收到其它端申请连接时显示)
          if (controller.incomingConnectionRequests.isNotEmpty)
            _buildConnectionRequestSidebar(controller),
        ],
      ),
      bottomNavigationBar: _buildGlassBottomBar(),
    );
  }

  // 1. 高保真毛玻璃底栏
  Widget _buildGlassBottomBar() {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          height: 80 + bottomInset / 2,
          decoration: BoxDecoration(
            color: AppTheme.surface.withOpacity(0.8),
            border: Border(
              top: BorderSide(
                color: AppTheme.outlineVariant.withOpacity(0.3),
                width: 1.0,
              ),
            ),
          ),
          child: SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildNavItem(0, Icons.radar, '扫描'),
                _buildNavItem(1, Icons.devices, '连接'),
                _buildNavItem(2, Icons.swap_horiz, '传输'),
                _buildNavItem(3, Icons.settings, '设置'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 构建单个导航项，支持 Material Symbols 动态高亮与弹簧缩放交互
  Widget _buildNavItem(int index, IconData icon, String label) {
    final isSelected = _currentIndex == index;
    final color = isSelected ? AppTheme.primary : AppTheme.onSurfaceVariant;
    
    return InkWell(
      onTap: () {
        setState(() {
          _currentIndex = index;
        });
      },
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: color,
              size: 26,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: color,
                letterSpacing: 0.05,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 2. 接收文件全局气泡通知覆盖层
  Widget _buildInvitationOverlay(AppController controller) {
    final invitation = controller.incomingInvitations.first;
    final String senderPid = invitation['senderPid'] ?? '未知 PID';
    final String senderName = invitation['senderName'] ?? '其它客户端';
    final List<dynamic> items = invitation['items'] ?? [];

    IconData getFileIcon(String? type) {
      if (type == 'image') return Icons.image;
      if (type == 'voice') return Icons.mic;
      if (type == 'text') return Icons.text_fields;
      return Icons.description;
    }

    Widget buildFileRow(dynamic item) {
      final String name = item['name'] ?? '未知文件';
      final String sizeStr = item['formattedSize'] ?? '未知大小';
      final String? type = item['type'];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6.0),
        child: Row(
          children: [
            Icon(getFileIcon(type), color: AppTheme.primary, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              sizeStr,
              style: const TextStyle(fontSize: 11, color: AppTheme.outline, fontFamily: 'JetBrains Mono'),
            ),
          ],
        ),
      );
    }

    return Positioned(
      top: 64,
      left: 16,
      right: 16,
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: AppTheme.glassCardDecoration(color: Colors.white, opacity: 0.95),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 20,
                    backgroundColor: AppTheme.primary.withOpacity(0.1),
                    child: const Icon(Icons.tablet_android, color: AppTheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          senderName,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                        ),
                        Text(
                          'PID: $senderPid',
                          style: const TextStyle(color: AppTheme.outline, fontSize: 12, fontFamily: 'JetBrains Mono'),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceContainer,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '总共 ${items.length} 个文件',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              
              // 待接收文件详情容器（支持直接滑动查看所有文件，默认最高展示5个文件高度）
              Container(
                width: double.infinity,
                constraints: BoxConstraints(
                  maxHeight: (items.length * 34.0 + 16.0).clamp(50.0, 180.0),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Scrollbar(
                  controller: _invitationScrollController, // 指定局部滚动控制器
                  thumbVisibility: items.length > 5,
                  child: ListView.builder(
                    controller: _invitationScrollController, // 与 Scrollbar 保持一致的局部滚动控制器
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    physics: const BouncingScrollPhysics(),
                    itemCount: items.length,
                    itemBuilder: (context, index) {
                      return buildFileRow(items[index]);
                    },
                  ),
                ),
              ),
              const SizedBox(height: 8),
              
              // 总共待接收概览指标
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      '总计待接收大小:',
                      style: TextStyle(fontSize: 12, color: AppTheme.onSurfaceVariant, fontWeight: FontWeight.w500),
                    ),
                    Text(
                      invitation['totalSize'] ?? '0 B',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.secondary, fontFamily: 'JetBrains Mono'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _isInvitationExpanded = false;
                        });
                        controller.acceptInvitation(senderPid);
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: const Text('接受'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () {
                        setState(() {
                          _isInvitationExpanded = false;
                        });
                        controller.rejectInvitation(senderPid);
                      },
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: AppTheme.outlineVariant),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        foregroundColor: AppTheme.onSurface,
                      ),
                      child: const Text('拒绝'),
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

  // 3. 设备连接请求的毛玻璃居中弹出框
  Widget _buildConnectionRequestSidebar(AppController controller) {
    final request = controller.incomingConnectionRequests.first;
    final String senderPid = request['senderPid'] ?? '未知 PID';
    final String senderName = request['senderName'] ?? '其它客户端';
    final String senderOs = request['senderOs'] ?? 'windows';
    final String? senderAvatar = request['senderAvatar'];

    IconData osIcon = Icons.phone_iphone;
    if (senderOs == 'windows') osIcon = Icons.desktop_windows;
    if (senderOs == 'macos') osIcon = Icons.laptop_mac;
    if (senderOs == 'android') osIcon = Icons.phone_android;

    return Stack(
      children: [
        // 1. 半透明黑色遮罩，点击可关闭/拒绝
        Positioned.fill(
          child: GestureDetector(
            onTap: () => controller.rejectConnectionRequest(senderPid),
            child: Container(
              color: Colors.black.withOpacity(0.4),
            ),
          ),
        ),

        // 2. 居中发光毛玻璃卡片
        Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            padding: const EdgeInsets.all(24),
            decoration: AppTheme.glassCardDecoration(
              color: Colors.white,
              opacity: 0.9,
            ).copyWith(
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withOpacity(0.2),
                  blurRadius: 30,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 头像/系统图标
                Container(
                  width: 80,
                  height: 80,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x10000000),
                        blurRadius: 10,
                        offset: Offset(0, 4),
                      )
                    ],
                  ),
                  child: senderAvatar != null && senderAvatar.isNotEmpty
                      ? ClipOval(
                          child: Image.memory(
                            base64Decode(senderAvatar),
                            width: 80,
                            height: 80,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          ),
                        )
                      : CircleAvatar(
                          radius: 40,
                          backgroundColor: AppTheme.primary.withOpacity(0.1),
                          child: Icon(osIcon, color: AppTheme.primary, size: 36),
                        ),
                ),
                const SizedBox(height: 16),
                
                // 标题
                const Text(
                  '设备连接申请',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: AppTheme.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '设备名称: $senderName',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: AppTheme.onSurface,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'PID: $senderPid',
                  style: const TextStyle(
                    fontFamily: 'JetBrains Mono',
                    fontSize: 11,
                    color: AppTheme.outline,
                  ),
                ),
                const SizedBox(height: 12),
                
                // 倒计时
                // Row(
                //   mainAxisAlignment: MainAxisAlignment.center,
                //   children: [
                //     const Icon(Icons.timer_outlined, size: 16, color: Colors.orange),
                //     const SizedBox(width: 6),
                //   ],
                // ),
                const SizedBox(height: 20),
                
                // 选项按钮
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => controller.rejectConnectionRequest(senderPid),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.outlineVariant),
                          foregroundColor: AppTheme.onSurface,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('拒绝', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          controller.acceptConnectionRequest(senderPid);
                          // 同意后跳转到连接页面 (索引 1)
                          setState(() {
                            _currentIndex = 1;
                          });
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(
                          '同意 (${controller.countdownValues[senderPid] ?? 60}s)',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
