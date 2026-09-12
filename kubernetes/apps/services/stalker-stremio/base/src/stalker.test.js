import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import {
  StalkerPortal,
  normalisePortalUrl,
  parseStreamCmd,
  rewriteStreamHost,
  playableUrlFromCmd,
} from './stalker.js';
import {
  parseMediaId,
  paginateChannels,
  channelMediaId,
  selectChannels,
} from './addon.js';
import { createApp, encodeConfig } from './server.js';

let server;
let base;
let lastHeaders = {};
let createLinkCalls = 0;
let failNextHandshake = false;
let failAllHandshakes = false;
let inFlight = 0;
let maxInFlight = 0;

before(async () => {
  server = createServer((req, res) => {
    lastHeaders = req.headers;
    const url = new URL(req.url, 'http://localhost');
    const action = url.searchParams.get('action');
    const type = url.searchParams.get('type');

    inFlight++;
    maxInFlight = Math.max(maxInFlight, inFlight);

    // Small delay so concurrent requests would overlap if not serialised.
    setTimeout(() => {
      if (action === 'handshake' && (failNextHandshake || failAllHandshakes)) {
        failNextHandshake = false;
        res.writeHead(failAllHandshakes ? 400 : 429, { 'content-type': 'application/json' });
        res.end('{}');
        inFlight--;
        return;
      }

      let payload;
      if (action === 'handshake') {
        payload = { js: { token: 'tok123' } };
      } else if (action === 'get_profile') {
        payload = { js: { id: '1', name: 'Mock Portal' } };
      } else if (type === 'itv' && action === 'get_all_channels') {
        payload = {
          js: {
            data: [
              {
                id: '101',
                name: 'BBC One',
                number: '1',
                cmd: 'ffmpeg http://localhost/ch/101_',
                tv_genre_id: '5',
                logo: 'http://logos/101.png',
              },
            ],
          },
        };
      } else if (type === 'itv' && action === 'get_genres') {
        payload = {
          js: [
            { id: '*', title: 'All' },
            { id: '5', title: 'Netherlands' },
          ],
        };
      } else if (type === 'itv' && action === 'create_link') {
        createLinkCalls++;
        payload = { js: { cmd: 'ffmpeg http://localhost/ch/101_play' } };
      } else {
        payload = { js: {} };
      }

      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify(payload));
      inFlight--;
    }, 15);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  base = `http://127.0.0.1:${server.address().port}`;
});

after(() => server.close());

test('normalisePortalUrl handles the common portal shapes', () => {
  assert.equal(normalisePortalUrl('http://h:8080/c/'), 'http://h:8080/portal.php');
  assert.equal(
    normalisePortalUrl('http://h/stalker_portal/c/'),
    'http://h/stalker_portal/server/load.php'
  );
  assert.equal(normalisePortalUrl('http://h/portal.php'), 'http://h/portal.php');
  assert.equal(
    normalisePortalUrl('http://h/stalker_portal/server/load.php'),
    'http://h/stalker_portal/server/load.php'
  );
});

test('parseStreamCmd strips the player prefix', () => {
  assert.equal(parseStreamCmd('ffmpeg http://x/y'), 'http://x/y');
  assert.equal(parseStreamCmd('auto http://x/y.m3u8'), 'http://x/y.m3u8');
  assert.equal(parseStreamCmd('http://x/y'), 'http://x/y');
});

test('rewriteStreamHost only rewrites unusable hosts', () => {
  assert.equal(
    rewriteStreamHost('http://localhost/ch/1_', `${base}/portal.php`),
    `${base}/ch/1_`
  );
  assert.equal(
    rewriteStreamHost('http://cdn.example/ch/1_', `${base}/portal.php`),
    'http://cdn.example/ch/1_'
  );
});

test('playableUrlFromCmd trusts real hosts, rejects placeholders', () => {
  assert.equal(
    playableUrlFromCmd('ffmpeg http://portal.example:80/play/live.php?stream=1'),
    'http://portal.example:80/play/live.php?stream=1'
  );
  assert.equal(playableUrlFromCmd('ffmpeg http://localhost/ch/1_'), null);
  assert.equal(playableUrlFromCmd(''), null);
  assert.equal(playableUrlFromCmd('not a url'), null);
});

test('createLink prefers a fully-qualified cmd over the broken create_link API', async () => {
  const portal = new StalkerPortal({ portalUrl: `${base}/portal.php`, mac: '00:1A:79:AA:BB:CC' });
  await portal.init();
  const cmd =
    'ffmpeg http://portal.example:80/play/live.php?mac=00:1A:79:AA:BB:CC&stream=102&extension=ts&play_token=abc';
  // The mock's create_link returns a *different* (localhost) URL, so this
  // asserts the cmd URL was used and create_link was never consulted.
  assert.equal(
    await portal.createLink({ cmd }),
    'http://portal.example:80/play/live.php?mac=00:1A:79:AA:BB:CC&stream=102&extension=ts&play_token=abc'
  );
});

test('handshake, channel list, and create_link round trip', async () => {
  const portal = new StalkerPortal({ portalUrl: `${base}/portal.php`, mac: '00:1A:79:AA:BB:CC' });
  await portal.init();
  assert.equal(portal.token, 'tok123');

  const channels = await portal.getChannels({ fresh: true });
  assert.equal(channels.length, 1);
  assert.equal(channels[0].name, 'BBC One');
  assert.equal(channels[0].logo, 'http://logos/101.png');

  const link = await portal.createLink(channels[0].cmd);
  assert.equal(link, `${base}/ch/101_play`);
  assert.equal(lastHeaders.authorization, 'Bearer tok123');
  assert.match(lastHeaders.cookie, /mac=00:1A:79:AA:BB:CC/);
});

test('media ids and catalog pagination', () => {
  assert.deepEqual(parseMediaId(channelMediaId('101')), { type: 'tv', portalId: '101' });
  assert.equal(parseMediaId('garbage'), null);

  const channels = Array.from({ length: 250 }, (_, index) => ({
    id: String(index),
    name: 'Channel ' + index,
  }));
  assert.equal(paginateChannels(channels).length, 100);
  assert.equal(paginateChannels(channels, { skip: 200 }).length, 50);
  assert.deepEqual(
    paginateChannels(channels, { search: 'Channel 12' }).map((c) => c.id),
    ['12', '120', '121', '122', '123', '124', '125', '126', '127', '128', '129']
  );
});

test('selectChannels whitelists by genre or explicit id', () => {
  const channels = [
    { id: '1', name: 'NL One', genreId: '10' },
    { id: '2', name: 'NL Two', genreId: '10' },
    { id: '3', name: 'DE One', genreId: '20' },
  ];
  assert.equal(selectChannels(channels, {}).length, 3);
  assert.deepEqual(selectChannels(channels, { includeGenres: ['10'] }).map((c) => c.id), ['1', '2']);
  assert.deepEqual(selectChannels(channels, { includeChannels: ['3'] }).map((c) => c.id), ['3']);
  assert.deepEqual(
    selectChannels(channels, { includeGenres: ['10'], includeChannels: ['3'] }).map((c) => c.id),
    ['1', '2', '3']
  );
  assert.equal(selectChannels(channels, { includeGenres: ['999'] }).length, 0);
});

test('createLink caches the resolved link so repeated playback reuses the session', async () => {
  const portal = new StalkerPortal({ portalUrl: `${base}/portal.php`, mac: '00:1A:79:AA:BB:CC' });
  await portal.init();
  const before = createLinkCalls;
  const first = await portal.createLink('ffmpeg http://localhost/ch/101_');
  const second = await portal.createLink('ffmpeg http://localhost/ch/101_');
  assert.equal(first, second);
  assert.equal(createLinkCalls - before, 1);
});

test('userAgent override is sent to the portal', async () => {
  const portal = new StalkerPortal({
    portalUrl: `${base}/portal.php`,
    mac: '00:1A:79:AA:BB:CC',
    userAgent: 'CustomBox/1.0',
  });
  await portal.init();
  assert.equal(lastHeaders['user-agent'], 'CustomBox/1.0');
});

test('retries a 429 handshake', async () => {
  failNextHandshake = true;
  const portal = new StalkerPortal({ portalUrl: `${base}/portal.php`, mac: '00:1A:79:AA:BB:CC' });
  await portal.init();
  assert.equal(portal.token, 'tok123');
});

test('portal requests are serialised (no concurrent bursts)', async () => {
  const portal = new StalkerPortal({ portalUrl: `${base}/portal.php`, mac: '00:1A:79:AA:BB:CC' });
  await portal.init();
  maxInFlight = 0;
  await Promise.all([
    portal.request({ type: 'itv', action: 'get_all_channels' }),
    portal.request({ type: 'itv', action: 'get_genres' }),
    portal.request({ type: 'itv', action: 'get_all_channels' }),
  ]);
  assert.equal(maxInFlight, 1);
});

test('http routes serve manifest, catalog, meta, and streams', async () => {
  const app = createApp();
  app.listen(0, '127.0.0.1');
  await once(app, 'listening');
  const appBase = `http://127.0.0.1:${app.address().port}`;
  const cfg = encodeConfig({ portalUrl: `${base}/portal.php`, mac: '00:1A:79:AA:BB:CC' });

  try {
    const manifest = await (await fetch(`${appBase}/${cfg}/manifest.json`)).json();
    assert.deepEqual(manifest.types, ['tv']);
    assert.ok(manifest.resources.includes('stream'));

    const catalog = await (await fetch(`${appBase}/${cfg}/catalog/tv/stalker_tv.json`)).json();
    assert.equal(catalog.metas.length, 1);
    assert.equal(catalog.metas[0].id, 'stalker:tv:101');

    const meta = await (await fetch(`${appBase}/${cfg}/meta/tv/stalker:tv:101.json`)).json();
    assert.equal(meta.meta.name, '1. BBC One');

    const testResult = await (
      await fetch(
        `${appBase}/api/test?portalUrl=${encodeURIComponent(`${base}/portal.php`)}&mac=00:1A:79:AA:BB:CC`
      )
    ).json();
    assert.equal(testResult.ok, true);
    assert.equal(testResult.channels, 1);

    const query = `portalUrl=${encodeURIComponent(`${base}/portal.php`)}&mac=00:1A:79:AA:BB:CC`;
    const genres = await (await fetch(`${appBase}/api/genres?${query}`)).json();
    assert.deepEqual(genres.genres, [{ id: '5', name: 'Netherlands' }]);
    const channelList = await (await fetch(`${appBase}/api/channels?${query}`)).json();
    assert.deepEqual(channelList.channels, [{ id: '101', name: 'BBC One', genreId: '5' }]);

    const matched = encodeConfig({
      portalUrl: `${base}/portal.php`,
      mac: '00:1A:79:AA:BB:CC',
      includeGenres: ['5'],
    });
    const matchedCatalog = await (
      await fetch(`${appBase}/${matched}/catalog/tv/stalker_tv.json`)
    ).json();
    assert.equal(matchedCatalog.metas.length, 1);

    const unmatched = encodeConfig({
      portalUrl: `${base}/portal.php`,
      mac: '00:1A:79:AA:BB:CC',
      includeGenres: ['999'],
    });
    const unmatchedCatalog = await (
      await fetch(`${appBase}/${unmatched}/catalog/tv/stalker_tv.json`)
    ).json();
    assert.equal(unmatchedCatalog.metas.length, 0);

    const streams = await (await fetch(`${appBase}/${cfg}/stream/tv/stalker:tv:101.json`)).json();
    assert.equal(streams.streams.length, 1);
    assert.equal(streams.streams[0].url, `${base}/ch/101_play`);
    assert.ok(streams.streams[0].behaviorHints.proxyHeaders.request['User-Agent']);

    // Some clients percent-encode the ":" in the media id.
    const encoded = await (
      await fetch(`${appBase}/${cfg}/stream/tv/stalker%3Atv%3A101.json`)
    ).json();
    assert.equal(encoded.streams.length, 1);

    const proxyCfg = encodeConfig({
      portalUrl: `${base}/portal.php`,
      mac: '00:1A:79:AA:BB:CC',
      streamRoute: 'proxy',
    });
    const proxied = await (
      await fetch(`${appBase}/${proxyCfg}/stream/tv/stalker:tv:101.json`)
    ).json();
    assert.equal(proxied.streams.length, 1);
    assert.match(proxied.streams[0].url, /\/proxy\/tv\/101$/);
    assert.equal(proxied.streams[0].behaviorHints.proxyHeaders, undefined);
  } finally {
    await new Promise((resolve) => app.close(resolve));
  }
});

test('stream endpoint degrades to an error stream instead of a 500', async () => {
  failAllHandshakes = true;
  const app = createApp();
  app.listen(0, '127.0.0.1');
  await once(app, 'listening');
  const appBase = `http://127.0.0.1:${app.address().port}`;
  // Unique config so no cached portal can satisfy it.
  const cfg = encodeConfig({
    portalUrl: `${base}/portal.php`,
    mac: '00:1A:79:00:00:99',
  });
  try {
    const response = await fetch(`${appBase}/${cfg}/stream/tv/stalker:tv:101.json`);
    assert.equal(response.status, 200);
    const body = await response.json();
    assert.equal(body.streams.length, 1);
    assert.equal(body.streams[0].url, undefined);
    assert.equal(body.streams[0].title, 'Portal error');
  } finally {
    failAllHandshakes = false;
    await new Promise((resolve) => app.close(resolve));
  }
});
