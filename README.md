# github-runner-manager

Run several repositories' self-hosted GitHub Actions runners on one modest
machine without their heavy jobs (emulators, native builds) starving each other.

Status: work in progress. The scripts, tests and design notes are not on `main` yet.

## Keeping private details out

Contributors keep their own list of private terms (repository names, hostnames,
user names) in a file **outside** this repository and point
`scripts/check-no-private-terms.sh` at it:

```bash
PRIVATE_TERMS_FILE=~/my-private-terms.txt scripts/check-no-private-terms.sh
```

Installed as a local `pre-push` hook, it checks every pushed commit's files and
message. Without `PRIVATE_TERMS_FILE` it is a no-op.

## License

MIT, see [LICENSE](LICENSE).
