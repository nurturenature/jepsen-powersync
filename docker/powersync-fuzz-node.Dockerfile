#
# Custom powersync-fuzz node
#
FROM debian AS powersync-fuzz-setup

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

RUN wget --no-verbose https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.27.3-stable.tar.xz
RUN tar -xf ./flutter_linux_3.27.3-stable.tar.xz -C /usr/bin/
ENV PATH=/usr/bin/flutter/bin:$PATH

# required by how flutter uses git
RUN git config --global --add safe.directory /usr/bin/flutter

# build into /app
WORKDIR /app

# app is responsible for getting native lib
RUN wget --no-verbose -O libpowersync_x64.so https://github.com/powersync-ja/powersync-sqlite-core/releases/download/v0.3.9/libpowersync_x64.so

# Resolve app dependencies.
COPY pubspec.* ./
RUN dart pub get

# Copy app source code and compile app to standalone binary.
COPY ./ ./
RUN dart compile exe --target-os linux --output powersync_fuzz bin/powersync_fuzz.dart

# copy executable, library, and env to final image
FROM powersync-fuzz-setup AS powersync-fuzz-final
WORKDIR /powersync_fuzz
COPY --from=dart-build /app/.env .env
COPY --from=dart-build /app/powersync_fuzz powersync_fuzz
COPY --from=dart-build /app/libpowersync_x64.so libpowersync_x64.so

ENTRYPOINT [ "sleep", "infinity" ]