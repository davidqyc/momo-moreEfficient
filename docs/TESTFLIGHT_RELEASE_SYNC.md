# TestFlight release sync rule

This project treats GitHub public distribution facts as part of release completion.

After each new public TestFlight build becomes available:

1. update `README.md` and `README.en.md` so the current public build label matches the newly available TestFlight build;
2. verify the TestFlight public-link URL shown on GitHub; if the public URL changed, update every public TestFlight link in the repository;
3. do not mark the release complete in the current Issue, `docs/PROJECT_STATE.md`, or `CHANGELOG.md` while GitHub still shows an old public build or stale TestFlight URL.

This is a release-closing rule, not a requirement to change the TestFlight URL when Apple keeps the same public link across builds.
