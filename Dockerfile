# syntax=docker/dockerfile:1

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5
ARG DEBIAN_VERSION=bookworm-20260421-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:bookworm-slim"

# ---- builder ----
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends build-essential git ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV=prod

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
RUN mix deps.compile

COPY lib lib

RUN mix release

# ---- runtime ----
FROM ${RUNNER_IMAGE}

RUN apt-get update -y \
  && apt-get install -y --no-install-recommends \
       libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/* \
  && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

RUN useradd --create-home --shell /bin/bash --uid 1000 sark \
  && mkdir -p /storage \
  && chown -R sark:sark /app /storage

USER sark

COPY --from=builder --chown=sark:sark /app/_build/prod/rel/sark ./

# Mount point: expects config.yml + plugin dirs + data subdir here.
#   /storage/config.yml
#   /storage/data/        (config - data_dir)
#   /storage/plugins/...  (config - plugin paths)
VOLUME ["/storage"]

ENV SARK_CONFIG=/storage/config.yml

CMD ["/app/bin/sark", "start"]
