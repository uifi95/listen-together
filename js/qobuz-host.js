// ListenTogether: Qobuz main-process half.
// Evaluated in Qobuz's Electron main process through its Node inspector as
// `(<this function>)(<page script source>)`. Installs global.__listenTogether,
// which the Mac app calls for every Qobuz operation.
(async (PAGE) => {
  const { webContents } = process.mainModule.require('electron');
  const page = () => webContents.getAllWebContents()
    .find((wc) => !wc.isDestroyed() && wc.getURL().endsWith('/app.html'));

  const run = async (wc, expr) => wc.executeJavaScript(expr);
  const ensure = async (wc) => {
    for (let i = 0; i < 20; i++) {
      const r = await run(wc, PAGE).catch((e) => 'error: ' + e.message);
      if (r === 'installed' || r === 'already installed') return true;
      if (r !== 'store not ready') throw new Error('page bridge: ' + r);
      await new Promise((res) => setTimeout(res, 500));
    }
    throw new Error('Qobuz is still loading');
  };

  const sleep = (ms) => new Promise((res) => setTimeout(res, ms));

  const perform = async (name, arg) => {
    const wc = page();
    if (!wc) return JSON.stringify({ error: 'Qobuz window not open' });
    try {
      await ensure(wc);
      if (name === 'play' || name === 'pause') {
        const want = name === 'play';
        const s = await run(wc, 'window.__lt.state()');
        if (s.playing === want) return JSON.stringify({ ok: true });
        // Qobuz's media keys go through this IPC, and it only toggles, so
        // wait until the player has flipped before anything else may look.
        wc.send('media-controls', 'togglePlayPause');
        for (let i = 0; i < 30; i++) {
          await sleep(50);
          if ((await run(wc, 'window.__lt.state()')).playing === want) break;
        }
        return JSON.stringify({ ok: true });
      }
      if (name === 'next') {
        // Qobuz's own "next" media key; wait until the queue has moved on.
        const before = (await run(wc, 'window.__lt.queueState()')).current;
        wc.send('media-controls', 'next');
        for (let i = 0; i < 30; i++) {
          await sleep(50);
          if ((await run(wc, 'window.__lt.queueState()')).current !== before) break;
        }
        return JSON.stringify({ ok: true });
      }
      const r = await run(wc, `window.__lt.${name}(${JSON.stringify(arg === undefined ? null : arg)})`);
      return JSON.stringify(r === undefined ? null : r);
    } catch (e) {
      return JSON.stringify({ error: e.message });
    }
  };

  // One operation at a time, so two callers can't both toggle.
  let queue = Promise.resolve();
  global.__listenTogether = {
    call(name, arg) {
      const result = queue.then(() => perform(name, arg));
      queue = result.catch(() => {});
      return result;
    },
  };
  const wc = page();
  if (wc) await ensure(wc);
  return 'ok';
});
