[CmdletBinding()]
param(
    [string]$Repository = "priyanka-newtuple/hrms",
    [string]$Environment = "production",
    [string]$HrmsDomain = "62-238-103-67.sslip.io",
    [string]$CertbotEmail = "admin@newtuple.com",
    [string]$AdminEmail = "priyanka@newtuple.com",
    [string]$AdminFirstName = "Priyanka",
    [string]$AdminLastName = "Admin",
    [string]$AdminEmployeeCode = "NT0001",
    [string]$SmtpHost = "smtp.gmail.com",
    [string]$SmtpUsername = "priyanka@newtuple.com",
    [string]$EmailFrom = "Newtuple HRMS <priyanka@newtuple.com>",
    [switch]$DisableEmail
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI is required. Run deploy-production.bat once to install it, then rerun this script."
}

& gh auth status *> $null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Opening GitHub sign-in..."
    & gh auth login --web --git-protocol https
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub authentication failed."
    }
}

# Creating an environment through the API is idempotent. This also makes the
# script work when the production environment has not yet been created in the UI.
& gh api --method PUT "repos/$Repository/environments/$Environment" --silent
if ($LASTEXITCODE -ne 0) {
    throw "Could not create or access the '$Environment' environment."
}

$emailEnabled = if ($DisableEmail) { "false" } else { "true" }
$variables = [ordered]@{
    HRMS_DOMAIN                         = $HrmsDomain
    CERTBOT_EMAIL                       = $CertbotEmail
    BOOTSTRAP_ADMIN_EMAIL               = $AdminEmail
    BOOTSTRAP_ADMIN_FIRST_NAME          = $AdminFirstName
    BOOTSTRAP_ADMIN_LAST_NAME           = $AdminLastName
    BOOTSTRAP_ADMIN_EMPLOYEE_CODE       = $AdminEmployeeCode
    PRODUCTION_SERVER_PORT              = "22"
    HRMS_BIND_PORT                      = "8081"
    EMAIL_ENABLED                       = $emailEnabled
    SMTP_HOST                           = $SmtpHost
    SMTP_PORT                           = "587"
    SMTP_USERNAME                       = $SmtpUsername
    EMAIL_FROM                          = $EmailFrom
    PRODUCTION_DEMO_DATA_ENABLED        = "true"
}

Write-Host "Configuring GitHub environment variables for $Repository / $Environment..."
foreach ($entry in $variables.GetEnumerator()) {
    $value = [string]$entry.Value
    if ($value.Length -eq 0) {
        & gh variable set $entry.Key --repo $Repository --env $Environment "--body="
    }
    else {
        & gh variable set $entry.Key --repo $Repository --env $Environment --body $value
    }
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to set $($entry.Key)."
    }
    Write-Host "  Set $($entry.Key)"
}

$requiredSecrets = @(
    "PRODUCTION_SERVER_HOST",
    "PRODUCTION_SERVER_USER",
    "PRODUCTION_SSH_PRIVATE_KEY",
    "PRODUCTION_SSH_HOST_KEY",
    "POSTGRES_PASSWORD",
    "JWT_SECRET",
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET"
)
if (-not $DisableEmail) {
    $requiredSecrets += "SMTP_PASSWORD"
}

$repositorySecretNames = @(
    & gh secret list --repo $Repository --json name --jq ".[].name"
)
$environmentSecretNames = @(
    & gh secret list --repo $Repository --env $Environment --json name --jq ".[].name"
)
$availableSecrets = @($repositorySecretNames + $environmentSecretNames | Sort-Object -Unique)
$missingSecrets = @($requiredSecrets | Where-Object { $_ -notin $availableSecrets })

$deploymentEnabled = if ($missingSecrets.Count -eq 0) { "true" } else { "false" }
& gh variable set PRODUCTION_DEPLOY_ENABLED --repo $Repository --env $Environment --body $deploymentEnabled
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set environment PRODUCTION_DEPLOY_ENABLED."
}

# GitHub evaluates the deploy job's `if` expression before loading environment
# variables. Keep this flag at repository level as well so the job can start.
& gh variable set PRODUCTION_DEPLOY_ENABLED --repo $Repository --body $deploymentEnabled
if ($LASTEXITCODE -ne 0) {
    throw "Failed to set repository PRODUCTION_DEPLOY_ENABLED."
}

if ($missingSecrets.Count -gt 0) {
    Write-Warning "Deployment remains disabled. Add these GitHub secrets:"
    $missingSecrets | ForEach-Object { Write-Warning "  $_" }
    Write-Host "Rerun this script after adding them; it will enable deployment automatically."
    exit 2
}

Write-Host "All required secrets are present. PRODUCTION_DEPLOY_ENABLED=true"
Write-Host "Production environment configuration is ready."
