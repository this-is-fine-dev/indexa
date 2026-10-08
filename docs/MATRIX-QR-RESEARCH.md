# Element X QR login — implementation research

Verified 2026-10-07 against Matrix Rust SDK 0.19.1, MAS 1.26.0, Synapse 1.162.0, and current Element X iOS source. User now explicitly requests QR login and permits a fresh Matrix setup. This supersedes the earlier decision to defer MAS.

## Minimum supported architecture

Keep native Synapse. Add native PostgreSQL and MAS; compile MAS on macOS. The MAS 1.26.0 release API lists only Linux aarch64/x86_64 archives. Those archives include platform-independent `share/` assets (templates, compiled policy, frontend, translations), which can accompany the native binary. No VM/container is required. [MAS installation](https://element-hq.github.io/matrix-authentication-service/setup/installation.html), [release](https://github.com/element-hq/matrix-authentication-service/releases/tag/v1.26.0), [database](https://element-hq.github.io/matrix-authentication-service/setup/database.html).

Use a small native Rust sidecar for the existing owner device. Matrix Rust SDK implements both sides of QR login; do not invent cryptography or encode passwords into a QR. QR login is OAuth device authorization followed by an encrypted transfer of cross-signing secrets. [SDK OAuth module](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/oauth/mod.rs), [QR grant implementation](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/oauth/qrcode/grant.rs).

## Element X supports the required direction

Element X iOS login mode scans the desktop QR, receives raw `Data`, and invokes `loginService.loginWithQRCode(data: qrData)`. Its separate link-mobile mode displays a QR. Indexa should display the QR and Element X should use its initial QR login scanner. This is distinct from in-session identity verification QR. [Element X QR view model, handleScan](https://github.com/element-hq/element-x-ios/blob/develop/ElementX/Sources/Screens/QRCodeLoginScreen/QRCodeLoginScreenViewModel.swift#L118).

## Native SDK API

Minimal dependency configuration, based on the pinned crate feature definitions:

```toml
matrix-sdk = { version = "=0.19.1", default-features = false, features = ["e2e-encryption", "sqlite", "rustls-aws-lc-rs"] }
tokio = { version = "1", features = ["rt-multi-thread", "macros", "io-util", "io-std", "sync"] }
futures-util = "0.3"
serde_json = "1"
```

`qrcode` is the device-verification QR feature and is not needed for login QR serialization. Add `bundled-sqlite` only if system SQLite linkage becomes an issue. [Cargo features](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/Cargo.toml).

Create the owner client with a private encrypted crypto store:

```rust
use matrix_sdk::{Client, SessionMeta, SessionTokens, store::RoomLoadSettings};
use matrix_sdk::authentication::matrix::MatrixSession;

let client = Client::builder()
    .homeserver_url(public_homeserver_url)
    .sqlite_store(private_store_path, Some(store_passphrase))
    .build().await?;
client.matrix_auth().restore_session(MatrixSession {
    meta: SessionMeta {
        user_id: owner_user_id.parse()?,
        device_id: owner_device_id.into(),
    },
    tokens: SessionTokens { access_token: owner_token.into(), refresh_token: None },
}, RoomLoadSettings::default()).await?;
```

This is an API sketch, not a compiled artifact. Token/passphrase arrive over private stdin, never command arguments or logs. Reuse the existing encrypted vault and private directory policy. [Client builder](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/client/builder/mod.rs), [session restore](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/matrix/mod.rs).

MAS can provision nonadmin users and issue stable compatibility tokens with `mas-cli manage register-user --yes owner` and `mas-cli manage issue-compatibility-token owner INDEXA_OWNER`. Do not supply the admin-token option. Issue a separate bot token similarly. A compatibility token should suffice for the grant side because its implementation uses the client's Matrix identity/crypto store and does not retrieve an OAuth user session; **this is an implementation inference requiring a live test**. [CLI management](https://element-hq.github.io/matrix-authentication-service/reference/cli/manage.html).

Before granting, bootstrap cross-signing on the fresh owner account with `client.encryption().bootstrap_cross_signing(None).await?`, after initial sync/key upload as needed. Do not repeat a reset on every launch. All three private cross-signing keys must exist. Backup is optional; an existing backup private key without its backup version is an error. Persist this store across launches. [Secret export implementation](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk-crypto/src/store/mod.rs#L1078), [bootstrap example](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/examples/cross_signing_bootstrap/src/main.rs).

The exact grant loop is documented beside `GrantLoginWithQrCodeBuilder::generate`:

```rust
let oauth = client.oauth();
let grant = oauth.grant_login_with_qr_code().generate();
let mut progress = grant.subscribe_to_progress();
// Process progress concurrently with grant.await.
```

Events from `GrantLoginProgress<GeneratedQrProgress>`:

- `EstablishingSecureChannel(QrReady(data))`: send `data.to_base64()` over the local IPC. Swift decodes Base64 to raw bytes and gives those bytes to `CIQRCodeGenerator`. Do not encode Base64 text itself in the visual QR.
- `EstablishingSecureChannel(QrScanned(sender))`: request the two-digit check code displayed by Element X; parse `u8` and call `sender.send(code).await?`. Never auto-confirm or guess.
- `WaitingForAuth { verification_uri, continuation_sender }`: display the MAS consent page, then call `continuation_sender.confirm().await?` when the app is ready to continue. This resumes the protocol; it does not itself grant consent on MAS.
- `SyncingSecrets`, `Done`: show status; SDK completes secure secret transfer.

Sender types are cloneable `CheckCodeSender` and `ContinuationMessageSender`; cancel via the latter's `.cancel()` or by dropping/aborting the grant task. [Builder API sample](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/oauth/mod.rs#L1710), [progress/sender definitions](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/oauth/qrcode/mod.rs), [QR byte encoding](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk-crypto/src/types/qr_login/mod.rs).

For a native UI, a MAS web consent view may be embedded, with credentials managed only against a pinned MAS origin and no external navigation. The upstream SDK describes opening a secure system browser; an embedded view is an Indexa integration choice, not an SDK requirement demonstrated by a test. Do not silently approve new devices. MAS uses browser-session cookies and CSRF-protected forms. [MAS device consent handler](https://github.com/element-hq/matrix-authentication-service/blob/v1.26.0/crates/handlers/src/oauth2/device/consent.rs).

## Local rendezvous and routing

Synapse already implements the rendezvous storage: enable `experimental_features.msc4108_enabled: true`, along with `matrix_authentication_service.enabled: true`. No third-party relay and no custom relay code are needed. POST `/_matrix/client/unstable/org.matrix.msc4108/rendezvous` creates sessions. [Synapse routes](https://github.com/element-hq/synapse/blob/v1.162.0/synapse/rest/client/rendezvous.py), [configuration](https://github.com/element-hq/synapse/blob/v1.162.0/synapse/config/experimental.py).

Set Synapse `public_baseurl` to its reachable Tailscale HTTPS address. **The owner Rust SDK client must also use the public HTTPS homeserver URL**, because generated QR `server_name` is exactly `client.homeserver().to_string()`, including any port. A localhost-configured owner produces an unusable phone QR. [Secure channel reciprocate implementation](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/oauth/qrcode/secure_channel/mod.rs#L66).

Configure matching MAS/Synapse shared secrets. Route `/_matrix/client/*/login`, `/logout`, and `/refresh` to MAS; remaining Matrix API traffic including rendezvous to Synapse. MAS public issuer/web endpoints must be reachable over Tailscale HTTPS. Prefer separate HTTPS origin/port and native local reverse proxy if necessary; this is a deployment choice. Do not alter the corporate VPN. [MAS homeserver configuration](https://element-hq.github.io/matrix-authentication-service/setup/homeserver.html), [MAS public URL](https://element-hq.github.io/matrix-authentication-service/setup/running.html).

## Meaningful verification

Use a second Rust SDK client as the new device: decode generated bytes using `QrCodeData::from_bytes`, extract `Msc4108IntentData::Reciprocate { server_name }`, build its client, and call `oauth.login_with_qr_code(Some(&registration_data)).scan(&data)`. Subscribe before awaiting; its `LoginProgress::EstablishingSecureChannel(QrProgress { check_code })` supplies the check code, and `WaitingForToken { user_code }` supplies the OAuth user code. Use a real MAS consent transaction in the isolated test account. Assert owner user ID, new device ID, imported cross-signing secrets, and encrypted message round trip. Finally remove the disposable device. Negative checks: wrong check code rejects; cancellation/expiration rejects; mismatched MAS URI is not opened. [Official reciprocal example](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/examples/qr_login/src/main.rs), [SDK generated-grant tests](https://github.com/matrix-org/matrix-rust-sdk/blob/matrix-sdk-0.19.1/crates/matrix-sdk/src/authentication/oauth/qrcode/grant.rs).

Passing a desktop integration test proves protocol/server interoperability, not the user's iPhone camera/login UX. A final Element X scan is still necessary before claiming phone acceptance.
