# Volleyball .dvw auto-fetch

Downloads new Centre volleyball scout files (`.dvw`) from Hudl VolleyMetrics and
commits them to `volleyball/dvw/`. Only matches not already in
`dvw/manifest.json` are downloaded, so nothing is ever re-fetched.

- `fetch_dvw.py` — the Playwright downloader
- `dvw/` — committed `.dvw` files + `manifest.json` (the "already have" record)
- `.github/workflows/volleyball-dvw.yml` — daily scheduled run

## One-time setup

### 1. Add GitHub Secrets
Repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret | Value |
|---|---|
| `HUDL_EMAIL` | the Hudl login email |
| `HUDL_PASSWORD` | the Hudl password (never commit it — paste it only into the GitHub Secrets UI) |
| `HUDL_STORAGE_STATE_B64` | base64 of a saved session (step 2) — strongly recommended |

Or via the `gh` CLI:
```bash
gh secret set HUDL_EMAIL
gh secret set HUDL_PASSWORD
gh secret set HUDL_STORAGE_STATE_B64 < session.b64
```

### 2. Capture a saved session (avoids fresh cloud logins)
Run once **on your Mac** (a trusted IP Hudl won't challenge):
```bash
pip install playwright && playwright install chromium
export HUDL_EMAIL='you@example.com' HUDL_PASSWORD='your-password'   # your shell keeps these out of the file
python volleyball/fetch_dvw.py --save-session      # opens a browser, logs in
base64 -i volleyball/storage_state.json > session.b64
```
Store `session.b64`'s contents as `HUDL_STORAGE_STATE_B64`. The runner reuses
this session and usually skips the Auth0 login entirely.

Sessions expire (days–weeks). When the workflow starts failing with a login
challenge, just repeat step 2 to refresh the secret.

## Local testing
```bash
python volleyball/fetch_dvw.py --recon    # list matches + which are NEW/HAVE
python volleyball/fetch_dvw.py --headed   # watch it run
python volleyball/fetch_dvw.py            # real download
```

## Security notes
- Credentials live only in GitHub Secrets — never in the repo. `storage_state.json`
  and `artifacts/` are git-ignored.
- The workflow has `contents: write` only; it can push data, nothing else.
- If Hudl shows a CAPTCHA/verification page, the job fails and uploads a
  screenshot artifact instead of committing an empty/garbage result.

## Hooking into the R analysis
New `.dvw` files land in `volleyball/dvw/`. Point your R DataVolley reader
(e.g. the `datavolley` package) at that directory. If you want the workflow to
run R automatically after downloading, add a `setup-r` + `Rscript` step after
the download step (say the word and I'll wire it up).
