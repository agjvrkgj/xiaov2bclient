import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../theme/app_theme.dart';
import '../widgets/custom_window_bar.dart';
import '../providers/language_provider.dart';
import '../services/mihomo/mihomo_constants.dart';
import '../services/mihomo/mihomo_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final MihomoService _mihomo = MihomoService();
  String _outboundMode = 'rule'; // 'rule' or 'global'

  @override
  void initState() {
    super.initState();
    _loadMihomoSettings();
  }

  Future<void> _loadMihomoSettings() async {
    await _mihomo.initialize();
    if (!mounted) return;
    setState(() => _outboundMode = _mihomo.mode);
  }

  @override
  Widget build(BuildContext context) {
    final lang = Provider.of<LanguageProvider>(context);
    const textColor = Colors.white;
    const subTextColor = Colors.grey;

    return CustomWindowBar(
      child: Scaffold(
      appBar: AppBar(
        title: Text(lang.getText('settings'), style: const TextStyle(color: textColor)),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, size: 20, color: textColor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: ListView(
        children: [
          _buildSectionHeader(lang.getText('connection')),
          ListTile(
            title: Text(lang.getText('outbound_mode'), style: const TextStyle(color: textColor)),
            subtitle: Text(
              _outboundMode == 'rule' ? lang.getText('mode_rule') : lang.getText('mode_global'),
              style: const TextStyle(color: subTextColor),
            ),
            trailing: const Icon(Icons.arrow_forward_ios, size: 16, color: subTextColor),
            onTap: () => _showOutboundModeDialog(context, lang, textColor),
          ),
          
          _buildSectionHeader(lang.getText('general')),
          ListTile(
            title: Text(lang.getText('language'), style: const TextStyle(color: textColor)),
            subtitle: Text(lang.currentLocale.languageCode == 'en' ? 'English' : '中文', style: const TextStyle(color: subTextColor)),
            trailing: const Icon(Icons.language, color: subTextColor),
            onTap: () => _showLanguageDialog(context, lang, textColor),
          ),
          
          _buildSectionHeader(lang.getText('about')),
          ListTile(
            title: Text(lang.getText('privacy_policy'), style: TextStyle(color: textColor)),
            trailing: Icon(Icons.arrow_forward_ios, size: 16, color: subTextColor),
            onTap: () {},
          ),
          ListTile(
            title: Text(lang.getText('version'), style: TextStyle(color: textColor)),
            subtitle: Text(
              'Mihomo ${_mihomo.coreVersion ?? MihomoConstants.version}',
              style: TextStyle(color: subTextColor),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: const TextStyle(
          color: AppTheme.primaryColor,
          fontSize: 13,
          fontWeight: FontWeight.bold,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  void _showOutboundModeDialog(BuildContext context, LanguageProvider lang, Color textColor) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: Text(lang.getText('outbound_mode'), style: TextStyle(color: textColor)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            RadioListTile<String>(
              title: Text(lang.getText('mode_rule'), style: TextStyle(color: textColor)),
              value: 'rule',
              groupValue: _outboundMode,
              activeColor: AppTheme.primaryColor,
              onChanged: (val) async {
                Navigator.pop(context);
                if (val != null) await _changeOutboundMode(val);
              },
            ),
            RadioListTile<String>(
              title: Text(lang.getText('mode_global'), style: TextStyle(color: textColor)),
              value: 'global',
              groupValue: _outboundMode,
              activeColor: AppTheme.primaryColor,
              onChanged: (val) async {
                Navigator.pop(context);
                if (val != null) await _changeOutboundMode(val);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            child: Text(lang.getText('cancel')),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Future<void> _changeOutboundMode(String value) async {
    final previous = _outboundMode;
    setState(() => _outboundMode = value);
    try {
      await _mihomo.setMode(value);
    } on MihomoOperationException catch (error) {
      if (!mounted) return;
      setState(() => _outboundMode = previous);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  void _showLanguageDialog(BuildContext context, LanguageProvider lang, Color textColor) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        title: Text(lang.getText('language'), style: TextStyle(color: textColor)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text('English', style: TextStyle(color: textColor)),
              leading: Radio<String>(
                value: 'en',
                groupValue: lang.currentLocale.languageCode,
                activeColor: AppTheme.primaryColor,
                onChanged: (val) {
                  lang.changeLanguage(const Locale('en'));
                  Navigator.pop(context);
                },
              ),
              onTap: () {
                lang.changeLanguage(const Locale('en'));
                Navigator.pop(context);
              },
            ),
            ListTile(
              title: Text('中文', style: TextStyle(color: textColor)),
              leading: Radio<String>(
                value: 'zh',
                groupValue: lang.currentLocale.languageCode,
                activeColor: AppTheme.primaryColor,
                onChanged: (val) {
                  lang.changeLanguage(const Locale('zh'));
                  Navigator.pop(context);
                },
              ),
              onTap: () {
                lang.changeLanguage(const Locale('zh'));
                Navigator.pop(context);
              },
            ),
          ],
        ),
      ),

    );
  }
}
