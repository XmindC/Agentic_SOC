# Security policy

Agentic SOC is a teaching lab. It is built to be attacked from inside its own network, so treat every address and account in it as lab-only.

## Reporting a problem

If you find a secret, a personal detail or a way for the AI agents to act without a human, do not open a public issue. Contact the repository owner privately through GitHub (Security tab, "Report a vulnerability", once private reporting is enabled) and include the file path and commit.

## What must never be in this repository

- API keys, tokens, passwords, session secrets, license keys or private keys. Real values go in `.env`, which is git-ignored, or in the credential store of the service that uses them (n8n, Cortex, TheHive).
- Live exports: `docker-compose.yml` from the running host, `ossec.conf`, n8n workflow exports with credentials, Wazuh `wazuh-install-files.tar`.
- Personal data: email addresses, home network addresses, real usernames.
- Screenshots, until each one has been checked by hand. One screenshot in this project's history showed an API key.

Placeholders look like `<OPENAI_API_KEY>`. `install.sh` refuses to run while any remain in `.env`.

## Before every commit

```bash
pre-commit run --all-files        # gitleaks, private-key check, large files, shellcheck
gitleaks git --redact -v .        # full history
git diff --cached                 # read what you are about to commit
```

## If a secret is committed

1. Rotate it at the provider first. Deleting it from Git does not make it safe.
2. Then remove it from history with `git-filter-repo --sensitive-data-removal` and force-push.
3. Record what happened in `docs/06-operations/` without repeating the value.

## The agent safety rule

The AI agents hold no credentials and no tools. They return text. Only n8n acts (create a case, post a comment, send a notification), and nothing in the pipeline blocks, isolates, disables or deletes. Any change that gives an agent a credential or a response action is a security issue and should be reported as one.
