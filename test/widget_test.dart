import 'package:flutter_test/flutter_test.dart';
import 'package:ip_camera/main.dart';

void main() {
  testWidgets('CameraApp renders stream controls and overlay', (WidgetTester tester) async {
    await tester.pumpWidget(const CameraApp());

    expect(find.text('Access stream at:'), findsOneWidget);
    expect(find.text('Start Streaming'), findsOneWidget);
  });
}
