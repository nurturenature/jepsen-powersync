## Usage

### Configuration

`./config/config.yaml`
- `client_auth.jwks` must match `./lib/auth.dart`

`./.env` PowerSync only
- `JWKS_PUBLIC_KEY` must match `./lib/auth.dart`
 
`./app/.env` app only
- `POWERSYNC_URL` should be provided

----

### Docker

The Docker environment is the easiest way to run tests.
Use provided `docker-build.sh`, `docker-compose-up/down.sh` scripts.

See Docker [README](../docker/README.md).

----

### Local

Dart + Flutter SDK required:
- https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_3.22.2-stable.tar.xz

Native lib needs to be manually provided to Dart:
- https://github.com/powersync-ja/powersync-sqlite-core/releases/download/v0.2.0/libpowersync_x64.so
- as libpowersync_x64.so in same directory as compiled app

Bring up PowerSync service Docker:
- compile and run local app
  - `.env` `powersync_url=http:localhost:6060`
