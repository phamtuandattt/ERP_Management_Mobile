import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:mssql_connection/mssql_connection.dart';

class DbException implements Exception {
  DbException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ErpDb {
  ErpDb._();
  static final ErpDb instance = ErpDb._();

  final MssqlConnection _sql = MssqlConnection.getInstance();
  bool _ready = false;

  Future<LoginSession> login(String username, String password) async {
    final name = username.trim();
    if (name.isEmpty || password.isEmpty) {
      throw DbException('Sai tên đăng nhập hoặc mật khẩu!');
    }
    await _ensureConnected();
    final rows = await _query(
      'EXEC sp_Login @Username = @Username, @Password_Hash = @Password_Hash',
      {'Username': name, 'Password_Hash': _hashPassword(password)},
    );
    if (rows.isEmpty) throw DbException('Không có phản hồi từ server');

    final row = rows.first;
    final result = _str(row, 'Result');
    if (result.toUpperCase() != 'SUCCESS') {
      final message = switch (result) {
        'INVALID_CREDENTIALS' => 'Sai tên đăng nhập hoặc mật khẩu!',
        'ACCOUNT_DISABLED' => 'Tài khoản đã bị vô hiệu hóa!',
        _ => 'Đăng nhập thất bại!',
      };
      throw DbException(message);
    }

    final session = LoginSession(
      userId: _int(row, 'User_ID'),
      username: name,
      fullName: _str(row, 'Full_Name'),
      roleId: _int(row, 'Role_ID'),
      roleName: _str(row, 'Role_Name'),
    );
    if (!await _canViewWarehouse(session)) {
      throw DbException('Bạn không có quyền xem kho.');
    }
    return session;
  }

  Future<List<ProjectItem>> projects(LoginSession session) async {
    await _ensureConnected();
    if (!await _canViewWarehouse(session)) {
      throw DbException('Bạn không có quyền xem kho.');
    }
    final rows = await _query(
      "SELECT ProjectCode, ISNULL(ProjectName, N'') AS ProjectName FROM ProjectInfo ORDER BY ProjectCode",
    );
    return rows
        .map((e) => ProjectItem(code: _str(e, 'ProjectCode'), name: _str(e, 'ProjectName')))
        .toList();
  }

  Future<StockPageData> stock(LoginSession session, {String projectCode = '', String keyword = ''}) async {
    await _ensureConnected();
    if (!await _canViewWarehouse(session)) {
      throw DbException('Bạn không có quyền xem kho.');
    }
    final project = projectCode.trim();
    final text = keyword.trim();
    final filters = <String>[];
    final params = <String, dynamic>{};
    if (project.isNotEmpty) {
      filters.add('s.Project_Code = @proj');
      params['proj'] = project;
    }
    if (text.isNotEmpty) {
      filters.add(
        '(s.Size LIKE @kwPat OR s.Material LIKE @kwPat OR s.Item_Name LIKE @kwPat OR s.ID_Code LIKE @kwPat OR s.Import_No LIKE @kwPat OR s.PONo LIKE @kwPat)',
      );
      params['kwPat'] = '%$text%';
    }
    final where = filters.isEmpty ? '' : 'WHERE ${filters.join(' AND ')}';
    final rows = await _query(
      '''
      SELECT s.Item_Name, s.Size, s.Qty_Stock, s.Weight_Stock,
             ISNULL(s.PONo, N'') AS PONo,
             ISNULL(s.Project_Code, N'') AS Project_Code,
             ISNULL(p.ProjectName, N'') AS ProjectName
      FROM vw_Warehouse_Stock_V2 s
      LEFT JOIN ProjectInfo p ON p.ProjectCode = s.Project_Code
      $where
      ORDER BY s.Item_Name, s.Size
      ''',
      params,
    );
    final items = rows.map(StockItem.fromRow).toList();
    return StockPageData(
      count: items.length,
      qtyStock: items.fold<double>(0, (sum, item) => sum + item.qtyStock),
      weightStock: items.fold<double>(0, (sum, item) => sum + item.weightStock),
      items: items,
    );
  }

  Future<void> _ensureConnected() async {
    if (_ready && _sql.isConnected) return;
    final info = await _loadConnection();
    // Azure SQL từ chối lệnh USE. Tên cơ sở dữ liệu phải nằm trong cấu hình
    // đăng nhập của FreeTDS, trước khi mở kết nối.
    await _selectDatabase(info.database);
    final ok = await _sql.connect(
      ip: info.host,
      port: info.port,
      databaseName: '',
      username: info.user,
      password: info.password,
      timeoutInSeconds: info.timeoutSeconds,
      encrypt: info.encrypt,
      trustServerCertificate: info.trustServerCertificate,
      tdsVersion: '7.4',
    );
    if (!ok || !_sql.isConnected) {
      throw DbException('Không kết nối được cơ sở dữ liệu. Kiểm tra mạng hoặc tường lửa Azure SQL.');
    }
    _ready = true;
  }

  Future<void> _selectDatabase(String database) async {
    final safe = database.replaceAll(RegExp(r'[\r\n#]'), '');
    final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}erp_mobile_freetds.conf');
    await file.writeAsString(
      '[global]\n\ttds version = 7.4\n\tencryption = require\n\tdatabase = $safe\n',
    );
    final kernel = DynamicLibrary.open('kernel32.dll');
    final setEnv = kernel.lookupFunction<
        Int32 Function(Pointer<Utf16> name, Pointer<Utf16> value),
        int Function(Pointer<Utf16> name, Pointer<Utf16> value)>('SetEnvironmentVariableW');
    final name = 'FREETDSCONF'.toNativeUtf16();
    final value = file.path.toNativeUtf16();
    try {
      if (setEnv(name, value) == 0) {
        throw DbException('Không đặt được cơ sở dữ liệu cho kết nối.');
      }
    } finally {
      malloc.free(name);
      malloc.free(value);
    }
  }

  Future<List<Map<String, dynamic>>> _query(String sql, [Map<String, dynamic>? params]) async {
    try {
      final raw = params == null || params.isEmpty
          ? await _sql.getData(sql)
          : await _sql.getDataWithParams(sql, params);
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return [];
      final error = decoded['error'];
      if (error is String && error.isNotEmpty) throw DbException(error);
      final rows = decoded['rows'];
      if (rows is! List) return [];
      return rows.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } on DbException {
      rethrow;
    } on SQLException catch (ex) {
      throw DbException(ex.message.isEmpty ? 'Lỗi truy vấn cơ sở dữ liệu.' : ex.message);
    } catch (_) {
      throw DbException('Lỗi truy vấn cơ sở dữ liệu.');
    }
  }

  Future<bool> _canViewWarehouse(LoginSession session) async {
    if (_isAdmin(session)) return true;
    final detailed = await _query(
      'SELECT Module_Code, Action_Name, Is_Granted FROM User_Detailed_Permissions WHERE User_ID = @UserId',
      {'UserId': session.userId},
    );
    if (detailed.isNotEmpty) {
      return detailed.any((row) =>
          _str(row, 'Module_Code').toUpperCase() == 'WAREHOUSE' &&
          _str(row, 'Action_Name').toLowerCase() == 'xem' &&
          _bool(row, 'Is_Granted'));
    }
    final view = await _query(
      '''
      SELECT TOP 1 1 AS Allowed
      FROM vw_User_Effective_Permissions
      WHERE User_ID = @UserId
        AND Module_Code = 'WAREHOUSE'
        AND Can_View = 1
      ''',
      {'UserId': session.userId},
    );
    return view.isNotEmpty;
  }

  bool _isAdmin(LoginSession session) =>
      session.roleId == 1 ||
      session.roleName.toLowerCase() == 'admin' ||
      session.roleName.toLowerCase() == 'administrator' ||
      session.username.toLowerCase() == 'admin';

  String _hashPassword(String password) => sha256.convert(utf8.encode(password)).toString();

  Future<_SqlTarget> _loadConnection() async {
    try {
      final raw = await rootBundle.loadString('connection.local.json');
      final json = jsonDecode(raw);
      if (json is! Map || json['connectionString'] is! String) {
        throw DbException('Chuỗi kết nối không hợp lệ.');
      }
      return _SqlTarget.parse(json['connectionString'] as String);
    } on DbException {
      rethrow;
    } catch (_) {
      throw DbException('Không đọc được chuỗi kết nối.');
    }
  }
}

class _SqlTarget {
  _SqlTarget({
    required this.host,
    required this.port,
    required this.database,
    required this.user,
    required this.password,
    required this.encrypt,
    required this.trustServerCertificate,
    required this.timeoutSeconds,
  });

  final String host;
  final String port;
  final String database;
  final String user;
  final String password;
  final bool encrypt;
  final bool trustServerCertificate;
  final int timeoutSeconds;

  factory _SqlTarget.parse(String raw) {
    final values = <String, String>{};
    for (final part in raw.split(';')) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      values[part.substring(0, eq).trim().toLowerCase()] = part.substring(eq + 1).trim();
    }
    final server = values['server'] ?? values['data source'] ?? '';
    var host = server;
    var port = '1433';
    if (host.toLowerCase().startsWith('tcp:')) host = host.substring(4);
    final comma = host.lastIndexOf(',');
    if (comma > 0) {
      port = host.substring(comma + 1).trim();
      host = host.substring(0, comma).trim();
    }
    final database = values['initial catalog'] ?? values['database'] ?? '';
    final user = values['user id'] ?? values['uid'] ?? '';
    final password = values['password'] ?? values['pwd'] ?? '';
    if (host.isEmpty || database.isEmpty || user.isEmpty || password.isEmpty) {
      throw DbException('Chuỗi kết nối thiếu máy chủ, cơ sở dữ liệu hoặc tài khoản.');
    }
    return _SqlTarget(
      host: host,
      port: port,
      database: database,
      user: user,
      password: password,
      encrypt: _flag(values['encrypt'], fallback: true),
      trustServerCertificate: _flag(values['trustservercertificate'], fallback: false),
      timeoutSeconds: int.tryParse(values['connection timeout'] ?? '') ?? 30,
    );
  }

  static bool _flag(String? value, {required bool fallback}) {
    if (value == null || value.isEmpty) return fallback;
    return value.toLowerCase() == 'true' || value == '1';
  }
}

class LoginSession {
  LoginSession({
    required this.userId,
    required this.username,
    required this.fullName,
    required this.roleId,
    required this.roleName,
  });

  final int userId;
  final String username;
  final String fullName;
  final int roleId;
  final String roleName;
}

class ProjectItem {
  ProjectItem({required this.code, required this.name});
  final String code;
  final String name;
  String get label => name.trim().isEmpty ? code : '$code — $name';
}

class StockPageData {
  StockPageData({required this.count, required this.qtyStock, required this.weightStock, required this.items});
  final int count;
  final double qtyStock;
  final double weightStock;
  final List<StockItem> items;
}

class StockItem {
  StockItem({
    required this.importNo,
    required this.importDate,
    required this.itemName,
    required this.material,
    required this.size,
    required this.unit,
    required this.qtyImport,
    required this.qtyExported,
    required this.qtyStock,
    required this.weightStock,
    required this.qcCode,
    required this.qcStatus,
    required this.remarks,
    required this.rirNo,
    required this.rirStatus,
    required this.poNo,
    required this.projectCode,
    required this.projectName,
  });

  final String importNo;
  final DateTime? importDate;
  final String itemName;
  final String material;
  final String size;
  final String unit;
  final double qtyImport;
  final double qtyExported;
  final double qtyStock;
  final double weightStock;
  final String qcCode;
  final String qcStatus;
  final String remarks;
  final String rirNo;
  final String rirStatus;
  final String poNo;
  final String projectCode;
  final String projectName;

  factory StockItem.fromRow(Map<String, dynamic> row) {
    return StockItem(
      importNo: _str(row, 'Import_No'),
      importDate: _date(row, 'Import_Date'),
      itemName: _str(row, 'Item_Name'),
      material: _str(row, 'Material'),
      size: _str(row, 'Size'),
      unit: _str(row, 'UNIT'),
      qtyImport: _double(row, 'Qty_Import'),
      qtyExported: _double(row, 'Qty_Exported'),
      qtyStock: _double(row, 'Qty_Stock'),
      weightStock: _double(row, 'Weight_Stock'),
      qcCode: _str(row, 'QC_Code'),
      qcStatus: _str(row, 'QC_Status'),
      remarks: _str(row, 'Remarks'),
      rirNo: _str(row, 'RIR_No'),
      rirStatus: _str(row, 'RIR_Status'),
      poNo: _str(row, 'PONo'),
      projectCode: _str(row, 'Project_Code'),
      projectName: _str(row, 'ProjectName'),
    );
  }
}

dynamic _cell(Map<String, dynamic> row, String name) {
  if (row.containsKey(name)) return row[name];
  final lower = name.toLowerCase();
  for (final entry in row.entries) {
    if (entry.key.toLowerCase() == lower) return entry.value;
  }
  return null;
}

String _str(Map<String, dynamic> row, String name) => _cell(row, name)?.toString() ?? '';

int _int(Map<String, dynamic> row, String name) => _double(row, name).round();

double _double(Map<String, dynamic> row, String name) {
  final value = _cell(row, name);
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value) ?? 0;
  return 0;
}

bool _bool(Map<String, dynamic> row, String name) {
  final value = _cell(row, name);
  if (value is bool) return value;
  if (value is num) return value != 0;
  final text = value?.toString().toLowerCase() ?? '';
  return text == 'true' || text == '1';
}

DateTime? _date(Map<String, dynamic> row, String name) {
  final value = _cell(row, name);
  if (value is DateTime) return value;
  if (value == null) return null;
  return DateTime.tryParse(value.toString());
}
