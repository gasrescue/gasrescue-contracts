// Compiles the contracts with the exact settings of the deployed ones (solc 0.8.28, optimizer 200
// runs, EVM cancun) into build/. The same settings reproduce the verified bytecode on the explorers.
const fs = require('fs');
const path = require('path');
const solc = require('solc');

const root = path.resolve(__dirname, '..');
const sources = {
  'contracts/GasRelay.sol': ['GasRelay'],
  'contracts/SwapRelay.sol': ['SwapRelay'],
  'contracts/SwapRelay2.sol': ['SwapRelay2'],
  'contracts/test/SimToken.sol': ['SimToken'],
  'contracts/test/SimSaltToken.sol': ['SimSaltToken'],
  'contracts/test/SimSwap.sol': ['SimWrapped', 'SimRouter'],
};

function findImports(importPath) {
  const fullPath = path.join(root, 'node_modules', importPath);
  if (fs.existsSync(fullPath)) return { contents: fs.readFileSync(fullPath, 'utf8') };
  return { error: `Missing import: ${importPath}` };
}

const input = {
  language: 'Solidity',
  sources: Object.fromEntries(Object.keys(sources).map((key) => [key, { content: fs.readFileSync(path.join(root, key), 'utf8') }])),
  settings: {
    evmVersion: 'cancun',
    optimizer: { enabled: true, runs: 200 },
    outputSelection: { '*': { '*': ['abi', 'evm.bytecode.object'] } },
  },
};
const output = JSON.parse(solc.compile(JSON.stringify(input), { import: findImports }));
const errors = (output.errors || []).filter((item) => item.severity === 'error');
if (errors.length) {
  for (const error of errors) process.stderr.write(`${error.formattedMessage}\n`);
  process.exit(1);
}
const outDir = path.join(root, 'build');
fs.mkdirSync(outDir, { recursive: true });
for (const [key, names] of Object.entries(sources)) {
  for (const name of names) {
    const compiled = output.contracts[key][name];
    fs.writeFileSync(path.join(outDir, `${name}.json`), JSON.stringify({ contractName: name, solc: solc.version(), abi: compiled.abi, bytecode: `0x${compiled.evm.bytecode.object}` }, null, 2));
  }
}
process.stdout.write(`Compiled ${Object.values(sources).flat().join(', ')} with solc ${solc.version()}\n`);
