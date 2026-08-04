# Build environment staleness

Our CircleCI test image is frozen at a base built 2025-01-06, and the
procedure for updating it is manual enough that it does not get done.
That single fact produces four of the five problems below. The fifth,
an unpinned Node in the production build, is unrelated and should be
fixed first.

This document is written to be picked up cold. Everything asserted here
was checked on 2026-08-03 or 2026-08-04; where a claim needs
re-verifying before it is relied on, it says so.

## Status

**Already done and merged** (branch `apt-get-update`, deployed to
staging 2026-08-04):

* The `apt-get update` step in the CircleCI `build` job is commented
  out, with the reasoning beside it. It served no purpose and printed an
  error on every build.
* The `deploy` job has its own browser-free image,
  `cimg/node@sha256:8966565f…` (`:24.19.0`), rather than sharing the
  test image. That job holds `HEROKU_API_KEY`, so it should carry as
  little as possible. The Heroku CLI moved to 11.8.1 at the same time,
  because 10.17.0 declared `engines: node 20.x` and Node 20 is end of
  life.

**In progress** (branch `build_env_staleness`): step 1 of
[the plan](#the-plan), pinning Node. The repository side is done; the
buildpack still has to be added to the two Heroku applications, in the
order given under [Pinning Node](#pinning-node-for-the-production-build).

**Decided, not yet built:** steps 2 to 11 of
[The plan](#the-plan).

**Chrome:** decided *and built* 2026-08-05, a second container; see
[Chrome: a second container](#chrome-a-second-container). Landed ahead
of the new test image on purpose, so that it changes one thing against a
known-good baseline instead of arriving mixed in with a new image.

## Finding 1: a frozen image freezes its trust anchors too

`sudo apt-get update` in the `build` job failed on every run:

```text
Err:5 https://dl.google.com/linux/chrome/deb stable InRelease
  The following signatures couldn't be verified because the public key
  is not available: NO_PUBKEY FD533C07C264648F
```

| What | When |
| ---- | ---- |
| `cimg/ruby:3.4.1-browsers`, our base, was built | 2025-01-06 14:20:58Z |
| Google created signing subkey `FD533C07C264648F` | 2025-01-07 |

The base image was built the day before the key existed, so its copy of
Google's keyring cannot contain it. Today's `InRelease` verifies as
`using RSA key 0E225917414670F4442C250DFD533C07C264648F`.

Pinning by digest froze the image, and the keyring came with it. That is
pinning working as designed.

**The lesson, which outlives this repository.** Two different things
want pinning, at different layers:

* **Artifacts** (images, actions, gems, CLIs) pin by **digest**.
  Identity is the content; freshness comes from a deliberate bump.
* **Trust anchors** (signing keys) pin by **fingerprint**, and fetch the
  material fresh. Identity is the long-lived master key; the material
  must rotate.

Google's master key `EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796` was
created 2016-04-12 and has no expiry. Under it are eight signing
subkeys rotated roughly annually; the newest, `1D09C015006FEAB8`, was
created 2026-03-10 and is not yet in use.

We did not need that here, because nothing in the job uses apt. Checked,
not assumed: there is no `apt-get install` anywhere in
`.circleci/config.yml`; `browser-tools/install-chromedriver` fetches
chromedriver with `curl` and only apt-installs on yum-based systems; and
nothing `rake default` runs touches apt.

It still matters, because `dockerfiles/3.4.1-browsers/Dockerfile:31`
runs its own `apt-get update`. Rebuilding our layer against the same
frozen base would hit the same error.

## Finding 2: the test image is nineteen months old

`.circleci/config.yml` pins `drdavidawheeler/cii-bestpractices` by
digest; that pin arrived in commit `816568f1` on 2025-10-24 and has not
changed. It is built `FROM cimg/ruby@sha256:a0b57bca…`, built
2025-01-06.

This is not a production exposure. Staging and production do not run our
Docker images: the deploy is `git push heroku`, and Heroku builds a slug
with its own Ruby buildpack. Our images are used by CircleCI only.

**The problem is the procedure, not the age.**
`dockerfiles/how-to-create-image.md` describes seven manual steps and
needs DockerHub push access to a personal account. Anything that manual
is out of date most of the time, so "rebuild it" is a reprieve, not a
fix.

## Finding 3: Ruby is nine patch releases behind

The staging deploy of 2026-08-04 reported:

```text
###### WARNING:
       There is a more recent Ruby version available for you to use:
       3.4.10
```

`.ruby-version` says 3.4.1, and the `Gemfile` reads that file, so it
governs both production and the test image. This is the same problem as
finding 2: upgrading Ruby means rebuilding the test image.

## Finding 4: CI tests on a different Ubuntu than production runs

Production and staging build on the **Heroku-24** stack, which is Ubuntu
24.04. Our test image is Ubuntu 22.04, shown by `jammy` throughout the
apt output. Heroku reports that Heroku-26 is available, so upgrading
production would put two LTS releases between them.

**No stock CircleCI image closes this while we are on Ruby 3.4.**
CircleCI pins an operating system per Ruby line:

| cimg-ruby line | Base | Ubuntu |
| -------------- | ---- | ------ |
| 3.4 | `cimg/base:2026.03-22.04` | 22.04 |
| 4.0 | `cimg/base:2026.03` | 24.04 |

`cimg/base:2026.03` and `cimg/base:2026.03-24.04` share digest
`sha256:fdfacc6c…`, so the unsuffixed tag is the 24.04 one. Every
`cimg/ruby:3.4.x` image is Ubuntu 22.04 and will stay so, and nothing
CircleCI publishes is on 26.04 at all.

## Finding 5: the production build installs an unpinned Node

Unrelated to the image, and the one that can break a deploy. From the
same staging deploy:

```text
###### WARNING:
       Default version of Node.js changed (20.9.0 to 24.13.0)
       This version is not pinned and can change over time, causing
       unexpected failures.
```

Node is not incidental. `Gemfile:135` has `gem 'terser'`, which minifies
JavaScript through ExecJS, which uses Node, and the deploy runs
`rake assets:precompile`. So JavaScript minification for production
silently moved four major versions.

We pin CircleCI images by digest, the Codecov CLI by SHA-256, and the
Heroku CLI by SHA-512, and then let the platform choose a Node for the
production build. There is no `package.json` and no `.node-version` to
constrain it.

Heroku's fix is to place the `heroku/nodejs` buildpack ahead of
`heroku/ruby` and pin the version there. See their Ruby support
reference under `devcenter.heroku.com`.

## The decision

**Approach D**, decided 2026-08-04: build the test image on the same
stack image production uses, and build it in the pipeline so no one ever
builds it by hand.

### Why not simply use a stock image

Tempting, because our custom image adds nothing that is still needed:

| What it adds | Why it is not needed |
| ------------ | -------------------- |
| `cmake` | already in `cimg/base`, 22.04 and 24.04 |
| `shared-mime-info` | its comment says "for gem mimemagic"; we use `marcel (1.2.1)`, which carries MIME data internally |
| Bundler 2.7 | `.circleci/config.yml` already installs the version named in `Gemfile.lock`, overriding the image |

But a stock `cimg/ruby` locks us to Ubuntu 22.04 while production runs
24.04 and is heading for 26.04, per finding 4. Ending image maintenance
and matching production pull against each other, and matching
production is what we were asked for. Approach D takes the maintenance
back and removes it a different way, by automating it.

### Also considered

* **Automated rebuild of the present custom image.** Same automation,
  none of the parity. Superseded by D.
* **Browser in a separate `selenium/standalone-chrome` container.**
  Decouples browser from Ruby image, needs Capybara reconfigured for a
  remote driver and the app reachable from that container. Reasonable
  later; solves a coupling that is not hurting now.
* **Building the image inside the test job.** Rejected: it spends the
  test time we are protecting.
* **A parameterized executor fed by dynamic configuration**, instead of
  a mutable stable tag. Removes the tag race entirely, at the price of
  dynamic configuration. Not worth it while the race is judged
  unlikely and self-correcting. Confirm how parameterized executors
  behave before relying on this if that judgement changes.

## The design

### The image

`FROM heroku/heroku:24-build`, pinned by digest resolved at build time,
plus Ruby, Chrome, and chromedriver.

Heroku maintains those base images: `heroku/heroku:24`, `:26`, and both
`-build` variants existed and had been rebuilt on 2026-07-29.

**Install Heroku's own Ruby binary rather than compiling.** The prebuilt
tarballs are publicly readable. The path differs by stack, which is easy
to get wrong:

```text
heroku-24/amd64/ruby-3.4.10.tgz   -> 200
heroku-24/ruby-3.4.1.tgz          -> 403   (no arch segment)
heroku-22/ruby-3.4.1.tgz          -> 200
```

under `https://heroku-buildpack-ruby.s3.us-east-1.amazonaws.com/`.

**Trap:** S3 answers 403 rather than 404 when listing is denied, so a
missing object and a forbidden one look identical. Only a **200** means
anything definite. An earlier version of this document wrongly concluded
these tarballs were private on the strength of a 403 from the path
without the architecture segment.

Using Heroku's binary means the interpreter matches production, not just
the operating system, and the build is a download rather than a compile.

**Install the Node that `package.json` pins**, 24.19.0, from the same
place Heroku's Node buildpack takes it, so CI minifies JavaScript with
the interpreter production minifies with. Node is no longer optional in
this image for a second reason: `license_finder` activates its NPM
scanner on the presence of `package.json`, so `rake default` now shells
out to `npm`. Read the version from `package.json` rather than repeating
it, so the two cannot drift.

**Verify before building anything else** that
`heroku/heroku:24-build` carries `libpq` and its headers, and a working
C toolchain, since the `pg` gem and several others compile against them.
It ought to, being the image Heroku's own buildpacks compile in, but it
is a five-minute check that would sink this approach if it failed, so do
it first rather than discover it at the end.

**No browser goes in this image.** Chrome runs as a second container;
see [Chrome: a second container](#chrome-a-second-container).

### Pinning

The build job resolves what `heroku/heroku:24-build` points at now and
passes it in, so the Dockerfile reads
`FROM heroku/heroku:24-build@${BASE_DIGEST}`. Every build is pinned to
an exact digest and records which one. The policy changes from "a digest
frozen in a file until someone edits it" to "pin whatever was current at
build time, and record it".

### Caching, and why the check is in the pipeline

The check belongs in the same workflow that builds and tests, not in a
scheduled job. Correctness that depends on someone noticing a broken
cron job is not correctness, and a pull request that edits the
Dockerfile must be tested with the image it just described.

Two jobs in one workflow, because **a CircleCI job cannot run inside an
image it just built** — the executor's image is resolved from static
configuration before any step runs:

```text
prepare-image  ->  build (tests)
```

Tag each build with everything that determines its contents:

```text
badgeapp-test:heroku24-ruby3.4.10-<base-digest>-<recipe-hash>
```

where `<recipe-hash>` is a hash over the `Dockerfile` and every file it
copies in. **Both halves are needed.** The base digest alone keeps us
current with nobody deciding anything, because when Heroku rebuilds the
stack image the key changes by itself; but it cannot notice that *we*
changed the recipe. The recipe hash alone would cache too well, because
an operating system security update changes nothing we wrote. An earlier
version of this design used only the base digest and Ruby, which would
have let a pull request that edits the `Dockerfile` score a cache hit
and run its tests against the image it had just replaced.

`prepare-image` then:

1. Resolves what `heroku/heroku:24-build` points at now: one request.
2. Computes the recipe hash from the working tree.
3. Asks the registry whether the matching tag exists: one request.
4. **Points `badgeapp-test:current` at that tag**, whether it was
   already there or has just been built.
5. Halts with `circleci-agent step halt` if the tag already existed, so
   the build is skipped.

**Step 4 happens on both paths, and that is the whole point.** An
earlier version halted at step 3 on a cache hit, leaving `:current`
wherever the last cache *miss* had put it. That is silently wrong as
soon as two Ruby versions are in flight, which is exactly what
`propose_ruby_upgrade` produces: a branch on 3.4.1 and a branch on
3.4.10 would alternate cache hits, neither repointing `:current`, and
each would run its tests on the other's interpreter without saying so.

**Order still matters for the expensive parts.** The `checkout` needed
for the recipe hash is cheap; the `setup_remote_docker` that provisions
a Docker environment, and the build itself, come after the halt, so
neither runs on the common path. The common path is now two registry
requests and one registry write rather than pure early exit. That is the
price of a `:current` that is always right, and it is worth paying.

The tests run against `badgeapp-test:current`, so
`.circleci/config.yml` stays unchanged except when Ruby or the stack
changes, which is exactly when a human should read it.

**Decisions taken:**

* The comparison is *existence of a tag name*, not reading a label and
  comparing digest strings. The latter keeps one tag but means walking a
  manifest to a config blob and handling multi-architecture indexes.
  Simple wins while both are reliable.
* The stable tag is mutable, so two branches can still race between
  step 4 and the `build` job pulling it. Accepted, with eyes open: the
  window is seconds rather than a whole pipeline, and a mismatch shows
  up as a test failure on a rerunnable job rather than as a quiet pass.
  If that judgement ever changes, the fix is the parameterized executor
  under [Also considered](#also-considered), which removes the shared
  mutable name entirely.
* A miss takes a few minutes. Accepted: that work must happen somewhere
  to stay current, and until now it happened by hand, or rather did not.

### Why not CircleCI's own cache

Asked, and the answer is no, for a structural reason rather than a
preference. **`save_cache` and `restore_cache` are steps, and steps run
inside the executor.** By the time any cache could be restored, the
container we wanted to restore is already the one we are running in.
This is the same fact recorded above, that a job cannot run inside an
image it just built, seen from another angle: the executor's image is
resolved from static configuration before any step exists to consult a
cache. Workspaces have the same shape and the additional limit of
living only within one workflow run.

So the image must come from a registry. CircleCI's caching is still
useful *within* `prepare-image`, for Docker layers on the rare miss, and
that is where to apply it.

**Use `ghcr.io` under the `ossf` organisation, and make the image
public.** That answers the complaint in finding 2, which was not about
DockerHub as such but about push access to one person's personal
account. Public means the `build` job needs no pull credential at all,
so the only secret is `prepare-image`'s push token: a GitHub App
installation token or fine-grained personal access token with
`packages: write` and nothing else, in a CircleCI context restricted to
the people who may hold it.

Making it public also removes most of the rate-limit exposure below,
since `ghcr.io` does not meter anonymous pulls the way DockerHub does.

### Registry rate limits

DockerHub meters anonymous pulls, and we would rather not trade rights
for headroom by authenticating a pull that needs no authentication.

With the image on `ghcr.io`, what remains is the pull of
`heroku/heroku:24-build`, which happens only on a cache miss, and the
`cimg/postgres` and `cimg/node` pulls we already do today. So the
exposure is small and mostly unchanged.

Handle it by waiting rather than by escalating privilege: retry the base
image pull with exponential backoff and a generous ceiling. A rate limit
is a transient condition with a known cure, and the cure is patience.
Log each retry, so a limit we are actually living inside shows up as
something visible rather than as a slow build nobody can explain.

## Chrome: a second container

Decided 2026-08-05. Chrome leaves our image entirely and runs as a
second container, `selenium/standalone-chrome`, beside `cimg/postgres`
in the `ruby-postgres` executor. Capybara talks to it over a URL.

**The deciding reason is upgrades, not decoupling.** As an image pinned
in `.circleci/config.yml`, Chrome falls under Renovate's `circleci`
manager, which we are adding anyway. A new Chrome then arrives as an
ordinary pull request, which is the whole interface described under
[Keeping pins current](#keeping-pins-current), with no bespoke
mechanism. Every other option needs something built to keep Chrome
fresh, which is the exact failure this document exists to end.

**Chrome's own version is pinnable.** The image publishes Chrome-version
tags, not merely Selenium ones:

```text
150.0.7871.124
150.0.7871.124-chromedriver-150.0.7871.124-grid-4.46.0-20260707
150.0
```

Pin the plain exact-Chrome tag plus a digest. Chromedriver is matched to
Chrome by construction inside the image, the Grid version rides along in
the digest, and a short tag changes when Chrome changes, which is the
signal worth seeing in a pull request title.

It also **closes finding 1 rather than managing it**: our `Dockerfile`
never adds Google's apt repository, so there is no keyring to rotate,
and the `browser-tools` orb goes away with it.

### Why the usual objection does not apply

A single standalone container serves one session at a time
(`SE_NODE_MAX_SESSIONS=1`), which normally collides with parallel tests.
We never need more than one. `lib/tasks/default.rake:25` says
`test:optimized` "runs regular tests (parallelized) then system tests
(serial)", and `test/test_helper.rb:148` gives the reason: system tests
are serial because `Capybara.server_port` is fixed at 31337. The scale
is 22 test cases in 10 files. Parallel system tests are blocked today by
that fixed port, not by the browser, so this decision forecloses
nothing.

Checked, and we use none of the APIs a remote browser complicates: no
`attach_file` and therefore no file-detector problem, no `within_window`
or `switch_to`, no browser-log reading, no download assertions.

### Where the change goes, which is not where it looks

**Not in `Capybara.register_driver`.**
`ActionDispatch::SystemTesting::Driver#register` calls
`Capybara.register_driver` under its own name, `:selenium`, and makes it
current, so our `Capybara.register_driver :headless_chrome` block is not
what system tests run. Rails builds the driver from
`driven_by`, and passes `options:` straight through to
`Capybara::Selenium::Driver.new`:

```ruby
SELENIUM_REMOTE_URL = ENV.fetch('SELENIUM_REMOTE_URL', nil)
SELENIUM_OPTIONS =
  if SELENIUM_REMOTE_URL
    { browser: :remote, url: SELENIUM_REMOTE_URL }
  else
    {}
  end

driven_by :selenium, using: driver || :headless_chrome,
          screen_size: [1400, 1400], options: SELENIUM_OPTIONS do |option|
```

**`browser: :remote` is load-bearing, not cosmetic.**
`Driver#initialize` reads
`@browser.preload unless @options[:browser] == :remote`, and `preload`
is what resolves a *local* chromedriver through Selenium Manager. Pass
only `url:` and a machine with no browser still tries to download one,
which is the cost we are removing. This does mean the driver becomes a
`Remote::Driver` rather than a `Chrome::Driver`, correcting an earlier
claim here that the class would not change. Nothing we do needs the
Chrome subclass, and the `driven_by` block still configures Chrome
options, which the run below confirms.

**Everything else stands.** The block's `no-sandbox` and
`disable-dev-shm-usage` arguments, Rails' own `--headless`, and
`screen_size` all reach the remote browser unchanged.

### The experiment, including how it first lied

Run 2026-08-05 against `selenium/standalone-chrome:150.0.7871.124`
(digest `sha256:95690147…`) on `--network host`, to match CircleCI's
shared-localhost topology, with the container's default 64 MB
`/dev/shm`, because CircleCI gives no way to raise it.

| Run | Result |
| --- | ------ |
| Baseline, local Chrome, 22 tests | 197 assertions, 0 failures, 104.3s |
| Remote, 22 tests | 197 assertions, 0 failures, 104.1s |
| Negative control, container stopped | `Errno::ECONNREFUSED` on every test |

**The first attempt passed while proving nothing**, because the change
had been made in the `register_driver` block that Rails does not use.
The tests were quietly still driving local Chrome. What exposed it was
asking the container what it had done: `docker logs` showed **zero**
sessions created. The negative control is now the standing check, since
a configuration that cannot fail when the browser is absent is not
testing the browser.

The container log confirms the real run: one session, `browserName
chrome`, `browserVersion 150.0.7871.124`, `chromedriverVersion
150.0.7871.124`, matched by construction, with our arguments present as
`[--disable-search-engine-cho…, --headless, no-sandbox,
disable-dev-shm-usage]`. No crash, no shared-memory complaint.

Both questions this was meant to settle came out yes: **the browser
container reaches the application on localhost**, and **64 MB of
`/dev/shm` is survivable**, the latter because
`test/application_system_test_case.rb` has passed
`disable-dev-shm-usage` all along. There is no measurable time cost;
104.1s against 104.3s is noise.

### Keeping a headed browser available

Remote and headless is what CI wants; a person debugging a test wants
the opposite. Both already work, because `DRIVER` and
`SELENIUM_REMOTE_URL` are independent and all four combinations are
valid. Verified 2026-08-05, each one run:

| `DRIVER` | `SELENIUM_REMOTE_URL` | Result |
| -------- | --------------------- | ------ |
| unset | unset | local, headless. The local default |
| unset | set | remote, headless. What CI does |
| `chrome` | unset | local, headed. A window opens here |
| `chrome` | set | headed in the container, watchable over noVNC |

Rails adds `--headless` only for `:headless_chrome`, so `DRIVER=chrome`
is genuinely headed: the container log for the fourth row shows
`args: [--disable-search-engine-cho…, no-sandbox,
disable-dev-shm-usage]` with no `--headless`, and the image's noVNC
answers on port 7900.

**No new knob.** `DRIVER` already existed, is already used by
`docs/testing.md`, and adding a `HEADED` alias would be a second way to
say one thing. What was missing was accurate documentation, since
`docs/testing.md` was still describing `test/features/`, which no longer
exists, and `poltergeist`, which left the `Gemfile` long ago.

One caveat, unresolved: headed runs failed intermittently in the
development container used for this work, roughly twice in eight runs,
then five times clean in a row, and the message was never captured.
Headed mode is the only path needing a real X display, which is the
fragile part of that environment. Watch for it on a real desktop before
concluding anything.

### A green suite is not evidence, so we made it evidence

The false pass above was not a one-off risk; while the old test image
still carries a Chrome, *any* mistake in wiring up the remote browser
fails silently into a local one, and the suite goes green. CI would have
told us nothing.

So `test/system/system_test_configuration_test.rb` now carries a guard:
if `SELENIUM_REMOTE_URL` is set, the driver must actually be using it.
It asserts twice on purpose, once that we asked for the right thing and
once that asking worked, since reading `page.driver.browser` forces a
real session to exist.

It was tested by breaking the thing it guards. With the configuration
deliberately reverted to ignore `SELENIUM_REMOTE_URL`, exactly
reproducing the earlier bug, the guard failed as it should:

```text
Minitest::Assertion: Expected: "http://127.0.0.1:4444"
3 tests, 5 assertions, 1 failures, 0 errors, 0 skips
```

It skips when the variable is unset, so local work is unaffected. A
guard that has never been seen to fail is a guess.

### What went into the pipeline

* A third container in the `ruby-postgres` executor,
  `selenium/standalone-chrome:150.0.7871.124@sha256:95690147…`, and
  `SELENIUM_REMOTE_URL: http://127.0.0.1:4444` in the primary
  container's environment.
* **A readiness wait.** CircleCI starts secondary containers but does
  not wait for what is *inside* them, and the grid takes a few seconds,
  so the first system test would otherwise race the browser's startup.
  The step polls `/status` and fails loudly after 60 seconds. Both its
  patterns were checked against real output rather than guessed.
* **The `browser-tools` orb is gone**, and with it the last orb, so the
  `orbs` key no longer exists. Chrome's own container carries a matched
  chromedriver.
* `google-chrome --version` dropped from the version banner. The Chrome
  that matters is in the other container, and the wait step prints it.
  Any Chrome in the test image is not the one under test.

### The resource budget, now measured rather than assumed

`.circleci/config.yml:105` sets `resource_class: medium` on the `build`
job, and has since commit `687477ba`. That is good practice in itself:
CircleCI's reference says the default "is subject to change" and that
specifying one explicitly is preferred. The `deploy` job sets none and
so takes that changeable default.

**What `medium` actually grants was not verified.** CircleCI's docs are
rendered client-side and the figures live in a partial that could not be
retrieved, so the familiar "2 vCPU, 4 GB" is repeated here by nobody.
Rather than guess, the version-banner step now prints `nproc` and the
cgroup memory limit, which is the method CircleCI's own reference
recommends. Read those numbers from the next run before touching
`resource_class` in either direction. The block handles cgroup v1 and
v2, since v2 replaced `hierarchical_memory_limit` with `memory.max`,
and says so plainly rather than failing if neither is readable.

The budget is shared by every container in the job, and adding a
Java-plus-Chrome container made it tighter without anyone measuring it.
If the grid never becomes ready, or a container is killed, that is the
first place to look, and `large` is the first thing to try.

**A related trap, from CircleCI's own reference.** Java and other
runtimes that introspect `/proc` for CPU count "may request 32 CPU
cores and run slower than they would when requesting one core" under
resource classes. Selenium Grid is a Java program. If the grid is
mysteriously slow rather than absent, this, not memory, is the likely
cause, and the cure is to pin its thread count rather than to buy a
larger machine.

### Two dead fragments found while doing this

Neither blocks the change, and both should go in a separate cleanup.

* The whole `Capybara.register_driver :headless_chrome` block is
  unreachable from system tests, per the finding above, and nothing
  outside `test/system/` uses Capybara. Inside it,
  `driver.browser.download_path = Capybara.save_path` and
  `browser_options.binary = ENV.fetch('GOOGLE_CHROME_SHIM', nil) if
  ENV['CI']` are dead twice over: `GOOGLE_CHROME_SHIM` is a Heroku
  buildpack convention CircleCI never sets, while `CI` always is, so
  that line assigns nil on every CI run.
* Rails' `default_chrome_options` already adds `--headless` for
  `:headless_chrome`, so the block's own `--headless` is a duplicate of
  something we no longer reach.

### The orb is redundant, which is why dropping it is safe

Established 2026-08-05 by running Selenium Manager directly, the same
binary Selenium invokes:

| Situation | What it resolves |
| --------- | ---------------- |
| No `chromedriver` on `PATH` | one from `~/.cache/selenium`, downloading on a miss |
| `chromedriver` on `PATH` | the one on `PATH` |

Nothing in our code sets `driver_path`, so `DriverFinder` runs Selenium
Manager on every driver creation, and this machine has no `chromedriver`
on `PATH` at all yet holds cached drivers for Chrome 141 through 150. So
`browser-tools/install-chromedriver` is used in CI but not needed:
remove it and Selenium Manager fetches an equivalent driver from the
same place. Under this decision neither is involved, because the driver
lives in the Selenium container.

While looking: the WebMock and VCR allowances for
`chromedriver.storage.googleapis.com/LATEST_RELEASE_*`,
`googlechromelabs.github.io` and `storage.googleapis.com` in
`test/test_helper.rb` are stale. They date from the `webdrivers` gem,
which we no longer use, and they could not affect Selenium Manager in
any case, since it is a separate binary run as a subprocess and WebMock
patches Ruby HTTP libraries. Harmless, but they describe a mechanism
that no longer exists, which is worse than saying nothing.

## Keeping pins current

The organising principle, decided 2026-08-04: **the pull request list is
the set of decisions waiting for a human.** Nothing should require
anyone to remember to check whether an upgrade is available. Look at the
open pull requests, accept one, and it takes effect. That is the whole
interface.

It follows that a proposal must always be one we could actually accept.
A pull request that cannot be merged is not a decision waiting for a
human, it is a chore, and chores are what we are removing.

Four tools, distinct ground:

| Tool | Covers |
| ---- | ------ |
| Dependabot | `Gemfile`, npm, GitHub Actions workflows |
| Renovate | `.circleci/config.yml` images and orbs |
| `propose_ruby_upgrade` | `.ruby-version`, from what Heroku has |
| `prepare-image` | the test image, rebuilt when its base moves |

Renovate does **not** manage `.ruby-version`, though it can; see
[Proposing Ruby upgrades](#proposing-ruby-upgrades-heroku-can-build)
for why we took that job away from it.

**Dependabot cannot read `.circleci/config.yml`.** It has no CircleCI
support: `dependabot/dependabot-core` carries one directory per
ecosystem, 43 of them including `bundler`, `docker`, `github_actions`
and `npm_and_yarn`, and there is no `circleci` directory. Its `docker`
ecosystem reads Dockerfiles, not CI configurations.

**Nor does it update Ruby.** Not for want of Ruby knowledge: it reads
our Ruby version already, because it must, to pick gem versions that
will run. It just does not propose upgrades to it. Issue 2254, "Update
ruby version in Gemfile", asks for exactly `Gemfile`, `Gemfile.lock` and
`.ruby-version`; opened 2018-06-28, still open.

**Renovate does both.** Its `circleci` manager supports the `docker` and
`orb` datasources. Its `ruby-version` manager declares
`displayName = '.ruby-version'`, a file pattern of
`/(^|/)\.ruby-version$/`, and the Ruby version datasource, reading the
trimmed file contents as the current version. We use the first and not
the second.

Run Renovate with `enabledManagers` limited to `circleci`. At its
defaults it also reads the Gemfile, `.ruby-version` and Dockerfiles, and
competes with Dependabot and with `propose_ruby_upgrade`.

### Prerequisite: a pin must carry its own tag

**Done 2026-08-05** for all three images in `.circleci/config.yml`, and
it had to be, or Renovate would have proposed the wrong thing quietly.
Found by reading Renovate's source.

We used to write pins with the tag in a comment:

```yaml
- image: cimg/postgres@sha256:2e4f1a96… # pin :16.4
```

`splitImageParts` in Renovate's Dockerfile manager, which its `circleci`
manager calls for every image, splits on `@` and then on `:`. With no
tag in the reference itself, `depTagSplit.length === 1`, so it records a
`depName` and leaves **`currentValue` undefined**. The comment is
invisible to it. A dependency with a digest and no tag then resolves
against `latest`:

```ts
const newTag = isNonEmptyString(newValue) ? newValue : 'latest';
const newTag = newValue ?? 'latest';
```

For `cimg/postgres` that means silently crossing PostgreSQL major
versions; for our own test image it would be simply wrong.

Write the tag where a machine can read it:

```yaml
- image: cimg/postgres:16.4@sha256:2e4f1a96…
```

Renovate then updates tag and digest together, and the tag stops being
an unverifiable comment that a human has to keep in step with the digest
by hand. That is the `AGENTS.md` rule about preferring automated
prevention to documentation, applied to a comment that had been the sole
record of what a digest means.

**The pair is self-checking, which is the part worth knowing.** Verified
2026-08-05: `docker manifest inspect` on an existing tag paired with
another tag's digest fails with `manifest verification failed`, while
each correct pair resolves. So a tag and digest that drift apart become
an error rather than a silent disagreement, which the old comment form
could never manage.

Before converting, each comment was checked against the registry rather
than trusted: all three tags resolved to exactly the digest already
pinned beside them, so nothing was encoded that was not already true.

**Scope, deliberately.** Only `.circleci/config.yml`, because that is
what Renovate's `circleci` manager reads. GitHub Actions workflows keep
`uses: owner/repo@sha  # vX.Y.Z`, which is that ecosystem's own
convention and which Dependabot parses, comment and all. Do not
"harmonise" them.

`dockerfiles/how-to-create-image.md` was updated at the same time, since
otherwise following it would reintroduce exactly the format just
removed. That file is slated for deletion at step 5 regardless.

This is worth doing on its own, ahead of everything else here, and it
covers `cimg/postgres`, `cimg/node`, the Selenium image and the new test
image.
Renovate's `custom` manager, a regular expression matcher, covers
anything version-like we later pin in a file no built-in manager knows.

A worry raised and settled: our `Gemfile` says
`ruby File.read('.ruby-version').strip`, which Bundler evaluates but a
static parser might not, and Dependabot issue 14617 concerns exactly
that. It is not biting. Dependabot will not propose a version whose Ruby
requirement it thinks we cannot meet, and it offered `bootstrap_form`
5.6.1 and merged a `simplecov` bump, both requiring `ruby >= 3.2`. What
that cannot show is whether it resolves exactly 3.4.1 or merely
"at least 3.2", since nothing in our tree requires 3.3 or 3.4. Read
Dependabot's job logs only if an update ever looks unexpectedly held
back.

### Due diligence on Renovate

`renovatebot/renovate`, started 2016-12-17, **AGPL-3.0-only**, backed by
Mend.io; the `renovatebot` GitHub organisation gives its location as
Israel and its contact as `renovate@mend.io`. It exists as a hosted
GitHub App and as the same open source program run yourself, via npm, a
container image, or `renovatebot/github-action`. **Self-host it.**
Updating our own CI configuration is no reason to give a third party
access to this repository.

Evidence, 2026-08-04: OpenSSF Scorecard **6.7**, scoring 10 on
Contributors, CI-Tests, License, SAST, Binary-Artifacts,
Security-Policy, Maintained, Dangerous-Workflow, Dependency-Update-Tool
and Code-Review, and 8 on Branch-Protection; npm releases carry **SLSA
provenance v1** attestations; last commit and latest npm release both
that day; 22,171 stars and about 350,000 npm downloads a week.

Weaknesses, because a one-sided assessment is not an assessment:
Token-Permissions 0, Signed-Releases 0, Fuzzing 0, and Vulnerabilities
0, the last meaning known unfixed vulnerabilities were found, which for
a large Node project usually means transitive advisories. We have not
checked which. Its score on our own badge is 2.

**The threat model is smaller than it looks.** Renovate would have no
ability to change or deploy code. It proposes; a human reviews and
merges. That is the same power any stranger has, since anyone may fork
and open a pull request, and we already rely on review plus CI for that.
A bot doing it on a schedule is not a new category of trust, only a more
punctual contributor.

That holds only while its proposals get the same scrutiny as anyone
else's, so:

* Grant `contents: write` and `pull-requests: write`, nothing else.
* **Not** `workflows: write`. Scoped to `circleci` and `ruby-version` it
  has no business under `.github/workflows/`, and withholding it means
  it cannot alter our GitHub Actions.
* Keep branch protection on `staging` and `production`. Those are the
  branches the deploy job runs from, so protecting them is what makes
  "it cannot deploy" true rather than intended.
* **Do not use the default `GITHUB_TOKEN`.** GitHub does not start
  workflow runs for events raised by that token. Our `brakeman`,
  `codeql`, `codespell` and `main` workflows all trigger on
  `pull_request`, so a Renovate pull request opened with it would skip
  all four and be checked *less* than a stranger's. Use a dedicated
  GitHub App installation token or a fine-grained personal access token
  with the two permissions above. CircleCI is unaffected either way,
  since it triggers from its own integration.

## Proposing Ruby upgrades Heroku can build

Decided 2026-08-04, after finding that Renovate cannot be made safe for
this job.

**The problem.** Renovate's Ruby datasource is ruby-lang.org, which
announces a release the day it happens. Heroku builds its own binary
some unknown time later. So Renovate would open a pull request we cannot
merge, the deployability guard below would correctly turn it red, and it
would sit there. Red pull requests that are merely early are worse than
useless: they teach people to disregard red, and they turn the pull
request list into a to-do list of things to keep re-checking, which is
exactly the habit we are trying to retire.

**No list exists, and this is not an oversight.** Checked by reading
Heroku's own buildpack, 2026-08-04.
`lib/language_pack/helpers/download_presence.rb` and
`outdated_ruby_version.rb` discover what exists by **issuing `HEAD`
requests against S3 for versions they guess**. `OutdatedRubyVersion`
carries `DEFAULT_RANGE = 1..5`: from the current version it probes the
next five patch releases in parallel, and if the last of them exists it
enqueues a further range and keeps going. It probes upward across minor
lines the same way. That is how our staging deploy knew to suggest
3.4.10.

`DownloadPresence` declares
`STACKS = ["heroku-22", "heroku-24", "heroku-26"]` above the comment
that those three "have identical ruby versions supported", which is
useful: our stack upgrade will not narrow what Ruby we may run.

The devcenter reference page lists supported versions in prose, 3.3.12,
3.4.10 and 4.0.6 as of 2026-08-04, but not per stack and not
machine-readably. So probing is not a workaround for a missing API; it
is the only method available, and it is what the vendor does.

**The design: propose only what exists.** A scheduled job,
`propose_ruby_upgrade`, probes forward exactly as Heroku does, and opens
a pull request bumping `.ruby-version` to what it finds. It cannot
propose an undeployable version, so there is nothing to retry, and the
schedule *is* the retry: a Heroku lag means "no pull request this week,
a pull request next week", silently and with nothing red.

* **Probe every line above ours, not just our own patch line.** A move
  from 3.4 to 3.5, or to 4.0, is a decision we want *offered*. Offering
  it is not committing to it. The point of the pull request list is that
  choices arrive on their own and wait to be judged.
* **One pull request per line**, so accepting the routine patch bump
  does not require an opinion about the major upgrade sitting beside it.
* **Share the probe with the guard test below.** One piece of code that
  answers "does Heroku have this Ruby for this stack", two callers.
* A dead cron here leaves us stale, not wrong. That is why this may be
  scheduled although the caching check in `prepare-image` may not: the
  guard, not the cron, is what keeps an undeployable pin out.
* **It opens pull requests, so the token analysis written for Renovate
  applies to it unchanged**: `contents: write` and
  `pull-requests: write`, never `workflows: write`, and **not** the
  default `GITHUB_TOKEN`, or its pull requests would start none of our
  `pull_request` workflows and be checked less than a stranger's.
* Being `lib/` code, it falls under the 100% coverage rule. Unit-test
  the probe with stubbed HTTP; see the guard below, which shares it.

## Guard: Ruby pins must stay deployable

Only Ruby versions Heroku offers for our stack will deploy, so a pull
request proposing a newer one, from `propose_ruby_upgrade` or from a
human editing the file by hand, could pass CI and fail at deploy. Guard
it in CI.

The check reads `.ruby-version`, issues one `HEAD` for the corresponding
tarball, and fails unless the answer is **200**.

**It must not be a Minitest test.** `test/test_helper.rb:58` calls
`WebMock.disable_net_connect!(allow_localhost: true, allow: driver_urls)`,
so the suite is hermetic on purpose and a real request to S3 would be
refused. Worse, that refusal is not a network error, so any
"skip when the network is unavailable" logic would read it as an offline
developer, skip silently, and go on skipping forever. A guard that never
guards is more dangerous than no guard, because it is also reassuring.

So make it a **rake task that CI runs**, one that needs no Rails and
therefore lives in `lib/tasks/standalone/`; see [Deploying without a
development environment](#deploying-without-a-development-environment).
There the skip is honest, because a real connection failure is a real
connection failure. Skip when offline so local work is unaffected; CI
has a network, and CI is where it matters.

* **Compare the exact version.** It answers precisely the question we
  care about, with no version arithmetic. Looser schemes, such as
  accepting any patch within our X.Y series, need the bucket listed
  rather than probed, which is not permitted, and answer a weaker
  question.
* **Read the stack name from the same constant the image build uses**,
  so a stack upgrade cannot change one and forget the other.
* **Assert "must be 200"**, never "must not be 404", for the S3 reason
  above.
* **The probe itself is ordinary `lib/` code** shared with
  `propose_ruby_upgrade`, so it falls under the 100% coverage rule.
  Unit-test it with stubbed HTTP covering 200, 403 and a connection
  failure. The rake task is the thin part that CI runs live.

Because `.ruby-version` is also an input to the test image, a pull
request bumping it changes the cache key, so `prepare-image` builds an
image for that Ruby and the tests genuinely run on it.

## Deploying without a development environment

Investigated 2026-08-04. `rake deploy_staging` and `rake deploy_production`
currently require a working development environment. Nothing they do
needs one; the requirement is an accident of how Rake starts.

### Every rake task boots the whole application

`Rakefile:7` reads:

```ruby
require File.expand_path('config/application', __dir__)
```

`config/application.rb` then does `require 'rails/all'` and
`Bundler.require(*Rails.groups)`, so **every** invocation of `rake`, for
any task, loads every gem in the `Gemfile` including the test-only ones.
Measured: `rake -T` takes **4.7 seconds**, and it cannot run at all
unless the full bundle is installed at the right Ruby. That, and not
anything about deploying, is why deploying needs a development
environment.

It is not that the tasks need the application. `deploy_production` is
pure git, with no Heroku credential of any kind:

```text
git checkout production && git pull &&
  git merge --ff-only origin/staging && git push && git checkout main
```

`deploy_staging` is the same fast-forward from `origin/main`, preceded
by `production_to_staging`, which is two `heroku` CLI calls.

### The fix: boot only when the requested task needs it

Rake sets `Rake.application.top_level_tasks` from the command line
*before* it loads the `Rakefile`, so the `Rakefile` can see what was
asked for and decide. Put the tasks that need no application in
`lib/tasks/standalone/`, load those first, and boot only if something
unrecognised was requested:

```ruby
Dir.glob(File.expand_path('lib/tasks/standalone/*.rake', __dir__))
   .sort.each { |f| load f }

wanted = Rake.application.top_level_tasks.map { |t| t.split('[').first }
unless wanted.all? { |t| Rake::Task.task_defined?(t) }
  require File.expand_path('config/application', __dir__)
  Rails.application.load_tasks
end
```

Verified as a working prototype 2026-08-04, including the cases that
matter: `rake deploy_production` skips the boot; `rake` with no
arguments, `rake -T` and any unknown task still boot, because Rake
substitutes `default` when no task is named, and `default` is not a
standalone task. `rake foo[bar]` is why the name is split on `[`.

**Use `lib/tasks/standalone/`, not `rakelib/`.** Rake auto-imports
`rakelib/*.rake`, but *after* the `Rakefile`, so the names are not
defined in time to test. Loading them explicitly as well defines every
task twice, and a task defined twice runs both bodies. The first
prototype did exactly that and deployed twice in one command.

The set of tasks that skip the boot is then expressed by which directory
a file sits in, with no list to maintain. Add a test asserting that no
standalone task shares a name with a task from the full set, so a
shadowed name cannot silently skip the application it needed.

### Move the database refresh into the deploy job

Decided 2026-08-05, and it does more than tidy up.

`production_to_staging` exists in the `Rakefile` only because that is
where someone happened to put it. It is work done *to* staging as part
of deploying to staging, and the job that deploys to staging already
holds the credential to do it. Move it there, gated on the branch:

```text
maintenance:on
  restore production's latest backup over staging   <- staging only
  git push heroku staging:master
  heroku run -- rails db:migrate
maintenance:off
```

**Restore before the code push, and migrate after.** Then the one
migration that runs is the new code's migrations against production's
schema, which is what staging is *for*. Today's order runs migrations
twice: once from `production_to_staging` against the code staging is
still running, which achieves nothing, and once from CircleCI after the
push, which is the one that matters.

What this removes, which is the point:

* **`HEROKU_API_KEY` never has to reach GitHub.** The staging button and
  the production button become the same operation, advancing a branch,
  and neither touches Heroku. The credential stays in the one place it
  already lives, held by the one job that already has it.
* **`production_to_staging` leaves the `Rakefile`.** `deploy_staging`
  and `deploy_production` are then the same five git commands differing
  only in the source branch, so they collapse into one parameterised
  task.
* **The deploy tasks stop needing the `heroku` CLI at all.** The local
  path needs only `git`, which is a stronger result than this section
  set out to get.
* **The fire-and-forget migration goes away**, because the surviving
  migration is CircleCI's existing blocking `heroku run`. That was the
  first of the four cautions below and it no longer applies.
* **The restore stops running against a live site.** Today it happens
  before anything enters maintenance mode. In the deploy job it lands
  after `maintenance:on`, which is strictly better.

Three consequences to accept deliberately, none of them objections:

1. **Every push to `staging` now refreshes the database**, not only the
   ones made through the task. That is what staging is for, but it does
   mean you can no longer test a migration against staging's accumulated
   state without doing the restore by hand.
2. **Re-running the staging deploy job becomes destructive.** Today
   re-running it is safe; afterwards it wipes staging and restores
   production. Reasonable for staging, but it changes what a familiar
   button does, so say so where people will read it.
3. **Verify that `pg:backups:restore` survives the running dyno.**
   Maintenance mode stops web traffic but the dyno keeps running, and
   solid_queue runs inside Puma, so connections stay open. Check whether
   the restore terminates them or fails; do not pre-emptively add a
   `ps:scale web=0` that may not be needed.

**Hardcode both application names in the restore step.** The
surrounding job derives `HEROKU_APP` from `$CIRCLE_BRANCH`, but the
restore's source and target are constants, production to staging. Write
them as constants, so that no branch name can ever redirect a restore,
and let the existing branch allowlist be the second lock rather than the
only one.

Checked, not assumed: `heroku pg:backups` runs with no plugins
installed on CLI 11.8.1, the version the `deploy` job pins, so the
`deploy-only` executor needs nothing added.

### Then the deploy can be a button

With the tasks free of Rails, and free of Heroku, a `workflow_dispatch`
GitHub Actions workflow with a `target` input can call exactly the same
code, so there is one implementation and two ways to run it, and the
local path still works when GitHub does not.

Both buttons now need **no Heroku credential at all**. What they need is
the right to push to the protected `staging` and `production` branches:
a GitHub App token listed as a bypass actor on exactly those two
branches, not a broadly privileged `GITHUB_TOKEN`. Authorisation is
GitHub Environments with required reviewers, one per target, which now
guard an action rather than a secret. That the push starts no
GitHub-side workflow does not matter here, because CircleCI triggers
from its own integration.

The remaining cautions, reduced from four to two by the move above:

1. **`--confirm staging-bestpractices` stops being a safety check** once
   it is a constant in a job rather than something a human types. The
   protection moves to the branch allowlist in the deploy job and to who
   may push to `staging`, which is enforced where the key actually is.
2. **The restore uses production's latest *existing* backup**, which is
   deliberate, so as not to disturb production, and means staging can
   come up with data up to a day old. The button should say so.

## Pinning Node for the production build

The fix for finding 5, in two halves. Checked 2026-08-04.

**The repository half, done.** A root `package.json` whose only
substantive content is `engines.node`, pinned to an exact **24.19.0**.
That is the newest release of the 24 line, which is the current LTS, and
it is the version the `deploy` job's `cimg/node` image already carries,
so the Node that minifies our JavaScript and the Node that runs the
Heroku CLI are now the same. Heroku publishes it: the buildpack's
`inventory/node.toml` at release `v361`, published 2026-08-03, lists
24.19.0 with a SHA-256 and fetches it from `nodejs.org`.

We pin the exact version rather than the `24.x` range Heroku's README
suggests. A range is the problem restated: the build changes and nobody
decided it should.

There is no `package-lock.json`, because there is nothing to lock. The
buildpack reads `package-lock.json` only to choose between `npm ci` and
`npm install`, and takes the latter without complaint.

**The application half, not done.** `heroku/nodejs` must be configured
on both applications, between the mimalloc buildpack and `heroku/ruby`:

```text
heroku buildpacks:add --index 2 heroku/nodejs --app staging-bestpractices
```

Until then this pin does nothing. `heroku/ruby` does not read
`engines.node`; it installs a Node of its own whenever it sees `execjs`
in `Gemfile.lock`, which it does.

**Order matters, and getting it wrong rejects a deploy.**
`heroku/nodejs` `bin/detect` *requires* `package.json` in the root, and a
classic buildpack whose detect fails fails the whole build. So the
`package.json` must reach the application first, and only then may the
buildpack be added. Deploy, add, deploy again, and read the second
build's log to confirm it reports 24.19.0.

**Consequence for the new test image.** `license_finder` activates its
NPM scanner on the presence of `package.json`, so it now shells out to
`npm`. It passes here, having nothing to find, but the new test image
must carry Node and npm or that check breaks. It should carry *this*
Node; see [The image](#the-image).

## The plan

1. **Pin Node for the production build** (finding 5). Independent,
   cheap, and the only finding that can break a deploy. Add the
   `heroku/nodejs` buildpack ahead of `heroku/ruby` and pin the version.
   See [Pinning Node](#pinning-node-for-the-production-build); the
   repository half is done.
2. **Check that `heroku/heroku:24-build` has `libpq`, its headers and a
   C toolchain**, before writing anything that depends on the answer.
3. **Add the `Dockerfile` and the `prepare-image` job together, leaving
   the `build` job on the old image.** `prepare-image` then builds and
   publishes on the very first pipeline, so the image exists, has been
   produced by the mechanism that will keep producing it, and can be
   pulled and tried, with nothing yet depending on it. This replaces an
   earlier plan to build one by hand first: there is no reason to
   bootstrap with a procedure we are trying to abolish.
4. **Point the `build` job at `badgeapp-test:current`.** A one-line
   change, and the first pipeline whose tests genuinely run on the new
   image. Keep it a separate pull request so a failure here cannot be
   confused with a failure in step 3.
5. **Delete `dockerfiles/3.4.1-browsers/`, `dockerfiles/3.3.6-browsers/`
   and `how-to-create-image.md`** once nothing references them. Leave
   the DockerHub image itself in place for a while: branches and open
   pull requests older than step 4 still pin it by digest, and deleting
   it breaks their pipelines for no gain.
6. **Add the Heroku-availability probe and the guard** that uses it, so
   step 7 cannot silently regress.
7. **Take Ruby to 3.4.10** (finding 3), which under this design is a
   one-line change plus an automatic rebuild.
8. **Add `propose_ruby_upgrade`**, sharing the probe from step 6, so
   nobody has to remember to look.
9. **Add Renovate**, self-hosted, scoped to `circleci` and permissioned
   as above.
10. **Then upgrade production to Heroku-26**, test environment first, so
    the stack move is exercised somewhere before it reaches production.

Independent of the above, and in no particular order with it:

11. **Move the staging database refresh into the CircleCI deploy job**,
    which takes Heroku out of the deploy tasks altogether.
12. **Stop booting Rails for every rake task**, then make the deploys a
    `workflow_dispatch` button. See [Deploying without a development
    environment](#deploying-without-a-development-environment).

Prerequisite: [a pin must carry its own
tag](#prerequisite-a-pin-must-carry-its-own-tag) is done, ahead of
the rest, because Renovate proposes the wrong upgrades without it.

[Chrome: a second container](#chrome-a-second-container) is done,
ahead of step 3, against the old image as a known-good baseline.

Findings 1, 2 and 4 have no separate step: steps 2 to 5 remove their
cause.

## Facts worth not re-deriving

* Production stack: **Heroku-24** (Ubuntu 24.04); Heroku-26 available.
* Production Ruby: from `.ruby-version`, currently **3.4.1**; Heroku
  reports 3.4.10 available.
* Deploy is `git push heroku`, no `heroku.yml` or `app.json`, so Heroku
  builds the slug; our images never run in production.
* Migrations are not automatic on deploy: the CircleCI `deploy` job runs
  `heroku run -- bundle exec rails db:migrate`.
* `cimg/ruby` 3.4 is Ubuntu 22.04; 4.0 is 24.04.
* `heroku/heroku:24`, `:26`, `:24-build`, `:26-build` all exist and are
  rebuilt regularly.
* Heroku Ruby tarballs: `heroku-24/amd64/ruby-X.Y.Z.tgz`,
  `heroku-22/ruby-X.Y.Z.tgz`, under the S3 host named above.
* There is **no list** of the Ruby versions Heroku has, for anyone.
  Heroku's own buildpack probes with `HEAD` requests, guessing versions.
  heroku-22, heroku-24 and heroku-26 support the same set, per the
  comment on `DownloadPresence::STACKS`.
* Buildpacks on both applications, in order:
  `deadmanssnitch/buildpack-mimalloc`, then `heroku/ruby`. `heroku/ruby`
  installs a Node of its own because `execjs` is in `Gemfile.lock`.
* `Rakefile:7` requires `config/application`, so *every* rake task loads
  every gem. `rake -T` costs 4.7 seconds and needs the full bundle.
* `deploy_production` uses no Heroku credential; it is git only.
  `deploy_staging` also runs `production_to_staging`, which restores
  production's latest *existing* backup over staging. That restore is
  moving into the CircleCI deploy job, after which neither task touches
  Heroku.
* `heroku pg:backups` and `pg:backups:restore` are core CLI commands,
  needing no plugin install, on CLI 11.8.1.
* A CircleCI job's executor image must come from a registry. Its cache
  cannot supply one, because `restore_cache` is a step and steps run
  inside the executor that is already running.
* `test/test_helper.rb:58` calls `WebMock.disable_net_connect!`, so no
  Minitest test may reach the network. Live checks belong in rake tasks.
* The test image lives at `ghcr.io`, public, under the `ossf`
  organisation.
* CircleCI docs are rendered client-side, so plain `curl` returns
  navigation rather than content. Two things were therefore *not*
  verified and should be before use: how parameterized executors behave
  in this situation, and what Docker layer caching costs on our plan.
