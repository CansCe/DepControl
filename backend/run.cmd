@echo off
REM Convenience wrapper: runs run.ps1 with a per-invocation execution-policy
REM bypass so the unsigned local script isn't blocked. Changes no persistent
REM setting. Any args (e.g. -Build) are passed through to run.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run.ps1" %*
