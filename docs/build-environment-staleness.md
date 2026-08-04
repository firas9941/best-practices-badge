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

1. **Rebuild by hand, now.** Bump the base to a current
   `cimg/ruby:<version>-browsers`, rebuild, push, re-pin. Fixes all four
   for a while. Does nothing about the procedure, so expect to be back
   here.
2. **Automate the rebuild.** A scheduled job that rebuilds the image
   from a current base and opens a pull request with the new digest.
   This is the only option that addresses the cause. Cost: somewhere to
   run it, and credentials to push to a registry.
3. **Stop maintaining a custom image.** Ours adds only three things to
   `cimg/ruby:*-browsers`: `cmake`, `shared-mime-info`, and Bundler
   2.7.

   One of those three is already redundant. `cmake` is installed by
   `cimg/base` itself, in both the 22.04 and 24.04 variants, so
   `dockerfiles/3.4.1-browsers/Dockerfile:31` is installing a package
   the base image already has. That leaves `shared-mime-info`, needed
   by the `mimemagic` gem, and a specific Bundler version, which recent
   `cimg/ruby` images may well ship already.

   If what remains can be dropped or done in a CI step, the whole
   maintenance burden disappears and we pin a stock image that CircleCI
   keeps current. **Check this first**, because it would make options 1
   and 2 unnecessary.
4. **Move the pin to something that updates itself.** Dependabot's
   `docker` ecosystem can bump the `FROM` digest in
   `dockerfiles/*/Dockerfile`, but it does not parse CircleCI configs,
   so the pin of our own image in `.circleci/config.yml` would still be
   manual. Partial at best.

Investigate option 3 before choosing. If we do not need a custom image,
every other option here is wasted effort.

## Suggested order

1. Pin Node for the production build (finding 5). Independent, cheap,
   and the only one that can break a deploy.
2. Determine whether we still need a custom test image at all. If not,
   pin a stock `cimg/ruby` and delete `dockerfiles/`.
3. If we do need one, automate its rebuild rather than doing it by hand.
4. Whichever way that goes, take Ruby to 3.4.10 and the test image to
   Ubuntu 24.04 in the same change, so CI and production match.
