//! One pairing session per process. Secrets arrive on stdin, never argv or logs.
use anyhow::{bail, Context, Result};
use futures_util::StreamExt;
use matrix_sdk::{
    authentication::{matrix::MatrixSession, oauth::qrcode::{GeneratedQrProgress, GrantLoginProgress}},
    config::SyncSettings,
    Client, SessionMeta, SessionTokens,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{io::Write, path::PathBuf, time::Duration};
use tokio::io::{AsyncBufReadExt, BufReader};
use url::Url;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    homeserver: String,
    user: String,
    token: String,
    store: PathBuf,
    pickle: String,
    #[serde(default)]
    initialize: bool,
    #[serde(default)]
    verify_identity: Option<VerifyIdentity>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VerifyIdentity { user: String, master: String, device: String, key: String }

fn emit(value: Value) {
    println!("{value}");
    let _ = std::io::stdout().flush();
}

async fn run() -> Result<()> {
    let mut input = BufReader::new(tokio::io::stdin()).lines();
    let frame = input.next_line().await?.context("credentials_missing")?;
    if frame.len() > 16384 { bail!("credentials_too_large"); }
    let credentials: Credentials = serde_json::from_str(&frame)?;
    let origin = Url::parse(&credentials.homeserver)?;
    if origin.scheme() != "https" || origin.host_str().is_none() || !origin.username().is_empty() || origin.password().is_some() {
        bail!("invalid_homeserver");
    }
    let client = Client::builder().homeserver_url(&credentials.homeserver)
        .sqlite_store(&credentials.store, Some(&credentials.pickle))
        .build().await?;
    client.restore_session(MatrixSession {
        meta: SessionMeta { user_id: credentials.user.parse()?, device_id: "INDEXA_OWNER".into() },
        tokens: SessionTokens { access_token: credentials.token, refresh_token: None },
    }).await?;
    client.sync_once(SyncSettings::default().timeout(Duration::ZERO)).await?;
    if credentials.initialize {
        // Only on explicit fresh setup, never reset a pre-existing identity during login.
        client.encryption().bootstrap_cross_signing(None).await?;
        emit(json!({"state":"initialized"}));
        return Ok(());
    }
    let status = client.encryption().cross_signing_status().await.context("identity_missing")?;
    if !status.is_complete() { bail!("identity_missing"); }
    if let Some(expected) = credentials.verify_identity {
        let own = client.user_id().context("owner_missing")?;
        if expected.user != format!("@indexa:{}", own.server_name()) || expected.device != "INDEXA_BOT" {
            bail!("unexpected_bot_identity");
        }
        let user = expected.user.parse::<matrix_sdk::ruma::OwnedUserId>()?;
        let identity = client.encryption().request_user_identity(&user).await?.context("bot_identity_missing")?;
        if identity.master_key().get_first_key().map(|key| key.to_base64()).as_deref() != Some(&expected.master) {
            bail!("bot_master_key_mismatch");
        }
        let device = client.encryption().get_device(&user, expected.device.as_str().into()).await?.context("bot_device_missing")?;
        if device.ed25519_key().map(|key| key.to_base64()).as_deref() != Some(&expected.key) || !device.is_cross_signed_by_owner() {
            bail!("bot_device_signature_mismatch");
        }
        identity.verify().await?;
        let identity = client.encryption().request_user_identity(&user).await?.context("bot_identity_missing")?;
        let device = client.encryption().get_device(&user, expected.device.as_str().into()).await?.context("bot_device_missing")?;
        if !identity.is_verified() || !device.is_verified_with_cross_signing() { bail!("bot_verification_failed"); }
        emit(json!({"state":"identity_verified"}));
        return Ok(());
    }
    let owner = client.user_id().context("owner_missing")?.to_owned();
    client.encryption().request_user_identity(&owner).await?;
    let previous: Vec<_> = client.encryption().get_user_devices(&owner).await?.keys().map(|id| id.to_owned()).collect();
    let oauth = client.oauth();
    let grant = oauth.grant_login_with_qr_code().generate();
    let mut progress = grant.subscribe_to_progress();
    let grant = async { grant.await };
    tokio::pin!(grant);
    loop {
        let state = tokio::select! {
            result = &mut grant => { result?; break; },
            state = progress.next() => state.context("progress_closed")?,
        };
        match state {
            GrantLoginProgress::Starting | GrantLoginProgress::SyncingSecrets => (),
            GrantLoginProgress::EstablishingSecureChannel(GeneratedQrProgress::QrReady(data)) => {
                emit(json!({"state":"qr","data":data.to_base64()}));
            }
            GrantLoginProgress::EstablishingSecureChannel(GeneratedQrProgress::QrScanned(sender)) => {
                emit(json!({"state":"code"}));
                let line = input.next_line().await?.context("cancelled")?;
                let command: Value = serde_json::from_str(&line)?;
                let code = command.get("code").and_then(Value::as_u64).filter(|x| *x < 100).context("invalid_check_code")?;
                sender.send(code as u8).await?;
            }
            GrantLoginProgress::WaitingForAuth { verification_uri, continuation_sender } => {
                let target = Url::parse(verification_uri.as_str())?;
                if target.origin() != origin.origin() || target.path() != "/link" {
                    bail!("unexpected_authorization_server");
                }
                emit(json!({"state":"consent","url":target.as_str()}));
                // This only starts OAuth polling on the phone. MAS still requires
                // the user's explicit consent in the embedded authentication page.
                continuation_sender.confirm().await?;
            }
            GrantLoginProgress::Done => (),
        }
    }
    // The phone publishes its signature after importing the transferred identity.
    // Only keys verified by that identity may become trusted by the bot.
    for _ in 0..30 {
        client.encryption().request_user_identity(&owner).await?;
        let devices = client.encryption().get_user_devices(&owner).await?;
        let verified: Vec<_> = devices.devices().filter(|device|
            device.is_verified_with_cross_signing())
            .filter_map(|device| device.ed25519_key().map(|key|
                json!({"id":device.device_id().as_str(),"key":key.to_base64()}))).collect();
        if verified.iter().any(|device| !previous.iter().any(|id| Some(id.as_str()) == device["id"].as_str())) {
            emit(json!({"state":"done","devices":verified}));
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    bail!("new_device_signature_missing");
}

#[tokio::main(worker_threads = 2)]
async fn main() {
    // No SDK logs: HTTP/crypto errors can include authentication data.
    let result = tokio::time::timeout(Duration::from_secs(180), run()).await;
    match result {
        Ok(Ok(())) => (),
        Ok(Err(_)) => { emit(json!({"state":"error","error":"pairing_failed"})); std::process::exit(1); }
        Err(_) => { emit(json!({"state":"error","error":"pairing_expired"})); std::process::exit(1); }
    }
}
