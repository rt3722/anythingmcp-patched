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

FROM helpcodeai/anythingmcp:latest

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

# Drop back to the unprivileged user the upstream runner stage sets.
USER appuser

LABEL org.opencontainers.image.title="anythingmcp-patched" \
      org.opencontainers.image.description="AnythingMCP with a configurable REST connector timeout (CONNECTOR_TIMEOUT_MS)." \
      org.opencontainers.image.base.name="docker.io/helpcodeai/anythingmcp:latest" \
      org.opencontainers.image.source="https://github.com/rt3722/anythingmcp-patched"

# ENTRYPOINT/CMD, EXPOSE and HEALTHCHECK are inherited from the upstream image.
