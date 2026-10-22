#!/usr/bin/env node
// Genera public/docs/A00_Blog_Interactivo/index/videos.json: un manifiesto con los
// videos que haya en esa carpeta (excepto el usado como fondo del hero), para que
// index.html pueda mostrarlos como cards sin que ningún nombre ni cantidad de video
// esté escrito a mano en la página. Se ejecuta automáticamente antes de "dev"/"build"
// (ver package.json), así que basta con añadir o quitar archivos de la carpeta.

import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';
import { execFile } from 'child_process';
import { promisify } from 'util';

const execFileAsync = promisify(execFile);

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT_DIR = path.resolve(__dirname, '..');
const INDEX_DIR = path.join(ROOT_DIR, 'public/docs/A00_Blog_Interactivo/index');
const INDEX_HTML = path.join(INDEX_DIR, 'index.html');
const MANIFEST_PATH = path.join(INDEX_DIR, 'videos.json');
const VIDEO_EXTENSIONS = new Set(['.mp4', '.webm', '.mov', '.ogg', '.ogv']);

async function detectBackgroundVideoFile() {
  try {
    const html = await fs.readFile(INDEX_HTML, 'utf8');
    const bgBlockMatch = html.match(/<video[^>]*class="bg-video"[\s\S]*?<\/video>/);
    const sourceMatch = (bgBlockMatch ? bgBlockMatch[0] : html).match(/<source\s+src="([^"]+)"/);
    return sourceMatch ? sourceMatch[1] : null;
  } catch {
    return null;
  }
}

async function probeVideo(filePath) {
  try {
    const { stdout } = await execFileAsync('ffprobe', [
      '-v', 'error',
      '-select_streams', 'v:0',
      '-show_entries', 'stream=width,height',
      '-show_entries', 'format=duration',
      '-of', 'json',
      filePath,
    ]);
    const parsed = JSON.parse(stdout);
    const stream = (parsed.streams && parsed.streams[0]) || {};
    const duration = parsed.format && parsed.format.duration ? Math.round(parseFloat(parsed.format.duration)) : null;
    return { width: stream.width || null, height: stream.height || null, duration };
  } catch {
    return { width: null, height: null, duration: null };
  }
}

async function main() {
  const backgroundFile = await detectBackgroundVideoFile();
  let entries;
  try {
    entries = await fs.readdir(INDEX_DIR, { withFileTypes: true });
  } catch {
    console.warn('generate-video-manifest: no existe la carpeta', INDEX_DIR, '- se omite.');
    return;
  }

  const videoFiles = entries
    .filter(e => e.isFile() && VIDEO_EXTENSIONS.has(path.extname(e.name).toLowerCase()))
    .map(e => e.name)
    .filter(name => name !== backgroundFile)
    .sort((a, b) => a.localeCompare(b, 'es'));

  const videos = [];
  for (const name of videoFiles) {
    const filePath = path.join(INDEX_DIR, name);
    const stat = await fs.stat(filePath);
    const meta = await probeVideo(filePath);
    videos.push({ file: name, sizeBytes: stat.size, ...meta });
  }

  await fs.writeFile(MANIFEST_PATH, JSON.stringify({ generatedAt: new Date().toISOString(), videos }, null, 2) + '\n');
  console.log(`generate-video-manifest: ${videos.length} video(s) listado(s) en ${path.relative(ROOT_DIR, MANIFEST_PATH)} (excluido fondo: ${backgroundFile || 'ninguno detectado'}).`);
}

main();
