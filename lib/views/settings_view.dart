import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../controllers/app_controller.dart';
import '../theme/app_theme.dart';
import 'avatar_crop_dialog.dart';

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  late TextEditingController _nameController;
  final FocusNode _nameFocus = FocusNode();
  bool _isNameFocused = false;

  @override
  void initState() {
    super.initState();
    final controller = Provider.of<AppController>(context, listen: false);
    _nameController = TextEditingController(text: controller.myName);
    
    _nameFocus.addListener(() {
      setState(() {
        _isNameFocused = _nameFocus.hasFocus;
      });
      // 失去焦点时自动保存改动的设备名称
      if (!_nameFocus.hasFocus) {
        _saveDeviceName(controller);
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _saveDeviceName(AppController controller) {
    String txt = _nameController.text.trim();
    if (txt.isNotEmpty && txt != controller.myName) {
      controller.updateDeviceName(txt);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('设备名称已更改为 "$txt"'),
          backgroundColor: AppTheme.secondary,
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  // 从相册选择并打开圆形裁剪器 (方案A: 采用已开启SDK 36底座的 image_picker, 结合相册权限直接调起谷歌官方安全照片选择器)
  void _pickAndCropAvatar(AppController controller) async {
    try {
      // 1. 在 Android 上自适应申请相册/存储授权
      if (Platform.isAndroid) {
        final status = await Permission.photos.request();
        if (status.isDenied) {
          await Permission.storage.request();
        }
      }

      final ImagePicker picker = ImagePicker();
      // 2. 调起谷歌官方系统级照片选择器，实现零克隆、零垃圾复制
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);

      if (image != null) {
        // 3. 立即异步读取文件到内存字节数组中
        final bytes = await image.readAsBytes();
        
        // 4. 瞬间物理删除临时缓存文件，绝不给系统媒体库扫描和索引的机会！
        try {
          File(image.path).deleteSync();
        } catch (_) {}
        
        if (mounted) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AvatarCropDialog(
              imageBytes: bytes,
              controller: controller,
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('选择图片出错: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);

    // 如果控制器更新了设备名称而输入框没更新（例如初始化完成），在此进行同步
    if (!_nameFocus.hasFocus && _nameController.text != controller.myName) {
      _nameController.text = controller.myName;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20)),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Column(
          children: [
            const SizedBox(height: 12),
            
            // 1. 头像卡片区域
            _buildProfileSection(controller),
            
            const SizedBox(height: 32),
            
            // 2. 通用设置列表
            _buildGeneralSettings(controller),
            
            const SizedBox(height: 24),
            
            // 3. 其它系统设置列表 (关于我们)
            // _buildSystemSettings(),
            
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildDefaultAvatar() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.primary, AppTheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: const Icon(
        Icons.person,
        color: Colors.white,
        size: 52,
      ),
    );
  }

  // 1. 头像、设备名与 PID 区
  Widget _buildProfileSection(AppController controller) {
    return Column(
      children: [
        // 拟真头像 + 相机悬浮修改按纽
        Stack(
          children: [
            Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 4),
                boxShadow: const [BoxShadow(color: Color(0x10000000), blurRadius: 10, offset: Offset(0, 4))],
              ),
              child: ClipOval(
                child: controller.customAvatarBase64.isNotEmpty
                    ? Image.memory(
                        base64Decode(controller.customAvatarBase64),
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        key: ValueKey(controller.customAvatarBase64), // 强制缓存刷新
                        errorBuilder: (context, error, stackTrace) => _buildDefaultAvatar(),
                      )
                    : _buildDefaultAvatar(),
              ),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: 36,
                height: 36,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppTheme.primaryContainer,
                  boxShadow: [BoxShadow(color: Color(0x20000000), blurRadius: 6, offset: Offset(0, 3))],
                ),
                child: IconButton(
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.edit, color: Colors.white, size: 18),
                  onPressed: () => _pickAndCropAvatar(controller),
                ),
              ),
            )
          ],
        ),
        
        const SizedBox(height: 24),

        // 设备名称输入编辑器
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 8.0, bottom: 4.0),
              child: Text(
                '设备名称',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.onSurfaceVariant),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isNameFocused ? AppTheme.primary : AppTheme.outlineVariant.withOpacity(0.5),
                  width: 1.5,
                ),
                boxShadow: _isNameFocused
                    ? [BoxShadow(color: AppTheme.primary.withOpacity(0.08), blurRadius: 8, offset: const Offset(0, 4))]
                    : null,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      focusNode: _nameFocus,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                      onSubmitted: (_) => _saveDeviceName(controller),
                    ),
                  ),
                  const Icon(Icons.edit_note, color: AppTheme.outline, size: 22),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 只读 PID 展示框
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 8.0, bottom: 4.0),
              child: Text(
                '我的 PID',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.onSurfaceVariant),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.outlineVariant.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    controller.myPid,
                    style: const TextStyle(
                      fontFamily: 'JetBrains Mono',
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.5,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  Row(
                    children: [
                      Icon(Icons.lock, color: AppTheme.outline.withOpacity(0.6), size: 14),
                      const SizedBox(width: 4),
                      Text('不可修改', style: TextStyle(color: AppTheme.outline.withOpacity(0.7), fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // 【个人信息创建时间展示框】
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(left: 8.0, bottom: 4.0),
              child: Text(
                '账户创建时间',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.onSurfaceVariant),
              ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.outlineVariant.withOpacity(0.3)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    controller.profileCreateTime.isNotEmpty
                        ? controller.profileCreateTime.substring(0, 10) + ' ' + controller.profileCreateTime.substring(11, 19)
                        : DateTime.now().toIso8601String().substring(0, 10),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppTheme.onSurfaceVariant,
                    ),
                  ),
                  const Row(
                    children: [
                      Icon(Icons.calendar_today, color: AppTheme.primary, size: 14),
                      SizedBox(width: 4),
                      Text('自动记录', style: TextStyle(color: AppTheme.primary, fontSize: 11, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 2. 通用设置列表 (支持上传/下载任务并发限制滑动设置)
  Widget _buildGeneralSettings(AppController controller) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(left: 8.0, bottom: 8.0),
          child: Text(
            '通用设置',
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: AppTheme.primary, letterSpacing: 0.5),
          ),
        ),
        Container(
          decoration: AppTheme.glassCardDecoration(color: Colors.white),
          child: Column(
            children: [
              // 保存路径设置
              _buildSettingTile(
                icon: Icons.folder,
                iconBgColor: AppTheme.primary.withOpacity(0.1),
                iconColor: AppTheme.primary,
                title: '保存路径',
                subtitle: '路径: ${controller.savePath}',
                onTap: () => _pickSaveDirectory(controller),
              ),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Divider(color: AppTheme.outlineVariant.withOpacity(0.3), height: 1),
              ),

              // 最大并发上传数限制
              _buildConcurrencySliderTile(
                icon: Icons.upload_file,
                iconBgColor: Colors.blue.withOpacity(0.1),
                iconColor: Colors.blue,
                title: '最大同时上传数',
                value: controller.maxConcurrentUploads,
                minVal: 1,
                maxVal: 8,
                onChanged: (val) => controller.updateMaxConcurrentUploads(val),
              ),

              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Divider(color: AppTheme.outlineVariant.withOpacity(0.3), height: 1),
              ),

              // 最大并发下载数限制
              _buildConcurrencySliderTile(
                icon: Icons.download_for_offline,
                iconBgColor: Colors.orange.withOpacity(0.1),
                iconColor: Colors.orange,
                title: '最大同时下载数',
                value: controller.maxConcurrentDownloads,
                minVal: 1,
                maxVal: 8,
                onChanged: (val) => controller.updateMaxConcurrentDownloads(val),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 拟真滑动进度条 Tile
  Widget _buildConcurrencySliderTile({
    required IconData icon,
    required Color iconBgColor,
    required Color iconColor,
    required String title,
    required int value,
    required int minVal,
    required int maxVal,
    required ValueChanged<int> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBgColor,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    Text('$value 个', style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold, fontSize: 13)),
                  ],
                ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3.0,
                    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8.0),
                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 16.0),
                    activeTrackColor: AppTheme.primary,
                    inactiveTrackColor: AppTheme.outlineVariant.withOpacity(0.3),
                    thumbColor: AppTheme.primary,
                  ),
                  child: Slider(
                    value: value.toDouble(),
                    min: minVal.toDouble(),
                    max: maxVal.toDouble(),
                    divisions: maxVal - minVal,
                    onChanged: (val) => onChanged(val.round()),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }



  // 列表Tile子抽取
  Widget _buildSettingTile({
    required IconData icon,
    required Color iconBgColor,
    required Color iconColor,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: iconBgColor,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: iconColor, size: 20),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: AppTheme.onSurfaceVariant, fontSize: 12),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right, color: AppTheme.outlineVariant),
      onTap: onTap,
    );
  }

  // 选择保存文件夹
  void _pickSaveDirectory(AppController controller) async {
    try {
      String? selectedDirectory = await FilePicker.platform.getDirectoryPath();
      if (selectedDirectory != null) {
        bool success = await controller.updateSavePath(selectedDirectory);
        if (success) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('默认保存目录已变更为 "$selectedDirectory"'), backgroundColor: AppTheme.secondary),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('更改路径失败：修改为外部共享路径需要您授权“管理所有文件权限”。'),
              backgroundColor: Colors.red,
            ),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('文件夹选择错误: $e'), backgroundColor: Colors.red),
      );
    }
  }
}
