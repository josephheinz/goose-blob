// GET /media/CHANNEL/KEY: on disk, gweb::send_file serves it (ETag, 304, HEAD, streaming, a sandbox for SVG);
// on S3, a redirect to a presigned URL that works for an hour.
import std;
import net.http;
import gweb;
import gweb.http.files;
import blob;
import lib.media;

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let s, ok = media::channel(gweb::param(ctx, "channel"));
    var key: u8[>..] = [];
    if !ok || !gweb::path_decode(key, gweb::param(ctx, "path")) || !blob::key_ok(key) {
        http::text(res, http::Status.NotFound, "Not Found");
        return;
    }
    if blob::is_disk(s) {
        var opts = gweb::FileOptions { .. };
        gweb::send_file(req, ctx, res, blob::root(s), key, opts);
        return;
    }
    var url: u8[>..] = [];
    if !blob::presign_get(s, key, 3600, url) { http::text(res, http::Status.InternalServerError, blob::last_error()); return; }
    http::set_header(res, "Cache-Control", "no-store");
    gweb::redirect(ctx, url, 302);
}
