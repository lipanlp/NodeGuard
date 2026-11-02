# NodeGuard working conventions

- Use the native Swift implementation and system frameworks. Keep dependencies small and pinned.
- Preserve the user's Clash subscription, scripts, DNS, rules and residential proxy definitions. The only live control write implemented by the product is selecting the approved front group.
- Claude termination scope is desktop only: `/Applications/Claude.app/Contents/`. Exclude Claude Code, shells and terminal applications.
- Exercise termination through the injected signal sender and failover through the fake Unix API during development. Do not kill a real Claude task or switch the live front selector to validate a code change.
- Never commit or print Clash YAML, subscription URLs, proxy credentials, Codex authentication, raw response headers or environment variables. Third-party fixture passwords must be obviously fake.
- Build with `scripts/build.sh`, test with `scripts/test.sh` and `scripts/mock-api-test.py`. Use `--observe-only` for live UI inspection.
- Keep intermediate files in `work/`, deliverables in `outputs/`. Runtime private files live under NodeGuard's own user application support/cache directories.
- Report separately: implemented behavior, automated tests, read-only live probes, and unperformed live failover/termination/login/notification/soak validation.
