import 'package:flutter_test/flutter_test.dart';
import 'package:linkmesh/services/permissions.dart';

void main() {
  test('missing Bluetooth permission prevents headless startup', () {
    const permissions = MeshPermissions(bluetooth: false, location: true);
    expect(permissions.canRunHeadless(35, isAndroid: true), isFalse);
  });

  test('granted permissions allow headless startup', () {
    const permissions = MeshPermissions(bluetooth: true, location: true);
    expect(permissions.canRunHeadless(35, isAndroid: true), isTrue);
  });

  test('Android 12+ headless BLE does not require location permission', () {
    const permissions = MeshPermissions(bluetooth: true, location: false);
    expect(permissions.canRunHeadless(31, isAndroid: true), isTrue);
  });

  test('Android 11 headless discovery requires location permission', () {
    const permissions = MeshPermissions(bluetooth: true, location: false);
    // On Android <=30, location permission is required for BLE scanning.
    expect(permissions.canRunHeadless(30, isAndroid: true), isFalse);
  });
}
