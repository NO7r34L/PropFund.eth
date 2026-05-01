// Minimal flag parser. No external dep. Returns { _: [positional...], flags: {} }.
// Supports --flag value, --flag=value, --flag (boolean), -x value, -x=value.
export function parseArgs(argv) {
    const out = { _: [], flags: {} };
    for (let i = 0; i < argv.length; i++) {
        const a = argv[i];
        if (a.startsWith('--')) {
            const eq = a.indexOf('=');
            if (eq > 0) {
                out.flags[a.slice(2, eq)] = a.slice(eq + 1);
            } else {
                const key = a.slice(2);
                const next = argv[i + 1];
                if (next != null && !next.startsWith('-')) {
                    out.flags[key] = next; i++;
                } else {
                    out.flags[key] = true;
                }
            }
        } else if (a.startsWith('-') && a.length > 1) {
            const eq = a.indexOf('=');
            if (eq > 0) {
                out.flags[a.slice(1, eq)] = a.slice(eq + 1);
            } else {
                const key = a.slice(1);
                const next = argv[i + 1];
                if (next != null && !next.startsWith('-')) {
                    out.flags[key] = next; i++;
                } else {
                    out.flags[key] = true;
                }
            }
        } else {
            out._.push(a);
        }
    }
    return out;
}

export function flag(args, name, fallback) {
    return Object.prototype.hasOwnProperty.call(args.flags, name) ? args.flags[name] : fallback;
}

export function requireFlag(args, name) {
    if (!Object.prototype.hasOwnProperty.call(args.flags, name) || args.flags[name] === true) {
        throw new Error(`--${name} is required`);
    }
    return args.flags[name];
}

export function isJson(args) {
    return flag(args, 'json', false) === true || flag(args, 'json', false) === 'true';
}
