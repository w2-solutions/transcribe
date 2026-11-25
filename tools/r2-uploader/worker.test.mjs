// Tests for worker.js with a stand-in bucket (no Cloudflare, no network): node --test tools/r2-uploader/worker.test.mjs
// Run by scripts/tests/release-scripts-test.sh when node is installed.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

// worker.js is an ES module without a package.json beside it, so load its text as one.
const source = readFileSync(new URL("./worker.js", import.meta.url), "utf8");
const worker = (await import("data:text/javascript," + encodeURIComponent(source))).default;

function bucket() {
  const created = [];
  return {
    created,
    async createMultipartUpload(key, options) {
      created.push({ key, options });
      return { uploadId: "u1" };
    },
    resumeMultipartUpload() {
      return {};
    },
  };
}

function call(env, path) {
  return worker.fetch(new Request(`https://uploader.example${path}`, { headers: { "x-token": "t" } }), env);
}

const SIG = "ab+/cd==";
const QUERY = `key=transcribe/Transcribe-0.3.0.dmg&sha256=${"a".repeat(64)}&version=0.3.0&build=300&edsignature=${encodeURIComponent(SIG)}`;

test("create stores the metadata a resume needs", async () => {
  const env = { TOKEN: "t", DOWNLOADS: bucket() };
  const response = await call(env, `/create?${QUERY}`);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { uploadId: "u1" });
  assert.deepEqual(env.DOWNLOADS.created, [
    {
      key: "transcribe/Transcribe-0.3.0.dmg",
      options: {
        httpMetadata: { contentType: "application/x-apple-diskimage" },
        customMetadata: { sha256: "a".repeat(64), version: "0.3.0", build: "300", edsignature: SIG },
      },
    },
  ]);
});

test("create without the metadata is refused", async () => {
  for (const drop of ["sha256", "version", "build", "edsignature"]) {
    const env = { TOKEN: "t", DOWNLOADS: bucket() };
    const query = QUERY.split("&").filter((p) => !p.startsWith(`${drop}=`)).join("&");
    const response = await call(env, `/create?${query}`);
    assert.equal(response.status, 400, drop);
    assert.equal(env.DOWNLOADS.created.length, 0, drop);
  }
});

test("a wrong token is refused", async () => {
  const env = { TOKEN: "other", DOWNLOADS: bucket() };
  assert.equal((await call(env, `/create?${QUERY}`)).status, 401);
  assert.equal(env.DOWNLOADS.created.length, 0);
});
