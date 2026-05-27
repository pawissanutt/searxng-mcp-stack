#!/usr/bin/env node
// tests/load.mjs — 50 concurrent searches validate the pass_ip limiter whitelist.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";

const T = setTimeout(() => { console.error("[load] FAIL: timeout 60s"); process.exit(1); }, 60000);
T.unref?.();

const PORT = process.env.MCP_HTTP_PORT || "23000";
const ENDPOINT = `http://127.0.0.1:${PORT}/mcp`;
const POOL = ["github","openai","podman","valkey","linux","python","rust","node","docker","search"];

let client;
try {
  const transport = new StreamableHTTPClientTransport(new URL(ENDPOINT));
  client = new Client({ name: "searxng-mcp-opencode-load", version: "0.1.0" }, {});
  await client.connect(transport);

  const queries = Array.from({ length: 50 }, (_, i) => POOL[i % POOL.length]);
  const results = await Promise.allSettled(
    queries.map(q => client.callTool({ name: "searxng_web_search", arguments: { query: q } }))
  );

  let successes = 0;
  const failures = [];
  for (let i = 0; i < results.length; i++) {
    const r = results[i];
    if (r.status === "fulfilled") {
      const text = r.value?.content?.[0]?.text;
      (typeof text === "string" && /https?:\/\//.test(text)) ? successes++ : failures.push({ i, status: "fulfilled", snippet: String(text).slice(0, 120) });
    } else {
      failures.push({ i, status: "rejected", reason: String(r.reason?.message || r.reason).slice(0, 120) });
    }
  }

  if (failures.length > 0) {
    console.error("[load] FAIL: failures (if 403/429, check limiter.toml pass_ip and link_token):");
    for (const f of failures) console.error(`  #${f.i} ${f.status}: ${f.snippet || f.reason}`);
    await client.close(); process.exit(1);
  }
  if (successes !== 50) {
    console.error(`[load] FAIL: expected 50 successes, got ${successes} (if 403/429, check limiter.toml pass_ip and link_token)`);
    await client.close(); process.exit(1);
  }

  await client.close();
  console.log("[load] PASS (50/50)");
  process.exit(0);
} catch (err) {
  try { await client?.close?.(); } catch {}
  console.error(`[load] FAIL: ${err?.message || err} (if 403/429, check limiter.toml pass_ip and link_token)`);
  process.exit(1);
}
