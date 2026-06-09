class TransferItem {
  final String id; // 唯一传输任务 ID
  final String name; // 文件名或消息简述
  final int size; // 文件字节数 (文本/语音时可能为 0)
  final String type; // 类型: 'file', 'text', 'voice', 'image'
  final String? path; // 本地保存或要发送的物理文件路径
  final String? content; // 文本内容，或者语音音频物理文件路径
  final double progress; // 进度: 0.0 到 1.0
  final double speed; // 传输速度: MB/s
  final String status; // 状态: 'queued' (队列中), 'waiting' (等待接收确认), 'transferring' (传输中), 'success' (成功), 'failed' (失败)
  final String direction; // 方向: 'sent' (发送), 'received' (接收)
  final DateTime timestamp;
  final String peerId; // 目标设备/发送者 PID
  final String peerName; // 目标设备/发送者名称

  TransferItem({
    required this.id,
    required this.name,
    this.size = 0,
    required this.type,
    this.path,
    this.content,
    this.progress = 0.0,
    this.speed = 0.0,
    this.status = 'queued',
    required this.direction,
    required this.timestamp,
    required this.peerId,
    required this.peerName,
  });

  // 格式化输出文件大小
  String get formattedSize {
    if (type == 'text') return '文本';
    if (size <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double dSize = size.toDouble();
    while (dSize >= 1024 && i < suffixes.length - 1) {
      dSize /= 1024;
      i++;
    }
    return '${dSize.toStringAsFixed(1)} ${suffixes[i]}';
  }

  TransferItem copyWith({
    String? id,
    String? name,
    int? size,
    String? type,
    String? path,
    String? content,
    double? progress,
    double? speed,
    String? status,
    String? direction,
    DateTime? timestamp,
    String? peerId,
    String? peerName,
  }) {
    return TransferItem(
      id: id ?? this.id,
      name: name ?? this.name,
      size: size ?? this.size,
      type: type ?? this.type,
      path: path ?? this.path,
      content: content ?? this.content,
      progress: progress ?? this.progress,
      speed: speed ?? this.speed,
      status: status ?? this.status,
      direction: direction ?? this.direction,
      timestamp: timestamp ?? this.timestamp,
      peerId: peerId ?? this.peerId,
      peerName: peerName ?? this.peerName,
    );
  }
}
