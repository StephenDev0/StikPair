// Forked from idevice's `ffi/src/pairable_host.rs` (jkcoxson/idevice @ 7bd551c),
// but with the mDNS advertising removed: upstream advertises with `mdns-sd` (raw
// multicast, which needs the iOS multicast entitlement). Instead we link the
// idevice *library* directly and, right before `accept()`, invoke a `ready`
// callback with the service identifier, port, and TXT records; the Swift side
// publishes them via `NetService` (mDNSResponder), needing only Local Network.

use std::ffi::{c_char, c_void, CStr, CString};
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::ptr;

use idevice::remote_pairing::{
    PairableHost, PairableHostInfo, RpPairingFile, RpPairingSocket,
};
use tokio::net::TcpListener;

pub type StikPairReadyCb = Option<
    extern "C" fn(
        ctx: *mut c_void,
        service_id: *const c_char,
        port: u16,
        txt_keys: *const *const c_char,
        txt_vals: *const *const c_char,
        txt_count: usize,
    ),
>;

pub type StikPairPinCb = Option<extern "C" fn(pin: *const c_char, ctx: *mut c_void)>;

#[repr(C)]
pub struct StikPairResult {
    pub error: *mut c_char,
    pub device_name: *mut c_char,
    pub device_model: *mut c_char,
    pub device_udid: *mut c_char,
    pub pairing_file_path: *mut c_char,
    pub host_alt_irk_hex: *mut c_char,
}

impl StikPairResult {
    fn empty() -> Self {
        Self {
            error: ptr::null_mut(),
            device_name: ptr::null_mut(),
            device_model: ptr::null_mut(),
            device_udid: ptr::null_mut(),
            pairing_file_path: ptr::null_mut(),
            host_alt_irk_hex: ptr::null_mut(),
        }
    }
}

fn cstr(s: impl Into<Vec<u8>>) -> *mut c_char {
    CString::new(s).unwrap_or_default().into_raw()
}

struct Callbacks {
    ready: StikPairReadyCb,
    pin: StikPairPinCb,
    ctx: *mut c_void,
}
unsafe impl Send for Callbacks {}

unsafe fn opt_str(p: *const c_char, default: &str) -> String {
    if p.is_null() {
        return default.to_string();
    }
    match CStr::from_ptr(p).to_str() {
        Ok(s) if !s.is_empty() => s.to_string(),
        _ => default.to_string(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn stikpair_run_host(
    bind_addr: *const c_char,
    port: u16,
    name: *const c_char,
    model: *const c_char,
    out_path: *const c_char,
    ready_cb: StikPairReadyCb,
    pin_cb: StikPairPinCb,
    ctx: *mut c_void,
    out: *mut StikPairResult,
) -> i32 {
    if out.is_null() {
        return 2;
    }
    *out = StikPairResult::empty();

    let bind_addr = opt_str(bind_addr, "0.0.0.0");
    let name = opt_str(name, "StikPair");
    let model = opt_str(model, "Mac17,7");
    let out_path = opt_str(out_path, "rp_pairing_file.plist");
    let cbs = Callbacks { ready: ready_cb, pin: pin_cb, ctx };

    let rt = match tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            (*out).error = cstr(format!("failed to start runtime: {e}"));
            return 1;
        }
    };

    match rt.block_on(run(bind_addr, port, name, model, out_path, cbs)) {
        Ok(res) => {
            (*out).device_name = cstr(res.name);
            (*out).device_model = cstr(res.model);
            (*out).device_udid = cstr(res.udid);
            (*out).pairing_file_path = cstr(res.path);
            (*out).host_alt_irk_hex = cstr(res.host_alt_irk_hex);
            0
        }
        Err(e) => {
            (*out).error = cstr(e);
            1
        }
    }
}

struct Paired {
    name: String,
    model: String,
    udid: String,
    path: String,
    host_alt_irk_hex: String,
}

async fn run(
    bind_addr: String,
    port: u16,
    name: String,
    model: String,
    out_path: String,
    cbs: Callbacks,
) -> Result<Paired, String> {
    // Bind first so we can advertise the real port.
    let ip: IpAddr = bind_addr
        .parse()
        .unwrap_or(IpAddr::V4(Ipv4Addr::UNSPECIFIED));
    let listener = TcpListener::bind(SocketAddr::new(ip, port))
        .await
        .map_err(|e| format!("failed to bind {bind_addr}:{port}: {e}"))?;
    let port = listener
        .local_addr()
        .map_err(|e| format!("no local addr: {e}"))?
        .port();

    // Host identity. A production app should persist both the pairing file and
    // `host_info.alt_irk` so already-paired devices keep working.
    let mut pairing_file = RpPairingFile::generate(&name);
    let host_info = PairableHostInfo::generate(&name, &model);
    let host_alt_irk = host_info.alt_irk;
    let service_identifier = pairing_file.identifier.clone();

    // Hand advertising to Swift (NetService) — upstream did this with mdns-sd.
    emit_ready(&cbs, &service_identifier, port, &host_info);

    // Wait for a device to connect and drive pairing.
    let (stream, _peer) = listener
        .accept()
        .await
        .map_err(|e| format!("accept failed: {e}"))?;

    let socket = RpPairingSocket::new_device(stream);
    let mut host = PairableHost::new(socket, host_info);

    let peer = host
        .accept(&mut pairing_file, move |pin| async move {
            if let Some(cb) = cbs.pin {
                if let Ok(c) = CString::new(pin) {
                    cb(c.as_ptr(), cbs.ctx);
                }
            }
        })
        .await
        .map_err(|e| format!("pairing failed: {e}"))?;

    pairing_file
        .write_to_file(&out_path)
        .await
        .map_err(|e| format!("failed to write pairing file: {e}"))?;

    Ok(Paired {
        name: peer.name,
        model: peer.model,
        udid: peer.remotepairing_udid,
        path: out_path,
        host_alt_irk_hex: hex(&host_alt_irk),
    })
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn emit_ready(cbs: &Callbacks, service_id: &str, port: u16, host_info: &PairableHostInfo) {
    let Some(cb) = cbs.ready else { return };

    let records = host_info.mdns_txt_records(service_id);
    let mut keys: Vec<CString> = Vec::with_capacity(records.len());
    let mut vals: Vec<CString> = Vec::with_capacity(records.len());
    for (k, v) in &records {
        keys.push(CString::new(k.as_str()).unwrap_or_default());
        vals.push(CString::new(v.as_str()).unwrap_or_default());
    }
    let key_ptrs: Vec<*const c_char> = keys.iter().map(|s| s.as_ptr()).collect();
    let val_ptrs: Vec<*const c_char> = vals.iter().map(|s| s.as_ptr()).collect();

    let Ok(id_c) = CString::new(service_id) else { return };
    cb(
        cbs.ctx,
        id_c.as_ptr(),
        port,
        key_ptrs.as_ptr(),
        val_ptrs.as_ptr(),
        records.len(),
    );
}

#[no_mangle]
pub unsafe extern "C" fn stikpair_result_free(r: *mut StikPairResult) {
    if r.is_null() {
        return;
    }
    for p in [
        (*r).error,
        (*r).device_name,
        (*r).device_model,
        (*r).device_udid,
        (*r).pairing_file_path,
        (*r).host_alt_irk_hex,
    ] {
        if !p.is_null() {
            drop(CString::from_raw(p));
        }
    }
    *r = StikPairResult::empty();
}
