/** Concurrent callers share the active refresh result; changes queue one later refresh. */
export class SharedRefresh {
  private pending?: Promise<boolean>;
  private again = false;
  private disposed = false;

  constructor(private readonly update: () => Promise<boolean>) {}

  request(): Promise<boolean> {
    if (this.disposed) return Promise.resolve(false);
    if (this.pending) {
      this.again = true;
      return this.pending;
    }
    this.again = false;
    const pending = Promise.resolve().then(this.update).finally(() => {
      if (this.pending !== pending) return;
      this.pending = undefined;
      if (this.again && !this.disposed) {
        // The next refresh has no waiting caller; a failure must not become unhandled.
        void this.request().catch(() => undefined);
      }
    });
    this.pending = pending;
    return pending;
  }

  dispose(): void {
    this.disposed = true;
    this.again = false;
  }
}
