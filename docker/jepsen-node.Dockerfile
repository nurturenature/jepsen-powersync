#
# Custom PowerSync node
#
ARG JEPSEN_REGISTRY

FROM ${JEPSEN_REGISTRY:-}jepsen-node AS jepsen-setup

# build on a working image
FROM debian AS dart-build

# install flutter
# deps
RUN apt-get -qy update && \
    apt-get -qy install \
    git wget xz-utils

RUN wget --no-verbose https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.41.6-stable.tar.xz
RUN tar -xf ./flutter_linux_3.41.6-stable.tar.xz -C /usr/bin/
ENV PATH=/usr/bin/flutter/bin:$PATH

# required by how flutter uses git
RUN git config --global --add safe.directory /usr/bin/flutter

# build into /app
WORKDIR /app

# Resolve app dependencies.
COPY pubspec.* ./
RUN dart pub get

# copy app source code
COPY ./ ./

# compile apps to standalone binaries
RUN ./build-http.sh
RUN ./build-fuzz.sh

# copy env, library, and executables to final image
FROM jepsen-setup AS jepsen-final
WORKDIR /jepsen/jepsen-powersync/powersync_endpoint
COPY --from=dart-build /app/.env .env

# need current version of SQLite3, use pre-built from app source dir
COPY --from=dart-build /app/powersync_http/bundle/lib/libpowersync_core.so          ./powersync_http/bundle/lib/libpowersync_core.so
COPY --from=dart-build /app/powersync_http/bundle/lib/libsqlite3_connection_pool.so ./powersync_http/bundle/lib/libsqlite3_connection_pool.so
COPY --from=dart-build /app/powersync_http/bundle/lib/libsqlite3.so                 ./powersync_http/bundle/lib/libsqlite3.so
COPY --from=dart-build /app/powersync_http/bundle/bin/powersync_http                ./powersync_http/bundle/bin/powersync_http

COPY --from=dart-build /app/powersync_fuzz/bundle/lib/libpowersync_core.so          ./powersync_fuzz/bundle/lib/libpowersync_core.so
COPY --from=dart-build /app/powersync_fuzz/bundle/lib/libsqlite3_connection_pool.so ./powersync_fuzz/bundle/lib/libsqlite3_connection_pool.so
COPY --from=dart-build /app/powersync_fuzz/bundle/lib/libsqlite3.so                 ./powersync_fuzz/bundle/lib/libsqlite3.so
COPY --from=dart-build /app/powersync_fuzz/bundle/bin/powersync_fuzz                ./powersync_fuzz/bundle/bin/powersync_fuzz

