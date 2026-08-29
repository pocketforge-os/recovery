use pocketforge_recovery_surface::{offscreen, *};

fn condition() -> RecoveryRequired {
    RecoveryRequired {
        failure: Failure::BootVerification {
            component: "rootfs".into(),
        },
        occurred_at: "2026-08-29T14:30:00Z".into(),
        evidence: EvidencePointer("pf-evidence://boot/sha256:012345".into()),
    }
}
fn surface(ota_available: bool) -> RecoverySurface {
    RecoverySurface {
        condition: condition(),
        capabilities: vec![
            if ota_available {
                Capability::Available {
                    action: RecoveryAction::OtaUpdate,
                    label: "Update with OTA".into(),
                }
            } else {
                Capability::Unavailable {
                    action: RecoveryAction::OtaUpdate,
                    reason: "Network is not reachable".into(),
                }
            },
            Capability::Available {
                action: RecoveryAction::FelRecovery,
                label: "Recover with FEL".into(),
            },
        ],
        last_result: None,
    }
}

#[test]
fn contract_round_trips() {
    let s = surface(false);
    assert_eq!(
        serde_json::from_str::<RecoverySurface>(&serde_json::to_string(&s).unwrap()).unwrap(),
        s
    );
}
#[test]
fn available_action_emits_typed_intent_only() {
    assert_eq!(
        surface(true).activate(0).unwrap(),
        RecoveryIntent::StartOtaUpdate
    );
    assert_eq!(
        surface(false).activate(1).unwrap(),
        RecoveryIntent::ShowFelRecovery
    );
}
#[test]
fn unavailable_action_cannot_activate() {
    let error = surface(false).activate(0).unwrap_err();
    assert_eq!(
        error,
        ActivationError::Unavailable {
            action: RecoveryAction::OtaUpdate,
            reason: "Network is not reachable".into(),
        }
    );
}
#[test]
fn out_of_range_selection_returns_typed_error() {
    let mut empty = surface(true);
    empty.capabilities.clear();
    assert_eq!(
        empty.activate(0),
        Err(ActivationError::InvalidSelection { index: 0 })
    );
    assert_eq!(
        surface(true).activate(2),
        Err(ActivationError::InvalidSelection { index: 2 })
    );
}
#[test]
fn typed_result_is_presented() {
    let mut s = surface(true);
    s.present_result(ActionResult::OtaUpdateCompleted {
        release: "2026.08".into(),
    });
    assert!(matches!(
        s.last_result,
        Some(ActionResult::OtaUpdateCompleted { .. })
    ));
}

#[test]
fn committed_frame_hashes_cover_condition_capabilities_and_results() {
    let expected = include_str!("../fixtures/frame-hashes.txt");
    let unavailable = surface(false);
    let available = surface(true);
    let mut result = surface(true);
    result.present_result(ActionResult::OtaUpdateFailed {
        reason: "signature invalid".into(),
        evidence: EvidencePointer("pf-evidence://ota/failed".into()),
    });
    let actual=format!("condition-capabilities-unavailable {}\ncondition-capabilities-available {}\ntyped-result {}\n",
        offscreen::stable_hash(&offscreen::render(&unavailable)).unwrap(),
        offscreen::stable_hash(&offscreen::render(&available)).unwrap(),
        offscreen::stable_hash(&offscreen::render(&result)).unwrap());
    assert_eq!(actual, expected);
}

#[test]
fn exact_customer_copy_fixture_is_safe() {
    let fixture = include_str!("../fixtures/customer-copy.txt");
    assert_eq!(
        fixture,
        format!("{OTA_AVAILABLE_COPY}\n{OTA_UNAVAILABLE_COPY}\n{FEL_FLOOR_COPY}\n")
    );
    let lower = fixture.to_ascii_lowercase();
    assert!(lower.contains("ota") && lower.contains("network") && lower.contains("fel"));
    for forbidden in ["sd card", "remove the card", "swap", "reflash"] {
        assert!(
            !lower.contains(forbidden),
            "forbidden movement copy: {forbidden}"
        );
    }
}

#[test]
fn stable_hash_uses_canonical_u32_dimensions() {
    let f = offscreen::Frame {
        width: 1,
        height: 1,
        rgba: vec![0x12, 0x34, 0x56, 0x78],
    };
    assert_eq!(offscreen::stable_hash(&f).unwrap(), "3ca103ceef0d1915");
}
#[cfg(target_pointer_width = "64")]
#[test]
fn stable_hash_rejects_oversize_dimensions() {
    let f = offscreen::Frame {
        width: u32::MAX as usize + 1,
        height: 1,
        rgba: vec![],
    };
    assert!(offscreen::stable_hash(&f).is_err());
}
