import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { dirname, join } from 'node:path';
import { Readable } from 'node:stream';
import { StalkerPortal } from './stalker.js';
import {
  buildManifest,
  buildStreams,
  channelToCatalogMeta,
  channelToMeta,
  paginateChannels,
  parseMediaId,
  selectChannels,
  CATALOG_TV,
} from './addon.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PORTAL_TTL_MS = 10 * 60 * 1000;
const portalCache = new Map();

export function encodeConfig(config) {
  return Buffer.from(JSON.stringify(config)).toString('base64url');
}

export function decodeConfig(token) {
  const config = JSON.parse(Buffer.from(token, 'base64url').toString('utf8'));
  if (!config.portalUrl || !config.mac) {
    throw new Error('config is missing portalUrl or mac');
  }
  return config;
}

async function getPortal(key, config) {
  const cached = portalCache.get(key);
  if (cached && Date.now() - cached.at < PORTAL_TTL_MS) return cached.portal;
  try {
    const portal = new StalkerPortal(config);
    await portal.init();
    portalCache.set(key, { portal, at: Date.now() });
    return portal;
  } catch (error) {
    // If a previous session exists, keep using it rather than failing the request.
    if (cached) {
      console.error(`[portal] refresh failed, reusing existing session: ${error.message}`);
      return cached.portal;
    }
    throw error;
  }
}

/** Cache portals by credentials too, so config-page calls share one handshake. */
function getPortalByCreds({ portalUrl, mac, timezone, serial, deviceId, userAgent }) {
  const key = `creds:${portalUrl}|${mac}|${serial ?? ''}|${deviceId ?? ''}|${userAgent ?? ''}|${timezone ?? ''}`;
  return getPortal(key, { portalUrl, mac, timezone, serial, deviceId, userAgent });
}

/** Pull the shared credential params out of a config-page URL. */
function readCredsFromQuery(url) {
  return {
    portalUrl: url.searchParams.get('portalUrl'),
    mac: url.searchParams.get('mac'),
    timezone: url.searchParams.get('timezone') || undefined,
    serial: url.searchParams.get('serial') || undefined,
    deviceId: url.searchParams.get('deviceId') || undefined,
    userAgent: url.searchParams.get('userAgent') || undefined,
  };
}

function json(res, status, body) {
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'access-control-allow-origin': '*',
  });
  res.end(JSON.stringify(body));
}

function stripJson(value) {
  return value?.replace(/\.json$/, '');
}

/** Stremio may percent-encode ":"-containing media ids; decode defensively. */
function safeDecode(value) {
  if (!value) return value;
  try {
    return decodeURIComponent(value);
  } catch {
    return value;
  }
}

const configUi = readFileSync(join(__dirname, 'config-ui.html'), 'utf8');

/** Absolute base of this addon as seen by the requesting client. */
function baseUrl(req) {
  const proto = req.headers['x-forwarded-proto']?.split(',')[0] || 'http';
  const host = req.headers['x-forwarded-host'] || req.headers.host;
  return `${proto}://${host}`;
}

async function handleCatalog(res, key, config, rest) {
  const type = rest[1];
  const catalogId = stripJson(rest[2]);
  if (type !== 'tv' || catalogId !== CATALOG_TV) {
    return json(res, 200, { metas: [] });
  }
  const extra = new URLSearchParams(rest[3] ? safeDecode(stripJson(rest[3])) : '');
  const skip = extra.get('skip');
  let channels;
  try {
    const portal = await getPortal(key, config);
    channels = selectChannels(await portal.getChannels(), config);
  } catch (error) {
    console.error(`[catalog] ${error.message}`);
    return json(res, 200, { metas: [] });
  }
  const metas = paginateChannels(channels, {
    search: extra.get('search') || undefined,
    skip: skip ? Number(skip) : undefined,
  }).map(channelToCatalogMeta);
  json(res, 200, { metas });
}

async function handleMeta(res, key, config, type, id) {
  const parsed = parseMediaId(id);
  if (type !== 'tv' || !parsed) return json(res, 200, { meta: null });
  try {
    const portal = await getPortal(key, config);
    const channel = await portal.resolveChannel(parsed.portalId);
    json(res, 200, { meta: channel ? channelToMeta(channel) : null });
  } catch (error) {
    console.error(`[meta] ${error.message}`);
    json(res, 200, { meta: null });
  }
}

async function handleStream(req, res, key, config, type, id) {
  const parsed = parseMediaId(id);
  if (type !== 'tv' || !parsed) return json(res, 200, { streams: [] });

  let portal;
  let channel;
  try {
    portal = await getPortal(key, config);
    channel = await portal.resolveChannel(parsed.portalId);
  } catch (error) {
    console.error(`[stream] portal error: ${error.message}`);
    return json(res, 200, {
      streams: [{ name: 'Stalker', title: 'Portal error', description: error.message }],
    });
  }
  if (!channel) return json(res, 200, { streams: [] });

  let tsUrl;
  try {
    tsUrl = await portal.createLink(channel);
  } catch (error) {
    console.error(`[stream] createLink failed for ${channel.id}: ${error.message}`);
    return json(res, 200, {
      streams: [{ name: 'Stalker', title: 'Failed to resolve stream', description: error.message }],
    });
  }

  // "direct" = the client fetches the portal itself (most box-like);
  // "proxy" = the addon fetches for the client (works behind a client HTTP proxy).
  const viaProxy = config.streamRoute === 'proxy';
  const streamUrl = viaProxy
    ? `${baseUrl(req)}/${key}/proxy/tv/${encodeURIComponent(channel.id)}`
    : tsUrl;

  json(res, 200, {
    streams: buildStreams({
      channel,
      streamUrl,
      requestHeaders: viaProxy ? undefined : portal.streamHeaders(),
    }),
  });
}

async function handleTsProxy(req, res, key, config, channelId) {
  const portal = await getPortal(key, config);
  const channel = await portal.resolveChannel(channelId);
  if (!channel) {
    res.writeHead(404, { 'access-control-allow-origin': '*' });
    res.end('channel not found');
    return;
  }

  const link = await portal.createLink(channel);

  let upstream;
  try {
    upstream = await fetch(link, { headers: portal.streamHeaders(), redirect: 'follow' });
  } catch (error) {
    console.error(`[proxy] upstream unreachable for ${channelId}: ${error.message}`);
    return json(res, 502, { error: 'Provider CDN node unreachable for this channel' });
  }

  // Some provider CDN nodes reject channels with 407 (proxy auth) or 5xx.
  if (upstream.status === 407 || upstream.status >= 500) {
    await upstream.body?.cancel?.().catch(() => {});
    console.error(`[proxy] upstream ${upstream.status} for ${channelId}`);
    return json(res, 502, {
      error: `Provider CDN rejected this channel (HTTP ${upstream.status})`,
    });
  }

  const headers = {
    'content-type': upstream.headers.get('content-type') || 'video/mp2t',
    'access-control-allow-origin': '*',
    'cache-control': 'no-store',
  };
  const length = upstream.headers.get('content-length');
  if (length) headers['content-length'] = length;

  res.writeHead(upstream.status, headers);
  if (req.method === 'HEAD' || !upstream.body) {
    res.end();
    return;
  }
  Readable.fromWeb(upstream.body).pipe(res);
  req.on('close', () => upstream.body?.cancel?.().catch(() => {}));
}

async function handleTest(url, res) {
  const creds = readCredsFromQuery(url);
  if (!creds.portalUrl || !creds.mac) {
    return json(res, 400, { ok: false, error: 'portalUrl and mac are required' });
  }
  try {
    const portal = await getPortalByCreds(creds);
    const channels = await portal.getChannels();
    json(res, 200, {
      ok: true,
      channels: channels.length,
      sample: channels.slice(0, 5).map((channel) => channel.name),
    });
  } catch (error) {
    json(res, 200, { ok: false, error: error.message });
  }
}

/** Config-page data: genres + the channel list to whitelist from. */
async function handleGenres(url, res) {
  const creds = readCredsFromQuery(url);
  if (!creds.portalUrl || !creds.mac) {
    return json(res, 400, { error: 'portalUrl and mac are required' });
  }
  try {
    const portal = await getPortalByCreds(creds);
    json(res, 200, { genres: await portal.getGenres() });
  } catch (error) {
    console.error(`[genres] ${error.message}`);
    json(res, 500, { error: error.message });
  }
}

async function handleChannels(url, res) {
  const creds = readCredsFromQuery(url);
  if (!creds.portalUrl || !creds.mac) {
    return json(res, 400, { error: 'portalUrl and mac are required' });
  }
  try {
    const portal = await getPortalByCreds(creds);
    const channels = (await portal.getChannels()).map((channel) => ({
      id: channel.id,
      name: channel.name,
      genreId: channel.genreId,
    }));
    json(res, 200, { channels });
  } catch (error) {
    console.error(`[channels] ${error.message}`);
    json(res, 500, { error: error.message });
  }
}

export async function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const parts = url.pathname.split('/').filter(Boolean);

  if (parts.length === 0) {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(configUi);
    return;
  }
  if (parts[0] === 'health') return json(res, 200, { ok: true });
  if (parts[0] === 'api' && parts[1] === 'test') return handleTest(url, res);
  if (parts[0] === 'api' && parts[1] === 'genres') return handleGenres(url, res);
  if (parts[0] === 'api' && parts[1] === 'channels') return handleChannels(url, res);

  const key = parts[0];
  let config;
  try {
    config = decodeConfig(key);
  } catch (error) {
    return json(res, 400, { error: error.message });
  }

  if (process.env.LOG_REQUESTS !== '0') {
    // Never log the config token (it is base64-encoded portal credentials),
    // and never log the query string (the /api/* routes carry the MAC there).
    const known = new Set(['', 'health', 'api']);
    const redacted = known.has(parts[0] ?? '')
      ? url.pathname
      : `/<config>/${parts.slice(1).join('/')}`;
    console.log(`${req.method} ${redacted}`);
  }
  if (parts[1] === 'manifest.json') return json(res, 200, buildManifest(config));
  if (parts[1] === 'catalog') return handleCatalog(res, key, config, parts.slice(1));
  if (parts[1] === 'meta')
    return handleMeta(res, key, config, parts[2], safeDecode(stripJson(parts[3])));
  if (parts[1] === 'stream')
    return handleStream(req, res, key, config, parts[2], safeDecode(stripJson(parts[3])));
  if (parts[1] === 'proxy') {
    return handleTsProxy(req, res, key, config, safeDecode(parts[3] ?? ''));
  }

  json(res, 404, { error: 'not found' });
}

export function createApp() {
  return createServer((req, res) => {
    handleRequest(req, res).catch((error) => {
      console.error(`[request] ${error.message}`);
      json(res, 500, { error: error.message });
    });
  });
}

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;
if (isMain) {
  const port = Number(process.env.PORT) || 7000;
  createApp().listen(port, () => {
    console.log(`stalker-stremio-addon listening on http://0.0.0.0:${port}`);
    console.log(`Open http://localhost:${port} to configure a portal.`);
  });
}
