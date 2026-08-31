import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../providers/language_provider.dart';
import '../services/api_service.dart';
import '../services/mihomo/mihomo_service.dart';
import '../widgets/connect_button.dart';
import '../widgets/server_card.dart';

import '../widgets/navigation_drawer.dart' as nav;
import 'notice_list_page.dart';
import '../widgets/custom_window_bar.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final MihomoService _mihomo = MihomoService();
  String _connectionTime = '00:00:00';
  Timer? _timer;
  int _seconds = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  
  // Subscription Data
  String _trafficInfo = '-- / --';
  String _expiryDate = '--';

  // Server Data
  List<dynamic> _serverList = [];
  Map<String, dynamic>? _selectedServer;
  bool _isLoadingServers = false;

  bool get _isConnected => _mihomo.isConnected;
  bool get _isConnectionBusy => _mihomo.isBusy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _mihomo.addListener(_onMihomoChanged);
    unawaited(_initializeMihomo());
    _fetchSubscribe();
    _fetchServers();
    _checkNotices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      print('App resumed, refreshing data...');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Row(
              children: [
                SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)),
                SizedBox(width: 16),
                Text('Refreshing data...', style: TextStyle(color: Colors.white)),
              ],
            ),
            duration: Duration(seconds: 2),
            backgroundColor: AppTheme.surfaceColor,
          ),
        );
      }
      _fetchSubscribe();
      _fetchServers();
      unawaited(_mihomo.refreshStatus());
    } else if (state == AppLifecycleState.detached) {
      unawaited(_mihomo.shutdownOnDesktopExit());
    }
  }

  Future<void> _initializeMihomo() async {
    await _mihomo.initialize();
    _onMihomoChanged();
    if (!mounted) return;
    await _fetchServers();
  }

  void _onMihomoChanged() {
    if (!mounted) return;
    setState(() {});
    if (_mihomo.isConnected) {
      _startTimer();
    } else {
      _stopTimer();
    }
  }

  Future<void> _fetchSubscribe() async {
    final data = await ApiService().getSubscribe();
    if (data != null && data['data'] != null) {
      final subData = data['data'];
      final int u = subData['u'] ?? 0;
      final int d = subData['d'] ?? 0;
      final int total = subData['transfer_enable'] ?? 0;
      final int expiredAt = subData['expired_at'] ?? 0;

      if (mounted) {
        setState(() {
          _trafficInfo = '${_formatBytes(u + d)} / ${_formatBytes(total)}';
          if (expiredAt > 0) {
            final date = DateTime.fromMillisecondsSinceEpoch(expiredAt * 1000);
            _expiryDate = DateFormat('yyyy-MM-dd').format(date);
          } else {
            _expiryDate = '∞';
          }
        });
      }
    }
  }

  Future<void> _fetchServers() async {
    if (!mounted) return;
    setState(() => _isLoadingServers = true);
    final servers = await ApiService().fetchServerNodes();
    if (mounted) {
      setState(() {
        _isLoadingServers = false;
        if (servers != null && servers.isNotEmpty) {
          _serverList = servers;
          if (_selectedServer == null) {
            final savedName = _mihomo.selectedProxy;
            if (savedName != null) {
              for (final server in servers) {
                if (server is Map && server['name']?.toString() == savedName) {
                  _selectedServer = Map<String, dynamic>.from(server);
                  break;
                }
              }
            }
            _selectedServer ??= Map<String, dynamic>.from(servers[0]);
          }
        }
      });
    }
  }

  Future<void> _checkNotices() async {
    final notices = await ApiService().fetchNotices();
    if (notices != null && notices.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final readNotices = prefs.getStringList('read_notices') ?? [];
      
      // Find the first unread notice
      for (var notice in notices) {
        final id = notice['id'].toString();
        if (!readNotices.contains(id)) {
          if (mounted) {
            _showNoticeDialog(notice);
          }
          break; // Show only one notice at a time
        }
      }
    }
  }

  void _showNoticeDialog(Map<String, dynamic> notice) {
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        title: Text(notice['title'] ?? 'Notice', style: const TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Text(notice['content'] ?? '', style: const TextStyle(color: Colors.white70)),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              final readNotices = prefs.getStringList('read_notices') ?? [];
              readNotices.add(notice['id'].toString());
              await prefs.setStringList('read_notices', readNotices);
              
              if (context.mounted) Navigator.pop(context);
            },
            child: Text(lang.getText('i_have_read'), style: const TextStyle(color: AppTheme.primaryColor)),
          ),
        ],
      ),
    );
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    var i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(2)} ${suffixes[i]}';
  }

  Future<void> _toggleConnection() async {
    if (_isConnectionBusy) return;
    try {
      if (_isConnected) {
        await _mihomo.disconnect();
      } else {
        if (_selectedServer == null) {
          throw const MihomoOperationException('请先选择一个节点');
        }
        await _mihomo.connect(
          selectedProxy: _selectedServer!['name']?.toString(),
        );
        if (_mihomo.lastError != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_mihomo.lastError!)),
          );
        }
      }
    } on MihomoOperationException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _startTimer() {
    _timer?.cancel();
    final connectedAt = _mihomo.connectedAt ?? DateTime.now();
    _seconds = DateTime.now()
        .difference(connectedAt)
        .inSeconds
        .clamp(0, 1 << 31)
        .toInt();
    _connectionTime = _formatTime(_seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _seconds = DateTime.now()
            .difference(connectedAt)
            .inSeconds
            .clamp(0, 1 << 31)
            .toInt();
        _connectionTime = _formatTime(_seconds);
      });
    });
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _connectionTime = '00:00:00';
  }

  String _formatTime(int seconds) {
    int h = seconds ~/ 3600;
    int m = (seconds % 3600) ~/ 60;
    int s = seconds % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _mihomo.removeListener(_onMihomoChanged);
    _timer?.cancel();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageProvider>(context);
    final statusText = switch (_mihomo.state) {
      MihomoConnectionState.connecting => lang.getText('connecting'),
      MihomoConnectionState.disconnecting => lang.getText('disconnecting'),
      MihomoConnectionState.connected => lang.getText('connected'),
      _ => lang.getText('not_connected'),
    };
    final statusColor = _isConnectionBusy
        ? Colors.orangeAccent
        : _isConnected
            ? AppTheme.primaryColor
            : Colors.grey;

    return CustomWindowBar(
      child: Scaffold(
        key: _scaffoldKey,
        drawer: const nav.AppNavigationDrawer(),
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded, color: Colors.white),
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text(
          '学习强国',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12.0),
            child: IconButton(
              icon: const Icon(Icons.notifications_none, color: Colors.white),
              onPressed: _checkNotices,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          const SizedBox(height: 24),
          // Status Text
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: (_isConnected || _isConnectionBusy)
                  ? statusColor.withOpacity(0.1)
                  : Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: statusColor,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _connectionTime,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 40,
              fontWeight: FontWeight.w600,
              fontFamily: 'Courier',
            ),
          ),
          
          // Subscription Info
          const SizedBox(height: 16),
          Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.data_usage, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text(
                    '${lang.getText('traffic_label')}: $_trafficInfo',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.calendar_today, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  Text(
                    '${lang.getText('expiry_label')}: $_expiryDate',
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                ],
              ),
            ],
          ),

          const Spacer(),
          
          // Connect Button (Smaller size)
          Center(
            child: SizedBox(
              width: 240, // Container for ripple
              height: 240,
              child: ConnectButton(
                isConnected: _isConnected,
                isLoading: _isConnectionBusy,
                onPressed: _toggleConnection,
              ),
            ),
          ),
          
          const Spacer(),
          
          // Server Selection
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
            child: ServerCard(
              countryName: _selectedServer != null ? _selectedServer!['name'] : 'Select Server',
              flagEmoji: '🌐', // We might need a way to map country codes to flags later
              latency: 'Auto', // Real latency pinging is a future task
              onTap: _isConnectionBusy ? () {} : () {
                showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  isScrollControlled: true, // Allow full height
                  builder: (context) {
                    final lang = Provider.of<LanguageProvider>(context);
                    return Container(
                    height: MediaQuery.of(context).size.height * 0.7, // 70% height
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor,
                      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                    ),
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Column(
                        children: [
                          Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white24,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          SizedBox(height: 16),
                          Text(
                            lang.getText('select_location'),
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Expanded(
                            child: _isLoadingServers
                                ? Center(child: CircularProgressIndicator(color: AppTheme.primaryColor))
                                : _serverList.isEmpty
                                    ? Center(child: Text('No servers available', style: TextStyle(color: Colors.white54)))
                                    : ListView.builder(
                                        itemCount: _serverList.length,
                                        itemBuilder: (context, index) {
                                          final server = _serverList[index];
                                          return _buildServerItem(server);
                                        },
                                      ),
                          ),
                        ],
                      ),
                    ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildServerItem(dynamic serverData) {
    final server = Map<String, dynamic>.from(serverData);
    final isSelected = _selectedServer?['name']?.toString() ==
        server['name']?.toString();
    return ListTile(
      leading: const Text('🌐', style: TextStyle(fontSize: 24)),
      title: Text(server['name'] ?? 'Unknown', style: const TextStyle(color: Colors.white)),
      trailing: isSelected 
          ? const Icon(Icons.check_circle, color: AppTheme.primaryColor)
          : null,
      onTap: () async {
        try {
          if (_isConnected) {
            await _mihomo.selectProxy(server['name']?.toString() ?? '');
          }
          if (!mounted) return;
          setState(() => _selectedServer = server);
          Navigator.pop(context);
        } on MihomoOperationException catch (error) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.message),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      },
    );
  }
}
