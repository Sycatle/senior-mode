# The base image of sandboxed sessions (ADR 0025, #763): a slim Debian with the tools a session needs, Node LTS, the
# `claude` CLI and a non-root user. `senior-mode` builds it on demand as senior-mode/base:<plugin version>, with
# CLAUDE_VERSION set to the host's version of the CLI; a project's .senior-mode/Dockerfile starts FROM it.
FROM node:lts-bookworm-slim

ARG CLAUDE_VERSION=latest

RUN apt-get update \
    && apt-get install -y --no-install-recommends bash git jq curl ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}" \
    && useradd --create-home --shell /bin/bash agent

WORKDIR /work
USER agent
