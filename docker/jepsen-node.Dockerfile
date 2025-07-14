#
# Custom PowerSync node
#
ARG JEPSEN_REGISTRY

FROM ${JEPSEN_REGISTRY:-}jepsen-node AS jepsen-setup

# PowerSync deps
RUN apt-get -qy update && \
    apt-get -qy install \
    libsqlite3-dev sqlite3 sqlite3-tools

# build on a working image
FROM debian AS dart-build

# install flutter
# deps
RUN apt-get -qy update && \
    apt-get -qy install \
    git wget xz-utils

RUN wget --no-verbose https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.32.6-stable.tar.xz
RUN tar -xf ./flutter_linux_3.32.6-stable.tar.xz -C /usr/bin/
ENV PATH=/usr/bin/flutter/bin:$PATH

# required by how flutter uses git
RUN git config --global --add safe.directory /usr/bin/flutter

# build into /app
WORKDIR /app

# Resolve app dependencies.
COPY pubspec.* ./
RUN dart pub get

# app is responsible for getting native lib
COPY download-powersync-sqlite-core.sh ./
RUN ./download-powersync-sqlite-core.sh

# copy app source code
COPY ./ ./

# compile apps to standalone binaries
RUN ./compile-http.sh
RUN ./compile-fuzz.sh

# copy env, library, and executables to final image
FROM jepsen-setup AS jepsen-final
WORKDIR /jepsen/jepsen-powersync/powersync_endpoint
COPY --from=dart-build /app/.env .env
COPY --from=dart-build /app/libpowersync_x64.so libpowersync_x64.so

# need current version of SQLite3, use pre-built from app source dir
COPY --from=dart-build /app/libsqlite3.so       libsqlite3.so
COPY --from=dart-build /app/sqlite3             sqlite3

COPY --from=dart-build /app/powersync_http powersync_http
COPY --from=dart-build /app/powersync_fuzz powersync_fuzz
