/// [DeviceInfo] 数据模型类
/// 用于表示局域网（LAN）中发现的对端活跃节点。
/// 该类封装了对端设备的网络寻址参数（如 IP 地址、TCP 端口号）以及本应用特有的
/// PID 身份标识别符、操作系统类型和连接状态，支持与 JSON 的相互转化（常用于 UDP 心跳广播及对等协商）。
class DeviceInfo {
  /// 设备唯一的物理/随机 PID（例如：ZEC-94A2-X8B1），在应用初次引导时自动生成，只读不可变
  final String id; 

  /// 用户可自定义的设备友好显示名称（例如：MacBook Pro、张三的手机），默认取系统主机名
  final String name; 

  /// 对方在局域网内部署的 IPv4 物理寻址地址，用于建立 TCP 直连上传通道
  final String ip; 

  /// 对方 TCP 共享服务器开辟的出站监听端口，默认固定为 8889 端口
  final int port; 

  /// 对方 WebSocket / HTTP 服务端口，默认固定为 8890 端口
  final int wsPort;

  /// 对端设备的操作系统分类（如 'windows', 'ios', 'android', 'macos', 'linux'）
  /// 用于在 UI 界面中自适应渲染差异化的系统标识徽章
  final String os; 

  /// 对端设备的头像 Base64 字符串
  final String? avatar;

  /// 设备在线心跳状态指示器。若 UDP 设备广播心跳在指定周期内未收到，则此值会被置为离线
  final bool isOnline;

  /// 本机是否与此设备建立了稳定的业务握手连接。只有建立了连接的设备才可以发送暂存队列
  final bool isConnected;

  /// 对方最后一次发送 UDP 心跳广播的时间戳，用于心跳过期检测
  final DateTime lastSeen;

  /// 默认全参数构造函数
  DeviceInfo({
    required this.id,
    required this.name,
    required this.ip,
    required this.port,
    this.wsPort = 8890,
    required this.os,
    this.avatar,
    this.isOnline = true,
    this.isConnected = false,
    required this.lastSeen,
  });

  /// [DeviceInfo.fromJson] 工厂转换函数
  /// 用于从捕获的 UDP 广播入站数据包中提取并解析对端设备的网络节点模型。
  /// [json] 为 UDP 报文中包含的设备特征 payload。
  /// [senderIp] 为从 UDP Datagram 中解析出来的发送端物理 IPv4 地址。
  factory DeviceInfo.fromJson(Map<String, dynamic> json, String senderIp) {
    return DeviceInfo(
      id: json['pid'] ?? 'UNKNOWN',
      name: json['name'] ?? '未知设备',
      ip: senderIp,
      port: json['port'] ?? 8889,
      wsPort: json['wsPort'] ?? 8890,
      os: (json['os'] ?? 'windows').toString().toLowerCase(),
      avatar: json['avatar'],
      isOnline: true,
      isConnected: false,
      lastSeen: DateTime.now(),
    );
  }

  /// [toJson] 序列化函数
  /// 将本端的设备属性转换为 JSON 键值对元数据，以便作为广播负载，
  /// 通过 UDP 端口 8888 播发到整个局域网网段内。
  Map<String, dynamic> toJson() {
    return {
      'pid': id,
      'name': name,
      'port': port,
      'wsPort': wsPort,
      'os': os,
      'avatar': avatar,
    };
  }

  /// [copyWith] 属性克隆拷贝辅助函数
  /// 采用不可变状态管理的设计思想，便于控制器在修改设备在线状态（`isOnline`）、
  /// 业务连接状态（`isConnected`）或最后在线心跳时间（`lastSeen`）时快速克隆新实例，触发状态通知。
  DeviceInfo copyWith({
    String? id,
    String? name,
    String? ip,
    int? port,
    int? wsPort,
    String? os,
    String? avatar,
    bool? isOnline,
    bool? isConnected,
    DateTime? lastSeen,
  }) {
    return DeviceInfo(
      id: id ?? this.id,
      name: name ?? this.name,
      ip: ip ?? this.ip,
      port: port ?? this.port,
      wsPort: wsPort ?? this.wsPort,
      os: os ?? this.os,
      avatar: avatar ?? this.avatar,
      isOnline: isOnline ?? this.isOnline,
      isConnected: isConnected ?? this.isConnected,
      lastSeen: lastSeen ?? this.lastSeen,
    );
  }
}
