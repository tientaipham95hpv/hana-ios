/// Drift boundary for Phase 5. Tables and migrations arrive with their domain phases.
abstract interface class AppDatabaseBoundary {
  Future<void> close();
}
