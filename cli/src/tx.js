// Helpers shared by write commands.

const MAX_UINT256 = (1n << 256n) - 1n;

export async function ensureAllowance({ usdc, owner, spender, needed, json, skipApprove }) {
    const current = await usdc.allowance(owner, spender);
    if (current >= needed) return null;
    if (skipApprove) {
        // Delegated flow: agent can't approve on behalf of the principal — they have to do it.
        throw new Error(
            `principal ${owner} has insufficient USDC allowance (have ${current}, need ${needed}). ` +
            `Principal must run \`usdc.approve(propfund, <budget>)\` themselves.`
        );
    }
    if (!json) {
        process.stdout.write(`approving USDC (current allowance ${current}, need ${needed})...\n`);
    }
    const tx = await usdc.approve(spender, MAX_UINT256);
    const receipt = await tx.wait();
    if (!json) {
        process.stdout.write(`approved (tx ${tx.hash})\n`);
    }
    return { txHash: tx.hash, blockNumber: receipt.blockNumber };
}

export async function waitTx(tx, label, json) {
    if (!json) process.stdout.write(`${label} submitted: ${tx.hash}\n`);
    const receipt = await tx.wait();
    if (!receipt) throw new Error(`${label}: no receipt`);
    if (receipt.status !== 1) throw new Error(`${label}: tx reverted`);
    if (!json) process.stdout.write(`${label} confirmed in block ${receipt.blockNumber}\n`);
    return receipt;
}
