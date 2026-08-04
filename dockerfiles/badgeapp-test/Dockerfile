# Test image for the OpenSSF Best Practices badge CI pipeline.
#
# Copyright the Linux Foundation and the CII Best Practices badge
# contributors. SPDX-License-Identifier: MIT
#
# This image is built by the "prepare-image" job in
# .circleci/config.yml, never by hand.  The procedure it replaced was
# seven manual steps needing push access to one person's DockerHub
# account, which is why the old image sat nineteen months out of date.
# See docs/build-environment-staleness.md.
#
# It deliberately contains no browser: Chrome runs in its own container
# beside this one, and no JDK: nothing we build or test uses a JVM.
# It deliberately does NOT contain our gems either.  The CI job restores
# a dependency cache and installs into it; a cold "bundle install" takes
# over five minutes, and baking it here would rebuild the image on every
# Gemfile.lock change for no gain.

# Pinned by digest at build time by prepare-image, so every build records
# exactly which base it came from, rather than freezing a digest in this
# file until someone remembers to edit it.
ARG BASE_IMAGE=heroku/heroku:24-build
FROM ${BASE_IMAGE}

# This label is not decoration. On ghcr.io a package pushed with a
# personal access token is NOT linked to a repository by default, and an
# unlinked package must be administered at the package level, which
# needs an organisation owner. This label links it at publication time,
# after which the package inherits the repository's access permissions,
# so a repository admin can manage it and set it public. Without it,
# turning the package public becomes someone else's ticket.
LABEL org.opencontainers.image.source=https://github.com/ossf/best-practices-badge
LABEL org.opencontainers.image.description="CI test image: Ubuntu 24.04 (Heroku-24 stack), Heroku's prebuilt Ruby, and the Node package.json pins. No browser, no JDK, no gems."
LABEL org.opencontainers.image.licenses=MIT

# Supplied by prepare-image, read from the files that already govern
# them: .ruby-version and package.json's engines.node.  They are not
# defaulted here, so a mismatch fails loudly instead of building
# something nobody asked for.
ARG RUBY_VERSION
ARG NODE_VERSION
ARG STACK=heroku-24

# The base runs as uid 1000 "heroku" and /usr/local is not writable by
# it.  Become root to install, hand the tree back, and drop down again.
# There is no sudo in this image, so everything CI does must work
# unelevated; that is why the Ruby tree is chowned rather than left root.
USER root

# Heroku's own prebuilt Ruby, so the interpreter matches production and
# the build is a download rather than a compile.
#
# The path needs the architecture segment.  S3 answers 403 rather than
# 404 when listing is denied, so a missing object and a forbidden one
# look identical; only a 200 means anything.  heroku-24 needs
# "amd64/", heroku-22 does not.
RUN set -eux; \
    test -n "${RUBY_VERSION}"; \
    mkdir -p /usr/local/ruby; \
    curl -sfSL \
      "https://heroku-buildpack-ruby.s3.us-east-1.amazonaws.com/${STACK}/amd64/ruby-${RUBY_VERSION}.tgz" \
      | tar xz -C /usr/local/ruby; \
    chown -R heroku:heroku /usr/local/ruby; \
    /usr/local/ruby/bin/ruby -v

# Node, at the version package.json pins for the production build, so CI
# minifies JavaScript with the interpreter production minifies with.
# Verified against nodejs.org's own SHASUMS256.txt: that is integrity,
# not provenance, since both come from the same host, but it catches a
# truncated or corrupted download rather than trusting the tarball
# blindly.
RUN set -eux; \
    test -n "${NODE_VERSION}"; \
    cd /tmp; \
    base="https://nodejs.org/download/release/v${NODE_VERSION}"; \
    tarball="node-v${NODE_VERSION}-linux-x64.tar.gz"; \
    curl -sfSL "${base}/${tarball}" -o "${tarball}"; \
    curl -sfSL "${base}/SHASUMS256.txt" -o SHASUMS256.txt; \
    grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c -; \
    mkdir -p /usr/local/node; \
    tar xz -C /usr/local/node --strip-components=1 -f "${tarball}"; \
    rm -f "${tarball}" SHASUMS256.txt; \
    chown -R heroku:heroku /usr/local/node; \
    /usr/local/node/bin/node --version

ENV PATH=/usr/local/ruby/bin:/usr/local/node/bin:$PATH

# The base leaves LANG unset, which gives LC_CTYPE=POSIX and therefore a
# US-ASCII default external encoding.  This application serves six
# languages, so that would corrupt non-ASCII text in ways that surface
# far from the cause.  C.utf8 exists in the base; en_US.utf8 does too.
ENV LANG=C.UTF-8

USER heroku
WORKDIR /home/heroku

# Fail the build rather than ship an image that cannot read UTF-8.
RUN set -eux; \
    ruby -e 'raise "default_external is #{Encoding.default_external}" \
             unless Encoding.default_external == Encoding::UTF_8'; \
    ruby -v; \
    node --version; \
    gem --version
