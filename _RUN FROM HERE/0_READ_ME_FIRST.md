# Run From Here

Use this folder when you want the simple TimeCapsule project controls.

The app code and Xcode project stay in the main repo folder. These files are just beginner-friendly launchers.

## Normal Use

1. Double-click `1_OPEN - TimeCapsule PowerShell.bat`
   - Opens PowerShell directly in `C:\Dev\TimeCapsule`.
   - Shows the current Git status.

2. Double-click `2_OPEN - Xcode Project.bat`
   - Opens `TimeCapsule.xcodeproj` with the system default app.
   - On a Mac/Xcode environment, this is the project to build/run.

3. Double-click `3_RUN - Git Status.bat`
   - Shows current branch and uncommitted changes.

4. Double-click `4_RUN - Pull Latest Main.bat`
   - Runs `git pull --ff-only`.
   - Use before starting work if the repo is clean.

5. Double-click `5_RUN - Setup Git Hooks.bat`
   - Configures repo-local Git hooks from `.githooks`.

6. Double-click `6_OPEN - Project Handoff.bat`
   - Opens the main project brief.

7. Double-click `7_OPEN - Source Folder.bat`
   - Opens the Swift source folder.

8. Double-click `8_OPEN - Docs Folder.bat`
   - Opens project docs.

## Important

TimeCapsule is an iOS app. Actual simulator/device build and run belongs in an Xcode/macOS environment. These Windows launchers organize the repo workflow and open the right project files.

