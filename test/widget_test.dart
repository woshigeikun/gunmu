// 基础冒烟测试:验证 App 能正常构建出首页
import 'package:flutter_test/flutter_test.dart';

import 'package:heart_rate_camera/main.dart';

void main() {
  testWidgets('App builds home page', (WidgetTester tester) async {
    await tester.pumpWidget(const HeartRateCameraApp());
    expect(find.text('连接手环'), findsOneWidget);
  });
}
