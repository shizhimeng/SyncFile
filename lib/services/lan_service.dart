import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import '../models/device_info.dart';
import '../models/transfer_item.dart';
import 'db_helper.dart';

class LanService {
  // 端口配置
  static const int udpPort = 8888;
  int tcpPort = 8889;
  int wsPort = 8890;

  RawDatagramSocket? _udpSocket;
  ServerSocket? _tcpServer;
  Timer? _broadcastTimer;

  // WebSocket 服务端和通道状态管理
  HttpServer? _wsServer;
  final Map<String, WebSocket> _activeWebSockets = {};
  final Map<String, Timer> _pingTimers = {};
  final Map<String, Timer> _syncTimers = {};
  final Map<String, DateTime> _lastPingReceived = {};
  final Set<String> _cancelledItemIds = {};
  
  // 私有 Socket 管理映射表，用于响应控制流套接字握手（解耦）
  final Map<String, Socket> _invitationSockets = {};
  final Map<String, Socket> _connectionRequestSockets = {};
  
  // 各种控制器与回调
  final String myPid;
  String myName;
  String myAvatar;
  
  // 并发下载数限制
  int maxConcurrentDownloads = 3;
  
  // 发现新设备的回调
  void Function(DeviceInfo device)? onDeviceDiscovered;
  // 设备下线回调
  void Function(String pid)? onDeviceOffline;
  // 收到传输邀请的回调（已解耦，不向 Controller 暴露 Socket）
  void Function(Map<String, dynamic> invitation)? onInvitationReceived;
  // 收到物理连接申请的回调（已解耦，不向 Controller 暴露 Socket）
  void Function(Map<String, dynamic> request)? onConnectionRequestReceived;
  // 传输进度更新回调
  void Function(String itemId, double progress, double speed, String status)? onTransferProgress;

  // WebSocket 各种持久通道的回调
  void Function(String pid, String name, String os, String avatar)? onWebSocketConnected;
  void Function(String pid)? onWebSocketDisconnected;
  void Function(Map<String, dynamic> invitation)? onWebSocketInvitationReceived;
  void Function(String senderPid, bool accepted)? onWebSocketInvitationResponse;
  void Function(String pid, String name, String avatar, int? tcpPort, int? wsPort)? onSyncInfoReceived;

  LanService({
    required this.myPid,
    required this.myName,
    required this.myAvatar,
    this.onDeviceDiscovered,
    this.onDeviceOffline,
    this.onInvitationReceived,
    this.onConnectionRequestReceived,
    this.onTransferProgress,
    this.onWebSocketConnected,
    this.onWebSocketDisconnected,
    this.onWebSocketInvitationReceived,
    this.onWebSocketInvitationResponse,
    this.onSyncInfoReceived,
  });

  // 1. 开启 UDP 设备发现与广播
  Future<void> startDiscovery() async {
    try {
      // 绑定 UDP 监听任意 IP 端口 8888，支持端口和地址复用，确保跨多网口设备通信畅通
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 
        udpPort,
        reuseAddress: true,
        reusePort: false, // 彻底关闭此参数。部分安卓系统底座（Linux 3.9以下）和 Windows 均不支持 reusePort 复用，关闭以保障极致兼容性
      );
      _udpSocket!.broadcastEnabled = true; // 允许广播

      if (kDebugMode) {
        print("UDP Discovery Service started on port $udpPort");
      }

      // 监听入站 UDP 广播包
      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg = _udpSocket!.receive();
          if (dg != null) {
            try {
              String dataStr = utf8.decode(dg.data);
              Map<String, dynamic> data = jsonDecode(dataStr);
              
              // 过滤掉本设备的广播
              if (data['pid'] != null && data['pid'] != myPid) {
                DeviceInfo device = DeviceInfo.fromJson(data, dg.address.address);
                onDeviceDiscovered?.call(device);
              }
            } catch (e) {
              if (kDebugMode) print("Error parsing UDP broadcast packet: $e");
            }
          }
        }
      });

      // 开启定时广播定时器 (每3秒向局域网广播本端信息)
      _broadcastTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
        broadcastPresence();
      });
      
      // 启动时立即广播一次
      broadcastPresence();
    } catch (e) {
      if (kDebugMode) print("Failed to start UDP Discovery: $e");
    }
  }

  // 发送本端广播信息
  void broadcastPresence() async {
    if (_udpSocket == null) return;
    try {
      String os = Platform.isWindows
          ? 'windows'
          : Platform.isIOS
              ? 'ios'
              : Platform.isAndroid
                  ? 'android'
                  : Platform.isMacOS
                      ? 'macos'
                      : 'linux';

      Map<String, dynamic> payload = {
        'pid': myPid,
        'name': myName,
        'port': tcpPort,
        'wsPort': wsPort,
        'os': os,
      };

      String jsonStr = jsonEncode(payload);
      List<int> bytes = utf8.encode(jsonStr);

      // 1. 发送到全局受限广播地址 (255.255.255.255)
      _udpSocket!.send(
        bytes,
        InternetAddress('255.255.255.255'),
        udpPort,
      );

      // 2. 额外向本网段的特定广播地址（如 192.168.x.255）发送广播以突破 Windows 防火墙和某些路由器的单播转换限制
      try {
        final localIp = await getLocalIp();
        if (localIp != null && localIp.contains('.')) {
          final parts = localIp.split('.');
          if (parts.length == 4) {
            final subnetBroadcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            _udpSocket!.send(
              bytes,
              InternetAddress(subnetBroadcast),
              udpPort,
            );
          }
        }
      } catch (_) {}

    } catch (e) {
      if (kDebugMode) print("Error sending UDP broadcast: $e");
    }
  }

  // 停止发现服务
  void stopDiscovery() {
    _broadcastTimer?.cancel();
    _udpSocket?.close();
    _udpSocket = null;
  }

  // 2. 开启 TCP 接收监听服务端
  Future<void> startTcpServer() async {
    while (true) {
      try {
        _tcpServer = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
        if (kDebugMode) {
          print("TCP File Sharing Server started on port $tcpPort");
        }

        _tcpServer!.listen((Socket clientSocket) {
          _handleIncomingConnection(clientSocket);
        });
        break; // 绑定成功，退出循环
      } catch (e) {
        if (kDebugMode) {
          print(" [SyncFile端口日志]: TCP 端口 $tcpPort 被占用，正在自动递增重试... 错误: $e");
        }
        tcpPort++;
        if (tcpPort > 65535) {
          if (kDebugMode) print(" [SyncFile端口日志]: TCP 监听启动失败：端口溢出！");
          break;
        }
      }
    }
  }

  // 处理入站 TCP 握手/连接
  void _handleIncomingConnection(Socket socket) {
    StringBuffer buffer = StringBuffer();
    StreamSubscription? subscription;

    subscription = socket.listen((List<int> data) {
      buffer.write(utf8.decode(data, allowMalformed: true));
      String content = buffer.toString();

      // 我们使用换行符 '\n' 或 JSON 解析成功作为协议头结束标志
      if (content.contains('\n') || (content.startsWith('{') && content.endsWith('}'))) {
        subscription?.cancel(); // 协议握手包读取完毕
        
        try {
          // 清洗数据，防止多余空格
          String cleanJson = content.trim();
          Map<String, dynamic> invitation = jsonDecode(cleanJson);
          
          String action = invitation['action'] ?? '';
          final String senderPid = invitation['senderPid'] ?? '';
          if (action == 'connect_request') {
            invitation['senderIp'] = socket.remoteAddress.address;
            invitation['senderPort'] = socket.remotePort;
            if (senderPid.isNotEmpty) {
              _connectionRequestSockets[senderPid] = socket;
            }
            // 触发连接申请握手回调
            onConnectionRequestReceived?.call(invitation);
          } else {
            if (senderPid.isNotEmpty) {
              _invitationSockets[senderPid] = socket;
            }
            // 触发传输邀请回调
            onInvitationReceived?.call(invitation);
          }
        } catch (e) {
          if (kDebugMode) print("TCP Handshake error parsing JSON: $e");
          socket.write(jsonEncode({'status': 'error', 'message': 'Protocol Error'}));
          socket.close();
        }
      }
    }, onError: (e) {
      if (kDebugMode) print("Socket listen error: $e");
      socket.close();
    });
  }

  // ================= HTTP 文件分发下载引擎 (Sender Server Side) =================

  // 待下载文件的内存映射：itemId -> { "filePath": "/path/to/file", "token": "xyz" }
  final Map<String, Map<String, String>> _downloadablePool = {};

  void registerDownloadableFile(String itemId, String filePath, String token) {
    _downloadablePool[itemId] = {
      'filePath': filePath,
      'token': token,
    };
    if (kDebugMode) {
      print("Registered downloadable file for item $itemId, token: $token");
    }
  }

  void unregisterDownloadableFile(String itemId) {
    _downloadablePool.remove(itemId);
  }

  // 生成高强度安全临时下载 Token
  String generateSecureToken() {
    final rand = Random.secure();
    final bytes = List<int>.generate(16, (i) => rand.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '').replaceAll('+', '').replaceAll('/', '');
  }

  // 获取本机局域网内的真实活动 IPv4 地址 (自动避开回环与虚拟网卡)
  Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (!addr.isLoopback &&
              (addr.address.startsWith('192.168.') ||
               addr.address.startsWith('10.') ||
               addr.address.startsWith('172.'))) {
            return addr.address;
          }
        }
      }
      if (interfaces.isNotEmpty && interfaces.first.addresses.isNotEmpty) {
        return interfaces.first.addresses.first.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  // HTTP 文件下载请求处理入口 (GET /download?id=xxx&token=yyy)
  void _handleHttpDownload(HttpRequest request) async {
    if (request.method != 'GET') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      request.response.close();
      return;
    }

    final query = request.uri.queryParameters;
    final String itemId = query['id'] ?? '';
    final String token = query['token'] ?? '';

    // 校验 Token 及文件是否存在于可下载池中
    final fileInfo = _downloadablePool[itemId];
    if (fileInfo == null || fileInfo['token'] != token) {
      request.response.statusCode = HttpStatus.forbidden;
      request.response.headers.contentType = ContentType.text;
      request.response.write('403 Forbidden: Invalid Token or ID');
      request.response.close();
      return;
    }

    final String filePath = fileInfo['filePath']!;
    final File file = File(filePath);
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.text;
      request.response.write('404 Not Found: File does not exist');
      request.response.close();
      return;
    }

    try {
      final int fileSize = await file.length();
      final String fileName = file.uri.pathSegments.last;

      // 解析 Range 请求头，用于支持断点续传（例如 Range: bytes=1000-）
      int start = 0;
      final String? rangeHeader = request.headers.value('range');
      bool isRange = false;
      if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
        final parts = rangeHeader.substring(6).split('-');
        if (parts.isNotEmpty) {
          final parsedStart = int.tryParse(parts[0]);
          if (parsedStart != null && parsedStart >= 0 && parsedStart < fileSize) {
            start = parsedStart;
            isRange = true;
          }
        }
      }

      // 填充标准 HTTP 分流响应头
      if (isRange) {
        request.response.statusCode = HttpStatus.partialContent; // 206 Partial Content
        request.response.headers.set('content-range', 'bytes $start-${fileSize - 1}/$fileSize');
        request.response.headers.contentLength = fileSize - start;
      } else {
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentLength = fileSize;
      }

      request.response.headers.chunkedTransferEncoding = false;
      request.response.headers.contentType = ContentType.parse('application/octet-stream');
      request.response.headers.set(
        'content-disposition',
        'attachment; filename="${Uri.encodeComponent(fileName)}"',
      );

      // 流式读取物理文件并逐步分流回写，实时触发发送端的进度通知
      int sentBytes = start;
      int sessionSentBytes = 0;
      final Stream<List<int>> fileStream = file.openRead(start);
      final DateTime startTime = DateTime.now();
      int lastUpdateTime = 0;

      await for (List<int> chunk in fileStream) {
        if (_cancelledItemIds.contains(itemId)) {
          if (kDebugMode) print("HTTP Download cancelled by sender/receiver for item: $itemId");
          break;
        }
        request.response.add(chunk);
        await request.response.flush();
        sentBytes += chunk.length;
        sessionSentBytes += chunk.length;

        // 计算进度百分比
        double progress = fileSize > 0 ? (sentBytes / fileSize) : 1.0;
        // 计算瞬时速率 (仅依据当前 session 实际传输的字节数进行计算)
        double durationSec = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
        double speed = durationSec > 0 ? (sessionSentBytes / (1024.0 * 1024.0)) / durationSec : 0.0;

        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastUpdateTime >= 1000) {
          onTransferProgress?.call(itemId, progress, speed, 'transferring');
          lastUpdateTime = now;
        }
      }

      if (_cancelledItemIds.contains(itemId)) {
        try {
          await request.response.close();
        } catch (_) {}
        onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');
        return;
      }

      await request.response.close();
      onTransferProgress?.call(itemId, 1.0, 0.0, 'success');
      if (kDebugMode) print("Successfully served HTTP download for item: $itemId");
    } catch (e) {
      if (kDebugMode) print("Error serving HTTP download: $e");
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.close();
      } catch (_) {}
    }
  }

  // ================= HTTP 流式下载拉取引擎 (Receiver Client Side) =================

  // 接收端通过 HTTP 协议从发送端的 HTTP 服务端并发拉取下载文件 (支持队列并发数限制)
  void startDownloadingItems(List<dynamic> items, String saveDir) async {
    if (items.isEmpty) return;

    final HttpClient httpClient = HttpClient();
    // 设置基础连接超时
    httpClient.connectionTimeout = const Duration(seconds: 5);

    int activeCount = 0;
    int index = 0;

    void startNext() async {
      if (index >= items.length) {
        if (activeCount == 0) {
          httpClient.close();
        }
        return;
      }

      final item = items[index++];
      activeCount++;

      try {
        await _downloadSingleItem(httpClient, item, saveDir);
      } catch (e) {
        if (kDebugMode) print("Download item error: $e");
      } finally {
        activeCount--;
        startNext();
      }
    }

    // 根据配置的最大下载并发数启动多路工人工作
    final int limit = min(maxConcurrentDownloads, items.length);
    for (int i = 0; i < limit; i++) {
      startNext();
    }
  }

  Future<void> _downloadSingleItem(HttpClient httpClient, dynamic item, String saveDir) async {
    final String itemId = item['id'] ?? '';
    if (_cancelledItemIds.contains(itemId)) {
      onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');
      return;
    }
    final String fileName = item['name'] ?? 'downloaded_file';
    final int totalSize = item['size'] ?? 0;
    final String downloadUrl = item['downloadUrl'] ?? '';
    final String type = item['type'] ?? 'file';
    final String? content = item['content'];

    // 文本且不是以物理文件传输的，直接视为成功，无需通过网络下载
    if (type == 'text' && (content != null && content.isNotEmpty)) {
      onTransferProgress?.call(itemId, 1.0, 0.0, 'success');
      return;
    }

    if (downloadUrl.isEmpty) {
      onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');
      return;
    }

    onTransferProgress?.call(itemId, 0.0, 0.0, 'transferring');

    try {
      // 创建下载保存目录
      final Directory dir = Directory(saveDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      String savePath = "$saveDir/$fileName";
      File file = File(savePath);
      int localSize = 0;
      bool isResume = false;

      final String senderPid = item['senderPid'] ?? '';
      bool hasFailedOverlap = false;
      try {
        final history = await DbHelper.getTransferHistory();
        hasFailedOverlap = history.any((element) =>
            element.name == fileName &&
            element.peerId == senderPid &&
            element.direction == 'received' &&
            element.status.startsWith('failed'));
      } catch (e) {
        if (kDebugMode) print("Error querying history for resume overlap: $e");
      }

      if (await file.exists()) {
        localSize = await file.length();
        if (localSize < totalSize && localSize > 0 && hasFailedOverlap) {
          isResume = true;
          print(" [SyncFile连接日志]: 检出相同发送方且文件名重叠的未完成传输记录，本地已下载 $localSize 字节，将发起 HTTP 断点续传，从偏移量 $localSize 继续下载。");
        }
      }
      // 自动规避重名冲突
      int counter = 1;
      while (!isResume && await file.exists()) {
        String baseName = fileName;
        String ext = '';
        int lastDot = fileName.lastIndexOf('.');
        if (lastDot != -1) {
          baseName = fileName.substring(0, lastDot);
          ext = fileName.substring(lastDot);
        }
        savePath = "$saveDir/${baseName}_($counter)$ext";
        file = File(savePath);
        counter++;
      }

      // 输出明确的本地保存路径日志
      print(" [SyncFile连接日志]: 文件下载开始。本地保存的目标物理路径为: '$savePath'");

      // 发起流式 HTTP GET 下载请求
      final HttpClientRequest request = await httpClient.getUrl(Uri.parse(downloadUrl));
      if (isResume) {
        request.headers.set('range', 'bytes=$localSize-');
      }
      final HttpClientResponse response = await request.close().timeout(const Duration(seconds: 10));

      if (response.statusCode != HttpStatus.ok && response.statusCode != HttpStatus.partialContent) {
        print(" [SyncFile连接日志]: 文件 $fileName 下载失败，发送端 HTTP 服务器返回了错误状态码: ${response.statusCode}");
        onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');
        return;
      }

      // 只有当对方服务器返回 206 时才真正以 append 模式续写文件，否则以重新写入覆盖写
      final bool actualResume = isResume && response.statusCode == HttpStatus.partialContent;
      final IOSink fileSink = actualResume
          ? file.openWrite(mode: FileMode.writeOnlyAppend)
          : file.openWrite();
      int receivedBytes = actualResume ? localSize : 0;
      int sessionReceivedBytes = 0;
      final DateTime startTime = DateTime.now();
      int lastUpdateTime = 0;

      Timer? timeoutTimer;
      bool isTimedOut = false;

      // 10秒文件无动静看张狗超时监控
      void resetTimeoutTimer() {
        timeoutTimer?.cancel();
        timeoutTimer = Timer(const Duration(seconds: 10), () async {
          isTimedOut = true;
          timeoutTimer?.cancel();
          print(" [SyncFile连接日志]: 文件传输超时 (检测到连续 10 秒没有任何字节数据流动)，已强制终止任务: '$fileName'");
          try {
            await fileSink.close();
            // 强行终止 HTTP Socket 链路
            response.detachSocket().then((socket) => socket.close());
          } catch (_) {}
          
          onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');
          
          // 超时立即通过 WebSocket 信道告知发送端
          final String senderPid = item['senderPid'] ?? '';
          if (senderPid.isNotEmpty) {
            sendTransferTimeoutOverWs(senderPid, itemId);
          }
        });
      }

      // 重置并初始化超时监控
      resetTimeoutTimer();

      // 流式读取 HTTP 响应字节块
      await for (List<int> chunk in response) {
        // 如果已超时则中断
        if (isTimedOut) break;

        // 【新增：手动终止传输检查】如果该文件 ID 被标记为已取消，立即执行清理并退出
        if (_cancelledItemIds.contains(itemId)) {
          print(" [SyncFile连接日志]: 接收端文件传输已被手动取消: '$fileName'");
          try {
            await fileSink.close();
            response.detachSocket().then((socket) => socket.close());
            if (await file.exists()) {
              await file.delete();
            }
          } catch (_) {}
          onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');
          return;
        }

        // 有字节数据流过，立即重置 10 秒超时监控定时器
        resetTimeoutTimer();

        // 写入本地文件系统
        fileSink.add(chunk);
        receivedBytes += chunk.length;
        sessionReceivedBytes += chunk.length;

        // 计算实时进度百分比
        double progress = totalSize > 0 ? (receivedBytes / totalSize) : 1.0;
        // 计算瞬时下载速率 (MB/s) (仅使用当前 session 实际传输的字节数)
        double durationSec = DateTime.now().difference(startTime).inMilliseconds / 1000.0;
        double speed = durationSec > 0 ? (sessionReceivedBytes / (1024.0 * 1024.0)) / durationSec : 0.0;

        // 通知控制器更新传输面板进度 (每 1000ms 节流通知一次，减少 Isolate 调度引起的页面切换卡顿)
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastUpdateTime >= 1000) {
          onTransferProgress?.call(itemId, progress, speed, 'transferring');
          lastUpdateTime = now;
        }
      }

      timeoutTimer?.cancel();
      if (!isTimedOut) {
        await fileSink.flush();
        await fileSink.close();
        onTransferProgress?.call(itemId, 1.0, 0.0, 'success');
        
        print(" [SyncFile连接日志]: 恭喜！文件下载已顺利完成。文件大小: $receivedBytes 字节。最终物理路径: '$savePath'");

        // 【接收方成功后，主动发送 WebSocket 请求告知发送方该文件接收成功】
        final String senderPid = item['senderPid'] ?? '';
        if (senderPid.isNotEmpty) {
          sendTransferSuccessOverWs(senderPid, itemId);
        }
      }
    } catch (e) {
      print(" [SyncFile连接日志]: 警告！在 HTTP 流式拉取下载 item $itemId 时发生致命异常，错误信息: $e");
      onTransferProgress?.call(itemId, 0.0, 0.0, 'failed');

      // 发送失败也协同通知发送方超时/出错
      final String senderPid = item['senderPid'] ?? '';
      if (senderPid.isNotEmpty) {
        sendTransferTimeoutOverWs(senderPid, itemId);
      }
    }
  }

  // 异步拉取对端的设备基础信息，用于扫描端的严苛校验准入
  Future<DeviceInfo?> fetchDeviceInfo(String ip, String targetPid, [int? targetWsPort]) async {
    final HttpClient httpClient = HttpClient();
    httpClient.connectionTimeout = const Duration(seconds: 3);
    try {
      final int activeWsPort = targetWsPort ?? wsPort;
      final HttpClientRequest request = await httpClient.getUrl(
        Uri.parse('http://$ip:$activeWsPort/info?pid=$targetPid'),
      );
      final HttpClientResponse response = await request.close().timeout(const Duration(seconds: 3));
      if (response.statusCode == HttpStatus.ok) {
        final String replyStr = await response.transform(utf8.decoder).join();
        final Map<String, dynamic> reply = jsonDecode(replyStr);
        if (reply['status'] == 'success' && reply['pid'] == targetPid) {
          return DeviceInfo(
            id: reply['pid'],
            name: reply['name'],
            ip: ip,
            port: reply['port'] ?? tcpPort,
            wsPort: activeWsPort,
            os: reply['os'] ?? 'windows',
            avatar: reply['avatar'],
            isOnline: true,
            isConnected: false,
            lastSeen: DateTime.now(),
          );
        }
      }
    } catch (e) {
      if (kDebugMode) print("fetchDeviceInfo error for $ip: $e");
    } finally {
      httpClient.close();
    }
    return null;
  }

  // 3.1 发送双向连接安全请求并异步等待确认
  Future<bool> sendConnectionRequest({
    required DeviceInfo device,
    required String senderOs,
    required String senderAvatar,
    required void Function(bool accepted) onDecision,
  }) async {
    Socket? socket;
    try {
      // 1. 建立与目标的 TCP 套接字连接
      socket = await Socket.connect(device.ip, device.port, timeout: const Duration(seconds: 5));
      
      // 2. 发送 connect_request 协议包
      Map<String, dynamic> req = {
        'action': 'connect_request',
        'senderPid': myPid,
        'senderName': myName,
        'senderOs': senderOs,
        'senderAvatar': senderAvatar,
      };
      
      socket.write(jsonEncode(req) + '\n');
      await socket.flush();
      
      // 3. 等待对端的握手接受/拒绝回应
      StringBuffer responseBuffer = StringBuffer();
      await for (List<int> chunk in socket) {
        responseBuffer.write(utf8.decode(chunk));
        String res = responseBuffer.toString().trim();
        
        try {
          Map<String, dynamic> reply = jsonDecode(res);
          bool isAccepted = reply['status'] == 'accepted';
          onDecision(isAccepted);
          return isAccepted;
        } catch (e) {
          // 等待数据接收完毕
        }
      }
      return false;
    } catch (e) {
      if (kDebugMode) print("Connection request failed: $e");
      onDecision(false);
      return false;
    } finally {
      socket?.close();
    }
  }

  // 4. WebSocket 与 HTTP 下载服务端方法实现
  Future<void> startWebSocketServer() async {
    if (_wsServer != null) return;
    while (true) {
      try {
        _wsServer = await HttpServer.bind(InternetAddress.anyIPv4, wsPort);
        if (kDebugMode) {
          print("WebSocket & HTTP Download Server started on port $wsPort");
        }
        _wsServer!.listen((HttpRequest request) {
          if (WebSocketTransformer.isUpgradeRequest(request)) {
            WebSocketTransformer.upgrade(request).then((WebSocket ws) {
              _handleIncomingWebSocket(ws);
            });
          } else if (request.method == 'GET' && request.uri.path == '/download') {
            _handleHttpDownload(request);
          } else if (request.method == 'GET' && request.uri.path == '/info') {
            _handleHttpInfo(request);
          } else {
            request.response.statusCode = HttpStatus.forbidden;
            request.response.close();
          }
        });
        break; // 绑定成功，退出循环
      } catch (e) {
        if (kDebugMode) {
          print(" [SyncFile端口日志]: WebSocket 端口 $wsPort 被占用，正在自动递增重试... 错误: $e");
        }
        wsPort++;
        if (wsPort > 65535) {
          if (kDebugMode) print(" [SyncFile端口日志]: WebSocket 监听启动失败：端口溢出！");
          break;
        }
      }
    }
  }

  // 处理获取本端设备信息的 HTTP 请求，带 PID 校验
  void _handleHttpInfo(HttpRequest request) async {
    final query = request.uri.queryParameters;
    final String targetPid = query['pid'] ?? '';
    
    if (targetPid == myPid) {
      request.response.statusCode = HttpStatus.ok;
      request.response.headers.contentType = ContentType.json;
      String os = Platform.isWindows
          ? 'windows'
          : Platform.isIOS
              ? 'ios'
              : Platform.isAndroid
                  ? 'android'
                  : Platform.isMacOS
                      ? 'macos'
                      : 'linux';
      Map<String, dynamic> info = {
        'status': 'success',
        'pid': myPid,
        'name': myName,
        'avatar': myAvatar,
        'os': os,
        'port': tcpPort,
      };
      request.response.write(jsonEncode(info));
    } else {
      request.response.statusCode = HttpStatus.badRequest;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({'status': 'error', 'message': 'PID mismatch'}));
    }
    await request.response.close();
  }

  void _handleIncomingWebSocket(WebSocket ws) {
    late StreamSubscription sub;
    sub = ws.listen((data) {
      try {
        Map<String, dynamic> msg = jsonDecode(data);
        if (msg['action'] == 'ws_handshake') {
          String peerPid = msg['pid'] ?? '';
          String peerName = msg['name'] ?? '';
          String peerOs = msg['os'] ?? '';
          String peerAvatar = msg['avatar'] ?? '';
          if (peerPid.isNotEmpty) {
            _initWebSocketChannel(peerPid, ws, peerName, peerOs, peerAvatar, sub);
            // 回复客户端握手
            ws.add(jsonEncode({
              'action': 'ws_handshake_reply',
              'pid': myPid,
              'name': myName,
              'os': Platform.isWindows
                  ? 'windows'
                  : Platform.isIOS
                      ? 'ios'
                      : Platform.isAndroid
                          ? 'android'
                          : 'macos',
              'avatar': myAvatar,
            }));
          }
        }
      } catch (e) {
        if (kDebugMode) print("WebSocket incoming handle error: $e");
      }
    }, onError: (e) {
      ws.close();
    });
  }

  Future<bool> connectToWebSocket(DeviceInfo device) async {
    try {
      WebSocket ws = await WebSocket.connect('ws://${device.ip}:${device.wsPort}')
          .timeout(const Duration(seconds: 5));
      // 发送握手
      String os = Platform.isWindows
          ? 'windows'
          : Platform.isIOS
              ? 'ios'
              : Platform.isAndroid
                  ? 'android'
                  : 'macos';
      ws.add(jsonEncode({
        'action': 'ws_handshake',
        'pid': myPid,
        'name': myName,
        'os': os,
        'avatar': myAvatar,
      }));

      Completer<bool> completer = Completer();
      late StreamSubscription sub;
      sub = ws.listen((data) {
        try {
          Map<String, dynamic> msg = jsonDecode(data);
          if (msg['action'] == 'ws_handshake_reply') {
            String peerPid = msg['pid'] ?? '';
            String peerName = msg['name'] ?? '';
            String peerOs = msg['os'] ?? '';
            String peerAvatar = msg['avatar'] ?? '';
            if (peerPid == device.id) {
              _initWebSocketChannel(peerPid, ws, peerName, peerOs, peerAvatar, sub);
              completer.complete(true);
            }
          }
        } catch (e) {
          sub.cancel();
          ws.close();
          completer.complete(false);
        }
      }, onError: (e) {
        sub.cancel();
        ws.close();
        completer.complete(false);
      });

      return await completer.future;
    } catch (e) {
      if (kDebugMode) print("Failed to connect to WebSocket: $e");
      return false;
    }
  }

  void _initWebSocketChannel(
    String peerPid,
    WebSocket ws,
    String peerName,
    String peerOs,
    String peerAvatar,
    StreamSubscription subscription,
  ) {
    // 清理可能已有的通道
    _activeWebSockets[peerPid]?.close();
    _pingTimers[peerPid]?.cancel();

    _activeWebSockets[peerPid] = ws;
    _lastPingReceived[peerPid] = DateTime.now();

    // 触发控制器回调，更新连接列表
    onWebSocketConnected?.call(peerPid, peerName, peerOs, peerAvatar);

    // 开启 3 秒的 Ping 心跳包发射定时器 (同时同步当前的 tcpPort 和 wsPort 供对方感知)
    _pingTimers[peerPid] = Timer.periodic(const Duration(seconds: 3), (timer) {
      if (_activeWebSockets[peerPid] != null) {
        try {
          _activeWebSockets[peerPid]!.add(jsonEncode({
            'action': 'ping',
            'tcpPort': tcpPort,
            'wsPort': wsPort,
          }));
        } catch (e) {
          _handleWsDisconnect(peerPid);
        }
      }

      // 超时断线判定：如果 9 秒内（三次心跳）未收到任何网络响应包，判定断线
      final lastSeen = _lastPingReceived[peerPid];
      if (lastSeen != null &&
          DateTime.now().difference(lastSeen).inSeconds > 9) {
        if (kDebugMode) print("Heartbeat timeout for $peerPid");
        _handleWsDisconnect(peerPid);
      }
    });

    // 动态重定向现有的 StreamSubscription 的回调函数
    subscription.onData((data) {
      try {
        Map<String, dynamic> msg = jsonDecode(data);
        String action = msg['action'] ?? '';

        // 更新最后心跳时间戳
        _lastPingReceived[peerPid] = DateTime.now();

        if (action == 'ping') {
          // 收到 ping，感知对方的最新接口变动并回传本端最新的 tcpPort 和 wsPort
          int? peerTcpPort = msg['tcpPort'];
          int? peerWsPort = msg['wsPort'];
          if (peerTcpPort != null && peerWsPort != null) {
            onSyncInfoReceived?.call(peerPid, '', '', peerTcpPort, peerWsPort);
          }
          ws.add(jsonEncode({
            'action': 'pong',
            'tcpPort': tcpPort,
            'wsPort': wsPort,
          }));
        } else if (action == 'pong') {
          // 收到 pong 证明对方存活，同样解析感知对方的接口变动
          int? peerTcpPort = msg['tcpPort'];
          int? peerWsPort = msg['wsPort'];
          if (peerTcpPort != null && peerWsPort != null) {
            onSyncInfoReceived?.call(peerPid, '', '', peerTcpPort, peerWsPort);
          }
        } else if (action == 'disconnect') {
          _handleWsDisconnect(peerPid);
        } else if (action == 'invite') {
          onWebSocketInvitationReceived?.call(msg['invitation']);
        } else if (action == 'invite_response') {
          onWebSocketInvitationResponse?.call(
            peerPid,
            msg['accepted'] ?? false,
          );
        } else if (action == 'transfer_timeout') {
          // 收到传输超时，强行将该项目置为失败
          onTransferProgress?.call(msg['itemId'] ?? '', 0.0, 0.0, 'failed');
        } else if (action == 'transfer_success') {
          // 收到接收方成功的反馈通知，强行将该项目置为成功
          onTransferProgress?.call(msg['itemId'] ?? '', 1.0, 0.0, 'success');
        } else if (action == 'transfer_cancel') {
          // 收到对方主动终止传输的通知
          final itemId = msg['itemId'] ?? '';
          if (itemId.isNotEmpty) {
            _cancelledItemIds.add(itemId);
            onTransferProgress?.call(itemId, 0.0, 0.0, 'failed:cancelled_by_peer');
          }
        } else if (action == 'sync_info') {
          onSyncInfoReceived?.call(
            peerPid,
            msg['name'] ?? '',
            msg['avatar'] ?? '',
            msg['tcpPort'],
            msg['wsPort'],
          );
        }
      } catch (e) {
        if (kDebugMode) print("Error parsing WS packet: $e");
      }
    });

    subscription.onError((e) {
      _handleWsDisconnect(peerPid);
    });

    subscription.onDone(() {
      _handleWsDisconnect(peerPid);
    });
  }

  void _handleWsDisconnect(String peerPid) {
    _pingTimers[peerPid]?.cancel();
    _pingTimers.remove(peerPid);
    _syncTimers[peerPid]?.cancel();
    _syncTimers.remove(peerPid);
    _activeWebSockets[peerPid]?.close();
    _activeWebSockets.remove(peerPid);
    _lastPingReceived.remove(peerPid);

    onWebSocketDisconnected?.call(peerPid);
  }

  void sendInvitationOverWs(String peerPid, Map<String, dynamic> invitation) {
    final ws = _activeWebSockets[peerPid];
    if (ws != null) {
      ws.add(jsonEncode({
        'action': 'invite',
        'invitation': invitation,
      }));
    }
  }

  void sendInvitationResponseOverWs(String peerPid, bool accepted) {
    final ws = _activeWebSockets[peerPid];
    if (ws != null) {
      ws.add(jsonEncode({
        'action': 'invite_response',
        'accepted': accepted,
      }));
    }
  }

  void sendTransferTimeoutOverWs(String peerPid, String itemId) {
    final ws = _activeWebSockets[peerPid];
    if (ws != null) {
      try {
        ws.add(jsonEncode({
          'action': 'transfer_timeout',
          'itemId': itemId,
        }));
      } catch (_) {}
    }
  }

  void sendTransferSuccessOverWs(String peerPid, String itemId) {
    final ws = _activeWebSockets[peerPid];
    if (ws != null) {
      try {
        ws.add(jsonEncode({
          'action': 'transfer_success',
          'itemId': itemId,
        }));
      } catch (_) {}
    }
  }

  void cancelTransfer(String itemId, {String? peerPid}) {
    _cancelledItemIds.add(itemId);
    if (peerPid != null) {
      sendTransferCancelOverWs(peerPid, itemId);
    }
  }

  void sendTransferCancelOverWs(String peerPid, String itemId) {
    final ws = _activeWebSockets[peerPid];
    if (ws != null) {
      try {
        ws.add(jsonEncode({
          'action': 'transfer_cancel',
          'itemId': itemId,
        }));
      } catch (_) {}
    }
  }

  /// 【已解耦】响应物理连接申请（同意/拒绝），并安全关闭入站 TCP 握手 Socket
  Future<void> respondToConnectionRequest(String senderPid, bool accept) async {
    final socket = _connectionRequestSockets.remove(senderPid);
    if (socket != null) {
      try {
        socket.write(jsonEncode({'status': accept ? 'accepted' : 'rejected'}));
        await socket.flush();
      } catch (e) {
        if (kDebugMode) {
          print(" [SyncFile连接日志]: 发送物理连接审批响应数据包失败: $e");
        }
      } finally {
        socket.close();
      }
    }
  }

  /// 【已解耦】响应局域网传输邀请，并安全关闭入站 TCP 握手 Socket（支持 WebSocket 回应降级）
  Future<void> respondToInvitation(String senderPid, bool accept) async {
    final socket = _invitationSockets.remove(senderPid);
    if (socket != null) {
      try {
        socket.write(jsonEncode({'status': accept ? 'accepted' : 'rejected'}));
        await socket.flush();
      } catch (e) {
        if (kDebugMode) {
          print(" [SyncFile连接日志]: 发送传输邀请审批响应数据包失败: $e");
        }
      } finally {
        socket.close();
      }
    } else {
      // 兼容主流 WebSocket 信道传输邀请的回应
      sendInvitationResponseOverWs(senderPid, accept);
    }
  }

  void disconnectWsChannel(String peerPid) {
    final ws = _activeWebSockets[peerPid];
    if (ws != null) {
      try {
        ws.add(jsonEncode({'action': 'disconnect'}));
      } catch (_) {}
      _handleWsDisconnect(peerPid);
    }
  }

  // 关闭所有连接与服务器定时器
  void dispose() {
    stopDiscovery();
    _tcpServer?.close();
    _wsServer?.close();
    _activeWebSockets.forEach((key, ws) => ws.close());
    _pingTimers.forEach((key, timer) => timer.cancel());
    _syncTimers.forEach((key, timer) => timer.cancel());
    _syncTimers.clear();
  }
}
