// `propfund candles --asset ETH --tf 1h --limit 100`
//
// Pulls OHLCV from Coinbase REST. Pure passthrough — no API key needed for public market data.
// Uses Coinbase's product IDs (ETH-USD, BTC-USD, etc.) derived from the asset name.

import { emitJson, printTable } from '../format.js';
import { isJson, flag, requireFlag } from '../args.js';

// Coinbase /products/{id}/candles granularity is in seconds. Map our friendly names.
const TIMEFRAME_SECONDS = {
    '1m': 60, '5m': 300, '15m': 900, '1h': 3600, '6h': 21600, '1d': 86400,
};

// Coinbase product mapping — most assets map by name + "-USD". A few (Gold, EUR, Crude, etc.)
// don't trade on Coinbase and aren't supported here. Agents should query Pyth Hermes for those.
const PRODUCT_OVERRIDES = {
    XAU: null,
    XAG: null,
    EUR: null,
    GBP: null,
    JPY: null,
    AUD: null,
    CAD: null,
    CHF: null,
    Gold: null,
    Crude: null,
};

function productIdFor(assetName) {
    const upper = String(assetName).toUpperCase();
    if (upper in PRODUCT_OVERRIDES) {
        const v = PRODUCT_OVERRIDES[upper];
        if (v === null) throw new Error(`asset "${assetName}" has no Coinbase market — query Pyth Hermes API directly for these`);
        return v;
    }
    return `${upper}-USD`;
}

// Pure Coinbase passthrough — no contract context required, so it works against any network
// (and even with no contract deployed).
export async function candles(args) {
    const assetName = requireFlag(args, 'asset');
    const tf = String(flag(args, 'tf', '1h'));
    const limit = Math.max(1, Math.min(300, Number(flag(args, 'limit', 100))));

    const granularity = TIMEFRAME_SECONDS[tf];
    if (!granularity) {
        throw new Error(`--tf must be one of: ${Object.keys(TIMEFRAME_SECONDS).join(', ')}`);
    }

    const product = productIdFor(assetName);
    const url = `https://api.exchange.coinbase.com/products/${product}/candles?granularity=${granularity}`;

    const res = await fetch(url, {
        headers: { 'User-Agent': 'propfund-cli/0.1' },
    });
    if (!res.ok) {
        throw new Error(`Coinbase request failed: ${res.status} ${res.statusText}`);
    }
    const raw = await res.json();
    if (!Array.isArray(raw)) {
        throw new Error(`unexpected Coinbase response: ${JSON.stringify(raw).slice(0, 200)}`);
    }

    // Coinbase returns [time, low, high, open, close, volume] descending by time. Take `limit`.
    const trimmed = raw.slice(0, limit).map(([t, low, high, open, close, volume]) => ({
        timestamp: t,
        open, high, low, close, volume,
    }));

    if (isJson(args)) {
        return emitJson({
            ok: true,
            asset: assetName.toUpperCase(),
            product,
            timeframe: tf,
            granularitySeconds: granularity,
            count: trimmed.length,
            candles: trimmed,
        });
    }

    const tz = (ts) => new Date(ts * 1000).toISOString().replace('T', ' ').slice(0, 16) + 'Z';
    printTable(
        ['TIME (UTC)', 'OPEN', 'HIGH', 'LOW', 'CLOSE', 'VOLUME'],
        trimmed.map(c => [
            tz(c.timestamp),
            c.open.toFixed(2),
            c.high.toFixed(2),
            c.low.toFixed(2),
            c.close.toFixed(2),
            c.volume.toFixed(2),
        ]),
    );
}
