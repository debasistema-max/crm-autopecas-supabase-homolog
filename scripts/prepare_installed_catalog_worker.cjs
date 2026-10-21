'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { validateConfig } = require('./installed_catalog_worker.cjs');

function prepare(configFile) {
  const physical = fs.realpathSync.native(configFile);
  const config = validateConfig(JSON.parse(fs.readFileSync(physical, 'utf8')));
  for (const name of ['database', 'manifest', 'python', 'ca']) config[name] = fs.realpathSync.native(config[name]);
  config.evidence = path.join(path.dirname(physical), 'evidence');
  validateConfig(config);
  const temporary = physical + '.prepared-' + process.pid;
  fs.writeFileSync(temporary, JSON.stringify(config, null, 2), { flag: 'wx', mode: 0o600 });
  fs.renameSync(temporary, physical);
  return physical;
}

if (require.main === module) {
  try { console.log(prepare(process.argv[2])); }
  catch (_) { console.error('CONFIGURACAO_FISICA_INVALIDA'); process.exitCode = 1; }
}
module.exports = { prepare };
