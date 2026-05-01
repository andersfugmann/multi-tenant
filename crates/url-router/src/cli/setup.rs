//! `url-router setup` subcommand.
//!
//! Verifies the environment, enables the systemd user service,
//! and registers url-router as the default browser.

use std::path::Path;
use std::process::Command;

use crate::config_io;

/// Run all setup checks and actions for a tenant.
pub fn run(tenant: &str, config_path: &str) {
    println!("Setting up url-router for tenant '{tenant}'...\n");

    let config = match config_io::load_config(config_path) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("✗ Config: failed to load {config_path}: {e}");
            std::process::exit(1);
        }
    };

    // 1. Verify tenant exists in config
    match config.tenant(tenant) {
        Some(t) => println!("✓ Tenant '{tenant}' found in config (name: {})", t.name),
        None => {
            eprintln!("✗ Tenant '{tenant}' not found in config");
            std::process::exit(1);
        }
    }

    // 2. Verify config file is readable
    println!("✓ Config file: {config_path}");

    // 3. Verify socket directory
    let socket_path = &config.tenant(tenant).unwrap().socket;
    let socket_dir = Path::new(socket_path)
        .parent()
        .unwrap_or(Path::new("/run/url-router"));
    if socket_dir.exists() {
        println!("✓ Socket directory: {}", socket_dir.display());
    } else {
        eprintln!(
            "✗ Socket directory {} does not exist. \
             Ensure tmpfiles.d is configured and run: systemd-tmpfiles --create",
            socket_dir.display()
        );
    }

    // 4. Enable systemd user service
    let service_name = format!("url-router@{tenant}.service");
    print!("  Enabling {service_name}... ");
    match Command::new("systemctl")
        .args(["--user", "enable", "--now", &service_name])
        .output()
    {
        Ok(out) if out.status.success() => println!("✓"),
        Ok(out) => {
            let stderr = String::from_utf8_lossy(&out.stderr);
            println!("✗ {}", stderr.trim());
        }
        Err(e) => println!("✗ {e}"),
    }

    // 5. Set url-router.desktop as default browser
    print!("  Setting url-router as default browser... ");
    let handlers = [
        "x-scheme-handler/http",
        "x-scheme-handler/https",
        "text/html",
    ];
    let mut all_ok = true;
    for handler in &handlers {
        match Command::new("xdg-mime")
            .args(["default", "url-router.desktop", handler])
            .output()
        {
            Ok(out) if out.status.success() => {}
            _ => {
                all_ok = false;
            }
        }
    }
    if all_ok {
        println!("✓");
    } else {
        println!("✗ (some handlers failed — is url-router.desktop installed?)");
    }

    // 6. Check for native messaging host manifests
    let native_host_paths = [
        "/etc/chromium/native-messaging-hosts/com.url_router.json",
        "/etc/opt/edge/native-messaging-hosts/com.url_router.json",
    ];
    println!("\n  Native messaging hosts:");
    for path in &native_host_paths {
        if Path::new(path).exists() {
            println!("    ✓ {path}");
        } else {
            println!("    ✗ {path} (install url-router-extension package)");
        }
    }

    println!("\nSetup complete.");
}
