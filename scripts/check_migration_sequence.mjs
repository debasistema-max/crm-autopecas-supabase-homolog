import { readdirSync } from 'node:fs';

const files = readdirSync('supabase/migrations')
  .filter((name) => /^\d{3}_.+\.sql$/.test(name))
  .sort();
const byNumber = new Map();

for (const file of files) {
  const number = Number(file.slice(0, 3));
  const entries = byNumber.get(number) || [];
  entries.push(file);
  byNumber.set(number, entries);
}

const expectedLastMigration = 114;
const missing = [];
for (let number = 1; number <= expectedLastMigration; number += 1) {
  if (!byNumber.has(number)) missing.push(String(number).padStart(3, '0'));
}

const unexpectedDuplicates = [...byNumber.entries()]
  .filter(([number, entries]) => number !== 1 && entries.length > 1)
  .map(([number, entries]) => `${String(number).padStart(3, '0')}: ${entries.join(', ')}`);

if (missing.length || unexpectedDuplicates.length) {
  if (missing.length) console.error(`Migrations ausentes: ${missing.join(', ')}`);
  if (unexpectedDuplicates.length) console.error(`Prefixos duplicados: ${unexpectedDuplicates.join('; ')}`);
  process.exit(1);
}

console.log(`Sequência de migrations 001-${expectedLastMigration} completa (${files.length} arquivos; 001 inclui baseline e partes históricas).`);
