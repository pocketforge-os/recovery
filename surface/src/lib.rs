//! Typed contract and CPU-only scaffold for the on-device recovery surface.

use serde::{Deserialize, Serialize};

/// Durable evidence that explains why the recovery surface was entered.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoveryRequired {
    pub failure: Failure,
    /// RFC 3339 timestamp recorded by the producer.
    pub occurred_at: String,
    /// Durable URI or content-addressed identifier for supporting evidence.
    pub evidence: EvidencePointer,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Failure {
    BootVerification { component: String },
    UpdateVerification { release: String },
    SystemIntegrity { detail: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidencePointer(pub String);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryAction {
    OtaUpdate,
    FelRecovery,
}

/// Availability is explicit and carries the truthful customer-facing explanation.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Capability {
    Available {
        action: RecoveryAction,
        label: String,
    },
    Unavailable {
        action: RecoveryAction,
        reason: String,
    },
}

impl Capability {
    pub fn action(&self) -> RecoveryAction {
        match self {
            Self::Available { action, .. } | Self::Unavailable { action, .. } => *action,
        }
    }

    /// Creates an activation token only for an action advertised as available.
    pub fn activate(&self) -> Result<Activation, ActivationError> {
        match self {
            Self::Available { action, .. } => Ok(Activation { action: *action }),
            Self::Unavailable { action, reason } => Err(ActivationError {
                action: *action,
                reason: reason.clone(),
            }),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Activation {
    action: RecoveryAction,
}

impl Activation {
    pub fn action(self) -> RecoveryAction {
        self.action
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ActivationError {
    pub action: RecoveryAction,
    pub reason: String,
}

/// Typed terminal or progress outcomes for every action that can be offered.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum ActionResult {
    OtaUpdateStarted {
        release: String,
    },
    OtaUpdateCompleted {
        release: String,
    },
    OtaUpdateFailed {
        reason: String,
        evidence: EvidencePointer,
    },
    FelInstructionsShown,
    FelRecoveryDetected,
    FelRecoveryFailed {
        reason: String,
        evidence: EvidencePointer,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoverySurface {
    pub condition: RecoveryRequired,
    pub capabilities: Vec<Capability>,
    pub last_result: Option<ActionResult>,
}

pub mod offscreen {
    use super::{Capability, RecoverySurface};

    pub const WIDTH: usize = 160;
    pub const HEIGHT: usize = 96;

    /// Deterministic RGBA buffer used until the production renderer is selected.
    #[derive(Clone, Debug, PartialEq, Eq)]
    pub struct Frame {
        pub width: usize,
        pub height: usize,
        pub rgba: Vec<u8>,
    }

    pub fn render(surface: &RecoverySurface) -> Frame {
        let mut frame = Frame {
            width: WIDTH,
            height: HEIGHT,
            rgba: vec![0; WIDTH * HEIGHT * 4],
        };
        fill(&mut frame, [20, 24, 31, 255]);
        rect(&mut frame, 8, 8, 144, 18, [183, 67, 67, 255]);

        // Placeholder capability rows: green means actionable, gray means unavailable.
        for (index, capability) in surface.capabilities.iter().enumerate() {
            let color = match capability {
                Capability::Available { .. } => [55, 151, 104, 255],
                Capability::Unavailable { .. } => [82, 88, 98, 255],
            };
            rect(&mut frame, 12, 36 + index * 20, 136, 12, color);
        }
        frame
    }

    pub fn stable_hash(frame: &Frame) -> String {
        // FNV-1a is intentionally simple and stable across toolchains.
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in frame
            .width
            .to_le_bytes()
            .into_iter()
            .chain(frame.height.to_le_bytes())
            .chain(frame.rgba.iter().copied())
        {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        format!("{hash:016x}")
    }

    fn fill(frame: &mut Frame, color: [u8; 4]) {
        for pixel in frame.rgba.as_chunks_mut::<4>().0 {
            pixel.copy_from_slice(&color);
        }
    }

    fn rect(frame: &mut Frame, x: usize, y: usize, width: usize, height: usize, color: [u8; 4]) {
        for row in y..(y + height).min(frame.height) {
            for column in x..(x + width).min(frame.width) {
                let offset = (row * frame.width + column) * 4;
                frame.rgba[offset..offset + 4].copy_from_slice(&color);
            }
        }
    }
}
