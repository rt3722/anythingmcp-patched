// Build-time patch for the compiled REST engine (rest.engine.js).
//
// GMGN's OpenAPI (openapi.gmgn.ai) rejects any request that lacks a
// `timestamp` query param (unix seconds, must be within ±5s of server time)
// and a `client_id` UUID (replays within 7s are rejected). AnythingMCP only
// supports static auth values, so a stored connector can never satisfy this.
//
// This wraps the single axios call in requestWithRetry() so that, for hosts
// listed in NONCE_AUTH_HOSTS (default: openapi.gmgn.ai), every attempt —
// including transient-error retries — gets a fresh timestamp + client_id.
// Array query params for those hosts are sent as repeated keys (a=1&a=2),
// matching gmgn-cli, instead of axios' default a[]=1&a[]=2.
// Requests to any other host are untouched.
'use strict';
const fs = require('fs');
const target = process.argv[2];
let src = fs.readFileSync(target, 'utf8');

const anchor = 'return await (0, axios_1.default)(axiosConfig);';
const count = src.split(anchor).length - 1;
if (count !== 1) { console.error(`FATAL: expected anchor exactly once, found ${count}`); process.exit(1); }

const helper = `
function __amcpApplyRequestNonce(cfg) {
    const hosts = (process.env.NONCE_AUTH_HOSTS ?? 'openapi.gmgn.ai').split(',').map((h) => h.trim()).filter(Boolean);
    let host;
    try { host = new URL(cfg.url).hostname; } catch { return cfg; }
    if (!hosts.includes(host)) return cfg;
    cfg.params = { ...(cfg.params || {}), timestamp: Math.floor(Date.now() / 1000), client_id: require('crypto').randomUUID() };
    cfg.paramsSerializer = { indexes: null };
    return cfg;
}
`;
src = src.replace(anchor, 'return await (0, axios_1.default)(__amcpApplyRequestNonce(axiosConfig));');
src = src.replace(/\n\/\/# sourceMappingURL=rest\.engine\.js\.map\s*$/, helper + '//# sourceMappingURL=rest.engine.js.map\n');
if (!src.includes('function __amcpApplyRequestNonce')) { console.error('FATAL: helper not appended'); process.exit(1); }
fs.writeFileSync(target, src);
console.log('PATCH OK: request nonce ->', target);
