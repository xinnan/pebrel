//! Shared handle table for Noise E2EE mobile link channels across JNI and C FFI.
//! Handles are bounded monotonic IDs, never raw pointers; close revokes and zeroizes them.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use pebrel_mobile_link::{
    crypto::{LinkError, MAX_MESSAGE, MAX_PACKET, SecureChannel},
    identity::Secret,
};
use zeroize::Zeroizing;

type Channel = Arc<Mutex<SecureChannel>>;

#[derive(Default)]
struct Handles {
    next: i64,
    channels: HashMap<i64, Channel>,
}

fn handles() -> &'static Mutex<Handles> {
    static HANDLES: OnceLock<Mutex<Handles>> = OnceLock::new();
    HANDLES.get_or_init(|| Mutex::new(Handles::default()))
}

fn channel(id: i64) -> Result<Channel, LinkError> {
    handles()
        .lock()
        .map_err(|_| LinkError::State)?
        .channels
        .get(&id)
        .cloned()
        .ok_or(LinkError::State)
}

pub(crate) fn create(host: &[u8], secret: &[u8], context: &[u8]) -> Result<i64, LinkError> {
    if host.len() != 32 || secret.len() != 32 || context.len() > 512 {
        return Err(LinkError::Frame);
    }
    let secret = Secret::from_bytes(secret)?;
    let host: [u8; 32] = host.try_into().map_err(|_| LinkError::Credential)?;
    let channel = SecureChannel::initiator(&host, &secret, context)?;
    let mut guard = handles().lock().map_err(|_| LinkError::State)?;
    if guard.channels.len() >= 32 {
        return Err(LinkError::State);
    }
    guard.next = guard.next.checked_add(1).ok_or(LinkError::State)?;
    let id = guard.next;
    guard.channels.insert(id, Arc::new(Mutex::new(channel)));
    Ok(id)
}

pub(crate) fn hello(id: i64) -> Result<Vec<u8>, LinkError> {
    let owner = channel(id)?;
    let mut guard = owner.lock().map_err(|_| LinkError::State)?;
    guard.write_handshake()
}

pub(crate) fn finish(id: i64, response: &[u8]) -> Result<bool, LinkError> {
    if response.len() > 128 {
        return Err(LinkError::Frame);
    }
    let owner = channel(id)?;
    let mut guard = owner.lock().map_err(|_| LinkError::State)?;
    guard.read_handshake(response)?;
    Ok(guard.established())
}

pub(crate) fn verification_code(id: i64) -> Result<String, LinkError> {
    let owner = channel(id)?;
    let guard = owner.lock().map_err(|_| LinkError::State)?;
    guard.verification_code().map(str::to_owned).ok_or(LinkError::State)
}

pub(crate) fn seal(id: i64, plaintext: &[u8]) -> Result<Vec<Vec<u8>>, LinkError> {
    if plaintext.len() > MAX_MESSAGE {
        return Err(LinkError::Frame);
    }
    let owner = channel(id)?;
    let mut guard = owner.lock().map_err(|_| LinkError::State)?;
    guard.seal(plaintext)
}

pub(crate) fn open(id: i64, ciphertext: &[u8]) -> Result<Option<Zeroizing<Vec<u8>>>, LinkError> {
    if ciphertext.len() > MAX_PACKET {
        return Err(LinkError::Frame);
    }
    let owner = channel(id)?;
    let mut guard = owner.lock().map_err(|_| LinkError::State)?;
    guard.open(ciphertext)
}

pub(crate) fn close(id: i64) -> Result<(), LinkError> {
    let owner = handles().lock().map_err(|_| LinkError::State)?.channels.remove(&id);
    if let Some(owner) = owner {
        owner.lock().map_err(|_| LinkError::State)?.close();
    }
    Ok(())
}
