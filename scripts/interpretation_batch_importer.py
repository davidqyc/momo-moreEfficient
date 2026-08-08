#!/usr/bin/env python3
"""Issue #32/#39/#51 — small-batch interpretation importer: dry-run, create, update.

This is the first actually useful product workflow: the owner keeps a batch of
roughly 8–15 vocabulary entries whose interpretations are already written, and
this tool removes the repetitive manual entry into Maimemo. It never rewrites,
improves, translates, summarizes or otherwise alters the owner's interpretation
text — the only text transformation is normalizing the document's own newline /
blank-line boundary so the batch can be split into entries at all.

Issue #39 adds the last core MVP mode: ``--mode update`` replaces exactly one
existing authenticated-user custom interpretation per vocabulary item, using the
documented ``POST /open/api/v1/interpretations/{id}`` endpoint whose body carries
only ``interpretation``/``tags``/``status`` and never a ``voc_id``. The update
target is only ever the single record returned by the authenticated collection
GET, never a value from argv or from the batch document, and update mode never
falls back to create.

Issue #51 adds the explicit main-account opt-in that D-010 contemplated. The
default is unchanged and stays secondary/test-account only; ``--allow-main-account``
together with one of a narrow reviewed main-account label family (``主账号`` /
``main-account``) is the only way to reach the owner's real account, and the two
requirements fail closed independently. The write machinery is identical — the
main path adds an account gate, a distinct hidden Token prompt, a visible warning
and a distinct confirmation binding, and changes no preflight, POST, readback or
stop rule. There is still no account-identity endpoint, so the account a Token
belongs to remains the operator's responsibility and the tool says so out loud.

Deliberate non-goals, so this stays a bicycle: no phrase/example path, no delete
path, no automated rollback engine, no workflow engine, no plugin system, no
service layer, no database, no server, no GUI and no general Maimemo client
library. `scripts/issue9_live_harness.py` remains a frozen spike/safety harness:
every already-reviewed primitive (hidden credential handling, account-label
policy, production transport, ``HttpRequest``, reviewed GET path building, the
observed ``data`` wrappers, vocabulary/collection/record-id/status validation and
the documented create/update payload contracts) is imported from it rather than
copied.

The reviewed network shape is per item, sequential, and structurally capped:

    dry-run  — 2 GETs per item, 0 POSTs;
    create   — 2 preflight GETs per item, then at most 1 POST + 1 readback GET
               per item, with no retry of any kind;
    update   — the same 2 preflight GETs per item, then at most 1 POST + 1
               readback GET per *changed* item, with no retry of any kind. An
               item that already matches the intended final state exactly is a
               satisfied no-op and sends nothing.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
from datetime import datetime, timezone
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from typing import Any, Callable, Mapping, Sequence
from urllib.parse import urlsplit

_SCRIPTS = Path(__file__).resolve().parent
if str(_SCRIPTS) not in sys.path:
    sys.path.insert(0, str(_SCRIPTS))

import issue9_live_harness as harness  # noqa: E402


MODE_DRY_RUN = "dry-run"
MODE_CREATE = "create"
MODE_UPDATE = "update"
MODES: tuple[str, ...] = (MODE_DRY_RUN, MODE_CREATE, MODE_UPDATE)
OPERATION = "batch-interpretation-create"
OPERATION_UPDATE = "batch-interpretation-update"
CREATE_PATH = f"{harness.OPEN_API_PREFIX}/interpretations"
# The documented update endpoint. The record id lives ONLY in the path, and the
# concrete path is always rebuilt from this project-owned prefix plus one safe
# id taken from the authenticated collection GET.
UPDATE_PATH_TEMPLATE = f"{CREATE_PATH}/{{record_id}}"
COLLECTION_KEY = "interpretations"
# Exactly two reviewed GET endpoints. Phrases are outside the set on purpose:
# this tool performs no phrase request of any kind.
READ_PATHS: tuple[str, ...] = (f"{harness.OPEN_API_PREFIX}/vocabulary", CREATE_PATH)
# Tags and status are project-owned and are never accepted from the caller.
TAGS: tuple[str, ...] = ("MBA", "BEC", "GMAT")
STATUS = "PUBLISHED"
# The documented CREATE request keys. Nothing else is ever sent.
BODY_FIELDS: tuple[str, ...] = ("voc_id", "interpretation", "tags", "status")
# The documented UPDATE request keys. There is deliberately no voc_id and no id.
UPDATE_BODY_FIELDS: tuple[str, ...] = ("interpretation", "tags", "status")
# The documented interpretation status enum, owned by the frozen harness.
RECORD_STATUSES: tuple[str, ...] = harness.READ_ONLY_STATUS_ENUMS[COLLECTION_KEY]
# The documented tag vocabulary. An existing record's tags are pinned against
# this tuple before they are ever shown or stored, so an arbitrary server string
# can never travel out through the preview or the local report.
DOCUMENTED_TAGS: tuple[str, ...] = (
    "简明", "详细", "英英", "小学", "初中", "高中",
    "四级", "六级", "专升本", "专四", "专八", "考研",
    "考博", "雅思", "托福", "托业", "新概念", "法学", "医学",
    "GRE", "GMAT", "BEC", "MBA", "SAT", "ACT",
)
MAX_RECORD_TAGS = len(DOCUMENTED_TAGS)

# One simple Markdown batch format, and only one. No YAML/JSON/CSV/TSV variant.
HEADING_MARKER = "##"
HEADING_PATTERN = re.compile(r"^##[ ](\S.*)$")
MAX_BATCH_ITEMS = 30
TYPICAL_BATCH_ITEMS = (8, 15)
MAX_INTERPRETATION_CHARS = 2_000
MAX_INPUT_BYTES = 262_144

# A batch-specific write confirmation. It shares wording with neither the
# read-only nor the single-write confirmation, so no earlier confirmation string
# can be pasted into this gate.
#
# The CREATE form has already been validated end to end against production and is
# frozen byte for byte. The UPDATE form is deliberately different: Issue #41
# showed that the 181-character sentence is unreliable to copy out of a terminal
# by hand, and the run aborted before the first POST on strict equality. Issue
# #42 therefore renders UPDATE as one short project-owned token whose 16 hex
# characters are the SAME prefix of the SHA-256 digest over the SAME full
# `confirmation_binding()`. Nothing that was bound before is unbound now — the
# long human-readable fields simply stay in the visible confirmation block
# instead of being retyped inside the pasted string.
CONFIRMATION_PREFIX = "CONFIRM BATCH INTERPRETATION CREATE"
UPDATE_CONFIRMATION_PREFIX = "CONFIRM UPDATE"
# The shared binding-digest width. Both modes have always shown 16 hex chars.
BINDING_DIGEST_CHARS = 16
# A product bound on the string the owner copies by hand, so it cannot wrap in an
# ordinary terminal. Only the UPDATE form is required to satisfy it; the CREATE
# form predates it and is frozen.
MAX_COPIED_CONFIRMATION_CHARS = 80
BATCH_ONE_POST_CLAUSE = "EXACTLY-ONE-POST-PER-ITEM-NO-RETRY-IMMEDIATE-READBACK"
WRITE_POLICY = "EXACTLY ONE POST PER ITEM / NO RETRY / IMMEDIATE READBACK"
TOKEN_PROMPT = "Secondary/test-account Maimemo Token (hidden): "
CONFIRMATION_PROMPT = "Exact batch CREATE confirmation (hidden): "
UPDATE_CONFIRMATION_PROMPT = "Exact batch UPDATE confirmation (hidden): "
PRICING_TERMS_GATE = (
    "Confirm current official pricing/terms permit personal secondary/test-account "
    "use and show no mandatory metered API fee."
)

# Issue #51: the explicit, opt-in main-account path.
#
# The default is unchanged and stays secondary/test-account only. Main-account
# mode requires BOTH `--allow-main-account` AND one of a narrow reviewed label
# family, and it is deliberately built beside — never on top of — the frozen
# secondary policy in `issue9_live_harness`: that harness keeps rejecting every
# main/production label, so the historical spike/probe tools remain
# test-account-only exactly as D-010 requires.
ACCOUNT_SECONDARY = "secondary"
ACCOUNT_MAIN = "main"
ACCOUNT_MODES: tuple[str, ...] = (ACCOUNT_SECONDARY, ACCOUNT_MAIN)
# The whole reviewed main-account label family. It is intentionally tiny and
# personal: `prod`/`production` are NOT synonyms for the owner's main account and
# are never accepted here.
MAIN_ACCOUNT_LABELS: tuple[str, ...] = ("主账号", "main-account")
MAIN_ACCOUNT_CREDENTIAL_SOURCE = "owner-main-account"
MAIN_ACCOUNT_GATE_PREFIX = "CONFIRM MAIN ACCOUNT"
# Distinct confirmation prefixes, so a confirmation copied out of a secondary run
# is not even the right shape for a main-account run. Both are short tokens over
# the SAME full `confirmation_binding()` digest that the reviewed UPDATE form
# already uses, so nothing that was bound before becomes unbound here.
MAIN_CREATE_CONFIRMATION_PREFIX = "CONFIRM MAIN CREATE"
MAIN_UPDATE_CONFIRMATION_PREFIX = "CONFIRM MAIN UPDATE"
MAIN_TOKEN_PROMPT = "Main-account Maimemo Token (hidden): "
MAIN_CONFIRMATION_PROMPT = "Exact MAIN-ACCOUNT batch CREATE confirmation (hidden): "
MAIN_UPDATE_CONFIRMATION_PROMPT = "Exact MAIN-ACCOUNT batch UPDATE confirmation (hidden): "
MAIN_PRICING_TERMS_GATE = (
    "Confirm current official pricing/terms permit personal MAIN-account use and "
    "show no mandatory metered API fee."
)

# Conservative fixed pacing between production requests, so a 15-item batch does
# not arrive as one burst. It is a two-line local mechanism, not a rate limiter,
# and no correctness rule in this module depends on its value: tests inject a
# recording no-op sleep.
#
# The floor is chosen so a full batch stays inside the currently published
# official request windows (20 requests / 10 s, 40 requests / 60 s) without
# relying on network latency: a CREATE item costs at most 4 requests
# (2 preflight GET + 1 POST + 1 readback GET), so a 15-item batch sends 60
# requests. At 1.6 s, 20 intervals span 32 s and 40 intervals span 64 s.
PACING_SECONDS = 1.6

PARSE_REASONS: tuple[str, ...] = (
    "empty-document",
    "content-before-first-heading",
    "malformed-heading",
    "spelling-policy",
    "empty-interpretation",
    "interpretation-policy",
    "duplicate-spelling",
    "batch-too-large",
    "input-unreadable",
)

# The per-item preflight classification. `blocked-error` is the only state that
# also carries a closed transport/http/schema/safety class.
#
# `ready-create` / `blocked-existing` belong to create mode's zero baseline;
# `ready-update` / `already-matching` / `blocked-missing` belong to update mode's
# exactly-one baseline. `already-matching` is a satisfied no-op, not a blocker.
READY_CREATE = "ready-create"
READY_UPDATE = "ready-update"
ALREADY_MATCHING = "already-matching"
BLOCK_EXISTING = "blocked-existing"
BLOCK_MISSING = "blocked-missing"
BLOCK_AMBIGUOUS = "blocked-ambiguous"
BLOCK_ERROR = "blocked-error"
PREFLIGHT_STATES: tuple[str, ...] = (
    READY_CREATE,
    READY_UPDATE,
    ALREADY_MATCHING,
    BLOCK_EXISTING,
    BLOCK_MISSING,
    BLOCK_AMBIGUOUS,
    BLOCK_ERROR,
)

ERROR_CLASSES: tuple[str, ...] = (
    "transport",
    "http-status",
    "schema",
    "safety",
    "ambiguous",
    "mismatch",
    "unknown-write-outcome",
)

# The write-outcome vocabulary is shared with the reviewed one-shot probe.
OUTCOMES: tuple[str, ...] = harness.INTERPRETATION_CREATE_WRITE_OUTCOMES
NOT_ATTEMPTED = harness.WRITE_OUTCOME_NOT_ATTEMPTED
CONFIRMED = harness.WRITE_OUTCOME_CONFIRMED_SUCCESS
RECOVERED = harness.WRITE_OUTCOME_RECOVERED_SUCCESS
NOT_VERIFIED = harness.WRITE_OUTCOME_NOT_VERIFIED
AMBIGUOUS = harness.WRITE_OUTCOME_AMBIGUOUS

# `satisfied` is update mode's successful zero-write outcome: every item already
# equals the intended final state, so nothing was confirmed and nothing was sent.
RUN_STATUSES: tuple[str, ...] = (
    "ready",
    "blocked",
    "verified",
    "stopped",
    "satisfied",
)

REPORT_PREFIX = "issue32-interpretation-batch"
REPORT_VERSION = 2

BLOCKED_GATE_MESSAGE = (
    "BLOCKED: --allow-network, --mode, the batch file, the account label, the "
    "fixed contract, an interactive terminal or the locked transport was rejected."
)
BLOCKED_CREDENTIAL_MESSAGE = (
    "BLOCKED: the hidden secondary-account credential was not accepted."
)
BLOCKED_MAIN_CREDENTIAL_MESSAGE = (
    "BLOCKED: the hidden main-account credential was not accepted."
)
BLOCKED_MAIN_ACCOUNT_MESSAGE = (
    "BLOCKED: main-account use requires BOTH --allow-main-account AND one reviewed "
    "main-account label (主账号 or main-account). Without --allow-main-account this "
    "importer stays secondary/test-account only, and a secondary/test label can "
    "never be combined with --allow-main-account. No Token was requested and no "
    "transport was created."
)
BLOCKED_INTERNAL_MESSAGE = (
    "BLOCKED: the batch importer stopped safely; only project-owned sanitized "
    "fields are available."
)


def _pinned(allowed: tuple[str, ...], value: Any) -> str:
    """Return the module-owned constant equal to ``value``, selected by identity.

    Returning the constant *object* is what keeps every emitted enum
    project-owned: a server string, an injected transport or an external
    exception can never smuggle its own text out through one of these fields,
    even when that text happens to compare equal.
    """
    if not isinstance(value, str):
        raise harness.SafetyError("value is outside the fixed project enum")
    match = next((item for item in allowed if item == value), None)
    if match is None:
        raise harness.SafetyError("value is outside the fixed project enum")
    return match


def _canonical(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _digest(value: Any) -> str:
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _short_fingerprint(value: str) -> str:
    return harness._fingerprint(value)["sha256"][:16]


def _valid_fingerprint(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{16}", value) is not None


def _plain_count(value: Any, maximum: int) -> bool:
    return (
        isinstance(value, int)
        and not isinstance(value, bool)
        and 0 <= value <= maximum
    )


# --------------------------------------------------------------------------- #
# Account policy: the frozen secondary path, and the explicit main-account path
# --------------------------------------------------------------------------- #


class MainAccountGateError(harness.SafetyError):
    """The main-account opt-in and the account label did not agree.

    It names the one operator mistake this gate exists to catch — a reviewed
    main-account label without ``--allow-main-account``, or ``--allow-main-account``
    with a secondary/test label — without ever echoing the label itself.
    """


def _pinned_main_label(value: Any) -> str | None:
    """Return the reviewed main-account constant this label names, else ``None``.

    Matching is case-insensitive but the returned string is always this module's
    own constant, so the label that gets bound, gated and compared is canonical
    and can never be a caller-supplied lookalike.
    """
    if not isinstance(value, str):
        return None
    normalized = value.casefold()
    return next(
        (label for label in MAIN_ACCOUNT_LABELS if label.casefold() == normalized),
        None,
    )


def _secondary_label_accepted(value: Any) -> bool:
    """True when the FROZEN secondary/test policy would accept this label."""
    try:
        harness._validate_account_label_shape(value)
    except harness.SafetyError:
        return False
    return True


def validate_main_account_label(value: Any) -> str:
    """Accept only the narrow reviewed main-account label family, or fail closed.

    This is importer-local on purpose. The frozen harness gate is not relaxed and
    not consulted for acceptance: it keeps rejecting every main/production label,
    so no historical spike/probe tool gains a main-account path from this change.
    """
    validate_contract()
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or len(value) > harness.MAX_ACCOUNT_LABEL_CHARS
        or harness._has_control_characters(value)
    ):
        raise harness.SafetyError("account label does not meet the fixed safety policy")
    if any(
        marker in value.casefold()
        for marker in harness.REQUIRED_TEST_ACCOUNT_LABEL_MARKERS
    ):
        raise MainAccountGateError(
            "a secondary/test account label can never authorize main-account mode"
        )
    label = _pinned_main_label(value)
    if label is None:
        raise MainAccountGateError(
            "main-account mode requires one reviewed main-account label"
        )
    return label


def validate_account_label(
    value: Any, *, account_mode: str = ACCOUNT_SECONDARY
) -> str:
    """Validate one account label under exactly one account policy.

    The default is the frozen secondary/test policy, byte for byte as before. The
    only new behavior is that a reviewed main-account label offered WITHOUT the
    opt-in is reported as the specific gate mistake it is — it is still rejected,
    still before any Token prompt or transport, and still with a ``SafetyError``.
    """
    if _pinned(ACCOUNT_MODES, account_mode) == ACCOUNT_MAIN:
        return validate_main_account_label(value)
    try:
        return harness._validate_account_label_shape(value)
    except harness.SafetyError:
        if _pinned_main_label(value) is not None:
            raise MainAccountGateError(
                "a main-account label requires the explicit main-account opt-in"
            ) from None
        raise


@dataclass(frozen=True, repr=False)
class MainAccountCredential(harness.TestAccountCredential):
    """A hidden, memory-only Token explicitly bound to the owner's MAIN account.

    It reuses the reviewed credential primitive — same token-shape policy, same
    redacted ``repr``/``str``, same 16-hex fingerprint, same "never on argv, in
    the environment, in a file or in a log" contract — and differs in exactly two
    ways: it demands a reviewed main-account label, and it carries a distinct
    source name so a secondary gate can never accept it and vice versa.
    """

    source_name: str = MAIN_ACCOUNT_CREDENTIAL_SOURCE

    def __post_init__(self) -> None:
        # Deliberately does not call the base validator: that one enforces the
        # frozen secondary-only label policy, which this path must not relax.
        if (
            not isinstance(self.token, str)
            or not self.token
            or self.token != self.token.strip()
            or len(self.token) > harness.MAX_TOKEN_CHARS
            or harness._has_control_characters(self.token)
        ):
            raise harness.SafetyError("an injected main-account credential is required")
        label = validate_main_account_label(self.account_label)
        object.__setattr__(self, "account_label", label)
        if self.token in label:
            raise harness.SafetyError("account label contains forbidden credential material")
        if self.source_name != MAIN_ACCOUNT_CREDENTIAL_SOURCE:
            raise harness.SafetyError("credential source is not the main-account source")

    def __repr__(self) -> str:
        return "MainAccountCredential(<redacted>)"

    def __str__(self) -> str:
        return "<redacted main-account credential>"


@dataclass(frozen=True, repr=False)
class MainAccountGate:
    """The main-account analogue of the frozen manual secondary gate.

    Same shape, same redaction and the same strict equality — with a different
    expected sentence and an explicit main-account credential source, so neither
    gate can ever be satisfied by the other side's credential.
    """

    allow_network: bool
    account_label: str
    credential_fingerprint: str
    confirmation: str

    def __post_init__(self) -> None:
        validate_main_account_label(self.account_label)
        if (
            not isinstance(self.credential_fingerprint, str)
            or re.fullmatch(r"[0-9a-f]{16}", self.credential_fingerprint) is None
        ):
            raise harness.SafetyError("credential fingerprint does not meet the fixed policy")
        if (
            not isinstance(self.confirmation, str)
            or not self.confirmation
            or self.confirmation != self.confirmation.strip()
            or len(self.confirmation) > harness.MAX_GATE_CONFIRMATION_CHARS
            or harness._has_control_characters(self.confirmation)
        ):
            raise harness.SafetyError("account confirmation does not meet the fixed policy")

    def __repr__(self) -> str:
        return (
            "MainAccountGate(allow_network="
            f"{self.allow_network!r}, account_label=<redacted>, "
            f"credential_fingerprint={self.credential_fingerprint!r}, "
            "confirmation=<redacted>)"
        )

    def __str__(self) -> str:
        return (
            "<manual main-account gate; label/confirmation redacted; "
            f"fingerprint={self.credential_fingerprint}>"
        )

    @property
    def expected_confirmation(self) -> str:
        return (
            f"{MAIN_ACCOUNT_GATE_PREFIX}: {self.account_label} "
            f"TOKEN-FP: {self.credential_fingerprint}"
        )

    def validate(self, credential: harness.TestAccountCredential) -> None:
        if not self.allow_network:
            raise harness.SafetyError("network mode was not explicitly enabled")
        label = validate_main_account_label(self.account_label)
        if getattr(credential, "source_name", None) != MAIN_ACCOUNT_CREDENTIAL_SOURCE:
            raise harness.SafetyError(
                "main-account mode requires an explicit main-account credential"
            )
        if credential.account_label != label:
            raise harness.SafetyError("credential label does not match the confirmed account")
        if credential.token in label or credential.token in self.confirmation:
            raise harness.SafetyError("account gate contains forbidden credential material")
        if self.credential_fingerprint != credential.fingerprint:
            raise harness.SafetyError("credential fingerprint does not match the confirmed token")
        if self.confirmation != self.expected_confirmation:
            raise harness.SafetyError("main-account confirmation does not match exactly")


def _account_gate(
    label: str, fingerprint: str, *, account_mode: str = ACCOUNT_SECONDARY
) -> harness.ManualAccountGate | MainAccountGate:
    if _pinned(ACCOUNT_MODES, account_mode) == ACCOUNT_MAIN:
        return MainAccountGate(
            allow_network=True,
            account_label=label,
            credential_fingerprint=fingerprint,
            confirmation=(
                f"{MAIN_ACCOUNT_GATE_PREFIX}: {label} TOKEN-FP: {fingerprint}"
            ),
        )
    return harness.ManualAccountGate(
        allow_network=True,
        account_label=label,
        credential_fingerprint=fingerprint,
        confirmation=f"CONFIRM SECONDARY TEST ACCOUNT: {label} TOKEN-FP: {fingerprint}",
    )


def validate_contract() -> None:
    """Fail closed if the fixed batch create/update contract ever drifts."""
    harness._validate_read_only_origin_contract()
    reserved = (
        harness.READ_ONLY_CONFIRMATION_PREFIX,
        harness.WRITE_CONFIRMATION_PREFIX,
    )
    main_prefixes = (MAIN_CREATE_CONFIRMATION_PREFIX, MAIN_UPDATE_CONFIRMATION_PREFIX)
    if (
        CREATE_PATH != "/open/api/v1/interpretations"
        or UPDATE_PATH_TEMPLATE != "/open/api/v1/interpretations/{record_id}"
        or READ_PATHS != ("/open/api/v1/vocabulary", "/open/api/v1/interpretations")
        or TAGS != ("MBA", "BEC", "GMAT")
        or TAGS != harness.REQUIRED_TAGS
        or set(TAGS) - set(DOCUMENTED_TAGS)
        or STATUS != "PUBLISHED"
        or STATUS not in RECORD_STATUSES
        or RECORD_STATUSES != harness.READ_ONLY_STATUS_ENUMS[COLLECTION_KEY]
        or BODY_FIELDS != ("voc_id", "interpretation", "tags", "status")
        or UPDATE_BODY_FIELDS != ("interpretation", "tags", "status")
        or "voc_id" in UPDATE_BODY_FIELDS
        or MODES != (MODE_DRY_RUN, MODE_CREATE, MODE_UPDATE)
        or MAX_BATCH_ITEMS != 30
        or CONFIRMATION_PREFIX in reserved
        or UPDATE_CONFIRMATION_PREFIX in reserved
        or CONFIRMATION_PREFIX == UPDATE_CONFIRMATION_PREFIX
        or "BATCH" not in CONFIRMATION_PREFIX
        or "CREATE" not in CONFIRMATION_PREFIX
        or "UPDATE" in CONFIRMATION_PREFIX
        or "UPDATE" not in UPDATE_CONFIRMATION_PREFIX
        or "CREATE" in UPDATE_CONFIRMATION_PREFIX
        or UPDATE_CONFIRMATION_PREFIX != UPDATE_CONFIRMATION_PREFIX.strip()
        or BINDING_DIGEST_CHARS != 16
        # The pasted UPDATE token must stay short enough to copy in one piece.
        or len(UPDATE_CONFIRMATION_PREFIX) + 1 + BINDING_DIGEST_CHARS
        > MAX_COPIED_CONFIRMATION_CHARS
        # Issue #51 — the main-account opt-in, and its separation from the frozen
        # secondary path.
        or ACCOUNT_MODES != (ACCOUNT_SECONDARY, ACCOUNT_MAIN)
        or ACCOUNT_SECONDARY == ACCOUNT_MAIN
        or MAIN_ACCOUNT_LABELS != ("主账号", "main-account")
        # The two label families can never overlap: every reviewed main-account
        # label must still be rejected by the frozen secondary/test policy and
        # must carry no secondary/test marker at all.
        or any(_secondary_label_accepted(label) for label in MAIN_ACCOUNT_LABELS)
        or any(
            marker in label.casefold()
            for label in MAIN_ACCOUNT_LABELS
            for marker in harness.REQUIRED_TEST_ACCOUNT_LABEL_MARKERS
        )
        # And the frozen secondary gate itself is still closed against them.
        or {"main", "primary", "owner", "主账号"}
        - set(harness.FORBIDDEN_ACCOUNT_LABEL_MARKERS)
        # A production label is not a personal main-account label.
        or _pinned_main_label("prod") is not None
        or _pinned_main_label("production") is not None
        or MAIN_ACCOUNT_CREDENTIAL_SOURCE == harness.TEST_ACCOUNT_CREDENTIAL_SOURCE
        or MAIN_TOKEN_PROMPT == TOKEN_PROMPT
        # Neither confirmation family can be mistaken for, or pasted into, the
        # other, and both main forms stay copy-safe in one piece.
        or MAIN_CREATE_CONFIRMATION_PREFIX == MAIN_UPDATE_CONFIRMATION_PREFIX
        or set(main_prefixes)
        & {CONFIRMATION_PREFIX, UPDATE_CONFIRMATION_PREFIX, *reserved}
        or any("MAIN" not in prefix for prefix in main_prefixes)
        or "MAIN" in CONFIRMATION_PREFIX
        or "MAIN" in UPDATE_CONFIRMATION_PREFIX
        or MAIN_ACCOUNT_GATE_PREFIX == "CONFIRM SECONDARY TEST ACCOUNT"
        or "MAIN" not in MAIN_ACCOUNT_GATE_PREFIX
        or "CREATE" not in MAIN_CREATE_CONFIRMATION_PREFIX
        or "UPDATE" in MAIN_CREATE_CONFIRMATION_PREFIX
        or "UPDATE" not in MAIN_UPDATE_CONFIRMATION_PREFIX
        or "CREATE" in MAIN_UPDATE_CONFIRMATION_PREFIX
        or any(prefix != prefix.strip() for prefix in main_prefixes)
        or max(len(prefix) for prefix in main_prefixes) + 1 + BINDING_DIGEST_CHARS
        > MAX_COPIED_CONFIRMATION_CHARS
    ):
        raise harness.SafetyError("the fixed batch interpretation write contract changed")


# --------------------------------------------------------------------------- #
# Batch parsing
# --------------------------------------------------------------------------- #


class BatchFormatError(harness.SafetyError):
    """A local batch-document rejection naming one closed project-owned reason.

    The offending spelling, interpretation, line text or file path is never
    interpolated: the owner gets the reason plus a 1-based line number, which is
    enough to find the entry in their own file.
    """

    def __init__(self, reason: str, line: int | None = None) -> None:
        self.reason = _pinned(PARSE_REASONS, reason)
        self.line = line if isinstance(line, int) and not isinstance(line, bool) else None
        super().__init__(self.message)

    @property
    def message(self) -> str:
        location = "" if self.line is None else f" (line {self.line})"
        return f"batch document rejected: {self.reason}{location}"

    def __repr__(self) -> str:
        return f"BatchFormatError({self.reason!r}, line={self.line!r})"

    def __str__(self) -> str:
        return self.message


@dataclass(frozen=True)
class BatchEntry:
    """One parsed entry: the owner's spelling and their exact interpretation."""

    ordinal: int
    spelling: str
    normalized_spelling: str
    interpretation: str = field(repr=False)
    line: int = 0

    def __post_init__(self) -> None:
        if not _plain_count(self.ordinal, MAX_BATCH_ITEMS) or self.ordinal < 1:
            raise harness.SafetyError("batch entry ordinal is outside the fixed bound")
        normalized = harness._normalize_probe_spelling(self.spelling)
        if normalized != self.normalized_spelling:
            raise harness.SafetyError("batch entry spelling normalization does not match")
        _validate_interpretation_text(self.interpretation)


def _validate_interpretation_text(value: Any) -> str:
    """Accept the owner's interpretation verbatim, or fail closed.

    This is a validator, never a rewriter: the accepted string is returned
    unchanged. Internal newlines are preserved; every other control character is
    rejected rather than stripped, so nothing invisible is ever silently altered.
    """
    if not isinstance(value, str) or not value.strip():
        raise BatchFormatError("empty-interpretation")
    if len(value) > MAX_INTERPRETATION_CHARS or any(
        (ord(character) < 32 or ord(character) == 127) and character != "\n"
        for character in value
    ):
        raise BatchFormatError("interpretation-policy")
    return value


def parse_batch(document: Any) -> tuple[BatchEntry, ...]:
    """Parse the one supported Markdown batch format into frozen entries.

    The format is exactly::

        ## <spelling>
        <interpretation body until the next ## heading>

    Only the document's own outer boundary is normalized: CRLF/CR line endings
    become LF, and blank lines immediately before/after a body are dropped.
    Everything inside a body — including internal line breaks and indentation —
    is preserved byte for byte.
    """
    validate_contract()
    if not isinstance(document, str):
        raise BatchFormatError("input-unreadable")
    lines = document.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    headings: list[tuple[int, str]] = []
    bodies: list[list[str]] = []
    for index, raw_line in enumerate(lines, start=1):
        stripped = raw_line.rstrip()
        if stripped.startswith("#"):
            match = HEADING_PATTERN.fullmatch(stripped)
            if match is None:
                raise BatchFormatError("malformed-heading", index)
            headings.append((index, match.group(1)))
            bodies.append([])
            if len(headings) > MAX_BATCH_ITEMS:
                raise BatchFormatError("batch-too-large", index)
            continue
        if not headings:
            if raw_line.strip():
                raise BatchFormatError("content-before-first-heading", index)
            continue
        bodies[-1].append(raw_line)
    if not headings:
        raise BatchFormatError("empty-document")

    entries: list[BatchEntry] = []
    seen: dict[str, int] = {}
    for ordinal, ((line, spelling), body_lines) in enumerate(
        zip(headings, bodies), start=1
    ):
        try:
            normalized = harness._normalize_probe_spelling(spelling)
        except harness.SafetyError:
            raise BatchFormatError("spelling-policy", line) from None
        if normalized in seen:
            raise BatchFormatError("duplicate-spelling", line)
        seen[normalized] = line
        body = list(body_lines)
        while body and not body[0].strip():
            body.pop(0)
        while body and not body[-1].strip():
            body.pop()
        interpretation = "\n".join(body)
        if not interpretation.strip():
            raise BatchFormatError("empty-interpretation", line)
        try:
            _validate_interpretation_text(interpretation)
        except BatchFormatError as rejected:
            raise BatchFormatError(rejected.reason, line) from None
        entries.append(
            BatchEntry(
                ordinal=ordinal,
                spelling=spelling,
                normalized_spelling=normalized,
                interpretation=interpretation,
                line=line,
            )
        )
    return tuple(entries)


def load_batch(path: Any) -> tuple[BatchEntry, ...]:
    """Read one small UTF-8 batch file and parse it. Never follows a directory."""
    try:
        resolved = Path(path)
        if resolved.is_dir() or resolved.stat().st_size > MAX_INPUT_BYTES:
            raise BatchFormatError("input-unreadable")
        document = resolved.read_text(encoding="utf-8")
    except BatchFormatError:
        raise
    except Exception:
        # The rejected path is never echoed: it can name private directories.
        raise BatchFormatError("input-unreadable") from None
    return parse_batch(document)


def batch_digest(entries: Sequence[BatchEntry], *, mode: str = MODE_CREATE) -> str:
    """The ordered, id-free digest of the whole intended batch.

    It is stable across runs, safe to show and safe to persist, and it changes if
    any spelling, any interpretation, the order, the item count, the tags, the
    status, the host, the intended operation or the write path changes. A dry-run
    previews the create path, so it shares the create digest; an update batch has
    a different operation and a different write path and therefore never collides
    with the create digest of the same document.
    """
    validate_contract()
    update = _pinned(MODES, mode) == MODE_UPDATE
    return _digest(
        {
            "operation": OPERATION_UPDATE if update else OPERATION,
            "host": harness.PRODUCTION_BASE_URL,
            "method": "POST",
            "path": UPDATE_PATH_TEMPLATE if update else CREATE_PATH,
            "tags": list(TAGS),
            "status": STATUS,
            "item_count": len(entries),
            "items": [
                {
                    "ordinal": entry.ordinal,
                    "spelling": entry.spelling,
                    "interpretation": entry.interpretation,
                }
                for entry in entries
            ],
        }
    )


# --------------------------------------------------------------------------- #
# The two documented request bodies
# --------------------------------------------------------------------------- #


def update_path(record_id: Any) -> str:
    """Build the documented update path from the project prefix and one safe id.

    The id is never interpolated as given: it is re-validated as a single safe
    path segment and the returned string is assembled from this module's own
    constant, so nothing from argv, from the batch document or from a response
    body can steer the request anywhere else.
    """
    validate_contract()
    return f"{CREATE_PATH}/{harness._safe_record_id(record_id, 'target interpretation id')}"


def create_body(vocabulary_id: str, interpretation: str) -> dict[str, Any]:
    """Build the one documented CREATE body from project-owned values only."""
    return {
        "interpretation": {
            "voc_id": harness._safe_record_id(vocabulary_id, "target vocabulary id"),
            "interpretation": _validate_interpretation_text(interpretation),
            "tags": list(TAGS),
            "status": STATUS,
        }
    }


def validate_create_body(body: Any, vocabulary_id: str, interpretation: str) -> None:
    """Reject anything that is not exactly the documented per-item payload."""
    if not isinstance(body, Mapping):
        raise harness.SafetyError("interpretation create body must be one reviewed object")
    thawed = harness._thaw_json(body)
    harness._assert_no_sensitive_keys(thawed, "interpretation create body")
    # The reviewed create contract does the structural work: exact top-level key,
    # exact field set, tags exactly MBA/BEC/GMAT, non-empty text, PUBLISHED
    # status, matching voc_id and the reviewed create path.
    harness._validate_operation_payload(
        "create_interpretation", CREATE_PATH, thawed, vocabulary_id
    )
    entity = thawed["interpretation"]
    if set(entity) != set(BODY_FIELDS) or entity["interpretation"] != interpretation:
        raise harness.SafetyError("interpretation create body is not the intended payload")


def update_body(interpretation: str) -> dict[str, Any]:
    """Build the one documented UPDATE body from project-owned values only.

    The documented update body carries exactly ``interpretation``, ``tags`` and
    ``status``. There is no ``voc_id`` and no top-level ``id``: the target record
    is addressed only by the path.
    """
    return {
        "interpretation": {
            "interpretation": _validate_interpretation_text(interpretation),
            "tags": list(TAGS),
            "status": STATUS,
        }
    }


def validate_update_body(body: Any, path: str, interpretation: str) -> None:
    """Reject anything that is not exactly the documented per-item update payload."""
    if not isinstance(body, Mapping):
        raise harness.SafetyError("interpretation update body must be one reviewed object")
    thawed = harness._thaw_json(body)
    harness._assert_no_sensitive_keys(thawed, "interpretation update body")
    # The reviewed update contract does the structural work: exact top-level key,
    # exact field set, tags exactly MBA/BEC/GMAT, non-empty text, PUBLISHED
    # status, an absent voc_id/id and the reviewed `/interpretations/{id}` path.
    prefix = f"{CREATE_PATH}/"
    if not isinstance(path, str) or not path.startswith(prefix):
        raise harness.SafetyError("the update path is outside the reviewed endpoint")
    record_id = harness._safe_record_id(path[len(prefix):], "target interpretation id")
    harness._validate_operation_payload(
        "update_interpretation", update_path(record_id), thawed, record_id
    )
    entity = thawed["interpretation"]
    if set(entity) != set(UPDATE_BODY_FIELDS) or entity["interpretation"] != interpretation:
        raise harness.SafetyError("interpretation update body is not the intended payload")


def verify_record(record: Mapping[str, Any], interpretation: str) -> str:
    """Return the record id only when it matches the intended write exactly.

    Tags are compared as a set-like API field: exactly three, each expected tag
    once, server ordering irrelevant, duplicates and extras rejected.
    """
    try:
        record_id = harness._safe_record_id(record.get("id"), "created interpretation id")
    except harness.SafetyError:
        raise harness.VerificationError("created record id is absent or unsafe") from None
    tags = record.get("tags")
    if (
        record.get("interpretation") != interpretation
        or not isinstance(tags, list)
        or len(tags) != len(TAGS)
        or not harness._tags_equal(list(TAGS), tags)
        or harness._read_only_record_status(record, COLLECTION_KEY) != STATUS
    ):
        raise harness.VerificationError("the readback record does not match the intended write")
    return record_id


# --------------------------------------------------------------------------- #
# The gated transport
# --------------------------------------------------------------------------- #


class _ItemError(harness.SafetyError):
    """One sanitized per-item failure: a closed class plus a numeric status."""

    def __init__(self, error_class: str, http_status: Any = None) -> None:
        super().__init__("a batch item failed safely; only sanitized fields are available")
        self.error_class = _pinned(ERROR_CLASSES, error_class)
        self.http_status = harness._plain_http_status(http_status)

    def __repr__(self) -> str:
        return f"_ItemError({self.error_class!r}, http_status={self.http_status!r})"

    def __str__(self) -> str:
        return "a batch item failed safely; only sanitized fields are available"


def _armable_write_path(value: Any) -> str:
    """Return the one create path or one reviewed update path, rebuilt locally.

    Anything else — a phrase endpoint, a nested segment, an unsafe id, a query
    string, a non-string — fails closed before any POST budget is granted.
    """
    validate_contract()
    if value == CREATE_PATH:
        return CREATE_PATH
    prefix = f"{CREATE_PATH}/"
    if not isinstance(value, str) or not value.startswith(prefix):
        raise harness.SafetyError("the write path is outside the reviewed endpoints")
    return update_path(value[len(prefix):])


class BatchWriteGuard:
    """Structurally cap the run at the reviewed GET budget and one POST per item.

    The POST budget is consumed *before* the delegate is called, so once a POST
    invocation begins a second POST for that item is impossible in this process
    no matter how the first one ends — timeout, reset, TLS failure, malformed
    body, 4xx, 5xx, or an exception raised inside this module's own error
    handling. In dry-run mode ``posts_allowed`` is false and there is no code
    path that can arm or dispatch a POST at all.
    """

    def __init__(
        self,
        delegate: harness.Transport,
        *,
        max_gets: int,
        max_posts: int,
        sleep: Callable[[float], None] | None = None,
    ) -> None:
        validate_contract()
        if not _plain_count(max_gets, 3 * MAX_BATCH_ITEMS) or not _plain_count(
            max_posts, MAX_BATCH_ITEMS
        ):
            raise harness.SafetyError("the request budget is outside the fixed bounds")
        self._delegate = delegate
        self._sleep = sleep if sleep is not None else time.sleep
        self.max_gets = max_gets
        self.max_posts = max_posts
        self.get_count = 0
        self.post_count = 0
        self.posted_ordinals: set[int] = set()
        self._armed_ordinal: int | None = None
        self._armed_path: str | None = None
        self._armed_ordinals: set[int] = set()
        self._post_allowance = 0
        self._dispatched = False

    @property
    def posts_allowed(self) -> bool:
        return self.max_posts > 0

    def arm(self, ordinal: int, path: str = CREATE_PATH) -> None:
        """Grant the single POST budget for exactly one item and one exact path.

        Both halves matter: the ordinal caps the item at one POST for the whole
        process, and the path pins that POST to the create endpoint or to one
        already-selected update record. A POST to any other path — including a
        different record id — is refused before it is dispatched.
        """
        if not self.posts_allowed:
            raise harness.SafetyError("this run is read-only; no POST can be armed")
        if not _plain_count(ordinal, MAX_BATCH_ITEMS) or ordinal < 1:
            raise harness.SafetyError("the armed item ordinal is outside the fixed bound")
        if ordinal in self._armed_ordinals or self.post_count >= self.max_posts:
            raise harness.SafetyError("this item was already armed or the budget is spent")
        target = _armable_write_path(path)
        self._armed_ordinals.add(ordinal)
        self._armed_ordinal = ordinal
        self._armed_path = target
        self._post_allowance = 1

    def send(
        self, request: harness.HttpRequest, credential: harness.TestAccountCredential
    ) -> harness.HttpResponse:
        validate_contract()
        if not isinstance(request, harness.HttpRequest):
            raise harness.SafetyError("this transport requires one reviewed request")
        if request.method == "GET":
            harness._documented_read_path(request.path)
            if (
                request.payload is not None
                or self.get_count >= self.max_gets
                or urlsplit(request.path).path not in READ_PATHS
            ):
                raise harness.SafetyError("GET is outside the reviewed endpoints or budget")
            self.get_count += 1
        elif request.method == "POST":
            ordinal = self._armed_ordinal
            if (
                self._armed_path is None
                or request.path != self._armed_path
                or not self.posts_allowed
                or self._post_allowance <= 0
                or ordinal is None
                or self.post_count >= self.max_posts
            ):
                raise harness.SafetyError("POST is outside the reviewed path or item budget")
            # Consume first: from here a second POST for this item is impossible.
            self._post_allowance = 0
            self.post_count += 1
            self.posted_ordinals.add(ordinal)
        else:
            raise harness.SafetyError("this importer accepts only reviewed GET and POST")
        # Conservative fixed pacing, applied only between production requests.
        if self._dispatched:
            self._sleep(PACING_SECONDS)
        self._dispatched = True
        return self._delegate.send(request, credential)


def _read(
    guard: BatchWriteGuard,
    request: harness.HttpRequest,
    credential: harness.TestAccountCredential,
) -> tuple[harness.HttpResponse, int]:
    """Dispatch one reviewed GET and classify every failure mode it can have."""
    status: int | None = None
    try:
        response = guard.send(request, credential)
        status = harness._read_only_response_status(response)
        if status is None:
            raise harness.TransportError("no usable response status")
        harness._require_read_success(response)
        return response, status
    except harness.TransportResponseError as rejected:
        status = rejected.http_status
        reason = "transport"
    except harness.SafetyError:
        reason = "safety"
    except Exception:
        reason = "transport"
    if status is not None:
        reason = "schema" if 200 <= status < 300 else "http-status"
    raise _ItemError(reason, status) from None


# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #


def _validate_baseline_text(value: Any) -> str:
    """Accept the account's own current interpretation text verbatim, or fail closed.

    This is the only server-provided free text this module ever shows or stores:
    the owner cannot judge a replacement without seeing exactly what is about to
    be overwritten. It is never rewritten or normalized — it is bounded, and any
    control character other than a newline is a hard rejection rather than a
    silent strip.
    """
    if not isinstance(value, str) or not value.strip():
        raise harness.SafetyError("the existing interpretation text is empty or unreadable")
    if len(value) > MAX_INTERPRETATION_CHARS or any(
        (ord(character) < 32 or ord(character) == 127) and character != "\n"
        for character in value
    ):
        raise harness.SafetyError("the existing interpretation text is outside the local policy")
    return value


def _baseline_tags(value: Any) -> tuple[str, ...]:
    """Return the record's tags as documented project-owned constants."""
    if not isinstance(value, list) or len(value) > MAX_RECORD_TAGS:
        raise harness.SafetyError("the existing interpretation tags are not a documented list")
    return tuple(_pinned(DOCUMENTED_TAGS, tag) for tag in value)


@dataclass(frozen=True, repr=False)
class RecordBaseline:
    """The exact pre-update state of the one authenticated-user custom record.

    It exists so the owner can see what is being replaced, so the confirmation is
    bound to that exact prior state, and so the local private report holds enough
    evidence for a MANUAL restoration. It is not a rollback engine: nothing in
    this module ever replays it.
    """

    record_id: str = field(repr=False)
    interpretation: str = field(repr=False)
    tags: tuple[str, ...] = ()
    status: str = STATUS

    def __post_init__(self) -> None:
        object.__setattr__(self, "tags", tuple(self.tags))
        self.revalidate()

    def revalidate(self) -> None:
        harness._safe_record_id(self.record_id, "target interpretation id")
        _validate_baseline_text(self.interpretation)
        object.__setattr__(self, "tags", _baseline_tags(list(self.tags)))
        object.__setattr__(self, "status", _pinned(RECORD_STATUSES, self.status))

    @property
    def record_fingerprint(self) -> str:
        return _short_fingerprint(self.record_id)

    def matches(self, interpretation: str) -> bool:
        """True when this record already equals the intended final state exactly."""
        return (
            self.interpretation == interpretation
            and len(self.tags) == len(TAGS)
            and harness._tags_equal(list(TAGS), list(self.tags))
            and self.status == STATUS
        )

    def snapshot(self) -> dict[str, Any]:
        """The id-free pre-update snapshot shown, bound and privately retained."""
        return {
            "interpretation": self.interpretation,
            "tags": list(self.tags),
            "status": self.status,
            "record_fingerprint": self.record_fingerprint,
        }

    def __repr__(self) -> str:
        return (
            f"RecordBaseline(record_fingerprint={self.record_fingerprint!r}, "
            f"tags={list(self.tags)!r}, status={self.status!r})"
        )


def read_baseline(record: Mapping[str, Any]) -> RecordBaseline:
    """Build the pre-update snapshot from one strictly validated record."""
    return RecordBaseline(
        record_id=harness._safe_record_id(record.get("id"), "target interpretation id"),
        interpretation=_validate_baseline_text(record.get("interpretation")),
        tags=_baseline_tags(record.get("tags")),
        status=harness._read_only_record_status(record, COLLECTION_KEY),
    )


@dataclass(frozen=True, repr=False)
class PreflightItem:
    """One item's whole-batch preflight verdict. The raw id never leaves."""

    ordinal: int
    spelling: str
    interpretation: str = field(repr=False)
    state: str = BLOCK_ERROR
    existing_count: int | None = None
    vocabulary_id: str | None = field(default=None, repr=False)
    returned_spelling: str | None = None
    error_class: str | None = None
    http_status: int | None = None
    baseline: RecordBaseline | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "state", _pinned(PREFLIGHT_STATES, self.state))
        if self.error_class is not None:
            object.__setattr__(
                self, "error_class", _pinned(ERROR_CLASSES, self.error_class)
            )
        if self.vocabulary_id is not None:
            harness._safe_record_id(self.vocabulary_id, "target vocabulary id")
        if (self.state == BLOCK_ERROR) != (self.error_class is not None):
            raise harness.SafetyError("only a preflight error may carry an error class")
        if self.state == READY_CREATE and (
            self.existing_count != 0 or self.vocabulary_id is None
        ):
            raise harness.SafetyError("a ready item requires a resolved zero baseline")
        if self.state == BLOCK_MISSING and self.existing_count != 0:
            raise harness.SafetyError("a missing-record item requires a zero baseline")
        if (self.baseline is not None) != self.settled:
            raise harness.SafetyError("only a settled update item may carry a baseline")
        if self.settled:
            if self.existing_count != 1 or self.vocabulary_id is None:
                raise harness.SafetyError(
                    "an update verdict requires exactly one resolved existing record"
                )
            self.baseline.revalidate()
            if self.baseline.matches(self.interpretation) != self.no_op:
                raise harness.SafetyError(
                    "the update verdict contradicts the pre-update snapshot"
                )

    @property
    def ready(self) -> bool:
        return self.state == READY_CREATE

    @property
    def update_ready(self) -> bool:
        return self.state == READY_UPDATE

    @property
    def no_op(self) -> bool:
        return self.state == ALREADY_MATCHING

    @property
    def settled(self) -> bool:
        """True when update mode may proceed with this item: change it, or skip it."""
        return self.state in (READY_UPDATE, ALREADY_MATCHING)

    @property
    def voc_id_fingerprint(self) -> str | None:
        if self.vocabulary_id is None:
            return None
        return _short_fingerprint(self.vocabulary_id)

    @property
    def record_fingerprint(self) -> str | None:
        if self.baseline is None:
            return None
        return self.baseline.record_fingerprint

    def __repr__(self) -> str:
        return (
            f"PreflightItem(ordinal={self.ordinal!r}, spelling={self.spelling!r}, "
            f"state={self.state!r}, existing_count={self.existing_count!r}, "
            f"voc_id_fingerprint={self.voc_id_fingerprint!r}, "
            f"record_fingerprint={self.record_fingerprint!r})"
        )


def preflight_item(
    guard: BatchWriteGuard,
    entry: BatchEntry,
    credential: harness.TestAccountCredential,
    *,
    mode: str = MODE_CREATE,
) -> PreflightItem:
    """GET vocabulary, GET the authenticated collection, classify. Never raises."""
    update = _pinned(MODES, mode) == MODE_UPDATE
    base = {
        "ordinal": entry.ordinal,
        "spelling": entry.spelling,
        "interpretation": entry.interpretation,
    }
    try:
        request = harness.HttpRequest(
            "GET", harness.build_query_path("vocabulary", {"spelling": entry.spelling})
        )
    except Exception:
        return PreflightItem(**base, state=BLOCK_ERROR, error_class="safety")
    try:
        response, status = _read(guard, request, credential)
    except _ItemError as failure:
        return PreflightItem(
            **base,
            state=BLOCK_ERROR,
            error_class=failure.error_class,
            http_status=failure.http_status,
        )
    try:
        vocabulary_id, returned = harness._validate_probe_vocabulary(
            harness._canonical_probe_vocabulary_body(response.body), entry.spelling
        )
        request = harness.HttpRequest(
            "GET", harness.build_query_path(COLLECTION_KEY, {"voc_id": vocabulary_id})
        )
    except Exception:
        return PreflightItem(
            **base, state=BLOCK_ERROR, error_class="schema", http_status=status
        )
    try:
        response, status = _read(guard, request, credential)
    except _ItemError as failure:
        return PreflightItem(
            **base,
            state=BLOCK_ERROR,
            error_class=failure.error_class,
            http_status=failure.http_status,
            returned_spelling=returned,
        )
    try:
        records = harness._interpretation_create_records(response)
    except Exception:
        return PreflightItem(
            **base,
            state=BLOCK_ERROR,
            error_class="schema",
            http_status=status,
            returned_spelling=returned,
        )
    # Exactly the reviewed classification, mirrored for the two write modes.
    #
    # create: 0 may be created, 1 needs update mode, more than 1 is ambiguous.
    # update: exactly 1 is the only shape that can carry an update target, 0 has
    #         nothing to replace, more than 1 is ambiguous.
    #
    # No blocked state may ever fall back to the other mode, to another record or
    # to a different word.
    baseline: RecordBaseline | None = None
    if update and len(records) == 1:
        try:
            baseline = read_baseline(records[0])
        except Exception:
            return PreflightItem(
                **base,
                state=BLOCK_ERROR,
                error_class="schema",
                http_status=status,
                returned_spelling=returned,
            )
        state = (
            ALREADY_MATCHING if baseline.matches(entry.interpretation) else READY_UPDATE
        )
    elif update:
        state = BLOCK_MISSING if len(records) == 0 else BLOCK_AMBIGUOUS
    else:
        state = (
            READY_CREATE
            if len(records) == 0
            else BLOCK_EXISTING
            if len(records) == 1
            else BLOCK_AMBIGUOUS
        )
    try:
        return PreflightItem(
            **base,
            state=state,
            existing_count=len(records),
            vocabulary_id=vocabulary_id,
            returned_spelling=returned,
            http_status=status,
            baseline=baseline,
        )
    except Exception:
        return PreflightItem(**base, state=BLOCK_ERROR, error_class="safety")


def preflight_batch(
    guard: BatchWriteGuard,
    entries: Sequence[BatchEntry],
    credential: harness.TestAccountCredential,
    *,
    mode: str = MODE_CREATE,
) -> tuple[PreflightItem, ...]:
    """Preflight the WHOLE batch, in input order, before any write is possible."""
    return tuple(
        preflight_item(guard, entry, credential, mode=mode) for entry in entries
    )


# --------------------------------------------------------------------------- #
# The immutable batch plan
# --------------------------------------------------------------------------- #


@dataclass(frozen=True, repr=False)
class PlannedItem:
    """One frozen, fully bound write item. Preview, digest and POST share it.

    A create item has no ``baseline``; an update item carries the exact
    pre-update snapshot of the single authenticated-user record it replaces, and
    that snapshot supplies the only record id this module will ever POST to.
    """

    ordinal: int
    spelling: str
    returned_spelling: str
    vocabulary_id: str = field(repr=False)
    interpretation: str = field(repr=False)
    request_body: Mapping[str, Any] = field(repr=False)
    baseline: RecordBaseline | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "request_body", harness._freeze_json(self.request_body))
        self.revalidate()

    def revalidate(self) -> None:
        validate_contract()
        harness._safe_record_id(self.vocabulary_id, "target vocabulary id")
        if not _plain_count(self.ordinal, MAX_BATCH_ITEMS) or self.ordinal < 1:
            raise harness.SafetyError("planned item ordinal is outside the fixed bound")
        normalize = harness._normalize_probe_spelling
        if normalize(self.returned_spelling) != normalize(self.spelling):
            raise harness.SafetyError("returned spelling is not the intended spelling")
        if self.baseline is None:
            validate_create_body(
                self.request_body, self.vocabulary_id, self.interpretation
            )
            return
        self.baseline.revalidate()
        # An item that already equals the intended final state is a no-op, never
        # a write target: if a mutation makes it match, the plan fails closed.
        if self.baseline.matches(self.interpretation):
            raise harness.SafetyError("an already matching item is never an update target")
        validate_update_body(self.request_body, self.write_path, self.interpretation)

    @property
    def is_update(self) -> bool:
        return self.baseline is not None

    @property
    def record_id(self) -> str | None:
        """The raw update target id. Internal only — it is never emitted."""
        return None if self.baseline is None else self.baseline.record_id

    @property
    def voc_id_fingerprint(self) -> str:
        return _short_fingerprint(self.vocabulary_id)

    @property
    def record_fingerprint(self) -> str | None:
        return None if self.baseline is None else self.baseline.record_fingerprint

    @property
    def write_path(self) -> str:
        if self.baseline is None:
            return CREATE_PATH
        return update_path(self.baseline.record_id)

    @property
    def readback_path(self) -> str:
        return harness.build_query_path(COLLECTION_KEY, {"voc_id": self.vocabulary_id})

    def write_request(self) -> harness.HttpRequest:
        """Build the single POST from the frozen plan body, never from a copy."""
        self.revalidate()
        return harness.HttpRequest(
            "POST", self.write_path, harness._thaw_json(self.request_body)
        )

    def bound_fields(self) -> dict[str, Any]:
        fields = {
            "ordinal": self.ordinal,
            "spelling": self.spelling,
            "interpretation": self.interpretation,
            "tags": list(TAGS),
            "status": STATUS,
            "voc_id_fingerprint": self.voc_id_fingerprint,
        }
        if self.baseline is not None:
            fields["pre_update"] = self.baseline.snapshot()
        return fields

    def __repr__(self) -> str:
        return (
            f"PlannedItem(ordinal={self.ordinal!r}, spelling={self.spelling!r}, "
            f"voc_id_fingerprint={self.voc_id_fingerprint!r}, "
            f"record_fingerprint={self.record_fingerprint!r})"
        )


@dataclass(frozen=True, repr=False)
class BatchPlan:
    """One frozen, fully bound batch-create plan behind ONE batch confirmation.

    Fifteen separate confirmations would be worse than useless, so the single
    confirmation digest binds *everything* that could change the outcome:
    operation, production host, write path, account label, Token fingerprint, the
    ordered batch digest, every spelling, every resolved raw ``voc_id``, every
    exact interpretation, the tags, the status, the item count and the
    pricing/terms gate. An update plan additionally binds every raw target record
    id, every exact pre-update text/tags/status snapshot, the exact intended
    update body and the no-op count. Mutating any item or any baseline afterwards
    changes the digest, so the already-entered confirmation no longer matches and
    the send boundary rejects it.
    """

    account_label: str = field(repr=False)
    credential_fingerprint: str
    items: tuple[PlannedItem, ...] = field(repr=False)
    digest: str = ""
    mode: str = MODE_CREATE
    no_op_count: int = 0
    account_mode: str = ACCOUNT_SECONDARY

    def __post_init__(self) -> None:
        object.__setattr__(self, "items", tuple(self.items))
        object.__setattr__(self, "mode", _pinned(MODES, self.mode))
        object.__setattr__(self, "account_mode", _pinned(ACCOUNT_MODES, self.account_mode))
        self.revalidate()

    def revalidate(self) -> None:
        validate_contract()
        validate_account_label(self.account_label, account_mode=self.account_mode)
        if (
            self.mode not in (MODE_CREATE, MODE_UPDATE)
            or not _valid_fingerprint(self.credential_fingerprint)
            or not self.items
            or not _plain_count(len(self.items), MAX_BATCH_ITEMS)
            or not _plain_count(self.no_op_count, MAX_BATCH_ITEMS)
            or not _plain_count(len(self.items) + self.no_op_count, MAX_BATCH_ITEMS)
            or not re.fullmatch(r"[0-9a-f]{64}", self.digest or "")
        ):
            raise harness.SafetyError("the batch plan violates the fixed write policy")
        if any(item.is_update != self.is_update for item in self.items):
            raise harness.SafetyError("the batch plan mixes create and update items")
        if self.is_update:
            record_ids = [item.record_id for item in self.items]
            if len(set(record_ids)) != len(record_ids):
                raise harness.SafetyError("the batch plan targets one record twice")
        elif self.no_op_count:
            raise harness.SafetyError("a create plan can never carry a no-op count")
        ordinals = [item.ordinal for item in self.items]
        # A create plan covers the whole batch, so its ordinals are 1..n. An
        # update plan skips the already-matching items, so its ordinals are the
        # original batch ordinals in strictly increasing input order.
        expected = (
            sorted(set(ordinals)) if self.is_update else list(range(1, len(ordinals) + 1))
        )
        if ordinals != expected:
            raise harness.SafetyError("the batch plan is not in original input order")
        spellings = [item.spelling for item in self.items]
        if len(set(spellings)) != len(spellings):
            raise harness.SafetyError("the batch plan contains a duplicate spelling")
        for item in self.items:
            item.revalidate()

    @property
    def is_update(self) -> bool:
        return self.mode == MODE_UPDATE

    @property
    def is_main(self) -> bool:
        return self.account_mode == ACCOUNT_MAIN

    @property
    def item_count(self) -> int:
        return len(self.items)

    def bound_fields(self) -> dict[str, Any]:
        """The shared, id-free description behind preview, digest and report."""
        fields = {
            "operation": OPERATION_UPDATE if self.is_update else OPERATION,
            "mode": self.mode,
            "host": harness.PRODUCTION_BASE_URL,
            "method": "POST",
            "path": UPDATE_PATH_TEMPLATE if self.is_update else CREATE_PATH,
            "tags": list(TAGS),
            "status": STATUS,
            "item_count": self.item_count,
            "batch_digest": self.digest,
            "credential_fingerprint": self.credential_fingerprint,
            "items": [item.bound_fields() for item in self.items],
        }
        if self.is_update:
            fields["no_op_count"] = self.no_op_count
        return fields

    def confirmation_binding(self) -> dict[str, Any]:
        # The raw ids and the account label are bound here but never emitted.
        binding = dict(
            self.bound_fields(),
            account_label=self.account_label,
            vocabulary_ids=[item.vocabulary_id for item in self.items],
            request_bodies=[harness._thaw_json(item.request_body) for item in self.items],
            write_policy=WRITE_POLICY,
            pricing_and_terms_checked=True,
        )
        if self.is_update:
            binding["record_ids"] = [item.record_id for item in self.items]
            binding["write_paths"] = [item.write_path for item in self.items]
        if self.is_main:
            # The smallest distinct binding this needs: everything the secondary
            # confirmation bound is still bound, and a main-account run adds the
            # account mode itself. A secondary binding therefore cannot produce a
            # main digest and a main binding cannot produce a secondary one, even
            # if every other bound field somehow agreed. The secondary binding is
            # untouched, so its already live-validated digests stay identical.
            binding["account_mode"] = ACCOUNT_MAIN
        return binding

    @property
    def binding_digest(self) -> str:
        """The 16 hex characters that stand for the WHOLE confirmation binding.

        Both modes have always shown exactly this value. It is the only part of
        either confirmation string that can change when anything bound changes,
        which is why the UPDATE form can shrink to just this token without
        unbinding a single field.
        """
        self.revalidate()
        return _digest(self.confirmation_binding())[:BINDING_DIGEST_CHARS]

    @property
    def expected_confirmation(self) -> str:
        digest = self.binding_digest
        if self.is_main:
            # One short, unmistakably main-account token per operation. It is the
            # same construction the reviewed UPDATE form uses — the digest still
            # covers the WHOLE binding — and the surrounding block keeps every
            # human-readable field visible.
            prefix = (
                MAIN_UPDATE_CONFIRMATION_PREFIX
                if self.is_update
                else MAIN_CREATE_CONFIRMATION_PREFIX
            )
            return f"{prefix} {digest}"
        if self.is_update:
            # One short token. The counts, Token fingerprint, pricing clause and
            # write policy stay visible in `confirmation_lines`, and remain bound
            # by this digest exactly as before — see Issue #42.
            return f"{UPDATE_CONFIRMATION_PREFIX} {digest}"
        # Frozen: this exact CREATE string has already been validated live.
        return (
            f"{CONFIRMATION_PREFIX}: {digest} ITEMS: {self.item_count} "
            f"TOKEN-FP: {self.credential_fingerprint} "
            f"{harness.WRITE_PRICING_TERMS_CLAUSE} {BATCH_ONE_POST_CLAUSE}"
        )

    def validate(self, credential: harness.TestAccountCredential) -> None:
        """Rebind the plan to the exact manual gate for ITS account mode."""
        self.revalidate()
        _account_gate(
            self.account_label,
            self.credential_fingerprint,
            account_mode=self.account_mode,
        ).validate(credential)
        for item in self.items:
            baseline = item.baseline
            if credential.token in (
                item.spelling,
                item.interpretation,
                item.vocabulary_id,
                item.returned_spelling,
            ) or harness._contains_credential_material(
                harness._thaw_json(item.request_body), credential.token
            ):
                raise harness.SafetyError("the batch plan contains forbidden credential material")
            if baseline is not None and credential.token in (
                baseline.record_id,
                baseline.interpretation,
                *baseline.tags,
            ):
                raise harness.SafetyError("the batch plan contains forbidden credential material")

    def validate_confirmation(self, provided: Any) -> None:
        if not isinstance(provided, str) or provided != self.expected_confirmation:
            raise harness.ConfirmationError("batch write confirmation does not match exactly")

    def __repr__(self) -> str:
        return (
            f"BatchPlan(mode={self.mode!r}, account_mode={self.account_mode!r}, "
            f"item_count={self.item_count!r}, "
            f"no_op_count={self.no_op_count!r}, digest={self.digest!r}, "
            f"credential_fingerprint={self.credential_fingerprint!r})"
        )


def build_plan(
    *,
    account_label: str,
    credential_fingerprint: str,
    entries: Sequence[BatchEntry],
    preflight: Sequence[PreflightItem],
    account_mode: str = ACCOUNT_SECONDARY,
) -> BatchPlan:
    """Build the frozen plan. Every item must already be READY_CREATE."""
    if len(entries) != len(preflight) or not entries:
        raise harness.SafetyError("the batch plan requires one preflight verdict per entry")
    items: list[PlannedItem] = []
    for entry, verdict in zip(entries, preflight):
        if (
            not verdict.ready
            or verdict.ordinal != entry.ordinal
            or verdict.spelling != entry.spelling
            or verdict.interpretation != entry.interpretation
            or verdict.vocabulary_id is None
            or verdict.returned_spelling is None
        ):
            raise harness.SafetyError("only a fully ready batch may become a write plan")
        items.append(
            PlannedItem(
                ordinal=entry.ordinal,
                spelling=entry.spelling,
                returned_spelling=verdict.returned_spelling,
                vocabulary_id=verdict.vocabulary_id,
                interpretation=entry.interpretation,
                request_body=create_body(verdict.vocabulary_id, entry.interpretation),
            )
        )
    return BatchPlan(
        account_label=account_label,
        credential_fingerprint=credential_fingerprint,
        items=tuple(items),
        digest=batch_digest(entries),
        mode=MODE_CREATE,
        account_mode=account_mode,
    )


def build_update_plan(
    *,
    account_label: str,
    credential_fingerprint: str,
    entries: Sequence[BatchEntry],
    preflight: Sequence[PreflightItem],
    account_mode: str = ACCOUNT_SECONDARY,
) -> BatchPlan:
    """Build the frozen update plan from the READY_UPDATE items only.

    Every item must already be settled: an ALREADY_MATCHING item is skipped as a
    satisfied no-op, and anything blocked is a programming error here because the
    whole batch aborts before this point.
    """
    if len(entries) != len(preflight) or not entries:
        raise harness.SafetyError("the batch plan requires one preflight verdict per entry")
    items: list[PlannedItem] = []
    no_op_count = 0
    for entry, verdict in zip(entries, preflight):
        if (
            verdict.ordinal != entry.ordinal
            or verdict.spelling != entry.spelling
            or verdict.interpretation != entry.interpretation
            or not verdict.settled
        ):
            raise harness.SafetyError("only a fully settled batch may become an update plan")
        if verdict.no_op:
            no_op_count += 1
            continue
        if (
            verdict.vocabulary_id is None
            or verdict.returned_spelling is None
            or verdict.baseline is None
        ):
            raise harness.SafetyError("an update target requires one resolved existing record")
        items.append(
            PlannedItem(
                ordinal=entry.ordinal,
                spelling=entry.spelling,
                returned_spelling=verdict.returned_spelling,
                vocabulary_id=verdict.vocabulary_id,
                interpretation=entry.interpretation,
                request_body=update_body(entry.interpretation),
                baseline=verdict.baseline,
            )
        )
    if not items:
        raise harness.SafetyError("an update plan requires at least one changed item")
    return BatchPlan(
        account_label=account_label,
        credential_fingerprint=credential_fingerprint,
        items=tuple(items),
        digest=batch_digest(entries, mode=MODE_UPDATE),
        mode=MODE_UPDATE,
        no_op_count=no_op_count,
        account_mode=account_mode,
    )


# --------------------------------------------------------------------------- #
# The write phase
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class ItemOutcome:
    """One item's sanitized write outcome. Only closed fields ever leave."""

    ordinal: int
    spelling: str
    post_attempted: bool = False
    readback_attempted: bool = False
    outcome: str = NOT_ATTEMPTED
    failure_class: str | None = None
    post_http_status: int | None = None
    readback_http_status: int | None = None
    record_fingerprint: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "outcome", _pinned(OUTCOMES, self.outcome))
        if self.failure_class is not None:
            object.__setattr__(
                self, "failure_class", _pinned(ERROR_CLASSES, self.failure_class)
            )
        if (self.outcome == NOT_ATTEMPTED) != (not self.post_attempted):
            raise harness.SafetyError("the outcome contradicts whether a POST was attempted")
        if self.verified and (
            self.failure_class is not None
            or not self.readback_attempted
            or not _valid_fingerprint(self.record_fingerprint)
        ):
            raise harness.SafetyError("a verified item requires a clean readback fingerprint")
        if self.record_fingerprint is not None and not _valid_fingerprint(
            self.record_fingerprint
        ):
            raise harness.SafetyError("the record fingerprint is not a project fingerprint")

    @property
    def verified(self) -> bool:
        return self.outcome in (CONFIRMED, RECOVERED)


def _single_post(
    guard: BatchWriteGuard,
    request: harness.HttpRequest,
    credential: harness.TestAccountCredential,
) -> tuple[int | None, bool]:
    """Invoke the POST exactly once and classify its outcome.

    No exception path here — or anywhere downstream — can send a second POST for
    this item: the guard consumed the single per-item budget before delegating.
    """
    try:
        response = guard.send(request, credential)
    except harness.TransportResponseError as rejected:
        return rejected.http_status, True
    except Exception:
        return None, True
    status = harness._read_only_response_status(response)
    if status is None:
        return None, True
    return status, not 200 <= status < 300


def write_item(
    guard: BatchWriteGuard,
    item: PlannedItem,
    credential: harness.TestAccountCredential,
    provided_confirmation: str,
    plan: BatchPlan,
) -> ItemOutcome:
    """Write one item: at most one POST, then exactly one GET-only readback."""
    base = {"ordinal": item.ordinal, "spelling": item.spelling}
    try:
        plan.revalidate()
        if plan.expected_confirmation != provided_confirmation:
            raise harness.ConfirmationError("the confirmation changed before the send boundary")
        if not any(item is planned for planned in plan.items):
            raise harness.SafetyError("this item is not part of the confirmed plan")
        guard.arm(item.ordinal, item.write_path)
        request = item.write_request()
        if harness._contains_credential_material(
            harness._thaw_json(request.payload), credential.token
        ):
            raise harness.SafetyError("the request contains forbidden credential material")
    except Exception:
        return ItemOutcome(**base, outcome=NOT_ATTEMPTED, failure_class="safety")

    post_status, uncertain = _single_post(guard, request, credential)
    if item.ordinal not in guard.posted_ordinals:
        # The guard refused to dispatch, so nothing was written and there is
        # nothing to recover: no readback is performed for this item.
        return ItemOutcome(**base, outcome=NOT_ATTEMPTED, failure_class="safety")

    # Exactly one GET-only readback/recovery. This is never a write retry, and it
    # runs identically for a clean 2xx and for an uncertain POST outcome.
    try:
        readback = harness.HttpRequest("GET", item.readback_path)
    except Exception:
        return ItemOutcome(
            **base,
            post_attempted=True,
            outcome=NOT_VERIFIED,
            failure_class="safety",
            post_http_status=post_status,
        )
    partial = dict(
        base, post_attempted=True, readback_attempted=True, post_http_status=post_status
    )
    try:
        response, read_status = _read(guard, readback, credential)
    except _ItemError as failure:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class=failure.error_class,
            readback_http_status=failure.http_status,
        )
    try:
        records = harness._interpretation_create_records(response)
    except Exception:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="schema",
            readback_http_status=read_status,
        )
    if not records:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="unknown-write-outcome",
            readback_http_status=read_status,
        )
    if len(records) > 1:
        return ItemOutcome(
            **partial,
            outcome=AMBIGUOUS,
            failure_class="ambiguous",
            readback_http_status=read_status,
        )
    try:
        record_id = verify_record(records[0], item.interpretation)
        # An update must land on the record this run selected during preflight.
        # A different id — even one carrying the exact intended content — is a
        # closed failure, never a success and never a reason to POST again.
        if item.is_update and record_id != item.record_id:
            raise harness.VerificationError("the readback record is not the update target")
    except Exception:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="mismatch",
            readback_http_status=read_status,
        )
    try:
        return ItemOutcome(
            **partial,
            outcome=RECOVERED if uncertain else CONFIRMED,
            readback_http_status=read_status,
            record_fingerprint=_short_fingerprint(record_id),
        )
    except Exception:
        return ItemOutcome(
            **partial,
            outcome=NOT_VERIFIED,
            failure_class="safety",
            readback_http_status=read_status,
        )


def write_batch(
    guard: BatchWriteGuard,
    plan: BatchPlan,
    credential: harness.TestAccountCredential,
    provided_confirmation: str,
) -> tuple[ItemOutcome, ...]:
    """Process items sequentially in the original input order, stopping on failure.

    A runtime failure after earlier items were already verified stops the whole
    remaining batch immediately. Nothing is rolled back, nothing is deleted and
    no later item is attempted; the remaining items are reported as
    ``not-attempted``.
    """
    outcomes: list[ItemOutcome] = []
    stopped = False
    for item in plan.items:
        if stopped:
            outcomes.append(ItemOutcome(ordinal=item.ordinal, spelling=item.spelling))
            continue
        outcome = write_item(guard, item, credential, provided_confirmation, plan)
        outcomes.append(outcome)
        if not outcome.verified:
            stopped = True
    return tuple(outcomes)


# --------------------------------------------------------------------------- #
# The run
# --------------------------------------------------------------------------- #


@dataclass(frozen=True, repr=False)
class BatchResult:
    """The whole sanitized run outcome. No raw id or credential is reachable."""

    mode: str
    status: str
    digest: str
    preflight: tuple[PreflightItem, ...] = field(repr=False)
    outcomes: tuple[ItemOutcome, ...] = field(repr=False)
    get_count: int = 0
    post_count: int = 0
    report_path: Path | None = field(default=None, repr=False)
    account_mode: str = ACCOUNT_SECONDARY

    def __post_init__(self) -> None:
        object.__setattr__(self, "mode", _pinned(MODES, self.mode))
        object.__setattr__(self, "status", _pinned(RUN_STATUSES, self.status))
        object.__setattr__(self, "account_mode", _pinned(ACCOUNT_MODES, self.account_mode))
        if self.mode == MODE_DRY_RUN and (self.post_count or self.outcomes):
            raise harness.SafetyError("a dry-run can never carry a write outcome")

    @property
    def item_count(self) -> int:
        return len(self.preflight)

    @property
    def ready_count(self) -> int:
        """The items this mode may proceed with — a no-op counts as satisfied."""
        if self.mode == MODE_UPDATE:
            return sum(1 for item in self.preflight if item.settled)
        return sum(1 for item in self.preflight if item.ready)

    @property
    def update_count(self) -> int:
        return sum(1 for item in self.preflight if item.update_ready)

    @property
    def no_op_count(self) -> int:
        return sum(1 for item in self.preflight if item.no_op)

    @property
    def blocked_count(self) -> int:
        return self.item_count - self.ready_count

    @property
    def verified_count(self) -> int:
        return sum(1 for item in self.outcomes if item.verified)

    @property
    def not_attempted_count(self) -> int:
        return sum(1 for item in self.outcomes if not item.post_attempted)

    @property
    def stopped_on(self) -> ItemOutcome | None:
        """The first item that failed. Later items are merely not attempted."""
        return next(
            (
                item
                for item in self.outcomes
                if not item.verified
                and (item.post_attempted or item.failure_class is not None)
            ),
            None,
        )

    @property
    def remaining_not_attempted(self) -> int:
        """How many attempted-batch items were left untouched after the stop."""
        for index, item in enumerate(self.outcomes):
            if not item.verified and (
                item.post_attempted or item.failure_class is not None
            ):
                return len(self.outcomes) - index - 1
        return 0

    def __repr__(self) -> str:
        return (
            f"BatchResult(mode={self.mode!r}, account_mode={self.account_mode!r}, "
            f"status={self.status!r}, "
            f"items={self.item_count!r}, ready={self.ready_count!r}, "
            f"verified={self.verified_count!r}, posts={self.post_count!r})"
        )


def run_batch(
    *,
    mode: str,
    entries: Sequence[BatchEntry],
    transport: harness.Transport,
    credential: harness.TestAccountCredential,
    account_label: str,
    confirm: Callable[[BatchPlan], str] | None = None,
    emit: Callable[[str], None] | None = None,
    sleep: Callable[[float], None] | None = None,
    report: "BatchRunReport | None" = None,
    now: Callable[[], datetime] | None = None,
    account_mode: str = ACCOUNT_SECONDARY,
) -> BatchResult:
    """Run one dry-run, create or update batch. All preflight the WHOLE batch first.

    ``account_mode`` defaults to the frozen secondary/test path. Main-account mode
    is the explicit Issue #51 opt-in: the label family, the gate, the credential
    source and the confirmation string all change together, and nothing about the
    write machinery — whole-batch preflight, one POST per changed item, no retry,
    immediate authenticated readback, stop-on-failure, no rollback — changes at all.
    """
    validate_contract()
    chosen = _pinned(MODES, mode)
    account = _pinned(ACCOUNT_MODES, account_mode)
    if not entries or len(entries) > MAX_BATCH_ITEMS:
        raise harness.SafetyError("the batch size is outside the fixed bounds")
    label = validate_account_label(account_label, account_mode=account)
    _account_gate(label, credential.fingerprint, account_mode=account).validate(credential)
    write = emit if emit is not None else _print_line
    writes = chosen in (MODE_CREATE, MODE_UPDATE)
    digest = batch_digest(entries, mode=chosen)
    guard = BatchWriteGuard(
        transport,
        max_gets=(3 if writes else 2) * len(entries),
        max_posts=len(entries) if writes else 0,
        sleep=sleep,
    )

    if account == ACCOUNT_MAIN:
        for line in main_account_warning_lines(chosen):
            write(line)
    preflight = preflight_batch(guard, entries, credential, mode=chosen)
    for line in preview_lines(
        chosen, digest, credential.fingerprint, preflight, account_mode=account
    ):
        write(line)

    outcomes: tuple[ItemOutcome, ...] = ()
    acceptable = (
        (lambda item: item.settled) if chosen == MODE_UPDATE else (lambda item: item.ready)
    )
    if chosen == MODE_DRY_RUN or not all(acceptable(item) for item in preflight):
        status = "ready" if all(item.ready for item in preflight) else "blocked"
        if writes:
            status = "blocked"
            write(
                "ABORTED BEFORE THE FIRST POST: the whole batch is blocked because at "
                f"least one item is not ready to {chosen}."
            )
        return _finish(
            mode=chosen,
            account_mode=account,
            status=status,
            digest=digest,
            preflight=preflight,
            outcomes=outcomes,
            guard=guard,
            emit=write,
            report=report,
            now=now,
        )

    if chosen == MODE_UPDATE and not any(item.update_ready for item in preflight):
        # Every item already equals the intended final state. This is a satisfied
        # no-op: no confirmation is asked for and no request is sent.
        write(
            "NOTHING TO UPDATE: every item already matches the intended "
            "interpretation, tags and status exactly."
        )
        return _finish(
            mode=chosen,
            account_mode=account,
            status="satisfied",
            digest=digest,
            preflight=preflight,
            outcomes=outcomes,
            guard=guard,
            emit=write,
            report=report,
            now=now,
        )

    builder = build_update_plan if chosen == MODE_UPDATE else build_plan
    plan = builder(
        account_label=label,
        credential_fingerprint=credential.fingerprint,
        entries=entries,
        preflight=preflight,
        account_mode=account,
    )
    plan.validate(credential)
    for line in confirmation_lines(plan):
        write(line)
    try:
        provided = confirm(plan) if confirm is not None else ""
        plan.validate_confirmation(provided)
    except Exception:
        write(
            "ABORTED BEFORE THE FIRST POST: the batch confirmation did not match "
            "this run's exact string."
        )
        return _finish(
            mode=chosen,
            account_mode=account,
            status="blocked",
            digest=digest,
            preflight=preflight,
            outcomes=outcomes,
            guard=guard,
            emit=write,
            report=report,
            now=now,
        )

    outcomes = write_batch(guard, plan, credential, provided)
    status = "verified" if all(item.verified for item in outcomes) else "stopped"
    return _finish(
        mode=chosen,
        account_mode=account,
        status=status,
        digest=digest,
        preflight=preflight,
        outcomes=outcomes,
        guard=guard,
        emit=write,
        report=report,
        now=now,
    )


def _finish(
    *,
    mode: str,
    status: str,
    digest: str,
    preflight: tuple[PreflightItem, ...],
    outcomes: tuple[ItemOutcome, ...],
    guard: BatchWriteGuard,
    emit: Callable[[str], None],
    report: "BatchRunReport | None",
    now: Callable[[], datetime] | None,
    account_mode: str = ACCOUNT_SECONDARY,
) -> BatchResult:
    result = BatchResult(
        mode=mode,
        status=status,
        digest=digest,
        preflight=preflight,
        outcomes=outcomes,
        get_count=guard.get_count,
        post_count=guard.post_count,
        account_mode=account_mode,
    )
    path: Path | None = None
    if report is not None:
        try:
            path = report.write(report_document(result, now=now))
        except Exception:
            # A report failure never changes what happened on the server and never
            # authorizes another POST; it is reported and the run still returns.
            emit("NOTE: the local sanitized run report could not be written.")
    for line in result_lines(result, path):
        emit(line)
    return BatchResult(
        mode=result.mode,
        status=result.status,
        digest=result.digest,
        preflight=result.preflight,
        outcomes=result.outcomes,
        get_count=result.get_count,
        post_count=result.post_count,
        report_path=path,
        account_mode=result.account_mode,
    )


# --------------------------------------------------------------------------- #
# Owner-readable output
# --------------------------------------------------------------------------- #


def _print_line(line: str) -> None:
    print(line)


def _indented(text: str, prefix: str = "      ") -> list[str]:
    """Render the owner's interpretation for the terminal, preserving its breaks."""
    return [f"{prefix}{line}" for line in text.split("\n")]


_STATE_LABELS: Mapping[str, str] = {
    READY_CREATE: "READY_CREATE",
    READY_UPDATE: "READY_UPDATE",
    ALREADY_MATCHING: "ALREADY_MATCHING",
    BLOCK_EXISTING: "BLOCK_EXISTING",
    BLOCK_MISSING: "BLOCK_MISSING",
    BLOCK_AMBIGUOUS: "BLOCK_AMBIGUOUS",
    BLOCK_ERROR: "BLOCK_ERROR",
}


def _update_item_lines(item: PreflightItem) -> list[str]:
    """The old/new block for one update item. Neither text is ever rewritten."""
    baseline = item.baseline
    if baseline is None:
        return _indented(item.interpretation)
    if item.no_op:
        lines = ["      CURRENT = PROPOSED (no change, no request will be sent):"]
        lines.extend(_indented(baseline.interpretation, "        "))
        lines.append(f"      tags {' '.join(baseline.tags)}   status {baseline.status}")
        return lines
    lines = ["      CURRENT (this exact text will be replaced):"]
    lines.extend(_indented(baseline.interpretation, "        "))
    lines.append(
        f"      current tags {' '.join(baseline.tags) or '(none)'}"
        f"   current status {baseline.status}"
    )
    lines.append("      PROPOSED:")
    lines.extend(_indented(item.interpretation, "        "))
    lines.append(f"      proposed tags {' '.join(TAGS)}   proposed status {STATUS}")
    return lines


MAIN_ACCOUNT_BANNER = "=" * 72


def main_account_warning_lines(mode: str) -> list[str]:
    """The unmistakable main-account banner, shown before the whole-batch preflight.

    It states the four things the operator has to know before a Token is used
    against their real account: this is main-account mode; this tool cannot prove
    which account the Token belongs to; the Token must have been obtained while
    logged into the intended account; and create/update change real data.
    """
    chosen = _pinned(MODES, mode)
    lines = [
        MAIN_ACCOUNT_BANNER,
        "MAIN ACCOUNT MODE IS ACTIVE — this run targets the owner's REAL main "
        "Maimemo account.",
        "The current Open API gives this importer NO reliable account-identity "
        "check: it cannot",
        "prove which account a Token belongs to. That check is the operator's "
        "responsibility.",
        "Obtain the Token while logged into the intended main account, and nowhere "
        "else.",
    ]
    if chosen == MODE_DRY_RUN:
        lines.append(
            "This mode is dry-run: it reads only and sends 0 POST. create and "
            "update change real account data."
        )
    else:
        lines.append(
            f"This mode is {chosen}: it CHANGES REAL ACCOUNT DATA. There is no "
            "rollback and no delete path."
        )
    lines.extend([MAIN_ACCOUNT_BANNER, ""])
    return lines


def main_account_token_notice_lines() -> list[str]:
    """The short notice printed immediately before the distinct hidden prompt."""
    return [
        "MAIN ACCOUNT MODE — the next hidden prompt expects the Token of the "
        "owner's MAIN Maimemo account.",
        "Obtain it while logged into that exact account. This importer cannot "
        "verify a Token's owner, and never prints it.",
    ]


def preview_lines(
    mode: str,
    digest: str,
    credential_fingerprint: str,
    preflight: Sequence[PreflightItem],
    *,
    account_mode: str = ACCOUNT_SECONDARY,
) -> list[str]:
    """The complete owner-readable batch preview. No raw voc_id or record id, ever."""
    chosen = _pinned(MODES, mode)
    account = _pinned(ACCOUNT_MODES, account_mode)
    update = chosen == MODE_UPDATE
    ready = sum(1 for item in preflight if item.ready)
    account_line = (
        "account [REDACTED] (MAIN ACCOUNT — reviewed main-account label accepted)   "
        if account == ACCOUNT_MAIN
        else "account [REDACTED] (secondary/test label accepted)   "
    )
    lines = [
        f"BATCH INTERPRETATION IMPORTER — mode {chosen}",
        "host "
        f"{harness.PRODUCTION_BASE_URL}   path "
        f"{UPDATE_PATH_TEMPLATE if update else CREATE_PATH}",
        f"{account_line}"
        f"token fp {credential_fingerprint}",
        f"tags {' '.join(TAGS)}   status {STATUS}   items {len(preflight)}"
        f" (typical {TYPICAL_BATCH_ITEMS[0]}–{TYPICAL_BATCH_ITEMS[1]}, max {MAX_BATCH_ITEMS})",
        f"batch digest {digest}",
        f"write policy {WRITE_POLICY}",
        "",
    ]
    for item in preflight:
        detail = _STATE_LABELS[item.state]
        if item.state == BLOCK_ERROR:
            detail = f"{detail} ({item.error_class}"
            detail += f", http {item.http_status})" if item.http_status else ")"
        elif item.state == BLOCK_MISSING:
            detail = f"{detail} (no custom interpretation to replace)"
        elif item.existing_count and not item.settled:
            detail = f"{detail} (existing custom interpretations: {item.existing_count})"
        lines.append(f"{item.ordinal:>3}  {item.spelling}  —  {detail}")
        if update:
            lines.extend(_update_item_lines(item))
        else:
            lines.extend(_indented(item.interpretation))
        fingerprints = []
        if item.voc_id_fingerprint is not None:
            fingerprints.append(f"voc fp {item.voc_id_fingerprint}")
        if item.record_fingerprint is not None:
            fingerprints.append(f"record fp {item.record_fingerprint}")
        if fingerprints:
            lines.append(f"      {'   '.join(fingerprints)}")
        lines.append("")
    if update:
        lines.append(f"READY_UPDATE {sum(1 for item in preflight if item.update_ready)}")
        lines.append(f"ALREADY_MATCHING {sum(1 for item in preflight if item.no_op)}")
        lines.append(f"BLOCKED {sum(1 for item in preflight if not item.settled)}")
        return lines
    lines.append(f"READY {ready}")
    lines.append(f"BLOCKED {len(preflight) - ready}")
    if chosen == MODE_DRY_RUN:
        lines.append("WRITES 0")
    return lines


def _main_confirmation_lines(plan: BatchPlan) -> list[str]:
    """The main-account confirmation block. Same bound fields, different gate.

    Everything the short main token does not spell out stays readable here and
    stays bound by that token's digest, exactly as the reviewed UPDATE form does.
    """
    confirmation = plan.expected_confirmation
    counts = (
        f"UPDATES: {plan.item_count}   NO-OP: {plan.no_op_count}   "
        if plan.is_update
        else f"ITEMS: {plan.item_count}   "
    )
    replaced = (
        f"{plan.item_count} existing custom interpretations replaced"
        if plan.is_update
        else f"{plan.item_count} items created"
    )
    return [
        MAIN_ACCOUNT_BANNER,
        f"MAIN ACCOUNT {'UPDATE' if plan.is_update else 'CREATE'} CONFIRMATION — "
        f"{replaced}, one POST each, no retry",
        "THIS WRITES TO THE OWNER'S REAL MAIN MAIMEMO ACCOUNT. No rollback, no delete.",
        f"batch digest {plan.digest}",
        f"{counts}TOKEN-FP: {plan.credential_fingerprint}",
        f"{harness.WRITE_PRICING_TERMS_CLAUSE}   {BATCH_ONE_POST_CLAUSE}",
        f"MANUAL GATE: {MAIN_PRICING_TERMS_GATE}",
        "A confirmation from a secondary/test run can never authorize this run.",
        "Copy the next line exactly into the hidden prompt "
        f"({len(confirmation)} characters, nothing before or after):",
        confirmation,
        MAIN_ACCOUNT_BANNER,
        "",
    ]


def confirmation_lines(plan: BatchPlan) -> list[str]:
    """The ONE batch-level confirmation block shown before any write.

    The confirmation is printed on its own line with no indentation, quoting or
    decoration, because `validate_confirmation` demands exact equality: whatever
    is displayed must be directly pasteable without the owner editing it.
    """
    confirmation = plan.expected_confirmation
    if plan.is_main:
        return _main_confirmation_lines(plan)
    if plan.is_update:
        # Everything the short UPDATE token no longer spells out stays readable
        # here. It is all still bound by the token's digest.
        return [
            f"UPDATE CONFIRMATION — {plan.item_count} existing custom "
            f"interpretations replaced, one POST each, no retry "
            f"({plan.no_op_count} already matching, no request)",
            f"batch digest {plan.digest}",
            f"UPDATES: {plan.item_count}   NO-OP: {plan.no_op_count}   "
            f"TOKEN-FP: {plan.credential_fingerprint}",
            f"{harness.WRITE_PRICING_TERMS_CLAUSE}   {BATCH_ONE_POST_CLAUSE}",
            f"MANUAL GATE: {PRICING_TERMS_GATE}",
            "Copy the next line exactly into the hidden prompt "
            f"({len(confirmation)} characters, nothing before or after):",
            confirmation,
            "",
        ]
    return [
        f"CREATE CONFIRMATION — {plan.item_count} items, one POST each, no retry",
        f"batch digest {plan.digest}",
        f"MANUAL GATE: {PRICING_TERMS_GATE}",
        "Copy the next line exactly into the hidden prompt:",
        confirmation,
        "",
    ]


def result_lines(result: BatchResult, report_path: Path | None = None) -> list[str]:
    """The short, obvious owner-facing verdict."""
    lines: list[str] = []
    if result.mode == MODE_DRY_RUN:
        pass
    elif result.status not in ("verified", "stopped"):
        if result.mode == MODE_UPDATE and result.status == "satisfied":
            lines.append(f"ALREADY MATCHING {result.no_op_count}/{result.item_count}")
        lines.append("WRITES 0")
    else:
        attempted = result.update_count if result.mode == MODE_UPDATE else result.item_count
        verb = "UPDATED" if result.mode == MODE_UPDATE else "VERIFIED"
        lines.append(f"{verb} {result.verified_count}/{attempted}")
        if result.mode == MODE_UPDATE:
            lines.append(f"ALREADY MATCHING {result.no_op_count} (no request sent)")
        stopped = result.stopped_on
        if stopped is not None:
            lines.append(f"STOPPED ON {stopped.ordinal}: {stopped.spelling}")
            lines.append(
                f"  outcome {stopped.outcome}"
                + (f" / {stopped.failure_class}" if stopped.failure_class else "")
            )
            lines.append(f"REMAINING NOT ATTEMPTED {result.remaining_not_attempted}")
            rerun = (
                "will preflight the finished items as ALREADY_MATCHING"
                if result.mode == MODE_UPDATE
                else "will block the already-created items during preflight"
            )
            lines.append(
                "Nothing was rolled back or deleted. Do not re-POST any item; a rerun "
                f"{rerun}."
            )
    lines.append(
        f"requests: GET {result.get_count}  POST {result.post_count}  retries 0"
    )
    if report_path is not None:
        lines.append(f"local sanitized report: {report_path}")
    return lines


# --------------------------------------------------------------------------- #
# The small local sanitized run report
# --------------------------------------------------------------------------- #


def report_document(
    result: BatchResult, *, now: Callable[[], datetime] | None = None
) -> dict[str, Any]:
    """Build the small sanitized report. Fingerprints only — never a raw id.

    For an update target the report also retains the exact pre-update text, tags
    and status. That is the whole point of the file: it is the local evidence the
    owner needs to restore a replaced interpretation BY HAND. It is not a replay
    log — no code path in this module ever reads it back.
    """
    validate_contract()
    update = result.mode == MODE_UPDATE
    clock = now if now is not None else (lambda: datetime.now(timezone.utc))
    outcomes = {item.ordinal: item for item in result.outcomes}
    items: list[dict[str, Any]] = []
    for verdict in result.preflight:
        outcome = outcomes.get(verdict.ordinal)
        baseline = verdict.baseline
        items.append(
            {
                "ordinal": verdict.ordinal,
                "spelling": verdict.spelling,
                "interpretation": verdict.interpretation,
                "tags": list(TAGS),
                "status": STATUS,
                "preflight": verdict.state,
                "preflight_error_class": verdict.error_class,
                "preflight_http_status": verdict.http_status,
                "existing_count": verdict.existing_count,
                "voc_id_fingerprint": verdict.voc_id_fingerprint,
                "pre_update_interpretation": baseline.interpretation if baseline else None,
                "pre_update_tags": list(baseline.tags) if baseline else None,
                "pre_update_status": baseline.status if baseline else None,
                "post_attempted": bool(outcome and outcome.post_attempted),
                "readback_attempted": bool(outcome and outcome.readback_attempted),
                "outcome": outcome.outcome if outcome else NOT_ATTEMPTED,
                "failure_class": outcome.failure_class if outcome else None,
                "post_http_status": outcome.post_http_status if outcome else None,
                "readback_http_status": outcome.readback_http_status if outcome else None,
                "record_fingerprint": (
                    (outcome.record_fingerprint if outcome else None)
                    or (baseline.record_fingerprint if baseline else None)
                ),
            }
        )
    stopped = result.stopped_on
    document = {
        "version": REPORT_VERSION,
        "operation": OPERATION_UPDATE if update else OPERATION,
        "mode": result.mode,
        # Which account family this run targeted. It is a closed project-owned
        # enum, never the account label itself, which is still never persisted.
        "account_mode": result.account_mode,
        "status": result.status,
        "host": harness.PRODUCTION_BASE_URL,
        "path": UPDATE_PATH_TEMPLATE if update else CREATE_PATH,
        "created_at": clock().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "batch_digest": result.digest,
        "intended_tags": list(TAGS),
        "intended_status": STATUS,
        "item_count": result.item_count,
        "ready_count": result.ready_count,
        "blocked_count": result.blocked_count,
        "update_count": result.update_count if update else None,
        "no_op_count": result.no_op_count if update else None,
        "verified_count": result.verified_count,
        "not_attempted_count": (
            result.not_attempted_count if result.outcomes else result.item_count
        ),
        "stopped_on_ordinal": stopped.ordinal if stopped else None,
        "get_count": result.get_count,
        "post_count": result.post_count,
        "retries": 0,
        "rollback": "none; manual restoration only, from the pre-update snapshot",
        "items": items,
    }
    harness._assert_no_sensitive_keys(document, "batch run report")
    return document


class BatchRunReport:
    """One small ignored local report below ``artifacts/private/``.

    It is not a replay state machine and not a database: nothing in this module
    ever reads it back to decide whether to write.
    """

    def __init__(self, root: Path = harness.PRIVATE_STATE_ROOT) -> None:
        resolved = Path(root).resolve()
        private_root = harness.PRIVATE_STATE_ROOT.resolve()
        if resolved != private_root and private_root not in resolved.parents:
            raise harness.SafetyError("the run report must remain below artifacts/private")
        self.root = resolved

    def path_for(self, document: Mapping[str, Any]) -> Path:
        mode = _pinned(MODES, document.get("mode"))
        stamp = document.get("created_at")
        digest = document.get("batch_digest")
        if (
            not isinstance(stamp, str)
            or re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", stamp) is None
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise harness.SafetyError("the report name fields are outside the fixed policy")
        compact = stamp.replace("-", "").replace(":", "")
        return self.root / f"{REPORT_PREFIX}-{mode}-{compact}-{digest[:16]}.json"

    def write(self, document: Mapping[str, Any]) -> Path:
        """Write the report privately, or fail closed without partial output."""
        harness._assert_no_sensitive_keys(document, "batch run report")
        _assert_no_raw_identifiers(document)
        path = self.path_for(document)
        serialized = (
            json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
        )
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path, flags, 0o600)
        except OSError:
            raise harness.SafetyError("the run report could not be written safely") from None
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(serialized)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(path, 0o600)
        return path


_FINGERPRINT_KEYS = frozenset({"voc_id_fingerprint", "record_fingerprint"})
_RAW_ID_KEYS = frozenset({"id", "voc_id", "vocabulary_id", "record_id"})


def _assert_no_raw_identifiers(value: Any, path: str = "report") -> None:
    """Fail closed if a raw vocabulary/record id key ever reaches the report."""
    if isinstance(value, Mapping):
        for raw_key, item in value.items():
            key = str(raw_key)
            if key in _RAW_ID_KEYS:
                raise harness.SafetyError(f"{path} carries a raw identifier field")
            if key in _FINGERPRINT_KEYS and item is not None and not _valid_fingerprint(item):
                raise harness.SafetyError(f"{path} carries a non-fingerprint identifier")
            _assert_no_raw_identifiers(item, f"{path}.{key}")
    elif isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            _assert_no_raw_identifiers(item, f"{path}[{index}]")


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #


CLI_PROGRAM_NAME = "interpretation_batch_importer.py"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """One command, three modes, no subcommands, and never a Token on argv.

    There is deliberately no way to name a target interpretation record: update
    mode only ever writes to the single record the authenticated GET returned.
    """
    parser = harness.SanitizedArgumentParser(
        prog=CLI_PROGRAM_NAME,
        description=(
            "Issue #32/#39 small-batch interpretation importer. Tags, status and "
            "the update target are fixed by this project and are never accepted "
            "from the command line."
        ),
    )
    parser.add_argument("--mode", choices=MODES, default=MODE_DRY_RUN)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--account-label", required=True)
    parser.add_argument(
        "--allow-network",
        action="store_true",
        help="explicitly acknowledge that this command may create the locked transport",
    )
    parser.add_argument(
        "--allow-main-account",
        action="store_true",
        help=(
            "explicitly opt in to the owner's MAIN account, which also requires a "
            "reviewed main-account label; without it this importer stays "
            "secondary/test-account only"
        ),
    )
    return parser.parse_args(argv)


def _cli_confirm(plan: BatchPlan, prompt: Callable[[str], str]) -> str:
    if plan.is_main:
        return harness._hidden_prompt(
            prompt,
            MAIN_UPDATE_CONFIRMATION_PROMPT
            if plan.is_update
            else MAIN_CONFIRMATION_PROMPT,
        )
    return harness._hidden_prompt(
        prompt,
        UPDATE_CONFIRMATION_PROMPT if plan.is_update else CONFIRMATION_PROMPT,
    )


def main(
    argv: list[str] | None = None,
    *,
    token_prompt: Callable[[str], str] | None = None,
    confirmation_prompt: Callable[[str], str] | None = None,
    transport_factory: Callable[[], harness.Transport] | None = None,
    stdin_isatty: Callable[[], bool] | None = None,
    report_factory: Callable[[], BatchRunReport] | None = None,
    sleep: Callable[[float], None] | None = None,
    now: Callable[[], datetime] | None = None,
) -> int:
    args = parse_args(argv)
    # The account mode is decided from argv alone, BEFORE the label is validated,
    # so a main-account label offered without the opt-in is rejected by the frozen
    # secondary policy — before any Token prompt and before any transport exists.
    account_mode = ACCOUNT_MAIN if args.allow_main_account else ACCOUNT_SECONDARY
    main_account = account_mode == ACCOUNT_MAIN
    try:
        validate_contract()
        if not args.allow_network:
            raise harness.SafetyError("network access was not explicitly enabled")
        mode = _pinned(MODES, args.mode)
        account_label = validate_account_label(
            args.account_label, account_mode=account_mode
        )
        entries = load_batch(args.input)
        if not (stdin_isatty or sys.stdin.isatty)():
            raise harness.SafetyError("an interactive terminal is required")
        report = report_factory() if report_factory is not None else BatchRunReport()
        transport = (transport_factory or harness.ProductionHttpTransport)()
    except MainAccountGateError:
        print(BLOCKED_MAIN_ACCOUNT_MESSAGE)
        return 3
    except BatchFormatError as rejected:
        print(f"BLOCKED: {rejected.message}")
        return 3
    except Exception:
        print(BLOCKED_GATE_MESSAGE)
        return 3
    if main_account:
        for line in main_account_token_notice_lines():
            print(line)
    # The Token is never bound to a local name: it goes straight from the hidden
    # prompt into the credential, exactly as on the secondary path.
    build_credential = (
        MainAccountCredential if main_account else harness.TestAccountCredential
    )
    try:
        credential = build_credential(
            harness._hidden_prompt(
                token_prompt or getpass.getpass,
                MAIN_TOKEN_PROMPT if main_account else TOKEN_PROMPT,
            ),
            account_label,
        )
    except Exception:
        print(
            BLOCKED_MAIN_CREDENTIAL_MESSAGE
            if main_account
            else BLOCKED_CREDENTIAL_MESSAGE
        )
        return 3
    try:
        result = run_batch(
            mode=mode,
            entries=entries,
            transport=transport,
            credential=credential,
            account_label=account_label,
            confirm=lambda plan: _cli_confirm(
                plan, confirmation_prompt or getpass.getpass
            ),
            sleep=sleep,
            report=report,
            now=now,
            account_mode=account_mode,
        )
    except Exception:
        # Nothing server-provided, nothing external and no credential material can
        # travel out here: only this fixed project-owned sentence is printed.
        print(BLOCKED_INTERNAL_MESSAGE)
        return 4
    if result.status in ("ready", "verified", "satisfied"):
        return 0
    return 3 if result.status == "blocked" else 4


if __name__ == "__main__":
    raise SystemExit(main())
