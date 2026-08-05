# DepControl API -> Fly.io.
#
# Build context is the REPO ROOT, not this directory:
#     docker build -f backend/Dockerfile .
#
# Why: `backend` is a pub workspace member (`resolution: workspace`) whose
# `shared` and `ecosystem` dependencies resolve through the root lockfile. A
# context of `backend/` alone cannot see `packages/` and `dart pub get` fails.
#
# Every local package `backend` depends on has to be copied in AND given a path
# override below — a workspace member missing from both is only reported as
# "could not find package <name> at https://pub.dev", which reads like a typo
# rather than a missing COPY.
#
# `dart_frog build` ships its own Dockerfile, but it is not usable here. It
# emits a `pubspec_overrides.yaml` pointing at the *host's absolute path* to
# `packages/shared` (on Windows it mangles it further, into `C:\C:\...`), and it
# never copies `shared` into the build output. Both are corrected below.

FROM dart:stable AS build

# Pinned to the version this project was built against; `dart_frog build`
# generates the production entrypoint (`bin/server.dart`) from `routes/`.
RUN dart pub global activate dart_frog_cli 1.2.14

WORKDIR /app
COPY packages ./packages
COPY backend ./backend

WORKDIR /app/backend

# Detach from the workspace: the image deliberately carries no root pubspec (the
# root workspace also pulls in `frontend`, which would drag the whole Flutter SDK
# into an API image), so `resolution: workspace` has to come out of pubspec.yaml
# itself and the overrides point each local package at the copy alongside it.
#
# It is NOT enough to cancel it with `resolution: null` in pubspec_overrides.yaml:
# pub honours that, but `dart_frog build` reads pubspec.yaml directly, sees
# `resolution: workspace`, fails to find a workspace root, and then — with only
# an "Unable to determine workspace root" line on stdout and a zero exit code —
# skips bundling entirely. The build still "succeeds" and still produces
# bin/server.dart, but with an empty Router: every route 404s with "Route not
# found" at runtime. Deleting the key here is what keeps that from coming back.
RUN sed -i '/^resolution: workspace$/d' pubspec.yaml \
 && printf 'dependency_overrides:\n  shared:\n    path: ../packages/shared\n  ecosystem:\n    path: ../packages/ecosystem\n' \
      > pubspec_overrides.yaml \
 && dart pub get

RUN dart pub global run dart_frog_cli:dart_frog build

# A routeless build is silent and still exits 0 (see above), so fail loudly here
# rather than shipping an API that 404s everything.
RUN test -d build/routes \
 && grep -q "routes/index.dart" build/bin/server.dart \
 || (echo "ERROR: dart_frog build produced no routes" && exit 1)

# `dart_frog build` regenerates its own broken overrides inside `build/`.
# Overwrite it, then resolve and compile for real. From `/app/backend/build`,
# `../../packages/shared` is `/app/packages/shared`.
WORKDIR /app/backend/build
RUN printf 'dependency_overrides:\n  shared:\n    path: ../../packages/shared\n  ecosystem:\n    path: ../../packages/ecosystem\n' \
      > pubspec_overrides.yaml \
 && dart pub get \
 && dart compile exe bin/server.dart -o bin/server

# `/runtime/` carries the system libraries *and* the CA certificate bundle the
# compiled binary needs — this API makes outbound TLS calls to api.github.com,
# pub.dev and Supabase, all of which fail without it.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/backend/build/bin/server /app/bin/server

# Quiets the per-request dev logger and raises the default log level to info.
ENV ENV=production

# The generated server reads PORT, defaulting to 8080; fly.toml sets it
# explicitly next to internal_port. EXPOSE is documentation only.
EXPOSE 8080

CMD ["/app/bin/server"]
