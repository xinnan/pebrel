//! C FFI boundary for iOS (Swift) sharing the exact SSH, SFTP and Noise E2EE core with Android.
//!
//! No protocol state lives here. Handles are opaque monotonic int64 IDs; error strings are
//! static NUL-terminated ASCII constants that callers must not free.

use std::ffi::{CStr, CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::ptr;
use std::slice;

use pebrel_mobile_link::crypto::LinkError;
use zeroize::{Zeroize, Zeroizing};

use crate::link_store;
use crate::session::{self, Failure, Geometry, Open, Options, Result as SshResult, runtime};

#[repr(C)]
pub struct PebrelByteSlice {
    pub ptr: *mut u8,
    pub len: usize,
}

fn static_ssh_error(code: &'static str) -> *const c_char {
    match code {
        "INVALID_INPUT" => c"INVALID_INPUT".as_ptr(),
        "CLOSED" => c"CLOSED".as_ptr(),
        "UNKNOWN_HOST" => c"UNKNOWN_HOST".as_ptr(),
        "REFUSED" => c"REFUSED".as_ptr(),
        "NETWORK" => c"NETWORK".as_ptr(),
        "TIMEOUT" => c"TIMEOUT".as_ptr(),
        "NEGOTIATION" => c"NEGOTIATION".as_ptr(),
        "HOST_KEY_CHANGED" => c"HOST_KEY_CHANGED".as_ptr(),
        "TRUST_REJECTED" => c"TRUST_REJECTED".as_ptr(),
        "KEY" => c"KEY".as_ptr(),
        "AUTH" => c"AUTH".as_ptr(),
        "CHANNEL" => c"CHANNEL".as_ptr(),
        "QUERY_LIMIT" => c"QUERY_LIMIT".as_ptr(),
        "QUERY_ENCODING" => c"QUERY_ENCODING".as_ptr(),
        "SFTP_NOT_FOUND" => c"SFTP_NOT_FOUND".as_ptr(),
        "SFTP_PERMISSION" => c"SFTP_PERMISSION".as_ptr(),
        "SFTP_UNSUPPORTED" => c"SFTP_UNSUPPORTED".as_ptr(),
        "SFTP_CLOSED" => c"SFTP_CLOSED".as_ptr(),
        "SFTP_OPERATION" => c"SFTP_OPERATION".as_ptr(),
        "SFTP_TIMEOUT" => c"SFTP_TIMEOUT".as_ptr(),
        "SFTP_LIMIT" => c"SFTP_LIMIT".as_ptr(),
        "SFTP_STALE" => c"SFTP_STALE".as_ptr(),
        "SFTP_FILE_TYPE" => c"SFTP_FILE_TYPE".as_ptr(),
        "SFTP_CHANGED" => c"SFTP_CHANGED".as_ptr(),
        "SFTP_EXISTS" => c"SFTP_EXISTS".as_ptr(),
        _ => c"INTERNAL".as_ptr(),
    }
}

fn static_link_error(error: LinkError) -> *const c_char {
    match error {
        LinkError::Credential => c"invalid_credential".as_ptr(),
        LinkError::Random => c"secure_random_unavailable".as_ptr(),
        LinkError::State => c"invalid_link_state".as_ptr(),
        LinkError::Frame => c"invalid_secure_frame".as_ptr(),
        LinkError::Authentication => c"secure_authentication_failed".as_ptr(),
    }
}

unsafe fn clear_error(out_error: *mut *const c_char) {
    if !out_error.is_null() {
        unsafe { *out_error = ptr::null() };
    }
}

unsafe fn set_error(out_error: *mut *const c_char, error: *const c_char) {
    if !out_error.is_null() {
        unsafe { *out_error = error };
    }
}

fn invoke_ssh<T>(
    out_error: *mut *const c_char,
    fallback: T,
    call: impl FnOnce() -> SshResult<T>,
) -> T {
    unsafe { clear_error(out_error) };
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            unsafe { set_error(out_error, static_ssh_error(error.0)) };
            fallback
        },
        Err(_) => {
            unsafe { set_error(out_error, c"INTERNAL".as_ptr()) };
            fallback
        },
    }
}

fn invoke_link<T>(
    out_error: *mut *const c_char,
    fallback: T,
    call: impl FnOnce() -> Result<T, LinkError>,
) -> T {
    unsafe { clear_error(out_error) };
    match catch_unwind(AssertUnwindSafe(call)) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => {
            unsafe { set_error(out_error, static_link_error(error)) };
            fallback
        },
        Err(_) => {
            unsafe { set_error(out_error, c"secure_link_internal_error".as_ptr()) };
            fallback
        },
    }
}

unsafe fn read_cstr(ptr: *const c_char, max_len: usize) -> SshResult<String> {
    if ptr.is_null() {
        return Err(Failure("INVALID_INPUT"));
    }
    let text = unsafe { CStr::from_ptr(ptr) }.to_str().map_err(|_| Failure("INVALID_INPUT"))?;
    if text.len() > max_len {
        return Err(Failure("INVALID_INPUT"));
    }
    Ok(text.to_owned())
}

unsafe fn read_bytes<'a>(ptr: *const u8, len: usize, max_len: usize) -> SshResult<&'a [u8]> {
    if len > max_len {
        return Err(Failure("INVALID_INPUT"));
    }
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(Failure("INVALID_INPUT"));
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

unsafe fn read_link_bytes<'a>(
    ptr: *const u8,
    len: usize,
    max_len: usize,
) -> Result<&'a [u8], LinkError> {
    if len > max_len {
        return Err(LinkError::Frame);
    }
    if len == 0 {
        return Ok(&[]);
    }
    if ptr.is_null() {
        return Err(LinkError::Frame);
    }
    Ok(unsafe { slice::from_raw_parts(ptr, len) })
}

fn geometry(columns: i32, rows: i32, width: i32, height: i32) -> SshResult<Geometry> {
    if !(1..=4096).contains(&columns) || !(1..=4096).contains(&rows) || width < 0 || height < 0 {
        return Err(Failure("INVALID_INPUT"));
    }
    Ok(Geometry {
        columns: columns as u32,
        rows: rows as u32,
        width: width as u32,
        height: height as u32,
    })
}

fn into_boxed_bytes(data: Vec<u8>) -> (*mut u8, usize) {
    let mut boxed = data.into_boxed_slice();
    let len = boxed.len();
    let ptr = if len == 0 {
        ptr::null_mut()
    } else {
        let raw = boxed.as_mut_ptr();
        std::mem::forget(boxed);
        raw
    };
    (ptr, len)
}

fn into_c_string(text: String) -> SshResult<*mut c_char> {
    CString::new(text).map(CString::into_raw).map_err(|_| Failure("INTERNAL"))
}

// ---------------------------------------------------------------------------
// Memory management helpers
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            let _ = CString::from_raw(ptr);
        }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_bytes_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            let mut boxed = Box::from_raw(ptr::slice_from_raw_parts_mut(ptr, len));
            boxed.zeroize();
        }));
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_packet_list_free(items: *mut PebrelByteSlice, count: usize) {
    if !items.is_null() && count > 0 {
        let _ = catch_unwind(AssertUnwindSafe(|| unsafe {
            let boxed = Box::from_raw(ptr::slice_from_raw_parts_mut(items, count));
            for item in boxed.iter() {
                pebrel_bytes_free(item.ptr, item.len);
            }
        }));
    }
}

// ---------------------------------------------------------------------------
// SSH / SFTP / Query C FFI
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_create(
    host: *const c_char,
    port: u16,
    user: *const c_char,
    password: *const u8,
    password_len: usize,
    fingerprint: *const c_char,
    private_key: *const u8,
    private_key_len: usize,
    out_error: *mut *const c_char,
) -> i64 {
    invoke_ssh(out_error, 0, || {
        if port == 0 {
            return Err(Failure("INVALID_INPUT"));
        }
        let host = unsafe { read_cstr(host, 1024)? };
        let user = unsafe { read_cstr(user, 1024)? };
        let fingerprint = unsafe { read_cstr(fingerprint, 256)? };
        let password =
            Zeroizing::new(unsafe { read_bytes(password, password_len, 4096)? }.to_vec());
        let private_key =
            Zeroizing::new(unsafe { read_bytes(private_key, private_key_len, 65536)? }.to_vec());
        session::start(Options { host, port, user, password, private_key, fingerprint })
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_next_event(
    id: i64,
    out_error: *mut *const c_char,
) -> *mut c_char {
    invoke_ssh(out_error, ptr::null_mut(), || {
        let owner = session::get(id)?;
        let event = runtime().block_on(owner.event())?;
        into_c_string(event)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_answer_host_key(
    id: i64,
    accepted: bool,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        session::get(id)?.answer(accepted)?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_open_shell(
    id: i64,
    columns: i32,
    rows: i32,
    width: i32,
    height: i32,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        let owner = session::get(id)?;
        runtime().block_on(owner.open(Open::Shell(geometry(columns, rows, width, height)?)))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_open_exec(
    id: i64,
    command: *const c_char,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        let command = unsafe { read_cstr(command, 8192)? };
        let owner = session::get(id)?;
        runtime().block_on(owner.open(Open::Exec(command)))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_open_pty_exec(
    id: i64,
    command: *const c_char,
    columns: i32,
    rows: i32,
    width: i32,
    height: i32,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        let command = unsafe { read_cstr(command, 8192)? };
        if command.is_empty() || command.chars().any(char::is_control) {
            return Err(Failure("INVALID_INPUT"));
        }
        let owner = session::get(id)?;
        runtime().block_on(
            owner.open(Open::PtyExec(geometry(columns, rows, width, height)?, command)),
        )?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_query(
    id: i64,
    command: *const c_char,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_error: *mut *const c_char,
) -> bool {
    if !out_ptr.is_null() {
        unsafe { *out_ptr = ptr::null_mut() };
    }
    if !out_len.is_null() {
        unsafe { *out_len = 0 };
    }
    invoke_ssh(out_error, false, || {
        if out_ptr.is_null() || out_len.is_null() {
            return Err(Failure("INVALID_INPUT"));
        }
        let command = unsafe { read_cstr(command, 8192)? };
        let response = runtime().block_on(session::get(id)?.query(command))?;
        let (ptr, len) = into_boxed_bytes(response.into_bytes());
        unsafe {
            *out_ptr = ptr;
            *out_len = len;
        }
        Ok(true)
    })
}

/// Reads up to `count` bytes (1..=16384).
/// Returns >0 byte count, -1 on EOF, or -2 on error (with `*out_error` populated).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_read(
    id: i64,
    target: *mut u8,
    count: usize,
    stderr_stream: bool,
    out_error: *mut *const c_char,
) -> i32 {
    invoke_ssh(out_error, -2, || {
        if target.is_null() || count == 0 || count > 16 * 1024 {
            return Err(Failure("INVALID_INPUT"));
        }
        let owner = session::get(id)?;
        let bytes = runtime().block_on(owner.read(stderr_stream, count))?;
        if bytes.is_empty() {
            return Ok(-1);
        }
        unsafe {
            ptr::copy_nonoverlapping(bytes.as_ptr(), target, bytes.len());
        }
        Ok(bytes.len() as i32)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_write(
    id: i64,
    source: *const u8,
    count: usize,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        if source.is_null() || count == 0 || count > 8192 {
            return Err(Failure("INVALID_INPUT"));
        }
        let bytes = unsafe { slice::from_raw_parts(source, count) }.to_vec();
        let owner = session::get(id)?;
        runtime().block_on(owner.write(bytes))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_resize(
    id: i64,
    columns: i32,
    rows: i32,
    width: i32,
    height: i32,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        let owner = session::get(id)?;
        runtime().block_on(owner.resize(geometry(columns, rows, width, height)?))?;
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_await_exit(
    id: i64,
    out_code: *mut i32,
    out_error: *mut *const c_char,
) -> bool {
    invoke_ssh(out_error, false, || {
        if out_code.is_null() {
            return Err(Failure("INVALID_INPUT"));
        }
        let owner = session::get(id)?;
        let code = runtime().block_on(owner.exit())?;
        unsafe { *out_code = code };
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_ssh_sftp(
    id: i64,
    request_json: *const c_char,
    out_error: *mut *const c_char,
) -> *mut c_char {
    invoke_ssh(out_error, ptr::null_mut(), || {
        let max_request = crate::sftp::BATCH.div_ceil(3) * 4 + 8192;
        let text = unsafe { read_cstr(request_json, max_request)? };
        let request = crate::sftp::parse(&text)?;
        let owner = session::get(id)?;
        let response = runtime().block_on(owner.sftp(request))?;
        into_c_string(response.to_string())
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn pebrel_ssh_close(id: i64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        session::close(id);
    }));
}

// ---------------------------------------------------------------------------
// Mobile Link (Noise NKpsk0 E2EE) C FFI
// ---------------------------------------------------------------------------

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_link_create(
    host_pub: *const u8,
    host_len: usize,
    secret: *const u8,
    secret_len: usize,
    context: *const u8,
    context_len: usize,
    out_error: *mut *const c_char,
) -> i64 {
    invoke_link(out_error, 0, || {
        let host = unsafe { read_link_bytes(host_pub, host_len, 32)? };
        let secret = unsafe { read_link_bytes(secret, secret_len, 32)? };
        let context = unsafe { read_link_bytes(context, context_len, 512)? };
        link_store::create(host, secret, context)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_link_hello(
    id: i64,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_error: *mut *const c_char,
) -> bool {
    if !out_ptr.is_null() {
        unsafe { *out_ptr = ptr::null_mut() };
    }
    if !out_len.is_null() {
        unsafe { *out_len = 0 };
    }
    invoke_link(out_error, false, || {
        if out_ptr.is_null() || out_len.is_null() {
            return Err(LinkError::Frame);
        }
        let output = link_store::hello(id)?;
        let (ptr, len) = into_boxed_bytes(output);
        unsafe {
            *out_ptr = ptr;
            *out_len = len;
        }
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_link_finish(
    id: i64,
    response: *const u8,
    response_len: usize,
    out_established: *mut bool,
    out_error: *mut *const c_char,
) -> bool {
    if !out_established.is_null() {
        unsafe { *out_established = false };
    }
    invoke_link(out_error, false, || {
        if out_established.is_null() {
            return Err(LinkError::Frame);
        }
        let response = unsafe { read_link_bytes(response, response_len, 128)? };
        let established = link_store::finish(id, response)?;
        unsafe { *out_established = established };
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_link_verification_code(
    id: i64,
    out_error: *mut *const c_char,
) -> *mut c_char {
    invoke_link(out_error, ptr::null_mut(), || {
        let code = link_store::verification_code(id)?;
        CString::new(code).map(CString::into_raw).map_err(|_| LinkError::State)
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_link_seal(
    id: i64,
    plaintext: *const u8,
    plaintext_len: usize,
    out_packets: *mut *mut PebrelByteSlice,
    out_count: *mut usize,
    out_error: *mut *const c_char,
) -> bool {
    if !out_packets.is_null() {
        unsafe { *out_packets = ptr::null_mut() };
    }
    if !out_count.is_null() {
        unsafe { *out_count = 0 };
    }
    invoke_link(out_error, false, || {
        if out_packets.is_null() || out_count.is_null() {
            return Err(LinkError::Frame);
        }
        let plaintext = unsafe {
            read_link_bytes(plaintext, plaintext_len, pebrel_mobile_link::crypto::MAX_MESSAGE)?
        };
        let packets = link_store::seal(id, plaintext)?;
        let mut slices = Vec::with_capacity(packets.len());
        for packet in packets {
            let (ptr, len) = into_boxed_bytes(packet);
            slices.push(PebrelByteSlice { ptr, len });
        }
        let mut boxed = slices.into_boxed_slice();
        let count = boxed.len();
        let ptr = if count == 0 {
            ptr::null_mut()
        } else {
            let raw = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            raw
        };
        unsafe {
            *out_packets = ptr;
            *out_count = count;
        }
        Ok(true)
    })
}

/// Opens a ciphertext frame. Returns `true` on success; when a multi-frame message is still
/// buffering, `*out_ptr` is NULL and `*out_len` is 0.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn pebrel_link_open(
    id: i64,
    ciphertext: *const u8,
    ciphertext_len: usize,
    out_ptr: *mut *mut u8,
    out_len: *mut usize,
    out_error: *mut *const c_char,
) -> bool {
    if !out_ptr.is_null() {
        unsafe { *out_ptr = ptr::null_mut() };
    }
    if !out_len.is_null() {
        unsafe { *out_len = 0 };
    }
    invoke_link(out_error, false, || {
        if out_ptr.is_null() || out_len.is_null() {
            return Err(LinkError::Frame);
        }
        let ciphertext = unsafe {
            read_link_bytes(ciphertext, ciphertext_len, pebrel_mobile_link::crypto::MAX_PACKET)?
        };
        if let Some(plaintext) = link_store::open(id, ciphertext)? {
            let (ptr, len) = into_boxed_bytes(plaintext.to_vec());
            unsafe {
                *out_ptr = ptr;
                *out_len = len;
            }
        }
        Ok(true)
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn pebrel_link_close(id: i64) {
    let _ = catch_unwind(AssertUnwindSafe(|| {
        let _ = link_store::close(id);
    }));
}

#[cfg(test)]
mod tests {
    use super::*;
    use pebrel_mobile_link::{
        crypto::{HostKey, SecureChannel},
        identity::Secret,
    };

    #[test]
    fn c_ffi_link_round_trip_and_verification_code() {
        let host = HostKey::generate().expect("host key");
        let secret_bytes = [0x42u8; 32];
        let secret = Secret::from_bytes(&secret_bytes).expect("secret");
        let context = b"pebrel.mobile.v2\nhost\ngrant\ninvite\nepoch-1";
        let mut responder =
            SecureChannel::responder(&host, &secret, context).expect("responder channel");

        let mut err: *const c_char = ptr::null();
        let id = unsafe {
            pebrel_link_create(
                host.public().as_ptr(),
                host.public().len(),
                secret_bytes.as_ptr(),
                secret_bytes.len(),
                context.as_ptr(),
                context.len(),
                &mut err,
            )
        };
        assert!(id > 0);
        assert!(err.is_null());

        let mut hello_ptr: *mut u8 = ptr::null_mut();
        let mut hello_len: usize = 0;
        let ok = unsafe { pebrel_link_hello(id, &mut hello_ptr, &mut hello_len, &mut err) };
        assert!(ok && err.is_null() && !hello_ptr.is_null() && hello_len > 0);
        let hello = unsafe { slice::from_raw_parts(hello_ptr, hello_len).to_vec() };
        unsafe { pebrel_bytes_free(hello_ptr, hello_len) };

        responder.read_handshake(&hello).expect("responder read");
        let reply = responder.write_handshake().expect("responder write");

        let mut established = false;
        let ok = unsafe {
            pebrel_link_finish(id, reply.as_ptr(), reply.len(), &mut established, &mut err)
        };
        assert!(ok && established && err.is_null());

        let code_ptr = unsafe { pebrel_link_verification_code(id, &mut err) };
        assert!(!code_ptr.is_null() && err.is_null());
        let code = unsafe { CStr::from_ptr(code_ptr) }.to_str().unwrap().to_owned();
        unsafe { pebrel_string_free(code_ptr) };
        assert_eq!(code, responder.verification_code().unwrap());

        // Multi-chunk seal (70 KiB > 60 KiB chunk) -> responder open
        let payload = vec![0x5Au8; 70 * 1024];
        let mut packets_ptr: *mut PebrelByteSlice = ptr::null_mut();
        let mut packets_count: usize = 0;
        let ok = unsafe {
            pebrel_link_seal(
                id,
                payload.as_ptr(),
                payload.len(),
                &mut packets_ptr,
                &mut packets_count,
                &mut err,
            )
        };
        assert!(ok && err.is_null() && packets_count == 2);
        let packets = unsafe { slice::from_raw_parts(packets_ptr, packets_count) };
        let mut received = None;
        for packet in packets {
            let chunk = unsafe { slice::from_raw_parts(packet.ptr, packet.len) };
            received = responder.open(chunk).expect("responder open");
        }
        unsafe { pebrel_packet_list_free(packets_ptr, packets_count) };
        assert_eq!(received.as_deref().map(Vec::as_slice), Some(payload.as_slice()));

        // Responder seal -> C FFI open
        let back = b"{\"type\":\"secure.accepted\",\"grant\":\"g1\"}";
        let encrypted = responder.seal(back).expect("responder seal");
        let mut out_ptr: *mut u8 = ptr::null_mut();
        let mut out_len: usize = 0;
        let ok = unsafe {
            pebrel_link_open(
                id,
                encrypted[0].as_ptr(),
                encrypted[0].len(),
                &mut out_ptr,
                &mut out_len,
                &mut err,
            )
        };
        assert!(ok && err.is_null() && !out_ptr.is_null());
        let opened = unsafe { slice::from_raw_parts(out_ptr, out_len).to_vec() };
        unsafe { pebrel_bytes_free(out_ptr, out_len) };
        assert_eq!(opened, back);

        pebrel_link_close(id);

        // Stale handle returns static error code
        let ok = unsafe { pebrel_link_hello(id, &mut hello_ptr, &mut hello_len, &mut err) };
        assert!(!ok);
        assert_eq!(unsafe { CStr::from_ptr(err) }.to_str().unwrap(), "invalid_link_state");
    }

    #[test]
    fn c_ffi_ssh_rejects_invalid_inputs_and_stale_handles() {
        let mut err: *const c_char = ptr::null();
        let id = unsafe {
            pebrel_ssh_create(
                c"example.com".as_ptr(),
                0,
                c"root".as_ptr(),
                ptr::null(),
                0,
                c"".as_ptr(),
                ptr::null(),
                0,
                &mut err,
            )
        };
        assert_eq!(id, 0);
        assert_eq!(unsafe { CStr::from_ptr(err) }.to_str().unwrap(), "INVALID_INPUT");

        let mut buf = [0u8; 16];
        let n = unsafe { pebrel_ssh_read(999_999, buf.as_mut_ptr(), buf.len(), false, &mut err) };
        assert_eq!(n, -2);
        assert_eq!(unsafe { CStr::from_ptr(err) }.to_str().unwrap(), "CLOSED");

        let ok = unsafe { pebrel_ssh_open_shell(999_999, 0, 24, 0, 0, &mut err) };
        assert!(!ok);
        assert_eq!(unsafe { CStr::from_ptr(err) }.to_str().unwrap(), "CLOSED");
    }
}
