import { build } from 'esbuild';
import { minify } from 'terser';
import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
const outdir = path.resolve(process.argv[2] || 'dist');
await mkdir(outdir, { recursive: true });
// Minify the emitted compiler without unsafe transforms or property mangling.
// Parity and the unchanged size gate consume these exact shipped bytes.
for (const name of ['tesl_playground.js', 'tesl_search.js']) {
  const file = path.join(outdir, name);
  const { code } = await minify(await readFile(file, 'utf8'), {
    ecma: 2022, compress: true, mangle: true, format: { comments: 'some' },
  });
  if (typeof code !== 'string' || code.length === 0) throw new Error(`empty compiler bundle: ${name}`);
  await writeFile(file, code);
}
await build({ entryPoints: ['monaco.js'], bundle: true, minify: true, format: 'iife', target: ['es2022'],
  outfile: path.join(outdir, 'monaco.js'), loader: { '.ttf': 'file' }, assetNames: 'monaco-assets/[name]-[hash]', legalComments: 'linked' });
await build({ entryPoints: ['node_modules/monaco-editor/esm/vs/editor/editor.worker.js'], bundle: true, minify: true,
  format: 'iife', target: ['es2022'], outfile: path.join(outdir, 'monaco-worker.js'), legalComments: 'linked' });
await copyFile('node_modules/monaco-editor/LICENSE', path.join(outdir, 'monaco-LICENSE.txt'));
