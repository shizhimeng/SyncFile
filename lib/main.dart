import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'controllers/app_controller.dart';
import 'services/voice_service.dart';
import 'theme/app_theme.dart';
import 'views/home_navigation.dart';
// 加载门限：确保本地 PID、主机名和保存目录初始化加载完成后才渲染主页，防止任何空异常
import 'package:permission_handler/permission_handler.dart';
import 'dart:io';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(
          create: (_) => AppController(),
        ),
        ChangeNotifierProvider(
          create: (_) => VoiceService(),
        ),
      ],
      child: MaterialApp(
        title: 'SyncFile',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const AppLoadingGate(),
      ),
    );
  }
}



class AppLoadingGate extends StatefulWidget {
  const AppLoadingGate({super.key});

  @override
  State<AppLoadingGate> createState() => _AppLoadingGateState();
}

class _AppLoadingGateState extends State<AppLoadingGate> {
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  void _initApp() async {
    final controller = Provider.of<AppController>(context, listen: false);
    await controller.initialize();
    setState(() {
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_tethering, color: AppTheme.primary, size: 56),
              SizedBox(height: 16),
              CircularProgressIndicator(color: AppTheme.primary),
              SizedBox(height: 16),
              Text(
                'SyncFile 正在载入网络层...',
                style: TextStyle(
                  color: AppTheme.onSurfaceVariant,
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.0,
                ),
              )
            ],
          ),
        ),
      );
    }

    return const HomeNavigation();
  }
}
