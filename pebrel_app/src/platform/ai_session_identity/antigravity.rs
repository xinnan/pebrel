//! Find the active Antigravity (`agy`) conversation when no hook has reported an ID yet
//! (for example right after restoring `agy --conversation <id>` before a new turn finishes).
//!
//! Inspects only `presence/<conversation_id>.lock` descriptors held open by a verified
//! Antigravity CLI process belonging to the pane's controlling terminal and instance.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use super::{MAX_PROBE_OUTPUT, MAX_PROBE_RECORDS, PROBE_TIMEOUT, run_probe_output};
#[cfg(unix)]
use crate::platform::process_snapshot::is_antigravity_process_name;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AntigravitySession {
    pub session_id: String,
    pub session_file: String,
}

const WSL_ANTIGRAVITY_PROBE_SCRIPT: &str = r###"
pane="$1"
instance="$2"
for proc in /proc/[0-9]*; do
    pid=${proc##*/}
    IFS= read -r comm < "$proc/comm" 2>/dev/null || continue
    case "$comm" in
        agy|antigravity|antigravity-cli|agy.exe|antigravity.exe|antigravity-cli.exe) ;;
        *) continue ;;
    esac
    [ -r "$proc/environ" ] || continue
    environment=$(tr "\0" "\n" < "$proc/environ" 2>/dev/null || true)
    pane_id=$(printf '%s\n' "$environment" | sed -n "s/^PEBREL_PANE_ID=//p" | head -n 1)
    if [ "$pane_id" != "$pane" ]; then
        pane_id=$(printf '%s\n' "$environment" | sed -n "s/^NEBULA_PANE_ID=//p" | head -n 1)
    fi
    process_id=$(printf '%s\n' "$environment" | sed -n "s/^PEBREL_PROCESS_ID=//p" | head -n 1)
    [ "$pane_id" = "$pane" ] && [ "$process_id" = "$instance" ] || continue
    IFS= read -r stat < "$proc/stat" 2>/dev/null || continue
    IFS=' ' read -r state ppid pgrp sid tty rest <<EOF
${stat##*) }
EOF
    [ "${tty:-0}" -ne 0 ] 2>/dev/null || continue
    guest_home=$(printf '%s\n' "$environment" | sed -n "s/^HOME=//p" | head -n 1)
    [ -n "$guest_home" ] || continue
    cli_root=$(CDPATH= cd -P "$guest_home/.gemini/antigravity-cli" 2>/dev/null && pwd -P) || continue
    presence_root=$(CDPATH= cd -P "$cli_root/presence" 2>/dev/null && pwd -P) || continue
    for fd in "$proc"/fd/*; do
        link=$(readlink "$fd" 2>/dev/null || true)
        case "$link" in
            "$presence_root"/*.lock)
                printf '%s\t%s\t%s\t%s\n' "$pid" "${fd##*/}" "$cli_root" "$link"
                ;;
        esac
    done
done
"###;

pub(crate) fn probe_antigravity_session(
    pane_id: u64,
    exec_context: Option<&crate::runtime_exec::PaneExecContext>,
    shell_pid: Option<u32>,
) -> Option<AntigravitySession> {
    let pane_id = pane_id.to_string();
    let context = exec_context?;
    let instance = context.process_instance()?;
    if let Some(distro) = context.wsl_distribution() {
        return probe_wsl(distro, context.wsl_user(), &pane_id, instance);
    }

    #[cfg(target_os = "linux")]
    return probe_local_proc(&pane_id, instance, shell_pid?);
    #[cfg(target_os = "macos")]
    {
        let _ = (pane_id, instance);
        return probe_macos(shell_pid?);
    }
    #[cfg(windows)]
    {
        let _ = (pane_id, instance, shell_pid);
        None
    }
}

fn probe_wsl(
    distro: Option<&str>,
    user: Option<&str>,
    pane_id: &str,
    instance: &str,
) -> Option<AntigravitySession> {
    let mut args = Vec::with_capacity(9);
    if let Some(distro) = distro {
        args.extend(["--distribution".to_owned(), distro.to_owned()]);
    }
    if let Some(user) = user {
        args.extend(["--user".to_owned(), user.to_owned()]);
    }
    args.extend([
        "--exec".to_owned(),
        "sh".to_owned(),
        "-c".to_owned(),
        WSL_ANTIGRAVITY_PROBE_SCRIPT.to_owned(),
        "pebrel-agy-session-probe".to_owned(),
        pane_id.to_owned(),
        instance.to_owned(),
    ]);
    let mut command = Command::new("wsl.exe");
    command.args(args);
    crate::platform::process::hidden_command(&mut command);
    parse_presence_records(&String::from_utf8_lossy(&run_probe_output(command)?))
}

#[cfg(target_os = "linux")]
fn probe_local_proc(pane_id: &str, instance: &str, shell_pid: u32) -> Option<AntigravitySession> {
    use super::{environment_has_value, environment_value};
    use crate::platform::process_snapshot::linux_process;
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt as _;

    let terminal = linux_process(shell_pid)?.terminal;
    if !terminal.is_attached() {
        return None;
    }
    let deadline = Instant::now() + PROBE_TIMEOUT;
    let mut output = String::new();
    let mut records = 0;
    for entry in std::fs::read_dir("/proc").ok()?.flatten() {
        if Instant::now() >= deadline {
            return None;
        }
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|name| name.parse::<u32>().ok()) else {
            continue;
        };
        let proc_dir = entry.path();
        let Ok(comm) = std::fs::read_to_string(proc_dir.join("comm")) else { continue };
        if !is_antigravity_process_name(comm.trim()) {
            continue;
        }
        let Ok(environment) = std::fs::read(proc_dir.join("environ")) else { continue };
        if !environment_has_value(&environment, b"PEBREL_PANE_ID", pane_id.as_bytes())
            && !environment_has_value(&environment, b"NEBULA_PANE_ID", pane_id.as_bytes())
        {
            continue;
        }
        if !environment_has_value(
            &environment,
            crate::agent_env::PROCESS_ENV.as_bytes(),
            instance.as_bytes(),
        ) {
            continue;
        }
        if linux_process(pid).is_none_or(|process| process.terminal != terminal) {
            continue;
        }
        let Some(home_bytes) = environment_value(&environment, b"HOME") else {
            continue;
        };
        let home = PathBuf::from(OsStr::from_bytes(home_bytes));
        let cli_root = proc_dir.join("cwd").join(home).join(".gemini").join("antigravity-cli");
        let Ok(canonical_cli) = cli_root.canonicalize() else {
            continue;
        };
        let Ok(presence_root) = canonical_cli.join("presence").canonicalize() else {
            continue;
        };
        let Ok(fds) = std::fs::read_dir(proc_dir.join("fd")) else { continue };
        for fd in fds.flatten() {
            let fd_path = fd.path();
            let Ok(link) = std::fs::read_link(&fd_path) else { continue };
            if presence_lock_id(&link, &presence_root).is_none() {
                continue;
            }
            let Some(fd_number) = fd.file_name().to_string_lossy().parse::<u32>().ok() else {
                continue;
            };
            use std::fmt::Write as _;
            let _ = writeln!(
                output,
                "{pid}\t{fd_number}\t{}\t{}",
                canonical_cli.display(),
                link.display()
            );
            records += 1;
            if records >= MAX_PROBE_RECORDS || output.len() >= MAX_PROBE_OUTPUT {
                return None;
            }
        }
    }
    parse_presence_records(&output)
}

#[cfg(target_os = "macos")]
fn probe_macos(shell_pid: u32) -> Option<AntigravitySession> {
    use std::collections::HashSet;

    let candidates = || -> Option<HashSet<u32>> {
        Some(
            crate::process_tree::descendants(shell_pid)
                .ok()?
                .into_iter()
                .filter(|process| {
                    is_antigravity_process_name(process.executable.rsplit('/').next().unwrap_or(""))
                })
                .map(|process| process.pid)
                .collect(),
        )
    };
    let pids = candidates()?;
    if pids.is_empty() || pids.len() > MAX_PROBE_RECORDS {
        return None;
    }
    let list = pids.iter().map(u32::to_string).collect::<Vec<_>>().join(",");
    let mut command = Command::new("/usr/sbin/lsof");
    command.args(["-n", "-P", "-a", "-p", &list, "-F0pfn"]);
    let bytes = run_probe_output(command)?;
    let live = candidates()?;
    let text = std::str::from_utf8(&bytes).ok()?;
    let (mut pid, mut fd) = (None, None);
    let mut output = String::new();
    let mut count = 0;
    for field in text.split('\0').map(|field| field.trim_start_matches('\n')) {
        if let Some(value) = field.strip_prefix('p') {
            pid = value.parse::<u32>().ok().filter(|p| pids.contains(p) && live.contains(p));
            fd = None;
        } else if let Some(value) = field.strip_prefix('f') {
            fd = value.parse::<u32>().ok();
        } else if let Some(path) = field.strip_prefix('n') {
            let (Some(pid), Some(fd)) = (pid, fd) else { continue };
            let file = Path::new(path);
            let Some(presence_dir) = file.parent() else { continue };
            let Some(cli_root) = presence_dir.parent() else { continue };
            if !path.starts_with('/')
                || path.chars().any(char::is_control)
                || presence_dir.file_name().and_then(|n| n.to_str()) != Some("presence")
                || cli_root.file_name().and_then(|n| n.to_str()) != Some("antigravity-cli")
                || presence_lock_id(file, presence_dir).is_none()
            {
                continue;
            }
            use std::fmt::Write as _;
            let _ = writeln!(output, "{pid}\t{fd}\t{}\t{path}", cli_root.display());
            count += 1;
            if count >= MAX_PROBE_RECORDS || output.len() >= MAX_PROBE_OUTPUT {
                return None;
            }
        }
    }
    parse_presence_records(&output)
}

fn presence_lock_id<'a>(link: &'a Path, presence_root: &Path) -> Option<&'a str> {
    let relative = link.strip_prefix(presence_root).ok()?;
    if relative.components().count() != 1 {
        return None;
    }
    let name = link.file_name()?.to_str()?;
    let id = name.strip_suffix(".lock")?;
    crate::session::valid_antigravity_conversation_segment(id).then_some(id)
}

fn transcript_path_for(cli_root: &str, session_id: &str) -> Option<String> {
    if cli_root.is_empty() || cli_root.chars().any(char::is_control) {
        return None;
    }
    let trimmed = cli_root.trim_end_matches(['/', '\\']);
    let sep = if cli_root.contains('\\') && !cli_root.contains('/') { '\\' } else { '/' };
    let candidate = format!(
        "{trimmed}{sep}brain{sep}{session_id}{sep}.system_generated{sep}logs{sep}transcript_full.jsonl"
    );
    crate::session::valid_antigravity_transcript_path(&candidate, session_id).then_some(candidate)
}

fn parse_presence_records(output: &str) -> Option<AntigravitySession> {
    let mut candidate: Option<AntigravitySession> = None;
    for line in output.lines() {
        let mut fields = line.splitn(4, '\t');
        let _pid: u32 = fields.next()?.parse().ok()?;
        let _fd: u32 = fields.next()?.parse().ok()?;
        let cli_root = fields.next()?;
        let link_str = fields.next()?;
        let presence_root = Path::new(cli_root).join("presence");
        let Some(session_id) = presence_lock_id(Path::new(link_str), &presence_root) else {
            continue;
        };
        let Some(session_file) = transcript_path_for(cli_root, session_id) else {
            continue;
        };
        let session = AntigravitySession { session_id: session_id.to_owned(), session_file };
        if candidate.as_ref().is_some_and(|existing| existing != &session) {
            return None;
        }
        candidate = Some(session);
    }
    candidate
}

#[cfg(test)]
mod tests {
    use super::*;

    const CONV_A: &str = "1f01e5af-a1a9-443a-b393-2cb617faab4d";
    const CONV_B: &str = "dd71656d-3354-432d-84c7-a8149eebe659";

    #[test]
    fn parses_single_presence_lock_and_deduplicates_same_conversation() {
        let root = "/home/user/.gemini/antigravity-cli";
        let output = format!(
            "821823\t27\t{root}\t{root}/presence/{CONV_A}.lock\n\
             821823\t28\t{root}\t{root}/presence/{CONV_A}.lock\n"
        );
        let found = parse_presence_records(&output).expect("single lock resolves");
        assert_eq!(found.session_id, CONV_A);
        assert_eq!(
            found.session_file,
            format!("{root}/brain/{CONV_A}/.system_generated/logs/transcript_full.jsonl")
        );
    }

    #[test]
    fn rejects_ambiguous_or_invalid_presence_locks() {
        let root = "/home/user/.gemini/antigravity-cli";
        let ambiguous = format!(
            "10\t27\t{root}\t{root}/presence/{CONV_A}.lock\n\
             10\t28\t{root}\t{root}/presence/{CONV_B}.lock\n"
        );
        assert_eq!(parse_presence_records(&ambiguous), None);

        let nested = format!("10\t27\t{root}\t{root}/presence/sub/{CONV_A}.lock\n");
        assert_eq!(parse_presence_records(&nested), None);

        let foreign = format!("10\t27\t{root}\t/tmp/presence/{CONV_A}.lock\n");
        assert_eq!(parse_presence_records(&foreign), None);

        let non_lock = format!("10\t27\t{root}\t{root}/presence/{CONV_A}.txt\n");
        assert_eq!(parse_presence_records(&non_lock), None);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn linux_proc_probe_finds_pane_owned_agy_presence_lock_and_ignores_foreign() {
        use std::io::Read as _;
        use std::os::unix::fs::symlink;
        use std::process::Stdio;

        struct OwnedChild(std::process::Child);
        impl Drop for OwnedChild {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }

        let Some(my_term) = crate::platform::process_snapshot::linux_process(std::process::id())
            .map(|p| p.terminal)
        else {
            return;
        };
        if !my_term.is_attached() {
            // Headless test runners without a controlling TTY cannot attach a PTY;
            // pure record parsing above still verifies all contract boundaries.
            return;
        }

        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let presence = home.join(".gemini/antigravity-cli/presence");
        std::fs::create_dir_all(&presence).unwrap();
        let lock_file = presence.join(format!("{CONV_A}.lock"));
        std::fs::write(&lock_file, b"").unwrap();
        let agy_bin = dir.path().join("agy");
        symlink("/bin/sh", &agy_bin).unwrap();

        let pane_id = "agy-probe-pane-77";
        let instance = std::process::id().to_string();
        let mut cmd = Command::new(&agy_bin);
        cmd.args(["-c", "printf R; read -r _"])
            .current_dir(dir.path())
            .env_clear()
            .env("HOME", &home)
            .env("PEBREL_PANE_ID", pane_id)
            .env(crate::agent_env::PROCESS_ENV, &instance)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(std::fs::File::open(&lock_file).unwrap());
        let mut child = OwnedChild(cmd.spawn().unwrap());
        let mut ready = [0u8; 1];
        child.0.stdout.as_mut().unwrap().read_exact(&mut ready).unwrap();

        let found = probe_local_proc(pane_id, &instance, std::process::id())
            .expect("owned agy presence lock found");
        assert_eq!(found.session_id, CONV_A);
        assert!(found.session_file.ends_with(&format!(
            "brain/{CONV_A}/.system_generated/logs/transcript_full.jsonl"
        )));

        // Different pane_id must not match this child.
        assert_eq!(probe_local_proc("other-pane-99", &instance, std::process::id()), None);
    }
}
