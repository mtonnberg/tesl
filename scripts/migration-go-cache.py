#!/usr/bin/env python3
"""Keep warmed dependencies, discard completed migration phases' Go artifacts.

The runner supplies a fresh, private GOCACHE. Prune only between phases, after
all Go commands have exited; never operate on the developer's shared cache.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import stat

MARKER = '.tesl-migration-cache.json'


def files(cache):
    for directory, dirs, names in os.walk(cache, followlinks=False):
        # Do not follow directory links, including ones created by a fixture.
        for name in list(dirs):
            path = Path(directory) / name
            if path.is_symlink():
                dirs.remove(name)
                yield path
        for name in names:
            path = Path(directory) / name
            if path != cache / MARKER:
                yield path


def identity(cache):
    if cache.is_symlink() or not cache.is_dir():
        raise ValueError('migration cache must be a real private directory')
    info = cache.stat()
    return [str(cache.resolve()), info.st_dev, info.st_ino]


def seed(cache):
    owner = identity(cache)
    marker = cache / MARKER
    paths = list(files(cache))
    # Exclusive creation refuses a second seed that could retain generated apps.
    with marker.open('x') as output:
        json.dump({'version': 1, 'identity': owner,
                   'files': sorted(str(p.relative_to(cache)) for p in paths)}, output)
    size = sum(p.lstat().st_size for p in paths)
    print(f'Migration Go cache: warmed {size // (1024 * 1024)} MiB; '
          f'{shutil.disk_usage(cache).free // (1024 * 1024)} MiB free', flush=True)


def prune(cache):
    owner = identity(cache)
    marker = cache / MARKER
    if not stat.S_ISREG(marker.lstat().st_mode):
        raise ValueError('migration cache marker must be a regular file')
    state = json.loads(marker.read_text())
    if state['version'] != 1 or state['identity'] != owner:
        raise ValueError('migration cache ownership marker does not match')
    retained = set(state['files'])
    reclaimed = 0
    for path in files(cache):
        if str(path.relative_to(cache)) not in retained:
            reclaimed += path.lstat().st_size
            path.unlink()
    print(f'Migration Go cache: reclaimed {reclaimed // (1024 * 1024)} MiB; '
          f'{shutil.disk_usage(cache).free // (1024 * 1024)} MiB free', flush=True)
    return reclaimed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('seed', 'prune'))
    parser.add_argument('cache', type=Path)
    args = parser.parse_args()
    selected = os.environ.get('GOCACHE')
    if not selected or not Path(selected).is_absolute() or Path(selected).resolve() != args.cache.resolve():
        parser.error('the runner must explicitly select this private GOCACHE')
    (seed if args.operation == 'seed' else prune)(args.cache)


if __name__ == '__main__':
    main()
