import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SamsungTvPocApp());
}

class SamsungTvPocApp extends StatelessWidget {
  const SamsungTvPocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Samsung TV PoC',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF7C4DFF),
      ),
      home: const SamsungTvPocScreen(),
    );
  }
}

class SamsungTvPocScreen extends StatefulWidget {
  const SamsungTvPocScreen({super.key});

  @override
  State<SamsungTvPocScreen> createState() => _SamsungTvPocScreenState();
}

class _SamsungTvPocScreenState extends State<SamsungTvPocScreen> {
  final _ipCtrl = TextEditingController(text: "192.168.1.50");
  final _clientNameCtrl = TextEditingController(text: "SamsungTvPoC");
  final List<String> _logs = [];

  final _client = SamsungTvWsClient();

  final _pageScrollCtrl = ScrollController();

  bool _connecting = false;
  bool _connected = false;

  String? _token;

  bool _needsTvPermission = false;

  Timer? _permissionTimer;
  bool _autoRepairedOnce = false; // token gelmezse 1 kez otomatik re-pair

  @override
  void initState() {
    super.initState();

    _client.onLog = _log;
    _client.onConnectionChanged = (v) => setState(() => _connected = v);

    _client.onWsText = (text) {
      // ham ws text geldiğinde:
      // - token yakalamayı geniş yapıyoruz (bazı tv'lerde farklı geliyor)
      final extracted = SamsungTvWsClient.tryExtractTokenFromAnyShape(text);
      if (extracted != null && extracted.isNotEmpty) {
        _onTokenReceived(extracted);
        return;
      }

      // izin reddi / auth sorunu
      if (_looksLikePermissionDenied(text)) {
        _log("⚠️ Permission/Authorization issue detected. TV ekranından Allow/Accept yapmalısın.");
        setState(() => _needsTvPermission = true);
      }
    };

    _client.onToken = (t) async {
      await _onTokenReceived(t);
    };

    _initToken();
  }

  Future<void> _onTokenReceived(String t) async {
    final token = t.trim();
    if (token.isEmpty) return;

    // aynı token tekrar tekrar geliyorsa spam olmasın
    if (_token == token) return;

    _token = token;
    await TvTokenStore.saveToken(token);

    _log("✅ TOKEN RECEIVED & SAVED");
    _autoRepairedOnce = false;

    if (!mounted) return;
    setState(() => _needsTvPermission = false);

    _cancelPermissionTimer();
  }

  bool _looksLikePermissionDenied(String text) {
    final s = text.toLowerCase();

    const patterns = [
      "unauthorized",
      "access denied",
      "denied",
      "not authorized",
      "forbidden",
      "403",
      "401",
      "client is not permitted",
      "rejected",
      "not permitted",
      "permission",
      "authorization",
      "ms.channel.connect", // bazen connect event'i permission hatasıyla gelir
    ];

    for (final p in patterns) {
      if (s.contains(p)) return true;
    }
    return false;
  }

  Future<void> _initToken() async {
    final t = await TvTokenStore.loadToken();
    if (t != null && t.isNotEmpty) {
      _token = t;
      _log("Saved token found ✅");
      if (mounted) setState(() {});
    } else {
      _log("No token yet. First connect will show Allow/Deny on TV.");
    }
  }

  void _log(String msg) {
    final line = "${DateTime.now().toIso8601String()}  $msg";
    if (!mounted) return;
    setState(() => _logs.insert(0, line));

    // yeni log gelince hafifçe aşağı kaydırma (opsiyonel)
    // Sayfa kaydırılabilir olduğundan kullanıcı isterse aşağı iner.
  }

  void _startPermissionTimer({required String ip, required String name}) {
    _cancelPermissionTimer();

    // Bağlandıktan sonra token gelmezse => TV popup bekleniyor
    _permissionTimer = Timer(const Duration(seconds: 7), () async {
      if (!mounted) return;

      final hasToken = (_token != null && _token!.isNotEmpty);

      if (_connected && !hasToken) {
        _log("⚠️ Token still missing. TV ekranında Allow/Accept popup’ı bekleniyor.");
        setState(() => _needsTvPermission = true);

        // ✅ 1 kez otomatik re-pair dene (token yoksa TV popup’ını tekrar zorlar)
        if (!_autoRepairedOnce) {
          _autoRepairedOnce = true;
          _log("🔁 Auto re-pair attempt (1x): clearing token & reconnecting to trigger TV popup again...");
          await _autoRepair(ip: ip, name: name);
        }
      }
    });
  }

  Future<void> _autoRepair({required String ip, required String name}) async {
    await _clearTokenInternal(setNeedsPermissionTrue: true);
    await _client.close();
    await _client.connect(tvIp: ip, clientName: name, token: null);
    _startPermissionTimer(ip: ip, name: name);
  }

  void _cancelPermissionTimer() {
    _permissionTimer?.cancel();
    _permissionTimer = null;
  }

  Future<void> _connect() async {
    final ip = _ipCtrl.text.trim();
    final name = _clientNameCtrl.text.trim().isEmpty ? "SamsungTvPoC" : _clientNameCtrl.text.trim();

    setState(() {
      _connecting = true;
      _needsTvPermission = false;
    });

    try {
      final savedToken = _token ?? await TvTokenStore.loadToken();

      if (savedToken == null || savedToken.isEmpty) {
        _log("ℹ️ No saved token. TV should show Allow/Deny popup for pairing.");
        setState(() => _needsTvPermission = true);
      }

      _startPermissionTimer(ip: ip, name: name);

      await _client.connect(tvIp: ip, clientName: name, token: savedToken);

      _log("Connect attempt done. If buttons don't work, check TV popup and press Allow/Accept.");
    } catch (e) {
      _cancelPermissionTimer();
      _log("CONNECT ERROR ❌ $e");
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _disconnect() async {
    _cancelPermissionTimer();
    await _client.close();
  }

  Future<void> _clearTokenInternal({required bool setNeedsPermissionTrue}) async {
    await TvTokenStore.clearToken();
    _token = null;
    _log("Token cleared 🧹 Next connect should show Allow/Deny again on TV.");
    if (!mounted) return;
    setState(() => _needsTvPermission = setNeedsPermissionTrue);
  }

  Future<void> _clearToken() async {
    await _clearTokenInternal(setNeedsPermissionTrue: true);
  }

  Future<void> _repair() async {
    final ip = _ipCtrl.text.trim();
    final name = _clientNameCtrl.text.trim().isEmpty ? "SamsungTvPoC" : _clientNameCtrl.text.trim();

    _log("🔁 Re-pair started: clearing token & reconnecting...");
    _autoRepairedOnce = false;
    await _clearTokenInternal(setNeedsPermissionTrue: true);
    await _disconnect();
    await _client.connect(tvIp: ip, clientName: name, token: null);
    _startPermissionTimer(ip: ip, name: name);
  }

  void _sendKeySafe(String key) {
    final hasToken = (_token != null && _token!.isNotEmpty);

    if (!_connected) {
      _log("❌ Not connected. Please connect first.");
      return;
    }

    if (!hasToken) {
      _log("⚠️ TV permission/token missing. TV ekranında Allow/Accept yap, sonra tekrar dene.");
      setState(() => _needsTvPermission = true);

      // Permission banner görünür olduğunda kullanıcı aşağıda logları görmek isterse
      // otomatik biraz aşağı kaydırabiliriz (kapatmak istersen söyle)
      return;
    }

    _client.sendKey(key);
  }

  @override
  void dispose() {
    _cancelPermissionTimer();
    _ipCtrl.dispose();
    _clientNameCtrl.dispose();
    _pageScrollCtrl.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final tokenPreview = (_token != null && _token!.isNotEmpty)
        ? "${_token!.substring(0, _token!.length > 12 ? 12 : _token!.length)}…"
        : "-";

    return Scaffold(
      appBar: AppBar(
        title: const Text("Samsung TV PoC"),
        actions: [
          IconButton(
            tooltip: "Clear token",
            onPressed: _clearToken,
            icon: const Icon(Icons.vpn_key_off),
          ),
        ],
      ),

      // ✅ TEK SAYFA SCROLL: her şey aşağı doğru kayar
      body: SafeArea(
        child: SingleChildScrollView(
          controller: _pageScrollCtrl,
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            // küçük içerikte bile ekranı doldursun (daha düzgün)
            constraints: BoxConstraints(minHeight: MediaQuery.of(context).size.height - kToolbarHeight - 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _ipCtrl,
                  decoration: const InputDecoration(
                    labelText: "TV IP Address",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),

                TextField(
                  controller: _clientNameCtrl,
                  decoration: const InputDecoration(
                    labelText: "Client Name (shown on TV pairing prompt)",
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),

                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _connecting ? null : _connect,
                        icon: Icon(_connected ? Icons.check_circle : Icons.link),
                        label: Text(_connecting ? "Connecting..." : (_connected ? "Connected" : "Connect")),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _disconnect,
                        icon: const Icon(Icons.link_off),
                        label: const Text("Disconnect"),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 10),

                Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Token: $tokenPreview",
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton.tonalIcon(
                      onPressed: _clearToken,
                      icon: const Icon(Icons.vpn_key_off),
                      label: const Text("Clear Token"),
                    ),
                  ],
                ),

                if (_needsTvPermission) ...[
                  const SizedBox(height: 10),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer.withOpacity(0.35),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: cs.error.withOpacity(0.25)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "TV Permission Required (Pairing)",
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            color: cs.onErrorContainer,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          "1) Samsung TV ekranına bak.\n"
                              "2) Bu cihazı soran popup çıkınca Allow/Accept.\n"
                              "3) Sonra tuşları tekrar dene.\n\n"
                              "Popup yoksa Re-pair’e bas (token siler ve TV tekrar sorar).",
                          style: TextStyle(color: cs.onErrorContainer),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: _repair,
                                icon: const Icon(Icons.refresh),
                                label: const Text("Re-pair"),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _clearToken,
                                icon: const Icon(Icons.vpn_key_off),
                                label: const Text("Clear Token"),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 14),

                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _KeyBtn(
                      title: "VOL +",
                      icon: Icons.volume_up,
                      enabled: _connected,
                      onTap: () => _sendKeySafe("KEY_VOLUP"),
                    ),
                    _KeyBtn(
                      title: "VOL -",
                      icon: Icons.volume_down,
                      enabled: _connected,
                      onTap: () => _sendKeySafe("KEY_VOLDOWN"),
                    ),
                    _KeyBtn(
                      title: "MUTE",
                      icon: Icons.volume_off,
                      enabled: _connected,
                      onTap: () => _sendKeySafe("KEY_MUTE"),
                    ),
                    _KeyBtn(
                      title: "HOME",
                      icon: Icons.home,
                      enabled: _connected,
                      onTap: () => _sendKeySafe("KEY_HOME"),
                    ),
                  ],
                ),

                const SizedBox(height: 14),
                const Divider(),
                const SizedBox(height: 8),

                Row(
                  children: [
                    Text(
                      "Logs",
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const Spacer(),
                    Text(
                      "${_logs.length}",
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
                const SizedBox(height: 8),

                // ✅ Logs artık sayfanın içinde; sayfa kaydıkça aşağı gelir
                Container(
                  decoration: BoxDecoration(
                    color: cs.surfaceVariant.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: cs.outline.withOpacity(0.2)),
                  ),
                  child: _logs.isEmpty
                      ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      "No logs yet.",
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  )
                      : ListView.separated(
                    // ✅ İç içe scroll çakışmasın diye:
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: _logs.length,
                    separatorBuilder: (_, __) => Divider(color: cs.outline.withOpacity(0.2)),
                    itemBuilder: (context, i) => SelectableText(
                      _logs[i],
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KeyBtn extends StatelessWidget {
  const _KeyBtn({
    required this.title,
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  final String title;
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 150,
      child: FilledButton.tonalIcon(
        onPressed: enabled ? onTap : null,
        icon: Icon(icon),
        label: Text(title),
      ),
    );
  }
}

/* =========================
   WS CLIENT + TOKEN STORE
   ========================= */

class SamsungTvWsClient {
  WebSocket? _ws;

  void Function(String msg)? onLog;
  void Function(String token)? onToken;
  void Function(bool connected)? onConnectionChanged;
  void Function(String wsText)? onWsText;

  Future<void> connect({
    required String tvIp,
    required String clientName,
    String? token,
  }) async {
    await close();

    final nameEncoded = Uri.encodeComponent(clientName);

    // 1) WSS 8002
    final wssBase = "wss://$tvIp:8002/api/v2/channels/samsung.remote.control?name=$nameEncoded";
    final wssUrl = (token != null && token.isNotEmpty) ? "$wssBase&token=$token" : wssBase;

    _log("WS CONNECT => $wssUrl");
    _log("If TV shows permission popup, press Allow/Accept.");

    try {
      final ws = await _connectWssInsecure(wssUrl);
      _ws = ws;
      _onConn(true);
      _listen(ws);
      _log("WS OPEN ✅ (wss:8002)");
      return;
    } catch (e) {
      _log("WSS failed ❌ $e");
    }

    // 2) Fallback WS 8001
    final wsBase = "ws://$tvIp:8001/api/v2/channels/samsung.remote.control?name=$nameEncoded";
    final wsUrl = (token != null && token.isNotEmpty) ? "$wsBase&token=$token" : wsBase;

    _log("WS CONNECT (fallback) => $wsUrl");
    final ws = await WebSocket.connect(wsUrl);
    _ws = ws;
    _onConn(true);
    _listen(ws);
    _log("WS OPEN ✅ (ws:8001)");
  }

  Future<WebSocket> _connectWssInsecure(String url) async {
    final uri = Uri.parse(url);

    final httpClient = HttpClient()
      ..badCertificateCallback = (X509Certificate cert, String host, int port) {
        final isIp = RegExp(r"^\d{1,3}(\.\d{1,3}){3}$").hasMatch(host);
        return isIp; // sadece IP ise izin ver
      };

    return WebSocket.connect(uri.toString(), customClient: httpClient);
  }

  void _listen(WebSocket ws) {
    ws.listen(
          (event) {
        if (event is String) {
          _log("WS MSG: $event");
          onWsText?.call(event);

          // klasik token çıkarma
          final t = tryExtractTokenFromAnyShape(event);
          if (t != null && t.isNotEmpty) {
            onToken?.call(t);
          }
        } else {
          _log("WS MSG (non-string): ${event.runtimeType}");
        }
      },
      onDone: () {
        _log("WS CLOSED");
        _onConn(false);
      },
      onError: (e) {
        _log("WS ERROR ❌ $e");
        _onConn(false);
      },
      cancelOnError: true,
    );
  }

  static String? tryExtractTokenFromAnyShape(String text) {
    try {
      final json = jsonDecode(text);

      // Shape A: {"data":{"token":"..."}}
      if (json is Map) {
        final data = json["data"];
        if (data is Map && data["token"] is String) {
          final t = (data["token"] as String).trim();
          if (t.isNotEmpty) return t;
        }

        // Shape B: {"event":"ms.channel.connect","data":{"token":"..."}}
        if (json["event"] is String && (json["event"] as String).toLowerCase().contains("ms.channel.connect")) {
          final d = json["data"];
          if (d is Map && d["token"] is String) {
            final t = (d["token"] as String).trim();
            if (t.isNotEmpty) return t;
          }
        }

        // Shape C: token root'ta olabilir (nadiren)
        if (json["token"] is String) {
          final t = (json["token"] as String).trim();
          if (t.isNotEmpty) return t;
        }
      }
    } catch (_) {}
    return null;
  }

  void sendKey(String key) {
    final ws = _ws;
    if (ws == null) {
      _log("SEND $key ❌ not connected");
      return;
    }

    final payload = jsonEncode({
      "method": "ms.remote.control",
      "params": {
        "Cmd": "Click",
        "DataOfCmd": key,
        "Option": false,
        "TypeOfRemote": "SendRemoteKey",
      }
    });

    _log("SEND $key => $payload");
    ws.add(payload);
  }

  Future<void> close() async {
    try {
      await _ws?.close(1000, "client close");
    } catch (_) {}
    _ws = null;
    _onConn(false);
    _log("WS CLOSED (client)");
  }

  void _log(String m) => onLog?.call(m);
  void _onConn(bool v) => onConnectionChanged?.call(v);
}

class TvTokenStore {
  static const _k = "samsung_tv_token";

  static Future<void> saveToken(String token) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_k, token);
  }

  static Future<String?> loadToken() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_k);
  }

  static Future<void> clearToken() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_k);
  }
}
