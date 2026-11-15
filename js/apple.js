// ListenTogether: Apple Music half.
// Evaluated in the music.apple.com web player that the app hosts in a
// WKWebView. Drives the page's own MusicKit instance.
(() => {
  const VERSION = 4;
  // Changes whenever the page (and so the player's volume) was reloaded.
  const BRIDGE = Math.random().toString(36).slice(2);
  if (window.__lt && window.__lt.version === VERSION) return 'already installed';

  const mk = () => {
    try { return window.MusicKit && window.MusicKit.getInstance(); } catch (e) { return null; }
  };
  const need = () => {
    const i = mk();
    if (!i) throw new Error('Apple Music player is still loading');
    return i;
  };

  const song = (x) => {
    const a = x.attributes || {};
    return {
      id: String(x.id),
      title: a.name || x.title || '',
      artist: a.artistName || x.artistName || '',
      album: a.albumName || x.albumName || '',
      isrc: a.isrc || x.isrc || null,
      durationMs: a.durationInMillis || x.playbackDuration || 0,
    };
  };

  const toTrack = (item) => {
    const track = song(item);
    // Library items carry the catalog id in their play params.
    const pp = item.playParams || (item.attributes && item.attributes.playParams) || {};
    if (pp.catalogId) track.id = String(pp.catalogId);
    return track;
  };

  // The play queue, for the shared queue: MusicKit keeps the same item
  // objects when songs are added and makes new ones when the queue is
  // replaced, so each object gets a key.
  const keys = new WeakMap();
  let nextKey = 0;
  const keyOf = (x) => { if (!keys.has(x)) keys.set(x, 'a' + (++nextKey)); return keys.get(x); };
  let queueVersion = 0;
  let listeningTo = null;
  const listen = (i) => {
    if (listeningTo === i) return;
    listeningTo = i;
    i.addEventListener('queueItemsDidChange', () => { queueVersion++; });
    queueVersion++;
  };
  const queueKeys = () => need().queue.items.map(keyOf);
  const queueTracks = (wanted) => {
    const byKey = new Map(need().queue.items.map((x) => [keyOf(x), x]));
    const out = {};
    for (const key of wanted || []) {
      const x = byKey.get(key);
      if (!x) continue;
      const t = toTrack(x);
      out[key] = t.title ? t : null;
    }
    return out;
  };

  const state = () => {
    const i = mk();
    if (!i) return { ready: false, authorized: false, track: null, playing: false, positionMs: 0 };
    listen(i);
    const item = i.nowPlayingItem;
    let track = null;
    if (item) {
      track = toTrack(item);
      if (!track.durationMs && i.currentPlaybackDuration) track.durationMs = Math.round(i.currentPlaybackDuration * 1000);
    }
    return {
      ready: true,
      authorized: !!i.isAuthorized,
      track,
      playing: !!i.isPlaying,
      positionMs: Math.round((i.currentPlaybackTime || 0) * 1000),
      volume: typeof i.volume === 'number' ? i.volume : null,
      bridge: BRIDGE,
      queueVersion,
      // 1 = loading, 8 = waiting, 9 = stalled (MusicKit.PlaybackStates)
      loading: [1, 8, 9].includes(i.playbackState),
    };
  };

  const search = async ({ query, isrc, limit }) => {
    const i = need();
    const sf = i.storefrontId || 'us';
    const out = [];
    if (isrc) {
      const r = await i.api.music(`/v1/catalog/${sf}/songs`, { 'filter[isrc]': isrc });
      out.push(...((r.data && r.data.data) || []).map(song));
    }
    if (query) {
      const r = await i.api.music(`/v1/catalog/${sf}/search`, { term: query, types: 'songs', limit: limit || 10 });
      const songs = r.data && r.data.results && r.data.results.songs;
      out.push(...((songs && songs.data) || []).map(song));
    }
    return out;
  };

  const waitFor = async (test, ms) => {
    const end = Date.now() + ms;
    while (Date.now() < end) {
      if (test()) return true;
      await new Promise((r) => setTimeout(r, 100));
    }
    return false;
  };

  const playSong = async ({ id, positionMs, play }) => {
    const i = need();
    await i.setQueue({ song: String(id), startPlaying: !!play });
    if (positionMs > 1000) {
      // Seeking before the item has loaded is ignored, so wait for it.
      await waitFor(() => i.currentPlaybackDuration > 0, 8000);
      await i.seekToTime(positionMs / 1000);
    }
    if (play && !i.isPlaying) await i.play();
    return { ok: true };
  };

  const play = async () => { const i = need(); if (!i.isPlaying) await i.play(); return { ok: true }; };
  const pause = async () => { const i = need(); if (i.isPlaying) await i.pause(); return { ok: true }; };
  const seek = async (ms) => { await need().seekToTime(Math.max(0, ms) / 1000); return { ok: true }; };
  // The audio plays in WebKit's shared helper process, not this app's, so
  // per-app volume tools can't reach it; this is the player's own volume.
  const setVolume = (v) => {
    const i = need();
    i.volume = Math.min(1, Math.max(0, Number(v) || 0));
    return { ok: true, volume: i.volume };
  };
  const authorize = async () => { await need().authorize(); return { ok: true }; };

  window.__lt = { version: VERSION, state, search, playSong, play, pause, seek, setVolume, authorize, queueKeys, queueTracks };
  return 'installed';
})();
