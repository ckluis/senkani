import Foundation

/// Adapter shell for the `openai/privacy-filter` token classifier (Layer 3
/// of `SecretDetector`). T.2a registers the model + decoder + CLI; T.2b
/// wires the actual MLX-Swift Apex/MoE inference path (or the GGUF/llama.cpp
/// fallback). Until then `forward(_:)` and `runVerificationFixture()` throw
/// a clear staged-delivery error so operators see the gating, not a silent
/// no-op.
///
/// Why a shell ships in T.2a:
/// - `ModelManager` still gets a registered entry (so `senkani models list`
///   surfaces the model and `senkani models pull` has a concrete target).
/// - `senkani models pull pii-classifier-int8` can drive the HF snapshot
///   download without needing the inference backend, but T.2a does not
///   ship that download path either — it abort-rules into the manual-log
///   target (real network egress + 1.5GB blocking download). T.2b owns
///   both the backend wiring and the download driver.
/// - The `BIOESDecoder` is fully unit-tested without weights; once the
///   adapter starts producing real `[T, 33]` logits in T.2b, the decoder
///   plugs in unchanged.
public actor PIIClassifierAdapter {

    /// Senkani model id that maps to this adapter. Single source of truth
    /// — `MCPMain` and `ModelsCommand` both switch on this value.
    public static let modelId = "pii-classifier-int8"

    /// Process-wide instance. Following the EmbedTool/VisionTool pattern,
    /// the adapter is held as an actor singleton so MLX inference can be
    /// serialized via `MLXInferenceLock.shared`.
    public static let shared = PIIClassifierAdapter()

    public init() {}

    /// Marker error type so callers (CLI verify, MCP install path) can
    /// distinguish "backend not yet wired" from "backend errored at
    /// runtime". T.2b removes this when the inference path lands.
    public struct BackendNotReadyError: Error, CustomStringConvertible {
        public let stage: String
        public var description: String {
            "PIIClassifier \(stage) backend wired in T.2b. T.2a ships registry + decoder + CLI shell only."
        }
    }

    /// Place the model on disk. T.2a ships a documented gate; T.2b wires
    /// the actual HuggingFace snapshot download via `Hub` + the MLX-Swift
    /// loader (or llama.cpp/GGUF fallback if Apex/MoE coverage is
    /// incomplete).
    public func ensureModel() async throws {
        throw BackendNotReadyError(stage: "download")
    }

    /// Run the model-card example fixture and assert the expected
    /// `private_person` + `private_email` spans surface. Wired in T.2b.
    public func runVerificationFixture() async throws {
        throw BackendNotReadyError(stage: "verification")
    }

    /// Forward pass: produce `[T, 33]` logits for a tokenized string. Once
    /// T.2b wires the MLX path, this method runs under
    /// `MLXInferenceLock.shared` and returns the raw row-major logit
    /// matrix consumed by `BIOESDecoder.decode(logits:alignments:)`.
    public func forward(_ text: String) async throws -> [[Float]] {
        throw BackendNotReadyError(stage: "inference")
    }
}
