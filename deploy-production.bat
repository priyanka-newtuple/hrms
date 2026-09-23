@echo off
setlocal EnableExtensions EnableDelayedExpansion

where gh >nul 2>nul
if errorlevel 1 (
  echo GitHub CLI ^(gh^) is required. Install it from https://cli.github.com/
  exit /b 1
)

gh auth status >nul 2>nul
if errorlevel 1 (
  echo Sign in first with: gh auth login
  exit /b 1
)

echo Starting the HRMS production workflow...
gh workflow run ci.yml --repo priyanka-newtuple/hrms --ref main
if errorlevel 1 exit /b 1

echo Waiting for GitHub to create the workflow run...
timeout /t 5 /nobreak >nul

set RUN_ID=
for /f "usebackq delims=" %%I in (`gh run list --repo priyanka-newtuple/hrms --workflow ci.yml --event workflow_dispatch --branch main --limit 1 --json databaseId --jq ".[0].databaseId"`) do set RUN_ID=%%I

if not defined RUN_ID (
  echo The workflow was started, but its run ID was not available yet.
  echo View it at https://github.com/priyanka-newtuple/hrms/actions
  exit /b 0
)

echo Following workflow run !RUN_ID!...
gh run watch !RUN_ID! --repo priyanka-newtuple/hrms --exit-status
if errorlevel 1 (
  echo Production deployment failed. Opening the workflow logs...
  start "" "https://github.com/priyanka-newtuple/hrms/actions/runs/!RUN_ID!"
  exit /b 1
)

echo HRMS production deployment completed successfully.
exit /b 0
