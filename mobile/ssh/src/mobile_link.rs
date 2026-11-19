//! Android JNI bindings for the shared mobile link handle store.

use jni::{
    JNIEnv,
    objects::{JByteArray, JObject},
    sys::{jboolean, jbyteArray, jlong, jobjectArray, jstring},
};
use pebrel_mobile_link::crypto::{LinkError, MAX_MESSAGE, MAX_PACKET};
use std::panic::{AssertUnwindSafe, catch_unwind};
use zeroize::Zeroizing;

use crate::link_store;

fn invoke<T: Default>(
    env: &mut JNIEnv,
    call: impl FnOnce(&mut JNIEnv) -> Result<T, LinkError>,
) -> T {
    match catch_unwind(AssertUnwindSafe(|| call(env))) {
        Ok(Ok(value)) => value,
        error => {
            let code = match error {
                Ok(Err(error)) => error.to_string(),
                _ => "secure_link_internal_error".into(),
            };
            let _ = env.throw_new("java/io/IOException", code);
            T::default()
        },
    }
}

fn bytes(env: &JNIEnv, array: &JByteArray, max: usize) -> Result<Zeroizing<Vec<u8>>, LinkError> {
    let size = env.get_array_length(array).map_err(|_| LinkError::Frame)?;
    if size < 0 || size as usize > max {
        return Err(LinkError::Frame);
    }
    Ok(Zeroizing::new(env.convert_byte_array(array).map_err(|_| LinkError::Frame)?))
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_create(
    mut env: JNIEnv,
    _object: JObject,
    host: JByteArray,
    secret: JByteArray,
    context: JByteArray,
) -> jlong {
    invoke(&mut env, |env| {
        let host = bytes(env, &host, 32)?;
        let secret = bytes(env, &secret, 32)?;
        let context = bytes(env, &context, 512)?;
        link_store::create(&host, &secret, &context)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_hello(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
) -> jbyteArray {
    invoke(&mut env, |env| {
        let output = link_store::hello(id)?;
        env.byte_array_from_slice(&output)
            .map(|bytes| bytes.into_raw())
            .map_err(|_| LinkError::State)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_finish(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
    response: JByteArray,
) -> jboolean {
    invoke(&mut env, |env| {
        let response = bytes(env, &response, 128)?;
        Ok(u8::from(link_store::finish(id, &response)?))
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_seal(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
    plaintext: JByteArray,
) -> jobjectArray {
    invoke(&mut env, |env| {
        let plaintext = bytes(env, &plaintext, MAX_MESSAGE)?;
        let output = link_store::seal(id, &plaintext)?;
        let arrays = env
            .new_object_array(output.len() as i32, "[B", JObject::null())
            .map_err(|_| LinkError::State)?;
        for (index, packet) in output.iter().enumerate() {
            let bytes = env.byte_array_from_slice(packet).map_err(|_| LinkError::State)?;
            env.set_object_array_element(&arrays, index as i32, &bytes)
                .map_err(|_| LinkError::State)?;
            env.delete_local_ref(bytes).map_err(|_| LinkError::State)?;
        }
        Ok(arrays.into_raw())
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_verificationCode(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
) -> jstring {
    invoke(&mut env, |env| {
        let code = link_store::verification_code(id)?;
        env.new_string(code).map(|value| value.into_raw()).map_err(|_| LinkError::State)
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_open(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
    ciphertext: JByteArray,
) -> jbyteArray {
    invoke(&mut env, |env| {
        let ciphertext = bytes(env, &ciphertext, MAX_PACKET)?;
        match link_store::open(id, &ciphertext)? {
            Some(plaintext) => env
                .byte_array_from_slice(&plaintext)
                .map(|bytes| bytes.into_raw())
                .map_err(|_| LinkError::State),
            None => Ok(std::ptr::null_mut()),
        }
    })
}

#[unsafe(no_mangle)]
pub extern "system" fn Java_io_github_kuddev_pebrel_ssh_NativeLink_close(
    mut env: JNIEnv,
    _object: JObject,
    id: jlong,
) {
    invoke(&mut env, |_| link_store::close(id));
}
