# Move the gig explorer bundle from Firebase Hosting to Cloudflare Pages

Status: proposed, not started (written 2026-11-07). Nothing below has been done yet.

This is a brief for whoever picks the work up, person or agent. It says what the
change is, why it's safe, the exact steps, how to check each one, and where to stop
for a human.

## The change in one paragraph

`lml_frontend_client` builds three static bundles (`lml_gig_explorer_live`, `_beta`,
`_dev`) into `dists/firebase_root/` and `make deploy` pushes them to Firebase Hosting
(project `lml-seo`). They are served at `assets.livemusiclocator.com.au`, which is a
CNAME to `lml-seo.web.app`. Move the hosting to a Cloudflare Pages project serving the
same files at the same hostname, with the same headers. Rails does not change.

## Why

- The DNS for `livemusiclocator.com.au` is already on Cloudflare (nameservers
  `anuj.ns.cloudflare.com`, `zelda.ns.cloudflare.com`), so the assets host joins the
  account that already runs the domain, and attaching the hostname is a few clicks
  with a certificate issued straight away.
- One host and one tool (`wrangler`) instead of the Firebase CLI, which is a separate
  global install today.
- Cloudflare Pages' free plan has no stated bandwidth or request cap for static
  files. Limits that could matter, from
  https://developers.cloudflare.com/pages/platform/limits/ (Sep 2026): 20,000 files
  per site, 25 MiB per file, 100 projects per account. The bundles are far inside
  all of them.

Nothing is broken today; this is consolidation, not a fix. If it turns out to be
awkward, not doing it is fine.

## Why it is safe

The cache invalidation design (see "How the back end picks up a new front end build"
in this repo's README) depends on only two things from the host, and Cloudflare Pages
provides both:

1. **Hashed entry files cached forever**: `lml_gig_explorer.<hash>.js` and `.css` are
   new urls every build, served `public, max-age=31536000, immutable`.
2. **One uncached file at a fixed url**: `manifest.json`, served `no-cache`. Rails'
   `SpaAssets` (`lml_rb/app/services/spa_assets.rb`) reads it at most once a minute per
   process and falls back to `lml_rb/config/spa_assets.yml` on any failure.

Cloudflare Pages deploys are atomic and purge Pages' edge cache on every deploy, so a
new `manifest.json` is visible as soon as the deploy finishes, as on Firebase.

Because the hostname stays `assets.livemusiclocator.com.au`, every url Rails knows
about (`spa_assets.yml`, `SpaAssets`, `rake spa:fetch` in `lml_rb/lib/tasks/spa.rake`,
`config/initializers/spa_assets.rb`) keeps working with no code change.

## What Firebase does today

All of it is in `lml_frontend_client/firebase.json`. Verified against the live host
on 2026-11-07:

| Path | Header | Value |
| --- | --- | --- |
| `/lml_gig_explorer_live/**` | `Access-Control-Allow-Origin` | `https://www.livemusiclocator.com.au` |
| `/lml_gig_explorer_beta/**` | `Access-Control-Allow-Origin` | `https://beta.livemusiclocator.com.au` |
| `/lml_gig_explorer_dev/**` | `Access-Control-Allow-Origin` | `*` |
| `**/manifest.json` | `Cache-Control` | `no-cache` |
| `**/lml_gig_explorer.*.js` and `.css` | `Cache-Control` | `public, max-age=31536000, immutable` |

The CORS headers are required, not optional: Rails emits the tags with
`crossorigin="anonymous"`.

`firebase.json` also has rewrites for `/gigs/**` and `/editions/<city>/**`. **They are
dead**: both return 404 on `assets.livemusiclocator.com.au` today, and nothing builds
into those paths. They are left over from the old SEO site the `lml-seo` project was
named for. Do not port them.

## Steps

### 0. Decide which Cloudflare account owns the Pages project (human)

The Pages project should live in the **same Cloudflare account as the
`livemusiclocator.com.au` zone**, so the hosting belongs to LML rather than to one
person, other maintainers can deploy, and attaching the custom domain is automatic.
Mark's local `wrangler` is logged in to his personal account
(`Mark.ryall@gmail.com's Account`); if the zone is in a different account, log
`wrangler` in to that one (or be added as a member) before deploying. Ask before
creating anything if this is unclear.

### 1. Generate a `_headers` file in the build output

Cloudflare Pages reads headers from a `_headers` file at the root of the deployed
directory (https://developers.cloudflare.com/pages/configuration/headers/). Write it
into `dists/firebase_root/_headers` from the Makefile's `build` target, since `make
clean` deletes `dists/` on every deploy. A static file checked in at the repo root and
copied in is the simplest way.

A translation of the table above:

```
/lml_gig_explorer_live/*
  Access-Control-Allow-Origin: https://www.livemusiclocator.com.au

/lml_gig_explorer_beta/*
  Access-Control-Allow-Origin: https://beta.livemusiclocator.com.au

/lml_gig_explorer_dev/*
  Access-Control-Allow-Origin: *

/*/manifest.json
  Cache-Control: no-cache

/*/lml_gig_explorer.*
  Cache-Control: public, max-age=31536000, immutable
```

**Check the pattern syntax against the current Cloudflare docs before relying on
it.** Two things weren't verified when this brief was written: whether a rule may
contain more than one `*` (the last two rules use a splat in the middle and at the
end), and how headers combine when several rules match one path (Pages applies every
matching rule; a header set by two rules could be joined). If either is a problem,
write one rule per bundle, e.g. `/lml_gig_explorer_live/manifest.json` and
`/lml_gig_explorer_live/lml_gig_explorer.*`, three times over. The check in step 3 is
what matters.

### 2. Change `make deploy`

Keep the clean-then-build (the Makefile comment explains why it isn't optional), and
replace `firebase deploy --only hosting` with:

```
npx wrangler pages deploy dists/firebase_root --project-name <project> --branch main
```

`<project>` is the Pages project name, e.g. `lml-assets`. The first run asks to create
the project, or create it first with
`npx wrangler pages project create <project> --production-branch main`. Add `wrangler`
as a dev dependency so nobody needs a global install; the README currently says the
Firebase CLI must be installed separately.

The directory can keep the name `firebase_root` to avoid touching caddy
(`lml/bin/makefile/caddy` serves it at `assets.lml.test`). Renaming it, e.g. to
`site_root`, is a separate tidy-up that also needs the caddy script, the `lml_rb`
README and this repo's README changing together.

### 3. Trial deploy and compare headers (no user impact)

Deploy, then compare every header on the Pages url against the live Firebase host,
for each bundle:

```bash
for b in live beta dev; do
  for host in https://assets.livemusiclocator.com.au https://<project>.pages.dev; do
    m="$host/lml_gig_explorer_$b/manifest.json"
    js="$host/lml_gig_explorer_$b/$(curl -s "$m" | jq -r '."index.html".file')"
    echo "== $b $host"
    curl -sI "$m"  | grep -iE '^(HTTP|cache-control|access-control-allow-origin)'
    curl -sI "$js" | grep -iE '^(HTTP|cache-control|access-control-allow-origin)'
  done
done
```

The two hosts should match line for line: status 200, `no-cache` on the manifest,
`immutable` on the bundle, and the right origin per bundle.

Then point a local Rails at the trial deploy ("Both, locally" mode in this repo's
README, but with the Pages url):

```bash
cd lml_rb
SPA_BASE_URL=https://<project>.pages.dev/lml_gig_explorer_dev bin/dev
```

The page should load and the explorer should mount. The `dev` bundle sends
`Access-Control-Allow-Origin: *`, which is why this works from a `.test` origin; the
`live` bundle can only be checked from `www.livemusiclocator.com.au`, after the
cutover.

### 4. Cutover (human, or with explicit go-ahead)

**Stop and ask before this step.** It changes what production loads.

In the Pages project, add `assets.livemusiclocator.com.au` as a custom domain. With the
zone in the same account, Cloudflare repoints the DNS record (today a CNAME to
`lml-seo.web.app`) and issues the certificate. Then:

- rerun the step 3 header comparison against `assets.livemusiclocator.com.au` and
  check that its responses now come from Cloudflare, not Firebase
- load `https://www.livemusiclocator.com.au/` in a browser with devtools open and
  check the bundle loads with no CORS errors
- **check that Rails' server-side fetch still works.** `SpaAssets` fetches
  `manifest.json` from Heroku with `Net::HTTP`. If the zone has Bot Fight Mode, a WAF
  challenge or similar, that request could be challenged, and `SpaAssets` would
  quietly keep serving its last good answer, logging `SpaAssets could not read the
  manifest`. Check the Heroku logs after a front end deploy, or run
  `heroku run -a live-music-locator 'curl -sI https://assets.livemusiclocator.com.au/lml_gig_explorer_live/manifest.json'`.
- do a real front end deploy and confirm the new hash appears in the page within a
  minute (the curl in this repo's README under "Confirm which bundle you actually got").

**Rollback**: point the `assets` DNS record back at `lml-seo.web.app`. Leave the
Firebase deployment in place, untouched, until the new host has run without trouble
for a while; only then delete `firebase.json`, `.firebaserc` and `.firebase/` from
`.gitignore`.

### 5. Update the docs

Every place that says "firebase", found with `grep -rn -i firebase` across the three
repos:

- `lml/README.md`: the repositories table, the diagram, "How the back end picks up a
  new front end build" (which names firebase as the host), the Deployment table and
  "Back end only".
- `lml_frontend_client/README.md`: line 7 (where it's served from), the Deployment
  section (lines 73–91: login, `make deploy`, the CLI install note), the bundle and
  caching sections that cite `firebase.json` (lines 93–121, which should cite
  `_headers` instead), and line 60 ("the CORS header firebase uses").
- `lml_rb/README.md`: lines 10, 151, 155, 173 and the deployment table at 216.
- `lml_rb/lib/tasks/spa.rake`: the task description says "Fetch SPA build from
  Firebase"; the url it uses is already the custom domain, so only the wording
  changes.
- `lml_rb/config/initializers/spa_assets.rb` line 5 and `lml/bin/makefile/caddy`
  line 81: comments only.

Delete this file once the move is done, or turn it into a short "why the assets are
on Cloudflare Pages" note in the README.

## What not to change

- The hostname. Everything depends on `assets.livemusiclocator.com.au`.
- The bundle paths (`/lml_gig_explorer_<install>/`) and the file names Vite writes.
- `SpaAssets`, `spa_assets.yml` and the rake task's logic. If they need changing,
  something above has gone wrong.
- The clean-before-build in `make deploy`.
