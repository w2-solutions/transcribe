// Temporary Worker for uploading the Mac DMG: multipart upload to R2 through the bucket binding, because
// `wrangler r2 object put` stops at 300 MiB. Deployed only for the length of one upload, then deleted
// (see CLAUDE.md, "Uploading the Mac download to Cloudflare R2"). Every request needs the x-token header.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (request.headers.get("x-token") !== env.TOKEN) return new Response("no", { status: 401 });
    const key = url.searchParams.get("key");
    const p = url.pathname;
    if (p === "/head") {
      const o = await env.DOWNLOADS.head(key);
      return Response.json(o ? { size: o.size, etag: o.etag, uploaded: o.uploaded, type: o.httpMetadata?.contentType } : null);
    }
    if (p === "/get") {
      const o = await env.DOWNLOADS.get(key);
      return o ? new Response(o.body) : new Response("missing", { status: 404 });
    }
    if (p === "/create") {
      const u = await env.DOWNLOADS.createMultipartUpload(key, { httpMetadata: { contentType: "application/x-apple-diskimage" } });
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
