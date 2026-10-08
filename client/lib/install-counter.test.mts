// npm test. Node's own test runner, which runs TypeScript directly.
import assert from "node:assert/strict";
import { test } from "node:test";
import { createInstallRoute, type Limits } from "./install-counter.ts";

const URL = "https://talkflow.example/api/install";

/** A fake database: records each call and the arguments it was given. */
function fakeDb(fail?: Error) {
  const calls: unknown[][] = [];
  const increment = async (...args: unknown[]) => {
    calls.push(args);
    if (fail) throw fail;
  };
  return { calls, increment };
}

const roomy: Limits = { perWindow: 1000, windowMs: 60_000, now: () => 0 };

test("POST with no body increments once and answers 204 with no body", async () => {
  const db = fakeDb();
  const route = createInstallRoute(db.increment, roomy);
  const res = await route.POST(new Request(URL, { method: "POST" }));
  assert.equal(res.status, 204);
  assert.equal(await res.text(), "");
  assert.equal(db.calls.length, 1);
});

test("each POST increments exactly once", async () => {
  const db = fakeDb();
  const route = createInstallRoute(db.increment, roomy);
  for (let i = 0; i < 5; i++) await route.POST(new Request(URL, { method: "POST", headers: { "content-length": "0" } }));
  assert.equal(db.calls.length, 5);
});

test("no request data reaches the database layer", async () => {
  const db = fakeDb();
  const route = createInstallRoute(db.increment, roomy);
  await route.POST(
    new Request(URL, {
      method: "POST",
      headers: {
        "user-agent": "talkflow/9.9.9 (test)",
        "x-forwarded-for": "203.0.113.7",
        "x-real-ip": "203.0.113.7",
        "x-install-id": "fake-install-id",
        cookie: "id=abc",
      },
    }),
  );
  assert.equal(db.calls.length, 1);
  assert.deepEqual(db.calls[0], [], "increment is called with no arguments");
});

test("every other method is 405 and never touches the database", async () => {
  const db = fakeDb();
  const route = createInstallRoute(db.increment, roomy);
  for (const method of ["GET", "HEAD", "PUT", "PATCH", "DELETE", "OPTIONS"] as const) {
    const res = await route[method]();
    assert.equal(res.status, 405, method);
    assert.equal(res.headers.get("allow"), "POST", method);
    assert.equal(await res.text(), "", method);
  }
  assert.equal(db.calls.length, 0);
});

test("a request that declares or streams a body is refused unread", async () => {
  const db = fakeDb();
  const route = createInstallRoute(db.increment, roomy);
  const declared = await route.POST(new Request(URL, { method: "POST", headers: { "content-length": "12" } }));
  assert.equal(declared.status, 413);
  const streamed = await route.POST(new Request(URL, { method: "POST", headers: { "transfer-encoding": "chunked" } }));
  assert.equal(streamed.status, 413);
  assert.equal(db.calls.length, 0);
});

test("a database failure is a bare 500 that leaks nothing", async () => {
  const secret = "db-detail-that-must-not-leak";
  const db = fakeDb(Object.assign(new Error(`connect failed for ${secret}`), { code: "ECONNREFUSED" }));
  const route = createInstallRoute(db.increment, roomy);
  const logged: string[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => void logged.push(args.map(String).join(" "));
  try {
    const res = await route.POST(new Request(URL, { method: "POST" }));
    assert.equal(res.status, 500);
    assert.equal(await res.text(), "");
    assert.equal([...res.headers.keys()].length, 0);
  } finally {
    console.error = original;
  }
  assert.deepEqual(logged, ["install counter: increment failed (ECONNREFUSED)"]);
  assert.ok(!logged.join("").includes(secret));
});

test("past the per-instance limit it answers 429 without incrementing, then recovers", async () => {
  let now = 0;
  const db = fakeDb();
  const route = createInstallRoute(db.increment, { perWindow: 3, windowMs: 60_000, now: () => now });
  const statuses = [];
  for (let i = 0; i < 5; i++) statuses.push((await route.POST(new Request(URL, { method: "POST" }))).status);
  assert.deepEqual(statuses, [204, 204, 204, 429, 429]);
  assert.equal(db.calls.length, 3);
  now = 60_000;
  assert.equal((await route.POST(new Request(URL, { method: "POST" }))).status, 204);
  assert.equal(db.calls.length, 4);
});
