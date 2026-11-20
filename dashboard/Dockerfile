# The hosted relay (docs/relay.md): the dashboard in relay mode, showing what a
# runner host pushes to it. It reads no host and runs no command.
#
#   docker build -t grm-relay dashboard
#
# Settings come from the environment at run time; the secrets
# (GRM_RELAY_PUSH_TOKENS, GRM_RELAY_VIEWER_PASSWORD, SECRET_KEY_BASE) are never
# baked in.

# Pinned by digest, as CI pins its actions by commit; the tag says which.
ARG BUILDER_IMAGE=hexpm/elixir:1.20.0-erlang-29.0.1-debian-trixie-20260610-slim@sha256:4a82089d72152d317f4ab6eaed783c593e721479c2569f5629fe9652dfea52bd
ARG RUNNER_IMAGE=debian:trixie-20260610-slim@sha256:4e401d95de7083948053197a9c3913343cd06b706bf15eb6a0c3ccd26f436a0e

FROM ${BUILDER_IMAGE} AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
# Compile-time config first, so the dependencies compile with it.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

COPY config/runtime.exs config/
COPY lib lib
COPY priv priv
RUN mix compile --warnings-as-errors && mix release

FROM ${RUNNER_IMAGE}

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 libncurses6 openssl ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --system --uid 10001 --home-dir /app --shell /usr/sbin/nologin relay

WORKDIR /app
COPY --from=build --chown=root:root /app/_build/prod/rel/dashboard ./

# No Erlang distribution: nothing listens but the web port.
ENV LANG=C.UTF-8 \
  RELEASE_DISTRIBUTION=none \
  MIX_ENV=prod \
  PHX_SERVER=true \
  PORT=8080 \
  GRM_DASHBOARD_SOURCE=relay \
  RELEASE_TMP=/tmp

# The release's files belong to root and the server runs as relay, so a
# compromised server cannot change its own code.
USER relay
EXPOSE 8080

CMD ["/app/bin/dashboard", "start"]
