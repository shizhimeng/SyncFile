import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/device_info.dart';
import '../models/transfer_item.dart';

/// [DbHelper] 数据库管理器
/// 集成了标准的 SQLite 数据层支持，支持 Windows 桌面端 FFI 连接与 Android/iOS 原生物理存储读写。
class DbHelper {
  static Database? _database;

  /// 获取数据库实例，双重校验锁单例模式
  static Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDb();
    return _database!;
  }

  /// 跨平台初始化 SQLite 并建表
  static Future<Database> _initDb() async {
    // 1. 如果是 Windows、MacOS 或 Linux 桌面端开发环境，初始化 FFI 数据库工厂映射
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    // 2. 获取沙盒中隔离、安全的目录
    String dbPath;
    if (Platform.isWindows) {
      dbPath = join(Directory.current.path, 'SyncFile.db');
    } else {
      final supportDir = await getApplicationSupportDirectory();
      dbPath = join(supportDir.path, 'SyncFile.db');
    }

    if (kDebugMode) {
      print(" [SyncFile数据库日志]: 正在启动并连接 SQLite 数据库，物理存储路径为: $dbPath");
    }

    // 3. 打开数据库并触发 DDL 建表
    return await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        // 创建历史传输记录表
        await db.execute('''
          CREATE TABLE transfers (
            id TEXT PRIMARY KEY,
            name TEXT,
            size INTEGER,
            type TEXT,
            path TEXT,
            content TEXT,
            progress REAL,
            speed REAL,
            status TEXT,
            direction TEXT,
            timestamp TEXT,
            peer_id TEXT,
            peer_name TEXT
          )
        ''');

        // 创建全局设置与个人信息表
        await db.execute('''
          CREATE TABLE settings (
            key TEXT PRIMARY KEY,
            value TEXT
          )
        ''');

        // 创建已连接设备表，记录双方连接细节，用以显示“上次连接是什么时候”
        await db.execute('''
          CREATE TABLE connected_devices (
            id TEXT PRIMARY KEY,
            name TEXT,
            ip TEXT,
            port INTEGER,
            ws_port INTEGER,
            os TEXT,
            avatar TEXT,
            is_connected INTEGER, -- 1 为已连接，0 为断开
            last_connected_time TEXT
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('ALTER TABLE connected_devices ADD COLUMN ws_port INTEGER DEFAULT 8890');
          } catch (_) {}
        }
      },
    );
  }

  // ==========================================
  // 1. 传输记录 (Transfers) CRUD 操作
  // ==========================================

  /// 插入一条传输记录 (如果主键重复则覆盖)
  static Future<void> insertTransfer(TransferItem item) async {
    try {
      final db = await database;
      await db.insert(
        'transfers',
        _transferToMap(item),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 插入传输历史数据记录失败，底层错误原因为: $e");
    }
  }

  /// 更新传输进度、速度或状态
  static Future<void> updateTransfer(TransferItem item) async {
    try {
      final db = await database;
      await db.update(
        'transfers',
        _transferToMap(item),
        where: 'id = ?',
        whereArgs: [item.id],
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 更新传输历史状态进度失败，底层错误原因为: $e");
    }
  }

  /// 从数据库中物理删除一条传输记录
  static Future<void> deleteTransfer(String id) async {
    try {
      final db = await database;
      await db.delete(
        'transfers',
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 物理删除特定传输记录失败，底层错误原因为: $e");
    }
  }

  /// 清空所有传输记录
  static Future<void> clearAllTransfers() async {
    try {
      final db = await database;
      await db.delete('transfers');
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 物理清空所有传输历史表失败，底层错误原因为: $e");
    }
  }

  /// 获取完整的往来传输历史记录，按时间戳倒序排列
  static Future<List<TransferItem>> getTransferHistory() async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query(
        'transfers',
        orderBy: 'timestamp DESC',
      );

      return List.generate(maps.length, (i) {
        return TransferItem(
          id: maps[i]['id'] ?? '',
          name: maps[i]['name'] ?? '',
          size: maps[i]['size'] ?? 0,
          type: maps[i]['type'] ?? 'file',
          path: maps[i]['path'],
          content: maps[i]['content'],
          progress: maps[i]['progress'] ?? 0.0,
          speed: maps[i]['speed'] ?? 0.0,
          status: maps[i]['status'] ?? 'success',
          direction: maps[i]['direction'] ?? 'sent',
          timestamp: DateTime.tryParse(maps[i]['timestamp'] ?? '') ?? DateTime.now(),
          peerId: maps[i]['peer_id'] ?? 'UNKNOWN',
          peerName: maps[i]['peer_name'] ?? '其它客户端',
        );
      });
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 检索拉取往来传输历史记录列表失败，底层错误原因为: $e");
      return [];
    }
  }

  // ==========================================
  // 2. 个人信息与全局设置 (Settings) 键值对操作
  // ==========================================

  /// 保存设置键值对 (如果存在则替换)
  static Future<void> saveSetting(String key, String value) async {
    try {
      final db = await database;
      await db.insert(
        'settings',
        {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      if (kDebugMode) print("SQLite Error saving setting: $e");
    }
  }

  /// 获取设置内容，若不存在返回 null
  static Future<String?> getSetting(String key) async {
    try {
      final db = await database;
      final List<Map<String, dynamic>> maps = await db.query(
        'settings',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: [key],
      );

      if (maps.isNotEmpty) {
        return maps.first['value'] as String?;
      }
      return null;
    } catch (e) {
      if (kDebugMode) print("SQLite Error fetching setting for $key: $e");
      return null;
    }
  }

  // ==========================================
  // 3. 已连接设备历史表 (Connected Devices) CRUD 操作
  // ==========================================

  /// 保存或插入已连接设备，用于记录双方连接ok的时候
  static Future<void> insertConnectedDevice(DeviceInfo device, {required bool isConnected}) async {
    try {
      final db = await database;
      await db.insert(
        'connected_devices',
        {
          'id': device.id,
          'name': device.name,
          'ip': device.ip,
          'port': device.port,
          'ws_port': device.wsPort,
          'os': device.os,
          'avatar': device.avatar,
          'is_connected': isConnected ? 1 : 0,
          'last_connected_time': DateTime.now().toIso8601String(),
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 插入连接设备关系链失败: $e");
    }
  }

  /// 一方断开连接时，另一方修改状态为断开并可重新发起连接
  static Future<void> updateConnectedDeviceStatus(String id, {required bool isConnected}) async {
    try {
      final db = await database;
      await db.update(
        'connected_devices',
        {
          'is_connected': isConnected ? 1 : 0,
          // 如果重新发起连接成功，更新最后连接时间
          if (isConnected) 'last_connected_time': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 更新连接设备状态失败: $e");
    }
  }

  /// 允许物理删除此条连接记录
  static Future<void> deleteConnectedDevice(String id) async {
    try {
      final db = await database;
      await db.delete(
        'connected_devices',
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 物理删除已连接设备记录失败: $e");
    }
  }

  /// 获取所有曾经和当前连接的设备历史关系数据
  static Future<List<Map<String, dynamic>>> getConnectedDevices() async {
    try {
      final db = await database;
      return await db.query(
        'connected_devices',
        orderBy: 'last_connected_time DESC',
      );
    } catch (e) {
      if (kDebugMode) print(" [SyncFile数据库日志]: 获取连接设备关系链列表失败: $e");
      return [];
    }
  }

  // ==========================================
  // 工具转换函数
  // ==========================================

  /// 将数据模型转换为 SQLite Map 键值对
  static Map<String, dynamic> _transferToMap(TransferItem item) {
    return {
      'id': item.id,
      'name': item.name,
      'size': item.size,
      'type': item.type,
      'path': item.path,
      'content': item.content,
      'progress': item.progress,
      'speed': item.speed,
      'status': item.status,
      'direction': item.direction,
      'timestamp': item.timestamp.toIso8601String(),
      'peer_id': item.peerId,
      'peer_name': item.peerName,
    };
  }
}
