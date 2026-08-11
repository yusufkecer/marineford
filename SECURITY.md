# Security Policy

marineford delivers code into installed apps. A flaw in it is not a bug in one
app — it is a way into every app that trusts a given signing key. Please report
suspected vulnerabilities privately.

## Reporting

Use GitHub's [private vulnerability
reporting](https://github.com/yusufkecer/marineford/security/advisories/new) on
this repository. Do not open a public issue.

Include, if you can: the affected package and version, what you were able to
make the client accept or reject, and a minimal reproduction. A failing test
against `packages/marineford_core` is the most useful form.

Expect an acknowledgement within a week. This is a pre-release project
maintained in spare time; that is the honest commitment, not a guarantee.

## The threat model, stated plainly

**A patch is arbitrary code by design.** The security boundary is *who can
publish*, not *what a published patch can do*. Anyone holding the private
signing key can run code inside every app that carries the matching public key.
That is the intended behaviour, not a vulnerability.

Two consequences worth being explicit about:

**dart_eval is not a sandbox.** It is an interpreter. It limits what patch code
can reach only because nothing is exposed to it by default. Every bridge you
register hands that capability to anyone who can publish a patch. Registering a
file-system or HTTP bridge is equivalent to granting remote code execution with
that capability, and no amount of care in this library changes it.

**Nothing protects you from your own key.** If the signing key leaks, revoking
patches does not help — an attacker with the key can publish new ones. The
recovery path is a store release with a new public key.

## In scope

Anything that lets a patch load when it should not have:

- Accepting a container whose Ed25519 signature does not verify
- Accepting a container whose SHA-256 does not match the manifest
- Accepting a patch whose ABI fingerprint does not match the build
- Accepting a manifest whose detached signature does not verify
- Moving a device to a lower patch number without revocation (rollback attack)
- Reaching a decompression step before the signature has been checked
- Path traversal or escape from the patch store directory
- A patch that survives the crash-loop guard it should have tripped
- Any crash reachable from hostile bytes, since the client is supposed to reject
  rather than fail

Also in scope: the CLI signing or publishing something the client would then
refuse, or the reverse — publishing something the client accepts but should not.

## Not in scope

- What a patch does once it has been legitimately signed and loaded
- Capabilities you granted a patch by registering a bridge
- Anything requiring the attacker to already hold the private signing key
- Anything requiring physical access to an unlocked, rooted or jailbroken device
  — a patch on disk is re-verified on every load, but an attacker with that much
  access can modify the app itself and does not need marineford
- App store policy questions. Whether a given patch stays inside "does not
  change the app's primary purpose" is the publisher's responsibility, not a
  vulnerability in this library.
- `dart_eval` bugs. Report those
  [upstream](https://github.com/ethanblake4/dart_eval/issues); mention it here
  too if the consequence is that marineford accepts something it should reject.

## Supported versions

Pre-release. Only `main` is supported. Once packages are published to pub.dev
this section will name the supported minor versions.

## If a signing key is compromised

1. Ship a store release with a new public key. This is the only real fix.
2. Revoke every patch signed with the old key (`marineford revoke`) so devices
   that have not yet updated fall back to their store build.
3. Assume any patch published with the old key may have been replaced. Treat the
   affected app versions as untrusted until the store release lands.

The old key cannot be un-trusted on devices that are already running a build
containing it. Plan for that before it happens: keep the key in a secret store,
never in the repository, and prefer `MARINEFORD_SIGNING_KEY` in CI over a file
on anyone's laptop.
