#
# Custom PowerSync node
#
ARG JEPSEN_REGISTRY

FROM ${JEPSEN_REGISTRY:-}jepsen-node AS jepsen-setup

# deps
RUN apt-get -qy update && \
    apt-get -qy install \
    libsqlite3-dev sqlite3 sqlite3-tools

FROM dart:stable AS dart-build

# Resolve app dependencies.
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get

# Copy app source code (except anything in .dockerignore) and AOT compile app.
COPY . .
RUN dart compile exe --target-os linux bin/sqlite3_endpoint.dart

# Build minimal serving image from AOT-compiled `/server`
# and the pre-built AOT-runtime in the `/runtime/` directory of the base image.
FROM jepsen-setup AS jepsen-final
WORKDIR /jepsen/jepsen-powersync/sqlite3_endpoint
COPY --from=dart-build /app/.env .env
COPY --from=dart-build /app/bin/sqlite3_endpoint.exe ./bin/
