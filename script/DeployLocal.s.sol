// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PropFund} from "../src/PropFund.sol";
import {PropFundLens} from "../src/PropFundLens.sol";
import {EvalCert} from "../src/EvalCert.sol";
import {EvalCertRenderer} from "../src/EvalCertRenderer.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IPyth} from "../src/interfaces/IPyth.sol";

contract MockUSDCLocal {
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

/// In-memory Pyth mock for local Anvil. Same shape as test/mocks/MockPyth.sol; duplicated here
/// because Foundry scripts can't import from test/.
contract MockPythLocal is IPyth {
    mapping(bytes32 => Price) internal _prices;

    function setSpotE8(bytes32 id, int256 priceE8) external {
        _prices[id] = Price({ price: int64(priceE8), conf: 0, expo: -8, publishTime: block.timestamp });
    }

    function getPriceUnsafe(bytes32 id) external view override returns (Price memory) {
        return _prices[id];
    }

    function updatePriceFeeds(bytes[] calldata) external payable override {}

    function getUpdateFee(bytes[] calldata) external pure override returns (uint256) {
        return 1;
    }
}

/// Deploy-only local script. Drive faucet, eval, trade, etc. via the propfund CLI.
contract DeployLocalScript is Script {
    uint256 constant DEPLOYER_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    address constant DEPLOYER     = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
    // Anvil account #1 — distinct guardian so the treasury/guardian split is real even locally.
    address constant GUARDIAN_ADDR = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    bytes32 constant ETH_ID  = bytes32(uint256(1));
    bytes32 constant BTC_ID  = bytes32(uint256(2));
    bytes32 constant LINK_ID = bytes32(uint256(3));

    function run() external {
        vm.startBroadcast(DEPLOYER_KEY);

        MockUSDCLocal usdc = new MockUSDCLocal();
        // Full 8-asset set in the agent's canonical order (ETH,BTC,SOL,AVAX,LINK,AAVE,DOGE,ARB)
        // so the local deploy matches the agent's asset universe end-to-end.
        bytes32 SOL_ID  = bytes32(uint256(4));
        bytes32 AVAX_ID = bytes32(uint256(5));
        bytes32 AAVE_ID = bytes32(uint256(6));
        bytes32 DOGE_ID = bytes32(uint256(7));
        bytes32 ARB_ID  = bytes32(uint256(8));

        MockPythLocal pyth = new MockPythLocal();
        pyth.setSpotE8(ETH_ID,  4000e8);
        pyth.setSpotE8(BTC_ID,  60000e8);
        pyth.setSpotE8(SOL_ID,  150e8);
        pyth.setSpotE8(AVAX_ID, 35e8);
        pyth.setSpotE8(LINK_ID, 15e8);
        pyth.setSpotE8(AAVE_ID, 90e8);
        pyth.setSpotE8(DOGE_ID, 12e6);   // 0.12
        pyth.setSpotE8(ARB_ID,  80e6);   // 0.80

        bytes32[] memory ids = new bytes32[](8);
        ids[0] = ETH_ID; ids[1] = BTC_ID; ids[2] = SOL_ID;  ids[3] = AVAX_ID;
        ids[4] = LINK_ID; ids[5] = AAVE_ID; ids[6] = DOGE_ID; ids[7] = ARB_ID;
        uint256[] memory staleAfter = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) staleAfter[i] = 1 hours;

        PropFund fund = new PropFund(PropFund.Config({
            usdc: IERC20(address(usdc)),
            pyth: IPyth(address(pyth)),
            treasury: DEPLOYER,
            guardian: GUARDIAN_ADDR,
            evalFee: 10e6,
            fundedAllocation: 1_000e6,
            evalDuration: 50_400,
            traderDeposit: 100e6,
            maxFundedTraders: vm.envOr("MAX_FUNDED", uint256(50)),
            priceIds: ids,
            staleAfter: staleAfter
        }));

        // Wire up the renderer so cert tokenURI() works end-to-end.
        EvalCertRenderer renderer = new EvalCertRenderer(address(fund));
        EvalCert cert = fund.CERT();
        cert.setRenderer(address(renderer));
        PropFundLens lens = new PropFundLens(address(fund));

        // Seed LP pool so funded traders have allocation to draw on.
        usdc.mint(DEPLOYER, 1_000_000e6);
        usdc.approve(address(fund), type(uint256).max);
        fund.deposit(50_000e6);

        vm.stopBroadcast();

        console.log("=== DEPLOYED ===");
        console.log("PROPFUND_CONTRACT=", address(fund));
        console.log("PROPFUND_USDC=",     address(usdc));
        console.log("PYTH=",              address(pyth));
        console.log("RENDERER=",          address(renderer));
        console.log("LENS=",              address(lens));
        console.log("Pool seeded:",       fund.poolBalance());
    }
}
