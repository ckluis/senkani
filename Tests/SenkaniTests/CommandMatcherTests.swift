import Testing
@testable import Filter

@Suite("CommandMatcher") struct CommandMatcherTests {
    @Test func simpleCommand() {
        let match = CommandMatcher.parse("git status")
        #expect(match?.base == "git")
        #expect(match?.subcommand == "status")
    }

    @Test func flagsBeforeSubcommand() {
        let match = CommandMatcher.parse("git -C /path status")
        #expect(match?.base == "git")
        #expect(match?.subcommand == "status")
    }

    @Test func fullPath() {
        let match = CommandMatcher.parse("/usr/bin/git status")
        #expect(match?.base == "git")
        #expect(match?.subcommand == "status")
    }

    @Test func envVars() {
        let match = CommandMatcher.parse("FOO=bar GIT_DIR=/tmp git log")
        #expect(match?.base == "git")
        #expect(match?.subcommand == "log")
    }

    @Test func sudo() {
        let match = CommandMatcher.parse("sudo git push")
        #expect(match?.base == "git")
        #expect(match?.subcommand == "push")
    }

    @Test func noSubcommand() {
        let match = CommandMatcher.parse("ls")
        #expect(match?.base == "ls")
        #expect(match?.subcommand == nil)
    }

    @Test func emptyString() {
        #expect(CommandMatcher.parse("") == nil)
    }

    @Test func npmInstall() {
        let match = CommandMatcher.parse("npm install express")
        #expect(match?.base == "npm")
        #expect(match?.subcommand == "install")
    }

    @Test func cargoFlags() {
        let match = CommandMatcher.parse("cargo build --release")
        #expect(match?.base == "cargo")
        #expect(match?.subcommand == "build")
    }

    @Test func onlyFlags() {
        let match = CommandMatcher.parse("ls -la")
        #expect(match?.base == "ls")
        // -la is a flag, no subcommand
    }
}
