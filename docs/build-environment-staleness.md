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

**Decided, not yet built:** everything in
[The plan](#the-plan).

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

Tag each build with the base digest it came from:

```text
badgeapp-test:heroku24-ruby3.4.10-<short-base-digest>
```

`prepare-image` then:

1. Resolves what `heroku/heroku:24-build` points at now: one request.
2. Asks the registry whether the matching tag exists: one request.
3. If it does, runs `circleci-agent step halt`, ending the job
   successfully and immediately.

**Order matters.** The `checkout`, the `setup_remote_docker` that
provisions a Docker environment, and the build all come *after* the
halt, so none runs on the common path. Give the job a small executor
image; its only requirement is an HTTPS client.

Keying on the base digest is what keeps us current with nobody deciding
anything: when Heroku rebuilds the stack image, the key changes by
itself. Keying only on our Dockerfile would cache too well, because an
operating system security update changes nothing we wrote.

The tests run against a stable tag, `badgeapp-test:current`, which
`prepare-image` points at whatever it just built. That keeps
`.circleci/config.yml` unchanged except when Ruby or the stack changes,
which is exactly when a human should read it.

**Decisions taken:**

* The comparison is *existence of a tag name*, not reading a label and
  comparing digest strings. The latter keeps one tag but means walking a
  manifest to a config blob and handling multi-architecture indexes.
  Simple wins while both are reliable.
* The stable tag is mutable, so two branches editing the Dockerfile at
  once could race. Accepted: unlikely, and the loser's next pipeline
  corrects it.
* A miss takes a few minutes. Accepted: that work must happen somewhere
  to stay current, and until now it happened by hand, or rather did not.

## Keeping pins current

Three tools, distinct ground:

| Tool | Covers |
| ---- | ------ |
| Dependabot | `Gemfile`, npm, GitHub Actions workflows |
| Renovate | `.circleci/config.yml` images and orbs, and `.ruby-version` |
| `prepare-image` | the test image, rebuilt when its base moves |

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
trimmed file contents as the current version.

Run Renovate with `enabledManagers` limited to `circleci` and
`ruby-version`. At its defaults it also reads the Gemfile and
Dockerfiles and competes with Dependabot for the same upgrades.
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

## Guard: Ruby pins must stay deployable

Only Ruby versions Heroku offers for our stack will deploy, so a
Renovate pull request proposing a newer one could pass CI and fail at
deploy. Make it a test instead.

The test reads `.ruby-version`, issues one `HEAD` for the corresponding
tarball, and fails unless the answer is **200**. Skip it when the
network is unavailable, so offline work is unaffected; CI has a network,
and CI is where it matters.

* **Compare the exact version.** It answers precisely the question we
  care about, with no version arithmetic. Looser schemes, such as
  accepting any patch within our X.Y series, need the bucket listed
  rather than probed, which is not permitted, and answer a weaker
  question.
* **Read the stack name from the same constant the image build uses**,
  so a stack upgrade cannot change one and forget the other.
* **Assert "must be 200"**, never "must not be 404", for the S3 reason
  above.

Because `.ruby-version` is also an input to the test image, a pull
request bumping it changes the cache key, so `prepare-image` builds an
image for that Ruby and the tests genuinely run on it.

## The plan

1. **Pin Node for the production build** (finding 5). Independent,
   cheap, and the only finding that can break a deploy. Add the
   `heroku/nodejs` buildpack ahead of `heroku/ruby` and pin the version.
2. **Write the new test image**: `FROM heroku/heroku:24-build`, Heroku's
   prebuilt Ruby, Chrome, chromedriver. Confirm the suite passes on it
   before anything depends on it.
3. **Add `prepare-image`** with the halt-early caching above, and point
   the `build` job at `badgeapp-test:current`.
4. **Delete `dockerfiles/3.4.1-browsers/`, `dockerfiles/3.3.6-browsers/`
   and `how-to-create-image.md`**, and the DockerHub image they
   describe, once nothing references them.
5. **Take Ruby to 3.4.10** (finding 3), which under this design is a
   one-line change plus an automatic rebuild.
6. **Add the Heroku-availability test** so step 5 cannot silently
   regress.
7. **Add Renovate**, self-hosted, scoped and permissioned as above.
8. **Then upgrade production to Heroku-26**, test environment first, so
   the stack move is exercised somewhere before it reaches production.

Findings 1, 2 and 4 have no separate step: steps 2 to 4 remove their
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
* CircleCI docs are rendered client-side, so plain `curl` returns
  navigation rather than content. Two things were therefore *not*
  verified and should be before use: how parameterized executors behave
  in this situation, and what Docker layer caching costs on our plan.
