'use strict';
const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.PORT || 4361);
const HOST = process.env.HOST || '127.0.0.1';
const PUBLIC = (process.env.PUBLIC_URL || 'https://ryodan-meta.grooooog.space').replace(/\/$/, '');
const MAX_ID = 6666;
const GRID = 12;
const CELL = 30;
const PAD = 60;
const SIZE = GRID * CELL + PAD * 2;

function rng(seed) {
  let buf = crypto.createHash('sha256').update(seed).digest();
  let i = 0;
  return () => {
    if (i + 4 > buf.length) { buf = crypto.createHash('sha256').update(buf).digest(); i = 0; }
    const v = buf.readUInt32BE(i); i += 4;
    return v / 0x100000000;
  };
}

function art(set, id) {
  const r = rng(`ryodan-test:${set}:${id}`);
  const hue = Math.floor(r() * 360);
  const nft = set === 'nft';
  const bg = nft ? `hsl(${(hue + 180) % 360} 45% 12%)` : 'hsl(220 14% 10%)';
  const palette = nft
    ? [0, 35, 70, 200].map((d, k) => `hsl(${(hue + d) % 360} ${70 + k * 5}% ${50 + (k % 2) * 12}%)`)
    : [`hsl(${hue} 10% 70%)`, `hsl(${hue} 8% 50%)`, `hsl(${hue} 12% 35%)`, 'hsl(190 60% 55%)'];
  const half = GRID / 2;
  let rects = '';
  for (let y = 0; y < GRID; y++) {
    for (let x = 0; x < half; x++) {
      if (r() < 0.45) continue;
      const fill = palette[Math.floor(r() * (r() < 0.9 ? 3 : 4))];
      for (const cx of [x, GRID - 1 - x]) rects += `<rect x="${PAD + cx * CELL}" y="${PAD + y * CELL}" width="${CELL}" height="${CELL}" fill="${fill}"/>`;
    }
  }
  const label = `${nft ? 'NFT' : 'SBT'} #${String(id).padStart(4, '0')}`;
  const frame = nft ? palette[1] : 'hsl(220 10% 30%)';
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${SIZE} ${SIZE}" width="${SIZE}" height="${SIZE}" shape-rendering="crispEdges">`
    + `<rect width="${SIZE}" height="${SIZE}" fill="${bg}"/>`
    + `<rect x="${PAD - 10}" y="${PAD - 10}" width="${GRID * CELL + 20}" height="${GRID * CELL + 20}" fill="none" stroke="${frame}" stroke-width="6"/>`
    + rects
    + `<text x="${SIZE / 2}" y="${SIZE - 18}" fill="${nft ? palette[0] : 'hsl(220 10% 60%)'}" font-family="monospace" font-size="22" text-anchor="middle">${label}</text>`
    + `</svg>`;
}

function meta(set, id) {
  const nft = set === 'nft';
  const r = rng(`ryodan-test:${set}:${id}`);
  return {
    name: `Ryodan Key #${String(id).padStart(4, '0')}`,
    description: nft
      ? 'Ryodan Key, unlocked (NFT set). Sepolia TEST metadata, randomly generated pixel art: not the final artwork.'
      : 'Ryodan Key, locked (SBT set). Sepolia TEST metadata, randomly generated pixel art: not the final artwork.',
    image: `${PUBLIC}/${set}/${id}.svg`,
    external_url: 'https://ryodan.grooooog.space',
    attributes: [
      { trait_type: 'Set', value: nft ? 'NFT' : 'SBT' },
      { trait_type: 'Status', value: nft ? 'Unlocked' : 'Locked' },
      { trait_type: 'Network', value: 'Sepolia test' },
      { trait_type: 'Hue', value: Math.floor(r() * 360) },
      { display_type: 'number', trait_type: 'Key', value: id, max_value: MAX_ID },
    ],
  };
}

const route = /^\/(sbt|nft)\/([1-9][0-9]{0,3})\.(json|svg)$/;
const server = http.createServer((req, res) => {
  const headers = { 'Access-Control-Allow-Origin': '*', 'Cache-Control': 'public, max-age=3600' };
  const path = new URL(req.url, 'http://x').pathname;
  if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405, headers); return res.end(); }
  if (path === '/healthz') { res.writeHead(200, { ...headers, 'Content-Type': 'text/plain' }); return res.end('ok\n'); }
  if (path === '/' ) {
    res.writeHead(200, { ...headers, 'Content-Type': 'text/html; charset=utf-8' });
    const tiles = [1, 2, 3, 42, 667, 6666].map(i => `<figure><img src="/sbt/${i}.svg" width="160"><img src="/nft/${i}.svg" width="160"><figcaption>#${i}</figcaption></figure>`).join('');
    return res.end(`<!doctype html><meta name="viewport" content="width=device-width"><title>Ryodan Keys test metadata</title><style>body{background:#111;color:#ccc;font:14px monospace;padding:20px}figure{display:inline-block;margin:8px}</style><h1>Ryodan Keys · Sepolia test metadata</h1><p>/sbt/&lt;id&gt;.json · /nft/&lt;id&gt;.json · id 1–${MAX_ID}</p>${tiles}`);
  }
  const m = route.exec(path);
  const id = m ? Number(m[2]) : 0;
  if (!m || id < 1 || id > MAX_ID) { res.writeHead(404, { ...headers, 'Content-Type': 'application/json' }); return res.end('{"error":"not found"}\n'); }
  const [, set, , ext] = m;
  const body = ext === 'json' ? JSON.stringify(meta(set, id), null, 2) + '\n' : art(set, id);
  res.writeHead(200, { ...headers, 'Content-Type': ext === 'json' ? 'application/json' : 'image/svg+xml' });
  res.end(req.method === 'HEAD' ? undefined : body);
});
server.listen(PORT, HOST, () => console.log(`ryodan-meta on ${HOST}:${PORT}`));
