# 005 — Secrets: what this bench does, and what it refuses to pretend

- **Status:** Accepted
- **Date:** 2026-09-16

## Context

ticketflow needs a PostgreSQL password. That is the entire secret surface of
this repository, and it would be easy to make it look more sophisticated than it
is — wire up SOPS, commit an encrypted file, and let a reader assume the bench
demonstrates secure GitOps secret handling.

It would also be dishonest, because a single lab credential encrypted with a key
that is either committed or absent teaches nothing. Worse, it would obscure the
one genuinely interesting thing here: **the two engines have materially different
secret stories, and it is one of the sharpest differences between them.**

## Decision

**The chart renders a `Secret` from a documented lab default, and exposes
`postgres.existingSecret` as the seam where real secret management attaches.
Nothing is encrypted, and the repository says why.**

```yaml
postgres:
  auth:
    # Lab credential. This is not a secret: the cluster is disposable, it is
    # never exposed beyond localhost, and SECURITY.md says so explicitly.
    password: ticketflow
  existingSecret: ""     # point this at a Secret you manage yourself
```

When `existingSecret` is set, the chart renders no `Secret` at all and both the
API and the migration Job read from the one supplied. That is the single
integration point any real approach would use, and it costs four lines of
template.

## The difference this exposes between the two engines

This is worth more than the decision itself.

| | Argo CD 3.5.3 | Flux 2.9.5 |
|---|---|---|
| Decrypts secrets itself | **no** | **yes** — `Kustomization.spec.decryption` |
| Supported providers | — | `sops`, with age, OpenPGP, AWS KMS, Azure Key Vault, GCP KMS, OpenBao/Vault |
| Documented approach | external operators on the destination cluster, or a Config Management Plugin such as `argocd-vault-plugin` | native, in `kustomize-controller` |

Flux's [Kustomization API](https://fluxcd.io/flux/components/kustomize/kustomizations/)
states plainly:

> "`.provider`: The secrets decryption provider to be used. This field is
> required and the only supported value is `sops`."

Argo CD's [secret management page](https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/)
describes no native decryption. It recommends keeping secrets away from Argo CD
entirely — "Argo CD does not need to directly manage them" — with Sealed
Secrets, External Secrets Operator or the Secrets Store CSI Driver doing the work
on the destination cluster, or `argocd-vault-plugin` at manifest-generation time.

Neither position is wrong. Flux's is more convenient and puts a decryption key
inside the controller; Argo CD's pushes the problem to a purpose-built operator
and keeps the GitOps engine out of the key material. Which one is right depends
on your threat model, not on which tool is better.

**This bench does not exercise either.** It reports the difference and stops.

## Consequences

- **The one credential in this repository is committed in plain text**, in
  `hack/versions.env` (Gitea) and `apps/ticketflow/chart/values.yaml`
  (PostgreSQL). Both are documented in `SECURITY.md` as deliberate, and both
  protect nothing: a throwaway Git server and a throwaway database, on
  localhost.
- **No real secret management is demonstrated.** A reader looking for how to run
  SOPS or External Secrets will not find it here, and the README does not imply
  they will.
- **This is the weakest part of the bench**, and the part furthest from
  production. A production version of this comparison would need real key
  material, real rotation, and a threat model — none of which fit in a laptop
  lab.
- **Nothing is ever committed encrypted-but-decryptable**, which would be the
  worst outcome: the appearance of security with the key alongside it.

## Alternatives considered

**Encrypt the PostgreSQL password with SOPS and age, committing the encrypted
file.** Rejected. Either the age key is committed too — security theatre — or it
is not, and `make up` no longer works on a clean clone. Both outcomes are worse
than a documented plaintext lab default.

**Generate the password randomly at install time with `randAlphaNum`.**
Rejected. It breaks idempotency: Helm regenerates the value on every upgrade
unless guarded with a lookup, the migration Job and the API can disagree about
it mid-roll, and debugging that is a poor use of a reader's attention. The
failure mode is confusing and teaches nothing about either engine.

**Use Sealed Secrets, so at least one approach is shown end to end.** Rejected
as scope. It would need a controller in both clusters, and it works identically
on both — so it adds machinery without adding comparison. Flux's native SOPS
support, which does differ, cannot be shown symmetrically for the same reason:
Argo CD has no counterpart to compare it against.

**Say nothing about secrets at all.** Rejected. The difference in the table
above is one of the more decision-relevant differences between these two tools,
and a comparison document that omitted it because the bench does not exercise it
would be incomplete in a way that matters.
