"""Test-only process guard that makes accidental network access fail loudly."""

from __future__ import annotations

import os
import socket
import urllib.request


if os.environ.get("MOMO_TEST_NETWORK_DISABLED") == "1":
    def _blocked(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("network disabled by Issue #9 test guard")


    socket.socket = _blocked  # type: ignore[assignment]
    socket.create_connection = _blocked  # type: ignore[assignment]
    urllib.request.urlopen = _blocked  # type: ignore[assignment]
