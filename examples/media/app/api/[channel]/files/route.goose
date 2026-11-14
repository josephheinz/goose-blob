// GET /api/CHANNEL/files lists the channel's files; POST /api/CHANNEL/files?name=NAME stores the request body.
import std;
import net.http;
import gweb;
import blob;
import lib.media;

fn fail(res: http::Response&, status: http::Status, why: const u8[:]) {
    gweb::json(res, status);
    res.body.append("{\"error\":\"");
    gweb::json_escape(res.body, why);
    res.body.append("\"}");
}

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let s, ok = media::channel(gweb::param(ctx, "channel"));
    if !ok { fail(res, http::Status.NotFound, "no such channel"); return; }
    var page: blob::Entry[..1000] = [];
    if !blob::list(s, "", "", page) { fail(res, http::Status.InternalServerError, blob::last_error()); return; }
    gweb::json(res, http::Status.Ok);
    res.body.append("[");
    for e, i in page {
        if i > 0 { res.body.append(","); }
        var url: u8[>..] = [];
        blob::url(s, e.key, url);
        format(res.body, "{\"key\":\"", e.key, "\",\"size\":", e.size, ",\"url\":\"", url, "\"}");
    }
    res.body.append("]");
}

fn POST(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let s, ok = media::channel(gweb::param(ctx, "channel"));
    if !ok { fail(res, http::Status.NotFound, "no such channel"); return; }
    var name: u8[>..] = [];
    gweb::query(req, "name", name);
    // One segment of [a-z0-9._-]: key_ok refuses "..", "a/b", dot files and the rest.
    if find(name, "/") >= 0 || !blob::key_ok(name) { fail(res, http::Status.BadRequest, "bad name"); return; }
    var o = blob::PutOptions { .. };
    o.content_type.append(gweb::mime_type(name));
    if !blob::put(s, name, req.body, o) { fail(res, http::Status.InternalServerError, blob::last_error()); return; }
    var url: u8[>..] = [];
    blob::url(s, name, url);
    gweb::json(res, http::Status.Created);
    format(res.body, "{\"key\":\"", name, "\",\"url\":\"", url, "\"}");
}
