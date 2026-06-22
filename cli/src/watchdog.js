// Run an async step against a hard timeout. Resolves with the step's result if it finishes in
// time; rejects with Error('watchdog-timeout') if it hangs past timeoutMs. The timer is cleared
// either way, so successful steps never leave a dangling timer.
//
// Used by the agent and keeper loops: a tick makes RPC + Hermes (+ LLM) calls with no per-call
// timeout, so a dead socket can freeze the loop forever. Because the process stays *alive*,
// systemd's Restart=always never fires — so the caller treats a watchdog-timeout as fatal and
// exits, letting Restart=always bring the process back fresh.
export async function runWithWatchdog(fn, timeoutMs) {
    let timer;
    try {
        return await Promise.race([
            fn(),
            new Promise((_, reject) => {
                timer = setTimeout(() => reject(new Error('watchdog-timeout')), timeoutMs);
            }),
        ]);
    } finally {
        clearTimeout(timer);
    }
}
