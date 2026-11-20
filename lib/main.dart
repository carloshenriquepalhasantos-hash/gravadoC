import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:url_launcher/url_launcher.dart';

import 'editor/editor_page.dart';
import 'recorder_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const GravadocApp());
}

class GravadocApp extends StatelessWidget {
  const GravadocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'gravadoC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF090C12),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFFB6FF4A),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const AppShell(),
    );
  }
}

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  bool _editorVisited = false;
  String? _videoToEdit;

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nao foi possivel abrir o link.')),
        );
      }
    }
  }

  Future<void> _openSupport() async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Suporte - Pedidos'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Solicite melhorias para o gravadoC, suporte tecnico ou a criacao '
                'de software sob medida, sites e aplicativos para Android e Apple.',
              ),
              const SizedBox(height: 18),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.chat, color: Color(0xFF25D366)),
                title: const Text('WhatsApp'),
                subtitle: const Text('(49) 99710-357'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _openLink(
                    'https://wa.me/554999710357?text=${Uri.encodeComponent('Ola! Gostaria de solicitar um projeto ou melhoria para o gravadoC.')}',
                  );
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.camera_alt, color: Color(0xFFE4405F)),
                title: const Text('Instagram'),
                subtitle: const Text('@carloshenriquepalha'),
                onTap: () {
                  Navigator.pop(dialogContext);
                  _openLink('https://www.instagram.com/carloshenriquepalha/');
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Fechar'),
          ),
        ],
      ),
    );
  }

  void _openEditor([String? path]) {
    setState(() {
      _index = 1;
      _editorVisited = true;
      if (path != null) _videoToEdit = path;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: (i) =>
                i == 1 ? _openEditor() : setState(() => _index = 0),
            backgroundColor: const Color(0xFF0B0F17),
            labelType: NavigationRailLabelType.all,
            minWidth: 72,
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.fiber_manual_record_outlined),
                selectedIcon: Icon(Icons.fiber_manual_record),
                label: Text('Gravacao'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.movie_edit),
                label: Text('Edicao'),
              ),
            ],
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: InkWell(
                    key: const Key('open-support'),
                    onTap: _openSupport,
                    borderRadius: BorderRadius.circular(8),
                    child: const SizedBox(
                      width: 72,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.support_agent),
                          SizedBox(height: 4),
                          Text(
                            'Suporte',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10),
                          ),
                          Text(
                            'Pedidos',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 10),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _index,
              children: [
                RecorderPage(onOpenEditor: _openEditor),
                // O editor so e criado ao abrir, pois inicia o player de video.
                if (_editorVisited)
                  EditorPage(videoPath: _videoToEdit)
                else
                  const SizedBox(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
