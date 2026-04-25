import Foundation

/// Computes the `EffectiveSet` from a team manifest + user overrides.
///
/// Formula:  effective = team ∩ user.optOuts ∪ user.additions
///
/// Read: start from what the team committed, subtract the user's
/// opt-outs, then union in the user's personal additions. Additions
/// win over opt-outs when a name appears in both lists — the user
/// is the tie-breaker.
///
/// The resolver is pure; load/persist is `ManifestLoader`'s job.
public enum ManifestResolver {
    public static func resolve(
        manifest: Manifest?,
        overrides: ManifestOverrides
    ) -> EffectiveSet {
        let base = manifest ?? Manifest()
        let manifestPresent = manifest != nil

        let skills = apply(
            base: base.skills,
            optOuts: overrides.optOutSkills,
            additions: overrides.addSkills
        )
        let tools = apply(
            base: base.mcpTools,
            optOuts: overrides.optOutTools,
            additions: overrides.addTools
        )
        let hooks = apply(
            base: base.hooks,
            optOuts: overrides.optOutHooks,
            additions: overrides.addHooks
        )

        return EffectiveSet(
            skills: skills,
            mcpTools: tools,
            hooks: hooks,
            manifestPresent: manifestPresent
        )
    }

    private static func apply(
        base: [String],
        optOuts: [String],
        additions: [String]
    ) -> Set<String> {
        var result = Set(base)
        result.subtract(optOuts)
        result.formUnion(additions)
        return result
    }
}
