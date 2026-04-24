import Testing
import Foundation
@testable import Core

@Suite("SensitiveEnvironmentPolicy")
struct SensitiveEnvironmentPolicyTests {

    // MARK: - Strip paths

    @Test func stripsGitHubToken() {
        let input = ["GITHUB_TOKEN": "ghp_abc123"]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func stripsCloudCredentials() {
        let input = [
            "AWS_ACCESS_KEY_ID": "AKIA1234567890",
            "AWS_SECRET_ACCESS_KEY": "xxxxxxxxxxxxxxxxxxxx",
            "GCP_SERVICE_ACCOUNT_JSON": "{...}",
            "AZURE_CLIENT_SECRET": "s3cret",
            "GOOGLE_APPLICATION_CREDENTIALS": "/etc/creds.json",
        ]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func stripsAIProviderKeys() {
        let input = [
            "ANTHROPIC_API_KEY": "sk-ant-...",
            "OPENAI_API_KEY": "sk-...",
            "HUGGINGFACE_TOKEN": "hf_...",
            "HF_TOKEN": "hf_...",
            "COHERE_API_KEY": "co_...",
            "MISTRAL_API_KEY": "ms_...",
        ]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func stripsPaymentAndDataVendors() {
        let input = [
            "STRIPE_SECRET_KEY": "sk_live_...",
            "TWILIO_AUTH_TOKEN": "xxx",
            "SENDGRID_API_KEY": "SG....",
            "DATADOG_API_KEY": "xxx",
            "DD_API_KEY": "xxx",
            "SENTRY_AUTH_TOKEN": "xxx",
        ]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func stripsDatabaseCredentials() {
        let input = [
            "POSTGRES_PASSWORD": "hunter2",
            "PG_PASSWORD": "hunter2",
            "MYSQL_ROOT_PASSWORD": "hunter2",
            "REDIS_PASSWORD": "hunter2",
            "MONGODB_URI": "mongodb://user:hunter2@host",
        ]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func stripsArbitrarySubstringMatches() {
        // These don't appear in any prefix list but carry sensitive substrings.
        let input = [
            "MY_SERVICE_TOKEN": "x",
            "PROJECT_API_KEY": "x",
            "OAUTH_PASSWORD": "x",
            "DB_CREDENTIAL": "x",
            "CUSTOM_AUTH_VALUE": "x",
            "SOMETHING_SECRET": "x",
        ]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func sensitiveBeatsSenkaniPrefix() {
        // Defense-in-depth: even a variable that matches the SENKANI_
        // passthrough prefix is stripped if it's clearly sensitive.
        let input = ["SENKANI_TOKEN": "x", "SENKANI_API_KEY": "x"]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    // MARK: - Passthrough paths

    @Test func preservesExecutionPlumbing() {
        let input = [
            "PATH": "/usr/bin:/bin",
            "HOME": "/Users/alice",
            "SHELL": "/bin/zsh",
            "USER": "alice",
            "TMPDIR": "/var/folders/xyz/T",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "PWD": "/Users/alice/proj",
        ]
        let out = SensitiveEnvironmentPolicy.sanitize(input)
        #expect(out["PATH"] == "/usr/bin:/bin")
        #expect(out["HOME"] == "/Users/alice")
        #expect(out["SHELL"] == "/bin/zsh")
        #expect(out["USER"] == "alice")
        #expect(out["TMPDIR"] == "/var/folders/xyz/T")
        #expect(out["TERM"] == "xterm-256color")
        #expect(out["COLORTERM"] == "truecolor")
        #expect(out["PWD"] == "/Users/alice/proj")
    }

    @Test func preservesLocalePrefix() {
        let input = ["LC_ALL": "en_US.UTF-8", "LC_CTYPE": "en_US.UTF-8", "LANG": "en_US.UTF-8"]
        let out = SensitiveEnvironmentPolicy.sanitize(input)
        #expect(out["LC_ALL"] == "en_US.UTF-8")
        #expect(out["LC_CTYPE"] == "en_US.UTF-8")
        #expect(out["LANG"] == "en_US.UTF-8")
    }

    @Test func preservesSenkaniPanePlumbing() {
        let input = [
            "SENKANI_PANE_ID": "p-abc",
            "SENKANI_PROJECT_ROOT": "/tmp/x",
            "SENKANI_MODE": "passthrough",
        ]
        let out = SensitiveEnvironmentPolicy.sanitize(input)
        #expect(out["SENKANI_PANE_ID"] == "p-abc")
        #expect(out["SENKANI_PROJECT_ROOT"] == "/tmp/x")
        #expect(out["SENKANI_MODE"] == "passthrough")
    }

    @Test func stripsUnrecognizedVariablesByDefault() {
        // Not on any allowlist, not obviously sensitive — still stripped.
        // This is the default-deny posture.
        let input = ["MY_APP_VERSION": "1.2.3", "CUSTOM_FLAG": "on"]
        #expect(SensitiveEnvironmentPolicy.sanitize(input).isEmpty)
    }

    @Test func mixedBagPreservesSafeStripsSecret() {
        let input = [
            "PATH": "/bin",
            "HOME": "/Users/alice",
            "GITHUB_TOKEN": "ghp_...",
            "AWS_SECRET_ACCESS_KEY": "xxx",
            "LC_ALL": "en_US.UTF-8",
            "SENKANI_PANE_ID": "p-1",
            "CI": "true",
        ]
        let out = SensitiveEnvironmentPolicy.sanitize(input)
        #expect(out["PATH"] != nil)
        #expect(out["HOME"] != nil)
        #expect(out["LC_ALL"] != nil)
        #expect(out["SENKANI_PANE_ID"] != nil)
        #expect(out["CI"] != nil)
        #expect(out["GITHUB_TOKEN"] == nil)
        #expect(out["AWS_SECRET_ACCESS_KEY"] == nil)
    }
}
