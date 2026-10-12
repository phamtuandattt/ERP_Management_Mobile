import 'package:flutter_test/flutter_test.dart';
import 'package:erp_mobile/main.dart';

void main() {
  testWidgets('Màn đăng nhập hiện tên app', (tester) async {
    await tester.pumpWidget(const ErpApp());
    expect(find.text('ERP Kho'), findsOneWidget);
    expect(find.text('Đăng nhập'), findsOneWidget);
  });
}
