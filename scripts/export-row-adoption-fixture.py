#!/usr/bin/env python3
"""Build genuine public additive predecessors and an unchanged-handler inspector candidate.

Regression infrastructure only. Both compilers use the ordinary public route;
no row artifact entry point, metadata injection, or runtime overlay is used.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ['tesl', 'legacy-compiler', 'bridge-compiler', 'repo', 'out']:
        parser.add_argument('--' + arg, required=True, type=Path)
    args = parser.parse_args()
    root = args.out.resolve()
    root.mkdir(parents=True, exist_ok=False)
    repo = args.repo.resolve()
    fixture = repo / 'compiler/test/fixtures/row-adoption'
    tools, program, logs, releases = [root / n for n in ['tools', 'program', 'logs', 'releases']]
    for directory in [tools, program, logs, releases]:
        directory.mkdir()
    for name, source in [('tesl', args.tesl), ('legacy', args.legacy_compiler), ('bridge', args.bridge_compiler)]:
        shutil.copy2(source.resolve(), tools / name)
    environment = dict(os.environ, TESL_REPO_ROOT=str(repo), TESL_COMPILER=str(tools / 'legacy'))
    commands = []

    def run(label, *arguments, good=True, raw=False, cwd=program):
        command = list(arguments) if raw else [str(tools / 'tesl'), *arguments]
        result = subprocess.run(command, cwd=cwd, env=environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        (logs / (label + '.stdout')).write_bytes(result.stdout)
        (logs / (label + '.stderr')).write_bytes(result.stderr)
        commands.append({'label': label, 'args': command, 'exit': result.returncode})
        (root / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n')
        if (result.returncode == 0) != good:
            raise RuntimeError(f'{label}: unexpected exit {result.returncode}; see {logs}')
        return result.stdout

    def check(label, path, error=None):
        result = json.loads(run(label, 'agent-context', str(program / path), good=error is None))
        errors = {d['code'] for d in result['diagnostics'] if d['severity'] == 'error'}
        if errors != ({error} if error else set()):
            raise RuntimeError(f'{label}: wrong diagnostics: {errors}')

    def write(path, contents):
        target = program / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(contents)

    def build(name):
        check(name + '-app', 'app.tesl')
        run(name + '-check', 'check', 'app.tesl')
        run(name + '-build', 'build', '--local')
        generated = program / '.tesl-stuff/go-build'
        release = releases / name
        shutil.copytree(generated, release, ignore=shutil.ignore_patterns('*.json'))
        history = json.loads((generated / 'migration-history.json').read_text())
        if history.get('version') != 3:
            raise RuntimeError(f'{name}: ordinary format3 compiler path was not used')
        identity = {'compiler': digest(Path(environment['TESL_COMPILER'])), 'tesl': digest(tools / 'tesl'),
                    'appSource': digest(program / 'app.tesl'), 'appBinary': digest(release / 'tesl-app'),
                    'sourceFormat': history['version'], 'frozenV1Exists': (program / 'schema/notes/v1.tesl').exists(),
                    'sources': {str(p.relative_to(program)): digest(p) for p in program.rglob('*.tesl')}}
        (release / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
        return release, identity

    for name, dest in [('app.tesl.in', 'app.tesl'), ('tesl.toml.in', 'tesl.toml'), ('v1.tesl.in', 'schema/notes/v-current.tesl')]:
        write(dest, (fixture / name).read_bytes())
    check('v1-schema', 'schema/notes/v-current.tesl')
    _, original = build('v1')
    assert not original['frozenV1Exists']
    run('freeze-v1', 'migrate', 'generate', 'app.tesl', '--new-revision')
    check('frozen-v1', 'schema/notes/v1.tesl')
    write('schema/notes/v-current.tesl', (fixture / 'v2.tesl.in').read_bytes())
    check('v2-edited', 'schema/notes/v-current.tesl', 'MIG001')
    run('refresh-v2', 'migrate', 'generate', 'app.tesl')
    check('v2-schema', 'schema/notes/v-current.tesl')
    check('v2-migration', 'migrations/notes/v2.tesl')
    _, current = build('v2')
    environment['TESL_COMPILER'] = str(tools / 'bridge')
    # Remove only generated output so CLI compilation cannot reuse legacy runtime.
    shutil.rmtree(program / '.tesl-stuff/go-build')
    release, bridge = build('bridge')
    assert original['appSource'] == current['appSource'] == bridge['appSource']
    assert original['compiler'] == current['compiler']
    probe = release / 'cmd/adoption-inspect/main.go'
    probe.parent.mkdir(parents=True)
    probe.write_bytes((fixture / 'probe.go').read_bytes())
    run('bridge-inspector-build', 'go', 'build', '-o', 'inspect', './cmd/adoption-inspect', raw=True, cwd=release)
    program.rename(root / 'source-archive')
    manifest = {str(p.relative_to(releases)): digest(p) for p in releases.rglob('*') if p.is_file()}
    (root / 'programs.json').write_text(json.dumps(manifest, indent=2) + '\n')
    result = {'status': 'built', 'programs': str(releases), 'originalSourceAbsent': not program.exists(),
              'unchangedApp': True, 'sourceFormat': 3, 'adoptionMutationEnabled': False,
              'logs': {str(p.relative_to(root)): digest(p) for p in logs.iterdir()}}
    (root / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ['status', 'programs', 'originalSourceAbsent', 'unchangedApp']}))


if __name__ == '__main__':
    main()
