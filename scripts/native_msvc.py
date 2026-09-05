"""Keep native Microsoft tools ahead of Cygwin's namesakes in child processes."""

import os
from pathlib import Path


def prefer_msvc(environment, compiler):
    # GitHub's GITHUB_PATH entries can put Cygwin back ahead of the developer
    # environment between steps. Re-establish priority in the actual child env.
    directory = Path(compiler).absolute().parent
    if not (directory / "link.exe").is_file():
        raise ValueError("native MSVC link.exe is required beside cl.exe")
    return {**environment, "PATH": str(directory) + os.pathsep + environment.get("PATH", "")}
