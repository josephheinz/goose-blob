// DELETE /api/CHANNEL/files/NAME removes a file; deleting one that is not there is not an error.
import std;
import net.http;
import gweb;
import blob;
import lib.media;

fn DELETE(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let s, ok = media::channel(gweb::param(ctx, "channel"));
    let name = gweb::param(ctx, "name");
    if !ok || !blob::key_ok(name) { http::text(res, http::Status.NotFound, "Not Found"); return; }
    if !blob::delete(s, name) { http::text(res, http::Status.InternalServerError, blob::last_error()); return; }
    res.status = http::Status.NoContent;
    res.body.clear();
}
