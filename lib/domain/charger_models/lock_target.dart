/// Requested state for command 09 (manual button lock adjustment).
///
/// The charger does not expose a "toggle" on the wire: it accepts one explicit
/// data byte per request. Keeping the target as a closed enum means the app can
/// never send a lock request whose direction was inferred from local optimistic
/// state. The direction always comes from what the user picked and what the
/// latest valid 02 reply reported.
enum LockTarget {
  /// Data byte `A0`; the mini program labels this "手动按键调节 锁定".
  lock(0xA0, '手动按键调节 锁定'),

  /// Data byte `0A`; the mini program labels this "手动按键调节 开启".
  unlock(0x0A, '手动按键调节 开启');

  const LockTarget(this.wireByte, this.label);

  /// Data byte placed at frame offset 3. This is the only payload byte the mini
  /// program sends for command 09.
  final int wireByte;

  /// User-facing label matching the mini program's `index.forceLock` and
  /// `index.unlock` strings.
  final String label;

  static LockTarget? fromWireByte(int value) => switch (value) {
    0xA0 => LockTarget.lock,
    0x0A => LockTarget.unlock,
    _ => null,
  };

  /// Resolves the target that command 09 would move the device to, given the
  /// lock flag read from the latest valid 02 reply (`parameters.lockRaw`).
  static LockTarget fromLockRaw(int lockRaw) =>
      lockRaw == lock.wireByte ? lock : unlock;
}
