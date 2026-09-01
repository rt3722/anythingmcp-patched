# anythingmcp-patched

A one-layer Docker image on top of [`helpcodeai/anythingmcp:latest`](https://hub.docker.com/r/helpcodeai/anythingmcp)
that makes the REST connector's request timeout configurable at runtime.

Nothing is built from source. This repo is a single `Dockerfile` that patches the
compiled backend bundle already shipped in the upstream image.

## What's patched

Upstream pins the axios timeout as a literal in the REST connector's request
config — [`packages/backend/src/connectors/engines/rest.engine.ts:96`](https://github.com/HelpCode-ai/anythingmcp/blob/main/packages/backend/src/connectors/engines/rest.engine.ts#L96):

```ts
const axiosConfig: AxiosRequestConfig = {
  method: endpointMapping.method as Method,
  url,
  headers: { ...config.headers, ...resolvedEndpointHeaders },
  timeout: 30000,
};
```

This image rewrites that in the compiled `rest.engine.js` to:

```js
timeout: Number(process.env.CONNECTOR_TIMEOUT_MS || 30000)
```

## Why

The 30 000 ms ceiling is not adjustable. It is not a connector setting, and
`CONNECTOR_TIMEOUT_MS` — or any timeout key — appears nowhere in the upstream
`.env.example`; the value only exists as a literal in the request config object.
Any upstream API call that takes longer than 30 s is aborted, which is a real
limit for slow report/export/search endpoints.

After this patch the timeout is set from the environment, so it can be changed
from the Railway dashboard (or any other env source) and applied with a restart —
no rebuild, no fork of the monorepo.

## Usage

```
CONNECTOR_TIMEOUT_MS=120000
```

With the variable **unset or empty, behaviour is identical to upstream** (30 000 ms),
because of the `|| 30000` fallback.

Build it yourself and deploy the result:

```sh
docker build -t anythingmcp-patched .
```

On Railway, point the service at this repo and set `CONNECTOR_TIMEOUT_MS` as a
service variable.

## Scope and caveats

- **REST only.** The same hardcoded `30000` also appears in `soap.engine`,
  `graphql.engine`, `graphql-schema.service` and `graphql.parser`. Those are
  deliberately left untouched; only `rest.engine.js` is patched.
- **The value is not validated.** A non-numeric `CONNECTOR_TIMEOUT_MS` yields
  `NaN`. Set an integer number of milliseconds.
- **Tracks `helpcodeai/anythingmcp:latest`.** There is no version pin, so a
  rebuild picks up whatever `latest` currently is. If upstream changes that line,
  the build **fails loudly** rather than shipping an unpatched image (see below).
  Pin the base to a digest in `Dockerfile` if you want reproducible rebuilds.
- Patching the compiled `.js` desynchronises the adjacent `rest.engine.js.map`
  source map by one expression. Harmless at runtime.

## Fail-loud guarantee

The patch step runs under `set -eux` and aborts the build unless every check
passes:

1. Exactly one `rest.engine.js` exists outside `node_modules` (path is
   **discovered at build time**, not hardcoded, so an upstream layout change is
   caught rather than silently skipped).
2. The pre-patch literal is present **exactly once**.
3. The post-patch string is present exactly once afterwards.
4. No unpatched `timeout: 30000` survives.

The occurrence checks are anchored on the trailing digit boundary, because a
naive `grep 'timeout: 30000'` also matches `timeout: 300000` and would happily
"verify" the wrong value. Two patterns are used rather than `([^0-9]|$)`, since
`$` inside an alternation group is not portable across the BusyBox/musl regex
implementation in this Alpine-based image.

The resolved path is written to `/etc/anythingmcp-patched.path` so the patch can
be re-inspected from a running container:

```sh
docker run --rm --entrypoint sh anythingmcp-patched -c \
  'grep -n "timeout:" "$(cat /etc/anythingmcp-patched.path)"'
```

## Upstream

- Project: <https://github.com/HelpCode-ai/anythingmcp> (AGPL-3.0-only)
- Base image: `helpcodeai/anythingmcp:latest`

This repo contains no upstream code — only the `Dockerfile` that layers on the
published image.
