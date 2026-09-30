import { build } from 'esbuild';
import { copyFile, mkdir } from 'node:fs/promises';
import path from 'node:path';
const outdir = path.resolve(process.argv[2] || 'dist');
await mkdir(outdir, { recursive: true });
await build({ entryPoints: ['monaco.js'], bundle: true, minify: true, format: 'iife', target: ['es2022'],
  outfile: path.join(outdir, 'monaco.js'), loader: { '.ttf': 'file' }, assetNames: 'monaco-assets/[name]-[hash]', legalComments: 'linked' });
await build({ entryPoints: ['node_modules/monaco-editor/esm/vs/editor/editor.worker.js'], bundle: true, minify: true,
  format: 'iife', target: ['es2022'], outfile: path.join(outdir, 'monaco-worker.js'), legalComments: 'linked' });
await copyFile('node_modules/monaco-editor/LICENSE', path.join(outdir, 'monaco-LICENSE.txt'));
