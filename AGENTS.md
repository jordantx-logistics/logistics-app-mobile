# AGENTS.md

Guía para agentes del monorepo de las **apps móviles** del proyecto logístico (Fase 8). Consumen el API de `logistics-app-backend`. El plan y las decisiones viven en `logistics-app-spec` (`03-roadmap/fase-08-apps-moviles.md` y `05-frontend/apps-moviles/`).

## Estructura

```
packages/logistics_core/   # Sesión, PIN, cliente API, base cifrada y motor de sincronización
apps/pda/                  # Almacén: escaneos (cámara y lector tipo teclado)
apps/flota/                # Chofer: ruta, tramos, kilometraje, viáticos y combustible
apps/reparto/              # Última milla: hoja de ruta, firma, foto y GPS
apps/corporativa/          # Empleado: marcaciones
tool/                      # Contrato, cobertura, permisos de Android y E2E
```

Pub workspace (`pubspec.yaml` en la raíz), Flutter 3.38, solo Android por ahora. SQLCipher se activa en la raíz con `hooks.user_defines.sqlite3.source`.

## Comandos

```bash
flutter pub get
dart analyze
git ls-files '*.dart' | xargs dart format --line-length 120 --set-exit-if-changed  # no recorre build/
dart run tool/gen_contract.dart          # regenera las rutas desde el contrato del backend
dart run tool/gen_contract.dart --check  # falla si hay deriva
```

```bash
cd packages/logistics_core
flutter test --coverage
cd ../..
dart run tool/coverage_check.dart packages/logistics_core/coverage/lcov.info
```

Tras cambiar las tablas de `app_database.dart`:

```bash
cd packages/logistics_core
dart run build_runner build --delete-conflicting-outputs --force-jit
```

`--force-jit` es obligatorio: `sqlite3` usa build hooks, que `dart compile` no admite.

No formatees pasando `apps` o `packages` como directorio: `dart format` entra en `build/`, y en Windows falla por las rutas largas de Gradle.

### Tests de integración

Corren en un emulador encendido, contra el stack aislado del backend:

```bash
cd ../logistics-app-backend
sh scripts/e2e-up.sh

cd ../logistics-app-mobile
sh tool/e2e_all.sh

cd ../logistics-app-backend
sh scripts/e2e-down.sh
```

Consumen los datos sembrados: hay que volver a levantar el stack antes de repetirlos. El CI no los ejecuta.

Con `-no-window`, `adb screencap` devuelve la pantalla en blanco: para ver las pantallas, arranca el emulador con ventana y `-gpu host`.

### Compilar

```bash
cd apps/pda
flutter build apk --release --dart-define=API_BASE_URL=https://api.empresa.com
```

`API_BASE_URL` es obligatorio y en release debe ser HTTPS: `checkApiOrigin` falla al arrancar en caso contrario, porque `dart:io` no obedece la política de tráfico en claro de Android. La firma de release sigue siendo la de depuración: falta el keystore de distribución.

## Sincronización

Toda escritura de las apps pasa por la cola (`OpStore.enqueue`) y responde al instante. `SyncEngine` la vacía por canales (`SyncChannel`):

- **Orden**: como máximo una operación por entidad (`entityKey`) en cada envío. Si una espera o tiene conflicto, retiene las siguientes de su entidad.
- **Red o 5xx**: se reintenta sin tope, con espera exponencial y desfase aleatorio.
- **Rechazo de negocio**: queda como `conflict` y se muestra en `SyncScreen`. El servidor es la verdad; la app no corrige por su cuenta.
- **401**: se detiene sin perder nada y la sesión se cierra. La cola se envía al volver a entrar.
- **Idempotencia**: el id de la operación viaja como `scan_id`, `event_id` o `idempotency_key`.
- **Archivos**: viven en disco hasta que el servidor confirma, y entonces se borran.

Para añadir una operación: un `kind` y su `SyncChannel`. Los archivos nunca viajan dentro de un lote JSON: van por su endpoint multipart, antes del evento o con él.

## Convenciones

- Comentarios y textos de la interfaz en español, sin capa de i18n todavía. Lo que manda el servidor en inglés no se enseña tal cual: `friendlyRejection` traduce por código de error.
- Cada app tiene su `AppBrand` (color, logo y lema). Las pantallas usan los componentes de `widgets.dart`: botones y campos rellenos, sin contornos, y listas de `ItemCard`, cuyo estado se lee por color e icono.
- La letra llega con `google_fonts`: se descarga la primera vez que hay red y hasta entonces se ve la del sistema. Antes de producción hay que empaquetarla.
- El servidor decide las reglas: la app solo valida formato (`normalizeTicketCode`, números).
- Rutas del API solo desde `ApiPaths` (`contract.g.dart`, generado). Si una ruta sale del contrato, el generador falla.
- Pantallas por `AppScope.of(context)`, sin gestor de estado: los datos llegan por `watch` de la base.

## Límites conocidos

- El generador produce rutas, no modelos: Scribe no emite `required`, y unos modelos con todo opcional no protegerían de nada.
- Cámara, GPS y lector físico no se automatizan: el escaneo por cámara, la foto y la ubicación real no los cubren los tests. Los de la PDA abren `PdaHome` con `cameraEnabled: false` y escriben el código.
- La base cifrada y el Keystore se probaron en el emulador; falta un equipo físico (Zebra/Honeywell).
