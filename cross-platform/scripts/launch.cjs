const { spawn } = require('node:child_process');
const path = require('node:path');
const environment = { ...process.env };
delete environment.ELECTRON_RUN_AS_NODE;
// Hooks must use the user's Node binary, never Electron's executable.
environment.PIP_NODE_EXECUTABLE = process.execPath;
const child = spawn(require('electron'), ['.', ...process.argv.slice(2)], {
  cwd: path.join(__dirname, '..'), env: environment, stdio: 'inherit'
});
child.on('error', error => { console.error(error.message); process.exitCode = 1; });
child.on('exit', code => { process.exitCode = code === null ? 1 : code; });
