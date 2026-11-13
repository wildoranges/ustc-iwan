//! Shared client-side VPN handshake.
//!
//! All CLI entry points (manual auth/proxy, SOCKS/HTTP, OIDC) use this module
//! instead of re-implementing OPEN/AUTH_VERIFY/ACK handling.

use super::auth;
use super::crypto;
use super::sr::SrConfig;
use anyhow::{Context, Result};
use std::net::UdpSocket;
use std::time::Duration;

pub struct SessionConfig<'a> {
    pub server: &'a str,
    pub port: u16,
    pub user: &'a str,
    pub pass: &'a str,
    pub ct_pass: Option<&'a str>,
    pub salt: &'a str,
    pub mtu: u16,
    pub encrypt: u8,
    pub bind: Option<&'a str>,
    pub pipe: Option<(u16, u16)>,
    pub srlink: Option<u32>,
    pub sr: Option<SrConfig>,
}

pub struct ClientSession {
    pub sock: UdpSocket,
    pub auth: auth::AuthResult,
    pub xor_key: Vec<u8>,
    pub aes_key: Vec<u8>,
    pub encryption: u8,
    pub sr: Option<SrConfig>,
}

pub fn open(config: &SessionConfig<'_>) -> Result<ClientSession> {
    let ct = auth::get_ct(config.user, config.pass, config.ct_pass, config.salt)?;
    let nonce = auth::rand_u32();
    let mut open = auth::build_open(
        config.user,
        &ct,
        config.mtu,
        config.encrypt,
        config.pipe,
        config.srlink,
        Some(nonce),
    );
    let mut sent_auth_verify = true;
    let sock = auth::udp_connect(config.server, config.port, 3000, config.bind)?;

    let mut result = None;
    let mut last_error = None;
    for attempt in 0..=3 {
        sock.send(&open).context("send OPEN")?;
        println!("[{attempt}] -> OPEN");
        let mut buf = [0u8; 4096];
        match sock.recv(&mut buf) {
            Ok(n) => match auth::parse_ack(&buf[..n], nonce) {
                Ok(value) => {
                    if sent_auth_verify && value.tun.is_empty() {
                        eprintln!(
                            "  Server returned no tunnel IP for AUTH_VERIFY; retrying legacy handshake..."
                        );
                        open = auth::build_open(
                            config.user,
                            &ct,
                            config.mtu,
                            config.encrypt,
                            config.pipe,
                            config.srlink,
                            None,
                        );
                        sent_auth_verify = false;
                        continue;
                    }
                    value
                        .tun
                        .parse::<std::net::Ipv4Addr>()
                        .context("server returned no valid tunnel IPv4 address")?;
                    result = Some(value);
                    break;
                }
                Err(e) => last_error = Some(e),
            },
            Err(e) => last_error = Some(anyhow::anyhow!("timeout: {e}")),
        }
        if attempt < 3 {
            std::thread::sleep(Duration::from_secs(1));
        }
    }
    let auth =
        result.ok_or_else(|| last_error.unwrap_or_else(|| anyhow::anyhow!("auth failed")))?;
    let encryption = auth.enc.unwrap_or(config.encrypt);
    if encryption > 2 {
        anyhow::bail!("server selected unsupported encrypt mode {encryption}");
    }
    let key = crypto::session_key(config.user, config.pass);
    Ok(ClientSession {
        sock,
        auth,
        xor_key: key[..8].to_vec(),
        aes_key: key.to_vec(),
        encryption,
        sr: config.sr.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::protocol;

    fn mock_handshake(legacy: bool, valid_ip: bool) -> Result<ClientSession> {
        let gateway = UdpSocket::bind("127.0.0.1:0").unwrap();
        gateway
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let port = gateway.local_addr().unwrap().port();
        let peer = std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            let (n, addr) = gateway.recv_from(&mut buf).unwrap();
            let initial = protocol::parse_tlvs(&buf[24..n]);
            let nonce = initial
                .iter()
                .find(|tlv| tlv.typ == protocol::TlvType::AuthVerify)
                .unwrap()
                .value
                .clone();
            let header = protocol::pkhdr(protocol::PT_OPEN_ACK, 1, 1, 1);
            if legacy {
                let challenge = protocol::tlv(protocol::T_AUTH_VERIFY, &nonce);
                gateway
                    .send_to(&protocol::ctrl_pkt(&header, &challenge), addr)
                    .unwrap();
                let (n, retry_addr) = gateway.recv_from(&mut buf).unwrap();
                assert_eq!(retry_addr, addr);
                assert!(protocol::verify_sig(&buf[..n]));
                let expected: Vec<_> = initial
                    .into_iter()
                    .filter(|tlv| tlv.typ != protocol::TlvType::AuthVerify)
                    .collect();
                assert_eq!(protocol::parse_tlvs(&buf[24..n]), expected);
            }
            let mut payload = Vec::new();
            if valid_ip {
                payload.extend(protocol::tlv(protocol::T_IP, &[10, 0, 0, 2]));
            }
            if !legacy {
                payload.extend(protocol::tlv(protocol::T_AUTH_VERIFY, &nonce));
            }
            gateway
                .send_to(&protocol::ctrl_pkt(&header, &payload), addr)
                .unwrap();
        });
        let result = open(&SessionConfig {
            server: "127.0.0.1",
            port,
            user: "test-user",
            pass: "test-password",
            ct_pass: None,
            salt: "test-salt",
            mtu: 1400,
            encrypt: 1,
            bind: Some("127.0.0.1"),
            pipe: Some((1, 2)),
            srlink: Some(1),
            sr: None,
        });
        peer.join().unwrap();
        result
    }

    #[test]
    fn authentication_retries_legacy_open_when_challenge_has_no_ip() {
        assert_eq!(mock_handshake(true, true).unwrap().auth.tun, "10.0.0.2");
    }

    #[test]
    fn authentication_accepts_complete_ack_without_fallback() {
        assert_eq!(mock_handshake(false, true).unwrap().auth.tun, "10.0.0.2");
    }

    #[test]
    fn authentication_rejects_legacy_ack_without_ip() {
        let err = mock_handshake(true, false)
            .err()
            .expect("must reject missing IP");
        assert!(err.to_string().contains("no valid tunnel IPv4"));
    }
}
