/// The gate in front of a stored SAP password.
///
/// What happens, exactly:
/// * **Biometrics enrolled** (Face ID / Touch ID / fingerprint): the
/// password is read from the secure store only after [authenticate]
/// succeeds — it is never in memory before the gate is passed. A failed
/// or cancelled gate returns null (the caller asks for the password).
/// * **No biometrics enrolled** (a simulator, a device without them): the
/// stored password is used directly, with no prompt. It is then protected
/// only by the platform store: on iOS the Keychain's device-only,
/// unlocked-this-device class (`unlocked_this_device` — readable only
/// while this device is unlocked, never synced or backed up); on Android
/// `EncryptedSharedPreferences`, which encrypts at rest but has no unlock
/// gate of its own.
/// * The biometric check itself failing (plugin unavailable, an error)
/// returns null: the caller falls back to manual entry. So does the
/// secure store failing to answer ([hasStored] / [read] throwing).
///
/// Returns the released password, or null when nothing is stored (or the
/// stored value is empty) or the gate was not passed.
Future<String?> releaseStoredPassword({
  required Future<bool> Function() hasStored,
  required Future<bool> Function() biometricsEnrolled,
  required Future<bool> Function() authenticate,
  required Future<String?> Function() read,
}) async {
  // the store's own failures (a PlatformException from a corrupt Android
  // Keystore, iOS -34018) take the same way out as a failed gate: null,
  // the caller asks for the password. Outside this try they reached the
  // error view, whose Retry re-hit the store — a lockout no typed
  // password could end (audit 2026-10-23 R-9)
  try {
    if (!await hasStored()) return null;
  } catch (_) {
    return null; // the store unreadable — manual entry
  }
  bool released;
  try {
    released = !await biometricsEnrolled() || await authenticate();
  } catch (_) {
    released = false; // biometrics unavailable — manual entry
  }
  if (!released) return null;
  final String? stored;
  try {
    stored = await read();
  } catch (_) {
    return null; // the store unreadable — manual entry
  }
  return (stored == null || stored.isEmpty) ? null : stored;
}
