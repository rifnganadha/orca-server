{
    const webSocketEndpoint = `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}`;
    const advertisedEndpoint = document.currentScript.dataset.advertisedEndpoint;
    const serverArch = document.currentScript.dataset.serverArch;
    const runtimeEnvironmentKey = "orca.web.runtimeEnvironment.v1";

    const NativeWebSocket = window.WebSocket;
    window.WebSocket = new Proxy(NativeWebSocket, {
        construct(Target, args) {
            const requestedUrl = new URL(args[0], location.href);
            if (requestedUrl.origin === advertisedEndpoint) {
                const replacementUrl = new URL(webSocketEndpoint);
                requestedUrl.protocol = replacementUrl.protocol;
                requestedUrl.host = replacementUrl.host;
                args[0] = requestedUrl.toString();
            }
            return Reflect.construct(Target, args);
        },
    });

    const rewritePairingUrl = (pairingUrl) => {
        try {
            const url = new URL(pairingUrl);
            const payload = JSON.parse(atob(url.searchParams.get("code")));
            payload.endpoint = webSocketEndpoint;
            url.searchParams.set("code", btoa(JSON.stringify(payload)));
            return url.toString();
        } catch {
            return pairingUrl;
        }
    };

    const pairingUrl = new URL(location.href);
    if (pairingUrl.searchParams.has("pairing")) {
        pairingUrl.searchParams.set(
            "pairing",
            rewritePairingUrl(pairingUrl.searchParams.get("pairing")),
        );
        history.replaceState(history.state, "", pairingUrl);
    }

    try {
        const runtimeEnvironment = JSON.parse(
            localStorage.getItem(runtimeEnvironmentKey),
        );
        runtimeEnvironment.endpoints = runtimeEnvironment.endpoints.map(
            (endpoint) => ({
                ...endpoint,
                endpoint:
                    endpoint.kind === "websocket" &&
                    endpoint.endpoint === advertisedEndpoint
                        ? webSocketEndpoint
                        : endpoint.endpoint,
            }),
        );
        localStorage.setItem(
            runtimeEnvironmentKey,
            JSON.stringify(runtimeEnvironment),
        );
    } catch {
        // Orca creates this record after first pairing.
    }

    const userAgent = navigator.userAgent.replace(
        /\([^)]*\)/,
        `(X11; Linux ${serverArch})`,
    );

    Object.defineProperties(navigator, {
        platform: {
            configurable: true,
            get: () => `Linux ${serverArch}`,
        },
        userAgent: {
            configurable: true,
            get: () => userAgent,
        },
    });

    const cliStatus = {
        platform: "linux",
        commandName: "orca-ide",
        commandPath: "/home/orca/.local/bin/orca",
        pathDirectory: "/home/orca/.local/bin",
        pathConfigured: true,
        launcherPath: "/home/orca/.local/bin/orca-ide",
        installMethod: "server",
        supported: true,
        state: "installed",
        currentTarget: "server",
        unsupportedReason: null,
        detail: null,
    };
    const wslStatus = {
        platform: "linux",
        commandName: "orca-ide",
        supported: false,
        state: "unsupported",
        pathConfigured: null,
        detail: "WSL is not available on the Orca server.",
    };

    const patchApi = (value) => {
        if (!value?.cli) {
            return value;
        }

        Object.assign(value.cli, {
            getInstallStatus: () => Promise.resolve(cliStatus),
            install: () => Promise.resolve(cliStatus),
            remove: () => Promise.resolve(cliStatus),
            getWslInstallStatus: () => Promise.resolve(wslStatus),
            installWsl: () => Promise.resolve(wslStatus),
            removeWsl: () => Promise.resolve(wslStatus),
        });
        return value;
    };

    let api = patchApi(window.api);
    Object.defineProperty(window, "api", {
        configurable: true,
        get: () => api,
        set: (value) => {
            api = patchApi(value);
        },
    });
}

if (globalThis.crypto && !globalThis.crypto.randomUUID) {
    globalThis.crypto.randomUUID = () => {
        const bytes = crypto.getRandomValues(new Uint8Array(16));
        bytes[6] = (bytes[6] & 15) | 64;
        bytes[8] = (bytes[8] & 63) | 128;

        const hex = [...bytes].map((value) =>
            value.toString(16).padStart(2, "0"),
        );
        return [
            hex.slice(0, 4).join(""),
            hex.slice(4, 6).join(""),
            hex.slice(6, 8).join(""),
            hex.slice(8, 10).join(""),
            hex.slice(10).join(""),
        ].join("-");
    };
}