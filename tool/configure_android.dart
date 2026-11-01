// Aplica a cada app los permisos de Android que necesita. Idempotente.
//
//   dart run tool/configure_android.dart
//
// Solo el manifiesto de depuración permite HTTP. Lo que garantiza HTTPS en release es
// `checkApiOrigin`: `dart:io` no obedece la política de tráfico en claro de Android.
import 'dart:io';

const _common = ['android.permission.INTERNET', 'android.permission.ACCESS_NETWORK_STATE'];

const _apps = <String, ({String label, List<String> permissions})>{
  'pda': (label: 'Logistics PDA', permissions: ['android.permission.CAMERA', 'android.permission.VIBRATE']),
  'flota': (label: 'Logistics Fleet', permissions: ['android.permission.CAMERA']),
  'reparto': (
    label: 'Logistics Delivery',
    permissions: ['android.permission.CAMERA', 'android.permission.ACCESS_FINE_LOCATION', 'android.permission.ACCESS_COARSE_LOCATION'],
  ),
  'corporativa': (
    label: 'Logistics Staff',
    permissions: ['android.permission.ACCESS_FINE_LOCATION', 'android.permission.ACCESS_COARSE_LOCATION'],
  ),
};

void main() {
  for (final entry in _apps.entries) {
    final main = File('apps/${entry.key}/android/app/src/main/AndroidManifest.xml');
    var manifest = main.readAsStringSync().replaceAll('\r\n', '\n');

    for (final permission in [..._common, ...entry.value.permissions].reversed) {
      final line = '    <uses-permission android:name="$permission"/>\n';

      if (!manifest.contains('android:name="$permission"')) {
        manifest = manifest.replaceFirst(RegExp(r'(<manifest[^>]*>\n)'), '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n$line');
      }
    }

    manifest = manifest.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="${entry.value.label}"');
    main.writeAsStringSync(manifest);

    File('apps/${entry.key}/android/app/src/debug/AndroidManifest.xml').writeAsStringSync('''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <!-- Solo en depuración: el backend local no tiene HTTPS. -->
    <uses-permission android:name="android.permission.INTERNET"/>
    <application android:usesCleartextTraffic="true"/>
</manifest>
''');
  }
}
