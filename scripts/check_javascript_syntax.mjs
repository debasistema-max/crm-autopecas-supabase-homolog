import { readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { spawnSync } from 'node:child_process';

const roots = ['js', 'b2b/js', 'cadastro-publico/js', 'scripts', 'tests'];
const extensions = new Set(['.js', '.mjs', '.cjs']);
const ignored = new Set([join('js', 'vendor')]);
const files = [];

function collect(directory) {
  if (ignored.has(directory)) return;
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const file = join(directory, entry.name);
    if (entry.isDirectory()) collect(file);
    else if (extensions.has(extname(entry.name))) files.push(file);
  }
}

for (const root of roots) collect(root);
for (const file of files) {
  const result = spawnSync(process.execPath, ['--check', file], { stdio: 'inherit' });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

console.log(`Sintaxe JavaScript aprovada em ${files.length} arquivos.`);
