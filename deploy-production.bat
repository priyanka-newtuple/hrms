@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "GH=gh"
where gh >nul 2>nul
if errorlevel 1 (
  where winget >nul 2>nul
  if errorlevel 1 (
    echo GitHub CLI could not be found and winget is unavailable.
    echo Install GitHub CLI from https://cli.github.com/ and run this file again.
    exit /b 1
  )
  echo Installing GitHub CLI...
  winget install --id GitHub.cli --exact --source winget --accept-package-agreements --accept-source-agreements
  if errorlevel 1 exit /b 1
  set "GH=C:\Program Files\GitHub CLI\gh.exe"
)

"%GH%" auth status >nul 2>nul
if errorlevel 1 (
  echo Opening GitHub sign-in...
  "%GH%" auth login --web --git-protocol https
  if errorlevel 1 exit /b 1
)

echo Starting the HRMS production workflow...
"%GH%" workflow run ci.yml --repo priyanka-newtuple/hrms --ref main
if errorlevel 1 exit /b 1

echo Waiting for GitHub to create the workflow run...
timeout /t 5 /nobreak >nul

set RUN_ID=
for /f "usebackq delims=" %%I in (`"%GH%" run list --repo priyanka-newtuple/hrms --workflow ci.yml --event workflow_dispatch --branch main --limit 1 --json databaseId --jq ".[0].databaseId"`) do set RUN_ID=%%I

if not defined RUN_ID (
  echo The workflow was started, but its run ID was not available yet.
  echo View it at https://github.com/priyanka-newtuple/hrms/actions
  exit /b 0
)

echo Following workflow run !RUN_ID!...
"%GH%" run watch !RUN_ID! --repo priyanka-newtuple/hrms --exit-status
if errorlevel 1 (
  echo Production deployment failed. Opening the workflow logs...
  start "" "https://github.com/priyanka-newtuple/hrms/actions/runs/!RUN_ID!"
  exit /b 1
)

echo HRMS production deployment completed successfully.
exit /b 0
