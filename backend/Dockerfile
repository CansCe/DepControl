# DepControl API -> Fly.io.
#
# Build context is the REPO ROOT, not this directory:
#     docker build -f backend/Dockerfile .
#
# Why: `backend` is a pub workspace member (`resolution: workspace`) whose
# `shared` dependency resolves through the root lockfile. A context of
# `backend/` alone cannot see `packages/shared` and `dart pub get` fails.
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
COPY packages/shared ./packages/shared
COPY backend ./backend

WORKDIR /app/backend

# Detach from the workspace: `resolution: null` cancels `resolution: workspace`
# so this package resolves standalone, and the override points `shared` at the
# copy alongside it. Without this, pub looks for a root pubspec that the image
# deliberately does not carry (the root workspace also pulls in `frontend`,
# which would drag the whole Flutter SDK into an API image).
RUN printf 'dependency_overrides:\n  shared:\n    path: ../packages/shared\nresolution: null\n' \
      > pubspec_overrides.yaml \
 && dart pub get

RUN dart pub global run dart_frog_cli:dart_frog build

# `dart_frog build` regenerates its own broken overrides inside `build/`.
# Overwrite it, then resolve and compile for real. From `/app/backend/build`,
# `../../packages/shared` is `/app/packages/shared`.
WORKDIR /app/backend/build
RUN printf 'dependency_overrides:\n  shared:\n    path: ../../packages/shared\nresolution: null\n' \
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
