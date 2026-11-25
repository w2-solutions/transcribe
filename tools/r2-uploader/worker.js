// Temporary Worker for uploading the Mac DMG: multipart upload to R2 through the bucket binding, because
// `wrangler r2 object put` stops at 300 MiB. Deployed only for the length of one upload, then deleted
// (see CLAUDE.md, "Publishing the Mac app", Manual fallback). Every request needs the x-token header.
// /create stores the same custom metadata as publish-mac.sh (sha256, version, build, edsignature), which a later
// resume (publish-mac.sh --resume-check and --resume) requires; it refuses a request without all four.
const METADATA = ["sha256", "version", "build", "edsignature"];

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.headers.get("x-token") !== env.TOKEN) return new Response("no", { status: 401 });
    const key = url.searchParams.get("key");
    const p = url.pathname;
    if (p === "/head") {
      const o = await env.DOWNLOADS.head(key);
      return Response.json(o ? { size: o.size, etag: o.etag, uploaded: o.uploaded, type: o.httpMetadata?.contentType, metadata: o.customMetadata } : null);
    }
    if (p === "/get") {
      const o = await env.DOWNLOADS.get(key);
      return o ? new Response(o.body) : new Response("missing", { status: 404 });
    }
    if (p === "/create") {
      const customMetadata = {};
      for (const name of METADATA) {
        const value = url.searchParams.get(name);
        if (!value) return new Response(`missing ${name}`, { status: 400 });
        customMetadata[name] = value;
      }
      const u = await env.DOWNLOADS.createMultipartUpload(key, {
        httpMetadata: { contentType: "application/x-apple-diskimage" },
        customMetadata,
      });
      return Response.json({ uploadId: u.uploadId });
    }
    const u = env.DOWNLOADS.resumeMultipartUpload(key, url.searchParams.get("uploadId"));
    if (p === "/part") {
      const part = await u.uploadPart(Number(url.searchParams.get("n")), request.body);
      return Response.json(part);
    }
    if (p === "/complete") {
      const o = await u.complete(await request.json());
      return Response.json({ size: o.size, etag: o.etag });
    }
    if (p === "/abort") { await u.abort(); return new Response("aborted"); }
    return new Response("?", { status: 404 });
  },
};
