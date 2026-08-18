import assert from "node:assert/strict";
import test from "node:test";

import { createSerialTaskQueue } from "./alert-refresh.js";

function deferred() {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

test("an update queued during initial load renders the newest accepted revision last", async () => {
  const firstRead = deferred();
  let pendingSerial = 1;
  let reads = 0;
  const rendered = [];

  const enqueue = createSerialTaskQueue(async () => {
    reads += 1;
    const serial = pendingSerial;
    if (reads === 1) await firstRead.promise;
    rendered.push(serial);
  });

  const initialLoad = enqueue();
  await Promise.resolve();
  pendingSerial = 2;
  const updateLoad = enqueue();

  assert.deepEqual(rendered, []);
  firstRead.resolve();
  await Promise.all([initialLoad, updateLoad]);

  assert.deepEqual(rendered, [1, 2]);
});

test("a failed refresh does not prevent the next accepted revision from rendering", async () => {
  let attempts = 0;
  const enqueue = createSerialTaskQueue(async () => {
    attempts += 1;
    if (attempts === 1) throw new Error("transient IPC failure");
  });

  await assert.rejects(enqueue(), /transient IPC failure/);
  await enqueue();
  assert.equal(attempts, 2);
});
