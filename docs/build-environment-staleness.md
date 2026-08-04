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
if the stack is upgraded before the test image is.

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

For the automation half: **Dependabot has no CircleCI ecosystem**, so it
cannot bump this pin. **Renovate does**: its `circleci` manager supports
the `docker` and `orb` datasources, so one bot can keep both the image
digest and the `browser-tools` orb current, by pull request, with CI
proving each bump before it merges. Adding Renovate is a new tool for
this project, which is the main cost of this approach.

A smaller alternative is a scheduled GitHub Actions workflow that
resolves the current digest for the tag and opens a pull request when it
differs. Less capable than Renovate, but no new service.

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

#### Approach D: match production's operating system

Production builds on **Heroku-24**, which is Ubuntu 24.04. Every
`cimg/ruby` image is still Ubuntu 22.04: `cimg-ruby`'s 3.4 Dockerfile
reads `FROM cimg/base:2026.03-22.04`. So **no stock CircleCI Ruby image
closes finding 4 today.**

To match production we would have to build from `heroku/heroku:24` and
install Ruby and Chrome ourselves, which is a large custom image and
puts us back in the situation approach A escapes.

* **Pro.** Genuine parity: same distribution, same system libraries.
* **Con.** The most maintenance of any option here, for the problem we
  are trying to stop having.
* **Con.** Would not match production exactly anyway, since Heroku's
  Ruby comes from its buildpack, not from apt.

The honest position is that OS parity and low maintenance are in
tension, and low maintenance has been the thing we actually failed at.
Take the Ruby parity that approach A gives, record the operating system
gap, and revisit if CircleCI moves `cimg/ruby` to 24.04 or if a bug
appears that the gap explains.

#### Approach E: build the image inside the test job

Rejected. `setup_remote_docker` with layer caching still builds during
the run, which is exactly the test time we are trying to protect.

## Suggested order

1. **Pin Node for the production build** (finding 5). Independent,
   cheap, and the only finding that can break a deploy.
2. **Delete the custom test image** and point CircleCI at stock
   `cimg/ruby:3.4.10-browsers`, pinned by digest. This takes Ruby to
   3.4.10 at the same time, closing finding 3, and removes findings 1
   and 2 by removing the thing that caused them. Confirm the suite
   passes before deleting `dockerfiles/`.
3. **Add automated digest bumps**, by Renovate or a scheduled workflow,
   so step 2 does not decay the way the current arrangement did.
4. **Record finding 4 as accepted**, since no stock image closes it,
   and revisit when `cimg/ruby` moves to Ubuntu 24.04 or when a failure
   makes the gap matter.
