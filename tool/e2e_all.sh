#!/usr/bin/env sh
# Tests de integración de las cuatro apps, en un emulador encendido y contra el stack
# aislado del backend (`scripts/e2e-up.sh`). Consumen los datos sembrados: hay que
# volver a levantar el stack antes de repetirlos.
set -eu

device="${DEVICE:-emulator-5554}"
api="${API_BASE_URL:-http://10.0.2.2:8100}"

run() {
  (cd "apps/$1" && flutter test "integration_test/$2" -d "$device" --dart-define="API_BASE_URL=$api")
}

run pda encryption_test.dart
run pda pda_sync_test.dart
run corporativa attendance_sync_test.dart
run flota fleet_ui_test.dart
run flota fleet_sync_test.dart
run reparto delivery_ui_test.dart
run reparto delivery_sync_test.dart
