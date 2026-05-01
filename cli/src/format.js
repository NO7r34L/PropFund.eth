import { formatUnits } from 'ethers';

// JSON-encode anything ethers gives us, including bigints and Result tuples.
export function emitJson(obj) {
    process.stdout.write(JSON.stringify(obj, replacer, 2) + '\n');
}

function replacer(_key, value) {
    if (typeof value === 'bigint') return value.toString();
    if (value && typeof value === 'object' && typeof value.toJSON === 'function') {
        return value.toJSON();
    }
    return value;
}

export function fmtUsdc(raw, decimals = 6) {
    return formatUnits(raw, decimals);
}

export function fmtPrice(raw, decimals = 8) {
    return formatUnits(raw, decimals);
}

export function fmtEth(raw) {
    return formatUnits(raw, 18);
}

// Print a "key: value" block with aligned keys. Skips undefined values.
export function printRows(rows) {
    const pairs = rows.filter(r => r[1] !== undefined && r[1] !== null);
    if (pairs.length === 0) return;
    const w = Math.max(...pairs.map(([k]) => k.length));
    for (const [k, v] of pairs) {
        process.stdout.write(`${k.padEnd(w)}  ${v}\n`);
    }
}

export function printTable(headers, rows) {
    if (rows.length === 0) {
        process.stdout.write('(none)\n');
        return;
    }
    const widths = headers.map((h, i) => Math.max(h.length, ...rows.map(r => String(r[i] ?? '').length)));
    const fmtRow = r => r.map((c, i) => String(c ?? '').padEnd(widths[i])).join('  ');
    process.stdout.write(fmtRow(headers) + '\n');
    process.stdout.write(widths.map(w => '-'.repeat(w)).join('  ') + '\n');
    for (const r of rows) process.stdout.write(fmtRow(r) + '\n');
}

export function err(msg) {
    process.stderr.write(`error: ${msg}\n`);
}
