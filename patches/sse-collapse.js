// Build-time patch for the compiled REST engine (rest.engine.js).
//
// Nansen's /agent/fast and /agent/expert return text/event-stream: one
// `data: {"type":"delta","text":"..."}` event per token, plus tool_call,
// finish and error events. AnythingMCP buffers the whole stream and hands it
// to the MCP client verbatim, so a long expert report balloons to 10-20x its
// real size (100KB+), which clients truncate or reject.
//
// This collapses such streams into the assembled answer, followed by the
// tools used, conversation_id and any error events. Streams whose events
// don't match that {type: delta|tool_call|finish|error} shape, and all
// non-SSE responses, are returned unchanged.
'use strict';
const fs = require('fs');
const target = process.argv[2];
let src = fs.readFileSync(target, 'utf8');

const anchor = /const response = await this\.requestWithRetry\(axiosConfig\);\s*return response\.data;/g;
const count = (src.match(anchor) || []).length;
if (count !== 1) { console.error(`FATAL: expected anchor exactly once, found ${count}`); process.exit(1); }

const helper = `
function __amcpCollapseSse(response) {
    const data = response.data;
    const ctype = String(response.headers?.['content-type'] ?? '');
    if (typeof data !== 'string' || !(ctype.includes('text/event-stream') || data.startsWith('data:'))) return data;
    const events = [];
    for (const line of data.split(/\\r?\\n/)) {
        if (!line.startsWith('data:')) continue;
        const payload = line.slice(5).trim();
        if (!payload || payload === '[DONE]') continue;
        let ev;
        try { ev = JSON.parse(payload); } catch { return data; }
        if (!ev || typeof ev !== 'object' || !['delta', 'tool_call', 'finish', 'error'].includes(ev.type)) return data;
        events.push(ev);
    }
    if (!events.length) return data;
    let answer = '';
    const tools = [];
    const errors = [];
    let conversationId = null;
    for (const ev of events) {
        if (ev.type === 'delta') answer += String(ev.text ?? '');
        else if (ev.type === 'tool_call' && ev.name && !tools.includes(ev.name)) tools.push(ev.name);
        else if (ev.type === 'error') errors.push(\`Agent error\${ev.status_code ? ' (' + ev.status_code + ')' : ''}: \${ev.error ?? 'unknown'}\`);
        else if (ev.type === 'finish') {
            conversationId = ev.conversation_id ?? null;
            for (const t of ev.tool_calls ?? []) if (!tools.includes(t)) tools.push(t);
        }
    }
    const meta = [];
    if (tools.length) meta.push('Tools used: ' + tools.join(', '));
    if (conversationId) meta.push('conversation_id: ' + conversationId);
    const parts = [answer.trim(), ...errors];
    if (meta.length) parts.push('---\\n' + meta.join('\\n'));
    return parts.filter(Boolean).join('\\n\\n') || data;
}
`;
src = src.replace(anchor, 'const response = await this.requestWithRetry(axiosConfig);\n            return __amcpCollapseSse(response);');
src = src.replace(/\n\/\/# sourceMappingURL=rest\.engine\.js\.map\s*$/, helper + '//# sourceMappingURL=rest.engine.js.map\n');
if (!src.includes('function __amcpCollapseSse')) { console.error('FATAL: helper not appended'); process.exit(1); }
fs.writeFileSync(target, src);
console.log('PATCH OK: SSE collapse ->', target);
