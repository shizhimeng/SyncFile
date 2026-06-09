import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../controllers/app_controller.dart';
import '../models/device_info.dart';
import '../theme/app_theme.dart';

class ScanView extends StatefulWidget {
  const ScanView({super.key});

  @override
  State<ScanView> createState() => _ScanViewState();
}

class _ScanViewState extends State<ScanView> with TickerProviderStateMixin {
  late AnimationController _radarController;
  late AnimationController _breathingController;
  late AnimationController _dotsController;

  // 扫描页多选设备状态
  final Set<String> _selectedScanDeviceIds = {};
  bool _isConnecting = false;

  @override
  void initState() {
    super.initState();
    // 雷达水波纹定时器
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    );

    // 状态呼吸灯
    _breathingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    // 蹦跳等待小圆点
    _dotsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    // 默认开启扫描并绑定雷达播放
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final controller = Provider.of<AppController>(context, listen: false);
      if (controller.isScanning) {
        _radarController.repeat();
      }
    });
  }

  @override
  void dispose() {
    _radarController.dispose();
    _breathingController.dispose();
    _dotsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);

    // 如果未处于扫描状态，自动清理已选择的设备，隐藏底部申请连接按钮条
    if (!controller.isScanning && _selectedScanDeviceIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        setState(() {
          _selectedScanDeviceIds.clear();
        });
      });
    }

    // 过滤掉已经连接了的设备
    final undiscoveredDevices = controller.discoveredDevices.where((device) =>
        !controller.connectedDevices.any((conn) => conn.id == device.id)).toList();

    // 确保扫描状态与动画同步
    if (controller.isScanning && !_radarController.isAnimating) {
      _radarController.repeat();
    } else if (!controller.isScanning && _radarController.isAnimating) {
      _radarController.stop();
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('发现与连接', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Stack(
        children: [
          SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Column(
                children: [
                  // 1. 雷达动画核心区
                  _buildRadarSection(controller),
                  
                  const SizedBox(height: 16),
                  
                  // 2. 发现设备列表头
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        '设备列表',
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceContainer,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          '发现 ${controller.isScanning ? undiscoveredDevices.length : 0} 个设备',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                  
                  const SizedBox(height: 12),

                  // 3. 设备发现列表卡片
                  if (!controller.isScanning || undiscoveredDevices.isEmpty)
                    _buildEmptyPlaceholder(controller)
                  else
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: undiscoveredDevices.length,
                      itemBuilder: (context, index) {
                        return _buildDeviceCard(undiscoveredDevices[index], controller);
                      },
                    ),
                    
                  // 留出底部悬浮大按纽高度，防遮挡
                  if (_selectedScanDeviceIds.isNotEmpty)
                    const SizedBox(height: 80),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
          
          // 悬浮玻璃态连接按纽控制条
          if (_selectedScanDeviceIds.isNotEmpty)
            _buildFloatingConnectionBar(controller),
        ],
      ),
    );
  }

  // 1. 绘制带有相位偏移的多级同心波纹雷达核心
  Widget _buildRadarSection(AppController controller) {
    return Container(
      width: double.infinity,
      height: 280,
      alignment: Alignment.center,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // 背景微小的网格装饰线
          Opacity(
            opacity: 0.04,
            child: GridPaper(
              color: AppTheme.primary,
              interval: 24,
              subdivisions: 1,
              child: Container(width: double.infinity, height: 280),
            ),
          ),
          
          // 水波纹背景动画圈 (3个错落分布的透明圈)
          if (controller.isScanning)
            ...List.generate(3, (index) {
              return AnimatedBuilder(
                animation: _radarController,
                builder: (context, child) {
                  // 计算相位差
                  double progress = _radarController.value + (index * 0.33);
                  if (progress > 1.0) progress -= 1.0;
                  
                  double scale = 1.0 + (progress * 1.5); // 缩放: 1.0 到 2.5
                  double opacity = (1.0 - progress) * 0.6; // 透明度: 0.6 到 0.0

                  return Opacity(
                    opacity: opacity.clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: scale,
                      child: Container(
                        width: 96,
                        height: 96,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: AppTheme.primary, width: 1.5),
                        ),
                      ),
                    ),
                  );
                },
              );
            }),

          // 中央雷达发光核心
          GestureDetector(
            onTap: () {
              // 点击切换扫描状态，带来轻度缩放交互
              controller.toggleScanning(!controller.isScanning);
            },
            child: Container(
              width: 120,
              height: 120,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Color(0x15000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  )
                ],
              ),
              alignment: Alignment.center,
              child: AnimatedScale(
                scale: controller.isScanning ? 1.0 : 0.95,
                duration: const Duration(milliseconds: 200),
                child: Container(
                  width: 96,
                  height: 96,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: AppTheme.primaryGradient,
                    boxShadow: [
                      BoxShadow(
                        color: Color(0x330058BC),
                        blurRadius: 12,
                        offset: Offset(0, 4),
                      )
                    ],
                  ),
                  child: const Icon(
                    Icons.wifi_tethering,
                    color: Colors.white,
                    size: 40,
                  ),
                ),
              ),
            ),
          ),

          // 雷达状态文案及蹦跳等待球
          Positioned(
            bottom: 20,
            child: FadeTransition(
              opacity: _breathingController.drive(Tween(begin: 0.5, end: 1.0)),
              child: Column(
                children: [
                  Text(
                    controller.isScanning ? '扫描中...' : '点击雷达开启扫描',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2.0,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (controller.isScanning)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(3, (index) {
                        return AnimatedBuilder(
                          animation: _dotsController,
                          builder: (context, child) {
                            // 使用正弦函数制造高度错开的波形跳跃
                            double offset = math.sin((_dotsController.value * 2 * math.pi) - (index * math.pi / 2));
                            double translationY = (offset < 0 ? 0 : -offset) * 6; // 仅向上蹦

                            return Transform.translate(
                              offset: Offset(0, translationY),
                              child: Container(
                                width: 5,
                                height: 5,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppTheme.primary,
                                ),
                              ),
                            );
                          },
                        );
                      }),
                    )
                ],
              ),
            ),
          )
        ],
      ),
    );
  }

  // 2. 空白缺省卡片
  Widget _buildEmptyPlaceholder(AppController controller) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 40),
      decoration: AppTheme.glassCardDecoration(color: Colors.white),
      child: Column(
        children: [
          Icon(Icons.wifi_off, size: 48, color: AppTheme.outline.withOpacity(0.4)),
          const SizedBox(height: 12),
          Text(
            controller.isScanning ? '正在搜寻相同 Wi-Fi 网络下的设备...' : '局域网雷达未开启',
            style: const TextStyle(color: AppTheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  // 3. 单个发现设备高保真卡片
  Widget _buildDeviceCard(DeviceInfo device, AppController controller) {
    final isConnected = controller.connectedDevices.any((element) => element.id == device.id);
    final isSelected = _selectedScanDeviceIds.contains(device.id);
    
    // 图标分配
    IconData osIcon = Icons.phone_iphone;
    if (device.os == 'windows') osIcon = Icons.desktop_windows;
    if (device.os == 'macos') osIcon = Icons.laptop_mac;
    if (device.os == 'android') osIcon = Icons.phone_android;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () {
          if (isConnected) return; // 已经是稳定连接态，无需选择
          setState(() {
            if (isSelected) {
              _selectedScanDeviceIds.remove(device.id);
            } else {
              _selectedScanDeviceIds.add(device.id);
            }
          });
        },
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: (isConnected || isSelected) ? AppTheme.primary.withOpacity(0.05) : Colors.white,
            border: Border.all(
              color: (isConnected || isSelected) ? AppTheme.primary : AppTheme.outlineVariant.withOpacity(0.5),
              width: 1.5,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(
            children: [
              // 设备系统背景圈与自定义头像展示
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: device.avatar != null && device.avatar!.isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          base64Decode(device.avatar!),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          errorBuilder: (context, error, stackTrace) => Icon(osIcon, color: AppTheme.onSurfaceVariant, size: 24),
                        ),
                      )
                    : Icon(osIcon, color: AppTheme.onSurfaceVariant, size: 24),
              ),
              
              const SizedBox(width: 16),
              
              // 设备名称与 IP 标识
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${device.ip} • ${isConnected ? "已连接" : "在线"}',
                      style: const TextStyle(color: AppTheme.onSurfaceVariant, fontSize: 12),
                    ),
                  ],
                ),
              ),
              
              // 右侧连接勾选按纽
              Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: (isConnected || isSelected) ? AppTheme.primary : Colors.transparent,
                  border: Border.all(
                    color: (isConnected || isSelected) ? AppTheme.primary : AppTheme.outlineVariant,
                    width: 2,
                  ),
                ),
                child: (isConnected || isSelected)
                    ? const Icon(Icons.check, color: Colors.white, size: 14)
                    : null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 4. 绘制底部悬浮连接确认面板 (磨砂高透发光)
  Widget _buildFloatingConnectionBar(AppController controller) {
    return Positioned(
      bottom: 24,
      left: 16,
      right: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.85),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: AppTheme.outlineVariant.withOpacity(0.4),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppTheme.primary.withOpacity(0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                )
              ],
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '已选择 ${_selectedScanDeviceIds.length} 台设备',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: AppTheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      '需要对端同意才可加入连接',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.outline,
                      ),
                    ),
                  ],
                ),
                ElevatedButton(
                  onPressed: _isConnecting ? null : () => _initiateConnectionHandshake(controller),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  ),
                  child: _isConnecting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.0,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.link, size: 16),
                            SizedBox(width: 6),
                            Text(
                              '申请连接',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 5. 逐一发起连接握手请求并统一汇总通知
  void _initiateConnectionHandshake(AppController controller) async {
    setState(() {
      _isConnecting = true;
    });

    List<String> targetIds = _selectedScanDeviceIds.toList();
    int successCount = 0;
    int failCount = 0;

    for (var id in targetIds) {
      int idx = controller.discoveredDevices.indexWhere((element) => element.id == id);
      if (idx == -1) continue;

      DeviceInfo device = controller.discoveredDevices[idx];
      bool accepted = await controller.requestConnection(device);
      if (accepted) {
        successCount++;
      } else {
        failCount++;
      }
    }

    if (mounted) {
      setState(() {
        _isConnecting = false;
        _selectedScanDeviceIds.clear();
      });

      String message = '';
      if (successCount > 0 && failCount == 0) {
        message = '成功与 $successCount 台设备建立物理连接！';
      } else if (successCount > 0 && failCount > 0) {
        message = '成功连接 $successCount 台，被拒绝/失败 $failCount 台';
      } else {
        message = '连接请求已被对方拒绝或超时';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: successCount > 0 ? AppTheme.secondary : AppTheme.error,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }
}
