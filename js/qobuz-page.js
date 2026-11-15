// ListenTogether: Qobuz page half.
// Injected into the Qobuz renderer (app.html). Reads the player from the app's
// Redux store and drives it through the same actions Qobuz's own UI uses.
// Qobuz plays audio through a native engine, so there is no <audio> to touch.
(() => {
  const VERSION = 4;
  if (window.__lt && window.__lt.version === VERSION) return 'already installed';
  if (window.__lt && window.__lt.dispose) window.__lt.dispose();

  const findProp = (name, test) => {
    for (const el of document.querySelectorAll('body, body > *, #root, #app')) {
      const key = Object.keys(el).find((k) => k.startsWith('__reactContainer'));
      if (!key) continue;
      const stack = [el[key]];
      let visited = 0;
      while (stack.length && visited++ < 40000) {
        const node = stack.pop();
        if (!node) continue;
        const value = node.memoizedProps && node.memoizedProps[name];
        if (value && test(value)) return value;
        if (node.sibling) stack.push(node.sibling);
        if (node.child) stack.push(node.child);
      }
    }
    return null;
  };
  const isFunction = (f) => typeof f === 'function';

  const store = findProp('store', (s) => typeof s.getState === 'function');
  if (!store) return 'store not ready';

  // Qobuz's API wants the app id it sends in a header; remember it from the
  // app's own requests.
  const creds = (window.__ltCreds = window.__ltCreds || {});
  const grab = (k, v) => { if (/^x-app-id$/i.test(k) && v) creds.appId = v; };
  const setHeader = XMLHttpRequest.prototype.setRequestHeader;
  if (!setHeader.__lt) {
    const wrapped = function (k, v) { try { grab(k, v); } catch (e) {} return setHeader.apply(this, arguments); };
    wrapped.__lt = true;
    XMLHttpRequest.prototype.setRequestHeader = wrapped;
  }
  const origFetch = window.fetch;
  if (!origFetch.__lt) {
    const wrapped = function (input, init) {
      try { new Headers((init && init.headers) || (input && input.headers) || {}).forEach((v, k) => grab(k, v)); } catch (e) {}
      return origFetch.apply(this, arguments);
    };
    wrapped.__lt = true;
    window.fetch = wrapped;
  }

  const names = (people) => (people || []).map((a) => a.name && a.name.display).filter(Boolean).join(', ');
  const titleOf = (t) => (t.version ? `${t.title} (${t.version})` : t.title);

  const state = () => {
    const s = store.getState();
    const player = s.player || {};
    const current = player.currentTrack;
    const dict = s.dictionnary || {};
    const track = current && dict.tracks && dict.tracks.data && dict.tracks.data[current.id];
    const playing = player.playingState === 'play';
    const pos = player.position || { value: 0 };
    let positionMs = pos.value || 0;
    if (playing && pos.timestamp) positionMs += Date.now() - pos.timestamp;
    if (!track || !track.title) return { track: null, playing, positionMs, queueVersion };
    const release = dict.releases && dict.releases.data && dict.releases.data[track.releaseId];
    return {
      queueVersion,
      track: {
        id: String(track.id),
        albumId: track.releaseId ? String(track.releaseId) : null,
        title: titleOf(track),
        artist: names(track.interpreters) || (release && names(release.artists)) || '',
        album: release ? release.title : '',
        isrc: track.isrc || null,
        durationMs: current.duration || (track.duration || 0) * 1000,
      },
      playing,
      positionMs: Math.round(positionMs),
      loading: !!player.loading,
    };
  };

  // Make Qobuz send any API request so its app id shows up.
  const ensureAppId = async () => {
    if (creds.appId) return true;
    store.dispatch({ type: 'LOAD_TRACKS_EPIC', ids: [10000000 + Math.floor(Math.random() * 1e6)] });
    for (let i = 0; i < 30 && !creds.appId; i++) await new Promise((r) => setTimeout(r, 100));
    return !!creds.appId;
  };
  const api = async (path, query) => {
    if (!(await ensureAppId())) throw new Error('Qobuz app id not captured yet');
    const token = store.getState().user.token;
    const url = `https://www.qobuz.com/api.json/0.2/${path}?${new URLSearchParams(query)}`;
    const res = await origFetch(url, { headers: { 'X-App-Id': creds.appId, 'X-User-Auth-Token': token } });
    if (!res.ok) throw new Error(`Qobuz API ${path}: HTTP ${res.status}`);
    return res.json();
  };

  const search = async ({ query, limit }) => {
    const j = await api('track/search', { query, limit: limit || 10 });
    return ((j.tracks && j.tracks.items) || [])
      .filter((t) => t.streamable !== false)
      .map((t) => ({
        id: String(t.id),
        title: titleOf(t),
        artist: (t.performer && t.performer.name) || (t.album && t.album.artist && t.album.artist.name) || '',
        album: (t.album && t.album.title) || '',
        albumId: t.album && String(t.album.id),
        isrc: t.isrc || null,
        durationMs: (t.duration || 0) * 1000,
      }));
  };

  // Play a track the way an album page's track row does: replace the queue
  // with its album, starting at that track.
  const playTrack = async ({ trackId, albumId }) => {
    const album = await api('album/get', { album_id: albumId, extra: 'track_ids', limit: 1 });
    const ids = (album.track_ids || []).map(String);
    const index = ids.indexOf(String(trackId));
    if (index < 0) return { ok: false, error: 'track not on its album' };
    store.dispatch({
      type: 'REPLACE_PLAYQUEUE_FROM_RELEASE_EPIC',
      releaseId: albumId,
      index,
      origin: { type: 'album', id: albumId, from: 'Search/Tracks' },
    });
    return { ok: true };
  };

  const seek = (ms) => {
    const fn = findProp('seek', isFunction);
    if (!fn) return { ok: false, error: 'Qobuz seek control not found' };
    const duration = (store.getState().player.currentTrack || {}).duration || 0;
    fn({ position: Math.round(Math.min(Math.max(ms, 0), Math.max(duration - 1000, 0))) });
    return { ok: true };
  };

  // The play queue, for the shared queue: the app notices what someone
  // added ("Add to Queue" / "Play Next") by comparing item keys.
  let queueVersion = 0;
  let lastItems = null;
  const unsubscribe = store.subscribe(() => {
    const items = (store.getState().playqueue || {}).items;
    if (items !== lastItems) { lastItems = items; queueVersion++; }
  });
  const items = () => (store.getState().playqueue || {}).items || [];
  // Qobuz renumbers items (q1, q2…) when a queue is replaced, so the key
  // also carries the context, which each add/insert gets anew.
  const keyOf = (it) => `${it.queueItemId}|${it.trackId}|${it.contextUuid || ''}`;
  const queueKeys = () => items().map(keyOf);
  const queueTracks = (keys) => {
    const dict = store.getState().dictionnary || {};
    const byKey = new Map(items().map((it) => [keyOf(it), it]));
    const out = {};
    const missing = [];
    for (const key of keys || []) {
      const it = byKey.get(key);
      if (!it) continue;
      const t = dict.tracks && dict.tracks.data && dict.tracks.data[it.trackId];
      if (!t || !t.title) { out[key] = null; missing.push(it.trackId); continue; }
      const release = dict.releases && dict.releases.data && dict.releases.data[t.releaseId];
      out[key] = {
        id: String(t.id),
        albumId: t.releaseId ? String(t.releaseId) : null,
        title: titleOf(t),
        artist: names(t.interpreters) || (release && names(release.artists)) || '',
        album: release ? release.title : '',
        isrc: t.isrc || null,
        durationMs: (t.duration || 0) * 1000,
      };
    }
    if (missing.length) store.dispatch({ type: 'LOAD_TRACKS_EPIC', ids: missing });
    return out;
  };

  window.__lt = { version: VERSION, state, search, playTrack, seek, queueKeys, queueTracks, dispose: unsubscribe };
  return 'installed';
})();
