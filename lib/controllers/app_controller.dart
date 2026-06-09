import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import '../models/device_info.dart';
import '../models/transfer_item.dart';
import '../services/lan_service.dart';
import '../services/db_helper.dart';
import 'package:crypto/crypto.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

class AppController extends ChangeNotifier {
  LanService? _lanService;

  // 基本配置状态
  String _myPid = '';
  String _myName = '';
  String _savePath = '';
  String _networkMode = '优先局域网';
  String _customAvatarBase64 = '';
  String _profileCreateTime = '';

  int _maxConcurrentUploads = 3;
  int _maxConcurrentDownloads = 3;

  int get maxConcurrentUploads => _maxConcurrentUploads;
  int get maxConcurrentDownloads => _maxConcurrentDownloads;

  // 存储正在验证中的 IP/PID 列表，防止并发 UDP 包造成重复 HTTP 请求
  final Set<String> _pendingInfoVerifications = {};

  String get myPid => _myPid;
  String get myName => _myName;
  String get savePath => _savePath;
  String get networkMode => _networkMode;
  String get customAvatarBase64 => _customAvatarBase64;
  String get profileCreateTime => _profileCreateTime;

  // 状态变量
  bool _isScanning = false;
  List<DeviceInfo> _discoveredDevices = [];
  List<DeviceInfo> _connectedDevices = [];
  List<Map<String, dynamic>> _connectedDevicesHistory = [];

  List<Map<String, dynamic>> get connectedDevicesHistory => _connectedDevicesHistory;

  // 握手入站邀请 (保存邀请数据和对应的 Socket 套接字用于同意或拒绝回复)
  final List<Map<String, dynamic>> _incomingInvitations = [];

  // 握手入站连接申请
  final List<Map<String, dynamic>> _incomingConnectionRequests = [];
  
  // 60秒审批倒计时状态管理
  final Map<String, int> _countdownValues = {};
  final Map<String, Timer> _countdownTimers = {};

  // WebSocket 暂存的正在发送中的邀请元数据列表
  final Map<String, List<TransferItem>> _outgoingInvitations = {};

  // 记录每个传输任务的上次 UI 刷新时间戳（用于节流）
  final Map<String, int> _lastProgressUpdateTime = {};

  // 供视图层监听的主动 tab 切换请求
  int? _requestTabSwitch;
  int? get requestTabSwitch => _requestTabSwitch;

  void consumeTabSwitch() {
    _requestTabSwitch = null;
  }

  void switchToTab(int tabIndex) {
    _requestTabSwitch = tabIndex;
    notifyListeners();
  }

  List<Map<String, dynamic>> get incomingConnectionRequests =>
      _incomingConnectionRequests;
  Map<String, int> get countdownValues => _countdownValues;

  String? _lastDisconnectAlert;
  String? get lastDisconnectAlert => _lastDisconnectAlert;

  void clearDisconnectAlert() {
    _lastDisconnectAlert = null;
  }

  // 发送暂存队列与历史记录
  final List<TransferItem> _pendingSendQueue = [];
  final List<TransferItem> _transferHistory = [];

  bool get isScanning => _isScanning;
  List<DeviceInfo> get discoveredDevices => _discoveredDevices;
  List<DeviceInfo> get connectedDevices => _connectedDevices;
  List<Map<String, dynamic>> get incomingInvitations => _incomingInvitations;
  List<TransferItem> get pendingSendQueue => _pendingSendQueue;
  List<TransferItem> get transferHistory => _transferHistory;

  // 1. 初始化
  Future<void> initialize() async {
    // 首次安装运行申请相册与存储基础权限
    if (Platform.isAndroid) {
      try {
        await [
          Permission.photos,
          Permission.storage,
        ].request();
      } catch (e) {
        if (kDebugMode) print(" [SyncFile系统日志]: 首次启动权限申请失败: $e");
      }
    }

    // 确保数据库已初始化
    await DbHelper.database;

    // 在 Android 临时缓存目录写入 .nomedia 文件，阻止系统媒体扫描器扫描和展示 file_picker 的缓存图片
    if (Platform.isAndroid) {
      try {
        final cacheDir = await getTemporaryDirectory();
        final noMediaFile = File('${cacheDir.path}/.nomedia');
        if (!await noMediaFile.exists()) {
          await noMediaFile.create(recursive: true);
        }

        final fpCacheDir = Directory('${cacheDir.path}/file_picker');
        if (!await fpCacheDir.exists()) {
          await fpCacheDir.create(recursive: true);
        }
        final fpNoMedia = File('${fpCacheDir.path}/.nomedia');
        if (!await fpNoMedia.exists()) {
          await fpNoMedia.create(recursive: true);
        }
      } catch (e) {
        if (kDebugMode) print(" [SyncFile系统日志]: 创建防媒体扫描的 .nomedia 隔离占位文件失败: $e");
      }
    }

    // 根据手机/电脑的唯一硬件机器码生成 24 位的唯一 ID，哪怕卸载重装依然一致
    _myPid = await DbHelper.getSetting('my_pid') ?? '';
    if (_myPid.isEmpty) {
      _myPid = _generateHardwarePid();
      await DbHelper.saveSetting('my_pid', _myPid);
    }

    // 加载/设置设备名称 (默认使用真实友好的系统/手机型号名称)
    _myName = await DbHelper.getSetting('my_name') ?? '';
    if (_myName.isEmpty) {
      _myName = _getDefaultDeviceName();
      await DbHelper.saveSetting('my_name', _myName);
    }

    // 加载/设置默认保存文件夹
    _savePath = await DbHelper.getSetting('save_path') ?? '';
    if (_savePath.isEmpty) {
      try {
        Directory? downloadsDir;
        if (Platform.isWindows) {
          downloadsDir = Directory(
            "C:/Users/${Platform.environment['USERNAME']}/Downloads/SyncFile",
          );
        } else {
          // 【方案A】：第一次安装且无路径设置时，默认将路径初始化为绝对具有安全写入权限的 App 专属隔离沙盒文档目录
          final appDocDir = await getApplicationDocumentsDirectory();
          downloadsDir = Directory("${appDocDir.path}/SyncFile");
        }
        _savePath = downloadsDir.path.replaceAll('\\', '/');
        // 保存至持久化配置
        await DbHelper.saveSetting('save_path', _savePath);
      } catch (_) {
        _savePath = 'SyncFile';
      }
    }

    _networkMode = await DbHelper.getSetting('network_mode') ?? '优先局域网';

    _maxConcurrentUploads = int.tryParse(await DbHelper.getSetting('max_concurrent_uploads') ?? '3') ?? 3;
    _maxConcurrentDownloads = int.tryParse(await DbHelper.getSetting('max_concurrent_downloads') ?? '3') ?? 3;

    // 加载/设置个人档案的首次创建时间
    _profileCreateTime = await DbHelper.getSetting('profile_create_time') ?? '';
    if (_profileCreateTime.isEmpty) {
      _profileCreateTime = DateTime.now().toIso8601String();
      await DbHelper.saveSetting('profile_create_time', _profileCreateTime);
    }

    // 加载头像的 base64 字符串
    _customAvatarBase64 =
        await DbHelper.getSetting('custom_avatar_base64') ?? '';

    // 从 SQLite 加载历史传输记录
    final historyList = await DbHelper.getTransferHistory();
    _transferHistory.clear();
    _transferHistory.addAll(historyList);

    // 从 SQLite 加载曾经连接的设备历史表关系清单
    _connectedDevicesHistory = await DbHelper.getConnectedDevices();

    // 2. 初始化网络传输引擎 (LanService)
    _lanService = LanService(
      myPid: _myPid,
      myName: _myName,
      myAvatar: _customAvatarBase64,
      onDeviceDiscovered: _handleDeviceDiscovered,
      onDeviceOffline: _handleDeviceOffline,
      onInvitationReceived: _handleInvitationReceived,
      onConnectionRequestReceived: _handleConnectionRequestReceived,
      onTransferProgress: _handleTransferProgress,
      onWebSocketConnected: _handleWebSocketConnected,
      onWebSocketDisconnected: _handleWebSocketDisconnected,
      onWebSocketInvitationReceived: _handleWebSocketInvitationReceived,
      onWebSocketInvitationResponse: _handleWebSocketInvitationResponse,
      onSyncInfoReceived: _handleSyncInfoReceived,
    );

    // 同步并发下载数设置给服务层
    _lanService!.maxConcurrentDownloads = _maxConcurrentDownloads;

    // 3. 启动局域网接收服务器及设备广播发现服务
    await _lanService!.startTcpServer();
    await _lanService!.startWebSocketServer();
    await _lanService!.startDiscovery();

    notifyListeners();
  }

  // 3.1 处理局域网内其他设备的心跳广播 (支持严格的 HTTP 接口准入探活验证)
  void _handleDeviceDiscovered(DeviceInfo device) async {
    // 1. 如果已经是内存中已发现且经过验证的在线设备，仅更新 IP、端口与心跳时间
    int idx = _discoveredDevices.indexWhere((element) => element.id == device.id);
    if (idx != -1) {
      _discoveredDevices[idx] = _discoveredDevices[idx].copyWith(
        ip: device.ip,
        port: device.port,
        lastSeen: DateTime.now(),
      );
      notifyListeners();
      return;
    }

    // 2. 新发现设备：加入待验证队列，防止 UDP 广播并发引起的多次重叠 HTTP 探测请求
    final String verifyKey = '${device.ip}_${device.id}';
    if (_pendingInfoVerifications.contains(verifyKey)) return;
    _pendingInfoVerifications.add(verifyKey);

    try {
      // 通过 TCP/HTTP info 接口对端校验 PID，获取最新的头像和名称
      final verifiedDevice = await _lanService?.fetchDeviceInfo(device.ip, device.id, device.wsPort);
      if (verifiedDevice != null) {
        // 验证成功后，双重检测并正式入库
        int checkIdx = _discoveredDevices.indexWhere((element) => element.id == verifiedDevice.id);
        if (checkIdx != -1) {
          _discoveredDevices[checkIdx] = verifiedDevice;
        } else {
          _discoveredDevices.add(verifiedDevice);
        }
        notifyListeners();
      }
    } catch (e) {
      if (kDebugMode) print("AppController: Verification failed for device: ${device.id}, $e");
    } finally {
      _pendingInfoVerifications.remove(verifyKey);
    }
  }

  // 设备离线处理
  void _handleDeviceOffline(String pid) {
    _discoveredDevices.removeWhere((element) => element.id == pid);
    _connectedDevices.removeWhere((element) => element.id == pid);
    notifyListeners();
  }

  // 3.2 收到入站连接邀请的回调 (已解耦，Socket 由 LanService 处理)
  void _handleInvitationReceived(Map<String, dynamic> invitation) {
    String senderPid = invitation['senderPid'] ?? '';
    if (senderPid.isEmpty) return;

    // 存入邀请队列，让 UI 渲染“邀请信息”页
    _incomingInvitations.removeWhere(
      (element) => element['senderPid'] == senderPid,
    );
    _incomingInvitations.add(invitation);

    notifyListeners();
  }

  // 3.4 收到入站设备连接申请的回调 (已解耦，Socket 由 LanService 处理)
  void _handleConnectionRequestReceived(Map<String, dynamic> request) {
    String senderPid = request['senderPid'] ?? '';
    if (senderPid.isEmpty) return;

    // 存入申请队列，通知 UI 侧边栏滑出
    _incomingConnectionRequests.removeWhere(
      (element) => element['senderPid'] == senderPid,
    );
    _incomingConnectionRequests.add(request);


    // 清理可能已有的同设备倒计时定时器
    _countdownTimers[senderPid]?.cancel();

    // 启动 60 秒的精准连接申请审批倒计时，超时不操作自动拒绝
    _countdownValues[senderPid] = 60;
    _countdownTimers[senderPid] = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownValues[senderPid] != null && _countdownValues[senderPid]! > 0) {
        _countdownValues[senderPid] = _countdownValues[senderPid]! - 1;
        notifyListeners();
      } else {
        // 时间到，执行自动拒绝逻辑
        timer.cancel();
        _countdownTimers.remove(senderPid);
        _countdownValues.remove(senderPid);
        rejectConnectionRequest(senderPid);
      }
    });

    notifyListeners();
  }

  // 3.3 传输进度更新统一处理句柄
  void _handleTransferProgress(
    String itemId,
    double progress,
    double speed,
    String status,
  ) {
    int idx = _transferHistory.indexWhere((element) => element.id == itemId);
    if (idx != -1) {
      final oldStatus = _transferHistory[idx].status;
      
      // if (kDebugMode) {
      //   print(" [_handleTransferProgress] itemId: $itemId, oldStatus: $oldStatus, newStatus: $status");
      // }

      // 如果当前已经是终态（以failed:开头的细分失败、success或rejected），绝不允许回退到进行中状态或被普通的failed覆盖
      if (oldStatus.startsWith('failed:') || oldStatus == 'success' || oldStatus == 'rejected') {
        if (status == 'transferring' || status == 'waiting' || status == 'queued' || status == 'failed') {
          if (kDebugMode) {
            print(" [_handleTransferProgress] Blocked status transition from terminal state '$oldStatus' to '$status'");
          }
          return;
        }
      }

      String finalStatus = status;
      if (status == 'failed:cancelled_by_peer') {
        final direction = _transferHistory[idx].direction;
        if (direction == 'received') {
          // 我方是接收端，对方是发送端。对方（发送端）取消了 -> 对方暂停发送
          finalStatus = 'failed:对方暂停发送';
        } else {
          // 我方是发送端，对方是接收端。对方（接收端）取消了 -> 对方拒收
          finalStatus = 'failed:对方拒收';
        }
      }

      _transferHistory[idx] = _transferHistory[idx].copyWith(
        progress: progress,
        speed: speed,
        status: finalStatus,
      );

      // UI 刷新节流机制 (200ms)
      bool shouldNotify = true;
      if (finalStatus == 'transferring') {
        final now = DateTime.now().millisecondsSinceEpoch;
        final lastTime = _lastProgressUpdateTime[itemId] ?? 0;
        if (now - lastTime < 200) {
          shouldNotify = false;
        } else {
          _lastProgressUpdateTime[itemId] = now;
        }
      } else {
        // 非 transferring 状态或状态改变，立即更新时间戳
        _lastProgressUpdateTime.remove(itemId);
      }

      if (shouldNotify) {
        notifyListeners();
      }

      // 仅在状态改变、传输成功或失败时才更新数据库，避免频繁 I/O 操作导致的卡顿
      if (oldStatus != finalStatus || finalStatus == 'success' || finalStatus.startsWith('failed')) {
        DbHelper.updateTransfer(_transferHistory[idx]);
      }
    }
  }

  // 4. 更新设备基本配置
  Future<void> updateDeviceName(String newName) async {
    _myName = newName;
    await DbHelper.saveSetting('my_name', newName);
    if (_lanService != null) {
      _lanService!.myName = newName;
    }
    notifyListeners();
  }

  Future<bool> updateSavePath(String newPath) async {
    if (Platform.isAndroid) {
      // 检查选择的路径是否超出了 app 的内部安全沙盒私有路径
      final appDocDir = await getApplicationDocumentsDirectory();
      final String securePrefix = appDocDir.path.replaceAll('\\', '/');
      final String formattedNewPath = newPath.replaceAll('\\', '/');
      
      if (!formattedNewPath.startsWith(securePrefix)) {
        // 如果路径是外部非沙盒根目录（如 /storage/emulated/0），检查并必须强求 ManageExternalStorage 权限
        var status = await Permission.manageExternalStorage.status;
        if (!status.isGranted) {
          status = await Permission.manageExternalStorage.request();
          if (!status.isGranted) {
            // 用户拒绝授权，保存失败
            return false;
          }
        }
      }
    }
    
    _savePath = newPath.replaceAll('\\', '/');
    await DbHelper.saveSetting('save_path', _savePath);
    notifyListeners();
    return true;
  }

  Future<void> updateNetworkMode(String newMode) async {
    _networkMode = newMode;
    await DbHelper.saveSetting('network_mode', newMode);
    notifyListeners();
  }

  // 4.1 更新头像 Base64 字符串并写入 SQLite
  Future<void> updateAvatarBase64(String base64Str) async {
    _customAvatarBase64 = base64Str;
    await DbHelper.saveSetting('custom_avatar_base64', base64Str);
    if (_lanService != null) {
      _lanService!.myAvatar = base64Str;
    }
    notifyListeners();
  }



  // 5. 扫描逻辑
  void toggleScanning(bool active) {
    _isScanning = active;
    if (active) {
      _discoveredDevices.clear();
    }
    notifyListeners();
  }

  // 6. 连接控制 (实际局域网连接)
  void connectToDevice(DeviceInfo device) {
    // 将该设备移动到已连接列表中
    int idx = _connectedDevices.indexWhere(
      (element) => element.id == device.id,
    );
    if (idx == -1) {
      _connectedDevices.add(device.copyWith(isConnected: true));
    }

    notifyListeners();
  }

  void disconnectDevice(String pid) {
    _connectedDevices.removeWhere((element) => element.id == pid);
    // 主动断开：向对端发送 disconnect 包并物理销毁本端套接字
    _lanService?.disconnectWsChannel(pid);
    notifyListeners();
  }

  // 6.1 发送双向连接申请并异步等待响应 (同意后自动升级为 WebSocket)
  Future<bool> requestConnection(DeviceInfo device) async {
    String os = Platform.isWindows
        ? 'windows'
        : Platform.isIOS
        ? 'ios'
        : Platform.isAndroid
        ? 'android'
        : Platform.isMacOS
        ? 'macos'
        : 'linux';

    bool accepted = await _lanService!.sendConnectionRequest(
      device: device,
      senderOs: os,
      senderAvatar: _customAvatarBase64,
      onDecision: (isAccepted) async {
        if (isAccepted) {
          // 对方在 TCP 握手中同意了，立即发起 WebSocket 长连接建链
          await _lanService!.connectToWebSocket(device);
          // 成功连接，主动发送方跳转到连接页 (Tab 1)
          switchToTab(1);
        }
      },
    );
    notifyListeners();
    return accepted;
  }

  // 6.2 接受入站设备连接申请 (取消倒计时并建立长连接) (已解耦)
  Future<void> acceptConnectionRequest(String senderPid) async {
    _countdownTimers[senderPid]?.cancel();
    _countdownTimers.remove(senderPid);
    _countdownValues.remove(senderPid);

    int idx = _incomingConnectionRequests.indexWhere(
      (element) => element['senderPid'] == senderPid,
    );
    if (idx == -1) return;

    await _lanService?.respondToConnectionRequest(senderPid, true);

    _incomingConnectionRequests.removeAt(idx);
    notifyListeners();
  }




  // 6.3 拒绝入站设备连接申请
  Future<void> rejectConnectionRequest(String senderPid) async {
    // 立即取消并清理 60 秒倒计时定时器
    _countdownTimers[senderPid]?.cancel();
    _countdownTimers.remove(senderPid);
    _countdownValues.remove(senderPid);

    int idx = _incomingConnectionRequests.indexWhere(
      (element) => element['senderPid'] == senderPid,
    );
    if (idx == -1) return;

    await _lanService?.respondToConnectionRequest(senderPid, false);

    _incomingConnectionRequests.removeAt(idx);

    notifyListeners();
  }

  // 7. 发送暂存队列管理
  void addToSendQueue(TransferItem item) {
    _pendingSendQueue.add(item);
    notifyListeners();
  }

  void removeFromSendQueue(String itemId) {
    _pendingSendQueue.removeWhere((element) => element.id == itemId);
    notifyListeners();
  }

  void updatePendingSendText(String itemId, String newText) {
    int idx = _pendingSendQueue.indexWhere((element) => element.id == itemId);
    if (idx != -1) {
      _pendingSendQueue[idx] = _pendingSendQueue[idx].copyWith(
        name: newText,
        content: newText,
        size: newText.length,
      );
      notifyListeners();
    }
  }

  void clearSendQueue() {
    _pendingSendQueue.clear();
    notifyListeners();
  }

  // 8. 执行批量发送
  Future<void> sendQueueToDevices(List<String> targetPids) async {
    if (_pendingSendQueue.isEmpty || targetPids.isEmpty) return;

    List<TransferItem> sendList = List.from(_pendingSendQueue);
    // 清空暂存队列
    _pendingSendQueue.clear();
    notifyListeners();

    // 提前解析本机的局域网活动 IP 地址
    final String localIp = await _lanService?.getLocalIp() ?? '127.0.0.1';

    for (var pid in targetPids) {
      // 查找设备
      int devIdx = _connectedDevices.indexWhere((element) => element.id == pid);
      if (devIdx == -1) continue;
      DeviceInfo device = _connectedDevices[devIdx];

      // 为此设备复制传输项并置入传输历史中
      List<TransferItem> copiedItems = sendList.map((item) {
        return item.copyWith(
          id: const Uuid().v4(), // 重新赋予独立的 UUID 避免重复
          status: 'waiting',
          peerId: device.id,
          peerName: device.name,
          direction: 'sent',
          timestamp: DateTime.now(),
        );
      }).toList();

      _transferHistory.insertAll(0, copiedItems);
      for (var item in copiedItems) {
        await DbHelper.insertTransfer(item);
      }
      notifyListeners();

      // 暂存至发送队列记录中，等待对端 WebSocket 通道回复结果
      _outgoingInvitations[device.id] = copiedItems;

      // 动态生成每个文件的 HTTP 下载映射与安全鉴权 Token
      final List<Map<String, dynamic>> itemsPayload = [];
      int totalSizeBytes = 0;
      for (var item in copiedItems) {
        totalSizeBytes += item.size;
        String downloadUrl = '';
        // 物理文件才需要提供 HTTP 下载链接
        if (item.path != null && item.path!.isNotEmpty) {
          final String token = _lanService?.generateSecureToken() ?? 'secure_token';
          _lanService?.registerDownloadableFile(item.id, item.path!, token);
          final int activeWsPort = _lanService?.wsPort ?? 8890;
          downloadUrl = 'http://$localIp:$activeWsPort/download?id=${item.id}&token=$token';
        }

        itemsPayload.add({
          'id': item.id,
          'name': item.name,
          'size': item.size,
          'formattedSize': item.formattedSize,
          'type': item.type,
          'content': item.content,
          'downloadUrl': downloadUrl,
        });
      }

      // 计算发送端格式化的总大小
      String formattedTotal = '0 B';
      if (totalSizeBytes > 0) {
        if (totalSizeBytes < 1024) {
          formattedTotal = "$totalSizeBytes B";
        } else if (totalSizeBytes < 1024 * 1024) {
          formattedTotal = "${(totalSizeBytes / 1024).toStringAsFixed(1)} KB";
        } else if (totalSizeBytes < 1024 * 1024 * 1024) {
          formattedTotal = "${(totalSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB";
        } else {
          formattedTotal = "${(totalSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB";
        }
      }

      // 通过双向持久 WebSocket 通道将发送邀请元数据秒级推送到接收端 (包含 HTTP 临时下载 URL 和一次性 Token)
      _lanService?.sendInvitationOverWs(device.id, {
        'senderPid': _myPid,
        'senderName': _myName,
        'saveDir': _savePath,
        'items': itemsPayload,
        'totalSize': formattedTotal,
      });
    }
  }

  // 9. 接受或拒绝入站邀请
  Future<void> acceptInvitation(String senderPid) async {
    int idx = _incomingInvitations.indexWhere(
      (element) => element['senderPid'] == senderPid,
    );
    if (idx == -1) return;

    Map<String, dynamic> invitation = _incomingInvitations[idx];
    // 调度 LanService 进行握手回复（已解耦，Socket 由 LanService 自主调度）
    await _lanService?.respondToInvitation(senderPid, true);

    // 在历史记录中生成这些接收项
    List<dynamic> items = invitation['items'] ?? [];
    String senderName = invitation['senderName'] ?? '其它客户端';

    for (var rawItem in items) {
      TransferItem rItem = TransferItem(
        id: rawItem['id'] ?? const Uuid().v4(),
        name: rawItem['name'] ?? '未知文件',
        size: rawItem['size'] ?? 0,
        type: rawItem['type'] ?? 'file',
        content: rawItem['content'],
        direction: 'received',
        status: (rawItem['type'] == 'text')
            ? 'success'
            : 'transferring', // 文本无需进度直达成功
        timestamp: DateTime.now(),
        peerId: senderPid,
        peerName: senderName,
      );
      _transferHistory.insert(0, rItem);
      await DbHelper.insertTransfer(rItem);
    }
    notifyListeners();

    // 附加上传端 PID 用于网络看门狗超时反向推送
    final List<Map<String, dynamic>> itemsWithSender = items.map((e) {
      final map = Map<String, dynamic>.from(e);
      map['senderPid'] = senderPid;
      return map;
    }).toList();

    // 启动 HTTP 流式并行下载拉取引擎
    _lanService?.startDownloadingItems(itemsWithSender, _savePath);

    _incomingInvitations.removeAt(idx);

    notifyListeners();
  }

  Future<void> rejectInvitation(String senderPid) async {
    int idx = _incomingInvitations.indexWhere(
      (element) => element['senderPid'] == senderPid,
    );
    if (idx == -1) return;

    // 调度 LanService 进行物理握手或 WS 握手回复（已解耦）
    await _lanService?.respondToInvitation(senderPid, false);

    _incomingInvitations.removeAt(idx);
    notifyListeners();
  }

  // 10. 重试失败项目
  Future<void> retryTransfer(TransferItem item) async {
    // 重新塞入 pendingSendQueue，并跳转到连接页重发
    _transferHistory.removeWhere((element) => element.id == item.id);
    await DbHelper.deleteTransfer(item.id);
    addToSendQueue(item.copyWith(status: 'queued', progress: 0.0, speed: 0.0));
    notifyListeners();
  }

  // 10.5 手动终止传输记录 (支持发送端和接收端双向停止)
  void cancelTransfer(String itemId, String peerId) {
    _lanService?.cancelTransfer(itemId, peerPid: peerId);
    
    int idx = _transferHistory.indexWhere((element) => element.id == itemId);
    String reason = 'failed';
    if (idx != -1) {
      final direction = _transferHistory[idx].direction;
      if (direction == 'sent') {
        reason = 'failed:我方中断传输';
      } else {
        reason = 'failed:拒收文件';
      }
    }
    _handleTransferProgress(itemId, 0.0, 0.0, reason);
  }

  // 11. 删除指定传输记录 (从内存 and SQLite 中物理删除)
  Future<void> deleteTransferRecord(String itemId) async {
    _transferHistory.removeWhere((element) => element.id == itemId);
    await DbHelper.deleteTransfer(itemId);
    notifyListeners();
  }

  // 清空所有传输历史记录
  Future<void> clearAllTransferHistory() async {
    _transferHistory.clear();
    await DbHelper.clearAllTransfers();
    notifyListeners();
  }

  // 工具：生成指定长度的随机十六进制字符串
  String _randHex(int len) {
    const chars = '0123456789ABCDEF';
    Random rand = Random();
    return List.generate(len, (index) => chars[rand.nextInt(16)]).join();
  }

  @override
  void dispose() {
    _lanService?.dispose();
    super.dispose();
  }

  /// 依据硬件特征码计算标准的 24 位 MD5 唯一标示符
  String _generateHardwarePid() {
    final rawId = _getRawDeviceSignature();
    final fullMd5 = md5.convert(utf8.encode(rawId)).toString().toLowerCase();
    // 截取前 24 位以缩短显示长度，在局域网内依然具备极佳的熵值与绝对的唯一性
    return fullMd5.substring(0, 24);
  }

  /// 跨平台获取物理机器唯一指纹码
  String _getRawDeviceSignature() {
    try {
      if (Platform.isWindows) {
        // 1. 优先获取主板物理 UUID
        var result = Process.runSync('wmic', ['csproduct', 'get', 'uuid']);
        if (result.exitCode == 0) {
          String uuid = result.stdout.toString().replaceAll('UUID', '').trim();
          if (uuid.isNotEmpty &&
              uuid.toLowerCase() != 'value' &&
              !uuid.contains('error')) {
            return 'win-uuid-$uuid';
          }
        }

        // 2. 备用：从注册表获取 MachineGuid
        var regResult = Process.runSync('reg', [
          'query',
          'HKLM\\SOFTWARE\\Microsoft\\Cryptography',
          '/v',
          'MachineGuid',
        ]);
        if (regResult.exitCode == 0) {
          String output = regResult.stdout.toString();
          RegExp reg = RegExp(r'MachineGuid\s+REG_SZ\s+([a-fA-F0-9-]+)');
          var match = reg.firstMatch(output);
          if (match != null && match.groupCount >= 1) {
            return 'win-reg-${match.group(1)}';
          }
        }

        // 3. 末位备用：计算机名与系统变量组合
        return 'win-fallback-${Platform.environment['COMPUTERNAME']}-${Platform.environment['USERNAME']}';
      } else if (Platform.isMacOS) {
        var result = Process.runSync('ioreg', [
          '-rd1',
          '-c',
          'IOPlatformExpertDevice',
        ]);
        if (result.exitCode == 0) {
          String output = result.stdout.toString();
          RegExp reg = RegExp(r'"IOPlatformUUID" = "([^"]+)"');
          var match = reg.firstMatch(output);
          if (match != null && match.groupCount >= 1) {
            return 'mac-uuid-${match.group(1)}';
          }
        }
        return 'mac-fallback-${Platform.localHostname}';
      } else if (Platform.isLinux) {
        for (var path in ['/var/lib/dbus/machine-id', '/etc/machine-id']) {
          final file = File(path);
          if (file.existsSync()) {
            return 'linux-id-${file.readAsStringSync().trim()}';
          }
        }
        return 'linux-fallback-${Platform.localHostname}';
      } else {
        // 移动端沙盒安全限制：结合系统特征提供最佳相似签名
        return 'mobile-sig-${Platform.operatingSystem}-${Platform.numberOfProcessors}-${Platform.version}';
      }
    } catch (_) {
      return 'global-fallback-${Platform.localHostname}';
    }
  }

  /// 获取系统或手机硬件友好真实的默认名称
  String _getDefaultDeviceName() {
    try {
      if (Platform.isWindows) {
        // Windows: 优先获取系统环境变量 COMPUTERNAME
        final computerName = Platform.environment['COMPUTERNAME'];
        if (computerName != null && computerName.isNotEmpty) {
          return computerName;
        }
        return Platform.localHostname;
      } else if (Platform.isAndroid) {
        // Android: 物理运行 getprop 获取手机品牌与型号，完美规避 localhost 占位符
        var brandResult = Process.runSync('getprop', ['ro.product.brand']);
        var modelResult = Process.runSync('getprop', ['ro.product.model']);

        String brand = '';
        String model = '';

        if (brandResult.exitCode == 0) {
          brand = brandResult.stdout.toString().trim();
        }
        if (modelResult.exitCode == 0) {
          model = modelResult.stdout.toString().trim();
        }

        // 格式化输出
        if (brand.isNotEmpty || model.isNotEmpty) {
          String fullName = '${_capitalize(brand)} ${_capitalize(model)}'
              .trim();
          if (fullName.isNotEmpty) return fullName;
        }
        return 'Android Phone';
      } else if (Platform.isMacOS) {
        // MacOS: scutil 获取友好用户电脑名
        var scResult = Process.runSync('scutil', ['--get', 'ComputerName']);
        if (scResult.exitCode == 0) {
          String name = scResult.stdout.toString().trim();
          if (name.isNotEmpty) return name;
        }
        return Platform.localHostname;
      } else {
        return Platform.localHostname;
      }
    } catch (_) {
      try {
        return Platform.localHostname;
      } catch (_) {
        return Platform.isAndroid
            ? 'Android Device'
            : Platform.isIOS
            ? 'iPhone'
            : 'Windows PC';
      }
    }
  }

  String _capitalize(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  // ================= WebSocket 持久双向通道状态回调 =================

  // WebSocket 握手建链成功，同步更新连接状态
  void _handleWebSocketConnected(String peerPid, String peerName, String peerOs, String peerAvatar) async {
    int devIdx = _discoveredDevices.indexWhere((element) => element.id == peerPid);
    String ip = '127.0.0.1';
    int port = 8889;
    if (devIdx != -1) {
      ip = _discoveredDevices[devIdx].ip;
      port = _discoveredDevices[devIdx].port;
    }

    DeviceInfo device = DeviceInfo(
      id: peerPid,
      name: peerName,
      ip: ip,
      port: port,
      os: peerOs,
      avatar: peerAvatar,
      isOnline: true,
      isConnected: true,
      lastSeen: DateTime.now(),
    );

    int connIdx = _connectedDevices.indexWhere((element) => element.id == peerPid);
    if (connIdx == -1) {
      _connectedDevices.add(device);
    } else {
      _connectedDevices[connIdx] = device;
    }

    // 【新增连接设备表】：双方连接 ok 的时候插入/更新 SQLite 物理数据库记录，标记 is_connected = 1
    await DbHelper.insertConnectedDevice(device, isConnected: true);
    // 重新加载连接历史记录清单以同步 UI
    _connectedDevicesHistory = await DbHelper.getConnectedDevices();

    // 顺便清理倒计时和挂起状态
    _incomingConnectionRequests.removeWhere((element) => element['senderPid'] == peerPid);
    _countdownTimers[peerPid]?.cancel();
    _countdownTimers.remove(peerPid);
    _countdownValues.remove(peerPid);

    notifyListeners();
  }

  // WebSocket 心跳超时或主动切断
  void _handleWebSocketDisconnected(String peerPid) async {
    final idx = _connectedDevices.indexWhere((element) => element.id == peerPid);
    if (idx != -1) {
      final name = _connectedDevices[idx].name;
      _lastDisconnectAlert = "$name设备断开了连接";
    }
    _connectedDevices.removeWhere((element) => element.id == peerPid);

    // 【新增】若对方主动断开或网络异常下线，将与其关联的所有正在传输或等待的项全部强制设为“失败”，并中断文件流
    for (var i = 0; i < _transferHistory.length; i++) {
      final item = _transferHistory[i];
      if (item.peerId == peerPid && (item.status == 'transferring' || item.status == 'waiting')) {
        _lanService?.cancelTransfer(item.id);
        _transferHistory[i] = item.copyWith(status: 'failed', progress: 0.0, speed: 0.0);
        await DbHelper.updateTransfer(_transferHistory[i]);
      }
    }

    // 【一方断开连接】：另一方修改状态为断开（is_connected = 0），允许以后重新发起连接
    await DbHelper.updateConnectedDeviceStatus(peerPid, isConnected: false);
    _connectedDevicesHistory = await DbHelper.getConnectedDevices();

    notifyListeners();
  }

  // 【物理删除连接设备关系历史记录】
  Future<void> deleteConnectedDeviceRecord(String peerPid) async {
    await DbHelper.deleteConnectedDevice(peerPid);
    _connectedDevicesHistory = await DbHelper.getConnectedDevices();
    notifyListeners();
  }

  // WebSocket 收到文件传输邀请
  void _handleWebSocketInvitationReceived(Map<String, dynamic> invitation) {
    String senderPid = invitation['senderPid'] ?? '';
    if (senderPid.isEmpty) return;

    _incomingInvitations.removeWhere((element) => element['senderPid'] == senderPid);
    _incomingInvitations.add(invitation);
    notifyListeners();
  }

  // WebSocket 收到对方对文件传输邀请的决策（同意/拒绝）
  void _handleWebSocketInvitationResponse(String senderPid, bool accepted) {
    final copiedItems = _outgoingInvitations[senderPid];
    if (copiedItems == null || copiedItems.isEmpty) return;

    if (accepted) {
      // 对方同意了，状态更新为传输中 (发送端不需要主动推送，对端会以 HTTP 安全下载自主拉取数据)
      for (var item in copiedItems) {
        _handleTransferProgress(item.id, 0.0, 0.0, 'transferring');
      }
    } else {
      // 对方拒绝，将待发送文件状态明确置为被拒绝 'rejected'
      for (var item in copiedItems) {
        _handleTransferProgress(item.id, 0.0, 0.0, 'rejected');
      }
    }
    _outgoingInvitations.remove(senderPid);
    notifyListeners();
  }

  // WebSocket 同步消息接收处理器，根据 PID 动态修改对端的头像、名称、端口并物理持久化
  void _handleSyncInfoReceived(String peerPid, String peerName, String peerAvatar, [int? tcpPort, int? wsPort]) async {
    bool hasChanged = false;

    // 1. 更新已连接内存列表
    int connIdx = _connectedDevices.indexWhere((element) => element.id == peerPid);
    if (connIdx != -1) {
      final oldDev = _connectedDevices[connIdx];
      final newName = peerName.isNotEmpty ? peerName : oldDev.name;
      final newAvatar = peerAvatar.isNotEmpty ? peerAvatar : oldDev.avatar;
      final newPort = tcpPort ?? oldDev.port;
      final newWsPort = wsPort ?? oldDev.wsPort;

      if (oldDev.name != newName || oldDev.avatar != newAvatar || oldDev.port != newPort || oldDev.wsPort != newWsPort) {
        _connectedDevices[connIdx] = oldDev.copyWith(
          name: newName,
          avatar: newAvatar,
          port: newPort,
          wsPort: newWsPort,
        );
        hasChanged = true;
      }
    }

    // 2. 更新已扫描内存列表
    int discIdx = _discoveredDevices.indexWhere((element) => element.id == peerPid);
    if (discIdx != -1) {
      final oldDev = _discoveredDevices[discIdx];
      final newName = peerName.isNotEmpty ? peerName : oldDev.name;
      final newAvatar = peerAvatar.isNotEmpty ? peerAvatar : oldDev.avatar;
      final newPort = tcpPort ?? oldDev.port;
      final newWsPort = wsPort ?? oldDev.wsPort;

      if (oldDev.name != newName || oldDev.avatar != newAvatar || oldDev.port != newPort || oldDev.wsPort != newWsPort) {
        _discoveredDevices[discIdx] = oldDev.copyWith(
          name: newName,
          avatar: newAvatar,
          port: newPort,
          wsPort: newWsPort,
        );
        hasChanged = true;
      }
    }

    // 3. 持久化到 SQLite 数据库中的连接历史，重载列表
    if (hasChanged) {
      final targetDevice = connIdx != -1 
          ? _connectedDevices[connIdx] 
          : (discIdx != -1 ? _discoveredDevices[discIdx] : null);
      if (targetDevice != null) {
        await DbHelper.insertConnectedDevice(targetDevice, isConnected: connIdx != -1);
        _connectedDevicesHistory = await DbHelper.getConnectedDevices();
      }
      notifyListeners();
    }
  }

  // 并发上传数更新持久化
  Future<void> updateMaxConcurrentUploads(int value) async {
    _maxConcurrentUploads = value;
    await DbHelper.saveSetting('max_concurrent_uploads', value.toString());
    notifyListeners();
  }

  // 并发下载数更新持久化，同时同步到服务层
  Future<void> updateMaxConcurrentDownloads(int value) async {
    _maxConcurrentDownloads = value;
    await DbHelper.saveSetting('max_concurrent_downloads', value.toString());
    if (_lanService != null) {
      _lanService!.maxConcurrentDownloads = value;
    }
    notifyListeners();
  }
}
