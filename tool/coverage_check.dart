// Criterio 8 de la Fase 8: el motor de sincronización y los conflictos, al menos al 80 %.
//
//   cd packages/logistics_core && flutter test --coverage
//   dart run tool/coverage_check.dart packages/logistics_core/coverage/lcov.info
import 'dart:io';

void main(List<String> args) {
  final files = <String, List<int>>{};
  String? current;

  for (final line in File(args.single).readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      current = line.substring(3).replaceAll(r'\', '/');
    } else if (line.startsWith('DA:')) {
      final hits = int.parse(line.substring(3).split(',')[1]);
      final totals = files.putIfAbsent(current!, () => [0, 0]);

      totals[1]++;

      if (hits > 0) {
        totals[0]++;
      }
    }
  }

  var covered = 0;
  var total = 0;

  files.forEach((path, totals) {
    if (path.endsWith('.g.dart')) {
      return;
    }

    stdout.writeln('${_percent(totals[0], totals[1])} % ${path.split('lib/src/').last}');

    if (path.contains('/sync/')) {
      covered += totals[0];
      total += totals[1];
    }
  });

  final percent = _percent(covered, total);

  stdout.writeln('Sincronización: $percent % ($covered/$total)');

  if (total == 0 || double.parse(percent) < 80) {
    stderr.writeln('FALLO: la sincronización debe tener al menos 80 % de líneas.');
    exit(1);
  }
}

String _percent(int covered, int total) => total == 0 ? '0.0' : (covered / total * 100).toStringAsFixed(1);
