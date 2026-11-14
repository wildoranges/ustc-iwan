mod connections;
mod engine;
mod flow;
mod http;
mod socks;

use anyhow::{Context, Result};
use std::fmt;
use std::net::{Ipv4Addr, SocketAddr, TcpListener, UdpSocket};

use crate::core::dns::DnsResolver;
use crate::core::sr::SrConfig;

use engine::Engine;

/// Local protocol spoken by the userspace proxy listener.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProxyProtocol {
    Socks5,
    Http,
}

impl fmt::Display for ProxyProtocol {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Socks5 => "SOCKS5",
            Self::Http => "HTTP",
        })
    }
}

/// Run a local proxy listener backed by a smoltcp userspace TCP/IP stack.
///
/// `sock` must already be authenticated and connected to the VPN server.
pub struct ProxyConfig<'a> {
    pub listen: SocketAddr,
    pub protocol: ProxyProtocol,
    pub inner_ip: Ipv4Addr,
    pub gateway: Ipv4Addr,
    pub mtu: usize,
    pub xor_key: &'a [u8],
    pub aes_key: &'a [u8],
    pub sid: u16,
    pub token: u32,
    pub encryption: u8,
    pub sr: Option<SrConfig>,
    pub duplicate: bool,
    pub dns: DnsResolver,
}

pub fn run(sock: &UdpSocket, config: ProxyConfig<'_>) -> Result<()> {
    let listener = bind_listener(config.protocol, config.listen)?;
    run_with_listener(listener, sock, config)
}

/// Reserve the local address before authenticating or entering a reconnect loop.
pub fn bind_listener(protocol: ProxyProtocol, listen: SocketAddr) -> Result<TcpListener> {
    let listener =
        TcpListener::bind(listen).with_context(|| format!("bind {protocol} listener {listen}"))?;
    listener.set_nonblocking(true)?;
    Ok(listener)
}

/// Run using a listener reserved by the caller, which can be retained across reconnects.
pub fn run_with_listener(
    listener: TcpListener,
    sock: &UdpSocket,
    config: ProxyConfig<'_>,
) -> Result<()> {
    sock.set_nonblocking(true)?;

    let mut engine = Engine::new(listener, sock, &config)?;

    println!("{} listening on {}", config.protocol, config.listen);
    if crate::core::util::debug_enabled() {
        eprintln!(
            "{} network: IP {}, gateway {}, MTU {}, DNS {}",
            config.protocol, config.inner_ip, config.gateway, config.mtu, config.dns
        );
    }

    engine.run()?;
    println!("{} stopped", config.protocol);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn occupied_listener_reports_address_and_io_error() {
        let listener = bind_listener(ProxyProtocol::Http, "127.0.0.1:0".parse().unwrap()).unwrap();
        let address = listener.local_addr().unwrap();
        let error = bind_listener(ProxyProtocol::Http, address).unwrap_err();
        assert!(error
            .to_string()
            .contains(&format!("HTTP listener {address}")));
        assert_eq!(
            error.downcast_ref::<std::io::Error>().unwrap().kind(),
            std::io::ErrorKind::AddrInUse
        );
        drop(listener);
        assert!(bind_listener(ProxyProtocol::Http, address).is_ok());
    }
}
