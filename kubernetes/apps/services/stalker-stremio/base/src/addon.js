export const ADDON_ID = 'org.stalker.portal';
export const ADDON_VERSION = '0.1.0';
export const CATALOG_TV = 'stalker_tv';
export const PAGE_SIZE = 100;

/** `stalker:tv:<portal channel id>` */
export function channelMediaId(channelId) {
  return `stalker:tv:${channelId}`;
}

export function parseMediaId(id) {
  const match = /^stalker:(tv):(.+)$/.exec(String(id));
  return match ? { type: match[1], portalId: match[2] } : null;
}

export function buildManifest(config = {}) {
  return {
    id: ADDON_ID,
    version: ADDON_VERSION,
    name: config.name || 'Stalker Portal',
    description:
      'Live TV from your Stalker/Ministra IPTV portal. Configure with the portal URL and MAC address.',
    resources: ['catalog', 'meta', 'stream'],
    types: ['tv'],
    idPrefixes: ['stalker:'],
    catalogs: [
      {
        type: 'tv',
        id: CATALOG_TV,
        name: 'Live TV',
        extra: [
          { name: 'search', isRequired: false },
          { name: 'skip', isRequired: false },
        ],
      },
    ],
    behaviorHints: {
      configurable: true,
      configurationRequired: false,
    },
  };
}

export function channelDisplayName(channel) {
  return channel.number ? `${channel.number}. ${channel.name}` : channel.name;
}

export function channelToCatalogMeta(channel) {
  return {
    id: channelMediaId(channel.id),
    type: 'tv',
    name: channelDisplayName(channel),
    poster: channel.logo,
    logo: channel.logo,
    description: 'Live channel from your Stalker portal',
  };
}

export function channelToMeta(channel) {
  return {
    id: channelMediaId(channel.id),
    type: 'tv',
    name: channelDisplayName(channel),
    poster: channel.logo,
    logo: channel.logo,
    background: channel.logo,
    description: 'Live channel from your Stalker portal',
  };
}

/**
 * Whitelist: if neither genres nor channels are set, everything is included.
 * Otherwise a channel is included when its id is picked or its genre is picked.
 */
export function selectChannels(channels, { includeGenres, includeChannels } = {}) {
  const genres = includeGenres ?? [];
  const ids = includeChannels ?? [];
  if (genres.length === 0 && ids.length === 0) return channels;
  const genreSet = new Set(genres.map(String));
  const idSet = new Set(ids.map(String));
  return channels.filter(
    (channel) =>
      idSet.has(String(channel.id)) ||
      (channel.genreId !== undefined && genreSet.has(String(channel.genreId)))
  );
}

/** Apply Stremio's `search=` / `skip=` catalog extras. */
export function paginateChannels(channels, { search, skip } = {}) {
  let list = channels;
  if (search) {
    const needle = search.toLowerCase();
    list = list.filter((channel) => channel.name.toLowerCase().includes(needle));
  }
  const start = Number.isFinite(skip) && skip > 0 ? skip : 0;
  return list.slice(start, start + PAGE_SIZE);
}

/**
 * A single stream entry. `streamUrl` is either the portal's own create_link URL
 * (most like a real Android set-top box) or our proxy URL (server-side fetch).
 */
export function buildStreams({ channel, streamUrl, requestHeaders }) {
  return [
    {
      name: 'Stalker',
      title: channelDisplayName(channel),
      url: streamUrl,
      behaviorHints: {
        notWebReady: true,
        filename: `${channel.name}.ts`,
        bingeGroup: 'stalker-tv',
        ...(requestHeaders ? { proxyHeaders: { request: requestHeaders } } : {}),
      },
    },
  ];
}
