# DevOps pack — context

This pack combines a **blast-radius gate** with a **prod-namespace
guard**. It pairs a two-phase HandManifest skill
(`blast-radius-containment` + `prod-namespace-guard`) with a
HookRouter policy fragment that denies the three highest-risk
destructive and prod-targeted patterns:

- `kubectl delete` — pod/deployment/namespace teardown.
- `terraform destroy` — workspace-wide resource destruction.
- `--context=prod` — prod-cluster targeting in the same line as any
  other operation.

Match patterns are deliberately specific so read-only verbs
(`kubectl get`, `terraform plan`, `aws describe`) and non-prod
contexts (`--context=staging`, `--context=dev`) pass through
unchanged. The skill phase bodies cover the broader context-
confirmation discipline (rollback documentation, workspace
selectors, explicit target naming).

To opt out of the deny rules, run `senkani pack uninstall devops`.
The pack scope key is `devops`, distinct from `code-quality` and
`security`, so all three packs install side-by-side without
collision.
