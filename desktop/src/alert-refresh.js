/**
 * Creates a FIFO queue for alert refreshes. An update received while the
 * initial pending-alert read is in flight is therefore read and rendered only
 * after that initial render completes, so stale IPC responses cannot win.
 *
 * A failed task does not poison later refreshes. The returned promise still
 * rejects so the caller can report that individual failure.
 *
 * @param {() => Promise<void>} task
 * @returns {() => Promise<void>}
 */
export function createSerialTaskQueue(task) {
  let tail = Promise.resolve();

  return function enqueue() {
    const run = tail.then(task);
    tail = run.catch(() => undefined);
    return run;
  };
}
