// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

// Deploy on Base Sepolia (chain id 84532) with real Pyth Network feeds.
// Run:
//   PRIVATE_KEY=0x... forge script script/DeployBaseSepolia.s.sol:DeployBaseSepoliaScript \
//     --rpc-url https://sepolia.base.org --broadcast

import {Script, console} from "forge-std/Script.sol";
import {PropFund} from "../src/PropFund.sol";
import {PropFundLens} from "../src/PropFundLens.sol";
import {EvalCert} from "../src/EvalCert.sol";
import {EvalCertRenderer} from "../src/EvalCertRenderer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

contract MockUSDCBaseSepolia {
    string public constant name = "Mock USDC";
    string public constant symbol = "USDC";
    uint8 public constant decimals = 6;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function transfer(address to, uint256 a) external returns (bool) { balanceOf[msg.sender] -= a; balanceOf[to] += a; return true; }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
}

contract DeployBaseSepoliaScript is Script {
    // Pyth Network on Base Sepolia (chain id 84532)
    address constant PYTH = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    // Canonical Pyth price IDs (same on every chain — Pyth IDs are global)
    bytes32 constant ETH_USD  = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    bytes32 constant BTC_USD  = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 constant SOL_USD  = 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d;
    bytes32 constant AVAX_USD = 0x93da3352f9f1d105fdfe4971cfa80e9dd777bfc5d0f683ebb6e1294b92137bb7;
    bytes32 constant LINK_USD = 0x8ac0c70fff57e9aefdf5edf44b51d62c2d433653cbb2cf5cc06bb115af04d221;
    bytes32 constant AAVE_USD = 0x2b9ab1e972a281585084148ba1389800799bd4be63b957507db1349314e47445;
    bytes32 constant DOGE_USD = 0xdcef50dd0a4cd2dcc17e45df1676dcb336a11a61c69df7a0299b0150c672d25c;
    bytes32 constant ARB_USD  = 0x3fa4252848f9f0a1480be62745a4629d9eb1322aebab8a791e344b3b9c1adcf5;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance);

        // ETH at index 0 — that's the eval asset. Order after that is by registration cohort.
        bytes32[] memory ids = new bytes32[](8);
        ids[0] = ETH_USD;
        ids[1] = BTC_USD;
        ids[2] = SOL_USD;
        ids[3] = AVAX_USD;
        ids[4] = LINK_USD;
        ids[5] = AAVE_USD;
        ids[6] = DOGE_USD;
        ids[7] = ARB_USD;

        // Per-feed staleAfter. Crypto majors (ETH/BTC/SOL) get tight 5-min windows since publishers
        // update them constantly. Mid-caps and L2 narrative get 24h on testnet (Base Sepolia has
        // fewer Pyth pushers; some feeds idle for hours). Tighten for mainnet deploy.
        uint256[] memory staleAfter = new uint256[](8);
        staleAfter[0] = 5 minutes;   // ETH
        staleAfter[1] = 5 minutes;   // BTC
        staleAfter[2] = 5 minutes;   // SOL
        staleAfter[3] = 24 hours;    // AVAX
        staleAfter[4] = 1 hours;     // LINK
        staleAfter[5] = 24 hours;    // AAVE
        staleAfter[6] = 24 hours;    // DOGE
        staleAfter[7] = 24 hours;    // ARB

        vm.startBroadcast(pk);

        MockUSDCBaseSepolia usdc = new MockUSDCBaseSepolia();

        PropFund fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            pyth: IPyth(PYTH),
            treasury: vm.envOr("TREASURY", deployer),
            guardian: vm.envOr("GUARDIAN", deployer),
            evalFee: 10e6,
            fundedAllocation: 1_000e6,
            evalDuration: 1_296_000,    // 30 days at 2s blocks on Base
            traderDeposit: 100e6,
            maxFundedTraders: 50,
            priceIds: ids,
            staleAfter: staleAfter
        }));

        // Wire the renderer up front so any eval-pass mints get the real on-chain SVG.
        // Renderer reads PropFund stats to draw a per-trader procedural candlestick chart.
        EvalCertRenderer renderer = new EvalCertRenderer(address(fund));
        EvalCert cert = fund.CERT();
        cert.setRenderer(address(renderer));
        PropFundLens lens = new PropFundLens(address(fund));

        // Seed pool so eval/funding flows work end-to-end
        usdc.mint(deployer, 1_000_000e6);
        usdc.approve(address(fund), type(uint256).max);
        fund.deposit(50_000e6);

        vm.stopBroadcast();

        console.log("");
        console.log("=== DEPLOYED TO BASE SEPOLIA (real Pyth feeds) ===");
        console.log("PropFund:", address(fund));
        console.log("MockUSDC:", address(usdc));
        console.log("EvalCert:", address(cert));
        console.log("Renderer:", address(renderer));
        console.log("Lens:    ", address(lens));
        console.log("Pyth:    ", PYTH);
        console.log("Pool:    ", fund.poolBalance());
        console.log("Assets:  ETH, BTC, SOL, AVAX, LINK, AAVE, DOGE, ARB (Pyth)");
        console.log("");
        console.log("Next steps:");
        console.log("  1. Update cli/src/networks.js with these addresses under `baseSepolia`");
        console.log("  2. Regenerate cli/src/propfund.abi.json with `forge inspect PropFund abi --json`");
    }
}
