# LML shared development setup

Live Music Locator is split across several repositories. This one holds the bits
that don't belong to any single component - the brew/mise dependencies, the caddy
config, and this document.

It is symlinked into each component repo as `lml/`, so component makefiles can
`include lml/Makefile` and get the shared `install` and `caddy` targets.

**Start here** if you are setting up a machine, or if you want to know which
combination of things to run for the work you are about to do.

## The repositories

Clone these as siblings of each other - the caddy config and the symlink
convention both assume that layout.

```
livemusiclocator/
├── lml                  # this repo: shared dev tooling and docs
├── lml_rb               # rails: the API, the admin, and the server rendered pages
└── lml_frontend_client  # the gig explorer: a react/vite single page app
```

| Repo | What it serves | Its own docs |
| --- | --- | --- |
| `lml_rb` | `api.lml.live` and the `livemusiclocator.com.au` pages | [README](https://github.com/livemusiclocator/lml_rb/blob/main/README.md) |
| `lml_frontend_client` | the gig explorer bundle, deployed to firebase | [README](https://github.com/livemusiclocator/lml_frontend_client/blob/main/README.md) |

## How the front end and the back end fit together

The gig explorer is **not** proxied by rails and is not part of the rails asset
pipeline. It is built separately, uploaded to firebase hosting, and served from
`assets.livemusiclocator.com.au`. Rails renders a page that pulls it in with a
script tag:

```
browser
  │
  ├── https://www.livemusiclocator.com.au/  ─────────────►  rails
  │      renders the explorer layout, which emits:
  │        • <script src="https://assets.livemusiclocator.com.au/…/lml_gig_explorer.js">
  │        • <link href="…/lml_gig_explorer.css">
  │        • window.APP_CONFIG = { gigsEndpoint, allLocations, themes, … }
  │
  ├── …/lml_gig_explorer.js  ───────────────────────────►  firebase hosting
  │
  └── APP_CONFIG.gigsEndpoint  ─────────────────────────►  the API (rails)
```

Two consequences worth internalising:

- **Rails decides which build of the front end you get**, via
  `lml_rb/config/spa_assets.yml` - one entry per rails environment
  (`live` for production, `beta` for test, `dev` for development).
- **The front end gets its configuration from the page that hosts it**, not from
  its own build. `window.APP_CONFIG` is merged over the defaults in
  `lml_frontend_client/src/config.js`, and that is how the API endpoint,
  the available locations and the map pin themes arrive.

Because the tags are emitted with `crossorigin="anonymous"`, whatever serves the
bundle **must** send `Access-Control-Allow-Origin`. Firebase does this per
build in `lml_frontend_client/firebase.json`; locally caddy does it for
`assets.lml.test`.

## Why it is arranged this way

It did not start here, and the history explains the shape.

Originally the two halves lived on separate domains:

- the front end was a static build on **github pages**, served per city from
  `<location>.lml.live` - `melbourne.lml.live`, `castlemaine.lml.live` and so on
- the API was rails on `api.lml.live`
- `livemusiclocator.com.au` was a **google sites** page, maintained by hand, with
  no connection to either

That worked for someone who already had the url and badly for everyone who would
have found the site by searching. A crawler arriving at a location subdomain got
an empty div and a script tag, and the domain people actually search for was a
disconnected brochure.

So `livemusiclocator.com.au` moved here. Rails serves it now, and every page it
serves carries server rendered metadata - `<title>`, open graph tags, and a
schema.org json-ld block built by `lml_rb/app/services/page_metadata_factory.rb`.
A crawler gets a described, indexable page without running any javascript. A
browser gets that same page plus the script tag, and the react bundle takes over
from firebase.

The split is deliberate rather than an accident of hosting:

| Who is asking | What they get | Served by |
| --- | --- | --- |
| a crawler | title, og tags, json-ld, and an html fallback | rails |
| a browser | the same page, then the spa mounts over it | rails, then firebase |
| the spa, once running | json | rails, on `api.lml.live` |

The location subdomains still resolve - `config/routes.rb` redirects them to
`www.livemusiclocator.com.au` with a `location` parameter, or to an edition - so
old links and anything still pointing at github pages era urls keep working.

## Every client side route needs a web route

This is the rule that is easy to forget and obvious once you have been bitten.

The spa uses `createBrowserRouter`, so its routes are **real urls**. Anyone who
lands on one from a shared link, refreshes the page, or is a crawler following a
link, sends that url to rails first. If rails has no route for it, they get a 404
and the spa never gets the chance to run.

So **every client side route in `lml_frontend_client` needs a matching route in
`lml_rb`**, in the `gig_guide` concern in `config/routes.rb`.

| Spa route (`src/App.jsx`) | Rails route (`config/routes.rb`) | Rails controller |
| --- | --- | --- |
| `index` | `root` | `Web::ExplorerController#index` |
| `gigs/:id` | `scope "gigs" { get ":id" }` | `Web::ExplorerController#show` |
| *(not added yet)* `acts/:id` | `scope "acts" { get ":id" }` | `Web::ActsController#show` |

The rails side is not a placeholder that exists only to let the spa boot. It is
the page the crawler indexes, so a new route also wants a generator in
`PageMetadataFactory` - without one the page serves no title, no og tags and no
json-ld, which is the whole reason rails is in front of it - and an html fallback
in the view for anything not running javascript.

The concern is included twice, at the root and again under
`editions/:edition_id`, so a route added there gets the edition version for free.

## Setting up a machine

Install the shared dependencies (caddy, mise, tmux) plus any the component
declares in its own `Brewfile`:

```bash
make install
```

Start caddy. This adds any missing `.test` domains to `/etc/hosts` (so it will
ask for your password), regenerates `caddyfile`, and runs in the foreground:

```bash
make caddy
```

Caddy terminates TLS for every `.test` domain with its own internal CA, so
everything is `https://` locally. **Any change to the caddy config needs caddy
stopped and `make caddy` run again** - the caddyfile is regenerated from scratch
on each start.

### What caddy routes where

Defined in `bin/makefile/caddy`:

| Domain | Goes to |
| --- | --- |
| `lml.test`, `api.lml.test`, `livemusiclocator.com.test`, `www.livemusiclocator.com.test` | rails, port 3000 |
| `brisbane`, `castlemaine`, `geelong`, `goldfields`, `melbourne`, `stkilda` `.lml.test` | rails, port 3000 |
| `adelaide`, `gigs`, `perth`, `sydney` `.lml.test` | the vite dev server, port 5173 |
| `assets.lml.test` | `lml_frontend_client/dists/firebase_root`, as static files with a wildcard CORS header |

The city subdomains are split across both because some editions are served by
rails and some are still served by the standalone SPA.

## Three ways to work

Pick the row that matches what you are changing.

### 1. Front end only

Run the SPA on its own. It serves its own `index.html` (the "Standalone dev
edition"), which sets a minimal `APP_CONFIG` with no `gigsEndpoint` - so it falls
back to the default in `src/config.js` and talks to the **production** API at
`api.lml.live`. No rails, no database, no docker.

```bash
cd lml_frontend_client
make run                      # vite on :5173
```

Then browse to `https://gigs.lml.test/` (via caddy) or `http://localhost:5173/`.

You are reading production data. Be aware that the standalone `index.html` is not
what real users get - it is a stand-in for the page rails renders, so layout and
config differences between the two are expected.

### 2. Back end only

Run rails and let it load the **most recently deployed** development bundle from
firebase. This is the default and needs nothing extra: `spa_assets.yml` already
points the development environment at
`https://assets.livemusiclocator.com.au/lml_gig_explorer_dev`.

```bash
cd lml_rb
bin/dev                       # rails on :3000
```

Browse to `https://www.livemusiclocator.com.test/`. You get whoever last ran a
deploy's front end, which is usually exactly what you want when you are working
on models, the API or the admin.

### 3. Both, locally

Build the front end locally and have rails point at that instead. Three
processes - the tmux session in the `lml_rb` README is a good home for them.

```bash
cd lml_frontend_client
make watch                    # rebuilds dists/firebase_root/lml_gig_explorer_dev on change
```

```bash
cd lml && make caddy          # serves that directory at https://assets.lml.test
```

```bash
cd lml_rb
SPA_BASE_URL=https://assets.lml.test/lml_gig_explorer_dev bin/dev
```

`SPA_BASE_URL` is honoured in development only, by
`lml_rb/config/initializers/spa_assets.rb`. To avoid typing it every time, put it
in a `lml_rb/.env` - foreman loads that automatically and it is gitignored. See
the `lml_rb` README for the details.

In this mode rails injects `gigsEndpoint: https://api.lml.test/gigs`, so the
front end talks to **your** rails. Everything is local.

Confirm which bundle you actually got - this is the single most useful check when
something looks stale:

```bash
curl -s https://www.livemusiclocator.com.test/ \
  | grep -oE '(src|href)="[^"]*lml_gig_explorer[^"]*"' | sort -u
```

`assets.lml.test` means you are on your local build. `assets.livemusiclocator.com.au`
means you are still on the deployed one.

## Deployment

| Component | Where it goes | How |
| --- | --- | --- |
| `lml_frontend_client` | firebase hosting, project `lml-seo` | manual: `./deploy_firebase` |
| `lml_rb` | heroku, app `live-music-locator` | `git push heroku main` |

Both are manual and neither is gated by CI. The front end deploy is documented in
its README - note that it publishes the `live`, `beta` and `dev` bundles all at
once, so **deploying replaces the bundle every other developer's local rails is
loading** in "back end only" mode.

## Troubleshooting

**A caddy config change did nothing.** The caddyfile is regenerated on start.
Stop caddy and run `make caddy` again.

**`assets.lml.test` returns 404.** Nothing has built into
`lml_frontend_client/dists/firebase_root` yet. Run `make watch` (or `make build`)
in that repo. Note the caddy root is resolved relative to the repo you ran
`make caddy` from, so run it from `lml` or a component repo, not elsewhere.

**The browser complains about CORS on the bundle.** Whatever is serving it isn't
sending `Access-Control-Allow-Origin`. The tags use `crossorigin="anonymous"`, so
this is required, not optional.

**Rails ignores `SPA_BASE_URL`.** It is read at boot. Restart rails.

**Front end changes don't show up.** `make watch` rebuilds, but there is no hot
reload in this mode - reload the page. For hot reload, work in "front end only".
