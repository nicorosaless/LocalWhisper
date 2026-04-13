use serde_json::{json, Value};
use std::env;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::time::{Duration, Instant};

struct Args {
    python: String,
    script: String,
    model_dir: String,
}

struct RuntimeConfig {
    low_ram: bool,
    idle_unload: Duration,
}

struct Backend {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    last_used: Instant,
}

fn env_bool(name: &str, default: bool) -> bool {
    match env::var(name) {
        Ok(v) => {
            let normalized = v.to_lowercase();
            normalized == "1" || normalized == "true" || normalized == "yes"
        }
        Err(_) => default,
    }
}

fn env_u64(name: &str, default: u64) -> u64 {
    match env::var(name) {
        Ok(v) => v.parse::<u64>().unwrap_or(default),
        Err(_) => default,
    }
}

fn runtime_config() -> RuntimeConfig {
    RuntimeConfig {
        low_ram: env_bool("LOCALWHISPER_LOW_RAM", true),
        idle_unload: Duration::from_secs(env_u64("LOCALWHISPER_IDLE_UNLOAD_SECONDS", 25)),
    }
}

fn parse_args() -> Result<Args, String> {
    let mut python: Option<String> = None;
    let mut script: Option<String> = None;
    let mut model_dir: Option<String> = None;

    let mut it = env::args().skip(1);
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--python" => {
                let value = it.next().ok_or("Missing value for --python")?;
                python = Some(value);
            }
            "--script" => {
                let value = it.next().ok_or("Missing value for --script")?;
                script = Some(value);
            }
            "--model-dir" => {
                let value = it.next().ok_or("Missing value for --model-dir")?;
                model_dir = Some(value);
            }
            _ => return Err(format!("Unknown argument: {arg}")),
        }
    }

    Ok(Args {
        python: python.ok_or("--python is required")?,
        script: script.ok_or("--script is required")?,
        model_dir: model_dir.ok_or("--model-dir is required")?,
    })
}

fn spawn_python(args: &Args) -> io::Result<(Child, ChildStdin, BufReader<ChildStdout>)> {
    let mut child = Command::new(&args.python)
        .arg(&args.script)
        .arg("--model-dir")
        .arg(&args.model_dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;

    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "Failed to open python stdin"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| io::Error::new(io::ErrorKind::Other, "Failed to open python stdout"))?;

    Ok((child, stdin, BufReader::new(stdout)))
}

fn start_backend(args: &Args, writer: &mut BufWriter<io::StdoutLock<'_>>) -> io::Result<Backend> {
    let (child, stdin, mut stdout) = spawn_python(args)?;
    let pid = child.id();

    let mut ready_line = String::new();
    match stdout.read_line(&mut ready_line) {
        Ok(0) => {
            let _ = emit_json(
                writer,
                &json!({"error": "Python backend exited before ready signal"}),
            );
            Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "backend exited before ready",
            ))
        }
        Ok(_) => {
            let trimmed = ready_line.trim();
            if trimmed.is_empty() {
                let _ = emit_json(
                    writer,
                    &json!({"error": "Python backend returned empty ready signal"}),
                );
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "empty ready signal",
                ));
            }
            let _ = writeln!(io::stderr(), "[qwen-daemon] backend started pid={pid}");
            Ok(Backend {
                child,
                stdin,
                stdout,
                last_used: Instant::now(),
            })
        }
        Err(e) => {
            let _ = emit_json(writer, &json!({"error": format!("Backend read error: {e}")}));
            Err(e)
        }
    }
}

fn stop_backend(backend: &mut Option<Backend>) {
    if let Some(mut b) = backend.take() {
        let pid = b.child.id();
        let _ = writeln!(b.stdin, "{}", json!({"cmd": "quit"}));
        let _ = b.stdin.flush();
        let _ = b.child.kill();
        let _ = b.child.wait();
        let _ = writeln!(io::stderr(), "[qwen-daemon] backend stopped pid={pid}");
    }
}

fn maybe_unload_idle_backend(backend: &mut Option<Backend>, cfg: &RuntimeConfig) {
    if !cfg.low_ram {
        return;
    }
    if let Some(b) = backend.as_ref() {
        if Instant::now().saturating_duration_since(b.last_used) >= cfg.idle_unload {
            stop_backend(backend);
        }
    }
}

fn emit_json(writer: &mut BufWriter<io::StdoutLock<'_>>, value: &Value) -> io::Result<()> {
    writer.write_all(value.to_string().as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()
}

fn main() {
    let cfg = runtime_config();

    let args = match parse_args() {
        Ok(v) => v,
        Err(e) => {
            let _ = writeln!(io::stderr(), "[qwen-daemon] {e}");
            std::process::exit(2);
        }
    };

    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = BufWriter::new(stdout.lock());
    let mut backend: Option<Backend> = None;

    let _ = emit_json(&mut out, &json!({"status": "ready"}));

    for line in stdin.lock().lines() {
        maybe_unload_idle_backend(&mut backend, &cfg);

        let line = match line {
            Ok(v) => v,
            Err(e) => {
                let _ = emit_json(&mut out, &json!({"error": format!("stdin read error: {e}")}));
                break;
            }
        };

        if line.trim().is_empty() {
            continue;
        }

        let parsed: Value = match serde_json::from_str(&line) {
            Ok(v) => v,
            Err(e) => {
                let _ = emit_json(&mut out, &json!({"error": format!("Invalid JSON: {e}")}));
                continue;
            }
        };

        if let Some(cmd) = parsed.get("cmd").and_then(Value::as_str) {
            match cmd {
                "ping" => {
                    let _ = emit_json(&mut out, &json!({"status": "ready"}));
                    continue;
                }
                "quit" => {
                    stop_backend(&mut backend);
                    let _ = emit_json(&mut out, &json!({"status": "bye"}));
                    break;
                }
                "unload" => {
                    stop_backend(&mut backend);
                    let _ = emit_json(&mut out, &json!({"status": "unloaded"}));
                    continue;
                }
                _ => {
                    let _ = emit_json(&mut out, &json!({"error": format!("Unknown command: {cmd}")}));
                    continue;
                }
            }
        }

        if backend.is_none() {
            match start_backend(&args, &mut out) {
                Ok(b) => backend = Some(b),
                Err(e) => {
                    let _ = emit_json(
                        &mut out,
                        &json!({"error": format!("Failed to start backend: {e}")}),
                    );
                    continue;
                }
            }
        }

        let Some(b) = backend.as_mut() else {
            let _ = emit_json(&mut out, &json!({"error": "Backend unavailable"}));
            continue;
        };

        if let Err(e) = writeln!(b.stdin, "{line}") {
            let _ = emit_json(
                &mut out,
                &json!({"error": format!("Failed to write to backend: {e}")}),
            );
            stop_backend(&mut backend);
            break;
        }
        if let Err(e) = b.stdin.flush() {
            let _ = emit_json(
                &mut out,
                &json!({"error": format!("Failed to flush backend stdin: {e}")}),
            );
            stop_backend(&mut backend);
            break;
        }

        let mut response = String::new();
        match b.stdout.read_line(&mut response) {
            Ok(0) => {
                let _ = emit_json(
                    &mut out,
                    &json!({"error": "Backend closed stdout unexpectedly"}),
                );
                stop_backend(&mut backend);
                break;
            }
            Ok(_) => {
                let _ = out.write_all(response.trim_end().as_bytes());
                let _ = out.write_all(b"\n");
                let _ = out.flush();
                b.last_used = Instant::now();
            }
            Err(e) => {
                let _ = emit_json(
                    &mut out,
                    &json!({"error": format!("Failed to read backend response: {e}")}),
                );
                stop_backend(&mut backend);
                break;
            }
        }
    }

    stop_backend(&mut backend);
}
