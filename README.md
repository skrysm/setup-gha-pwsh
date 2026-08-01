# setup-gha-pwsh

This action makes the `gha-pwsh` PowerShell wrapper available to all subsequent script steps via `gha-pwsh {0}`.
shell.

## Usage

```yaml
jobs:
  example:
    runs-on: ubuntu-latest
    steps:
      - name: Set up gha-pwsh
        uses: skrysm/setup-gha-pwsh@v1.0.0

      - name: Run a PowerShell script
        shell: gha-pwsh {0}
        run: |
          Write-Host "Hello from PowerShell"
```

The setup step must run before the first step that uses the custom shell. It's cheap and idempotent and thus can be executed multiple times without any problems. Therefore, it's recommended to run this as first step in every job and composite action that wants to use the `gha-pwsh` wrapper script.

## What it does

The `gha-pwsh` script does the following:

* It provides proper exception handling that produces full stack traces for PowerShell exceptions.
* Errors are written to the step log and as a full diagnostic in the job summary.
* It prevents `$LASTEXITCODE` from an inner call to "leak" to GitHub and thus fail the step even if the inner call was handled.
