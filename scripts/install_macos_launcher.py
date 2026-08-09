#!/usr/bin/env python3
"""Create/refresh a local double-clickable macOS launcher for Issue #54.

The generated app contains only a small AppleScript wrapper pointing at this
checkout.  No compiled bundle is committed, and no Token or account data is
accepted by this installer or embedded in the launcher.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import shlex
import subprocess
import sys
from typing import Callable, Sequence


ROOT = Path(__file__).resolve().parents[1]
UI_SCRIPT = ROOT / "scripts" / "interpretation_local_ui.py"
DEFAULT_DESTINATION = Path.home() / "Applications" / "momo-moreEfficient.app"
OSACOMPILE = "/usr/bin/osacompile"


class LauncherInstallError(Exception):
    def __init__(self) -> None:
        super().__init__("无法创建 momo-moreEfficient 启动器。")


def _applescript_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def launcher_source(python: Path, ui_script: Path) -> tuple[str, ...]:
    """Return the transparent AppleScript source compiled into the local app."""
    python_path = str(Path(python).resolve())
    script_path = str(Path(ui_script).resolve())
    check_command = (
        f"test -x {shlex.quote(python_path)} && "
        f"test -f {shlex.quote(script_path)}"
    )
    launch_command = (
        f"nohup {shlex.quote(python_path)} {shlex.quote(script_path)} "
        ">/dev/null 2>&1 &"
    )
    return (
        "try",
        f"do shell script {_applescript_string(check_command)}",
        f"do shell script {_applescript_string(launch_command)}",
        "on error",
        'display dialog "无法启动 momo-moreEfficient。请确认仓库仍在原位置，并已安装 Python 3。" '
        'with title "momo-moreEfficient" buttons {"好"} default button "好" with icon stop',
        "end try",
    )


def compile_argv(
    destination: Path, source: Sequence[str], *, osacompile: str = OSACOMPILE
) -> list[str]:
    argv = [osacompile, "-o", str(destination)]
    for line in source:
        argv.extend(("-e", line))
    return argv


def install_launcher(
    destination: Path = DEFAULT_DESTINATION,
    *,
    runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> Path:
    if not UI_SCRIPT.is_file():
        raise LauncherInstallError()
    # Use the interpreter that successfully started this installer.  Looking up
    # another generic ``python3`` could silently select an older system runtime.
    python = Path(sys.executable).resolve()
    target = Path(destination).expanduser().resolve()
    if target.suffix != ".app" or target.name != "momo-moreEfficient.app":
        raise LauncherInstallError()
    target.parent.mkdir(parents=True, exist_ok=True)
    source = launcher_source(python, UI_SCRIPT)
    try:
        completed = runner(
            compile_argv(target, source),
            capture_output=True,
            text=True,
            check=False,
        )
    except Exception:
        raise LauncherInstallError() from None
    if completed.returncode != 0:
        raise LauncherInstallError()
    return target


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="创建本地双击启动器；不会读取或保存 Token。"
    )
    parser.add_argument("--destination", type=Path, default=DEFAULT_DESTINATION)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        destination = install_launcher(args.destination)
    except LauncherInstallError as rejected:
        print(str(rejected))
        return 1
    print(f"启动器已创建：{destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
