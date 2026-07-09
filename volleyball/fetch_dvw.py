#!/usr/bin/env python3
"""
Fetch new Centre volleyball .dvw scout files from Hudl VolleyMetrics.

Pipeline (mirrors the basketball scrape's "only download what's new" idea):
  1. Log into the Hudl portal (reuse a saved session if we have one).
  2. Open the Matches list.
  3. For each match row, build a STABLE key (date + teams). Skip any key
     already in dvw/manifest.json -> we never re-download, so the repo stays
     clean. Download only the new ones.
  4. Save each .dvw to volleyball/dvw/ and record it in the manifest.

Credentials + session come from environment variables (GitHub Secrets in CI):
    HUDL_EMAIL              login email
    HUDL_PASSWORD           login password
    HUDL_STORAGE_STATE_B64  (optional) base64 of a Playwright storage_state.json
                            captured once locally, so CI reuses your session
                            instead of doing a fresh Auth0 login every run.

Local usage:
    python3 fetch_dvw.py --recon     # just LIST visible matches, download nothing
    python3 fetch_dvw.py --headed    # watch the browser (debugging)
    python3 fetch_dvw.py --save-session   # log in, write storage_state.json, exit
    python3 fetch_dvw.py             # download new matches

Exit codes: 0 = ok (even if nothing new); 2 = login/challenge failure.
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from playwright.sync_api import (
    Page,
    TimeoutError as PWTimeout,
    sync_playwright,
)

HERE = Path(__file__).resolve().parent
DVW_DIR = HERE / "dvw"
MANIFEST = DVW_DIR / "manifest.json"
SESSION_FILE = HERE / "storage_state.json"        # local only. It is git-ignored.
ARTIFACT_DIR = HERE / "artifacts"                 # screenshots on failure when the website asks for CAPTCHA.

PORTAL_URL = "https://portal.volleymetrics.hudl.com"

# Angular renders each match as a <my-matches-table-row> element. That custom
# tag is far more stable than nth-child positions, so we anchor on it.
ROW_SELECTOR = "my-matches-table-row"

def load_manifest() -> dict:
    if MANIFEST.exists():
        return json.loads(MANIFEST.read_text())
    return {}

def save_manifest(data: dict) -> None:
    MANIFEST.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def match_key(row_text: str) -> str:
    """Stable, filesystem-safe key from a match row's visible text."""
    collapsed = " ".join(row_text.split())          # kill newlines/extra spaces
    slug = re.sub(r"[^A-Za-z0-9]+", "-", collapsed).strip("-").lower()
    return slug[:120] or "match"

#Login
def is_challenge_page(page: Page) -> bool:
    """Detect a CAPTCHA / MFA / device-verification wall."""
    url = page.url.lower()
    if any(w in url for w in ("captcha", "mfa", "challenge", "verify")):
        return True
    body = (page.locator("body").inner_text(timeout=3000) or "").lower()
    return any(
        p in body
        for p in ("verify your identity", "enter the code", "i'm not a robot",
                  "unusual activity", "verify it's you")
    )


def login(page: Page, email: str, password: str) -> None:
    """Fresh Auth0 email+password login (recorded from the real flow)."""
    page.goto(PORTAL_URL, wait_until="domcontentloaded")

    # If a reused session already has us in, the Email box never appears.
    try:
        page.get_by_role("textbox", name="Email*").wait_for(timeout=8000)
    except PWTimeout:
        return  # already authenticated via storage_state

    page.get_by_role("textbox", name="Email*").fill(email)
    page.get_by_role("button", name="Continue", exact=True).click()
    page.get_by_role("textbox", name="Password*").fill(password)
    page.get_by_role("button", name="Continue").click()

    # Auth0 -> portal redirect can take a moment.
    page.wait_for_load_state("networkidle")
    if is_challenge_page(page):
        _fail_with_screenshot(page, "login-challenge")


def _fail_with_screenshot(page: Page, name: str) -> None:
    ARTIFACT_DIR.mkdir(exist_ok=True)
    shot = ARTIFACT_DIR / f"{name}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}.png" #Saves the screenshot as an artifact if the website crashes during login.
    try:
        page.screenshot(path=str(shot), full_page=True)
        print(f"!! Saved screenshot: {shot}", file=sys.stderr)
    except Exception:
        pass
    print(
        "!! Hudl presented a login/verification challenge. Automated login was "
        "blocked (this is the datacenter-IP risk). Refresh HUDL_STORAGE_STATE_B64 "
        "with a fresh local session, or run from a trusted IP.",
        file=sys.stderr,
    )
    sys.exit(2)


#Matches
def _dump_nav(page: Page) -> None:
    """Print every link/nav label we can see, to learn the real 'Matches' name."""
    print("visible links/nav (for selector debugging)", file=sys.stderr)
    try:
        for el in page.get_by_role("link").all():
            txt = (el.inner_text() or "").strip()
            if txt:
                print(f"   link: {txt!r}", file=sys.stderr)
    except Exception as exc:
        print(f"   (could not enumerate links: {exc})", file=sys.stderr)
    print("----------------------------------------------------", file=sys.stderr)


def open_matches(page: Page) -> None:
    # After the Auth0 redirect the SPA renders its nav asynchronously, so give
    # it a beat and try several ways to reach Matches. The row grid appearing
    # (ROW_SELECTOR) is our real success signal.
    page.wait_for_load_state("domcontentloaded")

    strategies = [
        lambda: page.get_by_role("link", name=re.compile(r"Matches", re.I)).first,
        lambda: page.get_by_role("button", name=re.compile(r"Matches", re.I)).first,
        lambda: page.locator("a", has_text=re.compile(r"Matches", re.I)).first,
        lambda: page.get_by_text(re.compile(r"^\s*Matches\s*$", re.I)).first,
    ]
    for make in strategies:
        try:
            loc = make()
            loc.wait_for(state="visible", timeout=10000)
            loc.click()
            page.wait_for_selector(ROW_SELECTOR, timeout=30000)
            page.wait_for_load_state("networkidle")
            return
        except PWTimeout:
            continue

    # Nothing worked.
    _dump_nav(page)
    _fail_with_screenshot(page, "no-matches-link")


def list_rows(page: Page):
    """Return [(key, row_locator, visible_text), ...] for every match row."""
    rows = page.locator(ROW_SELECTOR)
    out = []
    for i in range(rows.count()):
        row = rows.nth(i)
        text = row.inner_text().strip()
        if not text:
            continue
        out.append((match_key(text), row, text))
    return out


def inspect_download(page: Page, row) -> None:
    """Open one match popup and dump every 'download' element + its context,
    so we can choose the .dvw / DataVolley option by a stable label."""
    with page.expect_popup() as popup_info:
        row.locator(".generic-table-two-row-cell-text").first.click()
    mp = popup_info.value
    mp.wait_for_load_state("domcontentloaded")
    try:
        mp.wait_for_load_state("networkidle", timeout=15000)
    except PWTimeout:
        pass
    print(f"\nMatch page URL: {mp.url}", file=sys.stderr)

    # For each "DVW File" label, walk up to the smallest ancestor that also
    # contains a "Download" button, and print that ancestor's HTML. This shows
    # exactly which Download belongs to the DVW card.
    cards = mp.evaluate(
        r"""() => {
        const labels = Array.from(document.querySelectorAll('span.description-text'))
            .filter(s => /dvw file/i.test(s.textContent || ''));
        return labels.map(label => {
            let node = label;
            for (let i = 0; i < 8 && node.parentElement; i++) {
                node = node.parentElement;
                const dls = node.querySelectorAll('span.button-text');
                const hasDl = Array.from(dls).some(d => /download/i.test(d.textContent || ''));
                if (hasDl) break;
            }
            return {
                ancestorTag: node.tagName,
                ancestorCls: (node.className || '').toString().slice(0, 120),
                html: node.outerHTML.replace(/\s+/g, ' ').slice(0, 1200),
            };
        });
    }"""
    )
    print(f"Found {len(cards)} 'DVW File' card(s):", file=sys.stderr)
    for i, c in enumerate(cards):
        print(f"\n  --- DVW card [{i}] ancestor <{c['ancestorTag']}> "
              f"class={c['ancestorCls']!r} ---", file=sys.stderr)
        print(f"  {c['html']}", file=sys.stderr)
    print("\nLeave this browser open and eyeball where the .dvw download lives.",
          file=sys.stderr)
    # Keep the popup open a bit so you can look at it when running --headed.
    page.wait_for_timeout(8000)
    mp.close()


# Hudl tags the DataVolley-download action with its own QA automation id and an
# ng-click of onDvwDownloadClick() -> this targets the .dvw download and nothing
# else (not the video). The actions template is rendered twice (one copy is
# ng-hide), so we click only the visible instance.
DVW_DOWNLOAD_SELECTOR = '[data-qa-id="span-directives-vmMatchActionsTmpl-ondvwdownloadclick"]'
ACTIONS_SELECTOR = ".vm-match-actions-container"


class NoDvwAvailable(Exception):
    """The match page rendered but has no downloadable DVW file (yet)."""


def download_one(page: Page, row) -> tuple[str, str, str | None]:
    """Open a match row, click the DVW File's Download -> I Accept, save the .dvw.

    Returns (saved_filename, source_url, match_id). Raises NoDvwAvailable when the
    match simply has no DVW, or a generic error otherwise, so the caller can
    log-and-continue.
    """
    with page.expect_popup() as popup_info:
        # The whole row is clickable via its text cell.
        row.locator(".generic-table-two-row-cell-text").first.click()
    match_page = popup_info.value
    match_page.wait_for_load_state("domcontentloaded")
    source_url = match_page.url
    m = re.search(r"/match/(\d+)", source_url)
    match_id = m.group(1) if m else None

    # Wait for the actions panel to render, then decide if a DVW exists at all.
    # (Some matches never get a .dvw — don't burn a 20s timeout on them.)
    try:
        match_page.wait_for_selector(ACTIONS_SELECTOR, timeout=20000)
    except PWTimeout:
        pass
    match_page.wait_for_timeout(600)          # let ng-show/ng-hide settle

    dvw = match_page.locator(f"{DVW_DOWNLOAD_SELECTOR}:visible")
    if dvw.count() == 0:
        match_page.close()
        raise NoDvwAvailable(match_id or source_url)

    dvw_btn = dvw.first
    dvw_btn.scroll_into_view_if_needed()
    dvw_btn.click()

    with match_page.expect_download() as dl_info:
        match_page.get_by_role("button", name=re.compile(r"I Accept", re.I)).click()
    download = dl_info.value

    suggested = download.suggested_filename or f"{match_id or 'match'}.dvw"
    dest = DVW_DIR / suggested
    # Avoid clobbering a differently-named file for the same match.
    if dest.exists():
        dest = DVW_DIR / f"{match_id or match_key(source_url)}-{suggested}"
    download.save_as(str(dest))
    match_page.close()
    return dest.name, source_url, match_id


def build_context(pw, headed: bool):
    storage = None
    b64 = os.environ.get("HUDL_STORAGE_STATE_B64")
    if b64:
        SESSION_FILE.write_bytes(base64.b64decode(b64))
    if SESSION_FILE.exists():
        storage = str(SESSION_FILE)
        print(f"Using saved session: {SESSION_FILE.name}")

    browser = pw.chromium.launch(headless=not headed)
    context = browser.new_context(
        storage_state=storage,
        accept_downloads=True,
        viewport={"width": 1440, "height": 900},
        user_agent=(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
        ),
    )
    return browser, context


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--recon", action="store_true", help="list matches, download nothing")
    ap.add_argument("--headed", action="store_true", help="show the browser")
    ap.add_argument("--save-session", action="store_true",
                    help="log in, write storage_state.json, then exit")
    ap.add_argument("--limit", type=int, default=0,
                    help="download at most N new matches (0 = no limit); use 1 to test")
    ap.add_argument("--inspect", action="store_true",
                    help="open the first match and dump download elements, then exit")
    args = ap.parse_args()

    email = os.environ.get("HUDL_EMAIL", "")
    password = os.environ.get("HUDL_PASSWORD", "")
    headed = args.headed or os.environ.get("HUDL_HEADFUL") == "1"

    if not (email and password) and not SESSION_FILE.exists() \
            and not os.environ.get("HUDL_STORAGE_STATE_B64"):
        print("Set HUDL_EMAIL and HUDL_PASSWORD (or provide a saved session).",
              file=sys.stderr)
        return 2

    DVW_DIR.mkdir(parents=True, exist_ok=True)
    manifest = load_manifest()

    with sync_playwright() as pw:
        browser, context = build_context(pw, headed)
        page = context.new_page()
        try:
            login(page, email, password)

            if args.save_session:
                context.storage_state(path=str(SESSION_FILE))
                print(f"Saved session to {SESSION_FILE}. "
                      f"To use in CI:\n  base64 -i {SESSION_FILE}\n"
                      "and store the output as the HUDL_STORAGE_STATE_B64 secret.")
                return 0

            open_matches(page)
            rows = list_rows(page)
            print(f"Found {len(rows)} match rows.")

            if args.recon:
                for key, _row, text in rows:
                    seen = "HAVE" if key in manifest else "NEW "
                    print(f"  [{seen}] {key}   <- {text!r}")
                return 0

            if args.inspect:
                if rows:
                    inspect_download(page, rows[0][1])
                return 0

            new_count = 0
            for key, row, text in rows:
                if key in manifest:
                    continue
                try:
                    fname, url, match_id = download_one(page, row)
                    manifest[key] = {
                        "file": fname,
                        "url": url,
                        "match_id": match_id,
                        "text": " ".join(text.split()),
                        "downloaded_at": datetime.now(timezone.utc).isoformat(),
                    }
                    save_manifest(manifest)          # persist after each success
                    new_count += 1
                    print(f"  downloaded: {fname}")
                    if args.limit and new_count >= args.limit:
                        print(f"  (--limit {args.limit} reached, stopping)")
                        break
                except NoDvwAvailable:
                    # No DVW yet — leave OUT of the manifest so we re-check it on a
                    # future run (a scout file may be uploaded after the match).
                    print(f"  -- no DVW yet: {key}")
                except Exception as exc:               # log-and-continue
                    print(f"  !! failed on {key}: {exc}", file=sys.stderr)

            print(f"Done. {new_count} new match file(s).")
            # Refresh session snapshot so CI can hand back a fresh one as an artifact.
            context.storage_state(path=str(SESSION_FILE))
            return 0
        finally:
            context.close()
            browser.close()


if __name__ == "__main__":
    raise SystemExit(main())
