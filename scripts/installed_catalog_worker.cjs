'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawn, execFileSync } = require('node:child_process');
const { Client } = require('pg');

const PROJECT = 'mtwvxyvpnbgwgltelozw';
const CATALOG_PACKAGE = 'BrunoRImbanoJunior.CatlogoYokomitsu_m47cmv7cfchvj';

function catalogPackagePaths(info, programFiles = process.env.ProgramFiles) {
  if (!programFiles || info?.PackageFamilyName !== CATALOG_PACKAGE || !path.isAbsolute(info.InstallLocation || '')) throw new Error('PACOTE_CATALOGO_INVALIDO');
  const root = path.join(fs.realpathSync.native(programFiles), 'WindowsApps');
  const location = fs.realpathSync.native(info.InstallLocation);
  if (!location.toLowerCase().startsWith(root.toLowerCase() + path.sep)) throw new Error('ORIGEM_CATALOGO_INVALIDA');
  const files = { database: fs.realpathSync.native(path.join(location, 'data', 'catalog.db')),
    manifest: fs.realpathSync.native(path.join(location, 'manifest.json')) };
  if (Object.values(files).some((file) => !file.toLowerCase().startsWith(location.toLowerCase() + path.sep))) throw new Error('ORIGEM_CATALOGO_INVALIDA');
  return files;
}

function resolveCatalogConfig(config) {
  if (!config.catalogPackageFamily) return config;
  if (config.catalogPackageFamily !== CATALOG_PACKAGE) throw new Error('PACOTE_CATALOGO_INVALIDO');
  const command = "Get-AppxPackage -Name 'BrunoRImbanoJunior.CatlogoYokomitsu' | Where-Object {$_.PackageFamilyName -eq 'BrunoRImbanoJunior.CatlogoYokomitsu_m47cmv7cfchvj'} | Sort-Object Version -Descending | Select-Object -First 1 InstallLocation,PackageFamilyName | ConvertTo-Json -Compress";
  const result = execFileSync(path.join(process.env.WINDIR, 'System32/WindowsPowerShell/v1.0/powershell.exe'),
    ['-NoProfile', '-NonInteractive', '-Command', command], { encoding: 'utf8', windowsHide: true, timeout: 30000, stdio: ['ignore', 'pipe', 'pipe'] });
  return { ...config, ...catalogPackagePaths(JSON.parse(result.replace(/^\uFEFF/, '').trim())) };
}

function validateConfig(config) {
  if (config.project !== PROJECT || config.user !== `ips_catalog_worker.${PROJECT}`
    || !/^aws-[01]-[a-z0-9-]+\.pooler\.supabase\.com$/.test(config.host)
    || Number(config.port) !== 5432 || !config.password) throw new Error('DESTINO_OU_CREDENCIAL_INVALIDO');
  for (const name of ['database', 'manifest', 'python', 'ca', 'evidence']) {
    if (!path.isAbsolute(config[name] || '')) throw new Error('CAMINHO_INVALIDO_' + name.toUpperCase());
  }
  if (!config.database.toLowerCase().endsWith('catalog.db') || !config.manifest.toLowerCase().endsWith('manifest.json')) throw new Error('CATALOGO_LOCAL_INVALIDO');
  return config;
}

function connectionOptions(config) {
  return { host: config.host, port: 5432, user: config.user, password: config.password,
    database: 'postgres', ssl: { rejectUnauthorized: true, ca: fs.readFileSync(config.ca) },
    connectionTimeoutMillis: 20000, statement_timeout: 110000, application_name: 'ips-installed-catalog-worker' };
}

async function snapshot(client, job) {
  const rows = [];
  let after = '';
  while (true) {
    const result = await client.query('select public.snapshot_installed_catalog_sync($1,$2,$3) as rows', [job.id, job.claim_token, after]);
    const page = result.rows[0].rows;
    if (!Array.isArray(page)) throw new Error('SNAPSHOT_INVALIDO');
    if (!page.length) return rows;
    if (page.length > 250 || page[page.length - 1].codigo === after || rows.length + page.length > 50000) throw new Error('SNAPSHOT_FORA_DO_LIMITE');
    after = page[page.length - 1].codigo;
    rows.push(...page);
  }
}

function runPlanner(config, backup, output) {
  return new Promise((resolve, reject) => {
    const process = spawn(config.python, [path.join(__dirname, 'build_installed_ips_catalog.py'),
      '--database', config.database, '--manifest', config.manifest, '--crm-snapshot', backup, '--output', output],
    { windowsHide: true, stdio: ['ignore', 'ignore', 'ignore'], timeout: 15 * 60 * 1000 });
    process.once('error', () => reject(new Error('FALHA_INICIAR_LEITOR_LOCAL')));
    process.once('close', (code) => code === 0 ? resolve() : reject(new Error('FALHA_VALIDAR_CATALOGO_LOCAL')));
  });
}

async function run(config, checkOnly = false) {
  config = resolveCatalogConfig(config);
  validateConfig(config);
  for (const name of ['database', 'manifest', 'python', 'ca']) fs.accessSync(config[name], fs.constants.R_OK);
  const client = new Client(connectionOptions(config));
  let job;
  try {
    await client.connect();
    const identity = (await client.query('select current_user as role')).rows[0];
    if (identity.role !== 'ips_catalog_worker') throw new Error('PAPEL_DO_EXECUTOR_INVALIDO');
    if (checkOnly) return { status: 'ready', project: PROJECT };
    job = (await client.query('select public.claim_installed_catalog_sync() as job')).rows[0].job;
    if (!job) return { status: 'idle' };
    fs.mkdirSync(config.evidence, { recursive: true, mode: 0o700 });
    const folder = fs.mkdtempSync(path.join(config.evidence, job.id + '-'));
    const backup = path.join(folder, 'before.json');
    const output = path.join(folder, 'plan.json');
    fs.writeFileSync(backup, JSON.stringify(await snapshot(client, job)), { flag: 'wx', mode: 0o600 });
    if (!fs.statSync(backup).size) throw new Error('BACKUP_LOCAL_VAZIO');
    await runPlanner(config, backup, output);
    const content = fs.readFileSync(output, 'utf8');
    if (Buffer.byteLength(content) > 32 * 1024 * 1024) throw new Error('PLANO_FORA_DO_LIMITE');
    const plan = JSON.parse(content);
    if (!Number.isInteger(plan.summary?.source_products) || plan.summary.source_products < 1) throw new Error('CATALOGO_LOCAL_VAZIO');
    const result = (await client.query('select public.finish_installed_catalog_sync($1,$2,$3::jsonb) as result',
      [job.id, job.claim_token, plan])).rows[0].result;
    fs.writeFileSync(path.join(folder, 'result.json'), JSON.stringify(result), { flag: 'wx', mode: 0o600 });
    return { status: result.status, id: job.id, summary: result.summary };
  } catch (error) {
    if (job) {
      // A lost commit response cannot change a completed job into a failure.
      await client.query('select public.fail_installed_catalog_sync($1,$2)', [job.id, job.claim_token]).catch(() => {});
    }
    // Never print server errors, connection strings, environment or passwords.
    throw new Error(/^([A-Z_]+)$/.test(error.message) ? error.message : 'FALHA_EXECUTOR_LOCAL');
  } finally {
    await client.end().catch(() => {});
  }
}

if (require.main === module) {
  const configFile = process.argv[2];
  Promise.resolve().then(() => {
    if (!configFile || !path.isAbsolute(configFile)) throw new Error('CONFIGURACAO_LOCAL_OBRIGATORIA');
    const config = JSON.parse(fs.readFileSync(configFile, 'utf8'));
    return run(config, process.argv.includes('--check'));
  }).then((result) => console.log(JSON.stringify(result))).catch((error) => {
    console.error(/^([A-Z_]+)$/.test(error.message) ? error.message : 'FALHA_EXECUTOR_LOCAL');
    process.exitCode = 1;
  });
}

module.exports = { validateConfig, connectionOptions, snapshot, run, PROJECT, CATALOG_PACKAGE, catalogPackagePaths, resolveCatalogConfig };
