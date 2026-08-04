# Build environment staleness

This document records four problems with the environments we build and
test in, found on 2026-08-03 and 2026-08-04 while chasing an error in
CircleCI, together with the evidence for each and the options for fixing
them.

Three of the four are the same problem wearing different hats: our
CircleCI test image is frozen, and the procedure for updating it is
manual enough that it does not get done. The fourth is unrelated and is
arguably the most urgent: the production build installs an unpinned
Node.

## Where this stands

Nothing here is fixed yet. Two related items already are, on branch
`apt-get-update` (merged, and deployed to staging on 2026-08-04):

* The `apt-get update` step in the CircleCI `build` job is commented
  out. It served no purpose and printed an error on every build. See
  [Finding 1](#finding-1-a-frozen-image-freezes-its-trust-anchors-too).
* The `deploy` job has its own browser-free image,
  `cimg/node:24.19.0`, instead of sharing the test image. That job holds
  `HEROKU_API_KEY` and can push to production, so it should carry as
  little as possible. It also bumped the Heroku CLI to 11.8.1, because
  10.17.0 declared `engines: node 20.x` and Node 20 is end of life.

## Finding 1: a frozen image freezes its trust anchors too

`sudo apt-get update` in the `build` job failed on every run:

```text
Err:5 https://dl.google.com/linux/chrome/deb stable InRelease
  The following signatures couldn't be verified because the public key
  is not available: NO_PUBKEY FD533C07C264648F
```

The cause is exact, and it is nobody's mistake:

| What | When |
| ---- | ---- |
| `cimg/ruby:3.4.1-browsers` (our base) built | 2025-01-06 14:20:58Z |
| Google created signing subkey `FD533C07C264648F` | 2025-01-07 |

The base image was built the day before the key existed, so its copy of
Google's keyring cannot contain it. Today's `InRelease`, signed
2026-08-04, verifies as `using RSA key
0E225917414670F4442C250DFD533C07C264648F`.

Pinning by digest froze the image, and the keyring came along with it.
That is pinning working as designed, not failing.

**The general lesson, which outlives this particular repository.** Two
different things want pinning, at different layers:

* **Artifacts** (images, actions, gems, CLIs) pin by **digest**.
  Identity is the content, and freshness comes from a deliberate bump.
* **Trust anchors** (signing keys) pin by **fingerprint**, and fetch the
  material fresh. Identity is the long-lived master key; the material
  must rotate.

Google's master key `EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796` was
created 2016-04-12 and has no expiry. Under it are eight signing
subkeys, rotated roughly annually; the newest, `1D09C015006FEAB8`, was
created 2026-03-10 and is not yet in use. Pinning that fingerprint would
be a stronger claim than freezing a keyring, and would not rot.

We did not need to do any of that here, because nothing in the job uses
apt. Checked, not assumed: there is no `apt-get install` anywhere in
`.circleci/config.yml`; `browser-tools/install-chromedriver` fetches
chromedriver with `curl` and only apt-installs on yum-based systems; and
nothing `rake default` runs touches apt. The step is commented out with
that reasoning recorded beside it.

The finding still matters, because rebuilding the image will hit the
same error: `dockerfiles/3.4.1-browsers/Dockerfile:31` runs
`sudo apt-get update && sudo apt-get install -y cmake shared-mime-info`.
Rebuilding our layer against the same frozen base changes nothing about
the key. The base digest has to move too.

## Finding 2: the test image is nineteen months old

`.circleci/config.yml` pins `drdavidawheeler/cii-bestpractices` by
digest; that pin was introduced in commit `816568f1` on 2025-10-24 and
has not changed. It is built `FROM cimg/ruby@sha256:a0b57bca…`, built
2025-01-06.

So the environment our tests run in has had no operating system updates
for nineteen months. The stale Google key is the visible symptom; the
invisible one is every unpatched package in that image.

This is not a production exposure. Staging and production do not run our
Docker images at all: the deploy is `git push heroku`, and Heroku builds
a slug with its own Ruby buildpack. Our images are used only by
CircleCI.

**The real problem is the procedure, not the age.**
`dockerfiles/how-to-create-image.md` describes seven manual steps: get
the base SHA-256, write the Dockerfile, build, test, push to DockerHub,
update `.circleci/config.yml`, commit and test. It needs DockerHub push
access to a personal account. Anything that manual will be out of date
most of the time, so "rebuild it" is not a fix, only a reprieve.

## Finding 3: Ruby is nine patch releases behind

From the staging deploy of 2026-08-04:

```text
###### WARNING:
       There is a more recent Ruby version available for you to use:
       3.4.10
       The latest version will include security and bug fixes.
```

`.ruby-version` says 3.4.1, and the `Gemfile` reads that file, so it
governs both production and the test image.

This is the same problem as Finding 2 rather than a separate one:
upgrading Ruby means rebuilding the test image, which is the manual
procedure above. The two staleness problems are locked together.

## Finding 4: CircleCI tests on a different Ubuntu than production runs

Production and staging build on the **Heroku-24** stack, which is Ubuntu
24.04. Our test image is Ubuntu 22.04; the apt output above shows
`jammy` throughout.

So we test on one Ubuntu release and run on another. That is the kind of
gap that produces "worked in CI, failed in production" for anything
touching native extensions or system libraries.

The deploy job now happens to match production, because
`cimg/node:24.19.0` is Ubuntu 24.04 based (it reports OpenSSL 3.0.13,
where 22.04 ships 3.0.2). That was a side effect of choosing a
browser-free image, not a decision.

Heroku also reports that Heroku-26 is available, so the gap will widen
if the stack is upgraded before the test image is. Upgrading production
to Heroku-26 while CI stays where it is would put two LTS releases
between them.

**This gap cannot be closed with a stock CircleCI image while we are on
Ruby 3.4.** CircleCI pins an operating system per Ruby line, not per
image tag:

| cimg-ruby line | Base | Ubuntu |
| -------------- | ---- | ------ |
| 3.4 | `cimg/base:2026.03-22.04` | 22.04 |
| 4.0 | `cimg/base:2026.03` | 24.04 |

`cimg/base:2026.03` and `cimg/base:2026.03-24.04` have the same digest,
`sha256:fdfacc6c…`, so the unsuffixed tag is the 24.04 one. Every
`cimg/ruby:3.4.x` image, current or not, is Ubuntu 22.04 and will stay
that way. Ruby 4.0 is where CircleCI moved to 24.04, and nothing they
publish is on 26.04 at all.

So "use a current stock image" fixes the age of our test environment
without touching the operating system it runs.

## Finding 5: the production build installs an unpinned Node

This one is unrelated to the image, and is the one to fix first.

From the same staging deploy:

```text
###### WARNING:
       Default version of Node.js changed (20.9.0 to 24.13.0)

###### WARNING:
       Installing a default version (24.13.0) of Node.js.
       This version is not pinned and can change over time, causing
       unexpected failures.
```

Node is not incidental to the build. `Gemfile:135` has
`gem 'terser'`, which minifies JavaScript through ExecJS, and ExecJS
uses Node. The deploy runs `rake assets:precompile`, which completed in
7.54 seconds. So JavaScript minification for production silently moved
four major versions, from Node 20.9.0 to 24.13.0.

It worked this time. By Heroku's own warning it can change again at any
time, and the failure would land in the middle of a deploy, with the
tier in maintenance mode.

The contrast with the rest of our practice is the point. We pin CircleCI
images by digest, the Codecov CLI by SHA-256, and the Heroku CLI by
SHA-512, and then let the platform install whatever Node it likes into
the production build. There is no `package.json` and no `.node-version`
in the repository, so nothing constrains it.

Heroku's recommended fix is to place the `heroku/nodejs` buildpack ahead
of `heroku/ruby` and pin the version there. See
<https://devcenter.heroku.com/articles/ruby-support-reference#node-js-and-yarn-support>.

## How these relate

| Finding | Root cause |
| ------- | ---------- |
| 1. Stale Google apt key | test image frozen at 2025-01-06 |
| 2. Nineteen-month-old image | updating it is a seven-step manual process |
| 3. Ruby 3.4.1 vs 3.4.10 | upgrading Ruby requires rebuilding that image |
| 4. CI on 22.04, production on 24.04 | same |
| 5. Unpinned Node in production build | independent; nothing to do with the image |

Findings 1 to 4 are one problem. Rebuilding the image fixes them for a
while and then they return, because the procedure is the thing that is
broken. Finding 5 is separate, cheaper, and touches production.

## Options

### For finding 5, the unpinned Node

1. **Add the `heroku/nodejs` buildpack ahead of `heroku/ruby`, and pin
   the Node version.** Heroku's own recommendation. Needs a
   `package.json` with an `engines.node` field, or a `.node-version`
   file. Cheap, independent of everything else, and closes an unpinned
   dependency in the production build path.
2. **Do nothing and accept the risk.** Defensible only if we decide
   asset compilation is insensitive to the Node major version, which we
   have no evidence for either way.

Option 1, and soon. It is the only finding here that can break a
production deploy.

### For findings 1 to 4, the test image

What we want from the test environment, stated plainly, because these
pull against each other:

* Updating it must not be a manual chore. A manual chore does not get
  done, which is how we arrived here.
* It must carry a browser and whatever else the tests need, none of
  which production has.
* Tests must not get slower. Building an image during a test run trades
  one problem for a worse one.
* It should resemble production as closely as practical, and stay
  resembling it when we move production's Ruby or stack.

#### First: our custom image no longer adds anything

Everything `dockerfiles/3.4.1-browsers/Dockerfile` puts on top of
`cimg/ruby:3.4.1-browsers` is redundant or obsolete:

| What it adds | Why it is not needed |
| ------------ | -------------------- |
| `cmake` | already installed by `cimg/base`, in both 22.04 and 24.04 |
| `shared-mime-info` | the comment says it is "for gem mimemagic"; we do not use mimemagic. `Gemfile.lock` has `marcel (1.2.1)`, which carries its MIME data internally |
| Bundler 2.7 | `.circleci/config.yml` already installs the version named in `Gemfile.lock`, overriding whatever the image ships |

So the custom image, the DockerHub account it lives in, the seven-step
procedure, and the whole class of problems in findings 1 to 4 exist to
deliver nothing. That reframes the choice: this is not "how do we keep
our image fresh" but "why do we have one".

#### Approach A: use a stock image, pinned, and automate the bump

Point `.circleci/config.yml` at `cimg/ruby:<ruby>-browsers` by digest,
and delete `dockerfiles/`.

* **Pro.** No image to build, so the manual procedure disappears
  entirely rather than being automated.
* **Pro.** No effect on test time. CircleCI pulls a prebuilt image
  either way, and a widely used stock image is more likely to be warm
  on their infrastructure than a personal one.
* **Pro.** Keeps the browser, because the `-browsers` variant has it.
  Nothing has to change about how system tests run.
* **Pro.** Tracking `.ruby-version` becomes a one-line digest change,
  which is what makes keeping test and production in step realistic.
  `cimg/ruby:3.4.10-browsers` already exists, built 2026-06-30.
* **Pro.** Still fully pinned, so the Scorecard and SLSA position is
  unchanged.
* **Con.** We are trusting CircleCI's image contents rather than our
  own. That was already true; ours is three redundant lines on top of
  theirs.
* **Con.** If we ever need a package again, we need somewhere to put
  it. See approach B.

For the automation half, this approach depends entirely on a bot being
able to bump a digest inside `.circleci/config.yml`, which Dependabot
cannot do. See
[Keeping the remaining pins current](#keeping-the-remaining-pins-current-renovate-not-dependabot).

#### Approach B: keep a custom image, but build it automatically

If we do need extra packages, do not build the image by hand. A
scheduled workflow rebuilds from the current base, pushes to a registry,
and opens a pull request with the new digest.

* **Pro.** Keeps the option of extra packages.
* **Pro.** Rebuilds pick up base security updates on a cadence rather
  than when someone remembers.
* **Con.** Everything approach A deletes, we keep: a registry, push
  credentials, a Dockerfile, and a pipeline that can itself break.
* **Con.** Solves a problem we do not currently have, since the image
  adds nothing.

Worth designing only if approach A turns out to be impossible.

#### Approach C: run the browser as a separate container

CircleCI jobs can declare several images. Keep a plain `cimg/ruby` as
the primary and add `selenium/standalone-chrome` alongside it, with
Capybara driving the remote browser.

* **Pro.** The browser stops being a property of the Ruby image, so
  each updates on its own schedule.
* **Pro.** The primary image gets smaller, which helps pull time.
* **Con.** Capybara has to be reconfigured for a remote driver, and the
  application under test must be reachable from the browser container.
  Our system tests are a large part of the suite, so a mistake here is
  expensive.
* **Con.** Solves a coupling that is not currently hurting us.

Reasonable later; not the first move.

#### Approach D: build on the same stack image production uses

Build the test image `FROM heroku/heroku:24-build` (or `26-build` when
production moves), and install Ruby, Chrome, and chromedriver on it.
Rebuild it automatically, as in approach B.

Heroku publishes and maintains these images. `heroku/heroku:24`, `:26`,
and both `-build` variants exist and were last rebuilt 2026-07-29, so
they are not an abandoned artifact we would be pinning to.

* **Pro.** It is the only approach that closes finding 4. The test
  environment is the same distribution, the same system libraries, and
  the same OpenSSL as production, which is where "worked in CI, failed
  in production" actually comes from.
* **Pro.** It tracks production. Moving to Heroku-26 becomes a one-line
  change to the Dockerfile plus an automated rebuild, instead of
  waiting for someone else to publish an image we can use.
* **Pro.** It decouples our Ruby version from CircleCI's choices. We
  are not stuck on Ubuntu 22.04 merely because we are on Ruby 3.4.
* **Con.** It is a custom image, which is the thing we are trying to
  stop maintaining by hand. Only worth doing together with the
  automation in approach B; hand-built, it recreates this document.
* **Con.** More to install than a stock image gives us: Ruby, Chrome,
  and chromedriver, plus whatever the browser needs. That is a real
  amount of Dockerfile to get right once.
* **Con.** Our Ruby would not be Heroku's exact binary. Heroku's
  buildpack fetches prebuilt Ruby tarballs that are not publicly
  readable; the obvious S3 paths return HTTP 403. We would build or
  install Ruby ourselves. The operating system and its libraries would
  match, which is the part that matters for native extensions; the Ruby
  build itself would not be byte-identical.

#### Making approach D automatic: build in the pipeline, cache on the base

The objection to a custom image is the manual build, not the image. If
the pipeline builds it, and almost never actually has to, the objection
goes away. That is achievable, and the design turns on one choice.

**Key the cache on the base image's current digest.** Resolve what
`heroku/heroku:24-build` points at right now, and combine that with a
hash of our Dockerfile and the contents of `.ruby-version`. Use the
result as the tag of the image we push:

```text
badgeapp-test:<base-digest>-<dockerfile-hash>-<ruby-version>
```

**Check in the pipeline, not on a schedule.** Decided 2026-08-04. An
earlier draft proposed a scheduled job as the only thing that builds,
so that ordinary pipelines did no extra work at all. That was rejected,
and rightly: correctness that depends on somebody noticing a broken
cron job is not correctness. Baking the check into the pipeline that
builds and tests means the image always matches the inputs, on every
branch, with no window in which it does not, and a pull request that
edits the Dockerfile is tested with the image it just described.

The shape is two jobs in one workflow, on the same commit:

```text
prepare-image  ->  build (tests)
```

`prepare-image` decides whether anything needs building.
`build` runs the tests in the resulting image, at ordinary Docker
executor speed.

Two jobs rather than one because **a CircleCI job cannot run inside an
image it just built**. The executor's image is resolved from static
configuration when the job starts, so the container is already running
by the time any step could build a replacement. The alternative, a
machine executor that builds or pulls the image and runs the tests in a
container it controls, avoids the second job but makes every pipeline
pay machine-executor startup instead of Docker-executor startup, which
is the more expensive of the two.

**Guard the startup so the hit path does almost nothing.** A job is a
fresh container, so it is not free, but nearly all of its usual cost can
be skipped. Tag each build with the base digest it came from:

```text
badgeapp-test:heroku24-ruby3.4.10-<short-base-digest>
```

Then `prepare-image` is:

1. Resolve what `heroku/heroku:24-build` points at now: one request.
2. Ask the registry whether our correspondingly named tag exists: one
   request.
3. If it does, run `circleci-agent step halt`, which ends the job
   successfully and immediately.

Everything expensive comes after that halt: the `checkout`, the
`setup_remote_docker` that provisions a Docker environment, and the
build itself. On the common path none of them runs. Give the job a
small executor image as well, since its only requirement is an HTTPS
client.

The comparison is deliberately just "does this name exist". It could
instead read a label off the current image and compare digest strings,
which keeps everything under one tag, but that means walking a manifest
to a config blob and handling multi-architecture indexes. Existence of a
name is simpler and equally reliable, and simple wins here.

The tests themselves run against a stable tag, `badgeapp-test:current`,
which `prepare-image` points at whatever it just built. That keeps
`.circleci/config.yml` unchanged except when Ruby or the stack changes,
which is exactly when a human should be reading it.

**The mutable tag can race, and that is accepted.** Two branches editing
the Dockerfile at the same moment could both push `current`. It is
unlikely, and the loser's next pipeline corrects it, so it does not
justify the machinery that would prevent it.

**A miss takes minutes, and that is fine.** Ruby has to be compiled,
because Heroku's prebuilt tarballs are not publicly readable. That work
has to happen somewhere for us to stay current; until now it happened
by hand, or more accurately did not happen. Paying it occasionally, in
the pipeline, when the base image has genuinely moved, is the point
rather than the cost.

Keying on the base digest is what makes this stay current without
anyone deciding to update it. When Heroku rebuilds the stack image, and
they do so regularly (`heroku/heroku:24` and `:26` were both rebuilt
2026-07-29), the key changes by itself and we rebuild once. Keying only
on our Dockerfile would cache too well: the image would never pick up
an operating system security update, because nothing we wrote changed.

**Pinning survives this, and arguably improves.** Have the first job
resolve the digest and pass it in, so the Dockerfile reads
`FROM heroku/heroku:24-build@${BASE_DIGEST}`. Every build is then
pinned to an exact digest, recorded in the tag and in an image label,
and reproducible. What changes is the policy: instead of a digest
frozen in a file until someone edits it, we pin to whatever was current
when the image was built, and record what that was.

**One alternative was considered and set aside** for referring to the
image: a parameterized executor fed by CircleCI's dynamic
configuration, where a setup job computes the exact tag and passes it to
the continuation. That removes the mutable stable tag and its race
entirely, at the price of dynamic configuration. Since the race is
accepted as unlikely and self-correcting, it is not worth the machinery,
but it is the way to go if that judgement ever turns out to be wrong.
Confirm how parameterized executors behave in this situation before
relying on it.

The steady state, then: an ordinary pipeline gains one job that makes
two HTTPS requests and halts, and nobody builds an image by hand again.

#### Approach A revisited, given approach D

Approach A and approach D optimise for different things, and the choice
between them is a judgment about which failure we would rather have:

* **A** gives us zero image maintenance and a permanent Ubuntu 22.04
  test environment while production runs 24.04, moving to 26.04.
* **D** gives us a matching operating system, at the cost of a custom
  image that must be built automatically or it will rot exactly as the
  present one did.

An earlier draft of this document recommended A and proposed recording
the operating system gap as accepted. That was optimising for the
problem in front of us, staleness, rather than the one we were asked to
solve, which is that the test and production environments differ and
that keeping them together has been too hard. D is the answer to that
question. A is the answer to a different one.

#### Keeping the remaining pins current: Renovate, not Dependabot

Whichever approach is taken, `.circleci/config.yml` still pins things
that are not ours and that nothing rebuilds for us: the
`circleci/browser-tools` orb, the `cimg/postgres` secondary image, and
the `cimg/node` image the deploy job now uses. Those want a bot.

**Dependabot cannot do it.** It has no CircleCI support at all, so it
never reads `.circleci/config.yml`. This is checkable rather than a
matter of opinion: `dependabot/dependabot-core` carries one directory
per supported ecosystem, 43 of them, including `bundler`, `docker`,
`github_actions`, and `npm_and_yarn`, and there is no `circleci`
directory among them. Its `docker` ecosystem reads Dockerfiles, not CI
configurations, so it can bump a `FROM` line but not an `image:` line.

**Renovate can.** It has a `circleci` manager whose documentation states
that it "supports extracting the following datasources: docker, orb", so
one bot handles both the image references and the orb versions in that
file, by pull request, with our own CI proving each bump before it
merges.

They are complementary rather than competing, and using both is
reasonable:

| Tool | Covers here |
| ---- | ----------- |
| Dependabot | `Gemfile`, npm, GitHub Actions workflows, `dockerfiles/*/Dockerfile` |
| Renovate | `.circleci/config.yml`: executor images and orb versions |

One practical caution: run Renovate with `enabledManagers` limited to
`circleci`. Left at its defaults it will also read the Gemfile and the
Dockerfiles, and open pull requests competing with Dependabot's for the
same upgrades. Keeping each tool in its own lane is what makes running
two of them pleasant rather than noisy.

Note that under approach D the test image's own tag needs no bot at
all, because `prepare-image` maintains it on every pipeline. Renovate's
job is the third-party pins around it.

#### Due diligence on Renovate

Adding a tool that opens pull requests against this repository deserves
a look first. Recorded here so the decision can be reviewed later
against what we actually knew.

**What it is.** `renovatebot/renovate`, started 2016-12-17, licensed
AGPL-3.0-only, backed commercially by Mend.io. The `renovatebot` GitHub
organisation gives its location as Israel and its contact as
`renovate@mend.io`. It comes in two forms: a hosted GitHub App that
Mend runs, and the same open source program run yourself, as an npm
package, a container image, or the official `renovatebot/github-action`.
**We would self-host.** Nothing about updating our own CI configuration
requires giving a third party access to this repository.

**Evidence gathered 2026-08-04.**

* OpenSSF Scorecard **6.7**, scoring 10 on Contributors, CI-Tests,
  License, SAST, Binary-Artifacts, Security-Policy, Maintained,
  Dangerous-Workflow, Dependency-Update-Tool and Code-Review, and 8 on
  Branch-Protection.
* npm releases carry **SLSA provenance v1 attestations**, so the
  published package can be traced to the build that produced it.
* Actively maintained: last commit and latest npm release both on
  2026-08-04.
* Widely used: 22,171 stars, 3,212 forks, about 350,000 npm downloads
  a week.

Weaknesses, since a one-sided assessment is not an assessment:
Token-Permissions 0, Signed-Releases 0, Fuzzing 0, and Vulnerabilities
0, the last meaning Scorecard found known unfixed vulnerabilities,
which for a large Node project usually means transitive advisories
without fixes. We have not checked which. Its CII-Best-Practices score
is 2, which is a low score on our own badge.

**The threat model is smaller than it first appears.** Renovate would
have no ability to change or deploy code. It proposes; a human reviews
and merges. That is the same power any stranger on the internet already
has, since anyone may fork this repository and open a pull request, and
we have always relied on review plus CI to handle that. A bot doing it
on a schedule is not a new category of trust, only a more punctual
contributor.

That argument holds only while its proposals get the same scrutiny as
anyone else's, which leads to the one wrinkle worth getting right.

**Give it the least permission that works.**

* `contents: write` and `pull-requests: write`, and nothing else.
* **Not** `workflows: write`. Renovate needs that only to edit files
  under `.github/workflows/`, and scoped to the `circleci` manager it
  has no business there. Withholding it means it cannot alter our
  GitHub Actions even if it wanted to.
* Nothing for packages, deployments, or actions.
* Keep branch protection on `staging` and `production`. Those are the
  branches the deploy job runs from, so protecting them is what makes
  "it cannot deploy" true rather than merely intended.

**Do not use the default `GITHUB_TOKEN` for this.** GitHub deliberately
does not start workflow runs for events raised by that token, to stop
workflows triggering themselves. Our `brakeman`, `codeql`, `codespell`
and `main` workflows all trigger on `pull_request`, so a Renovate pull
request opened with `GITHUB_TOKEN` would skip every one of them, and
receive *less* checking than a stranger's pull request. Use a dedicated
GitHub App installation token or a fine-grained personal access token
with the two permissions above. CircleCI is unaffected either way, since
it triggers from its own integration.

#### Approach E: build the image inside the test job

Rejected. `setup_remote_docker` with layer caching still builds during
the run, which is exactly the test time we are trying to protect.

## Suggested order

1. **Pin Node for the production build** (finding 5). Independent,
   cheap, and the only finding that can break a deploy. Do this first
   regardless of what is decided about the image.
2. **Approach D**, decided 2026-08-04: build the test image on the same
   stack image production uses, so we test what we run. Approach A was
   considered and rejected because no stock CircleCI image can follow
   production's operating system.
3. **Build it in the pipeline and cache it on the base digest**, so
   there is never a manual build. The check is part of the same
   workflow that tests, not a scheduled job, and it halts before doing
   anything expensive when the image is already current.
   The failure this document describes is not that our image is old, it
   is that keeping it current was manual; this is the part that fixes
   that, and it should be built before anything depends on it.
4. **Take Ruby to 3.4.10 in the same change**, closing finding 3. Under
   A that means pinning `cimg/ruby:3.4.10-browsers`, which exists,
   built 2026-06-30. Under D it means naming 3.4.10 in our own
   Dockerfile.
5. **If D is chosen, upgrade production to Heroku-26 afterwards, not
   before.** Doing the test environment first means the stack upgrade
   gets tested somewhere before it reaches production, which is the
   whole point of having the environments match.
