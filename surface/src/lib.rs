//! Launcher-independent, CPU-only on-device recovery surface.

use serde::{Deserialize, Serialize};

pub const TITLE: &str = "PocketForge Recovery";
pub const REQUIRED_COPY: &str = "Recovery is required";
pub const RECEIPT_COPY: &str = "Recovery receipt";
pub const OTA_AVAILABLE_COPY: &str = "Network reachable. Update over the air (OTA).";
pub const OTA_UNAVAILABLE_COPY: &str = "Network unavailable. OTA cannot start.";
pub const FEL_FLOOR_COPY: &str = "Use FEL recovery when OTA is unavailable.";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RecoveryRequired {
    pub failure: Failure,
    pub occurred_at: String,
    pub evidence: EvidencePointer,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Failure {
    BootVerification { component: String },
    UpdateVerification { release: String },
    SystemIntegrity { detail: String },
}

impl Failure {
    fn receipt(&self) -> String {
        match self {
            Self::BootVerification { component } => {
                format!("Boot verification failed: {component}")
            }
            Self::UpdateVerification { release } => {
                format!("Update verification failed: {release}")
            }
            Self::SystemIntegrity { detail } => format!("System integrity failed: {detail}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EvidencePointer(pub String);

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RecoveryAction {
    OtaUpdate,
    FelRecovery,
}

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
    pub fn activate(&self) -> Result<Activation, ActivationError> {
        match self {
            Self::Available { action, .. } => Ok(Activation { action: *action }),
            Self::Unavailable { action, reason } => Err(ActivationError::Unavailable {
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
pub enum ActivationError {
    Unavailable {
        action: RecoveryAction,
        reason: String,
    },
    InvalidSelection {
        index: usize,
    },
}

/// The only output of activating a control. An authority outside the UI consumes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "intent", rename_all = "snake_case")]
pub enum RecoveryIntent {
    StartOtaUpdate,
    ShowFelRecovery,
}

impl From<Activation> for RecoveryIntent {
    fn from(value: Activation) -> Self {
        match value.action() {
            RecoveryAction::OtaUpdate => Self::StartOtaUpdate,
            RecoveryAction::FelRecovery => Self::ShowFelRecovery,
        }
    }
}

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

impl RecoverySurface {
    /// Produces an intent, never a device-side effect.
    pub fn activate(&self, index: usize) -> Result<RecoveryIntent, ActivationError> {
        self.capabilities
            .get(index)
            .ok_or(ActivationError::InvalidSelection { index })?
            .activate()
            .map(Into::into)
    }
    /// Results are supplied by the authority that consumed the intent.
    pub fn present_result(&mut self, result: ActionResult) {
        self.last_result = Some(result);
    }
}

pub mod offscreen {
    use super::*;
    pub const WIDTH: usize = 320;
    pub const HEIGHT: usize = 240;

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
        fill(&mut frame, [14, 18, 24, 255]);
        rect(&mut frame, 0, 0, WIDTH, 30, [132, 44, 52, 255]);
        text(&mut frame, 10, 10, TITLE, [255, 255, 255, 255]);
        text(&mut frame, 10, 40, REQUIRED_COPY, [255, 204, 204, 255]);
        text(&mut frame, 10, 54, RECEIPT_COPY, [178, 186, 199, 255]);
        text(
            &mut frame,
            10,
            66,
            &surface.condition.failure.receipt(),
            [235, 238, 242, 255],
        );
        text(
            &mut frame,
            10,
            78,
            &surface.condition.occurred_at,
            [178, 186, 199, 255],
        );
        text(
            &mut frame,
            10,
            90,
            &surface.condition.evidence.0,
            [178, 186, 199, 255],
        );

        for (index, capability) in surface.capabilities.iter().enumerate() {
            let y = 112 + index * 34;
            let (color, status, detail) = match capability {
                Capability::Available { label, .. } => {
                    ([35, 116, 79, 255], "AVAILABLE", label.as_str())
                }
                Capability::Unavailable { reason, .. } => {
                    ([62, 67, 76, 255], "UNAVAILABLE", reason.as_str())
                }
            };
            rect(&mut frame, 8, y, 304, 28, color);
            text(&mut frame, 14, y + 5, status, [255, 255, 255, 255]);
            text(&mut frame, 94, y + 5, detail, [255, 255, 255, 255]);
            let guidance = match capability.action() {
                RecoveryAction::OtaUpdate if matches!(capability, Capability::Available { .. }) => {
                    OTA_AVAILABLE_COPY
                }
                RecoveryAction::OtaUpdate => OTA_UNAVAILABLE_COPY,
                RecoveryAction::FelRecovery => FEL_FLOOR_COPY,
            };
            text(&mut frame, 14, y + 16, guidance, [220, 225, 231, 255]);
        }
        if let Some(result) = &surface.last_result {
            rect(&mut frame, 8, 184, 304, 44, [27, 57, 88, 255]);
            text(&mut frame, 14, 190, "RESULT", [151, 207, 255, 255]);
            text(
                &mut frame,
                14,
                202,
                &result_copy(result),
                [255, 255, 255, 255],
            );
        }
        frame
    }

    fn result_copy(result: &ActionResult) -> String {
        match result {
            ActionResult::OtaUpdateStarted { release } => format!("OTA update started: {release}"),
            ActionResult::OtaUpdateCompleted { release } => {
                format!("OTA update completed: {release}")
            }
            ActionResult::OtaUpdateFailed { reason, .. } => format!("OTA update failed: {reason}"),
            ActionResult::FelInstructionsShown => "FEL recovery instructions shown".into(),
            ActionResult::FelRecoveryDetected => "FEL recovery detected".into(),
            ActionResult::FelRecoveryFailed { reason, .. } => {
                format!("FEL recovery failed: {reason}")
            }
        }
    }

    pub fn stable_hash(frame: &Frame) -> Result<String, std::num::TryFromIntError> {
        let width = u32::try_from(frame.width)?;
        let height = u32::try_from(frame.height)?;
        let mut hash = 0xcbf29ce484222325_u64;
        for byte in width
            .to_le_bytes()
            .into_iter()
            .chain(height.to_le_bytes())
            .chain(frame.rgba.iter().copied())
        {
            hash ^= u64::from(byte);
            hash = hash.wrapping_mul(0x100000001b3);
        }
        Ok(format!("{hash:016x}"))
    }

    fn fill(frame: &mut Frame, color: [u8; 4]) {
        for pixel in frame.rgba.as_chunks_mut::<4>().0 {
            pixel.copy_from_slice(&color);
        }
    }
    fn rect(frame: &mut Frame, x: usize, y: usize, w: usize, h: usize, color: [u8; 4]) {
        for row in y..(y + h).min(frame.height) {
            for col in x..(x + w).min(frame.width) {
                let offset = (row * frame.width + col) * 4;
                frame.rgba[offset..offset + 4].copy_from_slice(&color);
            }
        }
    }
    // Source-owned embedded 5x7 diagnostic type; no font or theme package is needed.
    fn text(frame: &mut Frame, x: usize, y: usize, value: &str, color: [u8; 4]) {
        let mut cursor = x;
        for byte in value.bytes().take((frame.width.saturating_sub(x)) / 6) {
            for (row, bits) in glyph(byte.to_ascii_uppercase()).into_iter().enumerate() {
                for col in 0..5 {
                    if bits & (1 << (4 - col)) != 0 {
                        rect(frame, cursor + col, y + row, 1, 1, color);
                    }
                }
            }
            cursor += 6;
        }
    }

    fn glyph(byte: u8) -> [u8; 7] {
        match byte {
            b'A' => [14, 17, 17, 31, 17, 17, 17],
            b'B' => [30, 17, 17, 30, 17, 17, 30],
            b'C' => [14, 17, 16, 16, 16, 17, 14],
            b'D' => [30, 17, 17, 17, 17, 17, 30],
            b'E' => [31, 16, 16, 30, 16, 16, 31],
            b'F' => [31, 16, 16, 30, 16, 16, 16],
            b'G' => [14, 17, 16, 23, 17, 17, 15],
            b'H' => [17, 17, 17, 31, 17, 17, 17],
            b'I' => [14, 4, 4, 4, 4, 4, 14],
            b'J' => [7, 2, 2, 2, 18, 18, 12],
            b'K' => [17, 18, 20, 24, 20, 18, 17],
            b'L' => [16, 16, 16, 16, 16, 16, 31],
            b'M' => [17, 27, 21, 21, 17, 17, 17],
            b'N' => [17, 25, 21, 19, 17, 17, 17],
            b'O' => [14, 17, 17, 17, 17, 17, 14],
            b'P' => [30, 17, 17, 30, 16, 16, 16],
            b'Q' => [14, 17, 17, 17, 21, 18, 13],
            b'R' => [30, 17, 17, 30, 20, 18, 17],
            b'S' => [15, 16, 16, 14, 1, 1, 30],
            b'T' => [31, 4, 4, 4, 4, 4, 4],
            b'U' => [17, 17, 17, 17, 17, 17, 14],
            b'V' => [17, 17, 17, 17, 17, 10, 4],
            b'W' => [17, 17, 17, 21, 21, 21, 10],
            b'X' => [17, 17, 10, 4, 10, 17, 17],
            b'Y' => [17, 17, 10, 4, 4, 4, 4],
            b'Z' => [31, 1, 2, 4, 8, 16, 31],
            b'0' => [14, 17, 19, 21, 25, 17, 14],
            b'1' => [4, 12, 4, 4, 4, 4, 14],
            b'2' => [14, 17, 1, 2, 4, 8, 31],
            b'3' => [30, 1, 1, 14, 1, 1, 30],
            b'4' => [2, 6, 10, 18, 31, 2, 2],
            b'5' => [31, 16, 16, 30, 1, 1, 30],
            b'6' => [14, 16, 16, 30, 17, 17, 14],
            b'7' => [31, 1, 2, 4, 8, 8, 8],
            b'8' => [14, 17, 17, 14, 17, 17, 14],
            b'9' => [14, 17, 17, 15, 1, 1, 14],
            b':' => [0, 4, 4, 0, 4, 4, 0],
            b'.' => [0, 0, 0, 0, 0, 6, 6],
            b'/' => [1, 1, 2, 4, 8, 16, 16],
            b'-' => [0, 0, 0, 31, 0, 0, 0],
            b'(' => [2, 4, 8, 8, 8, 4, 2],
            b')' => [8, 4, 2, 2, 2, 4, 8],
            b'_' => [0, 0, 0, 0, 0, 0, 31],
            b' ' => [0; 7],
            _ => [14, 17, 1, 2, 4, 0, 4],
        }
    }
}
