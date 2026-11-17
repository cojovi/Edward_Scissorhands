# Edward Scissorhands delivery

- The canonical user-facing app is `/Applications/Edward Scissorhands.app`. Future app changes must update this copy.
- `dist/Edward Scissorhands.app` is generated staging output. Use `./script/build_and_run.sh` or Codex **Run** to build, install/update the canonical app, and launch it.
- `./script/build_and_run.sh --build-only` builds and installs/updates without launching. `./script/install_app.sh` installs an already packaged `dist` bundle without rebuilding.
- Do not report app changes as delivered until `/Applications/Edward Scissorhands.app` has been refreshed and checked for the expected change.
- Let active batches finish before relaunching the app. Preserve Application Support data, Keychain credentials, original media and exports during updates.
