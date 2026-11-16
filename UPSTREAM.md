# Upstream provenance

- **Project:** LinkMesh, by `litu173`
- **Repository:** https://github.com/litu173/LinkMesh
- **Imported source revision:** `c77c1a52d58719019ffb311693adc053dcf0493c` (2026-10-03)
- **Purpose:** non-commercial HYBRID-01 experimentation and showcase, as confirmed by the project owner to the user.
- **Imported areas:** `lib/`, `android/`, `assets/`, `test/`, `tool/`, and Flutter project metadata/dependency files.
- **Not imported:** iOS/macOS project directories, the web preview, and upstream Git history.

The upstream GitHub repository does not declare a repository licence. Permission to experiment with this project was confirmed by the user; retain attribution and confirm the owner's expectations before redistributing a modified source tree or release artifact. Dependency licences remain separate: in particular, review `flutter_blue_plus` terms and the app's declared use when changing the intended use or distribution.

Since the initial import, the local changes add a SQLite relay-queue table with a version-1-to-2 database migration, router queue restoration and persistence, atomic saving of newly originated outgoing messages with their queue entries, and a simulated router-restart recovery test. These changes have not yet been run through Flutter in the current workspace because Flutter, Dart, and Java are not installed here. The user's earlier successful build/test/analyze results apply to the pre-change baseline, not these new modifications. Physical BLE behavior and SQLite process-death recovery have not been tested.
