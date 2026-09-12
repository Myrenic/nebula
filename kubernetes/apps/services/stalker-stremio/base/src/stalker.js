import { createHash } from 'node:crypto';

const MAG_UA =
  'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const backoffMs = (attempt) =>
  Math.min(500 * 2 ** attempt, 5000) + Math.floor(Math.random() * 250);

/**
 * Normalise whatever the user pasted into a Stalker `load.php`/`portal.php`
 * endpoint. Handles the common shapes:
 *   http://host:port/c/
 *   http://host:port/stalker_portal/c/
 *   http://host:port/portal.php
 *   http://host:port/stalker_portal/server/load.php
 */
export function normalisePortalUrl(input) {
  const url = new URL(input);
  const path = url.pathname.replace(/\/+$/, '');
  if (path.endsWith('/load.php') || path.endsWith('/portal.php')) {
    return url.origin + path;
  }
  if (path.includes('/stalker_portal')) {
    return url.origin + '/stalker_portal/server/load.php';
  }
  return url.origin + '/portal.php';
}

/** Stalker `create_link` returns a command like `ffmpeg http://...`; pull the URL out. */
export function parseStreamCmd(raw) {
  return String(raw)
    .trim()
    .replace(/^(?:ffmpeg|auto|mpegts?|hls)\s+/i, '');
}

/**
 * Portals hand out stream URLs on `localhost`/`0.0.0.0`; the real host is the
 * portal's. Rewrite the origin only when the host is clearly unusable.
 */
export function rewriteStreamHost(streamUrl, endpoint) {
  try {
    const stream = new URL(streamUrl);
    if (!/^(localhost|127\.0\.0\.1|0\.0\.0\.0)$/i.test(stream.hostname)) {
      return stream.toString();
    }
    const portal = new URL(endpoint);
    stream.protocol = portal.protocol;
    stream.host = portal.host;
    return stream.toString();
  } catch {
    return streamUrl;
  }
}

/**
 * Some portals return a fully-qualified play URL directly in the channel's
 * `cmd` (and their `create_link` API is broken, returning an empty `stream=`).
 * Use that URL as-is. Only `localhost` / unspecified hosts need `create_link`.
 */
export function playableUrlFromCmd(cmd) {
  const url = parseStreamCmd(cmd);
  if (!/^https?:\/\//i.test(url)) return null;
  let hostname;
  try {
    hostname = new URL(url).hostname;
  } catch {
    return null;
  }
  if (/^(localhost|127\.0\.0\.1|0\.0\.0\.0)$/i.test(hostname)) return null;
  return url;
}

export class StalkerPortal {
  constructor({ portalUrl, mac, serial, deviceId, timezone, language, userAgent } = {}) {
    if (!portalUrl) throw new Error('portalUrl is required');
    if (!mac) throw new Error('mac is required');
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(mac)) {
      throw new Error('mac must look like 00:1A:79:AA:BB:CC');
    }

    this.endpoint = normalisePortalUrl(portalUrl);
    const origin = new URL(this.endpoint).origin;
    this.referer = this.endpoint.includes('/stalker_portal/')
      ? `${origin}/stalker_portal/c/index.html`
      : `${origin}/c/index.html`;

    this.mac = mac.toUpperCase();
    // MAG devices derive these from the MAC; allow overrides to match a real box.
    this.serial =
      serial || createHash('md5').update(this.mac).digest('hex').slice(0, 13).toUpperCase();
    this.deviceId =
      deviceId || createHash('sha256').update(this.mac).digest('hex').toUpperCase();
    this.timezone = timezone || 'UTC';
    this.language = language || 'en';
    this.userAgent = userAgent || MAG_UA;

    this.token = null;
    this.cookies = new Map();

    // Serialise portal calls: some panels rate-limit (429) on bursty requests.
    this._queue = Promise.resolve();

    this._channels = null;
    this._channelsAt = 0;
    this._channelsTtlMs = 5 * 60 * 1000;
    this._genres = null;
    this._genresAt = 0;
    // Resolved play links, reused across playback. Re-minting
    // create_link per refresh starts a new portal session and kills the old one.
    this._links = new Map();
    this._linkTtlMs = 30 * 60 * 1000;
  }

  cookieString() {
    const parts = [
      `mac=${this.mac}`,
      `stb_lang=${this.language}`,
      `timezone=${this.timezone}`,
    ];
    if (this.token) parts.push(`token=${this.token}`);
    for (const [key, value] of this.cookies) parts.push(`${key}=${value}`);
    return parts.join('; ');
  }

  headers({ auth = true } = {}) {
    const headers = {
      'User-Agent': this.userAgent,
      'X-User-Agent': 'Model: MAG250; Link: WiFi',
      Referer: this.referer,
      Accept: '*/*',
      Cookie: this.cookieString(),
    };
    if (auth && this.token) headers.Authorization = `Bearer ${this.token}`;
    return headers;
  }

  /** Headers needed to fetch the actual media stream from the portal. */
  streamHeaders() {
    return this.headers();
  }

  captureCookies(response) {
    const setCookies = response.headers.getSetCookie?.() ?? [];
    for (const cookie of setCookies) {
      const [pair] = cookie.split(';');
      const index = pair.indexOf('=');
      if (index > 0) {
        this.cookies.set(pair.slice(0, index).trim(), pair.slice(index + 1).trim());
      }
    }
  }

  /** Raw single portal call. Returns { status, ok, json, text }. */
  async _requestOnce(params, { auth = true } = {}) {
    const url = new URL(this.endpoint);
    for (const [key, value] of Object.entries(params)) {
      url.searchParams.set(key, value);
    }
    url.searchParams.set('JsHttpRequest', '1-xml');

    const response = await fetch(url, {
      headers: this.headers({ auth }),
      redirect: 'follow',
    });
    this.captureCookies(response);

    const text = await response.text();
    let json;
    try {
      json = JSON.parse(text);
    } catch {
      json = undefined;
    }
    return { status: response.status, ok: response.ok, json, text };
  }

  /** Re-run the handshake in place (used when a session goes invalid). */
  async _rehandshake() {
    const res = await this._requestOnce(
      { type: 'stb', action: 'handshake', token: '' },
      { auth: false }
    );
    const token = res.json?.js?.token ?? (typeof res.json?.js === 'string' ? res.json.js : undefined);
    if (token) this.token = token;
    await this._requestOnce({ type: 'stb', action: 'get_profile' });
  }

  /**
   * Serialised portal request with retry/backoff. All calls go through here, so
   * a portal never sees concurrent bursts; 429/5xx are retried; an invalidated
   * session triggers one re-handshake.
   */
  request(params, options = {}) {
    const run = () => this._requestWithRetry(params, options);
    const result = this._queue.then(run, run);
    this._queue = result.then(
      () => undefined,
      () => undefined
    );
    return result;
  }

  async _requestWithRetry(params, options = {}) {
    const maxAttempts = 4;
    let lastError;
    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      let res;
      try {
        res = await this._requestOnce(params, options);
      } catch (error) {
        lastError = error;
        await sleep(backoffMs(attempt));
        continue;
      }

      if ((res.status === 429 || res.status >= 500) && attempt < maxAttempts - 1) {
        await sleep(backoffMs(attempt));
        continue;
      }
      if ((res.status === 401 || res.status === 403) && this.token && !options.retriedAuth) {
        await this._rehandshake();
        return this._requestWithRetry(params, { ...options, retriedAuth: true });
      }
      if (!res.ok) {
        throw new Error(`portal request failed: ${res.status}`);
      }
      if (res.json === undefined) {
        throw new Error(`portal returned non-JSON: ${res.text.slice(0, 200)}`);
      }
      return res.json && typeof res.json === 'object' && 'js' in res.json
        ? res.json.js
        : res.json;
    }
    throw lastError ?? new Error('portal request failed after retries');
  }

  /** Handshake + profile. Must be called before anything else. */
  async init() {
    const handshake = await this.request(
      { type: 'stb', action: 'handshake', token: '' },
      { auth: false }
    );
    const token = typeof handshake === 'string' ? handshake : handshake?.token;
    if (!token) throw new Error('portal handshake did not return a token');
    this.token = token;

    await this.request({ type: 'stb', action: 'get_profile' });
    return this;
  }

  /** All live TV channels, cached briefly (portals can serve thousands). */
  async getChannels({ fresh = false } = {}) {
    if (!fresh && this._channels && Date.now() - this._channelsAt < this._channelsTtlMs) {
      return this._channels;
    }
    const js = await this.request({ type: 'itv', action: 'get_all_channels' });
    const data = Array.isArray(js) ? js : js?.data ?? [];
    this._channels = data.map((channel) => ({
      id: String(channel.id),
      name: channel.name ?? `Channel ${channel.id}`,
      number: channel.number,
      cmd: channel.cmd,
      genreId: channel.tv_genre_id ? String(channel.tv_genre_id) : undefined,
      logo: channel.logo || channel.tv_icon || channel.logo_url || undefined,
    }));
    this._channelsAt = Date.now();
    return this._channels;
  }

  /** Portal genres/categories, cached briefly. The `*` "All" entry is dropped. */
  async getGenres({ fresh = false } = {}) {
    if (!fresh && this._genres && Date.now() - this._genresAt < this._channelsTtlMs) {
      return this._genres;
    }
    const js = await this.request({ type: 'itv', action: 'get_genres' });
    const data = Array.isArray(js) ? js : js?.data ?? [];
    this._genres = data
      .filter((genre) => String(genre.id) !== '*')
      .map((genre) => ({
        id: String(genre.id),
        name: genre.title ?? genre.name ?? String(genre.id),
      }));
    this._genresAt = Date.now();
    return this._genres;
  }

  /**
   * Resolve a channel into a playable URL. Accepts a channel object or a raw
   * `cmd` string. Cached per channel so repeated playback reuses the same
   * portal session (re-minting create_link each refresh drops the old session).
   */
  async createLink(channelOrCmd) {
    const cmd = typeof channelOrCmd === 'string' ? channelOrCmd : channelOrCmd?.cmd;
    if (!cmd) throw new Error('create_link requires a cmd');

    const cached = this._links.get(cmd);
    const now = Date.now();
    if (cached && now - cached.at < this._linkTtlMs) return cached.url;

    // Prefer the portal's own fully-qualified URL when it provides one, else resolve.
    let url = playableUrlFromCmd(cmd);
    if (!url) {
      const js = await this.request({
        type: 'itv',
        action: 'create_link',
        cmd,
        forced_storage: '',
        disable_ad: '0',
        download: '0',
      });
      const raw = typeof js === 'string' ? js : js?.cmd;
      if (!raw) throw new Error('create_link did not return a stream URL');
      url = rewriteStreamHost(parseStreamCmd(raw), this.endpoint);
    }
    this._links.set(cmd, { url, at: now });
    return url;
  }

  async resolveChannel(channelId) {
    const channels = await this.getChannels();
    return channels.find((channel) => channel.id === String(channelId));
  }
}
