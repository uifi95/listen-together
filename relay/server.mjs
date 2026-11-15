// ListenTogether relay: passes playback state between the people in a room.
// Rooms are created on demand from the code in the URL:
//   ws(s)://host/?room=<code>&name=<display name>
// The relay also answers clock pings, so every client can express times on
// the relay's clock and positions line up regardless of each Mac's clock.
import http from 'node:http';
import { WebSocketServer } from 'ws';

const PORT = Number(process.env.PORT) || 47900;
const MAX_PEERS = Number(process.env.MAX_PEERS) || 4;

const rooms = new Map(); // code -> { peers: Set<ws>, last: string|null }

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/plain' });
  res.end(`ListenTogether relay: ${rooms.size} room(s) open\n`);
});

const wss = new WebSocketServer({ server, maxPayload: 64 * 1024 });

const send = (ws, msg) => { if (ws.readyState === ws.OPEN) ws.send(typeof msg === 'string' ? msg : JSON.stringify(msg)); };
const others = (room, ws) => [...room.peers].filter((p) => p !== ws);
const roster = (room) => [...room.peers].map((p) => ({ id: p.peerId, name: p.peerName }));

wss.on('connection', (ws, req) => {
  const url = new URL(req.url, 'http://relay');
  const code = (url.searchParams.get('room') || '').trim().toLowerCase();
  if (!/^[a-z0-9-]{3,64}$/.test(code)) {
    send(ws, { type: 'error', message: 'Room code must be 3-64 letters, digits or dashes' });
    return ws.close();
  }
  let room = rooms.get(code);
  if (!room) rooms.set(code, (room = { peers: new Set(), last: null }));
  if (room.peers.size >= MAX_PEERS) {
    send(ws, { type: 'error', message: 'Room is full' });
    return ws.close();
  }
  ws.peerId = Math.random().toString(36).slice(2, 10);
  ws.peerName = (url.searchParams.get('name') || 'Someone').slice(0, 40);
  ws.isAlive = true;
  room.peers.add(ws);

  send(ws, { type: 'welcome', id: ws.peerId, server: Date.now(), peers: roster(room) });
  // Catch the newcomer up with what the room is playing.
  if (room.last) send(ws, room.last);
  for (const p of others(room, ws)) send(p, { type: 'peers', peers: roster(room) });

  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }
    if (msg.type === 'ping') return send(ws, { type: 'pong', t0: msg.t0, server: Date.now() });
    if (msg.type !== 'state') return;
    msg.from = ws.peerId;
    msg.fromName = ws.peerName;
    const text = JSON.stringify(msg);
    room.last = text;
    for (const p of others(room, ws)) send(p, text);
  });
  ws.on('close', () => {
    room.peers.delete(ws);
    if (room.peers.size === 0) rooms.delete(code);
    else for (const p of room.peers) send(p, { type: 'peers', peers: roster(room) });
  });
});

// Drop connections that stopped answering (sleeping laptops, dead Wi-Fi).
setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.isAlive) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 20000);

server.listen(PORT, () => console.log(`ListenTogether relay listening on :${PORT}`));
