import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:image/image.dart' as img;
import '../theme/app_theme.dart';
import '../controllers/app_controller.dart';

/// [AvatarCropDialog] 头像圆形裁剪弹窗
/// 采用纯 Flutter 架构，不侵入原生 Native 代码，支持在 Windows、iOS、Android 全平台运行。
class AvatarCropDialog extends StatefulWidget {
  final Uint8List imageBytes;
  final AppController controller;

  const AvatarCropDialog({
    super.key,
    required this.imageBytes,
    required this.controller,
  });

  @override
  State<AvatarCropDialog> createState() => _AvatarCropDialogState();
}

class _AvatarCropDialogState extends State<AvatarCropDialog> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _isSaving = false;

  /// 执行高保真圆形物理裁剪
  Future<void> _performCrop() async {
    if (_isSaving) return;
    setState(() {
      _isSaving = true;
    });

    try {
      // 1. 获取 RepaintBoundary 并捕获 300x300 视口区域的原始图像 (以 2.0 的物理像素比以保证超高清头像)
      final renderObject = _boundaryKey.currentContext?.findRenderObject();
      if (renderObject == null || renderObject is! RenderRepaintBoundary) {
        throw Exception("无法获取画布渲染边界");
      }
      
      final RenderRepaintBoundary boundary = renderObject;
      final ui.Image capturedImage = await boundary.toImage(pixelRatio: 2.0);
      
      // 捕获的实际物理图像尺寸
      final double capturedSize = capturedImage.width.toDouble(); 
      // 圆形切片在物理图像中的直径尺寸 (对应 UI 中的 200/300)
      final double cropSize = capturedSize * (200.0 / 300.0); 
      // 偏移量以选取捕获图像正中心
      final double offset = (capturedSize - cropSize) / 2.0; 
      
      // 2. 使用 PictureRecorder 绘制圆形切片 (固定输出 128x128 像素)
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder, const Rect.fromLTWH(0, 0, 128, 128));
      
      // 在新画布上进行圆形剪裁 (Clip path to a circle)
      final clipPath = Path()..addOval(const Rect.fromLTWH(0, 0, 128, 128));
      canvas.clipPath(clipPath);
      
      // 绘制捕获图像的中心部分到圆形画布中
      canvas.drawImageRect(
        capturedImage,
        Rect.fromLTWH(offset, offset, cropSize, cropSize), // 抓取物理图像中心切片
        const Rect.fromLTWH(0, 0, 128, 128), // 铺满目标画布 (固定为 128x128)
        Paint()
          ..isAntiAlias = true
          ..filterQuality = ui.FilterQuality.high,
      );
      
      final picture = recorder.endRecording();
      final ui.Image croppedImage = await picture.toImage(128, 128);
      
      // 3. 提取 Raw RGBA 字节流并使用 image 库编码为 JPG
      final ByteData? byteData = await croppedImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) throw Exception("提取图像数据失败");
      
      final Uint8List rgbaBytes = byteData.buffer.asUint8List();
      
      // 使用 image 库将 RGBA 转换为 JPG 格式，压缩质量设为 85
      final imgImage = img.Image.fromBytes(
        width: 128,
        height: 128,
        bytes: rgbaBytes.buffer,
        order: img.ChannelOrder.rgba,
      );
      final Uint8List jpgBytes = Uint8List.fromList(img.encodeJpg(imgImage, quality: 85));
      
      // 编码为 Base64 并保存至 SQLite 数据库中，体积大幅减少 (一般 1.5KB ~ 3KB)
      final base64Str = base64Encode(jpgBytes);
      
      // 4. 更新控制器以更新头像 Base64 并持久化
      await widget.controller.updateAvatarBase64(base64Str);
      
      if (mounted) {
        Navigator.pop(context, true);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('头像裁剪保存成功!'),
            backgroundColor: AppTheme.secondary,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('头像裁剪失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20),
      child: Center(
        child: Container(
          width: 320,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(28),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 24,
                offset: const Offset(0, 10),
              )
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 头部标题
              Padding(
                padding: const EdgeInsets.only(top: 24, bottom: 16),
                child: Column(
                  children: [
                    const Text(
                      '裁剪头像',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '双指捏合缩放 / 拖拽调整区域',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.onSurfaceVariant.withOpacity(0.7),
                      ),
                    ),
                  ],
                ),
              ),

              // 裁剪预览窗口 (300x300 物理手势感应区，200x200 中央圆形视窗)
              Container(
                width: 300,
                height: 300,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      // 1. 底层 RepaintBoundary 包裹的 InteractiveViewer 拖动缩放图
                      RepaintBoundary(
                        key: _boundaryKey,
                        child: SizedBox(
                          width: 300,
                          height: 300,
                          child: InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 4.0,
                            boundaryMargin: const EdgeInsets.all(150),
                            child: Image.memory(
                              widget.imageBytes,
                              fit: BoxFit.cover,
                            ),
                          ),
                        ),
                      ),

                      // 2. 顶层 IgnorePointer 绘制的圆形裁剪半透明蒙层遮罩
                      IgnorePointer(
                        child: CustomPaint(
                          size: const Size(300, 300),
                          painter: CropMaskPainter(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // 底部操作栏
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 16, bottom: 20),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isSaving ? null : () => Navigator.pop(context),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppTheme.outlineVariant),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          foregroundColor: AppTheme.onSurface,
                        ),
                        child: const Text('取消', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _performCrop,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primary,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.0,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('确认裁剪', style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
              )
            ],
          ),
        ),
      ),
    );
  }
}

/// 圆形遮罩绘制器
class CropMaskPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    // 绘制外部半透明遮罩
    final paint = Paint()
      ..color = Colors.black.withOpacity(0.55)
      ..style = PaintingStyle.fill;

    final outerPath = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final innerPath = Path()
      ..addOval(Rect.fromCircle(
        center: Offset(size.width / 2, size.height / 2),
        radius: 100, // 圆形视窗直径 200 像素
      ));

    // 计算差集蒙版
    final maskPath = Path.combine(PathOperation.difference, outerPath, innerPath);
    canvas.drawPath(maskPath, paint);

    // 绘制圆形边界圈
    final borderPaint = Paint()
      ..color = Colors.white.withOpacity(0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 100, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
