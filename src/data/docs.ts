import { promises as fs } from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const docsDir = path.resolve(fileURLToPath(new URL('../../public/docs', import.meta.url)));

export type DocNode =
  | { type: 'folder'; name: string; title: string; children: DocNode[] }
  | { type: 'file'; name: string; title: string; url: string };

function normalizeTitle(name: string) {
  const withoutExt = name.replace(/\.html$/i, '');
  // El código de ordenación (p.ej. "A0", "FV01") va antes del primer "_" en
  // todo nombre de archivo/carpeta; se usa para ordenar pero no se muestra.
  const withoutCode = withoutExt.replace(/^[A-Za-z0-9]+_(.+)$/, '$1');
  return withoutCode
    .replace(/_/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

async function buildTree(dir: string): Promise<DocNode[]> {
  const entries = await fs.readdir(dir, { withFileTypes: true });
  const folders = entries.filter((entry) => entry.isDirectory()).sort((a, b) => a.name.localeCompare(b.name, 'es', { sensitivity: 'base' }));
  const files = entries.filter((entry) => entry.isFile() && entry.name.toLowerCase().endsWith('.html')).sort((a, b) => a.name.localeCompare(b.name, 'es', { sensitivity: 'base' }));

  const nodes: DocNode[] = [];

  for (const folder of folders) {
    nodes.push({
      type: 'folder',
      name: folder.name,
      title: normalizeTitle(folder.name),
      children: await buildTree(path.join(dir, folder.name)),
    });
  }

  for (const file of files) {
    const relPath = path.relative(docsDir, path.join(dir, file.name)).split(path.sep).join('/');
    nodes.push({
      type: 'file',
      name: file.name,
      title: normalizeTitle(file.name),
      url: `/docs/${relPath}`,
    });
  }

  return nodes;
}

function escapeHtml(text: string) {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

export function buildDocsMenuHtml(items: DocNode[]): string {
  let html = '';
  for (const item of items) {
    if (item.type === 'folder') {
      html += `<li class="folder"><details open><summary>${escapeHtml(item.title)}</summary><ul>${buildDocsMenuHtml(item.children)}</ul></details></li>`;
    } else {
      html += `<li class="file"><a href="${escapeHtml(item.url)}">${escapeHtml(item.title)}</a></li>`;
    }
  }
  return html;
}

export async function getDocsTree(): Promise<DocNode[]> {
  return await buildTree(docsDir);
}
