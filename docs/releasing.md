# Release process

1. Ensure `main` is green (CI: build + test on macOS).
2. Run the model-gated tests locally:
   `ACTIONROUTER_E5_DIR=tools/convert/build swift test`.
3. If routing behaviour changed, run the frozen test matrix and update
   `docs/benchmarks.md`:
   `swift run -c release actionrouter eval Benchmarks/episodes/test [--e5-dir …]`.
4. Update `CHANGELOG.md` (Keep a Changelog format) and bump the version in
   `ActionRouterCLI` (`CommandConfiguration.version`).
5. Tag: `git tag -a vX.Y.Z -m "vX.Y.Z" && git push --tags`.
6. Create the GitHub release. Attach the model artifacts produced by
   `tools/convert/convert_e5.py --int8`:
   - `MultilingualE5Small-Int8.zip` (mlpackage + tokenizer directory —
     this is what `actionrouter fetch-model` downloads)
   - `parity_report.txt`
7. Verify `swift run actionrouter fetch-model --to /tmp/model-check`
   downloads and routes.

Versioning: semantic. Pre-1.0, breaking API changes bump the minor
version and are listed under "Breaking" in the changelog.
