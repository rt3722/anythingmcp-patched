// Build-time patch for the compiled MCP endpoint controller
// (mcp-endpoint.controller.js).
//
// Some MCP clients (Grok) abandon a tools/call after ~30s of silence. Slow
// tools such as Nansen's /agent/expert take 45-110s, so the client drops the
// call even though the server would have answered.
//
// While a tool call is running, this sends a heartbeat on that call's SSE
// stream every MCP_HEARTBEAT_MS (default 10000; 0 disables):
//   - notifications/progress, if the client sent _meta.progressToken
//   - otherwise notifications/message (logging), which the spec allows at
//     any time; the server now declares the `logging` capability for this.
// Calls that finish before the first tick send nothing extra. The first tick
// of each call logs AMCP_HEARTBEAT with the tool, whether a progressToken was
// sent, and the client user-agent (no other headers, never auth).
'use strict';
const fs = require('fs');
const target = process.argv[2];
let src = fs.readFileSync(target, 'utf8');

function replaceOnce(re, replacement, label) {
    const n = (src.match(re) || []).length;
    if (n !== 1) { console.error(`FATAL: expected ${label} anchor exactly once, found ${n}`); process.exit(1); }
    src = src.replace(re, replacement);
}

replaceOnce(
    /new mcp_js_1\.McpServer\(\{ name: mcpServerConfig\.name, version: mcpServerConfig\.version \|\| '1\.0\.0' \}, \{ instructions \}\)/g,
    "new mcp_js_1.McpServer({ name: mcpServerConfig.name, version: mcpServerConfig.version || '1.0.0' }, { instructions, capabilities: { logging: {} } })",
    'McpServer',
);
replaceOnce(/const handler = async \(args\) => \{/g, 'const handler = async (args, extra) => {', 'handler');
replaceOnce(
    /const result = await this\.toolExecutor\.executeTool\(tool\.name, toolArgs, ctx\);/g,
    'const __stopHeartbeat = __amcpHeartbeat(tool.name, extra);\n' +
    '                        let result;\n' +
    '                        try { result = await this.toolExecutor.executeTool(tool.name, toolArgs, ctx); }\n' +
    '                        finally { __stopHeartbeat(); }',
    'executeTool',
);

const helper = `
function __amcpHeartbeat(toolName, extra) {
    const every = Number(process.env.MCP_HEARTBEAT_MS ?? 10000);
    if (!extra || typeof extra.sendNotification !== 'function' || !(every > 0)) return () => { };
    const token = extra._meta?.progressToken;
    const t0 = Date.now();
    let n = 0;
    const timer = setInterval(() => {
        n++;
        const msg = \`\${toolName} still running (\${Math.round((Date.now() - t0) / 1000)}s)\`;
        if (n === 1) {
            const ua = extra.requestInfo?.headers?.['user-agent'];
            console.log('AMCP_HEARTBEAT', JSON.stringify({ tool: toolName, progressToken: token !== undefined, ua: typeof ua === 'string' ? ua.slice(0, 120) : null }));
        }
        const note = token !== undefined
            ? { method: 'notifications/progress', params: { progressToken: token, progress: n, message: msg } }
            : { method: 'notifications/message', params: { level: 'info', logger: 'anythingmcp', data: msg } };
        Promise.resolve().then(() => extra.sendNotification(note)).catch((e) => console.log('AMCP_HEARTBEAT_ERR', String(e?.message ?? e)));
    }, every);
    timer.unref?.();
    return () => clearInterval(timer);
}
`;
replaceOnce(/\n\/\/# sourceMappingURL=mcp-endpoint\.controller\.js\.map\s*$/, helper + '//# sourceMappingURL=mcp-endpoint.controller.js.map\n', 'sourceMappingURL');

fs.writeFileSync(target, src);
console.log('PATCH OK (tool-heartbeat):', target);
