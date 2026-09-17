const router = @import("../router.zig");
const i18n = @import("i18n");

const style_css = @embedFile("../web/98.css");
const app_css = @embedFile("../web/app.css");
const app_js = @embedFile("../web/app.js");
const alpine_js = @embedFile("../web/alpine.js");

pub fn home(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.html(i18n.pl_html);
}

pub fn homeEn(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.html(i18n.en_html);
}

pub fn style(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.css(style_css);
}

pub fn appStyle(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.css(app_css);
}

pub fn appScript(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.javascript(app_js);
}

pub fn alpineScript(_: *router.App, _: *router.RequestContext) router.AppError!router.Response {
    return router.Response.javascript(alpine_js);
}
