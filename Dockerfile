# =============================================================================
# anythingmcp-patched — make the REST connector timeout configurable
# =============================================================================
# Layers on the upstream prebuilt image and patches the *compiled* backend
# bundle. Nothing is rebuilt from source; this is a sed over the shipped tsc
# output.
#
# Upstream source (packages/backend/src/connectors/engines/rest.engine.ts:96):
#
#     const axiosConfig: AxiosRequestConfig = {
#       ...
#       timeout: 30000,
#     };
#
# That 30000 ms ceiling is not exposed as a connector setting and does not
# appear anywhere in .env.example — it is a literal in the request config, so
# any upstream API call slower than 30s is aborted. This image rewrites it to:
#
#     timeout: Number(process.env.CONNECTOR_TIMEOUT_MS || 30000)
#
# so it can be tuned from the Railway dashboard (or any env) without a rebuild.
# With CONNECTOR_TIMEOUT_MS unset, behaviour is identical to upstream.
#
# Scope: rest.engine.js only. The same hardcoded 30000 also exists in
# soap.engine, graphql.engine, graphql-schema.service and graphql.parser;
# those are deliberately left alone.
# =============================================================================

# Pinned to the exact upstream build that has been running in production since
# 2026-09-01, so rebuilding this repo never silently upgrades AnythingMCP (and
# its DB migrations). Bump deliberately; every patch step below re-verifies its
# anchor and fails the build if upstream moved it.
FROM helpcodeai/anythingmcp:latest@sha256:d029b2c4735b9d17f5833e042fbf2343d6138edb1410c95e870b39973fdfbc11

# Upstream's final stage ends on `USER appuser`; become root to edit the bundle.
USER root

RUN set -eux; \
    \
    # ---- 1. Locate the compiled REST engine --------------------------------
    # Discovered at build time rather than hardcoded, so an upstream layout
    # change surfaces as a build failure instead of a silent no-op patch.
    matches="$(find / -name 'rest.engine.js' -not -path '*/node_modules/*' -type f 2>/dev/null)"; \
    echo "rest.engine.js candidates:"; echo "$matches"; \
    count="$(printf '%s\n' "$matches" | grep -c . || true)"; \
    if [ "$count" -ne 1 ]; then \
        echo "FATAL: expected exactly 1 rest.engine.js outside node_modules, found ${count}" >&2; \
        exit 1; \
    fi; \
    target="$matches"; \
    [ -f "$target" ] || { echo "FATAL: '${target}' is not a regular file" >&2; exit 1; }; \
    echo "target: ${target}"; \
    \
    # ---- 2. Assert the pre-patch literal is present exactly once -----------
    # A bare `grep 'timeout: 30000'` ALSO matches `timeout: 300000`, so the
    # trailing digit boundary is anchored explicitly. Two patterns are used
    # instead of `([^0-9]|$)` because `$` inside an alternation group is not
    # portable across BusyBox/musl regex (this image is Alpine-based).
    before="$(grep -oE -e 'timeout: 30000[^0-9]' -e 'timeout: 30000$' "$target" | wc -l | tr -d '[:space:]')"; \
    if [ "$before" -ne 1 ]; then \
        echo "FATAL: expected exactly 1 occurrence of 'timeout: 30000' in ${target}, found ${before}" >&2; \
        echo "--- all timeout occurrences ---" >&2; \
        grep -n 'timeout' "$target" >&2 || true; \
        exit 1; \
    fi; \
    echo "--- BEFORE ---"; \
    grep -nE -e 'timeout: 30000[^0-9]' -e 'timeout: 30000$' "$target"; \
    \
    # ---- 3. Apply the patch ------------------------------------------------
    # First expression handles the literal followed by any non-digit (e.g. a
    # trailing comma); second handles it sitting at end-of-line, where `$` is
    # an unambiguous anchor. Exactly one of the two fires.
    sed -i -E \
        -e 's/timeout: 30000([^0-9])/timeout: Number(process.env.CONNECTOR_TIMEOUT_MS || 30000)\1/g' \
        -e 's/timeout: 30000$/timeout: Number(process.env.CONNECTOR_TIMEOUT_MS || 30000)/' \
        "$target"; \
    \
    # ---- 4. Assert the post-patch string landed ----------------------------
    after="$(grep -cF 'timeout: Number(process.env.CONNECTOR_TIMEOUT_MS || 30000)' "$target" || true)"; \
    if [ "$after" -ne 1 ]; then \
        echo "FATAL: post-patch string not found exactly once in ${target} (found ${after})" >&2; \
        exit 1; \
    fi; \
    # ...and that no unpatched literal survived.
    leftover="$(grep -oE -e 'timeout: 30000[^0-9]' -e 'timeout: 30000$' "$target" | wc -l | tr -d '[:space:]')"; \
    if [ "$leftover" -ne 0 ]; then \
        echo "FATAL: ${leftover} unpatched 'timeout: 30000' occurrence(s) remain in ${target}" >&2; \
        exit 1; \
    fi; \
    echo "--- AFTER ---"; \
    grep -nF 'timeout: Number(process.env.CONNECTOR_TIMEOUT_MS || 30000)' "$target"; \
    \
    # Record the patched path so it can be re-inspected from a running container.
    echo "$target" > /etc/anythingmcp-patched.path; \
    echo "PATCH OK: ${target}"

# ── OpenAPI importer: resolve anyOf/oneOf/$ref types ─────────────────────────
# Upstream flattenSchema() imports any body property without a top-level
# `type` as 'string'. FastAPI/pydantic specs (Nansen) wrap optional fields in
# `anyOf`, so `filters` (object), `order_by` (array), booleans and numbers all
# became strings, and MCP clients sent them as JSON text that the API rejects.
# See patches/openapi-anyof-types.js. Only affects future imports/refreshes;
# tools already in the DB must be corrected separately (done 2026-09-24).
COPY patches/openapi-anyof-types.js /tmp/openapi-anyof-types.js
RUN set -eux; \
    matches="$(find / -name 'openapi.parser.js' -not -path '*/node_modules/*' -type f 2>/dev/null)"; \
    count="$(printf '%s\n' "$matches" | grep -c . || true)"; \
    if [ "$count" -ne 1 ]; then \
        echo "FATAL: expected exactly 1 openapi.parser.js outside node_modules, found ${count}" >&2; \
        exit 1; \
    fi; \
    node /tmp/openapi-anyof-types.js "$matches"; \
    node --check "$matches"; \
    rm /tmp/openapi-anyof-types.js

# ── REST engine: per-request timestamp + client_id (GMGN) ───────────────────
# GMGN's OpenAPI requires a fresh unix `timestamp` (±5s) and a single-use
# `client_id` UUID on every request, which static connector auth can't supply.
# See patches/request-nonce.js. Scoped to hosts in NONCE_AUTH_HOSTS
# (default openapi.gmgn.ai); all other connectors are unaffected.
COPY patches/request-nonce.js /tmp/request-nonce.js
RUN set -eux; \
    target="$(cat /etc/anythingmcp-patched.path)"; \
    node /tmp/request-nonce.js "$target"; \
    node --check "$target"; \
    rm /tmp/request-nonce.js

# Drop back to the unprivileged user the upstream runner stage sets.
USER appuser

LABEL org.opencontainers.image.title="anythingmcp-patched" \
      org.opencontainers.image.description="AnythingMCP with a configurable REST connector timeout (CONNECTOR_TIMEOUT_MS), anyOf-aware OpenAPI import, and per-request nonce auth for GMGN." \
      org.opencontainers.image.base.name="docker.io/helpcodeai/anythingmcp:latest" \
      org.opencontainers.image.source="https://github.com/rt3722/anythingmcp-patched"

# ENTRYPOINT/CMD, EXPOSE and HEALTHCHECK are inherited from the upstream image.
