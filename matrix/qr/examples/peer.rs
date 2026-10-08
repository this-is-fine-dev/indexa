//! Disposable protocol peer for the real QR integration check, never bundled.
use anyhow::{Context, Result};
use futures_util::StreamExt;
use matrix_sdk::{Client, authentication::oauth::{qrcode::{QrCodeData, QrCodeIntentData, Msc4108IntentData, LoginProgress, QrProgress}, registration::{ClientMetadata, ApplicationType, OAuthGrantType, Localized}}, ruma::serde::Raw};
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, BufReader};
use std::{io::Write, time::Duration};
fn emit(value:Value) { println!("{value}");let _=std::io::stdout().flush(); }
#[tokio::main(worker_threads=2)]
async fn main() -> Result<()> {
    let mut input=BufReader::new(tokio::io::stdin()).lines();
    let line=input.next_line().await?.context("input")?;
    let data=QrCodeData::from_base64(line.trim())?;
    let QrCodeIntentData::Msc4108 {data:Msc4108IntentData::Reciprocate{server_name},..}=data.intent_data() else {anyhow::bail!("qr_intent")};
    let client=Client::builder().homeserver_url(server_name).handle_refresh_tokens().build().await?;
    let mut metadata=ClientMetadata::new(ApplicationType::Native,vec![OAuthGrantType::DeviceCode],Localized::new(url::Url::parse("https://github.com/matrix-org/matrix-rust-sdk")?,[]));
    metadata.client_name=Some(Localized::new("Indexa disposable QR check".to_owned(),[]));
    let registration=Raw::new(&metadata)?.into();
    let oauth=client.oauth();
    let login=oauth.login_with_qr_code(Some(&registration)).scan(&data);
    let mut progress=login.subscribe_to_progress();
    let login=async { login.await };tokio::pin!(login);
    loop {
        let state=tokio::select! {r=&mut login=>{r?;break;},s=progress.next()=>s.context("progress_closed")?};
        match state {
            LoginProgress::EstablishingSecureChannel(QrProgress{check_code})=>emit(json!({"state":"code","code":format!("{check_code:02}")})),
            LoginProgress::WaitingForToken{user_code}=>emit(json!({"state":"token","code":user_code})),
            _=>(),
        }
    }
    let complete=client.encryption().cross_signing_status().await.context("identity")?.is_complete();
    emit(json!({"state":"done","user":client.user_id().map(|x|x.as_str()),"device":client.device_id().map(|x|x.as_str()),"cross_signing":complete}));
    // Keep session available long enough for the granting client to inspect signatures.
    let _=tokio::time::timeout(Duration::from_secs(30),input.next_line()).await;
    client.logout().await?;
    emit(json!({"state":"logged_out"}));
    Ok(())
}
