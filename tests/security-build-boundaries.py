#!/usr/bin/env python3
"""Regression checks for repository data crossing build and debug boundaries."""
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[1]
GEN = REPO / 'compiler/_build/default/gen/gen_docs.exe'


def run(args, cwd, **kwargs):
    return subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=20, **kwargs)


def docs():
    with tempfile.TemporaryDirectory(prefix='tesl-doc-boundary-') as temp:
        root = Path(temp) / 'repo'
        (root / 'manual').mkdir(parents=True)
        (root / 'example/learn').mkdir(parents=True)
        for name in ['README.md', 'LANGUAGE-SPEC.md', 'INSTALL.md']:
            (root / name).write_text('public documentation\n')
        commands = [[str(GEN), str(root)], ['ocaml', str(REPO / 'scripts/gen_embedded_docs.ml'), str(root)]]
        baseline = [run(cmd, REPO) for cmd in commands]
        assert all(p.returncode == 0 for p in baseline), baseline
        assert baseline[0].stdout == baseline[1].stdout
        secret = Path(temp) / 'secret'
        secret.write_text('HOST_SECRET_MUST_NOT_BE_EMBEDDED')
        target = root / 'example/learn/leak.md'
        for kind in ['symlink', 'fifo', 'oversize', 'directory-symlink']:
            if kind == 'symlink':
                target.symlink_to(secret)
            elif kind == 'fifo':
                os.mkfifo(target)
            elif kind == 'oversize':
                with target.open('wb') as stream:
                    stream.truncate(4 * 1024 * 1024 + 1)
            else:
                (root / 'example/learn').rmdir()
                outside = Path(temp) / 'outside'
                outside.mkdir()
                (outside / 'leak.md').write_text(secret.read_text())
                (root / 'example/learn').symlink_to(outside, target_is_directory=True)
            for cmd in commands:
                result = run(cmd, REPO)
                assert result.returncode != 0, (kind, cmd)
                assert secret.read_text() not in result.stdout, (kind, cmd)
            if kind != 'directory-symlink':
                target.unlink()
    print('documentation: regular files pass; symlinks, devices and oversized files fail closed')


def templates():
    with tempfile.TemporaryDirectory(prefix='tesl-template-boundary-') as temp:
        root = Path(temp)
        (root / 'app.tesl').write_text('module App exposing []\n')
        marker = root / 'owned'
        for field, value in [('name', f'x|g; e touch {marker}; #'), ('PORT', f'8086|g;e touch {marker};#'), ('PORT', '65536')]:
            name, port = (value, '8086') if field == 'name' else ('safe-name', value)
            (root / 'tesl.toml').write_text(f'[project]\nname = "{name}"\nentrypoint = "app.tesl"\n[env]\nPORT = "{port}"\n')
            result = run(['bash', str(REPO / 'nix/tesl-cli-body.sh'), 'build', '--no-docker'], root,
                         env={**os.environ, 'TESL_OCAML_COMPILER': '/bin/true'})
            assert result.returncode != 0, (field, result)
            assert not marker.exists()
        helpers = root / 'helpers.sh'
        helpers.write_text((REPO / 'nix/tesl-cli-body.sh').read_text().split('CMD="${1:-help}"')[0])
        template = root / 'template'
        template.write_text('__APP_NAME__ __PORT__\n')
        result = run(['bash', '-c', 'source "$1"; _tesl_render_template "$2" "$3" 8086',
                      'test', str(helpers), str(template), 'literal|&value'], root)
        assert result.returncode == 0 and result.stdout == 'literal|&value 8086\n', result
    print('templates: manifest injection rejected; replacement metacharacters remain data')


def debug_files():
    source = (REPO / '.claude/commands/tesl-debug-curl.md').read_text()
    for name, prefix in [('TESL_ATTACH_STATE', 'tesl-attach'), ('TESL_INSPECT_STATE', 'tesl-inspect')]:
        with tempfile.TemporaryDirectory(prefix='tesl-debug-boundary-') as temp:
            lines = source.splitlines()
            start = next(i for i, line in enumerate(lines) if f'{name}=' in line)
            setup = '\n'.join(line.strip() for line in lines[start-1:start+2])
            script = 'umask 022\n' + setup + f'\nprintf secret > "${name}/breakpoint.json"\nstat -c "%a" "${name}" "${name}/breakpoint.json"\nprintf "%s\\n" "${name}"\n'
            result = run(['bash', '-c', script], REPO, env={**os.environ, 'TMPDIR': temp})
            assert result.returncode == 0, result
            modes = result.stdout.splitlines()
            assert modes[:2] == ['700', '600'], modes
            assert not Path(modes[2]).exists(), 'cleanup trap left debug state behind'
    assert '/tmp/tesl-bp.' not in source
    print('debug snapshots: private directory, mode 0600 files, cleanup on exit')


if __name__ == '__main__':
    docs()
    templates()
    debug_files()
