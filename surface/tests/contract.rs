use pocketforge_recovery_surface::{
    offscreen, Capability, EvidencePointer, Failure, RecoveryAction, RecoveryRequired,
    RecoverySurface,
};

fn condition() -> RecoveryRequired {
    RecoveryRequired {
        failure: Failure::BootVerification {
            component: "rootfs".into(),
        },
        occurred_at: "2026-08-29T14:30:00Z".into(),
        evidence: EvidencePointer("pf-evidence://boot/sha256:012345".into()),
    }
}

fn capabilities() -> Vec<Capability> {
    vec![
        Capability::Unavailable {
            action: RecoveryAction::OtaUpdate,
            reason: "Network is not reachable".into(),
        },
        Capability::Available {
            action: RecoveryAction::FelRecovery,
            label: "Recover with FEL".into(),
        },
    ]
}

#[test]
fn condition_and_capabilities_round_trip() {
    let fixture = RecoverySurface {
        condition: condition(),
        capabilities: capabilities(),
        last_result: None,
    };
    let encoded = serde_json::to_string(&fixture).unwrap();
    let decoded: RecoverySurface = serde_json::from_str(&encoded).unwrap();
    assert_eq!(decoded, fixture);
}

#[test]
fn available_and_unavailable_states_are_covered() {
    assert!(matches!(capabilities()[0], Capability::Unavailable { .. }));
    assert!(matches!(capabilities()[1], Capability::Available { .. }));
    assert_eq!(
        capabilities()[1].activate().unwrap().action(),
        RecoveryAction::FelRecovery
    );
}

#[test]
fn unsupported_action_cannot_activate() {
    let error = capabilities()[0].activate().unwrap_err();
    assert_eq!(error.action, RecoveryAction::OtaUpdate);
    assert_eq!(error.reason, "Network is not reachable");
}

#[test]
fn offscreen_fixture_has_stable_hash() {
    let fixture = RecoverySurface {
        condition: condition(),
        capabilities: capabilities(),
        last_result: None,
    };
    let frame = offscreen::render(&fixture);
    assert_eq!(frame.rgba.len(), offscreen::WIDTH * offscreen::HEIGHT * 4);
    assert_eq!(offscreen::stable_hash(&frame), "35355fa5825f61a5");
}
