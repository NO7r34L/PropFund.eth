import { buildContext } from '../context.js';
import { emitJson, fmtPrice, printTable } from '../format.js';
import { isJson } from '../args.js';

export async function assets(args) {
    const { net, propfund } = buildContext({ network: args.flags.network });
    const list = await propfund.getAssets();

    const rows = list.map((a, i) => ({
        id: Number(a.id ?? a[0]),
        name: net.assetNames[i] ?? `asset_${i}`,
        price: (a.price ?? a[1]).toString(),
        fresh: Boolean(a.fresh ?? a[2]),
    }));

    if (isJson(args)) {
        return emitJson({ network: net.key, assets: rows });
    }

    printTable(
        ['ID', 'NAME', 'PRICE', 'FRESH'],
        rows.map(r => [r.id, r.name, fmtPrice(r.price, net.priceDecimals), r.fresh ? 'yes' : 'no']),
    );
}
