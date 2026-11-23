// GENERADO por tool/gen_contract.dart desde openapi/openapi.yaml. No editar.

abstract final class ApiPaths {
  static const authToken = '/api/v1/auth/token';
  static const authMe = '/api/v1/auth/me';
  static const authLogout = '/api/v1/auth/logout';
  static const scansSync = '/api/v1/operations/scans/sync';
  static const embarks = '/api/v1/operations/embarks';
  static const shipments = '/api/v1/operations/shipments';
  static const inventoryCounts = '/api/v1/operations/inventory-counts';
  static const routeSheet = '/api/v1/operations/deliveries/route-sheet';
  static const deliveriesBatch = '/api/v1/operations/deliveries/batch';
  static String deliveryEvidence(Object delivery) => '/api/v1/operations/deliveries/$delivery/evidence';
  static const fleetRoutes = '/api/v1/fleet/routes';
  static String fleetRoute(Object route) => '/api/v1/fleet/routes/$route';
  static const fleetSync = '/api/v1/fleet/sync';
  static const fleetExpenses = '/api/v1/fleet/expenses';
  static String fleetMileage(Object route) => '/api/v1/fleet/routes/$route/mileage';
  static const attendanceMine = '/api/v1/identity/attendance/mine';
  static const attendanceMineDays = '/api/v1/identity/attendance/mine/days';
  static const attendance = '/api/v1/identity/attendance';
}
