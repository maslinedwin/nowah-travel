// Entry shim so `node --test tests/` works across Node versions.
//
// Node <=22 expands a directory positional and runs the *.test.mjs files in
// it (this file does not match the test-file pattern, so it is ignored).
// Node 24 treats positionals as literal entries and spawns `node tests`,
// which resolves to this index — loading the real test file keeps the same
// command working there too.
module.exports = import('./model.test.mjs');
