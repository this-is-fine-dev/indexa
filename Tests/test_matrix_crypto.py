"""Offline native E2EE smoke test. Run with matrix-nio[e2e]==0.26.0, vodozemac==0.10.0."""
import secrets
import tempfile
from pathlib import Path

from nio.crypto import InboundGroupSession, OlmAccount, OutboundGroupSession


def test_native_crypto():
    keys = OlmAccount().identity_keys
    room = "!synthetic:indexa.test"
    outbound = OutboundGroupSession()
    inbound = InboundGroupSession(
        outbound.session_key, keys["ed25519"], keys["curve25519"], room
    )
    outbound.mark_as_shared()
    message = "Indexa — test szyfrowania 📝"
    encrypted = outbound.encrypt(message)
    assert message not in encrypted
    assert inbound.decrypt(encrypted) == (message, 0)

    # Restore keys from encrypted storage; a restart must retain access to the session.
    passphrase = secrets.token_hex(32)
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "synthetic-session"
        path.write_bytes(inbound.pickle(passphrase))
        restored = InboundGroupSession.from_pickle(
            path.read_bytes(), keys["ed25519"], keys["curve25519"], room, passphrase
        )
        assert restored.decrypt(outbound.encrypt(message)) == (message, 1)
        try:
            InboundGroupSession.from_pickle(
                path.read_bytes(), keys["ed25519"], keys["curve25519"], room, "wrong"
            )
        except Exception:
            pass
        else:
            raise AssertionError("Wrong passphrase unlocked encryption keys")


if __name__ == "__main__":
    test_native_crypto()
    print("PASS: native E2EE round-trip, key persistence, wrong-passphrase rejection")
