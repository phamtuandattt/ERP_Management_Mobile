import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'db.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ErpApp());
}

class ErpApp extends StatelessWidget {
  const ErpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ERP Kho',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E)),
        useMaterial3: true,
      ),
      home: const LoginPage(),
    );
  }
}

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _remember = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSaved();
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _loadSaved() async {
    try {
      final file = await _loginFile();
      if (!await file.exists() || !mounted) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      final remember = json['remember'] == true;
      setState(() {
        _remember = remember;
        if (remember) {
          _user.text = json['username'] as String? ?? '';
          _pass.text = json['password'] as String? ?? '';
        }
      });
    } catch (_) {}
  }

  Future<void> _storeLogin() async {
    final file = await _loginFile();
    if (!_remember) {
      if (await file.exists()) await file.delete();
      return;
    }
    await file.writeAsString(jsonEncode({
      'remember': true,
      'username': _user.text.trim(),
      'password': _pass.text,
    }));
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final session = await ErpDb.instance.login(_user.text.trim(), _pass.text);
      await _storeLogin();
      if (!mounted) return;
      await Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => StockPage(session: session),
      ));
    } on DbException catch (ex) {
      setState(() => _error = ex.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 36),
            Text('ERP Kho', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            const Text('Đăng nhập bằng tài khoản ERP để xem tồn kho.'),
            const SizedBox(height: 24),
            TextField(
              controller: _user,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Tên đăng nhập', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _pass,
              obscureText: true,
              onSubmitted: (_) => _busy ? null : _login(),
              decoration: const InputDecoration(labelText: 'Mật khẩu', border: OutlineInputBorder()),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Ghi nhớ tài khoản và mật khẩu'),
              value: _remember,
              onChanged: _busy ? null : (value) => setState(() => _remember = value ?? false),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _login,
              child: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Đăng nhập'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<File> _loginFile() async {
  final Directory dir;
  if (Platform.isWindows) {
    final base = Platform.environment['APPDATA'] ?? Directory.systemTemp.path;
    dir = Directory('$base\\ERP Kho');
  } else if (Platform.isAndroid) {
    dir = Directory('/data/user/0/com.dlhi.erp.erp_mobile/files');
  } else {
    dir = Directory('${Directory.systemTemp.path}${Platform.pathSeparator}ERP Kho');
  }
  if (!await dir.exists()) await dir.create(recursive: true);
  return File('${dir.path}${Platform.pathSeparator}login.json');
}

class StockPage extends StatefulWidget {
  const StockPage({super.key, required this.session});

  final LoginSession session;

  @override
  State<StockPage> createState() => _StockPageState();
}

class _StockPageState extends State<StockPage> {
  final _keyword = TextEditingController();
  List<ProjectItem> _projects = [];
  String _project = '';
  StockPageData? _data;
  bool _loadingProjects = true;
  bool _loadingStock = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadProjects();
    _search();
  }

  @override
  void dispose() {
    _keyword.dispose();
    super.dispose();
  }

  Future<void> _loadProjects() async {
    try {
      final list = await ErpDb.instance.projects(widget.session);
      if (!mounted) return;
      setState(() => _projects = list);
    } on DbException catch (ex) {
      if (mounted) setState(() => _error = ex.message);
    } finally {
      if (mounted) setState(() => _loadingProjects = false);
    }
  }

  Future<void> _search() async {
    setState(() {
      _loadingStock = true;
      _error = null;
    });
    try {
      final data = await ErpDb.instance.stock(widget.session, projectCode: _project, keyword: _keyword.text.trim());
      if (!mounted) return;
      setState(() => _data = data);
    } on DbException catch (ex) {
      if (mounted) setState(() => _error = ex.message);
    } finally {
      if (mounted) setState(() => _loadingStock = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tồn kho'),
        actions: [
          IconButton(
            tooltip: 'Đăng xuất',
            onPressed: () {
              Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const LoginPage()));
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              children: [
                TextField(
                  controller: _keyword,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: const InputDecoration(
                    hintText: 'Tìm tên, ID Code, PO No...',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: _project,
                  isExpanded: true,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem(value: '', child: Text('Tất cả dự án')),
                    ..._projects.map((p) => DropdownMenuItem(value: p.code, child: Text(p.label, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: _loadingProjects ? null : (value) => setState(() => _project = value ?? ''),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _loadingStock ? null : _search,
                    icon: const Icon(Icons.search),
                    label: const Text('Tìm'),
                  ),
                ),
              ],
            ),
          ),
          if (data != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
              child: Row(
                children: [
                  _Stat('Tổng mục', '${data.count}'),
                  _Stat('Tổng SL tồn', _n2(data.qtyStock)),
                  _Stat('Tổng KG tồn', _n2(data.weightStock)),
                ],
              ),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFDC2626))),
            ),
          Expanded(child: _body(data)),
        ],
      ),
    );
  }

  Widget _body(StockPageData? data) {
    if (_loadingStock) {
      return const Center(child: CircularProgressIndicator());
    }
    if (data == null) {
      return const Center(child: Text('Chưa có dữ liệu tồn kho.'));
    }
    if (data.items.isEmpty) {
      return const Center(child: Text('Không có vật tư tồn kho'));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: data.items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, index) => _StockCard(item: data.items[index]),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF64748B))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

class _StockCard extends StatelessWidget {
  const _StockCard({required this.item});
  final StockItem item;

  @override
  Widget build(BuildContext context) {
    final name = item.itemName.trim().isEmpty ? '—' : item.itemName.trim();
    final detail = [
      item.size.trim(),
      item.poNo.trim().isEmpty ? '' : 'PO ${item.poNo.trim()}',
      item.projectName.trim().isEmpty ? item.projectCode.trim() : '${item.projectCode.trim()} — ${item.projectName.trim()}',
    ].where((part) => part.isNotEmpty).join('  ·  ');
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(detail.isEmpty ? '—' : detail, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8))),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(_n2(item.qtyStock), style: TextStyle(fontWeight: FontWeight.w700, color: _qtyColor(item.qtyStock))),
          ],
        ),
      ),
    );
  }
}

String _n2(double value) {
  final negative = value < 0;
  final fixed = value.abs().toStringAsFixed(2);
  final parts = fixed.split('.');
  final digits = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
    buf.write(digits[i]);
  }
  return '${negative ? '-' : ''}$buf.${parts[1]}';
}

Color _qtyColor(double value) => value > 0 ? const Color(0xFF059669) : const Color(0xFFDC2626);
