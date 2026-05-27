#!/usr/bin/env node
// tests/e2e.mjs — Real end-to-end test against the live searxng-mcp-stack.
//
// Drives the MCP HTTP endpoint exclusively through the official
// @modelcontextprotocol/sdk client. No raw HTTP, no mocks, no fixtures —
// any failure surfaces as a real integration regression.
//
// Pass criteria (in order):
//   1. Client connects to http://127.0.0.1:${MCP_HTTP_PORT||3000}/mcp.
//   2. tools/list contains BOTH `searxng_web_search` and `web_url_read`.
//   3. searxng_web_search({query:"github"}) returns content[0].text that
//      matches the /https?:\/\// regex (i.e. a real result with a URL).
//
// Exit codes:
//   0 → stdout "[e2e] PASS"
//   1 → stderr "[e2e] FAIL: <reason>"
//
// A 30s watchdog (via setTimeout) guarantees the script terminates even if
// the SDK hangs on a half-open socket — required for the "stack down"
// negative case to exit under the 35s budget.

import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

// Watchdog: covers ALL failure modes (DNS, ECONNREFUSED retries, hung
// keepalive sockets, server accepting TCP but never replying). unref() so
// the timer never keeps the process alive on its own when we exit cleanly.
const TIMEOUT = setTimeout(() => {
  console.error("[e2e] FAIL: timeout 30s");
  process.exit(1);
}, 30000);
TIMEOUT.unref?.();

const PORT = process.env.MCP_HTTP_PORT || "3000";
const ENDPOINT = `http://127.0.0.1:${PORT}/mcp`;

let client;
try {
  // Use the global URL class (must NOT be shadowed) for the transport.
  const transport = new StreamableHTTPClientTransport(new URL(ENDPOINT));
  client = new Client(
    { name: "searxng-mcp-opencode-e2e", version: "0.1.0" },
    {},
  );

  await client.connect(transport);

  // --- Assertion 1: both tools are advertised. ---
  const listed = await client.listTools();
  const names = new Set((listed?.tools ?? []).map((t) => t.name));
  if (!names.has("searxng_web_search")) {
    throw new Error(
      `tools/list missing searxng_web_search (got: ${[...names].join(",") || "none"})`,
    );
  }
  if (!names.has("web_url_read")) {
    throw new Error(
      `tools/list missing web_url_read (got: ${[...names].join(",")})`,
    );
  }

  // --- Assertion 2: searxng_web_search returns at least one URL. ---
  // Engine results are flaky — DO NOT assert on count, ordering, or specific
  // URLs. Only the looser "text content contains an http(s):// URL" invariant.
  const res = await client.callTool({
    name: "searxng_web_search",
    arguments: { query: "github" },
  });

  const first = res?.content?.[0];
  if (!first || first.type !== "text" || typeof first.text !== "string") {
    throw new Error(
      `searxng_web_search returned no text content (got: ${JSON.stringify(res)?.slice(0, 200)})`,
    );
  }
  if (!/https?:\/\//.test(first.text)) {
    throw new Error(
      `searxng_web_search content has no http(s) URL (first 200 chars: ${first.text.slice(0, 200)})`,
    );
  }

  await client.close();
  console.log("[e2e] PASS");
  process.exit(0);
} catch (err) {
  // Be resilient: client may be undefined if construction itself threw.
  try {
    await client?.close?.();
  } catch {
    // swallow — original error is what we want to surface
  }
  const reason = err?.message || String(err);
  console.error(`[e2e] FAIL: ${reason}`);
  process.exit(1);
}
